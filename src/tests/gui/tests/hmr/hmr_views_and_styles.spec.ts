// CodeTracer HMR end-to-end tests against the actual ct binary and
// the actual build pipeline.
//
// These tests prove the developer-facing workflow:
//
//   1. Run `just build` (produces the dev binary with -d:ctHmr and
//      starts `tup monitor -a` in the background).
//   2. Launch `src/build-debug/bin/ct` (HMR active by default).
//   3. Edit a `.nim` panel source or a `.styl` theme file.
//   4. The running ct window updates without a navigation.
//
// Each test backs the source file up at start, mutates it, runs
// `tup upd` (which rebuilds the affected output — Stylus → .css for
// `.styl` edits, nim js → ui.js for `.nim` edits), and waits for the
// renderer's fs.watch transport to react. On test exit the source
// file is restored and Tup is re-run so the build artifacts settle
// back to their pristine state.
//
// Robustness: each test's `captureSource` step also runs
// `git checkout HEAD -- <path>` to wash out any leftover mutations
// from a previous crashed run. Tests are slow — Nim's JS backend
// recompiles the whole renderer per source change (~15-20s) — and
// the suite is intended for CI / pre-commit, not the developer's
// inner loop.
//
// Requires the binary to be built with -d:ctHmr (the default for
// `just build` since src/Tuprules.tup landed the flag).

import { test, expect, _electron, type ElectronApplication, type Page } from "@playwright/test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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

// Source paths the tests mutate. Both live under src/frontend/ and
// are part of the dependency graph Tup builds.
const HMR_RUNTIME_NIM = join(
  REPO_ROOT, "src", "frontend", "hmr_runtime.nim",
);
const LOADER_STYL = join(
  REPO_ROOT, "src", "frontend", "styles", "loader.styl",
);
// Tup wants to run from the src/ directory (where the .tup state
// lives).
const TUP_CWD = join(REPO_ROOT, "src");

function tupUpd() {
  // `tup upd` is the supported entry point and is idempotent — if
  // tup monitor -a is already running in the background (started by
  // `just build`) the explicit call is at worst redundant. Capture
  // stderr so a failed rebuild (Nim type error, Stylus parse error)
  // surfaces in the test log rather than vanishing.
  try {
    execSync("tup upd", {
      cwd: TUP_CWD,
      stdio: ["ignore", "ignore", "pipe"],
    });
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string };
    console.log(`# tup upd FAILED:\nstdout=${err.stdout ?? ""}\nstderr=${err.stderr ?? ""}`);
    throw e;
  }
}

function captureSource(path: string): string {
  // Wash out any leftover mutations from a previous crashed run.
  // `git checkout` no-ops cleanly when the file already matches
  // HEAD; if it fails for some other reason we still read whatever
  // is on disk and proceed, falling back to a finally-block restore
  // at test end.
  try {
    execSync(`git checkout HEAD -- ${JSON.stringify(path)}`, {
      cwd: REPO_ROOT, stdio: "ignore",
    });
  } catch {
    // Either the file is untracked or git is unavailable — both
    // pathological in this repo. Proceed with on-disk content.
  }
  return readFileSync(path, "utf8");
}

function makeHmrEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v;
  }
  env.CODETRACER_NEW_TRACE_POLICY = "window";
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.CT_HMR_BUNDLE = UI_JS_PATH;
  // HMR is on by default for -d:ctHmr builds; make sure CT_HMR is
  // not stuck at 0 from the inherited shell.
  delete env.CT_HMR;
  return env;
}

let app: ElectronApplication | null = null;
let page: Page | null = null;

