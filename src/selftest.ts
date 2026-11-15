import { invoke } from "@tauri-apps/api/core";
import { api } from "./lib/api";
import { useStore } from "./lib/store";

/**
 * End-to-end smoke test that runs inside the real app (WebView → IPC → Rust →
 * disk → events → UI). It only touches the vault the app was started with, so
 * always run it against a throwaway vault:
 *
 *   TEAROFF_VAULT=/tmp/v TEAROFF_SELFTEST=/tmp/report.json pnpm app:dev
 */
export async function runSelfTestIfRequested() {
  if (!(await invoke<boolean>("selftest_report", { report: null }))) return;
  const results: { name: string; ok: boolean; detail?: string }[] = [];
  window.addEventListener("error", (e) => results.push({ name: "uncaught error", ok: false, detail: e.message }));
  window.addEventListener("unhandledrejection", (e) => results.push({ name: "unhandled rejection", ok: false, detail: String(e.reason) }));
  const check = async (name: string, fn: () => Promise<unknown>) => {
    try {
      const detail = await fn();
      results.push({ name, ok: true, detail: detail === undefined ? undefined : String(detail) });
    } catch (e) {
      results.push({ name, ok: false, detail: String(e) });
    }
  };
  const expect = (cond: unknown, msg: string) => {
    if (!cond) throw new Error(msg);
  };
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const until = async (cond: () => boolean, ms = 4000) => {
    const t0 = Date.now();
    while (!cond()) {
      if (Date.now() - t0 > ms) throw new Error("timed out");
      await wait(50);
    }
  };

  let vaultEvents = 0;
  api.onVaultChanged(() => vaultEvents++);
  await wait(800);
  const state = await api.getState();
  const stamp = Date.now() % 100000;

  await check("getState", async () => {
    expect(/^\d{4}-\d{2}-\d{2}$/.test(state.today), "today");
    expect(state.settings.vaultPath, "vaultPath");
    return `${state.notes.length} notes, vault ${state.settings.vaultPath}`;
  });

  await check("panel layout", async () => {
    const panel = document.querySelector(".panel")!;
    if (state.panelShown) await until(() => Math.abs(panel.getBoundingClientRect().x) < 1, 2000).catch(() => {});
    const r = panel.getBoundingClientRect();
    const bg = getComputedStyle(panel).backgroundColor;
    expect(!state.panelShown || (panel.classList.contains("is-shown") && Math.abs(r.x) < 1), `panel is on screen but the UI is slid away (x=${r.x})`);
    return `${panel.className} | viewport ${innerWidth}x${innerHeight} | panel ${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)} | ${bg} | dpr ${devicePixelRatio}`;
  });

  let path = "";
  await check("createNote/writeNote/readNote", async () => {
    const meta = await api.createNote(`自检 ${stamp}`);
    path = meta.path;
    const written = await api.writeNote(path, "- [ ] 一\n\n**二** $x_1$\n", meta.modified);
    const doc = await api.readNote(path);
    expect(doc.content === "- [ ] 一\n\n**二** $x_1$\n", "content mismatch");
    expect(doc.modified === written.modified, "mtime mismatch");
    expect(written.preview === "一 二 $x1$", `preview: ${written.preview}`);
  });
  await check("writeNote conflict token", async () => {
    try {
      await api.writeNote(path, "x", 12345);
    } catch (e) {
      expect(String(e).includes("conflict"), String(e));
      return;
    }
    throw new Error("stale write was accepted");
  });
  await check("watcher → vault-changed event", async () => {
    await until(() => vaultEvents > 0);
    return `${vaultEvents} event(s)`;
  });
  await check("renameNote/setPinned/reorderCards", async () => {
    const meta = await api.renameNote(path, `自检改名 ${stamp}`);
    path = meta.path;
    await api.setPinned(path, true);
    await api.reorderCards([`note:${path}`]);
    const s = await api.getState();
    const n = s.notes.find((x) => x.path === path);
    expect(n?.pinned && n.order === 0, JSON.stringify(n));
  });
  await check("search", async () => {
    const hits = await api.search(`自检改名 ${stamp}`);
    expect(hits.some((h) => h.path === path), "not found");
  });
  await check("saveImage/resolveAsset", async () => {
    const src = await api.saveImage(path, "pasted.png", "iVBORw0KGgo=");
    expect(src.startsWith("assets/"), src);
    return api.resolveAsset(path, src);
  });

  // The UI on top of the same bridge: today's sheet saves what is typed.
  await check("today sheet types → file on disk", async () => {
    await useStore.getState().refresh();
    await until(() => !!document.querySelector(".sheet--today .ProseMirror"));
    const pm = document.querySelector(".sheet--today .ProseMirror") as HTMLElement & { editor: import("@tiptap/core").Editor };
    const before = (await api.readNote(`Daily/${state.today}.md`)).content;
    pm.editor.chain().focus("end").insertContent(`<p>自检行 ${stamp}</p>`).run();
    pm.editor.chain().focus("end").toggleTaskList().run();
    await wait(1200);
    const after = (await api.readNote(`Daily/${state.today}.md`)).content;
    expect(after.includes(`- [ ] 自检行 ${stamp}`), `after: ${JSON.stringify(after)}`);
    expect(after.startsWith(before.trimEnd()), "existing text was altered");
    return JSON.stringify(after.slice(-40));
  });
  await check("pinned note renders as a card with the same editor", async () => {
    await useStore.getState().refresh();
    await until(() => !!document.querySelector(`.cards [data-note="${CSS.escape(path)}"] .ProseMirror`));
    const a = getComputedStyle(document.querySelector(".sheet--today .ProseMirror")!);
    const b = getComputedStyle(document.querySelector(".cards .ProseMirror")!);
    expect(a.fontSize === b.fontSize && a.fontFamily === b.fontFamily && a.lineHeight === b.lineHeight && a.color === b.color, "typography differs");
    expect(!!document.querySelector(".cards .katex"), "formula not rendered");
  });

  const filesDir = state.settings.vaultPath.replace(/[\\/][^\\/]+$/, "") + "/files";
  let cardId = "";
  await check("folder card: create/list/newFolder/rename/move", async () => {
    const card = await api.createFolderCard(filesDir);
    cardId = card.id;
    const list = await api.listDir(filesDir, false);
    expect(list.some((e) => e.name === "archives" && e.isDir), "archives missing");
    const made = await api.fsNewFolder(filesDir);
    await api.fsRename(made, `自检夹 ${stamp}`);
    const dest = `${filesDir}/自检夹 ${stamp}`;
    // The bug-report gesture, as an operation: a file from archives/ into another folder and back up.
    await api.fsMove([`${filesDir}/archives/alpha.txt`], dest, false);
    expect((await api.listDir(dest, false)).some((e) => e.name === "alpha.txt"), "move in failed");
    await api.fsMove([`${dest}/alpha.txt`], `${filesDir}/archives`, false);
    expect((await api.listDir(`${filesDir}/archives`, false)).some((e) => e.name === "alpha.txt"), "move back failed");
    try {
      await api.fsMove([`${filesDir}/archives/alpha.txt`], `${filesDir}/archives`, false);
      await api.fsRename(`${filesDir}/archives/alpha.txt`, "beta.txt");
      throw new Error("clash accepted");
    } catch (e) {
      expect(String(e).includes("exists:beta.txt"), String(e));
    }
    return `${list.length} entries`;
  });
  await check("folder card renders and updates", async () => {
    await useStore.getState().refresh();
    await until(() => document.querySelectorAll(".sheet--folder .file").length > 0);
    const card = useStore.getState().folderCards.find((c) => c.id === cardId)!;
    await api.updateFolderCard({ ...card, viewMode: "icon", currentPath: `${filesDir}/archives` });
    const s = await api.getState();
    expect(s.folderCards.find((c) => c.id === cardId)?.viewMode === "icon", "not updated");
    await api.deleteFolderCard(cardId);
  });
  await check("settings round trip + busy flag", async () => {
    await api.setSettings({ ...state.settings, fontSize: 16 });
    expect((await api.getState()).settings.fontSize === 16, "not saved");
    await api.setSettings(state.settings);
    await api.setPanelBusy(true);
    await api.setPanelBusy(false);
    await api.setPanelPinned(false);
  });

  const failed = results.filter((r) => !r.ok).length;
  await invoke("selftest_report", { report: JSON.stringify({ failed, passed: results.length - failed, results }, null, 2) });
}
