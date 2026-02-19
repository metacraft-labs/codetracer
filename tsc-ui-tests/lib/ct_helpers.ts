// based on / copied from
//  https://playwright.dev/docs/api/class-electron
//  https://playwright.dev/docs/api/class-electronapplication#electron-application-browser-window
//  https://github.com/microsoft/playwright/blob/main/tests/electron/electron-app.spec.ts
//  ! https://github.com/spaceagetv/electron-playwright-example/blob/main/e2e-tests/main.spec.ts
// and others

import * as fs from "node:fs";
import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, type Page } from "@playwright/test";
import { _electron, chromium } from "playwright";

const electron = _electron;

let electronApp; // eslint-disable-line @typescript-eslint/init-declarations
export let window: Page; // eslint-disable-line @typescript-eslint/init-declarations
export let page: Page; // eslint-disable-line @typescript-eslint/init-declarations

// Track the last ct host process so it can be killed between test files.
let activeCtHostProcess: childProcess.ChildProcess | null = null;

export const currentDir = path.resolve(); // the tsc-ui-tests dir
export const codetracerInstallDir = path.dirname(currentDir);
export const codetracerTestDir = path.join(currentDir, "tests");
export const testProgramsPath = path.join(codetracerInstallDir, "test-programs");
export const testBinariesPath = path.join(currentDir, "binaries");

// in the sense of `linksPath`, NOT dev build src/links !
// only matters if `CODETRACER_E2E_CT_PATH` is NOT overriden:
//   as a default dev build test setup
// otherwise this is not really used
export const linksPath = path.join(codetracerInstallDir, "src", "build-debug");

const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
export const codetracerPath =
  // eslint-disable-next-line @typescript-eslint/no-magic-numbers
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(linksPath, "bin", "ct");

const OK_EXIT_CODE = 0;
const ERROR_EXIT_CODE = 1;
const NO_PID = -1;
const EDITOR_WINDOW_INDEX = 1; // if both windows are open: 1 is Editor, 0 is DevTools

/// exported public functions:

export function debugCodetracer(name: string, langExtension: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();
    await recordAndReplayTestProgram(name, langExtension);
  });
  test.afterAll(async () => {
    if (electronApp) {
      try { await electronApp.close(); } catch { /* already closed */ }
      electronApp = undefined;
    }
    await killActiveCtHost();
    cleanupCodetracerEnvVars();
  });
}

export function getTestProgramNameFromPath(filePath: string): string {
  if (filePath.startsWith("noir_")) {
    return path.basename(filePath);
  }
  const pathSegments = filePath.split(path.sep);
  // The first segment is the folder inside 'test-programs'
  return pathSegments[0];
}

export interface CtRunOptions {
  // Force browser mode (ct host + chromium) instead of the default Electron mode.
  // Only set this on a per-call basis — do NOT set the CODETRACER_TEST_IN_BROWSER
  // env var at module scope, because Playwright loads all spec files before running
  // any tests and the side effect would leak into unrelated test files.
  inBrowser?: boolean;
}

export function ctRun(relativeSourcePath: string, options?: CtRunOptions): void {
  test.beforeAll(async () => {
    // Recording + chromium launch + ct host startup retries can exceed the
    // default 30s beforeAll timeout, especially for browser-mode tests.
    const BEFORE_ALL_TIMEOUT_MS = 90_000;
    test.setTimeout(BEFORE_ALL_TIMEOUT_MS);
    // Kill any leftover ct host process from a previous test file/describe
    // block to avoid port conflicts on the hardcoded port 5005.
    await killActiveCtHost();

    setupLdLibraryPath();

    const sourcePath = path.join(testProgramsPath, relativeSourcePath);
    const programName = getTestProgramNameFromPath(relativeSourcePath);

    const traceId = recordTestProgram(sourcePath);

    const inBrowser =
      options?.inBrowser ?? (process.env.CODETRACER_TEST_IN_BROWSER === "1");
    if (!inBrowser) {
      await replayCodetracerInElectron(programName, traceId);
    } else {
      await replayCodetracerInBrowser(programName, traceId);
    }
  });

  // Clean up after all tests in this describe block / file.
  // Close the Electron app (and its backend-manager) so it doesn't
  // hold backend-socket ports that conflict with subsequent test files.
  // Also kill any ct host process used in browser mode.
  // Clean up env vars so they don't leak into subsequent test files
  // (e.g. CODETRACER_TRACE_ID causes server_index.js parseArgs to
  // short-circuit, ignoring --port and other CLI flags).
  test.afterAll(async () => {
    if (electronApp) {
      try { await electronApp.close(); } catch { /* already closed */ }
      electronApp = undefined;
    }
    await killActiveCtHost();
    cleanupCodetracerEnvVars();
  });
}

