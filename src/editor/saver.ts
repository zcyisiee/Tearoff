import { api } from "../lib/api";
import { useStore } from "../lib/store";

/**
 * Debounced writer for one open note. It is the only code path that writes
 * note bodies, and it only ever runs after a real edit — opening a note never
 * rewrites its file.
 */
export class NoteSaver {
  private timer: ReturnType<typeof setTimeout> | undefined;
  private pending: string | null = null;
  private chain: Promise<void> = Promise.resolve();
  /** Content and mtime of the file as we last read or wrote it. */
  savedContent: string;
  baseModified: number | null;

  constructor(
    public path: string,
    content: string,
    modified: number,
  ) {
    this.savedContent = content;
    this.baseModified = modified === 0 ? null : modified;
    savers.add(this);
  }

  get dirty(): boolean {
    return this.pending !== null;
  }

  schedule(content: string) {
    if (content === this.savedContent && this.pending === null) return;
    this.pending = content;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.flush(), 450);
  }

  flush(): Promise<void> {
    clearTimeout(this.timer);
    this.chain = this.chain.then(() => this.write());
    return this.chain;
  }

  private async write() {
    const content = this.pending;
    if (content === null) return;
    this.pending = null;
    if (content === this.savedContent) return;
    // Never create a file just to hold nothing.
    if (this.baseModified === null && content.trim() === "") return;
    const store = useStore.getState();
    try {
      const meta = await api.writeNote(this.path, content, this.baseModified);
      this.accept(content, meta.modified);
      store.upsertNote(meta);
    } catch (e) {
      if (!String(e).includes("conflict")) {
        this.pending ??= content;
        store.notify(`没有保存成功：${e}`);
        return;
      }
      await this.resolveConflict(content);
    }
  }

  /**
   * The file changed on disk under us. If the disk text is what we last saw,
   * only the timestamp moved and we can overwrite. Otherwise both versions
   * are real: ours goes to a sibling copy, the note keeps the disk version.
   */
  private async resolveConflict(content: string) {
    const store = useStore.getState();
    const disk = await api.readNote(this.path);
    if (disk.content === this.savedContent || disk.modified === 0) {
      const meta = await api.writeNote(this.path, content, null);
      this.accept(content, meta.modified);
      store.upsertNote(meta);
      return;
    }
    const stem = this.path.replace(/\.md$/, "");
    const copy = await api.writeNote(`${stem}（冲突副本 ${Date.now() % 100000}）.md`, content, null);
    store.upsertNote(copy);
    this.accept(disk.content, disk.modified);
    this.onExternalContent?.(disk.content);
    store.notify("这篇笔记在别处被改过，你刚才的内容已另存为冲突副本");
  }

  accept(content: string, modified: number) {
    this.savedContent = content;
    this.baseModified = modified === 0 ? null : modified;
  }

  /** Set by the editor: replace what is shown with fresh disk content. */
  onExternalContent?: (content: string) => void;

  retarget(path: string) {
    this.path = path;
  }

  dispose() {
    void this.flush();
    savers.delete(this);
  }
}

const savers = new Set<NoteSaver>();

export function flushAll(): Promise<void[]> {
  return Promise.all([...savers].map((s) => s.flush()));
}
