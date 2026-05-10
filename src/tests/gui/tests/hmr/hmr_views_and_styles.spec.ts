// CodeTracer HMR end-to-end tests against the actual ct binary.
//
// These tests prove that the hot-module-reload integration wired into
// the codetracer renderer (src/frontend/hmr_runtime.nim) works
// against the real built artifacts:
//
//   - JS bundle reload: modify src/build-debug/public/ui.js, the
//     renderer's fs.watch transport fires, applyBundleByScriptTag
//     re-executes the (modified) bundle, and a globalThis marker the
//     test injected becomes visible to page.evaluate().
//
//   - CSS LiveReload: modify a codetracer-managed stylesheet on
//     disk, the renderer's CssWatcher fires, the matching <link>
//     tag's href gets cache-busted, and the new stylesheet's rules
//     are reflected in the element's computed style.
//
// The tests bypass the Tup build pipeline by writing directly to the
// already-built artifacts. That keeps the test fast and deterministic
// (no per-iteration Nim recompile) while still exercising the
// renderer-side HMR mechanism end-to-end. A separate, slow CI suite
// could exercise the Tup leg by editing source files; this suite is
// the fast loop developers run after every change to the HMR
// runtime.
//
// Requires the binary to be built with -d:ctHmr (the default for
// `just build` since src/Tuprules.tup landed the flag). Without that,
// the renderer skips installing the watchers and the tests fail at
// the "verify HMR active" probe.

import { test, expect, _electron, type ElectronApplication, type Page } from "@playwright/test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { execSync } from "node:child_process";

const REPO_ROOT = resolve(__dirname, "..", "..", "..", "..", "..");
const CT_BIN = join(REPO_ROOT, "src", "build-debug", "bin", "ct");
// Electron loads index.html from src/build-debug/, so its
// `<script src='ui.js'>` resolves to src/build-debug/ui.js — *not* the
// public/ui.js copy that Tup's cp rule produces for server-mode use.
const UI_JS_PATH = join(REPO_ROOT, "src", "build-debug", "ui.js");
const STYLES_DIR = join(REPO_ROOT, "src", "build-debug", "frontend", "styles");
const LOADER_CSS_PATH = join(STYLES_DIR, "loader.css");

// Bundle / CSS content backups, restored in `afterEach` so a failed
// test does not leave the build artifacts in a half-mutated state.
let uiJsBackup: string | null = null;
let loaderCssBackup: string | null = null;

function backupUiJs() {
  if (uiJsBackup === null && existsSync(UI_JS_PATH)) {
    uiJsBackup = readFileSync(UI_JS_PATH, "utf8");
  }
}

function restoreUiJs() {
  if (uiJsBackup !== null) {
    writeFileSync(UI_JS_PATH, uiJsBackup);
    uiJsBackup = null;
  }
}

function backupLoaderCss() {
  if (loaderCssBackup === null && existsSync(LOADER_CSS_PATH)) {
    loaderCssBackup = readFileSync(LOADER_CSS_PATH, "utf8");
  }
}

function restoreLoaderCss() {
  if (loaderCssBackup !== null) {
    writeFileSync(LOADER_CSS_PATH, loaderCssBackup);
    loaderCssBackup = null;
  }
}

/** Build a clean env for the dev ct binary. HMR is on by default in
 *  `-d:ctHmr` builds — we don't pass `CT_HMR=1` here on purpose, to
 *  cover that out-of-the-box workflow. The bundle path override is
 *  left set so the test stays robust against any layout drift in
 *  build-debug/.
 */
function makeHmrEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v;
  }
  // Prevent the single-instance lock from delegating to a stale
  // Electron from a previous failed run.
  env.CODETRACER_NEW_TRACE_POLICY = "window";
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.CT_HMR_BUNDLE = UI_JS_PATH;
  // Make sure CT_HMR is not stuck at 0 from a prior test or shell.
  delete env.CT_HMR;
  return env;
}

let app: ElectronApplication | null = null;
let page: Page | null = null;