test.describe("CodeTracer HMR — full build pipeline", () => {
  // Each Nim edit triggers a ~15-20s `nim js` recompile, plus a
  // restore step that re-compiles. Stylus edits are much faster
  // (~1s). The Playwright per-test default of 90s isn't enough for
  // the Nim test on a cold cache.
  test.setTimeout(180_000);

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
    await page.waitForLoadState("domcontentloaded");
    // Let the renderer finish post-load init — `configure()` is
    // where the HMR transports get installed.
    await page.waitForTimeout(1500);
  });

  test.afterAll(async () => {
    // Tear Electron down before any final restoration so the
    // renderer doesn't pick up a flurry of fs.watch events on the
    // way out.
    if (app !== null) {
      const pid = app.process().pid;
      if (pid !== undefined) {
        try { execSync(`pkill -P ${pid}`, { stdio: "ignore" }); }
        catch { /* pkill exits 1 when no children matched */ }
        try { process.kill(pid, "SIGKILL"); }
        catch { /* already gone */ }
      }
      app = null;
      page = null;
    }
  });

  test("editing a .styl source rebuilds the .css and the renderer swaps the <link> in place", async () => {
    expect(page).not.toBeNull();
    const p = page!;

    test.skip(!existsSync(LOADER_CSS_PATH),
      `loader.css not built at ${LOADER_CSS_PATH}`);

    const stylBackup = captureSource(LOADER_STYL);

    // Capture the initial absolute href so we can detect the
    // cache-bust swap.
    const linkSelector = `link[rel="stylesheet"][href*="loader.css"]`;
    const initialAbsHref = await p.evaluate((sel) => {
      const node = document.querySelector(sel) as HTMLLinkElement | null;
      return node ? node.href : null;
    }, linkSelector);
    expect(initialAbsHref).not.toBeNull();
    expect(initialAbsHref!.includes("loader.css")).toBe(true);

    // Stylus is a CSS superset for plain selectors; appending a
    // CSS-style rule produces a valid Stylus source and a
    // straightforward output. The unique probe attribute keeps the
    // rule from interfering with anything else.
    const probeAttr = `data-ct-hmr-stylus-probe-${Date.now()}`;
    const probeRule =
      `\n[${probeAttr}]\n  color: rgb(11, 22, 33)\n`;
    try {
      writeFileSync(LOADER_STYL, stylBackup + probeRule);
      tupUpd();

      // The renderer's CSS watcher sees loader.css change and
      // swaps the link's href. 10s is generous — the actual swap
      // happens within ~200ms of stylus emitting the file.
      await p.waitForFunction(
        ({ sel, before }) => {
          const node = document.querySelector(sel) as HTMLLinkElement | null;
          return !!(node && node.href !== before);
        },
        { sel: linkSelector, before: initialAbsHref! },
        { timeout: 10_000 },
      );

      // Cross-check: new href still points at loader.css and carries
      // the cache-bust marker our CssWatcher constructs.
      const newHref = await p.evaluate((sel) => {
        const node = document.querySelector(sel) as HTMLLinkElement | null;
        return node ? node.href : null;
      }, linkSelector);
      expect(newHref).not.toBeNull();
      expect(newHref).toContain("loader.css");
      expect(/[?&]v=\d+/.test(newHref!)).toBe(true);
    } finally {
      writeFileSync(LOADER_STYL, stylBackup);
      tupUpd();
    }
  });

  test("editing a .nim source rebuilds ui.js and the renderer reloads the bundle in place", async () => {
    expect(page).not.toBeNull();
    const p = page!;

    const nimBackup = captureSource(HMR_RUNTIME_NIM);

    // Unique marker so a stale globalThis from an earlier
    // incarnation cannot mask a real failure.
    const marker =
      `__ct_hmr_nim_marker_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const before = await p.evaluate((k) => (globalThis as any)[k], marker);
    expect(before).toBeUndefined();

    // A bundle script-tag reload must NOT advance the navigation
    // count — full-page reload via `window.location.reload()` would
    // tick it up.
    const navsBefore = await p.evaluate(() =>
      performance.getEntriesByType("navigation").length);

    // Append a top-level proc-with-emit + call. The proc-call pattern
    // is the most-robust way to make module-init JS run on every
    // bundle evaluation: Nim's JS backend always compiles the call
    // into the module's init code regardless of optimization mode.
    // (A bare `{.emit.}` at module scope can be elided by Nim's
    // dead-code analysis in some configurations.)
    // Inject a proc-with-emit + call at module level. The proc-call
    // pattern is the most-robust way to make module-init JS run on
    // every bundle evaluation regardless of optimisation mode (a
    // bare `{.emit.}` at module scope can be elided by dead-code
    // analysis in some configurations).
    const setExpr = `globalThis[${JSON.stringify(marker)}] = 'applied';`;
    const appended =
      `\nwhen defined(ctHmr):\n` +
      `  proc setCtHmrTestMarker() =\n` +
      `    {.emit: ${JSON.stringify(setExpr)}.}\n` +
      `  setCtHmrTestMarker()\n`;
    try {
      writeFileSync(HMR_RUNTIME_NIM, nimBackup + appended);
      tupUpd();

      // Nim's full re-compile + bundle load on the renderer side
      // can take ~20s on a cold cache. 60s is the safety net.
      const handle = await p.waitForFunction(
        (k) => (globalThis as any)[k] === "applied",
        marker,
        { timeout: 60_000 },
      );
      expect(await handle.jsonValue()).toBe(true);

      const navsAfter = await p.evaluate(() =>
        performance.getEntriesByType("navigation").length);
      expect(navsAfter).toBe(navsBefore);
    } finally {
      writeFileSync(HMR_RUNTIME_NIM, nimBackup);
      tupUpd();
    }
  });

  test("a single .nim edit triggers HMR in TWO concurrent ct instances watching the same bundle", async () => {
    // Each ct binary's renderer process installs its own
    // fs.watchFile handle on src/build-debug/ui.js. Two
    // independent ct windows are two independent watchers — a
    // single edit fans out to both, the bundle reload runs
    // independently in each, and the marker shows up in both
    // globalThis objects.
    //
    // The first instance is the one beforeAll launched (`app` /
    // `page` module-scope). We launch a second one here in the
    // test body so its lifetime is scoped to this test.
    expect(page).not.toBeNull();
    const p1 = page!;

    // Two Electron instances on the same host need isolated
    // userData dirs — otherwise the second one collides with the
    // first's SingletonLock at `~/.config/Electron/SingletonLock`
    // and Chromium exits before the renderer ever starts. The ct
    // wrapper intercepts `--user-data-dir` as a codetracer CLI
    // option (it isn't passed through to Electron), so the
    // standard knob doesn't work here. The fallback is to point
    // the second process at a fresh HOME: Electron's
    // `app.getPath('userData')` on Linux resolves through
    // XDG_CONFIG_HOME → $HOME/.config/<appName>, so a unique HOME
    // gives a unique userData.
    const fakeHome2 = mkdtempSync(join(tmpdir(), "ct-hmr-multi-"));
    let app2: ElectronApplication | null = null;
    const nimBackup = captureSource(HMR_RUNTIME_NIM);
    try {
      const env2 = makeHmrEnv();
      env2.HOME = fakeHome2;
      env2.XDG_CONFIG_HOME = join(fakeHome2, ".config");
      env2.XDG_DATA_HOME = join(fakeHome2, ".local", "share");
      env2.XDG_CACHE_HOME = join(fakeHome2, ".cache");
      app2 = await _electron.launch({
        executablePath: CT_BIN,
        cwd: REPO_ROOT,
        env: env2,
      });
      const p2 = await app2.firstWindow();
      await p2.waitForLoadState("domcontentloaded");
      await p2.waitForTimeout(1500);

      // Sanity: each renderer has its own globalThis. A marker
      // set in one shouldn't be present in the other before we
      // edit.
      const marker =
        `__ct_hmr_multi_marker_${Date.now()}_${Math.random().toString(36).slice(2)}`;
      expect(await p1.evaluate((k) => (globalThis as any)[k], marker))
        .toBeUndefined();
      expect(await p2.evaluate((k) => (globalThis as any)[k], marker))
        .toBeUndefined();

      const navsBefore1 = await p1.evaluate(() =>
        performance.getEntriesByType("navigation").length);
      const navsBefore2 = await p2.evaluate(() =>
        performance.getEntriesByType("navigation").length);

      const setExpr = `globalThis[${JSON.stringify(marker)}] = 'applied';`;
      const appended =
        `\nwhen defined(ctHmr):\n` +
        `  proc setCtHmrMultiMarker() =\n` +
        `    {.emit: ${JSON.stringify(setExpr)}.}\n` +
        `  setCtHmrMultiMarker()\n`;
      writeFileSync(HMR_RUNTIME_NIM, nimBackup + appended);
      tupUpd();

      // Both renderers should see the marker. Parallel waits —
      // a serial check works too but parallelising surfaces a
      // bug where the second renderer's watcher silently never
      // fires.
      await Promise.all([
        p1.waitForFunction(
          (k) => (globalThis as any)[k] === "applied",
          marker,
          { timeout: 60_000 },
        ),
        p2.waitForFunction(
          (k) => (globalThis as any)[k] === "applied",
          marker,
          { timeout: 60_000 },
        ),
      ]);

      // Neither renderer should have done a full-page reload.
      const navsAfter1 = await p1.evaluate(() =>
        performance.getEntriesByType("navigation").length);
      const navsAfter2 = await p2.evaluate(() =>
        performance.getEntriesByType("navigation").length);
      expect(navsAfter1).toBe(navsBefore1);
      expect(navsAfter2).toBe(navsBefore2);
    } finally {
      writeFileSync(HMR_RUNTIME_NIM, nimBackup);
      tupUpd();
      if (app2 !== null) {
        const pid = app2.process().pid;
        if (pid !== undefined) {
          try { execSync(`pkill -P ${pid}`, { stdio: "ignore" }); }
          catch { /* pkill exits 1 when no children matched */ }
          try { process.kill(pid, "SIGKILL"); }
          catch { /* already gone */ }
        }
      }
      try { rmSync(fakeHome2, { recursive: true, force: true }); }
      catch { /* best-effort cleanup */ }
    }
  });
});
