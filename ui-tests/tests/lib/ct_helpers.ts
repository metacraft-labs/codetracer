// based on / copied from
//  https://playwright.dev/docs/api/class-electron
//  https://playwright.dev/docs/api/class-electronapplication#electron-application-browser-window
//  https://github.com/microsoft/playwright/blob/main/tests/electron/electron-app.spec.ts
//  ! https://github.com/spaceagetv/electron-playwright-example/blob/main/e2e-tests/main.spec.ts
// and others

import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";
import * as fs from "node:fs";

import { test, type Page } from "@playwright/test";
import { _electron, chromium } from "playwright";

const electron = _electron;

let electronApp; // eslint-disable-line @typescript-eslint/init-declarations
export let window: Page; // eslint-disable-line @typescript-eslint/init-declarations
export let page: Page; // eslint-disable-line @typescript-eslint/init-declarations

export const currentDir = path.resolve(); // the ui-tests dir
export const codetracerInstallDir = path.dirname(currentDir);
export const buildDebugPath = path.join(
  codetracerInstallDir,
  "src",
  "build-debug",
);
export const codetracerPath = path.join(buildDebugPath, "bin", "ct");
export const codetracerTestDir = path.join(currentDir, "tests");
export const testProgramsPath = path.join(currentDir, "programs");
export const testBinariesPath = path.join(currentDir, "binaries");
export const linksPath = path.join(codetracerInstallDir, "src", "links");
export const electronPath = path.join(linksPath, "electron");
export const indexPath = path.join(buildDebugPath, "src", "index.js");

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
  const relativePath = path.relative("programs", filePath);

  // Split the relative path into segments
  const pathSegments = relativePath.split(path.sep);

  // The first segment is the folder inside 'programs'
  // eslint-disable-next-line @typescript-eslint/no-magic-numbers
  const folderName = pathSegments[0];
  return folderName;
}

export function codeTracerRun(relativeSourceFilePath: string): void {
  test.beforeAll(async () => {
    setupLdLibraryPath();

    const sourceFilePath = path.join(testProgramsPath, relativeSourceFilePath);
    const sourceFileName = path.basename(
      relativeSourceFilePath,
      path.extname(relativeSourceFilePath),
    );
    // const sourceFileExtension = path.extname(sourceFilePath);
    const programName = getTestProgramNameFromPath(sourceFilePath);

    fs.mkdirSync(testBinariesPath, { recursive: true });

    const binaryFileName = `${programName}__${sourceFileName}`;
    const binaryFilePath = path.join(testBinariesPath, binaryFileName);

    buildTestProgram(sourceFilePath, binaryFilePath);

    const traceId = recordTestProgram(binaryFilePath);

    const inBrowser = process.env.CODETRACER_TEST_IN_BROWSER === "1";
    if (!inBrowser) {
      const runPid = 1;
      await replayCodetracerInElectron(binaryFileName, traceId, runPid);
    } else {
      await replayCodetracerInBrowser(binaryFileName, traceId);
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

/// end of exported public functions
/// ===================================

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
  binaryFileName: string,
  traceId: number,
  runPid: number,
): Promise<number> {
  // not clear, but maybe possible to directly augment the playwright test report?
  // test.info().annotations.push({type: 'something', description: `# starting codetracer for ${pattern}`});
  console.log(`# replay codetracer rr/gdb core process for ${binaryFileName}`);

  const ctProcess = childProcess.spawn(
    codetracerPath,
    ["start_core", binaryFileName, runPid.toString()],
    { cwd: codetracerInstallDir },
  );
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

  electronApp = await electron.launch({
    executablePath: electronPath,
    cwd: codetracerInstallDir,
    args: [indexPath],
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
      "chromium-1091",
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

function recordTestProgram(outputBinaryPath: string): number {
  // non-obvious options!
  // stdio: 'pipe', encoding: 'utf8' found form
  // https://stackoverflow.com/a/35690273/438099
  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["record", outputBinaryPath],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
    },
  );
  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    console.log(`ERROR: codetracer record: ${ctProcess.error}`);
    console.log(ctProcess.stderr);
    process.exit(ERROR_EXIT_CODE);
  }

  const lines = ctProcess.stdout.trim().split("\n");
  const lastLine = lines[lines.length - 1]; // eslint-disable-line @typescript-eslint/no-magic-numbers
  if (!lastLine.startsWith("> codetracer: finished with trace id: ")) {
    console.log("ERROR: unexpected last line of ct record:");
    console.log(lastLine);
    process.exit(ERROR_EXIT_CODE);
  }
  const traceIdTokenIndex = 2;
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
    `# codetracer recorded a trace for ${outputBinaryPath} with trace id ${maybeTraceId} succesfully`,
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

export class CodetracerTestError extends Error {
  constructor(msg: string) {
    super(msg);

    Object.setPrototypeOf(this, CodetracerTestError.prototype);
  }
}
