import { create } from "zustand";
import { api } from "./api";
import type { FolderCard, NoteMeta, Settings } from "./types";

export type View = "home" | "settings";

interface Store {
  loaded: boolean;
  notes: NoteMeta[];
  folderCards: FolderCard[];
  settings: Settings | null;
  today: string;
  panelPinned: boolean;

  view: View;
  /** Sheet currently morphed to fill the panel (note path), if any. */
  expanded: string | null;
  /** History row opened in place (note path), if any. */
  openRow: string | null;
  query: string;
  searching: boolean;
  toast: string | null;
  /** Bumped to ask the today sheet to take keyboard focus. */
  focusToday: number;

  refresh(): Promise<void>;
  upsertNote(meta: NoteMeta): void;
  setView(view: View): void;
  setExpanded(path: string | null): void;
  setOpenRow(path: string | null): void;
  setQuery(q: string): void;
  setSearching(on: boolean): void;
  notify(message: string): void;
  requestTodayFocus(): void;

  createNote(): Promise<void>;
  renameNote(path: string, title: string): Promise<string | null>;
  deleteNote(path: string): Promise<void>;
  setPinned(path: string, pinned: boolean): Promise<void>;
  moveCard(key: string, delta: -1 | 1): Promise<void>;
  addFolderCard(): Promise<void>;
  updateFolderCard(card: FolderCard): Promise<void>;
  removeFolderCard(id: string): Promise<void>;
  saveSettings(patch: Partial<Settings>): Promise<void>;
  togglePanelPinned(): Promise<void>;
}

export type Card = { key: string; order: number | null; created: number } & (
  | { kind: "note"; note: NoteMeta }
  | { kind: "folder"; card: FolderCard }
);

export const todayPath = (today: string) => `Daily/${today}.md`;

/** Pinned notes and folder cards, in their shared manual order. */
export function selectCards(s: Pick<Store, "notes" | "folderCards" | "today">): Card[] {
  const cards: Card[] = [
    ...s.notes
      .filter((n) => n.pinned && n.path !== todayPath(s.today))
      .map((note): Card => ({ kind: "note", key: `note:${note.path}`, order: note.order, created: note.created, note })),
    ...s.folderCards.map((card, i): Card => ({ kind: "folder", key: `folder:${card.id}`, order: card.order, created: i, card })),
  ];
  return cards.sort((a, b) => (a.order ?? 1e9) - (b.order ?? 1e9) || a.created - b.created);
}

/** Everything that is neither today's sheet nor pinned, newest first. */
export function selectHistory(s: Pick<Store, "notes" | "today">): NoteMeta[] {
  return s.notes
    .filter((n) => !n.pinned && n.path !== todayPath(s.today))
    .sort((a, b) => sortStamp(b) - sortStamp(a));
}

/** Daily sheets sort by the day they belong to, other notes by last edit. */
export function sortStamp(n: NoteMeta): number {
  if (n.dailyDate) {
    const [y, m, d] = n.dailyDate.split("-").map(Number);
    return new Date(y, m - 1, d, 23, 59, 59).getTime();
  }
  return n.modified;
}

let toastTimer: ReturnType<typeof setTimeout> | undefined;

export const useStore = create<Store>((set, get) => ({
  loaded: false,
  notes: [],
  folderCards: [],
  settings: null,
  today: "",
  panelPinned: false,
  view: "home",
  expanded: null,
  openRow: null,
  query: "",
  searching: false,
  toast: null,
  focusToday: 0,

  async refresh() {
    const s = await api.getState();
    set({
      loaded: true,
      notes: s.notes,
      folderCards: s.folderCards,
      settings: s.settings,
      today: s.today,
      panelPinned: s.panelPinned,
    });
  },
  upsertNote(meta) {
    set((s) => {
      const i = s.notes.findIndex((n) => n.path === meta.path);
      const notes = i >= 0 ? s.notes.map((n, j) => (j === i ? meta : n)) : [...s.notes, meta];
      return { notes };
    });
  },
  setView: (view) => set({ view }),
  setExpanded: (expanded) => set({ expanded }),
  setOpenRow: (openRow) => set({ openRow }),
  setQuery: (query) => set({ query }),
  setSearching: (searching) => set(searching ? { searching } : { searching, query: "" }),
  notify(message) {
    clearTimeout(toastTimer);
    set({ toast: message });
    toastTimer = setTimeout(() => set({ toast: null }), 3200);
  },
  requestTodayFocus: () => set((s) => ({ focusToday: s.focusToday + 1 })),

  async createNote() {
    const meta = await api.createNote(null);
    get().upsertNote(meta);
    set({ openRow: meta.path, searching: false, query: "", view: "home" });
  },
  async renameNote(path, title) {
    const clean = title.trim();
    if (!clean) return null;
    try {
      const meta = await api.renameNote(path, clean);
      set((s) => ({
        notes: s.notes.map((n) => (n.path === path ? meta : n)),
        openRow: s.openRow === path ? meta.path : s.openRow,
        expanded: s.expanded === path ? meta.path : s.expanded,
      }));
      return meta.path;
    } catch (e) {
      get().notify(String(e).includes("exists") ? `已经有一篇叫“${clean}”的笔记` : `重命名失败：${e}`);
      return null;
    }
  },
  async deleteNote(path) {
    await api.deleteNote(path);
    set((s) => ({
      notes: s.notes.filter((n) => n.path !== path),
      openRow: s.openRow === path ? null : s.openRow,
      expanded: s.expanded === path ? null : s.expanded,
    }));
    get().notify("已移到废纸篓");
  },
  async setPinned(path, pinned) {
    await api.setPinned(path, pinned);
    set((s) => ({
      notes: s.notes.map((n) => (n.path === path ? { ...n, pinned, order: pinned ? n.order : null } : n)),
      openRow: !pinned ? path : s.openRow === path ? null : s.openRow,
    }));
  },
  async moveCard(key, delta) {
    const keys = selectCards(get()).map((c) => c.key);
    const i = keys.indexOf(key);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= keys.length) return;
    [keys[i], keys[j]] = [keys[j], keys[i]];
    await api.reorderCards(keys);
    await get().refresh();
  },
  async addFolderCard() {
    const dir = await api.pickDirectory();
    if (!dir) return;
    await api.createFolderCard(dir);
    await get().refresh();
  },
  async updateFolderCard(card) {
    set((s) => ({ folderCards: s.folderCards.map((c) => (c.id === card.id ? card : c)) }));
    await api.updateFolderCard(card);
  },
  async removeFolderCard(id) {
    await api.deleteFolderCard(id);
    set((s) => ({ folderCards: s.folderCards.filter((c) => c.id !== id) }));
  },
  async saveSettings(patch) {
    const current = get().settings;
    if (!current) return;
    const next = { ...current, ...patch };
    set({ settings: next });
    try {
      await api.setSettings(next);
      if (patch.vaultPath !== undefined) await get().refresh();
    } catch (e) {
      set({ settings: current });
      get().notify(`设置没有保存：${e}`);
    }
  },
  async togglePanelPinned() {
    const next = !get().panelPinned;
    set({ panelPinned: next });
    await api.setPanelPinned(next);
  },
}));