// for Promise-fying setTimeout:
// consulted with various blogs/docs/etc
// for example:
// https://dev.to/bbarbour/making-settimeout-async-friendly-50je
// and similar others

// about the eslint warning: https://stackoverflow.com/a/69683474/438099
// eslint-disable-next-line @typescript-eslint/promise-function-async
export function wait(ms: number): Promise<void> {
  const future = new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
  return future;
}

/// Launch CodeTracer showing the welcome screen (no trace)
export function ctWelcomeScreen(): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();
    await launchWelcomeScreen();
  });
  test.afterAll(async () => {
    if (electronApp) {
      try { await electronApp.close(); } catch { /* already closed */ }
      electronApp = undefined;
    }
    cleanupCodetracerEnvVars();
  });
}

/// Launch CodeTracer in edit mode with a folder
export function ctEditMode(folderPath: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();
    await launchEditMode(folderPath);
  });
  test.afterAll(async () => {
    if (electronApp) {
      try { await electronApp.close(); } catch { /* already closed */ }
      electronApp = undefined;
    }
    cleanupCodetracerEnvVars();
  });
}

/// Launch CodeTracer in DeepReview mode with a JSON export file.
/// The ``--deepreview <jsonPath>`` flag loads the DeepReview data into
/// the standalone review view (offline, no debugger connection).
export function ctDeepReview(jsonPath: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();
    await launchDeepReview(jsonPath);
  });
  test.afterAll(async () => {
    if (electronApp) {
      try { await electronApp.close(); } catch { /* already closed */ }
      electronApp = undefined;
    }
    cleanupCodetracerEnvVars();
  });
}

/// end of exported public functions
/// ===================================

async function launchWelcomeScreen(): Promise<void> {
  console.log("# launching codetracer welcome screen");

  // Create a clean env without trace-related vars
  const cleanEnv = { ...process.env };
  delete cleanEnv.CODETRACER_TRACE_ID;
  delete cleanEnv.CODETRACER_CALLER_PID;

  cleanEnv.CODETRACER_IN_UI_TEST = "1";
  cleanEnv.CODETRACER_TEST = "1";

  electronApp = await electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [],
    env: cleanEnv,
  });

  const firstWindow = await electronApp.firstWindow();
  const firstWindowTitle = await firstWindow.title();

  if (firstWindowTitle === "DevTools") {
    window = electronApp.windows()[EDITOR_WINDOW_INDEX];
  } else {
    window = firstWindow;
  }
  page = window;
}

async function launchEditMode(folderPath: string): Promise<void> {
  console.log(`# launching codetracer edit mode for ${folderPath}`);

  // Create a clean env like launchWelcomeScreen does
  const cleanEnv = { ...process.env };
  delete cleanEnv.CODETRACER_TRACE_ID;
  delete cleanEnv.CODETRACER_CALLER_PID;

  cleanEnv.CODETRACER_IN_UI_TEST = "1";
  cleanEnv.CODETRACER_TEST = "1";

  // Launch ct directly with edit command.
  // The ct binary uses execv to replace itself with Electron,
  // forwarding Playwright's --inspect and --remote-debugging-port flags.
  electronApp = await electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: ["edit", folderPath],
    env: cleanEnv,
  });

  const firstWindow = await electronApp.firstWindow();
  const firstWindowTitle = await firstWindow.title();

  if (firstWindowTitle === "DevTools") {
    window = electronApp.windows()[EDITOR_WINDOW_INDEX];
  } else {
    window = firstWindow;
  }
  page = window;
}

