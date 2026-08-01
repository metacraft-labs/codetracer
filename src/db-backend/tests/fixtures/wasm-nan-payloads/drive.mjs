// NaN-payload demo (M52) — headless driver.
//
// Loads the page once in headless Chromium and waits for its own
// completion signal. That signal matters: the recording is finalised by
// the page calling `recorder.stop()`, so closing the browser early would
// truncate it into something that looks valid and is missing the very
// records this fixture exists to demonstrate.
//
//     node drive.mjs <preview-port> <record-web-port>
//
// Environment:
//   DEMO_HEADFUL=1   show the browser window

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CODETRACER_ROOT = path.resolve(HERE, "../../../../..");

// Playwright is resolved from the codetracer checkout's own
// `node_modules` — the same install the GUI suite uses — so this fixture
// needs no `npm install` of its own.
const require = createRequire(path.join(CODETRACER_ROOT, "package.json"));
const { chromium } = require("playwright");

const PREVIEW_PORT = Number(process.argv[2] || 4182);
const RECORD_WEB_PORT = Number(process.argv[3] || 9230);
const BASE_URL = `http://127.0.0.1:${PREVIEW_PORT}/?ws=${RECORD_WEB_PORT}`;

/**
 * Resolve the Chromium executable.
 *
 * Mirrors `codetracer/src/tests/gui/playwright.config.ts`. The scan
 * matters on Nix: Playwright hard-codes a browser revision that
 * routinely differs from the one the dev shell provides, so relying on
 * its built-in discovery fails with a "download new browsers" message
 * even though a perfectly good Chromium is present.
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
  const systemChromium = "/run/current-system/sw/bin/chromium";
  if (fs.existsSync(systemChromium)) return systemChromium;
  return undefined;
}

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

let exitCode = 0;
const browser = await chromium.launch({
  headless: process.env.DEMO_HEADFUL !== "1",
  executablePath: resolveChromiumExecutable(),
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
try {
  if (!(await waitForServer(`http://127.0.0.1:${PREVIEW_PORT}/`))) {
    throw new Error(`the static server never answered on ${PREVIEW_PORT}`);
  }
  const page = await browser.newPage();
  // A silent page-side failure would otherwise surface much later as a
  // mysteriously empty recording.
  page.on("console", (msg) => {
    if (msg.type() === "error") console.error(`[page] ${msg.text()}`);
  });
  page.on("pageerror", (err) => {
    console.error(`[page] uncaught: ${err.message}`);
    if (err.stack) console.error(err.stack);
  });
  page.on("response", (res) => {
    if (res.status() >= 400) console.error(`[page] ${res.status()} ${res.url()}`);
  });
  page.on("requestfailed", (req) => {
    console.error(
      `[page] request failed: ${req.url()} (${req.failure()?.errorText})`,
    );
  });

  await page.goto(BASE_URL, { waitUntil: "load" });
  await page.waitForFunction(
    () => (document.querySelector("#status")?.textContent ?? "") !== "running",
    undefined,
    { timeout: 60_000 },
  );
  const status = await page.evaluate(
    () => document.querySelector("#status")?.textContent ?? "",
  );
  if (!status.startsWith("probed ")) {
    throw new Error(`the page did not complete its probes: ${status}`);
  }
  console.log(`[drive] page reported: ${status}`);
  // The bit patterns the page asked the module for, in the recording's
  // own spelling, written beside the recording it belongs to.
  //
  // Deliberately NOT into `HERE`. `expected-bits.json` beside these
  // sources is the committed, hand-reviewed oracle: those four patterns
  // are the whole point of M52, and they must be a statement a reviewer
  // made, not one the run made about itself. A driver that overwrote it
  // would silently adopt whatever the producer had regressed to.
  const expected = await page.evaluate(() => globalThis.__demoExpected);
  const outDir = process.env.CT_RECORDING_OUT_DIR || HERE;
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, "observed-bits.json"),
    `${JSON.stringify(expected, null, 2)}\n`,
  );
  // Give the WebSocket frames a moment to reach the daemon before the
  // browser goes away.
  await page.waitForTimeout(500);
} catch (err) {
  console.error(`[drive] ${err.message}`);
  exitCode = 1;
} finally {
  await browser.close();
}

process.exit(exitCode);
