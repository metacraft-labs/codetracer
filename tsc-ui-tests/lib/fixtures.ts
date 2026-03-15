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
import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";

import {
  test as base,
  type Page,
  type ElectronApplication,
} from "@playwright/test";
import { _electron, chromium } from "playwright";

import { getFreeTcpPort } from "./port-allocator";
import { captureFailureDiagnostics } from "./test-diagnostics";
import { requiresRR } from "./lang-support";
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
const codetracerInstallDir = path.dirname(currentDir);
const testProgramsPath = path.join(codetracerInstallDir, "test-programs");
const codetracerPrefix = path.join(codetracerInstallDir, "src", "build-debug");

const ctBinaryName = isWindows ? "ct.exe" : "ct";
const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
const codetracerPath =
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(codetracerPrefix, "bin", ctBinaryName);

// On Windows, the `python3` name often resolves to the Windows Store alias
// stub which is not a real interpreter.  Detect and set the correct Python
// path so that `ct record` can find the recorder package.
if (isWindows && !process.env.CODETRACER_PYTHON_INTERPRETER) {
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
export type LaunchMode = "trace" | "welcome" | "edit" | "deepreview";

/**
 * Configurable options set via `test.use({ ... })`.
 */
interface CodetracerOptions {
  /** Electron (default) or Web (ct host + chromium). */
  deploymentMode: DeploymentMode;
  /** Relative path under test-programs/ for recording. */
  sourcePath: string;
  /** How to launch CodeTracer. */
  launchMode: LaunchMode;
  /** Folder path for edit mode. */
  editFolderPath: string;
  /** JSON path for deepreview mode. */
  deepreviewJsonPath: string;
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

function cleanupCodetracerEnvVars(): void {
  delete process.env.CODETRACER_TRACE_ID;
  delete process.env.CODETRACER_CALLER_PID;
  delete process.env.CODETRACER_IN_UI_TEST;
  delete process.env.CODETRACER_TEST;
}

// Cache trace IDs by source path so multiple tests for the same program
// don't re-record. This dramatically speeds up RR test suites where each
// language has 5 tests sharing the same sourcePath.
const recordingCache = new Map<string, number>();

function recordTestProgram(recordArg: string): number {
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
    },
  );

  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    throw new Error(
      `ct record failed: error=${ctProcess.error}; status=${ctProcess.status}\nstderr: ${ctProcess.stderr}\nstdout: ${ctProcess.stdout}`,
    );
  }

  const lines = ctProcess.stdout.trim().split("\n");
  const lastLine = lines[lines.length - 1];
  if (!lastLine.startsWith("traceId:")) {
    throw new Error(`Unexpected last line of ct record: ${lastLine}`);
  }
  const rawTraceId = lastLine.split(":")[1].trim();
  const traceId = Number(rawTraceId);
  if (isNaN(traceId)) {
    throw new Error(`Could not parse trace id from: ${rawTraceId}`);
  }
  console.log(`# recorded trace for ${recordArg} with id ${traceId}`);
  recordingCache.set(recordArg, traceId);
  return traceId;
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
  delete env.CODETRACER_TRACE_ID;
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
  if (extra) {
    Object.assign(env, extra);
  }
  return env;
}

/**
 * Resolves the chromium executable path from $PLAYWRIGHT_BROWSERS_PATH.
 *
 * On Linux, looks for chrome-linux directory with chrome binary.
 * On Windows, looks for chrome-win directory with chrome.exe binary.
 */
function resolveChromiumPath(): string {
  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!browsersDir) {
    throw new Error(
      "expected $PLAYWRIGHT_BROWSERS_PATH env var to be set: can't find browser without it",
    );
  }
  const chromiumDir = fs
    .readdirSync(browsersDir)
    .filter((d: string) => d.startsWith("chromium-") && !d.includes("headless"))
    .sort()
    .pop();
  if (!chromiumDir) {
    throw new Error(`no chromium-* directory found in ${browsersDir}`);
  }

  const chromiumBase = path.join(browsersDir, chromiumDir);

  if (isWindows) {
    const chromeSubdir = fs
      .readdirSync(chromiumBase)
      .find((d: string) => d.startsWith("chrome-win"));
    if (!chromeSubdir) {
      throw new Error(
        `no chrome-win* directory found in ${chromiumBase}`,
      );
    }
    return path.join(chromiumBase, chromeSubdir, "chrome.exe");
  }

  // Linux (and fallback for other Unix-like systems)
  const chromeSubdir = fs
    .readdirSync(chromiumBase)
    .find((d: string) => d.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new Error(
      `no chrome-linux* directory found in ${chromiumBase}`,
    );
  }
  return path.join(chromiumBase, chromeSubdir, "chrome");
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

