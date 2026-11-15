import { api } from "./api";
import { useStore } from "./store";
import { reloadDir } from "../components/FolderCardView";

const parentOf = (p: string) => p.replace(/[\\/][^\\/]+[\\/]?$/, "");

function targetAt(x: number, y: number): HTMLElement | null {
  return (document.elementFromPoint(x, y) as HTMLElement | null)?.closest<HTMLElement>("[data-drop-dir]") ?? null;
}

let hover: HTMLElement | null = null;
function setHover(el: HTMLElement | null) {
  if (hover === el) return;
  hover?.removeAttribute("data-drop-hover");
  hover = el;
  hover?.setAttribute("data-drop-hover", "");
}

/**
 * Every file drop — from another folder card or from outside the app —
 * arrives here as one event with a position. The element under the pointer
 * that carries `data-drop-dir` names the destination; there is no per-card
 * drag state that could be left behind when a drag ends unexpectedly.
 */
export function installFileDrops() {
  api.onFileDrop((e) => {
    if (e.type === "leave") return setHover(null);
    const target = targetAt(e.x, e.y);
    if (e.type === "over") return setHover(target);
    setHover(null);
    const dest = target?.dataset.dropDir;
    if (!dest) return;
    const sources = e.paths.filter((p) => parentOf(p) !== dest.replace(/[\\/]+$/, "") && p !== dest);
    if (!sources.length) return;
    api.fsMove(sources, dest, false).then(
      () => {
        reloadDir(dest);
        new Set(sources.map(parentOf)).forEach(reloadDir);
      },
      (err) => {
        const m = String(err);
        useStore.getState().notify(m.includes("exists:") ? `目标里已经有“${m.split("exists:")[1]}”，没有移动` : `没有移动成功：${m}`);
      },
    );
  });
  api.onDirChanged(reloadDir);
}
