import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ChevronRight, File, FileArchive, FileCode, FileImage, FileSpreadsheet, FileText, Folder, LayoutGrid, List as ListIcon,
  MoreHorizontal, type LucideIcon,
} from "lucide-react";
import { api, isTauri } from "../lib/api";
import { useStore } from "../lib/store";
import type { DirEntry, FolderCard } from "../lib/types";
import { IconButton, Menu, type MenuState } from "./Menu";

const IMAGE = new Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic"]);
const KIND: [Set<string>, LucideIcon][] = [
  [IMAGE, FileImage],
  [new Set(["md", "txt", "doc", "docx", "pdf", "rtf", "pages"]), FileText],
  [new Set(["xls", "xlsx", "csv", "numbers"]), FileSpreadsheet],
  [new Set(["zip", "gz", "tar", "7z", "rar", "dmg"]), FileArchive],
  [new Set(["js", "ts", "tsx", "py", "rs", "swift", "c", "cpp", "h", "java", "go", "sh", "json", "yaml", "yml", "toml", "html", "css"]), FileCode],
];

function iconFor(e: DirEntry): LucideIcon {
  if (e.isDir) return Folder;
  return KIND.find(([set]) => set.has(e.ext))?.[1] ?? File;
}

function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(1)} GB`;
}

const sepOf = (p: string) => (p.includes("\\") && !p.includes("/") ? "\\" : "/");
const baseName = (p: string) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || p;

/** Directories of every mounted folder card, so a drop can refresh both ends. */
const reloaders = new Map<string, Set<() => void>>();
export function reloadDir(dir: string) {
  reloaders.get(dir)?.forEach((f) => f());
}

/**
 * A folder on disk, browsable in place. Files leave the card as a native OS
 * drag (so Finder/Explorer and other apps accept them); drops are resolved by
 * the board-level handler through `data-drop-dir` targets.
 */
export function FolderCardView({ card, cardKey }: { card: FolderCard; cardKey: string }) {
  const update = useStore((s) => s.updateFolderCard);
  const remove = useStore((s) => s.removeFolderCard);
  const moveCard = useStore((s) => s.moveCard);
  const notify = useStore((s) => s.notify);
  const showHidden = useStore((s) => s.settings?.showHiddenFiles ?? false);

  const favorite = card.favorites.find((f) => f.id === card.selectedFavorite) ?? card.favorites[0];
  const root = favorite?.path ?? "";
  const dir = card.currentPath ?? root;

  const [entries, setEntries] = useState<DirEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [renaming, setRenaming] = useState<string | null>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const seq = useRef(0);

  const load = useCallback(() => {
    if (!dir) return;
    const mine = ++seq.current;
    api.listDir(dir, showHidden).then(
      (list) => {
        if (mine !== seq.current) return;
        setEntries(list);
        setError(null);
        setSelected((sel) => new Set([...sel].filter((p) => list.some((e) => e.path === p))));
      },
      (e) => {
        if (mine !== seq.current) return;
        setEntries([]);
        setError(String(e).includes("notFound") ? "这个文件夹不在了" : `打不开这个文件夹：${e}`);
      },
    );
  }, [dir, showHidden]);

  useEffect(() => {
    setEntries(null);
    load();
    const set = reloaders.get(dir) ?? new Set();
    set.add(load);
    reloaders.set(dir, set);
    return () => {
      set.delete(load);
    };
  }, [dir, load]);

  const sorted = useMemo(() => {
    const list = [...(entries ?? [])];
    const dirSign = card.sortAsc ? 1 : -1;
    list.sort((a, b) => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      let c = 0;
      if (card.sortKey === "modified") c = a.modified - b.modified;
      else if (card.sortKey === "kind") c = a.ext.localeCompare(b.ext);
      return (c || a.name.localeCompare(b.name, "zh-Hans-CN", { numeric: true })) * dirSign;
    });
    return list;
  }, [entries, card.sortKey, card.sortAsc]);

  const go = (path: string | null) => {
    setSelected(new Set());
    void update({ ...card, currentPath: path === root ? null : path });
  };

  const crumbs = useMemo(() => {
    if (!root) return [];
    const sep = sepOf(root);
    const rest = dir.startsWith(root) ? dir.slice(root.length).split(/[\\/]/).filter(Boolean) : [];
    const out = [{ name: favorite?.name ?? baseName(root), path: root }];
    let acc = root.replace(/[\\/]+$/, "");
    for (const part of rest) {
      acc += sep + part;
      out.push({ name: part, path: acc });
    }
    return out;
  }, [root, dir, favorite]);

  const act = async (what: Promise<unknown>) => {
    try {
      await what;
    } catch (e) {
      const m = String(e);
      notify(m.includes("exists:") ? `“${m.split("exists:")[1]}”已经存在` : `没有成功：${m}`);
    }
    load();
  };

  // Press → move a few pixels → hand the selection to the OS as a file drag.
  const press = (e: React.PointerEvent, entry: DirEntry) => {
    if (e.button !== 0 || renaming) return;
    let next = selected;
    if (e.metaKey || e.ctrlKey) {
      next = new Set(selected);
      if (next.has(entry.path)) next.delete(entry.path);
      else next.add(entry.path);
    } else if (e.shiftKey && selected.size) {
      const paths = sorted.map((x) => x.path);
      const a = paths.indexOf([...selected][selected.size - 1]);
      const b = paths.indexOf(entry.path);
      next = new Set(paths.slice(Math.min(a, b), Math.max(a, b) + 1));
    } else if (!selected.has(entry.path)) {
      next = new Set([entry.path]);
    }
    setSelected(next);
    const paths = [...(next.has(entry.path) ? next : new Set([entry.path]))];
    const x0 = e.clientX;
    const y0 = e.clientY;
    const move = (m: PointerEvent) => {
      if (Math.hypot(m.clientX - x0, m.clientY - y0) < 5) return;
      stop();
      void api.startFileDrag(paths);
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop);
  };

  const open = (entry: DirEntry) => (entry.isDir ? go(entry.path) : void api.openPath(entry.path));

  const entryMenu = (e: React.MouseEvent, entry: DirEntry | null) => {
    e.preventDefault();
    e.stopPropagation();
    const targets = entry ? (selected.has(entry.path) ? [...selected] : [entry.path]) : [];
    if (entry && !selected.has(entry.path)) setSelected(new Set([entry.path]));
    setMenu({
      x: e.clientX,
      y: e.clientY,
      items: entry
        ? [
            { label: "打开", onSelect: () => open(entry) },
            { label: "在文件管理器中显示", onSelect: () => void api.revealPath(entry.path) },
            "sep",
            { label: "重命名", disabled: targets.length !== 1, onSelect: () => setRenaming(entry.path) },
            { label: "拷贝路径", onSelect: () => void navigator.clipboard.writeText(targets.join("\n")) },
            "sep",
            { label: targets.length > 1 ? `把 ${targets.length} 项移到废纸篓` : "移到废纸篓", danger: true, onSelect: () => void act(api.fsTrash(targets)) },
          ]
        : [
            { label: "新建文件夹", onSelect: () => void act(api.fsNewFolder(dir).then((p) => setRenaming(p))) },
            { label: "在文件管理器中显示", onSelect: () => void api.openPath(dir) },
          ],
    });
  };

  const cardMenu = (e: React.MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const sort = (sortKey: FolderCard["sortKey"], label: string) => ({
      label: (card.sortKey === sortKey ? (card.sortAsc ? "↑ " : "↓ ") : "") + label,
      onSelect: () => void update({ ...card, sortKey, sortAsc: card.sortKey === sortKey ? !card.sortAsc : true }),
    });
    setMenu({
      x: r.right - 170,
      y: r.bottom + 4,
      items: [
        sort("name", "按名称排序"),
        sort("kind", "按类型排序"),
        sort("modified", "按修改时间排序"),
        "sep",
        {
          label: "再收藏一个文件夹",
          onSelect: async () => {
            const picked = await api.pickDirectory();
            if (!picked) return;
            const fav = { id: crypto.randomUUID(), path: picked, name: baseName(picked) };
            void update({ ...card, favorites: [...card.favorites, fav], selectedFavorite: fav.id, currentPath: null });
          },
        },
        {
          label: `取消收藏“${favorite?.name ?? ""}”`,
          disabled: card.favorites.length < 2,
          onSelect: () => {
            const favorites = card.favorites.filter((f) => f.id !== favorite?.id);
            void update({ ...card, favorites, selectedFavorite: favorites[0]?.id ?? null, currentPath: null });
          },
        },
        "sep",
        { label: "上移", onSelect: () => void moveCard(cardKey, -1) },
        { label: "下移", onSelect: () => void moveCard(cardKey, 1) },
        "sep",
        { label: "移除这张文件夹卡片", danger: true, onSelect: () => void remove(card.id) },
      ],
    });
  };

  return (
    <article className="sheet sheet--folder">
      <header className="sheet__head">
        <div className="sheet__heading">
          <nav className="crumbs" aria-label="路径">
            {card.favorites.length > 1 && card.currentPath === null
              ? card.favorites.map((f) => (
                  <button
                    key={f.id}
                    type="button"
                    className={"crumbs__fav" + (f.id === favorite?.id ? " is-on" : "")}
                    data-drop-dir={f.path}
                    onClick={() => void update({ ...card, selectedFavorite: f.id, currentPath: null })}
                  >
                    {f.name}
                  </button>
                ))
              : crumbs.map((c, i) => (
                  <span key={c.path} className="crumbs__part">
                    {i > 0 && <ChevronRight size={12} className="crumbs__sep" />}
                    <button
                      type="button"
                      className={"crumbs__btn" + (i === crumbs.length - 1 ? " is-here" : "")}
                      data-drop-dir={c.path}
                      onClick={() => go(c.path)}
                    >
                      {c.name}
                    </button>
                  </span>
                ))}
          </nav>
        </div>
        <div className="sheet__tools">
          <IconButton
            label={card.viewMode === "icon" ? "换成列表" : "换成图标"}
            onClick={() => void update({ ...card, viewMode: card.viewMode === "icon" ? "list" : "icon" })}
          >
            {card.viewMode === "icon" ? <ListIcon size={15} /> : <LayoutGrid size={15} />}
          </IconButton>
          <IconButton label="更多" onClick={cardMenu}>
            <MoreHorizontal size={15} />
          </IconButton>
        </div>
      </header>

      <div
        className={`files files--${card.viewMode}`}
        style={{ maxHeight: card.listHeight }}
        data-drop-dir={dir}
        onPointerDown={(e) => e.target === e.currentTarget && setSelected(new Set())}
        onContextMenu={(e) => entryMenu(e, null)}
      >
        {error && <p className="files__state">{error}</p>}
        {!error && entries && sorted.length === 0 && <p className="files__state">空文件夹。把文件拖进来。</p>}
        {sorted.map((entry) => {
          const Icon = iconFor(entry);
          const thumb = card.viewMode === "icon" && isTauri && IMAGE.has(entry.ext);
          return (
            <div
              key={entry.path}
              className={"file" + (selected.has(entry.path) ? " is-selected" : "") + (entry.isDir ? " is-dir" : "")}
              data-drop-dir={entry.isDir ? entry.path : undefined}
              onPointerDown={(e) => press(e, entry)}
              onDoubleClick={() => open(entry)}
              onContextMenu={(e) => entryMenu(e, entry)}
              title={entry.name}
            >
              {thumb ? (
                <img className="file__thumb" src={api.resolveAsset("", entry.path)} alt="" draggable={false} loading="lazy" />
              ) : (
                <Icon className="file__icon" size={card.viewMode === "icon" ? 30 : 16} strokeWidth={card.viewMode === "icon" ? 1.3 : 1.8} />
              )}
              {renaming === entry.path ? (
                <input
                  className="file__rename"
                  defaultValue={entry.name}
                  autoFocus
                  onFocus={(e) => {
                    const dot = entry.isDir ? -1 : entry.name.lastIndexOf(".");
                    e.currentTarget.setSelectionRange(0, dot > 0 ? dot : entry.name.length);
                  }}
                  onPointerDown={(e) => e.stopPropagation()}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") e.currentTarget.blur();
                    if (e.key === "Escape") {
                      e.stopPropagation();
                      e.currentTarget.value = entry.name;
                      e.currentTarget.blur();
                    }
                  }}
                  onBlur={(e) => {
                    const name = e.currentTarget.value.trim();
                    setRenaming(null);
                    if (name && name !== entry.name) void act(api.fsRename(entry.path, name));
                  }}
                />
              ) : (
                <span className="file__name">{entry.name}</span>
              )}
              {card.viewMode === "list" && <span className="file__meta">{entry.isDir ? "" : fmtSize(entry.size)}</span>}
            </div>
          );
        })}
      </div>
      {menu && <Menu menu={menu} onClose={() => setMenu(null)} />}
    </article>
  );
}
