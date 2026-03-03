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

// ---------------------------------------------------------------------------
// Path constants (shared with ct_helpers.ts)
// ---------------------------------------------------------------------------

const currentDir = path.resolve();
const codetracerInstallDir = path.dirname(currentDir);
const testProgramsPath = path.join(codetracerInstallDir, "test-programs");
const linksPath = path.join(codetracerInstallDir, "src", "build-debug");

const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
const codetracerPath =
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(linksPath, "bin", "ct");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const OK_EXIT_CODE = 0;
const EDITOR_WINDOW_INDEX = 1;
const MAX_CONNECT_ATTEMPTS = 12;
const RETRY_DELAY_MS = 1_000;
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
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function setupLdLibraryPath(): void {
  process.env.LD_LIBRARY_PATH = process.env.CT_LD_LIBRARY_PATH;
}

function cleanupCodetracerEnvVars(): void {
  delete process.env.CODETRACER_TRACE_ID;
  delete process.env.CODETRACER_CALLER_PID;
  delete process.env.CODETRACER_IN_UI_TEST;
  delete process.env.CODETRACER_TEST;
}

function recordTestProgram(recordArg: string): number {
  process.env.CODETRACER_IN_UI_TEST = "1";

  const ctProcess = childProcess.spawnSync(
    codetracerPath,
    ["record", recordArg],
    {
      cwd: codetracerInstallDir,
      stdio: "pipe",
      encoding: "utf-8",
    },
  );

  if (ctProcess.error !== undefined || ctProcess.status !== OK_EXIT_CODE) {
    throw new Error(
      `ct record failed: error=${ctProcess.error}; status=${ctProcess.status}\n${ctProcess.stderr}`,
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
  const firstWindow = await app.firstWindow();
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
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  if (extra) {
    Object.assign(env, extra);
  }
  return env;
}

/**
 * Resolves the chromium executable path from $PLAYWRIGHT_BROWSERS_PATH.
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
  const chromeSubdir = fs
    .readdirSync(path.join(browsersDir, chromiumDir))
    .find((d: string) => d.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new Error(
      `no chrome-linux* directory found in ${browsersDir}/${chromiumDir}`,
    );
  }
  return path.join(browsersDir, chromiumDir, chromeSubdir, "chrome");
}

// ---------------------------------------------------------------------------
// Launch strategies
// ---------------------------------------------------------------------------

interface LaunchResult {
  page: Page;
  electronApp: ElectronApplication | null;
  /** Cleanup function called during teardown. */
  teardown: () => Promise<void>;
}

async function launchTraceElectron(sourcePath: string): Promise<LaunchResult> {
  setupLdLibraryPath();

  const fullSourcePath = path.join(testProgramsPath, sourcePath);
  const traceId = recordTestProgram(fullSourcePath);

  console.log(`# launching Electron for trace ${traceId}`);

  process.env.CODETRACER_CALLER_PID = process.pid.toString();
  process.env.CODETRACER_TRACE_ID = traceId.toString();
  process.env.CODETRACER_IN_UI_TEST = "1";
  process.env.CODETRACER_TEST = "1";

  const app = await _electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [],
  });

  const page = await getEditorWindow(app);

  return {
    page,
    electronApp: app,
    teardown: async () => {
      try {
        await app.close();
      } catch {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchTraceWeb(sourcePath: string): Promise<LaunchResult> {
  setupLdLibraryPath();

  const fullSourcePath = path.join(testProgramsPath, sourcePath);
  const traceId = recordTestProgram(fullSourcePath);

  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();

  console.log(
    `# launching ct host for trace ${traceId} on port ${httpPort}`,
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
    { cwd: codetracerInstallDir },
  );

  const chromiumPath = resolveChromiumPath();
  const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
    .split(/\s+/)
    .filter(Boolean);
  const browser = await chromium.launch({
    executablePath: chromiumPath,
    args: extraArgs,
  });

  const page = await browser.newPage();

  // Wait for ct host to become ready with retry-based navigation.
  let connected = false;
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS && !connected; attempt++) {
    try {
      await page.goto(`http://localhost:${httpPort}`, {
        timeout: GOTO_TIMEOUT_MS,
      });
      connected = true;
    } catch {
      if (attempt < MAX_CONNECT_ATTEMPTS) {
        await sleep(RETRY_DELAY_MS);
      }
    }
  }
  if (!connected) {
    ctProcess.kill();
    await browser.close();
    throw new Error(
      `Failed to connect to ct host on port ${httpPort} after ${MAX_CONNECT_ATTEMPTS} attempts`,
    );
  }

  return {
    page,
    electronApp: null,
    teardown: async () => {
      try {
        ctProcess.kill();
      } catch {
        /* already exited */
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

  const app = await _electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [],
    env: makeCleanEnv(),
  });

  const page = await getEditorWindow(app);

  return {
    page,
    electronApp: app,
    teardown: async () => {
      try {
        await app.close();
      } catch {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchEditMode(folderPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  console.log(`# launching edit mode for ${folderPath}`);

  const app = await _electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: ["edit", folderPath],
    env: makeCleanEnv(),
  });

  const page = await getEditorWindow(app);

  return {
    page,
    electronApp: app,
    teardown: async () => {
      try {
        await app.close();
      } catch {
        /* already closed */
      }
      cleanupCodetracerEnvVars();
    },
  };
}

async function launchDeepReview(jsonPath: string): Promise<LaunchResult> {
  setupLdLibraryPath();
  console.log(`# launching deepreview mode for ${jsonPath}`);

  const app = await _electron.launch({
    executablePath: codetracerPath,
    cwd: codetracerInstallDir,
    args: [`--deepreview=${jsonPath}`],
    env: makeCleanEnv(),
  });

  const page = await getEditorWindow(app);

  return {
    page,
    electronApp: app,
    teardown: async () => {
      try {
        await app.close();
      } catch {
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
    ) => {
      let result: LaunchResult;

      switch (launchMode) {
        case "trace": {
          if (!sourcePath) {
            throw new Error(
              "sourcePath must be set via test.use() for trace launch mode",
            );
          }
          if (deploymentMode === "web") {
            result = await launchTraceWeb(sourcePath);
          } else {
            result = await launchTraceElectron(sourcePath);
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
