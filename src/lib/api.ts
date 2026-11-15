import type { Api } from "./types";
import { mockApi } from "./mockApi";
import { tauriApi } from "./tauriApi";

export const isTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

/** The single gateway to the backend. Components never call `invoke` directly. */
export const api: Api = isTauri ? tauriApi : mockApi;
