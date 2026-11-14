/**
 * Custom Playwright fixtures for CodeTracer UI tests.
 *
 * Replaces the global mutable `page`/`window` from ct_helpers.ts with
 * fixture-scoped resources that are properly set up and torn down.
 *
 * Usage:
 *   import { test, expect } from "../lib/fixtures";
 *
 *   test.describe("MyTests", () => {
 *     test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });
 *
 *     test("my test", async ({ ctPage, layoutPage }) => { ... });
 *   });
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  test as base,
  expect,
  type Page,
  type ElectronApplication,
  type BrowserContext,
} from "@playwright/test";
import { _electron, chromium } from "playwright";
import { ctHostPageUrl, withCtHostSessionSecret } from "./ct-host-session";

import { getFreeTcpPort } from "./port-allocator";
import { captureFailureDiagnostics } from "./test-diagnostics";
import { formatErrorGroups } from "./error-grouping";
import { requiresRR } from "./lang-support";
import { ctUserConfigDir, ctUserDataDir } from "./ct-home";
import {
  ensureDefaultConfig,
  prepareUserLayout,
  resetAutoHideState,
  resetEditLayout,
  restoreUserLayout,
  seedEditLayout,
} from "./layout-reset";
import {
  LIMIT_CACHED_RECORDING_MS,
  LIMIT_SMALL_RECORDING_MS,
  LIMIT_RR_RECORDING_MS,
  LIMIT_ELECTRON_LAUNCH_MS,
  LIMIT_FIRST_WINDOW_MS,
  LIMIT_TOTAL_SETUP_MS,
  LIMIT_CT_HOST_STARTUP_MS,
  timed,
} from "./performance-limits";
import { deploymentModeFromEnv, type DeploymentMode } from "./deployment-mode";
import { ensureCtMcr, recordingNeedsCtMcr } from "./sibling-provisioning";
import { assertHomeFitsSocketBound, scratchBase } from "./socket-path-bound";

/**
 * The extra time a test gets when it has to build `ct-mcr` itself. A cold build
 * compiles the recorder's Rust and Nim dependencies, which can outlast the test's
 * own budget, so it is charged to the test once, here, and not to a later spec.
 */
const CT_MCR_BUILD_BUDGET_MS = 60 * 60_000;

/**
 * Provision the sibling recorder a recording needs, before the timed record step.
 *
 * `ct record` of a compiled `.nim` runs `ct-mcr` from the codetracer-native-recorder
 * sibling. The dev shell does not build it, so on a fresh checkout `ct record` fails
 * with "ct-mcr was not found". This runs the same provisioning as the Rust harnesses
 * (`lib/sibling-provisioning.ts`), and it runs outside `timed()`: a cold build is not
 * a recording, and its duration must not be graded against the recording's limit.
 */
async function provisionRecorderForRecording(sourcePath: string, backend?: string): Promise<void> {
  // A recording already made in this worker is reused without `ct record`, so it
  // needs no recorder. The key is the one `recordTestProgram` caches under.
  const cached = recordingCache.has(JSON.stringify([sourcePath, backend ?? null]));
  if (cached || !recordingNeedsCtMcr(sourcePath, backend)) {
    return;
  }
  await ensureCtMcr(codetracerInstallDir, () => {
    const info = base.info();
    info.setTimeout(info.timeout + CT_MCR_BUILD_BUDGET_MS);
  });
}

// ---------------------------------------------------------------------------
// Platform detection
// ---------------------------------------------------------------------------

const isWindows = process.platform === "win32";

// ---------------------------------------------------------------------------
// Path constants (shared with ct_helpers.ts)
// ---------------------------------------------------------------------------

const currentDir = path.resolve();
// The test package lives at src/tests/gui/ — go up 3 levels to reach
// the repo root (codetracer/).  Previously it was at tsc-ui-tests/
// (1 level up).
const codetracerInstallDir = path.resolve(currentDir, "..", "..", "..");
const testProgramsPath = path.join(codetracerInstallDir, "test-programs");
// The active build output directory: honour CODETRACER_BUILD_DIR (set by the
// dev shells to the platform/config-specific dir, e.g. src/build-debug or
// src/build-debug-repro), falling back to src/build-debug for the Linux tup
// default. See codetracer-specs Architecture/Build-Outputs-And-Path-Resolution.md.
const codetracerPrefix =
  process.env.CODETRACER_BUILD_DIR && process.env.CODETRACER_BUILD_DIR.length > 0
    ? process.env.CODETRACER_BUILD_DIR
    : path.join(codetracerInstallDir, "src", "build-debug");
// Imports also run in the collector, in --list, and in base-Playwright tests
// that never use _workerCleanup. Keep their import-time isolation, but give
// every allocating process its own synchronous exit cleanup. Register before
// the first allocation so a later setup failure cannot leak a partial pair.
const ownedGuiTestHomes = new Map<string, string>();
function removeOwnedGuiTestHomes(): void {
  for (const [home, variable] of ownedGuiTestHomes) {
    try {
      fs.rmSync(home, { recursive: true, force: true });
      // Relinquish ownership once removed: a later exit must not remove a
      // directory somebody else recreates at this path after worker teardown.
      ownedGuiTestHomes.delete(home);
    } catch (ex) {
      console.warn(`fixtures: removing test ${variable} failed: ${(ex as Error).message}`);
    }
  }
}
process.once("exit", removeOwnedGuiTestHomes);

function makeGuiTestHome(prefix: string, variable: string): string {
  const home = fs.mkdtempSync(path.join(scratchBase(), prefix));
  ownedGuiTestHomes.set(home, variable);
  return home;
}

// Both scratch homes are made under `scratchBase()` — `/tmp` on POSIX, not
// `os.tmpdir()`. The product binds Unix sockets under `CODETRACER_HOME`
// (`$CODETRACER_HOME/tmp/session-manager/<pid>/<id>.sock`), a socket address
// holds 104 bytes on macOS, and a home in macOS's per-user `TMPDIR` (deeper
// still inside a nix shell) left no room: the session manager refused the
// socket and every spec drove a product with no replay backend
// (`lib/socket-path-bound.ts`).
const originalXdgConfigHome = process.env.XDG_CONFIG_HOME;
const guiTestXdgConfigHome =
  process.env.CODETRACER_GUI_TEST_XDG_CONFIG_HOME ??
  makeGuiTestHome("codetracer-gui-xdg-config-", "XDG_CONFIG_HOME");
process.env.XDG_CONFIG_HOME = guiTestXdgConfigHome;
// EVERY per-user location of every CodeTracer this worker launches — config
// and layouts, the trace index, recordings, caches, the tmp/socket dir —
// derives from `CODETRACER_HOME` (src/common/ct_home.nim, libs/ct-home), on
// every OS, and it outranks `XDG_CONFIG_HOME` above. A scratch one per worker,
// so no spec reads or writes the developer's own profile. Specs find the
// files under it through `lib/ct-home.ts`.
const originalCodetracerHome = process.env.CODETRACER_HOME;
const guiTestCodetracerHome =
  process.env.CODETRACER_GUI_TEST_CODETRACER_HOME ??
  makeGuiTestHome("codetracer-gui-home-", "CODETRACER_HOME");
const ownsGuiTestCodetracerHome =
  process.env.CODETRACER_GUI_TEST_CODETRACER_HOME === undefined;
// Before anything is launched: a home too deep for the sockets under it
// fails every spec of this worker here, naming the socket path, its length
// and the limit, instead of a product that opens empty or never opens. A
// home supplied through CODETRACER_GUI_TEST_CODETRACER_HOME is held to the
// same bound.
assertHomeFitsSocketBound(
  guiTestCodetracerHome,
  ownsGuiTestCodetracerHome
    ? "made by lib/fixtures.ts"
    : "from CODETRACER_GUI_TEST_CODETRACER_HOME",
);
// Outside the OS temp directory now (on macOS `/tmp` is not `os.tmpdir()`), so
// the home carries the marker that names it a harness's scratch home: a Nim
// test helper a spec runs keeps it instead of replacing it with a private
// one (`src/frontend/test_support/state_isolation.nim`).
if (ownsGuiTestCodetracerHome) {
  fs.writeFileSync(path.join(guiTestCodetracerHome, ".codetracer-test-home"), "");
}
process.env.CODETRACER_HOME = guiTestCodetracerHome;

const ctBinaryName = isWindows ? "ct.exe" : "ct";
const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
const codetracerPath =
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(codetracerPrefix, "bin", ctBinaryName);

// On Windows, the `python3` name often resolves to the Windows Store alias
// stub which is not a real interpreter.  Detect and set the correct Python
// path so that `ct record` can find the recorder package.
if (isWindows && !process.env.CODETRACER_PYTHON_INTERPRETER && !process.env.CODETRACER_PYTHON_EXE_PATH) {
  // Strategy 1: Try common Python install locations directly.
  const homeDir = process.env.USERPROFILE || process.env.HOME || "";
  const knownPaths = [
    path.join(homeDir, "AppData", "Local", "Programs", "Python", "Python312", "python.exe"),
    path.join(homeDir, "AppData", "Local", "Programs", "Python", "Python313", "python.exe"),
    path.join(homeDir, "AppData", "Local", "Programs", "Python", "Python311", "python.exe"),
    path.join(homeDir, "AppData", "Local", "Programs", "Python", "Python310", "python.exe"),
    "C:\\Python312\\python.exe",
    "C:\\Python311\\python.exe",
    "C:\\Python313\\python.exe",
  ];
  for (const p of knownPaths) {
    if (fs.existsSync(p)) {
      process.env.CODETRACER_PYTHON_INTERPRETER = p;
      process.env.CODETRACER_PYTHON_EXE_PATH = p;
      break;
    }
  }

  // Strategy 2: If not found above, try `where` to locate python/py.
  if (!process.env.CODETRACER_PYTHON_INTERPRETER) {
    for (const candidate of ["python", "py"]) {
      try {
        const whichResult = childProcess.spawnSync("where", [candidate], {
          encoding: "utf-8",
          timeout: 5_000,
        });
        if (whichResult.status === 0) {
          // Filter out the Windows Store alias (WindowsApps path)
          const lines = whichResult.stdout.trim().split("\n").map((l: string) => l.trim());
          const realPath = lines.find(
            (l: string) => l.endsWith(".exe") && !l.includes("WindowsApps"),
          );
          if (realPath) {
            // Validate it actually works
            const vResult = childProcess.spawnSync(realPath, ["--version"], {
              encoding: "utf-8",
              timeout: 5_000,
            });
            if (vResult.status === 0 && vResult.stdout.includes("Python")) {
              process.env.CODETRACER_PYTHON_INTERPRETER = realPath;
              process.env.CODETRACER_PYTHON_EXE_PATH = realPath;
              break;
            }
          }
        }
      } catch {
        // candidate not found, try next
      }
    }
  }
}

// On Windows, `ct record` for Python traces uses the `codetracer-python-recorder`
// console script, which it discovers on PATH (src/common/paths.nim:
// `pythonRecorderExe = findTool("codetracer-python-recorder")`).  The recorder
// is a PyO3/maturin package installed into the codetracer-python-recorder
// sibling repo's virtualenv.  When that venv is present, prepend its
// Scripts/ directory to PATH so the recorder resolves, and point the
// interpreter env vars at the venv Python (the venv has the recorder module
// importable, which the bare system Python does not).
if (isWindows) {
  const pyRecorderVenvScripts = path.join(
    codetracerInstallDir, "..", "codetracer-python-recorder", ".venv", "Scripts",
  );
  const pyRecorderExe = path.join(pyRecorderVenvScripts, "codetracer-python-recorder.exe");
  const pyRecorderVenvPython = path.join(pyRecorderVenvScripts, "python.exe");
  if (fs.existsSync(pyRecorderExe)) {
    const pathSep = path.delimiter;
    const currentPath = process.env.PATH ?? "";
    if (!currentPath.split(pathSep).includes(pyRecorderVenvScripts)) {
      process.env.PATH = `${pyRecorderVenvScripts}${pathSep}${currentPath}`;
    }
    // The recorder must be imported by the same interpreter that ships it.
    if (fs.existsSync(pyRecorderVenvPython)) {
      process.env.CODETRACER_PYTHON_INTERPRETER = pyRecorderVenvPython;
      process.env.CODETRACER_PYTHON_EXE_PATH = pyRecorderVenvPython;
    }
  }
}

// On Windows, detect Ruby and the pure-Ruby recorder so that `ct record`
// can trace Ruby programs.
if (isWindows) {
  if (!process.env.CODETRACER_RUBY_EXE_PATH) {
    const rubyPaths = [
      "C:\\Ruby33-x64\\bin\\ruby.exe",
      "C:\\Ruby32-x64\\bin\\ruby.exe",
      "C:\\Ruby31-x64\\bin\\ruby.exe",
    ];
    for (const p of rubyPaths) {
      if (fs.existsSync(p)) {
        process.env.CODETRACER_RUBY_EXE_PATH = p;
        break;
      }
    }
    // Fallback: try `where ruby`
    if (!process.env.CODETRACER_RUBY_EXE_PATH) {
      try {
        const r = childProcess.spawnSync("where", ["ruby"], {
          encoding: "utf-8",
          timeout: 5_000,
        });
        if (r.status === 0) {
          const line = r.stdout.trim().split("\n")[0]?.trim();
          if (line && fs.existsSync(line)) {
            process.env.CODETRACER_RUBY_EXE_PATH = line;
          }
        }
      } catch { /* not found */ }
    }
  }

  if (!process.env.CODETRACER_RUBY_RECORDER_PATH) {
    // The pure-Ruby recorder is installed as a gem binary.
    const rubyExeDir = process.env.CODETRACER_RUBY_EXE_PATH
      ? path.dirname(process.env.CODETRACER_RUBY_EXE_PATH)
      : null;
    // The recorder script is invoked as `ruby <recorder_path>`, so we need
    // the actual Ruby script, not the .bat wrapper.
    const recorderCandidates = [
      rubyExeDir ? path.join(rubyExeDir, "codetracer-pure-ruby-recorder") : "",
      rubyExeDir ? path.join(rubyExeDir, "codetracer-ruby-recorder") : "",
      // Also check the sibling repo source directly
      path.join(codetracerInstallDir, "..", "codetracer-ruby-recorder", "gems",
        "codetracer-pure-ruby-recorder", "bin", "codetracer-pure-ruby-recorder"),
    ].filter(Boolean);
    for (const p of recorderCandidates) {
      if (fs.existsSync(p)) {
        process.env.CODETRACER_RUBY_RECORDER_PATH = p;
        break;
      }
    }
  }
}

