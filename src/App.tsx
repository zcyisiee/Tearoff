import { useEffect, useState } from "react";
import { api, isTauri } from "./lib/api";
import { useStore } from "./lib/store";
import { flushAll } from "./editor/saver";
import { installFileDrops } from "./lib/drops";
import { installDiagnostics, log } from "./lib/log";
import { Home } from "./components/Home";
import { SettingsView } from "./components/SettingsView";
import { TopBar } from "./components/TopBar";

export function App() {
  const loaded = useStore((s) => s.loaded);
  const view = useStore((s) => s.view);
  const settings = useStore((s) => s.settings);
  const toast = useStore((s) => s.toast);
  const [shown, setShown] = useState(!isTauri);

  useEffect(() => {
    const store = useStore.getState();
    installDiagnostics();
    log.info("ui started");
    void store.refresh();
    // The panel may already be on screen by the time this UI has loaded.
    void api.getState().then((s) => s.panelShown && setShown(true));
    api.onVaultChanged(() => void useStore.getState().refresh());
    api.onPanelShown((focus) => {
      setShown(true);
      log.debug(`panel shown focus=${focus}`);
      void useStore.getState().refresh();
      if (focus) useStore.getState().requestTodayFocus();
    });
    api.onPanelHidden(() => {
      setShown(false);
      void flushAll();
    });
    installFileDrops();
    window.addEventListener("beforeunload", () => void flushAll());

    const key = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      const s = useStore.getState();
      if (mod && e.key.toLowerCase() === "n") {
        e.preventDefault();
        void s.createNote();
      } else if (mod && e.key.toLowerCase() === "f") {
        e.preventDefault();
        s.setView("home");
        s.setSearching(true);
      } else if (mod && e.key.toLowerCase() === "d") {
        e.preventDefault();
        s.setView("home");
        s.setSearching(false);
        s.requestTodayFocus();
      } else if (mod && e.key === ",") {
        e.preventDefault();
        s.setView("settings");
      } else if (e.key === "Escape" && !e.defaultPrevented) {
        if (s.view === "settings") s.setView("home");
        else if (s.searching) s.setSearching(false);
        else void flushAll().then(() => api.hidePanel());
      }
    };
    window.addEventListener("keydown", key);
    // The day can change while the panel stays open.
    const tick = setInterval(() => void useStore.getState().refresh(), 60_000);
    return () => {
      window.removeEventListener("keydown", key);
      clearInterval(tick);
    };
  }, []);

  useEffect(() => {
    if (!settings) return;
    const root = document.documentElement;
    root.dataset.theme = settings.theme;
    root.dataset.side = settings.side;
    root.style.setProperty("--font-size", `${settings.fontSize}px`);
  }, [settings]);

  return (
    <div className={"panel" + (shown ? " is-shown" : "") + (isTauri ? " is-native" : "")}>
      <TopBar />
      <main className="panel__scroll">{loaded && (view === "settings" ? <SettingsView /> : <Home />)}</main>
      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </div>
  );
}