async function launchTraceElectron(sourcePath: string, recordingLimit = LIMIT_SMALL_RECORDING_MS): Promise<LaunchResult> {
  setupLdLibraryPath();
  const t0 = Date.now();

  const fullSourcePath = path.join(testProgramsPath, sourcePath);
  const { result: traceId, durationMs: recordMs } = await timed(
    "record",
    recordingLimit,
    async () => recordTestProgram(fullSourcePath),
  );

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
          CODETRACER_TRACE_ID: traceId.toString(),
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

async function launchTraceWeb(sourcePath: string, recordingLimit = LIMIT_SMALL_RECORDING_MS): Promise<LaunchResult> {
  setupLdLibraryPath();
  const t0 = Date.now();

  const fullSourcePath = path.join(testProgramsPath, sourcePath);
  const { result: traceId, durationMs: recordMs } = await timed(
    "record",
    recordingLimit,
    async () => recordTestProgram(fullSourcePath),
  );

  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();

  console.log(
    `# launching ct host for trace ${traceId} on port ${httpPort} (record: ${recordMs}ms)`,
  );

  const ctProcess = childProcess.spawn(
    codetracerPath,
    [
      "host",
      traceId.toString(),
      `--port=${httpPort}`,
      `--backend-socket-port=${backendPort}`,
      `--frontend-socket=${backendPort}`,
    ],
    {
      cwd: codetracerInstallDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
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

  const consoleErrors: string[] = [];
  const page = await browser.newPage();
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

async function launchWelcomeScreen(): Promise<LaunchResult> {
  setupLdLibraryPath();
  console.log("# launching welcome screen");

  const welcomeExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
  const welcomeArgs = (isWindows && electronExePath) ? [codetracerPrefix] : [];

  const app = await _electron.launch({
    executablePath: welcomeExe,
    cwd: codetracerInstallDir,
    args: welcomeArgs,
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

async function launchEditMode(folderPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  console.log(`# launching edit mode for ${folderPath}`);

  const editExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
  const editArgs = (isWindows && electronExePath)
    ? [codetracerPrefix, "edit", folderPath]
    : ["edit", folderPath];

  const app = await _electron.launch({
    executablePath: editExe,
    cwd: codetracerInstallDir,
    args: editArgs,
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

async function launchDeepReview(jsonPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  console.log(`# launching deepreview mode for ${jsonPath}`);

  const drExe = (isWindows && electronExePath) ? electronExePath : codetracerPath;
  const drArgs = (isWindows && electronExePath)
    ? [codetracerPrefix, `--deepreview=${jsonPath}`]
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
  editFolderPath: ["", { option: true }],
  deepreviewJsonPath: ["", { option: true }],

  // Fixtures
  _workerCleanup: [
    async ({}, use) => {
      await use();
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
      { deploymentMode, sourcePath, launchMode, editFolderPath, deepreviewJsonPath },
      use,
      testInfo,
    ) => {
      let result: LaunchResult;

      const needsRR = sourcePath ? requiresRR(sourcePath) : false;
      const recordingLimit = needsRR ? LIMIT_RR_RECORDING_MS : LIMIT_SMALL_RECORDING_MS;

      if (needsRR && !process.env.CODETRACER_RR_BACKEND_PRESENT) {
        testInfo.skip(true, "requires ct-rr-support (RR-based language)");
      }
      if (needsRR && process.env.CODETRACER_DB_TESTS_ONLY === "1") {
        testInfo.skip(true, "RR test skipped — running DB-based tests only");
      }
      if (!needsRR && process.env.CODETRACER_RR_TESTS_ONLY === "1") {
        testInfo.skip(true, "DB-based test skipped — running RR tests only");
      }

      // RR-based tests need more time: compile + rr record + Electron + UI.
      if (needsRR) {
        test.setTimeout(120_000);
      }

      switch (launchMode) {
        case "trace": {
          if (!sourcePath) {
            throw new Error(
              "sourcePath must be set via test.use() for trace launch mode",
            );
          }
          if (deploymentMode === "web") {
            result = await launchTraceWeb(sourcePath, recordingLimit);
          } else {
            result = await launchTraceElectron(sourcePath, recordingLimit);
          }
          break;
        }
        case "welcome": {
          result = await launchWelcomeScreen();
          break;
        }
        case "edit": {
          if (!editFolderPath) {
            throw new Error(
              "editFolderPath must be set via test.use() for edit launch mode",
            );
          }
          result = await launchEditMode(editFolderPath);
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

      await result.teardown();
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

/** Wait for the event log footer to be populated. */
export async function loadedEventLog(p: Page): Promise<void> {
  await p.locator(".data-tables-footer-rows-count").waitFor({ state: "visible", timeout: 15_000 });
  await p.locator(".data-tables-footer-rows-count").click();
}
