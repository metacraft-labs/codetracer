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
import * as process from "node:process";
import { fileURLToPath } from "node:url";

import {
  test as base,
  expect,
  type Page,
  type ElectronApplication,
} from "@playwright/test";
import { _electron, chromium } from "playwright";

import { getFreeTcpPort } from "./port-allocator";
import { captureFailureDiagnostics } from "./test-diagnostics";
import { requiresRR } from "./lang-support";
import { ensureDefaultConfig, ensureDefaultLayout, restoreUserLayout } from "./layout-reset";
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
const codetracerPrefix = path.join(codetracerInstallDir, "src", "build-debug");
const originalXdgConfigHome = process.env.XDG_CONFIG_HOME;
const guiTestXdgConfigHome =
  process.env.CODETRACER_GUI_TEST_XDG_CONFIG_HOME ??
  fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-gui-xdg-config-"));
const ownsGuiTestXdgConfigHome =
  process.env.CODETRACER_GUI_TEST_XDG_CONFIG_HOME === undefined;
process.env.XDG_CONFIG_HOME = guiTestXdgConfigHome;

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
const EDITOR_WINDOW_INDEX = 1;
const MAX_CONNECT_ATTEMPTS = 20;
const RETRY_DELAY_MS = 1_500;
const GOTO_TIMEOUT_MS = 3_000;
const PORT_RELEASE_DELAY_MS = 500;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type DeploymentMode = "electron" | "web";
export type LaunchMode = "trace" | "trace-folder" | "welcome" | "edit" | "deepreview";

/**
 * Configurable options set via `test.use({ ... })`.
 */
interface CodetracerOptions {
  /** Electron (default) or Web (ct host + chromium). */
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
  /** Existing .ct or trace folder to import via ct host --trace-path. */
  visualReplayTracePath: string;
}

/**
 * Fixtures available in test functions.
 */