// On Windows, ct.exe spawns Electron as a child process (no execv), which
// prevents Playwright from connecting via CDP.  We launch Electron directly
// and pass the app directory so it picks up package.json / index.js.
const electronExePath: string | null = (() => {
  if (!isWindows) return null;
  // Try node_modules in the codetracer install dir
  const candidates = [
    path.join(codetracerInstallDir, "node-packages", "node_modules", "electron", "dist", "electron.exe"),
    path.join(codetracerInstallDir, "node_modules", "electron", "dist", "electron.exe"),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  return null;
})();

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const OK_EXIT_CODE = 0;
const MAX_CONNECT_ATTEMPTS = 20;
const RETRY_DELAY_MS = 1_500;
const GOTO_TIMEOUT_MS = 3_000;
const PORT_RELEASE_DELAY_MS = 500;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// Defined in ./deployment-mode beside the run-wide default it computes;
// re-exported so specs keep importing it from here.
export type { DeploymentMode };
export type LaunchMode = "trace" | "trace-folder" | "welcome" | "edit" | "deepreview";

/**
 * Configurable options set via `test.use({ ... })`.
 */
interface CodetracerOptions {
  /**
   * Electron or Web (ct host + chromium). Defaults to the run-wide mode set
   * by `CODETRACER_TEST_IN_BROWSER` (Electron when unset); a spec's own
   * `test.use({ deploymentMode })` overrides that default.
   */
  deploymentMode: DeploymentMode;
  /** Path to test program — relative to test-programs/ or absolute (for sibling repos). */
  sourcePath: string;
  /** How to launch CodeTracer. */
  launchMode: LaunchMode;
  /** New trace/open policy used by the Electron process. */
  newTracePolicy: "window" | "tab";
  /** Test-only folder returned by the native Open Folder dialog handler. */
  testOpenFolderDialogPath: string;
  /** Folder path for edit mode. */
  editFolderPath: string;
  /** Process cwd for edit mode launches. */
  editWorkingDirectory: string;
  /** JSON path for deepreview mode. */
  deepreviewJsonPath: string;
  /** Mark the recorded trace as visual-capable before launching replay. */
  visualReplayTrace: boolean;
  /**
   * The native backend `ct record` records a native program with (`--backend`);
   * "" for the product's default (MCR). A spec that needs a replay only one
   * backend gives — rr's instruction stepping — names it.
   */
  recordBackend: "" | "rr" | "mcr";
  /** Existing .ct or trace folder to import via ct host --trace-path. */
  visualReplayTracePath: string;
  /**
   * Keep whatever `auto_hide_state.json` the spec wrote before launching.
   *
   * The launch fixture normally deletes it alongside the layout reset, so a
   * panel one test pinned cannot come back in the next one.  Specs that exist
   * to prove a pinned panel IS restored across a restart seed the file in a
   * fixture-free `beforeEach` (which runs first) and set this so the reset
   * does not undo them.
   */
  preserveAutoHideState: boolean;
  /**
   * A JSON layout file to install as `default_edit_layout.json` before
   * launching.
   *
   * This is how a spec launches over a **pre-existing** saved layout instead
   * of the bundled default. It matters because `default_edit_layout.json` is
   * shared by two modes with different panel requirements: edit mode WRITES
   * it through a sanitiser that deletes `Content.AgentActivity`, and — since
   * RV-2 — `ct review <PATH>` READS it. A review launched on a fresh config
   * directory therefore exercises the fallback path (the bundled debugging
   * layout, sanitised), never the file a real user's review opens.
   *
   * Setting this implies `preserveEditLayout`: the file is installed after
   * the reset, not erased by it.
   */
  editLayoutPath: string;
  /**
   * Keep whatever `default_edit_layout.json` is already on disk.
   *
   * The launch fixture normally deletes it alongside the layout reset, so an
   * edit-mode session in an earlier test of the same worker cannot change
   * which layout a later launch opens. Specs that write the file themselves
   * in a fixture-free `beforeEach` (which runs BEFORE `ctPage`) set this so
   * the reset does not undo them.
   */
  preserveEditLayout: boolean;
  /**
   * Launch on the RAW bundled tree: `src/config/default_layout.json` is
   * copied verbatim into the saved `default_layout.json`, so the desktop
   * loads it as-is instead of deriving the Debug mode's default from it.
   *
   * Without this (the default) the saved layout is REMOVED and the launch
   * takes the product's own first-run path, exactly as on a machine that has
   * never run CodeTracer: the index process installs the Debug mode's default
   * (`index/config.installModeDefault`) — TESTS a tab of the FILES stack, no
   * CONSTRAINTS — which is what a user opens a recording with.
   *
   * No CodeTracer mode draws the bundled tree (`index/mode_default_layout.nim`
   * calls it "nobody's layout": a standing TEST RESULTS stack over a
   * CONSTRAINTS stack). Set this only in a spec whose subject is that tree.
   * Panes the bottom auto-hide strip registers (BUILD, PROBLEMS, FIND IN
   * FILES) are in neither tree and need no option. Contradicts
   * `preserveUserLayout`; setting both fails the launch.
   * See `layout-reset.prepareUserLayout`.
   */
  bundledLayout: boolean;
  /**
   * PLAT-45: leave the user's saved `default_layout.json` exactly as an
   * earlier test of the same worker left it — neither removed nor replaced
   * with the bundled tree — so a spec can observe the desktop RESTORING its
   * own last layout on the next start.
   */
  preserveUserLayout: boolean;
  /**
   * PLAT-45: the `CODETRACER_PREFIX` the launched `ct` resolves its
   * `config/` (and every other prefix-relative asset) from. Empty means the
   * default — the prefix `ct` derives from its own location. The capture lane
   * points it at a prefix whose `config/default_layout.json` came from a
   * scratch build of the shared default, to show the desktop's default
   * follows the shared tree.
   */
  codetracerPrefixOverride: string;
  /**
   * PLAT-47: the `theme:` the launch's `.config.yaml` names (`default_white`
   * for the desktop's light theme). Empty keeps the bundled config's
   * (`default_dark`). The launch fixture copies the bundled
   * `default_config.yaml` into the test's `XDG_CONFIG_HOME` before every
   * launch; this rewrites that copy's `theme:` line, so the desktop starts
   * in the named theme through its own configuration path — the stylesheet
   * and the Monaco theme both — exactly as a user's config would select it.
   */
  configTheme: string;
  /**
   * Extra environment variables for the launched CodeTracer process (and so
   * for every child it spawns).
   *
   * This is per test, through `test.use`, rather than through `process.env`:
   * with `--workers=1` every spec file shares one worker process, so a spec
   * that edited `process.env` would change the launches of the spec files
   * that run after it. The harness's own isolation variables
   * (`CODETRACER_HOME`, `XDG_CONFIG_HOME`, …) are applied after these and
   * cannot be overridden from here.
   *
   * #862: `agent-activity/enter_submits_prompt.spec.ts` uses it to put a
   * stub `codex-acp` first on the app's `PATH`.
   */
  launchEnv: Record<string, string>;
  /**
   * JavaScript run in every renderer document of an Electron launch BEFORE
   * the app's own scripts, or "" for none.
   *
   * `page.evaluate` in a test comes too late for anything the renderer does
   * while it starts: by the time `ctPage` is handed over, a `ct review`
   * launch has already painted the session it loaded. A spec that has to
   * observe that start-up installs its instrumentation here instead. It is
   * registered on the app's browser context as soon as `_electron.launch`
   * returns (`installRendererInitScript`), and applies to every window and
   * navigation after that. The spec should check that its script really ran
   * in the page it inspects (for example by a global the script sets).
   *
   * Per test, through `test.use`, for the reason `launchEnv` is. Web launches
   * have no Electron context and ignore it.
   */
  rendererInitScript: string;
  /**
   * Draw the test-only completed-move counter (`span.test-movement`) in the
   * status bar. Off by default, and a reference capture never turns it on.
   *
   * Every launch here sets `CODETRACER_TEST=1` -- in the Electron app's
   * environment and in the `ct host` a web launch starts, which runs the same
   * index process and sends its `startOptions` to the browser -- and under
   * the resulting `data.startOptions.inTest` the status bar emits the counter
   * in front of `.status-right`. A production renderer never emits it. So
   * while it was drawn, every Electron frame captured as the reference for
   * the native front-end had a number in front of "No certificates" that no
   * user ever sees and the native front-end correctly lacks. Every census of
   * the bar's boxes also listed it as a status-bar part.
   *
   * With the option off, the counter is hidden with `display: none` from
   * document start (see `HIDE_TEST_MOVEMENT_COUNTER_SCRIPT`). An element with
   * `display: none` has no box, so the frame and every box census taken from
   * it match the production bar. The element stays in the DOM and its text
   * is still patched, so the renderer behaves exactly as before. No helper
   * reads the counter. Turn it on to see the counter while debugging a run
   * by eye.
   *
   * Both deployment modes: Electron launches install the hiding on the app's
   * context, web launches on the browser context they create.
   */
  showTestMovementCounter: boolean;
}

/**
 * Fixtures available in test functions.
 */
interface CodetracerFixtures {
  /** The Playwright Page connected to CodeTracer. */
  ctPage: Page;
  /** The Electron app handle (null in web mode). */
  electronApp: ElectronApplication | null;
  /**
   * Renderer console errors collected since the page was created, in order.
   *
   * The same live array the failure diagnostics dump — so it covers the
   * whole launch, not just the part of it that happened after the test body
   * started.  Depends on `ctPage`, so requesting it launches the app.
   */
  consoleErrors: string[];
}

interface CodetracerWorkerFixtures {
  /** Internal: forces worker exit to avoid teardown timeout. */
  _workerCleanup: void;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function setupLdLibraryPath(): void {
  // LD_LIBRARY_PATH is a Linux/macOS concept; skip on Windows.
  if (isWindows) return;
  // Prepend CT_LD_LIBRARY_PATH (Nix-store libs the dev shell baked in)
  // to the current LD_LIBRARY_PATH rather than overwriting it.  The
  // current path already has sibling-repo additions baked in by
  // detect-siblings.sh — notably codetracer-trace-format-nim, which is
  // what wazero (codetracer-wasm-recorder) dlopens to write traces.
  // Overwriting drops that path and the wasm_example test (and any other
  // path that shells out to wazero) fails with
  // `libcodetracer_trace_writer.so: cannot open shared object file`.
  const ctLibs = process.env.CT_LD_LIBRARY_PATH ?? "";
  const current = process.env.LD_LIBRARY_PATH ?? "";
  process.env.LD_LIBRARY_PATH =
    ctLibs.length > 0 && current.length > 0
      ? `${ctLibs}:${current}`
      : ctLibs.length > 0
        ? ctLibs
        : current;
}

/**
 * Remove Electron's single-instance lock files so a fresh launch can
 * acquire the lock.  Stale locks from previous test runs (or manual
 * launches) cause `_electron.launch()` to hang because the new Electron
 * instance detects the lock and tries to delegate to a non-existent
 * first instance.
 */
function clearElectronSingletonLocks(): void {
  // Under a `CODETRACER_HOME` (which this worker always has) the app's
  // userData — and so the lock — is `$CODETRACER_HOME/state/electron`
  // (src/frontend/index.nim); the default location is still cleared for a
  // launch made without one.
  const electronUserDataDirs = [
    path.join(guiTestCodetracerHome, "state", "electron"),
    path.join(
      process.env.HOME ?? process.env.USERPROFILE ?? "",
      isWindows ? "AppData/Roaming/Electron" : ".config/Electron",
    ),
  ];
  for (const electronUserDataDir of electronUserDataDirs) {
    for (const lockFile of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) {
      const lockPath = path.join(electronUserDataDir, lockFile);
      try {
        fs.unlinkSync(lockPath);
      } catch {
        // File may not exist — that's fine.
      }
    }
  }
}

/**
 * Recursively kills a process and all its descendants.
 * Prevents backend-manager and db-backend from leaking as orphans
 * when Electron is killed during test teardown.
 *
 * On Windows, uses `taskkill /PID <pid> /T /F` which natively kills
 * the entire process tree. On Linux/macOS, walks the tree via pgrep
 * and sends SIGKILL to each process.
 */
function killProcessTree(pid: number): void {
  if (isWindows) {
    // taskkill /T kills the process and all child processes.
    // /F forces termination (equivalent to SIGKILL).
    try {
      childProcess.execSync(`taskkill /PID ${pid} /T /F`, {
        encoding: "utf-8",
        stdio: "pipe",
        windowsHide: true,
      });
    } catch {
      // Process may already be dead.
    }
    return;
  }

  // Linux/macOS: find children before killing the parent (once parent dies,
  // children get reparented to init and we lose the relationship).
  let childPids: number[] = [];
  try {
    const output = childProcess
      .execSync(`pgrep -P ${pid} 2>/dev/null`, { encoding: "utf-8" })
      .trim();
    if (output) {
      childPids = output.split("\n").map(Number).filter(Boolean);
    }
  } catch {
    // No children found.
  }

  // Recursively kill children first.
  for (const child of childPids) {
    killProcessTree(child);
  }

  // Kill the process itself.
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already dead.
  }
}

/**
 * Kill stray CodeTracer-related processes that may have leaked from
 * previous test runs.  On Windows, this kills all backend_manager.exe,
 * db-backend.exe, and db-backend-record.exe instances.  No-op on other
 * platforms where Unix process groups handle cleanup more reliably.
 */
function killStrayCodetracerProcesses(): void {
  if (!isWindows) return;
  for (const name of [
    "backend_manager.exe",
    "db-backend.exe",
    "db-backend-record.exe",
    "ct-native-replay.exe",
    "TTD.exe",
    "TTDInject.exe",
  ]) {
    try {
      childProcess.execSync(`taskkill /IM ${name} /F`, {
        encoding: "utf-8",
        stdio: "pipe",
        windowsHide: true,
      });
    } catch {
      // No matching processes — expected.
    }
  }
}

function cleanupCodetracerEnvVars(): void {
  // M-REC-6: CODETRACER_TRACE_ID is retired in favour of
  // CODETRACER_RECORDING_ID.  Both are deleted defensively in case a
  // legacy fixture or shell still exports the old name.
  delete process.env.CODETRACER_TRACE_ID;
  delete process.env.CODETRACER_RECORDING_ID;
  delete process.env.CODETRACER_CALLER_PID;
  delete process.env.CODETRACER_IN_UI_TEST;
  delete process.env.CODETRACER_TEST;
  delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
}

// Cache recording IDs by source path so multiple tests for the same
// program don't re-record. This dramatically speeds up RR test suites
// where each language has 5 tests sharing the same sourcePath.
//
// M-REC-2 / M-REC-3 / M-REC-6: the value is a UUIDv7 recording-id
// string — not a numeric DB row id.
const recordingCache = new Map<string, string>();

function recordTestProgram(recordArg: string, backend?: "rr" | "mcr" | "ttd"): string {
  // A test selecting a backend must not reuse a recording made by another
  // backend, or by the product's current default.
  const cacheKey = JSON.stringify([recordArg, backend ?? null]);
  const cached = recordingCache.get(cacheKey);
  if (cached !== undefined) {
    console.log(`# reusing cached trace for ${recordArg} with id ${cached}`);
    return cached;
  }

  process.env.CODETRACER_IN_UI_TEST = "1";

  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["record", ...(backend ? ["--backend", backend] : []), recordArg],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
      timeout: LIMIT_RR_RECORDING_MS,
      windowsHide: true,
    },
  );

  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    throw new Error(
      `ct record failed: error=${ctProcess.error}; status=${ctProcess.status}\nstderr: ${ctProcess.stderr}\nstdout: ${ctProcess.stdout}`,
    );
  }

  // M-REC-2 / M-REC-3 / M-REC-6: stdout marker is ``recordingId:`` and
  // the payload is a UUIDv7 recording-id string.  Validate the shape
  // lightly (non-empty after trimming) and pass it through verbatim —
  // no ``Number()`` coercion.
  //
  // The marker is NOT reliably the last line: `ct record` first replays
  // the traced program's own stdout (which may end with a trailing
  // separator/banner line, e.g. the sudoku board followed by a row of
  // dashes) and only then prints the `recordingId:` marker.  Depending on
  // stdout flush ordering between the child program and `ct` the marker
  // can be followed by trailing program output.  Scan every line for the
  // marker rather than assuming it is last.
  const lines = ctProcess.stdout.trim().split(/\r?\n/);
  const markerLine = [...lines]
    .reverse()
    .find((line) => line.trimStart().startsWith("recordingId:"));
  if (markerLine === undefined) {
    throw new Error(
      `No 'recordingId:' marker in ct record output:\n${ctProcess.stdout}`,
    );
  }
  const recordingId = markerLine
    .trimStart()
    .slice("recordingId:".length)
    .trim();
  if (recordingId.length === 0) {
    throw new Error(`Empty recording id from ct record output: ${markerLine}`);
  }
  console.log(`# recorded trace for ${recordArg} with id ${recordingId}`);
  recordingCache.set(cacheKey, recordingId);
  return recordingId;
}

