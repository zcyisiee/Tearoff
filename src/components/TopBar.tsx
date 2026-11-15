import { useEffect, useRef } from "react";
import { FolderPlus, Pin, Search, Settings as Gear, SquarePen, X } from "lucide-react";
import { useStore } from "../lib/store";
import { IconButton } from "./Menu";

export function TopBar() {
  const { searching, query, panelPinned, view } = useStore();
  const setSearching = useStore((s) => s.setSearching);
  const setQuery = useStore((s) => s.setQuery);
  const createNote = useStore((s) => s.createNote);
  const addFolderCard = useStore((s) => s.addFolderCard);
  const setView = useStore((s) => s.setView);
  const togglePin = useStore((s) => s.togglePanelPinned);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (searching) input.current?.focus();
  }, [searching]);

  return (
    <div className="topbar">
      {searching ? (
        <div className="topbar__search">
          <Search size={15} />
          <input
            ref={input}
            value={query}
            placeholder="搜索标题和正文"
            aria-label="搜索笔记"
            spellCheck={false}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                e.stopPropagation();
                setSearching(false);
              }
            }}
          />
          <IconButton label="关闭搜索" onClick={() => setSearching(false)}>
            <X size={15} />
          </IconButton>
        </div>
      ) : (
        <>
          <IconButton label="搜索  ⌘F" onClick={() => setSearching(true)}>
            <Search size={16} />
          </IconButton>
          <span className="topbar__gap" />
          <IconButton label="新建笔记  ⌘N" onClick={() => void createNote()}>
            <SquarePen size={16} />
          </IconButton>
          <IconButton label="添加文件夹" onClick={() => void addFolderCard()}>
            <FolderPlus size={16} />
          </IconButton>
          <IconButton label="设置" active={view === "settings"} onClick={() => setView(view === "settings" ? "home" : "settings")}>
            <Gear size={16} />
          </IconButton>
          <IconButton label={panelPinned ? "取消固定" : "固定"} active={panelPinned} onClick={() => void togglePin()}>
            <Pin size={16} />
          </IconButton>
        </>
      )}
    </div>
  );
}
