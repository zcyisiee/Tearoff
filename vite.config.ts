import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**", "**/legacy/**"] } },
  build: { target: "es2022", outDir: "dist" },
  test: { environment: "jsdom", include: ["src/**/*.test.ts"] },
});
