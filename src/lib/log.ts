import * as plugin from "@tauri-apps/plugin-log";

const native = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

function send(level: "debug" | "info" | "warn" | "error", message: string) {
  if (native) void plugin[level](`[ui] ${message}`).catch(() => {});
  else console[level](message);
}

/** UI-side logging. In the app it lands in the same file as the Rust log. */
export const log = {
  debug: (m: string) => send("debug", m),
  info: (m: string) => send("info", m),
  warn: (m: string) => send("warn", m),
  error: (m: string) => send("error", m),
};

/** Uncaught errors and long main-thread stalls are the two things a user reports as "it froze". */
export function installDiagnostics() {
  window.addEventListener("error", (e) => log.error(`uncaught ${e.message} @ ${e.filename}:${e.lineno}`));
  window.addEventListener("unhandledrejection", (e) => log.error(`unhandled rejection ${String(e.reason)}`));
  let last = performance.now();
  setInterval(() => {
    const now = performance.now();
    if (!document.hidden && now - last > 1500) log.warn(`ui thread stalled ${Math.round(now - last - 500)}ms`);
    last = now;
  }, 500);
}
