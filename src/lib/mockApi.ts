import type { Api, AppState, DirEntry, FolderCard, NoteMeta, Settings } from "./types";

/**
 * In-memory backend for running the UI in a plain browser (`pnpm dev`) and in
 * tests. Mirrors the semantics of the Rust commands closely enough to exercise
 * every screen; nothing touches disk.
 */

const DAY = 86400000;

function localDate(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function stripPreview(md: string): string {
  return md
    .replace(/^---\n[\s\S]*?\n---\n/, "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/^\s*[-*+]\s+\[[ xX]\]\s*/gm, "")
    .replace(/^\s*(#{1,6}|[-*+>]|\d+\.)\s+/gm, "")
    .replace(/[*_~`=]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
}

interface MockFile {
  content: string;
  created: number;
  modified: number;
  pinned: boolean;
  order: number | null;
}

const now = Date.now();
const files = new Map<string, MockFile>();

function seed(path: string, content: string, ageDays: number, pinned = false, order: number | null = null) {
  files.set(path, { content, created: now - ageDays * DAY, modified: now - ageDays * DAY, pinned, order });
}

seed(
  `Daily/${localDate(now)}.md`,
  "- [x] 回复导师邮件\n- [ ] 跑完实验 3 的消融\n- [ ] 订周五的会议室\n\n想法：缓存可以按 **请求指纹** 分桶，命中率也许能再提一截。\n",
  0,
);
seed(
  "常用命令.md",
  "## 服务器\n\n```bash\nssh lab-gpu01\nconda activate torch\n```\n\n- 查看显存：`nvidia-smi`\n- 后台跑：`nohup python train.py &`\n\n## 公式备忘\n\n注意力：$\\mathrm{softmax}(QK^\\top / \\sqrt{d_k})V$\n",
  3,
  true,
  0,
);
seed(
  "读书笔记.md",
  "# 《科学写作的科学》\n\n读者在**句子开头**期待旧信息，在*句末*期待新信息。\n\n> 把最想强调的内容放在重音位置。\n\n| 位置 | 读者期待 |\n| --- | --- |\n| 主题位 | 已知、承接 |\n| 重音位 | 新的、重要的 |\n",
  2,
);
seed(`Daily/${localDate(now - DAY)}.md`, "- [x] 提交报销\n- [x] 组会 PPT 初稿\n- [ ] 给师弟看代码\n", 1);
seed(`Daily/${localDate(now - 3 * DAY)}.md`, "- [x] 修好数据加载的 bug\n\n晚上想到：评测集应该按 ==时间切分== 而不是随机切分。\n", 3);
seed("周会要点.md", "1. 下周三前交初稿\n2. 补一组基线对比\n3. 图 3 换成对数坐标\n", 5);
seed("想买的东西.md", "- [ ] 人体工学椅\n- [ ] 4K 显示器\n- [x] 机械键盘\n", 12);
seed("论文想法/缓存分桶.md", "按请求指纹分桶，冷热分离。先在小数据集上验证命中率。\n", 20);
seed("旧笔记/含HTML.md", "这篇有 <kbd>Ctrl</kbd> 这样的行内 HTML，脚注[^1]。\n\n[^1]: 所以会用源码模式打开。\n", 40);

const fsTree = new Map<string, DirEntry[]>();
function ent(dir: string, name: string, isDir = false, size = 1024): DirEntry {
  const ext = isDir || !name.includes(".") ? "" : name.slice(name.lastIndexOf(".") + 1).toLowerCase();
  return { name, path: `${dir}/${name}`, isDir, size, modified: now - 5 * DAY, ext };
}
const ROOT = "/Users/demo/常用";
fsTree.set(ROOT, [
  ent(ROOT, "clash-for-linux-install", true),
  ent(ROOT, "模板", true),
  ent(ROOT, "开题报告.docx", false, 482133),
  ent(ROOT, "实验结果.xlsx", false, 80211),
  ent(ROOT, "架构图.png", false, 1203300),
  ent(ROOT, "notes.md", false, 2210),
]);
fsTree.set(`${ROOT}/clash-for-linux-install`, [
  ent(`${ROOT}/clash-for-linux-install`, "archives", true),
  ent(`${ROOT}/clash-for-linux-install`, "install.sh", false, 5120),
  ent(`${ROOT}/clash-for-linux-install`, "README.md", false, 3301),
]);
fsTree.set(`${ROOT}/clash-for-linux-install/archives`, [
  ent(`${ROOT}/clash-for-linux-install/archives`, "alpha.txt"),
  ent(`${ROOT}/clash-for-linux-install/archives`, "beta.txt"),
  ent(`${ROOT}/clash-for-linux-install/archives`, "gamma.md"),
]);
fsTree.set(`${ROOT}/模板`, []);

let folderCards: FolderCard[] = [
  {
    id: "fc-1",
    title: null,
    favorites: [{ id: "fav-1", path: ROOT, name: "常用" }],
    selectedFavorite: "fav-1",
    currentPath: null,
    viewMode: "list",
    sortKey: "name",
    sortAsc: true,
    listHeight: 200,
    order: 1,
  },
];

let settings: Settings = {
  vaultPath: "/Users/demo/Tearoff",
  side: "right",
  panelWidth: 460,
  edgeActivation: true,
  activationDelayMs: 300,
  hideDelayMs: 200,
  toggleShortcut: "CmdOrCtrl+Shift+Space",
  theme: "system",
  fontSize: 15,
  showHiddenFiles: false,
};
let panelPinned = false;

function meta(path: string): NoteMeta {
  const f = files.get(path)!;
  const name = path.slice(path.lastIndexOf("/") + 1).replace(/\.md$/, "");
  const folder = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  const dailyDate = folder.split("/")[0] === "Daily" && /^\d{4}-\d{2}-\d{2}$/.test(name) ? name : null;
  return {
    path,
    title: name,
    folder,
    created: f.created,
    modified: f.modified,
    pinned: f.pinned,
    order: f.order,
    preview: stripPreview(f.content),
    dailyDate,
  };
}

const vaultListeners: (() => void)[] = [];
const dirListeners: ((p: string) => void)[] = [];
const changed = () => vaultListeners.forEach((l) => l());
const parentOf = (p: string) => p.slice(0, p.lastIndexOf("/"));

export const mockApi: Api = {
  async getState(): Promise<AppState> {
    return {
      notes: [...files.keys()].map(meta),
      folderCards: structuredClone(folderCards),
      settings: { ...settings },
      today: localDate(Date.now()),
      panelPinned,
      panelShown: true,
    };
  },
  async readNote(path) {
    const f = files.get(path);
    return f ? { content: f.content, modified: f.modified } : { content: "", modified: 0 };
  },
  async writeNote(path, content, baseModified) {
    const f = files.get(path);
    if (f && baseModified !== null && f.modified !== baseModified) throw new Error("conflict");
    const t = Date.now();
    if (f) Object.assign(f, { content, modified: t });
    else files.set(path, { content, created: t, modified: t, pinned: false, order: null });
    return meta(path);
  },
  async createNote(title) {
    const base = (title ?? "").trim() || "未命名";
    let name = base;
    for (let i = 2; files.has(`${name}.md`); i++) name = `${base} ${i}`;
    const t = Date.now();
    files.set(`${name}.md`, { content: "", created: t, modified: t, pinned: false, order: null });
    return meta(`${name}.md`);
  },
  async renameNote(path, title) {
    const f = files.get(path);
    if (!f) throw new Error("not found");
    const folder = path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "";
    const next = `${folder}${title.trim()}.md`;
    if (next === path) return meta(path);
    if (files.has(next)) throw new Error("exists");
    files.delete(path);
    files.set(next, f);
    return meta(next);
  },
  async deleteNote(path) {
    files.delete(path);
  },
  async setPinned(path, pinned) {
    const f = files.get(path);
    if (f) {
      f.pinned = pinned;
      if (!pinned) f.order = null;
    }
  },
  async reorderCards(keys) {
    keys.forEach((k, i) => {
      if (k.startsWith("note:")) {
        const f = files.get(k.slice(5));
        if (f) f.order = i;
      } else {
        const c = folderCards.find((c) => c.id === k.slice(7));
        if (c) c.order = i;
      }
    });
  },
  async search(query) {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const hits = [];
    for (const [path, f] of files) {
      const m = meta(path);
      const idx = f.content.toLowerCase().indexOf(q);
      if (idx < 0 && !m.title.toLowerCase().includes(q)) continue;
      const snippet = idx < 0 ? m.preview.slice(0, 80) : f.content.slice(Math.max(0, idx - 20), idx + 60).replace(/\s+/g, " ");
      hits.push({ path, title: m.title, snippet });
    }
    return hits;
  },
  async saveImage(_notePath, name, dataBase64) {
    return `data:image/${name.split(".").pop()};base64,${dataBase64}`;
  },
  resolveAsset: (_notePath, src) => src,

  async createFolderCard(dir) {
    const card: FolderCard = {
      id: `fc-${Date.now()}`,
      title: null,
      favorites: [{ id: `fav-${Date.now()}`, path: dir, name: dir.slice(dir.lastIndexOf("/") + 1) }],
      selectedFavorite: null,
      currentPath: null,
      viewMode: "list",
      sortKey: "name",
      sortAsc: true,
      listHeight: 200,
      order: null,
    };
    card.selectedFavorite = card.favorites[0].id;
    folderCards.push(card);
    return structuredClone(card);
  },
  async updateFolderCard(card) {
    folderCards = folderCards.map((c) => (c.id === card.id ? structuredClone(card) : c));
  },
  async deleteFolderCard(id) {
    folderCards = folderCards.filter((c) => c.id !== id);
  },
  async listDir(path, showHidden) {
    const list = fsTree.get(path);
    if (!list) throw new Error("notFound");
    return list.filter((e) => showHidden || !e.name.startsWith("."));
  },
  async fsMove(sources, destDir, copy) {
    const dest = fsTree.get(destDir);
    if (!dest) throw new Error("notFound");
    for (const src of sources) {
      const from = fsTree.get(parentOf(src));
      const e = from?.find((x) => x.path === src);
      if (!e || parentOf(src) === destDir) continue;
      if (dest.some((x) => x.name === e.name)) throw new Error(`exists:${e.name}`);
      if (!copy) from!.splice(from!.indexOf(e), 1);
      dest.push({ ...e, path: `${destDir}/${e.name}` });
      dirListeners.forEach((l) => (l(parentOf(src)), l(destDir)));
    }
  },
  async fsRename(path, newName) {
    const list = fsTree.get(parentOf(path));
    const e = list?.find((x) => x.path === path);
    if (!e) throw new Error("notFound");
    if (list!.some((x) => x.name === newName)) throw new Error(`exists:${newName}`);
    e.name = newName;
    e.path = `${parentOf(path)}/${newName}`;
  },
  async fsTrash(paths) {
    for (const p of paths) {
      const list = fsTree.get(parentOf(p));
      const i = list?.findIndex((x) => x.path === p) ?? -1;
      if (i >= 0) list!.splice(i, 1);
    }
  },
  async fsNewFolder(dir) {
    const list = fsTree.get(dir);
    if (!list) throw new Error("notFound");
    let name = "新建文件夹";
    for (let i = 2; list.some((x) => x.name === name); i++) name = `新建文件夹 ${i}`;
    list.push(ent(dir, name, true));
    fsTree.set(`${dir}/${name}`, []);
    return `${dir}/${name}`;
  },
  async openPath(path) {
    console.info("[mock] open", path);
  },
  async revealPath(path) {
    console.info("[mock] reveal", path);
  },
  async revealNote(path) {
    console.info("[mock] reveal note", path);
  },
  async startFileDrag(paths) {
    console.info("[mock] drag", paths);
  },
  async pickDirectory() {
    return ROOT;
  },
  async setSettings(s) {
    settings = { ...s };
  },
  async setPanelPinned(p) {
    panelPinned = p;
  },
  async setPanelBusy() {},
  async hidePanel() {
    console.info("[mock] hide panel");
  },
  async quit() {},
  onVaultChanged: (cb) => void vaultListeners.push(cb),
  onDirChanged: (cb) => void dirListeners.push(cb),
  onPanelShown() {},
  onPanelHidden() {},
  onFileDrop() {},
};

/** Test hook: simulate an external edit. */
export function mockExternalWrite(path: string, content: string) {
  const f = files.get(path);
  const t = Date.now() + 1;
  if (f) Object.assign(f, { content, modified: t });
  else files.set(path, { content, created: t, modified: t, pinned: false, order: null });
  changed();
}