function traceFolderForId(recordingId: string): string {
  // `$CODETRACER_HOME/data` — where `ct record` under this worker put it.
  const dataDir = ctUserDataDir();
  // M-REC-7: the on-disk recording folder name is the bare UUIDv7
  // recording id — the pre-M-REC-7 `trace-<id>` prefix was retired
  // (see src/common/paths.nim `recordingFolder`).  Fall back to the
  // legacy prefixed name only if the bare folder is absent, so older
  // local recordings keep working.
  const bare = path.join(dataDir, recordingId);
  if (fs.existsSync(bare)) {
    return bare;
  }
  const legacy = path.join(dataDir, `trace-${recordingId}`);
  if (fs.existsSync(legacy)) {
    return legacy;
  }
  return bare;
}

function markTraceVisualReplayCapable(recordingId: string): void {
  const gfxDir = path.join(traceFolderForId(recordingId), "gfx_stream");
  fs.mkdirSync(gfxDir, { recursive: true });
  fs.writeFileSync(path.join(gfxDir, "gfx_commands.dat"), "");
}

function companionGfxStreamDir(tracePath: string): string {
  const baseDir = fs.statSync(tracePath).isDirectory()
    ? tracePath
    : path.dirname(tracePath);
  return path.join(baseDir, "gfx_stream");
}

function importedTraceIdFromStdout(stdout: string): string | null {
  const match = stdout.match(/ct host: imported as trace id ([0-9a-f-]{36})/);
  return match?.[1] ?? null;
}