async function launchDeepReview(jsonPath: string): Promise<void> {
  console.log(`# launching codetracer deepreview mode for ${jsonPath}`);

  // Create a clean env without trace-related vars, same as other modes.
  const cleanEnv = { ...process.env };
  delete cleanEnv.CODETRACER_TRACE_ID;
  delete cleanEnv.CODETRACER_CALLER_PID;

  cleanEnv.CODETRACER_IN_UI_TEST = "1";
  cleanEnv.CODETRACER_TEST = "1";

  // Launch ct with the --deepreview flag. The frontend reads the JSON file
  // via ``fs.readFileSync`` and ``JSON.parse``, then activates the
  // standalone DeepReview component instead of the normal debug layout.
  electronApp = await electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [`--deepreview=${jsonPath}`],
    env: cleanEnv,
  });

  const firstWindow = await electronApp.firstWindow();
  const firstWindowTitle = await firstWindow.title();

  if (firstWindowTitle === "DevTools") {
    window = electronApp.windows()[EDITOR_WINDOW_INDEX];
  } else {
    window = firstWindow;
  }
  page = window;
}

async function killActiveCtHost(): Promise<void> {
  if (activeCtHostProcess !== null) {
    try {
      activeCtHostProcess.kill();
    } catch {
      // Process may have already exited — ignore.
    }
    activeCtHostProcess = null;
  }

  // Also kill any leaked ct host that might still be holding port 5005.
  // This handles the case where Playwright reruns beforeAll after a test
  // failure, overwriting activeCtHostProcess without killing the old one.
  try {
    childProcess.execSync("fuser -k 5005/tcp", { stdio: "ignore" });
  } catch {
    // No process on port 5005 — expected for the first run.
  }

  // Allow a brief delay for the OS to release port 5005.
  const PORT_RELEASE_DELAY_MS = 500;
  await new Promise<void>((resolve) => setTimeout(resolve, PORT_RELEASE_DELAY_MS));
}

/// Remove env vars set by replayCodetracerInElectron so they don't leak
/// into subsequent test files.  In particular, CODETRACER_TRACE_ID causes
/// server_index.js's parseArgs to short-circuit, skipping --port and other
/// CLI flags (all ports default to 0).
function cleanupCodetracerEnvVars(): void {
  delete process.env.CODETRACER_TRACE_ID;
  delete process.env.CODETRACER_CALLER_PID;
  delete process.env.CODETRACER_IN_UI_TEST;
  delete process.env.CODETRACER_TEST;
}

function setupLdLibraryPath(): void {
  // originally in src/tester/tester.nim
  // required so <path to>/codetracer can be called internally
  // (it is called from ct itself)
  // we need the correct ld library paths
  // for more info, please read the comment for `setupLdLibraryPath`
  // in src/tester/tester.nim;
  process.env.LD_LIBRARY_PATH = process.env.CT_LD_LIBRARY_PATH;
}

async function replayCodetracerInElectron(
  programName: string,
  traceId: number,
): Promise<void> {
  console.log(`# replay codetracer in Electron for ${programName}`);

  // The Electron frontend reads the trace ID from env vars (see
  // src/frontend/index/args.nim parseArgs).  It spawns backend-manager
  // internally, which handles both RR and DB-based traces.
  process.env.CODETRACER_CALLER_PID = process.pid.toString();
  process.env.CODETRACER_TRACE_ID = traceId.toString();
  process.env.CODETRACER_IN_UI_TEST = "1";
  process.env.CODETRACER_TEST = "1";

  electronApp = await electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [],
  });

  const firstWindow = await electronApp.firstWindow();
  const firstWindowTitle = await firstWindow.title();

  if (firstWindowTitle === "DevTools") {
    window = electronApp.windows()[EDITOR_WINDOW_INDEX];
  } else {
    window = firstWindow;
  }
  page = window;
}