interface CodetracerFixtures {
  /** The Playwright Page connected to CodeTracer. */
  ctPage: Page;
  /** The Electron app handle (null in web mode). */
  electronApp: ElectronApplication | null;
  /** Internal: forces worker exit to avoid teardown timeout. */
  _workerCleanup: void;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function setupLdLibraryPath(): void {
  // LD_LIBRARY_PATH is a Linux/macOS concept; skip on Windows.
  if (!isWindows) {
    process.env.LD_LIBRARY_PATH = process.env.CT_LD_LIBRARY_PATH;
  }
}

/**
 * Remove Electron's single-instance lock files so a fresh launch can
 * acquire the lock.  Stale locks from previous test runs (or manual
 * launches) cause `_electron.launch()` to hang because the new Electron
 * instance detects the lock and tries to delegate to a non-existent
 * first instance.
 */
function clearElectronSingletonLocks(): void {
  const electronUserDataDir = path.join(
    process.env.HOME ?? process.env.USERPROFILE ?? "",
    isWindows ? "AppData/Roaming/Electron" : ".config/Electron",
  );
  for (const lockFile of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) {
    const lockPath = path.join(electronUserDataDir, lockFile);
    try {
      fs.unlinkSync(lockPath);
    } catch {
      // File may not exist — that's fine.
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

function recordTestProgram(recordArg: string): string {
  const cached = recordingCache.get(recordArg);
  if (cached !== undefined) {
    console.log(`# reusing cached trace for ${recordArg} with id ${cached}`);
    return cached;
  }

  process.env.CODETRACER_IN_UI_TEST = "1";

  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["record", recordArg],
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
  recordingCache.set(recordArg, recordingId);
  return recordingId;
}

function traceFolderForId(recordingId: string): string {
  const dataHome =
    process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share");
  // M-REC-7: the on-disk recording folder name is the bare UUIDv7
  // recording id — the pre-M-REC-7 `trace-<id>` prefix was retired
  // (see src/common/paths.nim `recordingFolder`).  Fall back to the
  // legacy prefixed name only if the bare folder is absent, so older
  // local recordings keep working.
  const bare = path.join(dataHome, "codetracer", recordingId);
  if (fs.existsSync(bare)) {
    return bare;
  }
  const legacy = path.join(dataHome, "codetracer", `trace-${recordingId}`);
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
 * When DevTools is open, the first window may be DevTools (index 0)
 * and the editor is at index 1.
 */
async function getEditorWindow(app: ElectronApplication): Promise<Page> {
  const firstWindow = await app.firstWindow({ timeout: 45_000 });
  const title = await firstWindow.title();
  if (title === "DevTools") {
    return app.windows()[EDITOR_WINDOW_INDEX];
  }
  return firstWindow;
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
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.XDG_CONFIG_HOME = guiTestXdgConfigHome;
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
function attachErrorCollectors(page: Page, bucket: string[]): void {
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      bucket.push(`[console.error] ${msg.text()}`);
    }
  });
  page.on("pageerror", (error) => {
    bucket.push(`[pageerror] ${error.message}`);
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
    console.error(`[diag] scripts: ${info.join("; ")}`);
    console.error(`[diag] globals: ${JSON.stringify(globals)}`);
    console.error(`[diag] CODETRACER_PREFIX: ${ctPrefix}`);
  }).catch(() => { /* page may be closed */ });
}

async function launchTraceElectron(
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
  const { result: traceId, durationMs: recordMs } = await timed(
    "record",
    recordingLimit,
    async () => recordTestProgram(fullSourcePath),
  );
  if (visualReplayTrace) markTraceVisualReplayCapable(traceId);

  console.log(`# launching Electron for trace ${traceId} (record: ${recordMs}ms)`);

  // On Windows, ct.exe spawns Electron as a child process (no execv),
  // which prevents Playwright from connecting via CDP.  Launch Electron
  // directly and pass the app directory so it picks up package.json.
  const launchExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
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
  const { result: page, durationMs: windowMs } = await timed(
    "first window",
    LIMIT_FIRST_WINDOW_MS,
    async () => getEditorWindow(app),
  );
  attachErrorCollectors(page, consoleErrors);

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
    ["host", "--trace-path", traceFolder, "0", "--port=0", "--idle-timeout=1ms"],
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

  const launchExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
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

  const consoleErrors: string[] = [];
  const page = await context.newPage();
  attachErrorCollectors(page, consoleErrors);

  // Wait for ct host to become ready with retry-based navigation.
  const tConnect0 = Date.now();
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(`http://localhost:${httpPort}`, {
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
  ctProcess.stdout?.on("data", (chunk: Buffer) => {
    ctStdout.push(chunk.toString());
  });
  ctProcess.stderr?.on("data", (chunk: Buffer) => {
    ctStderr.push(chunk.toString());
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

  const consoleErrors: string[] = [];
  const page = await context.newPage();
  attachErrorCollectors(page, consoleErrors);

  const tConnect0 = Date.now();
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(`http://localhost:${httpPort}`, {
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

  const welcomeExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
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

  const editExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
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

  const drExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
  const drArgs = (isWindows && electronExePath)
    ? [codetracerPrefix, "--deepreview", jsonPath]
    : [`--deepreview=${jsonPath}`];

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

export const test = base.extend<CodetracerFixtures & CodetracerOptions>({
  // Options (set via test.use)
  deploymentMode: ["electron", { option: true }],
  sourcePath: ["", { option: true }],
  launchMode: ["trace" as LaunchMode, { option: true }],
  newTracePolicy: ["window" as "window" | "tab", { option: true }],
  testOpenFolderDialogPath: ["", { option: true }],
  editFolderPath: ["", { option: true }],
  editWorkingDirectory: [codetracerInstallDir, { option: true }],
  deepreviewJsonPath: ["", { option: true }],
  visualReplayTrace: [false, { option: true }],
  visualReplayTracePath: ["", { option: true }],

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
      if (ownsGuiTestXdgConfigHome) {
        try {
          fs.rmSync(guiTestXdgConfigHome, { recursive: true, force: true });
        } catch (ex) {
          console.warn(`fixtures: removing test XDG_CONFIG_HOME failed: ${(ex as Error).message}`);
        }
      }
      if (originalXdgConfigHome === undefined) {
        delete process.env.XDG_CONFIG_HOME;
      } else {
        process.env.XDG_CONFIG_HOME = originalXdgConfigHome;
      }
      // Killing Electron with SIGKILL leaves Playwright's internal CDP
      // pipe handles open, preventing the worker from exiting.  Force
      // exit after a brief delay so test results can still be reported.
      setTimeout(() => process.exit(0), 2000);
    },
    { scope: "worker" as const, auto: true },
  ],

  electronApp: [
    async ({}, use) => {
      // Populated by ctPage fixture. Default null for direct use.
      await use(null);
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
        visualReplayTracePath,
        newTracePolicy,
        testOpenFolderDialogPath,
      },
      use,
      testInfo,
    ) => {
      let result: LaunchResult;

      // Ensure each test starts with the bundled default layout in the
      // worker-local config directory.  Earlier tests in the same worker may
      // have mutated the saved layout
      // (e.g. auto-hide pin-to-edge, build/problems panel pop-out, layout
      // resilience).  Without this reset, that mutated layout persists
      // via default_layout.json and subsequent tests see a stale layout that
      // may be missing the components they require (filesystem, state, etc.).
      try {
        ensureDefaultConfig(codetracerInstallDir);
        ensureDefaultLayout(codetracerInstallDir);
      } catch (ex) {
        // Non-fatal: a missing bundled layout file would surface as a
        // launch-time error anyway.  Log and continue so the test still
        // produces a meaningful failure.
        console.warn(`fixtures: ensureDefaultLayout failed: ${(ex as Error).message}`);
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
      if (needsRR) {
        test.setTimeout(process.platform === "win32" ? 720_000 : 120_000);
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
            result = await launchTraceElectron(sourcePath, recordingLimit, visualReplayTrace);
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
          await assertCoreElectronStylesLoaded(result.page);
        }

        await use(result.page);

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
          // Report collected JS errors from the renderer
          if (result.consoleErrors.length > 0) {
            console.log(`  FAIL JS errors (${result.consoleErrors.length}):`);
            for (const err of result.consoleErrors.slice(0, 50)) {
              console.log(`    ${err}`);
            }
          }
          // Report main process output (backend-manager, socket, init flow)
          if (result.mainProcessOutput.length > 0) {
            console.log(`  FAIL main process output (${result.mainProcessOutput.length} lines):`);
            for (const line of result.mainProcessOutput.slice(0, 100)) {
              console.log(`    ${line}`);
            }
          } else {
            console.log(`  FAIL main process output: (none captured)`);
          }
          await captureFailureDiagnostics(result.page, testInfo);
        }
      } finally {
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
  testProgramsPath,
  codetracerPath,
};

// Export recordTestProgram so multi-trace tests can pre-record additional
// programs and load them into new sessions via IPC.
export { recordTestProgram };

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

/** Wait for the entry point to be ready (location path clickable). */
export async function readyOnEntryTest(p: Page): Promise<void> {
  await p.locator(".location-path").waitFor({ state: "visible", timeout: 15_000 });
  await p.locator(".location-path").click();
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
  const rowsCount = p.locator(".data-tables-footer-rows-count");
  await rowsCount.waitFor({ state: "visible", timeout: 15_000 });
  await expect.poll(
    async () => {
      const text = (await rowsCount.textContent()) ?? "";
      const match = text.match(/(\d+)/);
      return match ? parseInt(match[1], 10) : 0;
    },
    { timeout: 30_000, intervals: [250, 500, 1000] },
  ).toBeGreaterThan(0);
}