async function copyCompanionGfxStreamAfterTracePathImport(
  tracePath: string,
  stdoutChunks: string[],
  ctProcess: childProcess.ChildProcess,
): Promise<void> {
  const sourceGfxDir = companionGfxStreamDir(tracePath);
  if (!fs.existsSync(sourceGfxDir)) {
    return;
  }

  const deadline = Date.now() + MAX_CONNECT_ATTEMPTS * RETRY_DELAY_MS;
  let recordingId: string | null = null;
  while (Date.now() < deadline) {
    recordingId = importedTraceIdFromStdout(stdoutChunks.join(""));
    if (recordingId) {
      break;
    }
    if (ctProcess.exitCode !== null || ctProcess.signalCode !== null) {
      break;
    }
    await sleep(100);
  }

  if (!recordingId) {
    console.warn(
      `fixtures: trace-path import id not observed; visual replay artifacts were not copied from ${sourceGfxDir}`,
    );
    return;
  }

  const targetGfxDir = path.join(traceFolderForId(recordingId), "gfx_stream");
  fs.mkdirSync(path.dirname(targetGfxDir), { recursive: true });
  fs.cpSync(sourceGfxDir, targetGfxDir, { recursive: true, force: true });
  const sourceCtfsSidecar = `${sourceGfxDir}.ctfs`;
  if (fs.existsSync(sourceCtfsSidecar)) {
    fs.copyFileSync(sourceCtfsSidecar, `${targetGfxDir}.ctfs`);
  }
  console.log(`# copied visual replay stream for imported trace ${recordingId}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}


/**
 * Finds the editor window from an Electron app.
 * When DevTools is open, the first window may be DevTools. On Windows the
 * editor's initial about:blank document can also be replaced immediately
 * after firstWindow() resolves, so reading its title races that navigation
 * and can fail with "Execution context was destroyed". URLs are available
 * without evaluating in the page and let us wait for the real editor window.
 */
async function getEditorWindow(app: ElectronApplication): Promise<Page> {
  await installRendererInitScript(app);
  await app.firstWindow({ timeout: 45_000 });
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    const editor = app.windows().find((window) => {
      const url = window.url();
      return url !== "about:blank" && !url.startsWith("devtools://");
    });
    if (editor) {
      const url = editor.url();
      try {
        await editor.waitForLoadState("domcontentloaded", { timeout: 1_000 });
        await sleep(250);
        if (!editor.isClosed() && editor.url() === url) {
          await editor.evaluate(() => document.readyState);
          return editor;
        }
      } catch (_error) {
        // The provisional document was replaced; retry with the new context.
      }
    }
    await sleep(50);
  }
  throw new Error("timed out waiting for Electron's editor window to navigate");
}

/** PLAT-45: the running test's `codetracerPrefixOverride`, or "". */
let activePrefixOverride = "";

/** #862: the running test's `launchEnv` (see that option), or {}. */
let activeLaunchEnv: Record<string, string> = {};

/** The running test's `rendererInitScript` (see that option), or "". */
let activeRendererInitScript = "";

/** The running test's `showTestMovementCounter` (see that option). */
let activeShowTestMovementCounter = false;

/**
 * Hides the test-only move counter (see the `showTestMovementCounter`
 * option) in every renderer document.
 *
 * It runs at document start, when the document may have no `<head>` yet,
 * so the `<style>` goes on `document.documentElement`, which always exists
 * by then. A `<style>` outside `<head>` applies like any other. If even
 * that is missing (a document that is not HTML), the script waits for
 * `DOMContentLoaded`. The rule is a stylesheet, not a one-off removal, so it
 * also holds when the status bar re-renders and emits a fresh element.
 */
const HIDE_TEST_MOVEMENT_COUNTER_SCRIPT = `(() => {
  const install = () => {
    const root = document.documentElement;
    if (!root || document.getElementById("ct-test-hide-test-movement")) return !!root;
    const style = document.createElement("style");
    style.id = "ct-test-hide-test-movement";
    style.textContent = ".test-movement { display: none !important; }";
    root.appendChild(style);
    return true;
  };
  if (!install()) document.addEventListener("DOMContentLoaded", install, { once: true });
})();`;

/**
 * Register the counter hiding on `context` unless the running test asked to
 * see the counter. Every launch calls it before its first document loads:
 * Electron through `installRendererInitScript`, the web launches straight
 * after `browser.newContext`.
 */
async function installTestMovementCounterHiding(context: BrowserContext): Promise<void> {
  if (activeShowTestMovementCounter) return;
  await context.addInitScript({ content: HIDE_TEST_MOVEMENT_COUNTER_SCRIPT });
}

/**
 * Register the launch's init scripts on `app`'s browser context, so they run
 * at document start in the editor window: the counter hiding (unless the
 * test asked to see the counter), then the running test's own
 * `rendererInitScript`. Called first thing in `getEditorWindow`, which every
 * Electron launch reaches straight after `_electron.launch` returns.
 */
async function installRendererInitScript(app: ElectronApplication): Promise<void> {
  await installTestMovementCounterHiding(app.context());
  if (activeRendererInitScript.length === 0) return;
  await app.context().addInitScript({ content: activeRendererInitScript });
}

/**
 * The `ct` a launch runs. With a `codetracerPrefixOverride` it is the
 * PREFIX'S OWN `bin/ct`, not the build's: `ct` derives the Electron main
 * script it starts (`<prefix>/src/index.js`, `common/paths.nim`
 * `electronIndexPath`) from its OWN location (`getAppDir().parentDir`), not
 * from `CODETRACER_PREFIX`. Launching the build's `ct` with an overridden
 * prefix therefore runs the build's main process against the prefix's
 * renderer — two different `ClientAction` enums on the two ends of the
 * config IPC, which is exactly the mismatch a prefix is not allowed to be.
 */
function launchCt(): string {
  if (activePrefixOverride.length > 0) {
    return path.join(activePrefixOverride, "bin", ctBinaryName);
  }
  return codetracerPath;
}

/**
 * Creates a clean environment for launching CodeTracer,
 * free of leftover trace-related vars.
 */
function makeCleanEnv(
  extra?: Record<string, string>,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v;
  }
  // The test's own `launchEnv` goes on first, so every isolation variable set
  // below still wins over it.
  Object.assign(env, activeLaunchEnv);
  // M-REC-6: legacy CODETRACER_TRACE_ID is retired; CODETRACER_RECORDING_ID
  // is the new name.  We delete both so neither leaks into the launched
  // process from the test runner's environment.
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_RECORDING_ID;
  delete env.CODETRACER_CALLER_PID;
  // On Windows with direct Electron launch, we MUST set CODETRACER_PREFIX
  // because Electron's own exe path is not inside build-debug/ so the Nim
  // code cannot derive the prefix from getAppDir().  On other platforms
  // (or when ct.exe launches Electron), remove it so the ct binary derives
  // it from its own location (getAppDir().parentDir).
  if (isWindows && electronExePath) {
    env.CODETRACER_PREFIX = codetracerPrefix;
  } else {
    delete env.CODETRACER_PREFIX;
  }
  // PLAT-45: a test that asked for a specific prefix gets it (see the
  // `codetracerPrefixOverride` option).
  if (activePrefixOverride.length > 0) {
    env.CODETRACER_PREFIX = activePrefixOverride;
  }
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  // Every `ct host` these tests start is given the session secret the page
  // URLs carry (ct-host-session.ts).
  withCtHostSessionSecret(env);
  // Turn HMR off for ordinary GUI tests.
  //
  // `just build-once` compiles the renderer with `-d:ctHmr`, and
  // `hmr_runtime.isHmrRequested()` defaults to ON when CT_HMR is unset.  So
  // every test launch tried to reach the LiveReload daemon at
  // ws://localhost:35729, which is not running under the test harness, and
  // Chromium logged `WebSocket connection ... failed: ERR_CONNECTION_REFUSED`
  // as a console *error*.  That line is emitted by the network stack, not by
  // page JS, so it cannot be demoted at the source — the only way to not log
  // it is to not attempt the connection.
  //
  // Disabling HMR here is right on its own merits, independently of the log
  // line: a test run has no file watcher, and a bundle swapped underneath a
  // running spec is a source of nondeterminism, not a feature.
  //
  // The HMR suite is unaffected: `tests/hmr/hmr_views_and_styles.spec.ts`
  // builds its launch environment with its own `makeHmrEnv()`, which starts
  // from `process.env` (untouched here — `env` is a local copy) and
  // explicitly `delete`s CT_HMR to opt back in against a daemon it starts
  // itself.
  env.CT_HMR = "0";
  env.XDG_CONFIG_HOME = guiTestXdgConfigHome;
  env.CODETRACER_HOME = guiTestCodetracerHome;
  // Bypass the Electron single-instance lock so that concurrent test runs
  // (or stale Electron processes from previous runs) do not prevent this
  // instance from starting.  With "window" policy the new process always
  // opens its own window instead of delegating to an existing instance.
  env.CODETRACER_NEW_TRACE_POLICY = "window";
  // Prevent the GPU process from crashing fatally during long-running tests
  // (e.g. Python traces that take ~40s to load).  The GPU process on some
  // systems (nVidia + Wayland) crashes and after a few retries Electron
  // terminates with "GPU process isn't usable. Goodbye."
  // --in-process-gpu runs the GPU code in the main process, avoiding the
  // separate GPU process crash/restart cycle entirely.
  // Remove Wayland env vars so Electron does not attempt the Wayland
  // backend when running under Xvfb.  Even with --ozone-platform-hint=x11,
  // Electron may try Wayland first if WAYLAND_DISPLAY is set, causing
  // "Failed to initialize Wayland platform" and process exit.
  delete env.WAYLAND_DISPLAY;
  delete env.XDG_SESSION_TYPE;
  env.CODETRACER_ELECTRON_ARGS = [
    "--no-sandbox",
    "--no-zygote",
    "--disable-gpu",
    "--disable-gpu-compositing",
    "--disable-dev-shm-usage",
    "--in-process-gpu",
    // Force X11 backend so Electron does not attempt Wayland first.
    "--ozone-platform-hint=x11",
  ].join(" ");
  if (extra) {
    Object.assign(env, extra);
  }
  return env;
}

/**
 * Resolves the chromium executable path for the web-mode browser fixture.
 *
 * Priority:
 *   1. $PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH — explicit override.
 *   2. $PLAYWRIGHT_BROWSERS_PATH — scan for the installed chromium revision
 *      (the nix dev shell provides browsers here).
 *   3. Playwright's default install cache (`~/AppData/Local/ms-playwright`
 *      on Windows, `~/.cache/ms-playwright` on Linux) — this is where
 *      `npx playwright install` puts browsers when no env var is set.
 *   4. `undefined` — let `chromium.launch()` use its own bundled-browser
 *      discovery. Returning `undefined` (rather than throwing) keeps the
 *      web-mode fixture working on machines that did not set
 *      $PLAYWRIGHT_BROWSERS_PATH, matching the graceful fallback in
 *      `playwright.config.ts`'s `resolveChromiumExecutable()`.
 */
function resolveChromiumPath(): string | undefined {
  const explicit = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  const candidateDirs: string[] = [];
  if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
    candidateDirs.push(process.env.PLAYWRIGHT_BROWSERS_PATH);
  }
  // Playwright's default browser cache location.
  const homeDir = os.homedir();
  if (homeDir) {
    if (isWindows) {
      candidateDirs.push(path.join(homeDir, "AppData", "Local", "ms-playwright"));
    } else {
      candidateDirs.push(path.join(homeDir, ".cache", "ms-playwright"));
    }
  }

  for (const browsersDir of candidateDirs) {
    if (!fs.existsSync(browsersDir)) {
      continue;
    }
    const chromiumDir = fs
      .readdirSync(browsersDir)
      .filter((d: string) => d.startsWith("chromium-") && !d.includes("headless"))
      .sort()
      .pop();
    if (!chromiumDir) {
      continue;
    }
    const chromiumBase = path.join(browsersDir, chromiumDir);
    if (isWindows) {
      const chromeSubdir = fs
        .readdirSync(chromiumBase)
        .find((d: string) => d.startsWith("chrome-win"));
      if (chromeSubdir) {
        const exe = path.join(chromiumBase, chromeSubdir, "chrome.exe");
        if (fs.existsSync(exe)) {
          return exe;
        }
      }
    } else {
      const chromeSubdir = fs
        .readdirSync(chromiumBase)
        .find((d: string) => d.startsWith("chrome-linux"));
      if (chromeSubdir) {
        const exe = path.join(chromiumBase, chromeSubdir, "chrome");
        if (fs.existsSync(exe)) {
          return exe;
        }
      }
    }
  }

  // Nothing discovered — let chromium.launch() fall back to its bundled
  // browser. This is not an error: Playwright ships its own chromium.
  return undefined;
}

// ---------------------------------------------------------------------------
// Launch strategies
// ---------------------------------------------------------------------------

interface LaunchResult {
  page: Page;
  electronApp: ElectronApplication | null;
  /** Cleanup function called during teardown. */
  teardown: () => Promise<void>;
  /** Collected console errors from the renderer (for diagnostics). */
  consoleErrors: string[];
  /** Collected main-process stderr lines (for diagnostics). */
  mainProcessOutput: string[];
}

type CoreStylesheetSpec = {
  name: string;
  selector: string;
};

const CORE_ELECTRON_STYLESHEETS: CoreStylesheetSpec[] = [
  {
    name: "theme",
    selector: "link#theme[href*='frontend/styles/']",
  },
  {
    name: "loader",
    selector: "link[rel='stylesheet'][href*='frontend/styles/loader.css']",
  },
];

async function coreStylesheetStatus(page: Page) {
  const browserStatus = await page.evaluate((specs) => {
    const links = specs.map((spec) => {
      const link = document.querySelector(spec.selector) as HTMLLinkElement | null;
      return {
        name: spec.name,
        selector: spec.selector,
        href: link?.href ?? "",
        found: !!link,
      };
    });

    return {
      links,
    };
  }, CORE_ELECTRON_STYLESHEETS);

  const links = browserStatus.links.map((link) => {
    let filePath = "";
    let exists = false;
    let size = 0;
    let fileError = "";
    if (link.href.length > 0) {
      try {
        const url = new URL(link.href);
        url.search = "";
        url.hash = "";
        filePath = fileURLToPath(url);
        const stat = fs.statSync(filePath);
        exists = stat.isFile();
        size = stat.size;
      } catch (error) {
        fileError = String(error);
      }
    }
    return {
      ...link,
      filePath,
      exists,
      size,
      fileError,
      loaded: link.found && exists && size > 0,
    };
  });

  return {
    ok: links.every((link) => link.loaded),
    links,
  };
}

async function assertCoreElectronStylesLoaded(page: Page): Promise<void> {
  const deadline = Date.now() + 5_000;
  let status = await coreStylesheetStatus(page);
  while (!status.ok &&
      status.links.some((link) => !link.found) &&
      Date.now() < deadline) {
    await page.waitForTimeout(100);
    status = await coreStylesheetStatus(page);
  }

  if (status.ok) return;

  const missing = status.links
    .filter((link) => !link.found || !link.loaded)
    .map((link) =>
      `${link.name}: found=${link.found} loaded=${link.loaded} href=${link.href || "(missing)"} ` +
        `file=${link.filePath || "(unresolved)"} exists=${link.exists} size=${link.size} ` +
        `error=${link.fileError || "(none)"}`,
    )
    .join("\n  ");

  throw new Error(
    "Core CodeTracer Electron stylesheets are missing or empty. " +
      "This usually means the debug build was created without the Tup/Stylus asset pipeline.\n" +
      `Missing core styles:\n  ${missing || "(none)"}`,
  );
}

/**
 * Attach a stderr listener to the Electron main process to capture
 * infoPrint / debugPrint output from the Nim-compiled index.js.
 */
function attachMainProcessCapture(
  app: ElectronApplication,
  bucket: string[],
): void {
  const proc = app.process();
  proc.stderr?.on("data", (chunk: Buffer) => {
    for (const line of chunk.toString().split("\n")) {
      if (line.trim().length > 0) {
        bucket.push(line);
      }
    }
  });
  proc.stdout?.on("data", (chunk: Buffer) => {
    for (const line of chunk.toString().split("\n")) {
      if (line.trim().length > 0) {
        bucket.push(`[stdout] ${line}`);
      }
    }
  });
}

/**
 * Attach console/page-error listeners to collect renderer-side JS errors.
 * Also probes the page for any errors that occurred before attachment.
 */
/**
 * The console-error bucket attached to each page, so the `consoleErrors`
 * fixture can hand a spec the *same* live array the launcher fills and the
 * failure diagnostics dump.  A WeakMap rather than a field on `LaunchResult`
 * because every launch mode builds its own result object, and a spec asking
 * for the errors should not have to know which mode it is running under.
 */
const pageConsoleErrors = new WeakMap<Page, string[]>();

/**
 * The `ElectronApplication` a page belongs to, so the `electronApp` fixture can
 * hand a spec the real main-process handle.
 *
 * **The same WeakMap-keyed-by-page arrangement as `pageConsoleErrors`, and for
 * the same reason**: every launch mode builds its own `LaunchResult`, and a
 * spec asking for the app should not have to know which mode it is under.
 *
 * WHY THIS EXISTS AT ALL. The `electronApp` fixture used to be
 * `async ({}, use) => { await use(null); }` with the comment *"populated by
 * ctPage fixture"*. Nothing populated it: a Playwright fixture cannot be
 * written from another fixture's body, so it handed `null` to every spec in
 * the suite, in every launch mode, always. That is not a cosmetic defect —
 * a spec written as `if (electronApp !== null) { …resize the window… }` is a
 * block that never runs and never says so, and PLAT-35's viewport matrix was
 * exactly that block. Measured 2026-09-21: a probe under `launchMode:
 * "trace-folder"` — a mode whose launcher returns a non-null app on every
 * path — printed `electronApp is NULL`.
 *
 * The fixture below now DEPENDS on `ctPage`, which is what makes this
 * well-defined: Playwright resolves `ctPage` first, its launcher registers the
 * page here, and the `electronApp` fixture reads it back. It stays `null` for
 * the web deployment mode, which genuinely has no Electron main process.
 */
const pageElectronApps = new WeakMap<Page, ElectronApplication>();

function attachErrorCollectors(page: Page, bucket: string[]): void {
  pageConsoleErrors.set(page, bucket);

  const initScript = () => {
    const handleErr = (error: any, type: string, origin?: string) => {
      const visited = new Set();
      function nimValueToString(v: any): string {
        if (v === null || v === undefined) return "";
        if (typeof v === "string") return v;
        if (typeof v === "object") {
          if (visited.has(v)) return "[Circular]";
          visited.add(v);
          if (Array.isArray(v)) {
            if (v.every(x => typeof x === "number")) {
              return String.fromCharCode(...v);
            }
            return "[" + v.map(nimValueToString).join(", ") + "]";
          }
          if (Array.isArray(v.data)) {
            return nimValueToString(v.data);
          }
          const keys = Object.keys(v);
          if (keys.length === 0) return String(v);
          return "{" + keys.map(k => `${k}: ${nimValueToString(v[k])}`).join(", ") + "}";
        }
        return String(v);
      }

      if (error && typeof error === "object") {
        try {
          const keys = Object.getOwnPropertyNames(error);
          const props: Record<string, string> = {};
          for (const k of keys) {
            props[k] = nimValueToString(error[k]);
          }
          console.error(`[BROWSER_ERROR_INSPECT][${type}] Details: ${JSON.stringify(props)}`);
        } catch (e) {
          console.error(`[BROWSER_ERROR_INSPECT][${type}] Failed to inspect: ${e}`);
        }
      } else {
        // A non-object payload has no message and no stack of its own, so
        // the event's source location is all that can attribute it.
        console.error(
          `[BROWSER_ERROR_INSPECT][${type}] Non-object error: ${error}` +
            (origin ? ` (${origin})` : ""),
        );
      }
    };

    window.addEventListener("error", (event) => {
      // `event.error` is null when the browser itself raised the event
      // rather than a script: a `ResizeObserver` loop report, or a script
      // whose origin hides the exception. `message` and the location are
      // then the only record of what happened.
      // https://html.spec.whatwg.org/multipage/webappapis.html#the-errorevent-interface
      handleErr(
        event.error,
        "error",
        `message=${JSON.stringify(event.message)} ` +
          `at ${event.filename || "<no file>"}:${event.lineno}:${event.colno}`,
      );
    });
    window.addEventListener("unhandledrejection", (event) => {
      handleErr(event.reason, "unhandledrejection");
    });
  };

  page.addInitScript(initScript);
  page.evaluate(initScript).catch(() => {});

  const dumpPath = process.env.CODETRACER_TEST_CONSOLE_DUMP_PATH;
  const dumpAll = process.env.CODETRACER_TEST_LOG_ALL_CONSOLE === "1";
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      bucket.push(`[console.error] ${msg.text()}`);
    } else if (dumpAll) {
      bucket.push(`[console.${msg.type()}] ${msg.text()}`);
    }
    if (dumpPath) {
      try {
        require("node:fs").appendFileSync(
          dumpPath,
          `[console.${msg.type()}] ${msg.text()}\n`,
        );
      } catch { /* ignore */ }
    }
  });
  page.on("pageerror", (error) => {
    function nimValueToString(v: any): string {
      if (v === null || v === undefined) return "";
      if (typeof v === "string") return v;
      if (Array.isArray(v)) {
        if (v.every(x => typeof x === "number")) {
          return String.fromCharCode(...v);
        }
        return "[" + v.map(nimValueToString).join(", ") + "]";
      }
      if (typeof v === "object") {
        if (Array.isArray(v.data)) {
          return nimValueToString(v.data);
        }
        const keys = Object.keys(v);
        if (keys.length === 0) return String(v);
        return "{" + keys.map(k => `${k}: ${nimValueToString(v[k])}`).join(", ") + "}";
      }
      return String(v);
    }

    let msg = error.message || String(error);
    let stack = error.stack ?? "";
    try {
      if (error && typeof error === "object") {
        const keys = Object.getOwnPropertyNames(error);
        const props: Record<string, any> = {};
        for (const k of keys) {
          props[k] = nimValueToString((error as any)[k]);
        }
        msg += " | details: " + JSON.stringify(props);
      }
    } catch {}
    bucket.push(`[pageerror] ${msg}\n${stack}`);
    if (dumpPath) {
      try {
        require("node:fs").appendFileSync(
          dumpPath,
          `[pageerror] ${msg}\n${stack}\n`,
        );
      } catch { /* ignore */ }
    }
  });
  // Check for script-load failures that happened before we attached.
  page.evaluate(() => {
    // Report which scripts are on the page and whether they have errors
    const scripts = Array.from(document.querySelectorAll("script[src]"));
    const info = scripts.map((s) => {
      const el = s as HTMLScriptElement;
      return `${el.src} (loaded)`;
    });
    // Check if key globals exist
    const globals: Record<string, boolean> = {
      "window.electron": typeof (window as any).electron !== "undefined",
      "window.inElectron": typeof (window as any).inElectron !== "undefined",
      "window.loadScripts": typeof (window as any).loadScripts !== "undefined",
    };
    // Check CODETRACER_PREFIX from main process env (accessible via Node require)
    let ctPrefix = "(not available)";
    try {
      ctPrefix = (window as any).require("process").env.CODETRACER_PREFIX ?? "(undefined)";
    } catch { /* renderer may not have Node integration */ }
    // `console.info`, not `console.error`.  These three lines are the
    // harness describing a healthy page, not the page reporting a fault —
    // and emitting them at ERROR put the collector's own output into the
    // very bucket `verify_clean_console_on_trace_open` asserts is empty.
    // They are still captured: `CODETRACER_TEST_CONSOLE_DUMP_PATH` and
    // `CODETRACER_TEST_LOG_ALL_CONSOLE=1` record every console level, and
    // the failure dump attaches the whole bucket.
    console.info(`[diag] scripts: ${info.join("; ")}`);
    console.info(`[diag] globals: ${JSON.stringify(globals)}`);
    console.info(`[diag] CODETRACER_PREFIX: ${ctPrefix}`);
  }).catch(() => { /* page may be closed */ });
}

async function launchTraceElectron(
  sourcePath: string,
  recordingLimit = LIMIT_SMALL_RECORDING_MS,
  visualReplayTrace = false,
  recordBackend: "" | "rr" | "mcr" = "",
): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  const t0 = Date.now();

  // Support both relative paths (under test-programs/) and absolute paths
  // (from sibling recorder repos via resolveRecorderTestProgram()).
  const fullSourcePath = path.isAbsolute(sourcePath)
    ? sourcePath
    : path.join(testProgramsPath, sourcePath);
  await provisionRecorderForRecording(fullSourcePath, recordBackend || undefined);
  const { result: traceId, durationMs: recordMs } = await timed(
    "record",
    recordingLimit,
    async () => recordTestProgram(fullSourcePath, recordBackend || undefined),
  );
  if (visualReplayTrace) markTraceVisualReplayCapable(traceId);

  console.log(`# launching Electron for trace ${traceId} (record: ${recordMs}ms)`);

  // On Windows, ct.exe spawns Electron as a child process (no execv),
  // which prevents Playwright from connecting via CDP.  Launch Electron
  // directly and pass the app directory so it picks up package.json.
  const launchExe = (isWindows && electronExePath) ? electronExePath : launchCt();
  const launchArgs = (isWindows && electronExePath) ? [codetracerPrefix] : [];

  const { result: app, durationMs: launchMs } = await timed(
    "electron launch",
    LIMIT_ELECTRON_LAUNCH_MS,
    async () =>
      _electron.launch({
        executablePath: launchExe,
        cwd: codetracerInstallDir,
        args: launchArgs,
        env: makeCleanEnv({
          CODETRACER_CALLER_PID: process.pid.toString(),
          // M-REC-6: env-var renamed from CODETRACER_TRACE_ID.  Carries
          // the recording-id string the Electron index process picks up
          // in src/frontend/index/args.nim.
          CODETRACER_RECORDING_ID: traceId,
        }),
      }),
  );

  const consoleErrors: string[] = [];
  const mainProcessOutput: string[] = [];
  attachMainProcessCapture(app, mainProcessOutput);
  for (const window of app.windows())
    attachErrorCollectors(window, consoleErrors);
  app.on("window", (window) => attachErrorCollectors(window, consoleErrors));
  const { result: page, durationMs: windowMs } = await timed(
    "first window",
    LIMIT_FIRST_WINDOW_MS,
    async () => getEditorWindow(app),
  );
  if (pageConsoleErrors.get(page) !== consoleErrors) {
    attachErrorCollectors(page, consoleErrors);
  }

  const totalMs = Date.now() - t0;
  console.log(`#   electron: ${launchMs}ms  window: ${windowMs}ms  total setup: ${totalMs}ms`);
  if (totalMs > LIMIT_TOTAL_SETUP_MS) {
    console.warn(`# WARNING: total setup ${totalMs}ms exceeds limit ${LIMIT_TOTAL_SETUP_MS}ms`);
  }

  return {
    page,
    electronApp: app,
    consoleErrors,
    mainProcessOutput,
    teardown: async () => {
      try {
        const pid = app.process().pid;
        if (pid) {
          killProcessTree(pid);
        }
      } catch (_e) {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

/**
 * Import a pre-recorded trace folder into CodeTracer's database via the
 * `ct host` CLI.  Returns the assigned recording id which the Electron
 * launcher then opens via CODETRACER_RECORDING_ID (M-REC-6).
 *
 * Used by `launchTraceFolderElectron` to support the BEAM (and other
 * recorder-bundle) tests that want to drive the GUI against a CTFS trace
 * produced offline rather than recording on demand.
 */
function importTraceFolder(traceFolder: string): string {
  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    [
      "host",
      "--trace-path",
      traceFolder,
      "0",
      "--port=0",
      "--idle-timeout=1ms",
      "--backend-socket-port=0",
      "--frontend-socket=0",
    ],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
      env: makeCleanEnv({
        CODETRACER_IN_UI_TEST: "1",
      }),
      timeout: 15_000,
      windowsHide: true,
    },
  );

  const output = `${ctProcess.stdout ?? ""}\n${ctProcess.stderr ?? ""}`;
  // M-REC-2/3: `ct host` assigns a UUIDv7 *string* recording id, not the
  // pre-1.0 integer id.  Match the canonical 8-4-4-4-12 hex form rather
  // than `\d+`, which previously captured only the leading digits of the
  // UUID (e.g. "019" from "019e4843-...") and produced a bogus integer.
  const match = output.match(
    /imported as trace id\s+([0-9a-fA-F-]{36})/,
  );
  if (!match) {
    throw new Error(
      `ct host did not import trace folder: error=${ctProcess.error}; status=${ctProcess.status}; signal=${ctProcess.signal}\n` +
      `stderr: ${ctProcess.stderr}\nstdout: ${ctProcess.stdout}`,
    );
  }

  const traceId = match[1];
  console.log(`# imported trace folder ${traceFolder} with id ${traceId}`);
  return traceId;
}

/** Restart an owned test app using the fixture's process-tree cleanup, keeping
 * its isolated profile and saved layout. Graceful app.close() can wait for
 * debugger children; the normal fixture teardown uses this same cleanup. */
export async function restartTraceFolderElectron(
  app: ElectronApplication,
  traceFolderPath: string,
): Promise<LaunchResult> {
  const closed = app.waitForEvent("close");
  const pid = app.process().pid;
  if (!pid) throw new Error("Cannot restart an Electron app without its process");
  killProcessTree(pid);
  await closed;
  return launchTraceFolderElectron(traceFolderPath);
}

/**
 * Launch Electron against a pre-existing CTFS trace folder rather than
 * recording on demand.  Used by the BEAM (Elixir/Erlang) UI smoke specs that
 * receive bundles from `prepare-beam-fixtures.sh` in the recorder repo.
 *
 * The trace folder must contain a CTFS `.ct` container (M-REC-1.5: the
 * legacy `trace_metadata.json` sidecar was retired).  The folder is
 * imported via `ct host` to obtain a stable recording id, then Electron is
 * launched with `CODETRACER_RECORDING_ID` (M-REC-6) so the GUI opens
 * that specific trace.
 */
async function launchTraceFolderElectron(traceFolderPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  const t0 = Date.now();
  const traceFolder = path.resolve(traceFolderPath);
  const hasCtFile = fs.readdirSync(traceFolder).some((n) => n.endsWith(".ct"));
  if (!hasCtFile) {
    throw new Error(`trace folder is missing a CTFS .ct container: ${traceFolder}`);
  }

  const { result: traceId, durationMs: importMs } = await timed(
    "import trace folder",
    LIMIT_SMALL_RECORDING_MS,
    async () => importTraceFolder(traceFolder),
  );

  const launchExe = (isWindows && electronExePath) ? electronExePath : launchCt();
  const launchArgs = (isWindows && electronExePath) ? [codetracerPrefix] : [];

  const { result: app, durationMs: launchMs } = await timed(
    "electron launch trace folder",
    LIMIT_ELECTRON_LAUNCH_MS,
    async () =>
      _electron.launch({
        executablePath: launchExe,
        cwd: codetracerInstallDir,
        args: launchArgs,
        env: makeCleanEnv({
          CODETRACER_CALLER_PID: process.pid.toString(),
          // M-REC-6: env-var renamed from CODETRACER_TRACE_ID.  Carries
          // the recording-id string the Electron index process picks up
          // in src/frontend/index/args.nim.
          CODETRACER_RECORDING_ID: traceId.toString(),
        }),
      }),
  );

  const consoleErrors: string[] = [];
  const mainProcessOutput: string[] = [];
  attachMainProcessCapture(app, mainProcessOutput);
  const { result: page, durationMs: windowMs } = await timed(
    "first window",
    LIMIT_FIRST_WINDOW_MS,
    async () => getEditorWindow(app),
  );
  attachErrorCollectors(page, consoleErrors);
  const totalMs = Date.now() - t0;
  console.log(`# launched Electron for trace folder ${traceFolder} (trace ${traceId}; import: ${importMs}ms electron: ${launchMs}ms window: ${windowMs}ms total: ${totalMs}ms)`);

  return {
    page,
    electronApp: app,
    consoleErrors,
    mainProcessOutput,
    teardown: async () => {
      try {
        const pid = app.process().pid;
        if (pid) {
          killProcessTree(pid);
        }
      } catch (_e) {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchTraceWeb(
  sourcePath: string,
  recordingLimit = LIMIT_SMALL_RECORDING_MS,
  visualReplayTrace = false,
): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  const t0 = Date.now();

  // Support both relative paths (under test-programs/) and absolute paths
  // (from sibling recorder repos via resolveRecorderTestProgram()).
  const fullSourcePath = path.isAbsolute(sourcePath)
    ? sourcePath
    : path.join(testProgramsPath, sourcePath);
  await provisionRecorderForRecording(fullSourcePath);
  const { result: traceId, durationMs: recordMs } = await timed(
    "record",
    recordingLimit,
    async () => recordTestProgram(fullSourcePath),
  );
  if (visualReplayTrace) markTraceVisualReplayCapable(traceId);

  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();

  console.log(
    `# launching ct host for trace ${traceId} on port ${httpPort} (record: ${recordMs}ms)`,
  );

  const ctProcess = childProcess.spawn(
    codetracerPath,
    [
      "host",
      traceId,
      `--port=${httpPort}`,
      `--backend-socket-port=${backendPort}`,
      `--frontend-socket=${backendPort}`,
    ],
    {
      cwd: codetracerInstallDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );

  // Capture ct host output for diagnostics.
  const ctStderr: string[] = [];
  const ctStdout: string[] = [];
  ctProcess.stdout?.on("data", (chunk: Buffer) => {
    ctStdout.push(chunk.toString());
  });
  ctProcess.stderr?.on("data", (chunk: Buffer) => {
    ctStderr.push(chunk.toString());
  });

  const chromiumPath = resolveChromiumPath();
  const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
    .split(/\s+/)
    .filter(Boolean);
  const browser = await chromium.launch({
    executablePath: chromiumPath,
    args: extraArgs,
  });

  const context = await browser.newContext({
    ...(process.env.RECORD_VIDEO === "1" && {
      recordVideo: {
        dir: path.join(codetracerInstallDir, "test-results", "videos"),
        size: { width: 1920, height: 1080 },
      },
      viewport: { width: 1920, height: 1080 },
    }),
  });
  await installTestMovementCounterHiding(context);

  const consoleErrors: string[] = [];
  const page = await context.newPage();
  attachErrorCollectors(page, consoleErrors);

  // Wait for ct host to become ready with retry-based navigation.
  const tConnect0 = Date.now();
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(ctHostPageUrl(httpPort), {
        timeout: GOTO_TIMEOUT_MS,
      });
      connected = true;
    } catch {
      if (attempt < MAX_CONNECT_ATTEMPTS) {
        console.log(`  attempt ${attempt}/${MAX_CONNECT_ATTEMPTS} failed, retrying...`);
        await sleep(RETRY_DELAY_MS);
      }
    }
  }
  const connectMs = Date.now() - tConnect0;
  if (!connected) {
    console.error(`ct host stdout:\n${ctStdout.join("")}`);
    console.error(`ct host stderr:\n${ctStderr.join("")}`);
    ctProcess.kill();
    await browser.close();
    throw new Error(
      `Failed to connect to ct host on port ${httpPort} after ${MAX_CONNECT_ATTEMPTS} attempts`,
    );
  }
  const totalMs = Date.now() - t0;
  console.log(`#   ct host connect: ${connectMs}ms  total web setup: ${totalMs}ms`);
  if (connectMs > LIMIT_CT_HOST_STARTUP_MS) {
    console.warn(`# WARNING: ct host connect ${connectMs}ms exceeds limit ${LIMIT_CT_HOST_STARTUP_MS}ms`);
  }

  return {
    page,
    electronApp: null,
    consoleErrors,
    mainProcessOutput: ctStderr,
    teardown: async () => {
      const pid = ctProcess.pid;
      if (pid) {
        killProcessTree(pid);
      }
      await sleep(PORT_RELEASE_DELAY_MS);
      try {
        await browser.close();
      } catch {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchTracePathWeb(tracePath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  const t0 = Date.now();

  if (!fs.existsSync(tracePath)) {
    throw new Error(`visualReplayTracePath does not exist: ${tracePath}`);
  }

  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();

  console.log(`# launching ct host for trace path ${tracePath} on port ${httpPort}`);

  // When the ct-host stdout/stderr is being captured for diagnostics, also
  // capture the ct_gfx_player's stderr (which is otherwise invisible — it
  // lives inside the renderer's process tree).  Derive the path from the
  // ct-host log so the two sit next to each other; respect an explicit
  // override if the operator already supplied one.
  const ctHostLogPath = process.env.CODETRACER_TEST_CT_HOST_OUTPUT_PATH;
  if (ctHostLogPath && !process.env.CODETRACER_TEST_GFX_PLAYER_OUTPUT_PATH) {
    process.env.CODETRACER_TEST_GFX_PLAYER_OUTPUT_PATH =
      ctHostLogPath.replace(/\.log$/i, "") + ".gfx-player.log";
  }

  const ctProcess = childProcess.spawn(
    codetracerPath,
    [
      "host",
      `--trace-path=${tracePath}`,
      `--port=${httpPort}`,
      `--backend-socket-port=${backendPort}`,
      `--frontend-socket=${backendPort}`,
    ],
    {
      cwd: codetracerInstallDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );

  const ctStderr: string[] = [];
  const ctStdout: string[] = [];
  // Optional realtime sink for ct host's stdout+stderr so a debugger can
  // tail the trace-path import / server bootstrap output before the
  // test teardown scrubs the temp dir.  Gated by env var; no-op when
  // unset, so production runs are unchanged.
  const ctOutputDumpPath = process.env.CODETRACER_TEST_CT_HOST_OUTPUT_PATH;
  const appendCtOutput = (label: string, chunk: string) => {
    if (!ctOutputDumpPath) return;
    try {
      require("node:fs").appendFileSync(
        ctOutputDumpPath,
        `[${label}] ${chunk}`,
      );
    } catch { /* ignore */ }
  };
  ctProcess.stdout?.on("data", (chunk: Buffer) => {
    const text = chunk.toString();
    ctStdout.push(text);
    appendCtOutput("ct.stdout", text);
  });
  ctProcess.stderr?.on("data", (chunk: Buffer) => {
    const text = chunk.toString();
    ctStderr.push(text);
    appendCtOutput("ct.stderr", text);
  });

  await copyCompanionGfxStreamAfterTracePathImport(tracePath, ctStdout, ctProcess);

  const chromiumPath = resolveChromiumPath();
  const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
    .split(/\s+/)
    .filter(Boolean);
  const browser = await chromium.launch({
    executablePath: chromiumPath,
    args: extraArgs,
  });

  const context = await browser.newContext({
    ...(process.env.RECORD_VIDEO === "1" && {
      recordVideo: {
        dir: path.join(codetracerInstallDir, "test-results", "videos"),
        size: { width: 1920, height: 1080 },
      },
      viewport: { width: 1920, height: 1080 },
    }),
  });
  await installTestMovementCounterHiding(context);

  const consoleErrors: string[] = [];
  const page = await context.newPage();
  attachErrorCollectors(page, consoleErrors);

  const tConnect0 = Date.now();
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(ctHostPageUrl(httpPort), {
        timeout: GOTO_TIMEOUT_MS,
      });
      connected = true;
    } catch {
      if (attempt < MAX_CONNECT_ATTEMPTS) {
        console.log(`  attempt ${attempt}/${MAX_CONNECT_ATTEMPTS} failed, retrying...`);
        await sleep(RETRY_DELAY_MS);
      }
    }
  }
  const connectMs = Date.now() - tConnect0;
  if (!connected) {
    console.error(`ct host stdout:\n${ctStdout.join("")}`);
    console.error(`ct host stderr:\n${ctStderr.join("")}`);
    ctProcess.kill();
    await browser.close();
    throw new Error(
      `Failed to connect to ct host on port ${httpPort} after ${MAX_CONNECT_ATTEMPTS} attempts`,
    );
  }

  const totalMs = Date.now() - t0;
  console.log(`#   ct host connect: ${connectMs}ms  total trace-path setup: ${totalMs}ms`);

  return {
    page,
    electronApp: null,
    consoleErrors,
    mainProcessOutput: ctStderr,
    teardown: async () => {
      const pid = ctProcess.pid;
      if (pid) {
        killProcessTree(pid);
      }
      await sleep(PORT_RELEASE_DELAY_MS);
      try {
        await browser.close();
      } catch {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchWelcomeScreen(
  newTracePolicy: "window" | "tab" = "window",
  testOpenFolderDialogPath = "",
): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  console.log("# launching welcome screen");

  const welcomeExe = (isWindows && electronExePath) ? electronExePath : launchCt();
  const welcomeArgs = (isWindows && electronExePath) ? [codetracerPrefix] : [];

  const app = await _electron.launch({
    executablePath: welcomeExe,
    cwd: codetracerInstallDir,
    args: welcomeArgs,
    env: makeCleanEnv({
      CODETRACER_NEW_TRACE_POLICY: newTracePolicy,
      ...(testOpenFolderDialogPath
        ? { CODETRACER_TEST_OPEN_FOLDER_DIALOG_PATH: testOpenFolderDialogPath }
        : {}),
    }),
  });

  const consoleErrors: string[] = [];
  const mainProcessOutput: string[] = [];
  attachMainProcessCapture(app, mainProcessOutput);
  const page = await getEditorWindow(app);
  attachErrorCollectors(page, consoleErrors);

  return {
    page,
    electronApp: app,
    consoleErrors,
    mainProcessOutput,
    teardown: async () => {
      try {
        const pid = app.process().pid;
        if (pid) {
          killProcessTree(pid);
        }
      } catch (_e) {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchEditMode(
  folderPath: string,
  workingDirectory: string = codetracerInstallDir,
  newTracePolicy: "window" | "tab" = "window",
): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  console.log(`# launching edit mode for ${folderPath}`);

  const editExe = (isWindows && electronExePath) ? electronExePath : launchCt();
  const editArgs = (isWindows && electronExePath)
    ? [codetracerPrefix, "edit", folderPath]
    : ["edit", folderPath];

  const app = await _electron.launch({
    executablePath: editExe,
    cwd: workingDirectory,
    args: editArgs,
    env: makeCleanEnv({ CODETRACER_NEW_TRACE_POLICY: newTracePolicy }),
  });

  const consoleErrors: string[] = [];
  const mainProcessOutput: string[] = [];
  attachMainProcessCapture(app, mainProcessOutput);
  const page = await getEditorWindow(app);
  attachErrorCollectors(page, consoleErrors);

  return {
    page,
    electronApp: app,
    consoleErrors,
    mainProcessOutput,
    teardown: async () => {
      try {
        const pid = app.process().pid;
        if (pid) {
          killProcessTree(pid);
        }
      } catch (_e) {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchDeepReview(jsonPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  clearElectronSingletonLocks();
  console.log(`# launching deepreview mode for ${jsonPath}`);

  // RV-1: the user-facing spelling is `ct review <PATH>`; the retired
  // `ct --deepreview <PATH>` option now fails with a pointer to it.  The
  // Windows branch launches ELECTRON directly rather than `ct`, so it passes
  // the internal ct -> Electron argument that `src/frontend/index/args.nim`
  // parses, which is unchanged and is not the retired option.
  const drExe = (isWindows && electronExePath) ? electronExePath : launchCt();
  const drArgs = (isWindows && electronExePath)
    ? [codetracerPrefix, "--deepreview", jsonPath]
    : ["review", jsonPath];

  const app = await _electron.launch({
    executablePath: drExe,
    cwd: codetracerInstallDir,
    args: drArgs,
    env: makeCleanEnv(),
  });

  const consoleErrors: string[] = [];
  const mainProcessOutput: string[] = [];
  attachMainProcessCapture(app, mainProcessOutput);
  const page = await getEditorWindow(app);
  attachErrorCollectors(page, consoleErrors);

  return {
    page,
    electronApp: app,
    consoleErrors,
    mainProcessOutput,
    teardown: async () => {
      try {
        const pid = app.process().pid;
        if (pid) {
          killProcessTree(pid);
        }
      } catch (_e) {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

// ---------------------------------------------------------------------------
// Fixture definition
// ---------------------------------------------------------------------------

export const test = base.extend<
  CodetracerFixtures & CodetracerOptions,
  CodetracerWorkerFixtures
>({
  // Options (set via test.use)
  // Run-wide default from CODETRACER_TEST_IN_BROWSER ("1" = web), read once
  // when this module loads; an invalid value throws here, failing the run
  // instead of quietly running Electron. `test.use({ deploymentMode })` in a
  // spec still overrides it.
  deploymentMode: [deploymentModeFromEnv(), { option: true }],
  sourcePath: ["", { option: true }],
  launchMode: ["trace" as LaunchMode, { option: true }],
  newTracePolicy: ["window" as "window" | "tab", { option: true }],
  testOpenFolderDialogPath: ["", { option: true }],
  editFolderPath: ["", { option: true }],
  editWorkingDirectory: [codetracerInstallDir, { option: true }],
  deepreviewJsonPath: ["", { option: true }],
  visualReplayTrace: [false, { option: true }],
  recordBackend: ["" as "" | "rr" | "mcr", { option: true }],
  visualReplayTracePath: ["", { option: true }],
  preserveAutoHideState: [false, { option: true }],
  editLayoutPath: ["", { option: true }],
  preserveEditLayout: [false, { option: true }],
  bundledLayout: [false, { option: true }],
  preserveUserLayout: [false, { option: true }],
  // `CODETRACER_TEST_PREFIX` runs EVERY spec against a prepared prefix (e.g.
  // one from `scripts/plat45-desktop-prefix.sh` carrying this checkout's
  // desktop JavaScript) instead of the build's own; a spec's `test.use` wins.
  codetracerPrefixOverride: [process.env.CODETRACER_TEST_PREFIX ?? "", { option: true }],
  configTheme: ["", { option: true }],
  launchEnv: [{}, { option: true }],
  rendererInitScript: ["", { option: true }],
  showTestMovementCounter: [false, { option: true }],

  // Fixtures
  _workerCleanup: [
    async ({}, use) => {
      // Kill any stray backend processes left over from previous runs.
      killStrayCodetracerProcesses();
      await use();
      // Kill any backend processes that may have leaked from this worker.
      killStrayCodetracerProcesses();
      // Restore the worker-local layout backup, if any.  GUI tests run with an
      // isolated XDG_CONFIG_HOME so layout resets and shutdown saves cannot
      // disturb a developer's interactive CodeTracer layout.
      try {
        restoreUserLayout();
      } catch (ex) {
        console.warn(`fixtures: restoreUserLayout failed: ${(ex as Error).message}`);
      }
      // Also registered on process exit for importers without this fixture.
      // Successful removals relinquish ownership; exit retries only failures.
      removeOwnedGuiTestHomes();
      if (originalXdgConfigHome === undefined) {
        delete process.env.XDG_CONFIG_HOME;
      } else {
        process.env.XDG_CONFIG_HOME = originalXdgConfigHome;
      }
      if (originalCodetracerHome === undefined) {
        delete process.env.CODETRACER_HOME;
      } else {
        process.env.CODETRACER_HOME = originalCodetracerHome;
      }
      // Killing Electron with SIGKILL leaves Playwright's internal CDP
      // pipe handles open, preventing the worker from exiting.  Force
      // exit after a brief delay so test results can still be reported.
      setTimeout(() => process.exit(0), 2000);
    },
    { scope: "worker" as const, auto: true },
  ],

  electronApp: [
    async ({ ctPage }, use) => {
      // DEPENDS ON `ctPage` ON PURPOSE — see `pageElectronApps`. Resolving
      // `ctPage` first is what runs the launcher that registers the page, and
      // is the difference between this fixture and the `use(null)` it replaced.
      await use(pageElectronApps.get(ctPage) ?? null);
    },
    { scope: "test" },
  ],

  consoleErrors: [
    async ({ ctPage }, use) => {
      const bucket = pageConsoleErrors.get(ctPage);
      if (bucket === undefined) {
        throw new Error(
          "no console-error collector is attached to this page — every " +
            "launch mode must call attachErrorCollectors()",
        );
      }
      await use(bucket);
    },
    { scope: "test" },
  ],

  ctPage: [
    async (
      {
        deploymentMode,
        sourcePath,
        launchMode,
        editFolderPath,
        editWorkingDirectory,
        deepreviewJsonPath,
        visualReplayTrace,
        recordBackend,
        visualReplayTracePath,
        newTracePolicy,
        testOpenFolderDialogPath,
        preserveAutoHideState,
        editLayoutPath: seedEditLayoutFrom,
        preserveEditLayout,
        bundledLayout,
        preserveUserLayout,
        codetracerPrefixOverride,
        configTheme,
        launchEnv,
        rendererInitScript,
        showTestMovementCounter,
      },
      use,
      testInfo,
    ) => {
      let result: LaunchResult;
      activePrefixOverride = codetracerPrefixOverride;
      activeLaunchEnv = launchEnv;
      activeRendererInitScript = rendererInitScript;
      activeShowTestMovementCounter = showTestMovementCounter;

      // Ensure each test starts from a known saved layout in the worker-local
      // config directory.  Earlier tests in the same worker may have mutated
      // it (e.g. auto-hide pin-to-edge, build/problems panel pop-out, layout
      // resilience); without this reset that layout persists via
      // default_layout.json and later tests see a stale arrangement.
      //
      // By default the saved layout is REMOVED, so the launch takes the
      // product's own first-run path and opens the Debug mode's default —
      // what a user sees. `bundledLayout` installs the raw bundled tree
      // instead, `preserveUserLayout` keeps what an earlier launch saved
      // (`layout-reset.prepareUserLayout`). Outside the try below on purpose:
      // a contradictory option pair, or a bundled tree that cannot be
      // installed, would otherwise only be logged and the spec would run on a
      // layout it did not ask for.
      prepareUserLayout({ bundledLayout, preserveUserLayout }, codetracerInstallDir);
      try {
        ensureDefaultConfig(codetracerInstallDir, configTheme);
        // The saved auto-hide state is the other half of the saved
        // arrangement — see `resetAutoHideState`. Without this a test that
        // pins a panel leaves it pinned for every later test in the worker.
        if (!preserveAutoHideState) {
          resetAutoHideState();
        }
        // ...and the saved EDIT layout is the third piece. Since RV-2 a
        // `ct review` launch reads `default_edit_layout.json`, so an
        // edit-mode test earlier in this worker would otherwise decide which
        // layout a later review opens — an ordering dependence, and the one
        // that hid a missing AGENT ACTIVITY panel from the whole suite.
        const seedsEditLayout = seedEditLayoutFrom.length > 0;
        if (!preserveEditLayout && !seedsEditLayout) {
          resetEditLayout();
        }
        if (seedsEditLayout) {
          // Launch over a layout a PREVIOUS session left behind. Reset first
          // so a stale `.broken` sibling from an earlier test cannot confuse
          // the recovery assertions.
          resetEditLayout();
          seedEditLayout(seedEditLayoutFrom);
        }
      } catch (ex) {
        // Non-fatal: a missing bundled config file would surface as a
        // launch-time error anyway.  Log and continue so the test still
        // produces a meaningful failure.
        console.warn(`fixtures: resetting the saved arrangement failed: ${(ex as Error).message}`);
      }

      const needsRR = sourcePath ? requiresRR(sourcePath) : false;
      const recordingLimit = needsRR ? LIMIT_RR_RECORDING_MS : LIMIT_SMALL_RECORDING_MS;

      if (needsRR && !process.env.CODETRACER_RR_BACKEND_PATH && !process.env.CODETRACER_RR_BACKEND_PRESENT) {
        testInfo.skip(true, "requires ct-native-replay (RR-based language)");
      }
      if (needsRR && process.env.CODETRACER_DB_TESTS_ONLY === "1") {
        testInfo.skip(true, "RR test skipped — running DB-based tests only");
      }
      if (!needsRR && process.env.CODETRACER_RR_TESTS_ONLY === "1") {
        testInfo.skip(true, "DB-based test skipped — running RR tests only");
      }

      // RR-based tests need more time: compile + rr/ttd record + Electron + UI.
      // TTD (Windows) recording has much higher overhead than RR.
      // A floor, never a cut: a spec that set a longer timeout of its own
      // (`c-cross-thread-copy.spec.ts`: 240 s) used to be cut to 120 s here.
      if (needsRR) {
        test.setTimeout(Math.max(testInfo.timeout, process.platform === "win32" ? 720_000 : 120_000));
      }

      switch (launchMode) {
        case "trace": {
          if (visualReplayTracePath) {
            if (deploymentMode !== "web") {
              throw new Error("visualReplayTracePath is currently supported only in web deploymentMode");
            }
            result = await launchTracePathWeb(visualReplayTracePath);
            break;
          }
          if (!sourcePath) {
            throw new Error(
              "sourcePath must be set via test.use() for trace launch mode",
            );
          }
          if (deploymentMode === "web") {
            result = await launchTraceWeb(sourcePath, recordingLimit, visualReplayTrace);
          } else {
            result = await launchTraceElectron(sourcePath, recordingLimit, visualReplayTrace, recordBackend);
          }
          break;
        }
        case "trace-folder": {
          if (!sourcePath) {
            throw new Error(
              "sourcePath must be set to a trace folder via test.use() for trace-folder launch mode",
            );
          }
          if (deploymentMode === "web") {
            throw new Error("trace-folder launch mode is only implemented for Electron");
          }
          result = await launchTraceFolderElectron(sourcePath);
          break;
        }
        case "welcome": {
          result = await launchWelcomeScreen(newTracePolicy, testOpenFolderDialogPath);
          break;
        }
        case "edit": {
          if (!editFolderPath) {
            throw new Error(
              "editFolderPath must be set via test.use() for edit launch mode",
            );
          }
          result = await launchEditMode(editFolderPath, editWorkingDirectory, newTracePolicy);
          break;
        }
        case "deepreview": {
          if (!deepreviewJsonPath) {
            throw new Error(
              "deepreviewJsonPath must be set via test.use() for deepreview launch mode",
            );
          }
          result = await launchDeepReview(deepreviewJsonPath);
          break;
        }
        default:
          throw new Error(`Unknown launch mode: ${launchMode as string}`);
      }

      try {
        if (result.electronApp !== null) {
          // REGISTER BEFORE `use`. The `electronApp` fixture depends on this
          // one, so Playwright resolves this body to its `use` call first and
          // reads the map afterwards; registering later would hand `null` to
          // the spec that asked for it.
          pageElectronApps.set(result.page, result.electronApp);
          await assertCoreElectronStylesLoaded(result.page);
        }

        await use(result.page);
      } finally {
        // A PASSING test can still have written corrupt reactive state: a
        // top-level `string` signal written `undefined` stores it silently and
        // never reaches the console. So an investigation needs the grouped
        // report even on green -- `CT_REPORT_JS_ERRORS=1` asks for it.
        if (process.env.CT_REPORT_JS_ERRORS === "1") {
          for (const line of formatErrorGroups(result.consoleErrors)) {
            console.log(line);
          }
        }
        // Capture diagnostics on test failure (DOM snapshot, summary, error details)
        if (testInfo.status !== testInfo.expectedStatus) {
          try {
            const url = result.page.url();
            const bodyText = await result.page.evaluate(() => {
              const body = document.body;
              return body ? body.innerHTML.substring(0, 500) : "(no body)";
            }).catch(() => "(page closed)");
            console.log(`  FAIL url: ${url}`);
            console.log(`  FAIL body: ${bodyText}`);
            // Check if key script files loaded
            const scriptStatus = await result.page.evaluate(() => {
              const scripts = Array.from(document.querySelectorAll("script[src]"));
              return scripts.map((s) => (s as HTMLScriptElement).src).join(", ");
            }).catch(() => "(page closed)");
            console.log(`  FAIL scripts: ${scriptStatus}`);
          } catch { /* page may be closed */ }
          // Report collected JS errors from the renderer.
          //
          // A COUNT cannot distinguish one cause from many. A single throw on
          // a reactive write re-fires on every subsequent write, so "1257 JS
          // errors" is one defect reported 1257 times -- and printing the
          // first 50 of them prints the same line 50 times while the *second*
          // distinct fault, the one that would name the real cause, scrolls
          // past unseen. Group by signature first, then print the FIRST
          // occurrence of each group with its stack.
          for (const line of formatErrorGroups(result.consoleErrors)) {
            console.log(line);
          }
          // Report main process output (backend-manager, socket, init flow)
          if (result.mainProcessOutput.length > 0) {
            console.log(`  FAIL main process output (${result.mainProcessOutput.length} lines):`);
            for (const line of result.mainProcessOutput.slice(0, 100)) {
              console.log(`    ${line}`);
            }
          }
          await captureFailureDiagnostics(result.page, testInfo, result.consoleErrors);
        }
        await result.teardown();
      }
    },
    { scope: "test" },
  ],
});

export { expect } from "@playwright/test";

// Re-export path constants for tests that need them
export {
  codetracerInstallDir,
  codetracerPrefix,
  testProgramsPath,
  codetracerPath,
};

// Export recordTestProgram so multi-trace tests can pre-record additional
// programs and load them into new sessions via IPC, and traceFolderForId so
// they can name the folder a recording id was written to (a session manifest
// references its traces by folder).
export { recordTestProgram, traceFolderForId };

// Re-export performance timing utilities for use in tests
export { timed, timedVoid } from "./performance-limits";
export {
  LIMIT_STEP_MS,
  LIMIT_NAVIGATE_MS,
  LIMIT_TAB_SWITCH_MS,
  LIMIT_CONTEXT_MENU_MS,
  LIMIT_SCRATCHPAD_UPDATE_MS,
  LIMIT_STATE_DISPLAY_MS,
  LIMIT_EVENT_LOG_POPULATE_MS,
  LIMIT_RELOAD_RECONNECT_MS,
} from "./performance-limits";

// ---------------------------------------------------------------------------
// Shared test utilities
// ---------------------------------------------------------------------------

export class CodetracerTestError extends Error {
  constructor(msg: string) {
    super(msg);
    Object.setPrototypeOf(this, CodetracerTestError.prototype);
  }
}

/** Promise-based delay. */
export function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Wall-clock budget for a launch to reach its entry location.
 *
 * Derived from measurement — see the comment inside `readyOnEntryTest` and
 * Value-Origin-Tracking milestone M46.
 */
export const READY_ON_ENTRY_BUDGET_MS = 30_000;

/**
 * The readiness signal: the editor gutter cell that carries the
 * execution-pointer arrow.
 *
 * `EditorViewComponent.onCompleteMove` (`src/frontend/ui/editor.nim`) stores
 * the debugger's location in the editor and repaints its gutter;
 * `editorLineNumber` (`src/frontend/ui/trace.nim`) then marks the line the
 * replay is stopped on with `gutter-highlight-active`
 * (`lib/monaco_appearance.editorGutterLineHtml`), which the stylesheet draws as
 * the arrow left of the line number.  The marker div itself is 0px tall (the
 * arrow is its absolutely positioned `:before`), so the wait is on the gutter
 * cell that holds it, which has the line's box.
 */
export const READY_ON_ENTRY_SELECTOR =
  ".monaco-editor .gutter:has(> .gutter-highlight-active)";

/** Wait until the session has reached its entry location.
 *
 * READY MEANS: the trace opened, the debugger reported an entry location,
 * and the UI is laid out and hit-testable.  The signal is the one a user
 * reads that from: an editor showing the entry file, with the
 * execution-pointer arrow on the entry line.  `READY_ON_ENTRY_SELECTOR` names
 * the exact element and the code that draws it.  The arrow is drawn by the
 * same code path that receives the entry location (`ct/complete-move` →
 * `EditorViewComponent.onCompleteMove` → `editorLineNumber`), not by a test
 * hook, so it cannot appear before the location has arrived.
 *
 * WHY NOT THE STATUS BAR ANY MORE.  Until 2026-11-11 this waited for the
 * footer's `.location-path` readout to be visible.  The status-bar design
 * hides that readout on purpose (`status_bar.styl`, "HIDDEN FOR NOW",
 * `docs/UI-Design-Decisions.md` D-05, 2026-10-15), and on 2026-11-11 the
 * decision was to keep it hidden and move readiness to the editor
 * (codetracer-pm `spec/Planned-Features/Auto-Hide-Panes.md` §3.1, and the issue
 * `2026-10-20-ready-on-entry-waits-for-a-location-path-the-status-bar-now-hides-by-design.md`).
 * The hidden `.location-path` is still rendered and still carries the
 * location text, so `StatusBar.location()` keeps working; it just no longer
 * says anything about what the user can see.  The footer's own visibility is
 * guarded by `tests/status-bar/footer-visibility-css-guard.spec.ts` and
 * `status-bar-footer-contract.spec.ts`, which never depended on this wait.
 *
 * IT IS A VISIBILITY WAIT, NOT AN ATTACHMENT WAIT, for the reason it always
 * was: an element can be in the DOM with the right content long before it has
 * a box, and `state: "attached"` would call that ready.  The `b27da3947` and
 * `51a3e820e` regressions (a blanket `display: none !important` on the
 * footer) were caught by exactly this property of the old wait.  A rule that
 * hides the editor, its margin or the arrow's gutter cell fails this one the
 * same way, and `readinessDiagnosis` says which.  Playwright's visibility is
 * box-and-`visibility`, so `opacity: 0` or an off-screen box still passes.
 */
export async function readyOnEntryTest(p: Page): Promise<void> {
  // One wait, with a budget taken from the measured launch time.
  //
  // WHAT THIS WAIT COSTS, MEASURED.  Nothing on the page can show the entry
  // location until the frontend has loaded its bundle, built its view models
  // and driven DAP to the entry location, so the appearance of the signal IS
  // the end of the launch.  Sampled (on the earlier footer signal, which the
  // same `ct/complete-move` renders) over 40 consecutive launches of
  // `statement_step*` on this host at load average 25-49 on 32 cores: min
  // 6.93s, median 8.04s, p90 10.60s, max 13.71s.  A single 15s budget
  // therefore sat about 1.1x above the observed maximum, which is why roughly
  // one launch in twelve used to time out here.
  //
  // The budget is per-launch wall clock, not CPU, and it degrades with
  // contention rather than with core count: pinning a run to 8 of the 32
  // cores changed nothing (7.0-9.1s), while pinning it to 4 cores that were
  // also carrying 12 spinners pushed every one of 8 launches past 15s, with
  // launch-to-entry totals of 17.3s to 29.6s.  The box this suite runs on
  // carries the developer's own CI and has been observed at load average
  // 185.  So 30s is not padding: it is roughly 3.7x the median and 1.0-1.7x
  // the worst case actually reproduced under contention.  The `# timing`
  // line below reports every launch's margin against it.
  //
  // WHAT IT IS NOT.  Until 2026-08-06 this was two 15s attempts with a
  // "fresh" locator, on the theory that Playwright's poll stalls and a new
  // locator unsticks it.  Both halves of that were wrong and the evidence is
  // in Value-Origin-Tracking milestone M46: a `Locator` holds nothing but its
  // frame and selector (`client/locator.ts`), so a fresh one is the identical
  // call, and `DEBUG=pw:protocol` on a reproduced failure shows the poll
  // running normally throughout.
  //
  // `filter({ visible: true }).first()`: several editors can carry the
  // arrow at once (a split, a session in a background tab, an editor tab
  // that is not in front), and only one that the user can see counts.
  const started = Date.now();
  try {
    await p
      .locator(READY_ON_ENTRY_SELECTOR)
      .filter({ visible: true })
      .first()
      .waitFor({ state: "visible", timeout: READY_ON_ENTRY_BUDGET_MS });
  } catch (timeout) {
    throw new CodetracerTestError(
      `${(timeout as Error).message}\n\n${await readinessDiagnosis(p)}`,
    );
  }
  // Report the margin on every launch, so the budget above stays checkable
  // instead of drifting back into the mystery it came from.
  const waitedMs = Date.now() - started;
  const percent = Math.round((waitedMs / READY_ON_ENTRY_BUDGET_MS) * 100);
  const line =
    `# timing: ready on entry (execution line visible): ` +
    `${waitedMs}ms / ${READY_ON_ENTRY_BUDGET_MS}ms (${percent}%)`;
  if (waitedMs * 2 > READY_ON_ENTRY_BUDGET_MS) {
    console.warn(`${line} [over half the budget]`);
  } else {
    console.log(`${line} [ok]`);
  }
  await settleFocusAfterEntry(p);
}

/**
 * Leave the page in the state the old readiness wait left it in.
 *
 * The footer-based wait ended with a click on `.location-path`, a span with no
 * handler.  That click did two things every spec after it has been written
 * against: it moved the pointer onto the footer, away from the editor (where
 * it would raise hovers), and it took keyboard focus off whatever had it, so
 * key presses go to the document's shortcuts rather than into an editor.
 * `.location-path` cannot be clicked now that it is hidden, so this clicks
 * the language / encoding readout beside it, which has no handler either.
 * The click is NOT part of the readiness contract: if a future design hides
 * that readout too, the same two effects are produced without it, and
 * readiness is unaffected.  Do not click the execution line instead — a
 * press on the gutter reaches Monaco, which selects the line.
 */
async function settleFocusAfterEntry(p: Page): Promise<void> {
  const neutral = p.locator("#status-base #file-info-status");
  if (await neutral.isVisible().catch(() => false)) {
    // Not part of the readiness contract (above), so a click that a loaded
    // host does not deliver in time falls back to the blur below instead of
    // failing a spec whose stop has already arrived (seen under stress-ng:
    // `locator.click: Timeout 5000ms exceeded` after a ready entry).
    const clicked = await neutral
      .click({ timeout: 5_000 })
      .then(() => true)
      .catch(() => false);
    if (clicked) return;
  }
  await p.evaluate(() => {
    const focused = document.activeElement as HTMLElement | null;
    if (focused !== null && focused !== document.body) focused.blur();
  });
  await p.mouse.move(1, 1);
}

/**
 * Explain a `readyOnEntryTest` timeout.
 *
 * The wait itself is strict — this only runs after it has already failed, and
 * it exists because a bare timeout does not say which link of the chain
 * broke.  Ready needs four things, and each has its own evidence here:
 *
 *   1. The page loaded and its renderer is alive (`page`, animation frames).
 *   2. The debugger reported an entry location.  The status bar still renders
 *      that location into its hidden `.location-path` readout (the design
 *      hides the readout, not the model), so its text says whether a
 *      `ct/complete-move` reached the frontend at all.  `.finished` instead
 *      means the replay is already at its end.
 *   3. An editor drew the execution line.  Each `.monaco-editor` is listed
 *      with its component host, whether it has a box, and the line its arrow
 *      is on, if any; the active tabs say which files are in front.
 *   4. That editor is laid out where the user can see it.  An arrow cell that
 *      is in the DOM but has no box is a hiding or layout regression, the
 *      shape of `b27da3947` on the old footer signal.
 *
 * Read the retry's call log with Playwright's convention in mind
 * (Value-Origin-Tracking milestone M46): a call log holding nothing but
 * `waiting for locator(...)` means every poll matched zero elements, which is
 * the normal shape of a timeout on something that was never there, not
 * evidence that the poll failed to run.
 */
async function readinessDiagnosis(p: Page): Promise<string> {
  try {
    const dom = await p.evaluate((selector: string) => {
      const boxOf = (node: Element) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return {
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          display: style.display,
          visibility: style.visibility,
        };
      };
      // The nearest element, from `node` up, that takes the box away.
      const hiddenBy = (node: Element): string | null => {
        for (
          let el: Element | null = node;
          el !== null && el !== document.documentElement;
          el = el.parentElement
        ) {
          const style = getComputedStyle(el);
          if (style.display === "none" || style.visibility === "hidden") {
            const id = el.id ? `#${el.id}` : "";
            const cls = el.classList.length
              ? `.${Array.from(el.classList).slice(0, 3).join(".")}`
              : "";
            return `${el.tagName.toLowerCase()}${id}${cls} { display: ${style.display}; visibility: ${style.visibility} }`;
          }
        }
        return null;
      };
      const statusLocation = document.querySelector("#status-base .location-path");
      return {
        url: location.href,
        title: document.title,
        visibilityState: document.visibilityState,
        hasStatusHost: document.getElementById("status") !== null,
        statusLocation: statusLocation === null
          ? null
          : (statusLocation.textContent ?? "").slice(0, 160),
        finished: document.querySelector("#status-base #location-status .finished") !== null,
        editors: Array.from(document.querySelectorAll(".monaco-editor")).map((editor) => {
          const arrow = editor.querySelector(".gutter:has(> .gutter-highlight-active)");
          // Monaco's `data-uri` is an `inmemory://model/N` id, not the file,
          // so the editor is named by its component host; the file it shows
          // is the active tab's title, listed below.
          return {
            host: editor.closest("[id^='editorComponent-']")?.id ?? null,
            ...boxOf(editor),
            arrowLine: arrow === null ? null : arrow.getAttribute("data-line"),
          };
        }),
        arrows: Array.from(document.querySelectorAll(selector)).map((cell) => ({
          line: cell.getAttribute("data-line"),
          ...boxOf(cell),
          hiddenBy: hiddenBy(cell),
        })),
        activeTabs: Array.from(document.querySelectorAll(".lm_tab.lm_active .lm_title"))
          .map((tab) => (tab.textContent ?? "").trim())
          .filter((title) => title.length > 0)
          .slice(0, 12),
      };
    }, READY_ON_ENTRY_SELECTOR);

    // Renderer liveness, as frames serviced per 500ms.  It does not gate the
    // locator poll (a driver-side retry loop over `Runtime.callFunctionOn`),
    // but it is a good proxy for how starved the renderer is, and starvation
    // is what makes a launch overrun its budget.  A healthy idle host reports
    // ~30 (60fps); failures captured while the host carried its own CI
    // reported 1-5.
    const frames = await p.evaluate(() => {
      return new Promise<number>((resolve) => {
        let count = 0;
        const started = performance.now();
        const tick = () => {
          count += 1;
          if (performance.now() - started < 500) {
            requestAnimationFrame(tick);
          } else {
            resolve(count);
          }
        };
        requestAnimationFrame(tick);
        // Resolve anyway if no frame ever arrives, so the diagnosis itself
        // cannot hang.
        setTimeout(() => resolve(count), 1500);
      });
    });

    // Ask the same question once more and keep the whole answer.  A quick
    // `resolved` means the launch finished just past the budget.
    let retryResolvedMs: number | null = null;
    const retry = await (async () => {
      const started = Date.now();
      try {
        await p
          .locator(READY_ON_ENTRY_SELECTOR)
          .filter({ visible: true })
          .first()
          .waitFor({ state: "visible", timeout: 3_000 });
        retryResolvedMs = Date.now() - started;
        return `resolved in ${retryResolvedMs}ms`;
      } catch (again) {
        return `still unresolved after ${Date.now() - started}ms: ${
          (again as Error).message.replace(/\n/g, "\n    ")
        }`;
      }
    })();

    const reported =
      dom.statusLocation !== null && dom.statusLocation.length > 0;
    const verdict = (() => {
      if (retryResolvedMs !== null) {
        return (
          "  => the launch overran its budget: the execution line became " +
          `visible ${retryResolvedMs}ms into the retry that ran right after ` +
          "the wait. Raise the budget only against a fresh measurement of the " +
          "launch time (readyOnEntryTest carries the last one)."
        );
      }
      if (dom.arrows.length > 0) {
        return (
          "  => the execution line IS drawn but has no box: " +
          `${JSON.stringify(dom.arrows[0])}. The wait is correctly refusing to ` +
          "call this ready: the editor marked the entry line where the user " +
          "cannot see it. Look for a rule or a layout change that hides the " +
          "editor, its margin or its gutter (`hiddenBy` names the nearest " +
          "element that does), the shape of the b27da3947 footer regression. " +
          "Do NOT raise the budget for this."
        );
      }
      if (dom.finished) {
        return (
          "  => the status bar says the replay is Finished: the session went " +
          "to the end of the trace instead of stopping at an entry location, " +
          "so there is no execution line to draw."
        );
      }
      if (!reported) {
        return (
          "  => no entry location arrived: the status bar holds no location " +
          "and no editor draws an execution line, so the debugger has not " +
          "reported a stop (`ct/complete-move`) to this page. Frames above at " +
          "1-5/500ms mean a starved renderer and a launch that was still " +
          "running; ~30 means a renderer with nothing to do, i.e. a launch " +
          "that is wedged rather than slow (or ctPage bound to another " +
          "window). See M46."
        );
      }
      if (dom.editors.length === 0) {
        return (
          `  => the debugger reported ${dom.statusLocation}, but no editor is ` +
          "open: the entry file was never shown, so nothing can carry the " +
          "execution line. Check the editor service's open-on-stop path and " +
          "whether the entry file's source is available to the frontend."
        );
      }
      return (
        `  => the debugger reported ${dom.statusLocation}, and ` +
        `${dom.editors.length} editor(s) are open, but none draws the ` +
        "execution line: the editors in front show another file (see " +
        "`active tabs`), or " +
        "the location never reached `EditorViewComponent.onCompleteMove`, " +
        "which is what marks the gutter."
      );
    })();

    return [
      "readyOnEntry diagnosis:",
      `  fresh locator retry: ${retry}`,
      `  page: ${dom.title} <${dom.url}> visibilityState=${dom.visibilityState}`,
      `  #status present=${dom.hasStatusHost} status-bar location=` +
        `${JSON.stringify(dom.statusLocation)} finished=${dom.finished}`,
      `  editors=${dom.editors.length} ${JSON.stringify(dom.editors)}`,
      `  execution-line cells=${dom.arrows.length} ${JSON.stringify(dom.arrows)}`,
      `  active tabs=${JSON.stringify(dom.activeTabs)}`,
      `  animation frames in 500ms=${frames}`,
      `  budget: ${READY_ON_ENTRY_BUDGET_MS}ms`,
      verdict,
    ].join("\n");
  } catch (diagnosisFailure) {
    return `readyOnEntry diagnosis unavailable: ${String(diagnosisFailure)}`;
  }
}

/** Wait for the event log footer to be populated.
 *
 * The footer is rendered immediately by the IsoNim event-log shell with
 * a placeholder row count of "0"; DataTables fills it in after its
 * server-side ajax response arrives.  We therefore wait until the
 * counter shows a non-zero integer before returning.
 *
 * Earlier revisions of this helper followed the visibility wait with a
 * `.click()` on the counter element; the click was redundant for the
 * actual readiness contract and routinely failed under Xvfb because
 * the footer can be off-viewport when the GoldenLayout is not yet
 * fully sized.  The non-zero text wait subsumes the previous goal
 * (let DataTables finish populating) without depending on the click.
 */
export async function loadedEventLog(p: Page): Promise<void> {
  // Accept either signal as "loaded":
  //   (a) the footer counter has a non-zero integer
  //   (b) the dense-table tbody has at least one rendered row
  //
  // The footer is the canonical "DataTables done populating" signal but
  // it's served by the IsoNim event-log shell which gets re-rendered on
  // certain session-VM lifecycle events and on each re-mount stamps a
  // static `text "0"` over whatever the legacy DataTable's
  // `updateTableFooter()` wrote.  Browsers see the right number for a
  // moment and then the IsoNim re-render replaces it with "0", which
  // makes the poll race-dependent.  The dense-table row count comes
  // from DataTables' own `<tr>` insertions and is unaffected by the
  // IsoNim shell refresh, so it's the more reliable readiness signal
  // for the "trace has at least N events" contract that callers care
  // about.  See `src/frontend/ui/event_log.nim:eventLogAfterRedraws`
  // for the underlying remount path that this works around.
  const rowsCount = p.locator(".data-tables-footer-rows-count");
  const denseRows = p.locator(".eventLog-dense-table tbody tr");
  await rowsCount.waitFor({ state: "visible", timeout: 15_000 });
  await expect.poll(
    async () => {
      const text = (await rowsCount.textContent()) ?? "";
      const match = text.match(/(\d+)/);
      const footerCount = match ? parseInt(match[1], 10) : 0;
      if (footerCount > 0) return footerCount;
      // Fall back to actual rendered rows in case the footer is in the
      // remount "0" gap.  We don't return the raw count here — any
      // non-zero answer is enough for callers (the assertion is
      // ">= 1").
      const renderedRows = await denseRows.count();
      return renderedRows;
    },
    { timeout: 30_000, intervals: [250, 500, 1000] },
  ).toBeGreaterThan(0);
}
