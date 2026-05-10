import { existsSync } from "node:fs";
import { defineConfig } from "@playwright/test";

// Minimal Playwright config for the codetracer HMR fixture. Stays
// separate from the main `src/tests/gui/playwright.config.ts` because
// this fixture is a lightweight static-served page (no Electron, no
// trace recording) — the e2e harness's launch overhead would dominate.

const chromiumExecutable =
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
  (existsSync("/run/current-system/sw/bin/chromium")
    ? "/run/current-system/sw/bin/chromium"
    : undefined);

export default defineConfig({
  testDir: "./specs",
  timeout: 30_000,
  use: {
    baseURL: "http://localhost:9200",
    headless: true,
    browserName: "chromium",
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: {
    // Python's http.server ships with the nix dev shell and avoids
    // pulling in a Node static-file server just for this fixture.
    command: "python3 -m http.server 9200 --bind 127.0.0.1",
    port: 9200,
    reuseExistingServer: true,
    cwd: __dirname,
  },
});
