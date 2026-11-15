/** Shared contract with the Rust backend — see docs/reference/contracts.md. */

export interface NoteMeta {
  /** Vault-relative path with "/" separators, e.g. "Daily/2026-11-15.md". Identity of a note. */
  path: string;
  title: string;
  /** Vault-relative folder, "" for the root. */
  folder: string;
  /** Milliseconds since epoch. */
  created: number;
  modified: number;
  pinned: boolean;
  order: number | null;
  /** First few hundred characters of body text, markdown syntax stripped. */
  preview: string;
  /** "YYYY-MM-DD" when the note is a daily sheet (Daily/**). */
  dailyDate: string | null;
}

export interface Favorite {
  id: string;
  path: string;
  name: string;
}

export interface FolderCard {
  id: string;
  title: string | null;
  favorites: Favorite[];
  selectedFavorite: string | null;
  /** Absolute directory currently browsed; null = the selected favourite's root. */
  currentPath: string | null;
  viewMode: "icon" | "list";
  sortKey: "name" | "kind" | "modified";
  sortAsc: boolean;
  listHeight: number;
  order: number | null;
}

export interface DirEntry {
  name: string;
  path: string;
  isDir: boolean;
  size: number;
  modified: number;
  ext: string;
}

export interface Settings {
  vaultPath: string;
  side: "left" | "right";
  panelWidth: number;
  edgeActivation: boolean;
  activationDelayMs: number;
  hideDelayMs: number;
  toggleShortcut: string;
  theme: "system" | "light" | "dark";
  fontSize: number;
  showHiddenFiles: boolean;
}

export interface AppState {
  notes: NoteMeta[];
  folderCards: FolderCard[];
  settings: Settings;
  /** Local date "YYYY-MM-DD" as the backend sees it. */
  today: string;
  panelPinned: boolean;
  /** Whether the panel is on screen right now (the UI may load after it was shown). */
  panelShown: boolean;
}

export interface NoteContent {
  content: string;
  /** mtime in ms; 0 when the file does not exist yet. */
  modified: number;
}

export interface SearchHit {
  path: string;
  title: string;
  snippet: string;
}

export interface Api {
  getState(): Promise<AppState>;
  readNote(path: string): Promise<NoteContent>;
  /** Fails with "conflict" when the file changed on disk since `baseModified`. */
  writeNote(path: string, content: string, baseModified: number | null): Promise<NoteMeta>;
  createNote(title: string | null): Promise<NoteMeta>;
  renameNote(path: string, title: string): Promise<NoteMeta>;
  deleteNote(path: string): Promise<void>;
  setPinned(path: string, pinned: boolean): Promise<void>;
  /** Keys: "note:<path>" | "folder:<id>", in display order. */
  reorderCards(keys: string[]): Promise<void>;
  search(query: string): Promise<SearchHit[]>;
  saveImage(notePath: string, name: string, dataBase64: string): Promise<string>;
  resolveAsset(notePath: string, src: string): string;

  createFolderCard(dir: string): Promise<FolderCard>;
  updateFolderCard(card: FolderCard): Promise<void>;
  deleteFolderCard(id: string): Promise<void>;
  listDir(path: string, showHidden: boolean): Promise<DirEntry[]>;
  fsMove(sources: string[], destDir: string, copy: boolean): Promise<void>;
  fsRename(path: string, newName: string): Promise<void>;
  fsTrash(paths: string[]): Promise<void>;
  fsNewFolder(dir: string): Promise<string>;
  openPath(path: string): Promise<void>;
  revealPath(path: string): Promise<void>;
  revealNote(path: string): Promise<void>;
  startFileDrag(paths: string[]): Promise<void>;
  pickDirectory(): Promise<string | null>;
  openLogs(): Promise<void>;

  setSettings(settings: Settings): Promise<void>;
  setPanelPinned(pinned: boolean): Promise<void>;
  /** While busy (menus, dialogs, drags) the panel never auto-hides. */
  setPanelBusy(busy: boolean): Promise<void>;
  hidePanel(): Promise<void>;
  quit(): Promise<void>;

  onVaultChanged(cb: () => void): void;
  onDirChanged(cb: (path: string) => void): void;
  onPanelShown(cb: (focus: boolean) => void): void;
  onPanelHidden(cb: () => void): void;
  onFileDrop(cb: (e: FileDropEvent) => void): void;
}

export type FileDropEvent =
  | { type: "over"; x: number; y: number }
  | { type: "drop"; x: number; y: number; paths: string[] }
  | { type: "leave" };