async function replayCodetracerInBrowser(
  pattern: string,
  traceId: number,
): Promise<number> {
  console.log(`# replay codetracer in browser for ${pattern} and ${traceId}`);
  const ctProcess = childProcess.spawn(
    codetracerPath,
    [
      "host",
      traceId.toString(),
      `--port=5005`,
      `--backend-socket-port=5001`,
      `--frontend-socket=5001`,
    ],
    { cwd: codetracerInstallDir },
  );

  // Track this process so it can be killed between test files.
  activeCtHostProcess = ctProcess;

  // TODO: some kind of error with the test firefox on my setup/nixos
  // let firefoxBrowser = await firefox.launch();
  // page = await firefoxBrowser.newPage();

  if (process.env.PLAYWRIGHT_BROWSERS_PATH === undefined) {
    throw new CodetracerTestError(
      "expected `$PLAYWRIGHT_BROWSERS_PATH` env var to be set: can't find browser without it",
    );
  }
  // Discover the chromium directory dynamically so the path doesn't break
  // when the nix-provided Playwright version (and its bundled chromium
  // revision number) changes.
  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  const chromiumDir = fs.readdirSync(browsersDir!)
    .filter((d: string) => d.startsWith("chromium-") && !d.includes("headless"))
    .sort()
    .pop();
  if (!chromiumDir) {
    throw new CodetracerTestError(
      `no chromium-* directory found in ${browsersDir}`,
    );
  }
  // The chrome binary lives under chrome-linux or chrome-linux64 depending
  // on the Playwright version.
  const chromeSubdir = fs.readdirSync(path.join(browsersDir!, chromiumDir))
    .find((d: string) => d.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new CodetracerTestError(
      `no chrome-linux* directory found in ${browsersDir}/${chromiumDir}`,
    );
  }
  // In CI the nix-store chrome-sandbox binary lacks the SUID bit, so
  // Chromium must be launched with --no-sandbox (same flags that
  // CODETRACER_ELECTRON_ARGS supplies for Electron launches).
  const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
    .split(/\s+/)
    .filter(Boolean);
  const chromiumBrowser = await chromium.launch({
    executablePath: path.join(browsersDir!, chromiumDir, chromeSubdir, "chrome"),
    args: extraArgs,
  });

  page = await chromiumBrowser.newPage();

  // Wait for the ct host server to become ready.  Use retry-based navigation
  // instead of a fixed delay so we tolerate variable startup times and
  // port-release delays between sequential browser-mode tests.
  const MAX_CONNECT_ATTEMPTS = 12;
  const RETRY_DELAY_MS = 1_000;
  const GOTO_TIMEOUT_MS = 3_000;
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(`http://localhost:5005`, { timeout: GOTO_TIMEOUT_MS });
      connected = true;
    } catch {
      if (attempt < MAX_CONNECT_ATTEMPTS) {
        await wait(RETRY_DELAY_MS);
      }
    }
  }
  if (!connected) {
    throw new CodetracerTestError(
      `Failed to connect to ct host on localhost:5005 after ${MAX_CONNECT_ATTEMPTS} attempts`,
    );
  }
  window = page;

  return ctProcess.pid ?? NO_PID;
}

async function replayCodetracerAndSetup(
  pattern: string,
  traceId: number,
): Promise<void> {
  const inBrowser = process.env.CODETRACER_TEST_IN_BROWSER === "1";
  if (!inBrowser) {
    await replayCodetracerInElectron(pattern, traceId);
  } else {
    await replayCodetracerInBrowser(pattern, traceId);
  }
}

// hopefully ok for build/record to be sync for now
// a bit easier to process output
// and we're not in a hurry because we're using
// it in a before all hook: we need this for the tests first

function buildTestProgram(
  programSourcePath: string,
  outputBinaryPath: string,
): void {
  // non-obvious options!
  // stdio: 'pipe', encoding: 'utf8' found form
  // https://stackoverflow.com/a/35690273/438099
  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["build", programSourcePath, outputBinaryPath],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
    },
  );
  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    console.log(`ERROR: codetracer build: ${ctProcess.error}`);
    console.log(ctProcess.stderr);
    process.exit(ERROR_EXIT_CODE);
  }
  console.log(`# codetracer built ${outputBinaryPath} succesfully`);
}

