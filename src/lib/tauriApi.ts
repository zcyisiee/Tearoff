import { invoke as rawInvoke, convertFileSrc } from "@tauri-apps/api/core";
import { log } from "./log";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { startDrag } from "@crabnebula/tauri-plugin-drag";
import type { Api, AppState, Settings } from "./types";

let vaultPath = "";

/** Every backend call is timed and logged; slow or failed ones stand out in the log file. */
const QUIET = new Set(["set_panel_busy", "get_state", "list_dir"]);
async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const t0 = performance.now();
  try {
    const out = await rawInvoke<T>(cmd, args);
    const ms = Math.round(performance.now() - t0);
    if (ms > 250) log.warn(`ipc ${cmd} slow ${ms}ms`);
    else if (!QUIET.has(cmd)) log.debug(`ipc ${cmd} ${ms}ms`);
    return out;
  } catch (e) {
    // "conflict" and "exists:…" are answers the UI handles, not faults.
    const refused = /^(conflict|exists:)/.test(String(e));
    log[refused ? "info" : "error"](`ipc ${cmd} ${refused ? "refused" : "failed"} after ${Math.round(performance.now() - t0)}ms: ${e}`);
    throw e;
  }
}

/** Drag preview: a paper chip with the file name (and a count for several). */
function dragIcon(paths: string[]): string {
  const name = paths[0].split(/[\\/]/).pop() ?? "";
  const label = paths.length > 1 ? `${name} 等 ${paths.length} 项` : name;
  const scale = window.devicePixelRatio || 1;
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d")!;
  const font = '13px -apple-system, "PingFang SC", "Segoe UI", sans-serif';
  ctx.font = font;
  const text = label.length > 28 ? label.slice(0, 27) + "…" : label;
  const w = Math.ceil(ctx.measureText(text).width) + 22;
  const h = 28;
  canvas.width = w * scale;
  canvas.height = h * scale;
  ctx.scale(scale, scale);
  ctx.fillStyle = "#fdfdfb";
  ctx.strokeStyle = "#1b7654";
  ctx.beginPath();
  ctx.roundRect(0.5, 0.5, w - 1, h - 1, 5);
  ctx.fill();
  ctx.stroke();
  ctx.font = font;
  ctx.fillStyle = "#1a211d";
  ctx.textBaseline = "middle";
  ctx.fillText(text, 11, h / 2 + 0.5);
  return canvas.toDataURL("image/png");
}

function joinVault(rel: string): string {
  const sep = vaultPath.includes("\\") ? "\\" : "/";
  return vaultPath.replace(/[\\/]+$/, "") + sep + rel.split("/").join(sep);
}

export const tauriApi: Api = {
  async getState() {
    const s = await invoke<AppState>("get_state");
    vaultPath = s.settings.vaultPath;
    return s;
  },
  readNote: (path) => invoke("read_note", { path }),
  writeNote: (path, content, baseModified) => invoke("write_note", { path, content, baseModified }),
  createNote: (title) => invoke("create_note", { title }),
  renameNote: (path, title) => invoke("rename_note", { path, title }),
  deleteNote: (path) => invoke("delete_note", { path }),
  setPinned: (path, pinned) => invoke("set_pinned", { path, pinned }),
  reorderCards: (keys) => invoke("reorder_cards", { keys }),
  search: (query) => invoke("search", { query }),
  saveImage: (notePath, name, dataBase64) => invoke("save_image", { notePath, name, dataBase64 }),
  resolveAsset(notePath, src) {
    if (/^(https?:|data:|blob:|asset:)/i.test(src)) return src;
    let decoded = src;
    try {
      decoded = decodeURI(src);
    } catch {
      /* keep raw */
    }
    if (/^(\/|[A-Za-z]:[\\/])/.test(decoded)) return convertFileSrc(decoded);
    const folder = notePath.includes("/") ? notePath.slice(0, notePath.lastIndexOf("/") + 1) : "";
    return convertFileSrc(joinVault(folder + decoded));
  },

  createFolderCard: (dir) => invoke("create_folder_card", { dir }),
  updateFolderCard: (card) => invoke("update_folder_card", { card }),
  deleteFolderCard: (id) => invoke("delete_folder_card", { id }),
  listDir: (path, showHidden) => invoke("list_dir", { path, showHidden }),
  fsMove: (sources, destDir, copy) => invoke("fs_move", { sources, destDir, copy }),
  fsRename: (path, newName) => invoke("fs_rename", { path, newName }),
  fsTrash: (paths) => invoke("fs_trash", { paths }),
  fsNewFolder: (dir) => invoke("fs_new_folder", { dir }),
  openPath: (path) => invoke("open_path", { path }),
  revealPath: (path) => invoke("reveal_path", { path }),
  revealNote: (path) => invoke("reveal_path", { path: joinVault(path) }),
  async startFileDrag(paths) {
    // The OS owns the mouse until the drop; the panel must stay put meanwhile.
    await invoke("set_panel_busy", { busy: true });
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      void invoke("set_panel_busy", { busy: false });
    };
    try {
      await startDrag({ item: paths, icon: dragIcon(paths), mode: "move" }, release);
    } catch (e) {
      release();
      throw e;
    }
    // Belt and braces: if the plugin never reports the end, do not stay busy forever.
    setTimeout(release, 60_000);
  },
  pickDirectory: () => invoke("pick_directory"),
  openLogs: () => invoke("open_logs"),

  async setSettings(settings: Settings) {
    await invoke("set_settings", { settings });
    vaultPath = settings.vaultPath;
  },
  setPanelPinned: (pinned) => invoke("set_panel_pinned", { pinned }),
  setPanelBusy: (busy) => invoke("set_panel_busy", { busy }),
  hidePanel: () => invoke("hide_panel"),
  quit: () => invoke("quit"),

  onVaultChanged: (cb) => void listen("vault-changed", () => cb()),
  onDirChanged: (cb) => void listen<string>("dir-changed", (e) => cb(e.payload)),
  onPanelShown: (cb) => void listen<boolean>("panel-shown", (e) => cb(e.payload)),
  onPanelHidden: (cb) => void listen("panel-hidden", () => cb()),
  onFileDrop(cb) {
    void getCurrentWebview().onDragDropEvent((e) => {
      const p = e.payload;
      const scale = window.devicePixelRatio || 1;
      if (p.type === "over") cb({ type: "over", x: p.position.x / scale, y: p.position.y / scale });
      else if (p.type === "drop") cb({ type: "drop", x: p.position.x / scale, y: p.position.y / scale, paths: p.paths });
      else if (p.type === "leave") cb({ type: "leave" });
    });
  },
};