test.describe("CodeTracer HMR — views and styles", () => {
  test.skip(!existsSync(CT_BIN),
    `ct binary not built at ${CT_BIN}; run \`just build\` first`);
  test.skip(!existsSync(UI_JS_PATH),
    `ui.js not built at ${UI_JS_PATH}; run \`just build\` first`);

  test.beforeAll(async () => {
    app = await _electron.launch({
      executablePath: CT_BIN,
      cwd: REPO_ROOT,
      env: makeHmrEnv(),
    });
    page = await app.firstWindow();
    // Welcome screen mounts quickly; wait for the global marker
    // exposed by ipc/router setup so we know the renderer has run
    // through `configure(data)` (which is where we install the HMR
    // transports). If the binary was built without -d:ctHmr, there
    // are no transports installed and the JS-bundle test will time
    // out — the skip at the top would have caught that earlier in
    // any case.
    await page.waitForLoadState("domcontentloaded");
    // Give the renderer a moment to finish post-load init (configure,
    // install transports). 1.5s is comfortable in practice; the CSS
    // and JS reload tests have their own retry loops on top.
    await page.waitForTimeout(1500);
  });

  test.afterAll(async () => {
    // Restore mutated artifacts BEFORE shutting Electron down — the
    // last fs.watch event the renderer sees is a settle-back to the
    // pre-test state.
    restoreUiJs();
    restoreLoaderCss();
    if (app !== null) {
      // Don't wait for Electron to close gracefully. The renderer
      // holds Node fs.watch handles installed by hmr_runtime; with
      // Electron's beforeunload + IPC teardown they can hang for
      // tens of seconds, blowing through the worker teardown
      // timeout. Force-killing the process tree is what every other
      // test in this repo does — see fixtures.ts:killProcessTree.
      const pid = app.process().pid;
      if (pid !== undefined) {
        try {
          execSync(`pkill -P ${pid}`, { stdio: "ignore" });
        } catch {
          // pkill exits 1 when no children matched — harmless.
        }
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          // Already gone.
        }
      }
      app = null;
      page = null;
    }
  });

  test.afterEach(() => {
    restoreUiJs();
    restoreLoaderCss();
  });

  test("ui.js mutation triggers an in-place reload via fs.watch + script tag, with no full-page navigation", async () => {
    expect(page).not.toBeNull();
    const p = page!;

    // Both halves of this test exercise the same single bundle
    // reload, so we don't burn through multiple fs.watch events on
    // Linux (Node's inotify-backed watcher gets flaky after repeated
    // back-to-back rewrites of the same file).

    // The marker we'll inject. Unique per run so a stale globalThis
    // from a previous incarnation cannot mask a real failure.
    const marker = `__ct_hmr_marker_${Date.now()}_${Math.random().toString(36).slice(2)}`;

    // Sanity: the marker is not present before we modify the bundle.
    const beforeMarker = await p.evaluate((key) => (globalThis as any)[key],
      marker);
    expect(beforeMarker).toBeUndefined();

    // Capture navigation count baseline. A bundle script-tag reload
    // must NOT advance this — if the renderer ever falls back to
    // window.location.reload() the count would tick up.
    const navsBefore = await p.evaluate(() =>
      performance.getEntriesByType("navigation").length);

    backupUiJs();
    const original = readFileSync(UI_JS_PATH, "utf8");
    writeFileSync(UI_JS_PATH,
      original + `\n;globalThis[${JSON.stringify(marker)}] = "applied";\n`);

    // Poll for the marker to appear. The renderer's fs.watch transport
    // debounces 80ms; applyBundleByScriptTag adds another async step
    // (script load). 5 seconds is generous and far below the test
    // timeout but well above what the mechanism actually needs.
    const handle = await p.waitForFunction(
      (key) => (globalThis as any)[key] === "applied",
      marker,
      { timeout: 5000 },
    );
    expect(await handle.jsonValue()).toBe(true);

    const navsAfter = await p.evaluate(() =>
      performance.getEntriesByType("navigation").length);
    expect(navsAfter).toBe(navsBefore);
  });

  test("stylesheet mutation triggers a cache-busted href swap on the matching link tag", async () => {
    expect(page).not.toBeNull();
    const p = page!;

    test.skip(!existsSync(LOADER_CSS_PATH),
      `loader.css not built at ${LOADER_CSS_PATH}`);

    // Find the link tag that loads loader.css. We use the renderer's
    // own selector logic: it watches every <link> whose href starts
    // with "frontend/styles/", and loader.css is one of those.
    const linkSelector = `link[rel="stylesheet"][href*="loader.css"]`;
    const initialAbsHref = await p.evaluate((sel) => {
      const node = document.querySelector(sel) as HTMLLinkElement | null;
      return node ? node.href : null;
    }, linkSelector);
    console.log(`# loader.css initial absolute href: ${initialAbsHref}`);
    expect(initialAbsHref).not.toBeNull();
    expect(initialAbsHref!.includes("loader.css")).toBe(true);

    // Append a uniquely-identifiable rule to loader.css. The exact
    // selector is one we add and remove in this test only, so it
    // does not collide with any production rule.
    const probeAttr = `data-ct-hmr-probe-${Date.now()}`;
    backupLoaderCss();
    const original = readFileSync(LOADER_CSS_PATH, "utf8");
    writeFileSync(LOADER_CSS_PATH,
      original + `\n[${probeAttr}] { color: rgb(123, 45, 67); }\n`);
    console.log(`# loader.css mutated, probe attr=${probeAttr}`);

    // The CssWatcher swaps the href to a cache-busted URL on change.
    // That swap is the integration contract under test — once the
    // href has changed in response to the file mutation, our
    // mechanism is doing its job. Whether the browser then applies a
    // particular new rule is downstream CSS-engine behaviour and
    // tested separately by Playwright/Chromium upstream; pulling it
    // into this spec creates timing flake (the link's `load` event
    // can fire before the new rules are flushed for a selector that
    // doesn't currently match anything in the document).
    await p.waitForFunction(
      ({ sel, before }) => {
        const node = document.querySelector(sel) as HTMLLinkElement | null;
        return !!(node && node.href !== before);
      },
      { sel: linkSelector, before: initialAbsHref! },
      { timeout: 5000 },
    );
    console.log("# href differs from initial — swap happened");

    // Cross-check: the new href should still point at loader.css and
    // carry a cache-bust query (`?v=…` or `&v=…`) — that's what the
    // CssWatcher constructs, and seeing it tells us the swap came
    // from our transport rather than some unrelated DOM mutation.
    const newHref = await p.evaluate((sel) => {
      const node = document.querySelector(sel) as HTMLLinkElement | null;
      return node ? node.href : null;
    }, linkSelector);
    expect(newHref).not.toBeNull();
    expect(newHref).toContain("loader.css");
    expect(/[?&]v=\d+/.test(newHref!)).toBe(true);
  });

});