function recordTestProgram(recordArg: string): number {
  process.env.CODETRACER_IN_UI_TEST = "1";

  // non-obvious options!
  // stdio: 'pipe', encoding: 'utf8' found form
  // https://stackoverflow.com/a/35690273/438099
  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["record", recordArg],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
    },
  );
  // console.log(ctProcess);
  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    console.log(
      `ERROR: codetracer record: error: ${ctProcess.error}; status: ${ctProcess.status}`,
    );
    console.log(ctProcess.stderr);
    process.exit(ERROR_EXIT_CODE);
  }

  const lines = ctProcess.stdout.trim().split("\n");
  const lastLine = lines[lines.length - 1]; // eslint-disable-line @typescript-eslint/no-magic-numbers
  if (!lastLine.startsWith("traceId:")) {
    console.log("ERROR: unexpected last line of ct record:");
    console.log(lastLine);
    process.exit(ERROR_EXIT_CODE);
  }
  const traceIdTokenIndex = 1;
  const rawTraceId = lastLine.split(":")[traceIdTokenIndex].trim();

  // based on https://stackoverflow.com/a/23440948/438099
  const maybeTraceId = Number(rawTraceId);
  if (isNaN(+maybeTraceId)) {
    console.log(
      `ERROR: couldn't parse trace id for record from this token: ${rawTraceId}`,
    );
    process.exit(ERROR_EXIT_CODE);
  }
  console.log(
    `# codetracer recorded a trace for ${recordArg} with trace id ${maybeTraceId} succesfully`,
  );
  return maybeTraceId;
}

function buildAndRecordTestProgram(
  programSourcePath: string,
  outputBinaryPath: string,
): number {
  buildTestProgram(programSourcePath, outputBinaryPath);
  return recordTestProgram(outputBinaryPath);
}

async function recordAndReplayTestProgram(
  name: string,
  langExtension: string,
): Promise<void> {
  const sourcePath = path.join(
    testProgramsPath,
    langExtension,
    `${name}.${langExtension}`,
  );
  const outputBinary = `${name}_${langExtension}`;
  const outputBinaryPath = path.join(testBinariesPath, outputBinary);

  // uses ct record <path>;
  //   stores it in the shared central local db as all the normal records
  //   maybe by an user, not in a separate test one!
  const traceId = buildAndRecordTestProgram(sourcePath, outputBinaryPath);
  await replayCodetracerAndSetup(outputBinary, traceId);
}

export async function readyOnEntryTest(): Promise<void> {
  await page.locator(".location-path").click();
}

export async function loadedEventLog(): Promise<void> {
  await page.locator(".data-tables-footer-rows-count").click();
}

export class CodetracerTestError extends Error {
  constructor(msg: string) {
    super(msg);

    Object.setPrototypeOf(this, CodetracerTestError.prototype);
  }
}

async function debugMovement(selector: string): Promise<void> {
  await page.locator("#debug").click();

  const initialText = await page.locator(".test-movement").textContent();
  if (initialText === null) {
    throw new Error("Initial text was null");
  }

  const initialValue = parseInt(initialText, 10);
  if (isNaN(initialValue)) {
    throw new Error(`Initial text was not a number: "${initialText}"`);
  }

  await page.locator(selector).click();
  await readyOnCompleteMove(initialValue);
}

export async function clickContinue(): Promise<void> {
  await debugMovement("#continue-debug");
}

export async function clickNext(): Promise<void> {
  await debugMovement("#next-debug");
}

export async function readyOnCompleteMove(initialValue: number): Promise<void> {
  const movement = page.locator(".test-movement");
  const elementHandle = await movement.elementHandle();
  if (elementHandle === null) throw new Error("Element not found");

  await page.waitForFunction(
    ({ el, expected }) => {
      const current = parseInt(el.textContent ?? "", 10);
      return !isNaN(current) && current !== expected;
    },
    { el: await movement.evaluateHandle((el) => el), expected: initialValue }, // pass both in an object
  );
}
