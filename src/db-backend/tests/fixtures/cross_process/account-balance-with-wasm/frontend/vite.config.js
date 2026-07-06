// Cross-Tracer Origin E2E — Fixture A' Vite config (three-tracer
// variant per TCT-M4). The dev server proxies the backend's
// `/balance` POST so the front-end can `fetch("/balance", ...)`
// with no CORS shenanigans.
import { defineConfig } from "vite";

export default defineConfig({
  root: ".",
  server: {
    port: 5173,
    proxy: {
      // Forward the POST /balance request to the aiohttp backend
      // started by regenerate.sh on port 8080.
      "/balance": "http://127.0.0.1:8080",
    },
  },
  preview: {
    port: 4173,
    proxy: {
      "/balance": "http://127.0.0.1:8080",
    },
  },
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
  },
});
