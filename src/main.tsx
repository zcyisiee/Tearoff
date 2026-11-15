import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "katex/dist/katex.min.css";
import "./styles/tokens.css";
import "./styles/app.css";
import "./styles/prose.css";
import { App } from "./App";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// Development only: `TEAROFF_SELFTEST=<file>` makes the real app exercise its own IPC surface.
if ("__TAURI_INTERNALS__" in window) {
  void import("./selftest").then((m) => m.runSelfTestIfRequested());
}
