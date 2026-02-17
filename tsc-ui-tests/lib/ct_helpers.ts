// based on / copied from
//  https://playwright.dev/docs/api/class-electron
//  https://playwright.dev/docs/api/class-electronapplication#electron-application-browser-window
//  https://github.com/microsoft/playwright/blob/main/tests/electron/electron-app.spec.ts
//  ! https://github.com/spaceagetv/electron-playwright-example/blob/main/e2e-tests/main.spec.ts
// and others

import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, type Page } from "@playwright/test";
import { _electron, chromium } from "playwright";

const electron = _electron;

let electronApp; // eslint-disable-line @typescript-eslint/init-declarations
export let window: Page; // eslint-disable-line @typescript-eslint/init-declarations
export let page: Page; // eslint-disable-line @typescript-eslint/init-declarations

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
}

export function getTestProgramNameFromPath(filePath: string): string {
  if (filePath.startsWith("noir_")) {
    return path.basename(filePath);
  }
  const pathSegments = filePath.split(path.sep);
  // The first segment is the folder inside 'test-programs'
  return pathSegments[0];
}

export function ctRun(relativeSourcePath: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();

    const sourcePath = path.join(testProgramsPath, relativeSourcePath);
    // const sourceFileName = path.basename(
    //   relativeSourceFilePath,
    //   path.extname(relativeSourceFilePath),
    // );
    // const sourceFileExtension = path.extname(sourceFilePath);
    const programName = getTestProgramNameFromPath(relativeSourcePath);

    // fs.mkdirSync(testBinariesPath, { recursive: true });

    // const binaryFileName = `${programName}__${sourceFileName}`;
    // const binaryFilePath = path.join(testBinariesPath, binaryFileName);

    // TODO: if rr-backend?
    // buildTestProgram(sourceFilePath, binaryFilePath);

    const traceId = recordTestProgram(sourcePath);

    const inBrowser = process.env.CODETRACER_TEST_IN_BROWSER === "1";
    if (!inBrowser) {
      const runPid = 1;
      await replayCodetracerInElectron(programName, traceId, runPid);
    } else {
      await replayCodetracerInBrowser(programName, traceId);
    }
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
}

/// Launch CodeTracer in edit mode with a folder
export function ctEditMode(folderPath: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();
    await launchEditMode(folderPath);
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
    args: ["--welcome-screen"],
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
  runPid: number,
): Promise<number> {
  // not clear, but maybe possible to directly augment the playwright test report?
  // test.info().annotations.push({type: 'something', description: `# starting codetracer for ${pattern}`});
  console.log(`# replay codetracer rr/gdb core process for ${programName}`);

  const ctProcess = childProcess.spawn(
    codetracerPath,
    ["start_core", `${traceId}`, runPid.toString()],
    { cwd: codetracerInstallDir },
  );
  // ctProcess.stdout.setEncoding("utf8");
  // ctProcess.stdout.on("data", console.log);
  // ctProcess.stderr.setEncoding("utf8");
  // ctProcess.stderr.on("data", console.log);
  ctProcess.on("close", (code) => {
    console.log(`child process exited with code ${code}`);

    // eslint-disable-next-line @typescript-eslint/no-magic-numbers
    if (code !== 0) {
      throw new CodetracerTestError(
        `The backend process has exited with status code ${code}`,
      );
    }
  });

  process.env.CODETRACER_CALLER_PID = runPid.toString();
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
  return ctProcess.pid ?? NO_PID;
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

  // TODO: some kind of error with the test firefox on my setup/nixos
  // let firefoxBrowser = await firefox.launch();
  // page = await firefoxBrowser.newPage();

  if (process.env.PLAYWRIGHT_BROWSERS_PATH === undefined) {
    throw new CodetracerTestError(
      "expected `$PLAYWRIGHT_BROWSERS_PATH` env var to be set: can't find browser without it",
    );
  }
  const chromiumBrowser = await chromium.launch({
    executablePath: path.join(
      process.env.PLAYWRIGHT_BROWSERS_PATH,
      "chromium-1134",
      "chrome-linux",
      "chrome",
    ),
  });

  page = await chromiumBrowser.newPage();

  // TODO: something more stable
  const waitingTimeBeforeServerIsReadyInMs = 2_500;
  await wait(waitingTimeBeforeServerIsReadyInMs);

  await page.goto(`http://localhost:5005`);
  window = page;

  return ctProcess.pid ?? NO_PID;
}

async function replayCodetracerAndSetup(
  pattern: string,
  traceId: number,
): Promise<void> {
  const inBrowser = process.env.CODETRACER_TEST_IN_BROWSER === "1";
  if (!inBrowser) {
    const runPid = 1;
    await replayCodetracerInElectron(pattern, traceId, runPid);
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
