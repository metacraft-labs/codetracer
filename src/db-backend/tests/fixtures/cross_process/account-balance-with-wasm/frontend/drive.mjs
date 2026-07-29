// Cross-process origin demo — headless driver for the browser tier.
//
// Serves the built bundle with `vite preview` and loads it once in
// headless Chromium, waiting for the page's own completion signal before
// closing. That signal matters: the browser recordings are finalised by
// the page calling `stopRecording()`, so closing the browser early would
// truncate them mid-exchange and produce a trace that looks valid but is
// missing the boundary markers the whole demo depends on.
//
// Run indirectly by `regenerate.sh`; runnable on its own for debugging:
//
//     node ./drive.mjs
//
// Environment:
//   DEMO_PREVIEW_PORT   port for `vite preview` (default 4173)
//   DEMO_HEADFUL=1      show the browser window

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { chromium } from "playwright";

const PORT = Number(process.env.DEMO_PREVIEW_PORT || 4173);
const BASE_URL = `http://127.0.0.1:${PORT}`;
const HEADFUL = process.env.DEMO_HEADFUL === "1";

/**
 * Resolve the Chromium executable.
 *
 * Mirrors the lookup order in
 * `codetracer/src/tests/gui/playwright.config.ts`. The scan matters on
 * Nix: Playwright hard-codes a browser revision that routinely differs
 * from the one the dev shell provides, so relying on its built-in
 * discovery fails with a "download new browsers" message even though a
 * perfectly good Chromium is present.
 *
 * Priority: explicit override -> revision scan under
 * PLAYWRIGHT_BROWSERS_PATH -> system chromium -> Playwright's default.
 */
function resolveChromiumExecutable() {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  }
  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (browsersDir && fs.existsSync(browsersDir)) {
    const chromiumDir = fs
      .readdirSync(browsersDir)
      .filter((d) => d.startsWith("chromium-") && !d.includes("headless"))
      .sort()
      .pop();
    if (chromiumDir) {
      const base = path.join(browsersDir, chromiumDir);
      const sub = fs
        .readdirSync(base)
        .find((d) => d.startsWith("chrome-linux") || d.startsWith("chrome-win"));
      if (sub) {
        const exe = path.join(
          base,
          sub,
          process.platform === "win32" ? "chrome.exe" : "chrome",
        );
        if (fs.existsSync(exe)) return exe;
      }
    }
  }
  const nixChromium = "/run/current-system/sw/bin/chromium";
  if (fs.existsSync(nixChromium)) return nixChromium;
  return undefined;
}

/** Poll until the preview server answers, or give up. */
async function waitForServer(url, attempts = 100) {
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url);
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  return false;
}

const preview = spawn(
  "npx",
  ["vite", "preview", "--host", "127.0.0.1", "--port", String(PORT)],
  { stdio: "inherit" },
);

let exitCode = 0;
try {
  if (!(await waitForServer(BASE_URL))) {
    throw new Error(`vite preview never became ready on ${BASE_URL}`);
  }

  const browser = await chromium.launch({
    headless: !HEADFUL,
    executablePath: resolveChromiumExecutable(),
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  try {
    const page = await browser.newPage();
    // Surface page-side failures: a silent recorder error would
    // otherwise show up much later as a mysteriously empty trace.
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        console.error(`[page] ${msg.text()}`);
      }
    });
    page.on("pageerror", (err) => {
      console.error(`[page] uncaught: ${err.message}`);
      if (err.stack) console.error(err.stack);
    });
    // A missing asset is the most likely cause of a page that loads but
    // records nothing, so name the URL rather than leaving a bare 404 in
    // the log.
    page.on("response", (res) => {
      if (res.status() >= 400) {
        console.error(`[page] ${res.status()} ${res.url()}`);
      }
    });
    page.on("requestfailed", (req) => {
      console.error(
        `[page] request failed: ${req.url()} (${req.failure()?.errorText})`,
      );
    });

    await page.goto(BASE_URL, { waitUntil: "load" });
    await page.waitForFunction(
      () => document.querySelector("#status")?.textContent === "stored",
      undefined,
      { timeout: 60_000 },
    );
    // The page flushes both recordings in its `finally` block; give the
    // WebSocket frames a moment to reach the daemon before tearing the
    // browser down.
    await page.waitForTimeout(500);
    console.log("[drive] page reported: stored");
  } finally {
    await browser.close();
  }
} catch (err) {
  console.error(`[drive] ${err.message}`);
  exitCode = 1;
} finally {
  preview.kill("SIGINT");
}

process.exit(exitCode);
