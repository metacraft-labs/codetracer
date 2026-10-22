/**
 * Playwright E2E test for cross-platform trace replay.
 *
 * Opens each pre-recorded MCR portable trace from `codetracer-example-recordings`
 * (recorded on different platforms/architectures) in the CodeTracer browser UI
 * via `ct host --trace-path=<folder>`, and checks that the session ends the way
 * the specifications say it must on this host:
 *
 * - **replayed** — the status bar shows a location in the recorded program's
 *   source, at a line the program has. Only a replay of the recording produces
 *   that; page title, panels and layout items are there before any replay
 *   answers, so they are not asserted as evidence of one.
 * - **refused** — the user is shown the prescribed refusal, word for word:
 *   `ct host`'s import refusal for a container version this build does not
 *   read, or `ct-mcr debugserver`'s refusal of a Linux interpose recording in
 *   Linux x86-64 trace mode, which reaches the GUI as an error notification.
 *
 * Which outcome a fixture must have is decided before the session opens, by
 * `expectedMcrPortableOutcome` in `lib/mcr-portable-replay.ts`, whose header
 * gives the rules and the specifications behind them. A fixture expected to
 * replay that does not fails, naming what the user was shown instead, with
 * one exception the issue allows: when the GUI shows exactly the symptom of
 * an open, recorded product defect and the replay worker's own log records
 * that defect's cause, the case is skipped as "not verified", naming the
 * issue (`knownDefectReport`). On a Linux x86-64 host that is the
 * macos-arm64 and windows-x86_64 fixtures: the replay worker builds its LLDB
 * target from the binary `ct-mcr debugserver` extracted, the debugserver
 * serves the trace from its static checkpoint mode (directly for the macOS
 * cooperative recording; after its cross-platform loader finds no initial
 * state for the Windows one), and the worker answers `RunToEntry` with "MCR
 * run-to-entry could not resolve an entry breakpoint"
 * (codetracer-pm/issues/2026-10-22-ct-mcr-static-checkpoint-mode-serves-a-foreign-isa-trace-as-the-host-isa.md,
 * codetracer-pm/issues/2026-10-22-ct-mcr-cross-platform-replay-ignores-a-windows-stage0-recordings-initial-state.md;
 * neither portable trace carries a line table either,
 * codetracer-pm/issues/2026-10-22-portable-export-bundles-no-dsym-or-pdb-debug-info.md).
 * Chrome only, nothing shown, any other error, or the symptom without that
 * fixture's cause in the log still fails.
 *
 * Each platform with a `trace-portable.ct` file gets its own independent test.
 * The test copies the portable trace into a temp folder as `trace.ct` (the name
 * ct host expects), spawns `ct host --trace-path=<folder>`, waits for the
 * server, then observes the GUI in a Chromium browser.
 *
 * Skips when the example-recordings sibling repo is not present.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test as base, expect, chromium } from "@playwright/test";

import { codetracerInstallDir } from "../lib/fixtures";
import {
  assertMcrSessionOutcome,
  expectedMcrPortableOutcome,
  knownDefectReport,
  mcrPortableFixture,
  observeMcrSession,
  replayWorkerLogs,
  type McrPortableFixture,
} from "../lib/mcr-portable-replay";
import { getFreeTcpPort } from "../lib/port-allocator";
import { ctHostPageUrl, withCtHostSessionSecret } from "../lib/ct-host-session";
import { StatusBar } from "../page-objects/status_bar";

// ---------------------------------------------------------------------------
// Path constants
// ---------------------------------------------------------------------------

// M49 — this used to be `path.dirname(path.resolve())`, i.e. one level
// up from Playwright's cwd. The cwd is `src/tests/gui`, so it resolved
// to `<repo>/src/tests`: `codetracerPrefix` became
// `<repo>/src/tests/src/build-debug`, which does not exist, and
// `workspaceRoot` became `<repo>/src` rather than the directory holding
// the sibling repos. Three levels are needed, and `lib/fixtures.ts`
// already exports the constant that does it — the same off-by-N this
// spec family has now hit three times (see the note in
// `lib/sibling-test-programs.ts`).
const codetracerPrefix = path.join(codetracerInstallDir, "src", "build-debug");
const ctBinaryName = process.platform === "win32" ? "ct.exe" : "ct";
const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
const codetracerPath =
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(codetracerPrefix, "bin", ctBinaryName);

// The example-recordings repo sits as a sibling of codetracer/ inside the
// workspace root.
const workspaceRoot = path.dirname(codetracerInstallDir);
const exampleRecordingsDir = path.join(
  workspaceRoot,
  "codetracer-example-recordings",
);
const MCR_DIR = path.join(exampleRecordingsDir, "mcr");

// The ct-mcr binary for trace enrichment during import. If the native
// recorder is available, ct host uses it to enrich portable traces.
const ctMcrCandidates = [
  path.join(codetracerPrefix, "bin", "ct-mcr"),
  path.join(
    workspaceRoot,
    "codetracer-native-recorder",
    "target",
    "debug",
    "ct-mcr",
  ),
];
const ctMcrPath = ctMcrCandidates.find((p) => fs.existsSync(p)) ?? "";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_CONNECT_ATTEMPTS = 25;
const RETRY_DELAY_MS = 1_500;
const GOTO_TIMEOUT_MS = 5_000;
const PORT_RELEASE_DELAY_MS = 500;
// How long ct host may take to read a fixture and refuse it before the test
// concludes that it did not refuse.
const IMPORT_REFUSAL_TIMEOUT_MS = 60_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Recursively kills a process and all its descendants.
 */
function killProcessTree(pid: number): void {
  if (process.platform === "win32") {
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

  for (const child of childPids) {
    killProcessTree(child);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already dead.
  }
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
    .filter(
      (d: string) => d.startsWith("chromium-") && !d.includes("headless"),
    )
    .sort()
    .pop();
  if (!chromiumDir) {
    throw new Error(`no chromium-* directory found in ${browsersDir}`);
  }

  const chromiumBase = path.join(browsersDir, chromiumDir);

  if (process.platform === "win32") {
    const chromeSubdir = fs
      .readdirSync(chromiumBase)
      .find((d: string) => d.startsWith("chrome-win"));
    if (!chromeSubdir) {
      throw new Error(`no chrome-win* directory found in ${chromiumBase}`);
    }
    return path.join(chromiumBase, chromeSubdir, "chrome.exe");
  }

  const chromeSubdir = fs
    .readdirSync(chromiumBase)
    .find((d: string) => d.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new Error(`no chrome-linux* directory found in ${chromiumBase}`);
  }
  return path.join(chromiumBase, chromeSubdir, "chrome");
}

/**
 * Creates a clean environment for launching CodeTracer processes,
 * free of leftover trace-related variables.
 */
function makeCleanEnv(
  extra?: Record<string, string>,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v;
  }
  // M-REC-6: CODETRACER_TRACE_ID → CODETRACER_RECORDING_ID; delete both.
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_RECORDING_ID;
  delete env.CODETRACER_CALLER_PID;
  delete env.CODETRACER_PREFIX;
  // The session secret every `ct host` started here is given
  // (../lib/ct-host-session.ts).
  withCtHostSessionSecret(env);
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  // Point ct host at the ct-mcr binary for trace enrichment if available.
  if (ctMcrPath) {
    env.CODETRACER_CT_MCR_CMD = ctMcrPath;
  }
  if (extra) {
    Object.assign(env, extra);
  }
  return env;
}

/**
 * Copies a directory tree recursively.
 */
function copyDirSync(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirSync(srcPath, destPath);
    } else if (entry.isSymbolicLink()) {
      // Resolve symlink and copy the target file.
      fs.copyFileSync(fs.realpathSync(srcPath), destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

/**
 * Prepares a temporary trace folder from a platform fixture.
 *
 * Copies the `trace-portable.ct` as `trace.ct` (the name ct host expects),
 * the recorded program's source into `files/source.c`, and the `binaries/`
 * directory if present.
 */
function prepareTraceFolder(fixture: McrPortableFixture): string {
  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-cross-platform-test-"),
  );

  // Copy the portable trace file as trace.ct.
  fs.copyFileSync(fixture.tracePath, path.join(tmpDir, "trace.ct"));

  // Copy the source file into files/ so the editor panel can display it.
  // `programSource` has the fixture's `source.c` link already followed.
  const filesDir = path.join(tmpDir, "files");
  fs.mkdirSync(filesDir, { recursive: true });
  fs.copyFileSync(fixture.programSource, path.join(filesDir, "source.c"));

  // Copy binaries directory if present (contains the original platform binary).
  const binariesDir = path.join(fixture.dir, "binaries");
  if (fs.existsSync(binariesDir)) {
    copyDirSync(binariesDir, path.join(tmpDir, "binaries"));
  }

  return tmpDir;
}

// ---------------------------------------------------------------------------
// Discover available platform fixtures (only those with trace-portable.ct)
// ---------------------------------------------------------------------------

const platforms: string[] = (() => {
  if (!fs.existsSync(MCR_DIR)) return [];
  return fs
    .readdirSync(MCR_DIR)
    .filter((d) =>
      fs.existsSync(path.join(MCR_DIR, d, "trace-portable.ct")),
    )
    .sort();
})();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

base.describe("cross-platform portable trace replay", () => {
  // Not `serial`: each platform is an independent session, and one
  // platform's failure must not hide the outcome of the others. The suite
  // runs with one worker, so the ct host instances still do not overlap.
  base.describe.configure({ timeout: 120_000 });

  base.skip(
    platforms.length === 0,
    `Skipped: no platform fixtures with trace-portable.ct found (expected at ${MCR_DIR})`,
  );

  for (const platform of platforms) {
    base(`${platform}: portable trace replays, or the user sees its refusal`, async () => {
      const fixture = mcrPortableFixture(MCR_DIR, platform);
      const expectation = expectedMcrPortableOutcome(fixture);
      console.log(
        `# cross-platform test [${platform}]: expected outcome on ` +
          `${process.platform}-${process.arch}: ` +
          (expectation.kind === "replay"
            ? "replay"
            : `refused by the ${expectation.refusedBy} (${expectation.reason})`),
      );
      const traceFolder = prepareTraceFolder(fixture);
      let ctProcess: childProcess.ChildProcess | null = null;
      let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

      try {
        // -- Allocate ports ---------------------------------------------------
        const httpPort = await getFreeTcpPort();
        const backendPort = await getFreeTcpPort();
        // Frontend socket must match backend socket (same port).
        const frontendPort = backendPort;

        // Set up LD_LIBRARY_PATH if configured (needed on Linux for native
        // shared libraries).
        if (process.env.CT_LD_LIBRARY_PATH) {
          process.env.LD_LIBRARY_PATH = process.env.CT_LD_LIBRARY_PATH;
        }

        console.log(
          `# cross-platform test [${platform}]: launching ct host ` +
            `--trace-path=${traceFolder} on port ${httpPort}`,
        );
        if (ctMcrPath) {
          console.log(`#   using ct-mcr at ${ctMcrPath}`);
        }

        // -- Launch ct host with --trace-path= (cligen requires = syntax) ----
        ctProcess = childProcess.spawn(
          codetracerPath,
          [
            "host",
            `--trace-path=${traceFolder}`,
            `--port=${httpPort}`,
            `--backend-socket-port=${backendPort}`,
            `--frontend-socket=${frontendPort}`,
          ],
          {
            cwd: codetracerInstallDir,
            env: makeCleanEnv(),
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
          },
        );

        // Capture stdout/stderr for diagnostics on failure.
        const ctStdout: string[] = [];
        const ctStderr: string[] = [];
        ctProcess.stdout?.on("data", (chunk: Buffer) => {
          ctStdout.push(chunk.toString());
        });
        ctProcess.stderr?.on("data", (chunk: Buffer) => {
          ctStderr.push(chunk.toString());
        });
        const ctExit = new Promise<number | null>((resolve) => {
          ctProcess?.on("exit", (code) => resolve(code));
        });

        // -- A container this build does not read: ct host refuses it -------
        //
        // The import reader refuses the fixture before anything is served,
        // so there is no page to look at. What the user sees is ct host's
        // output and its exit. The reason text is matched, not the way ct
        // host reports it: today it ends in an unhandled exception
        // (codetracer-pm/issues/2026-10-04-ct-importer-turns-a-container-refusal-into-false.md),
        // and a clean refusal must pass too. The android-arm64 and ios-arm64
        // fixtures are such containers until they are re-recorded
        // (codetracer-pm/issues/2026-10-02-example-recordings-fixtures-are-container-v3-v4.md).
        if (expectation.kind === "refused" && expectation.refusedBy === "import-reader") {
          let refusalTimer: NodeJS.Timeout | undefined;
          const exitCode = await Promise.race([
            ctExit,
            new Promise<"still running">((resolve) => {
              refusalTimer = setTimeout(() => resolve("still running"), IMPORT_REFUSAL_TIMEOUT_MS);
            }),
          ]);
          clearTimeout(refusalTimer);
          const output = ctStdout.join("") + ctStderr.join("");
          expect(
            exitCode,
            `[${platform}] ct host must refuse the fixture and exit (${expectation.reason}); ` +
              `output so far:\n${output}`,
          ).not.toBe("still running");
          expect(exitCode, `[${platform}] ct host exit code; output:\n${output}`).not.toBe(0);
          expect(output, `[${platform}] ct host must name the refusal`).toMatch(expectation.refusal);
          console.log(`# cross-platform test [${platform}]: ct host refused the fixture, exit ${exitCode}`);
          return;
        }

        // -- Launch browser and connect to ct host ----------------------------
        const chromiumPath = resolveChromiumPath();
        const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
          .split(/\s+/)
          .filter(Boolean);
        browser = await chromium.launch({
          executablePath: chromiumPath,
          args: extraArgs,
        });

        const page = await browser.newPage();

        // Retry connecting until ct host is ready.
        let connected = false;
        for (
          let attempt = 1;
          attempt <= MAX_CONNECT_ATTEMPTS && !connected;
          attempt++
        ) {
          try {
            await page.goto(ctHostPageUrl(httpPort), {
              timeout: GOTO_TIMEOUT_MS,
            });
            connected = true;
          } catch {
            if (attempt < MAX_CONNECT_ATTEMPTS) {
              console.log(
                `  ct host connect attempt ${attempt}/${MAX_CONNECT_ATTEMPTS} failed, retrying...`,
              );
              await sleep(RETRY_DELAY_MS);
            }
          }
        }

        if (!connected) {
          console.error(`ct host stdout:\n${ctStdout.join("")}`);
          console.error(`ct host stderr:\n${ctStderr.join("")}`);
          throw new Error(
            `Failed to connect to ct host on port ${httpPort} ` +
              `after ${MAX_CONNECT_ATTEMPTS} attempts [${platform}]`,
          );
        }

        console.log(`# ct host connected for ${platform}, observing the session...`);

        // -- Assertions: the replay's own output, or the refusal ------------
        //
        // Title, panels and layout items are present before any replay
        // answers, so they say nothing about the recording. The status bar's
        // location in the recorded program is produced only by a replay, and
        // a refusal reaches the user as an error notification.
        const statusBar = new StatusBar(page, page.locator("#status-base"));
        const observation = await observeMcrSession(statusBar, fixture);
        console.log(
          `# cross-platform test [${platform}]: location=` +
            JSON.stringify(observation.replayLocation) +
            ` notifications=${JSON.stringify(observation.notifications)}`,
        );
        // The symptom of an open, recorded defect, with its cause in the
        // replay worker's own log, is reported as not verified, as the issue
        // allows; every other outcome is asserted. The logs are read now,
        // while ct host's replay server (and so its run directory) is alive.
        const workerLogs = replayWorkerLogs(ctStdout.join("") + ctStderr.join(""));
        console.log(
          `# cross-platform test [${platform}]: replay worker logs read from ` +
            `${JSON.stringify(workerLogs.runDirs)} (${workerLogs.text.length} bytes)`,
        );
        const notVerified = knownDefectReport(observation, expectation, fixture, workerLogs);
        if (notVerified !== null) {
          console.log(`# cross-platform test [${platform}]: ${notVerified}`);
          base.skip(true, notVerified);
        }
        assertMcrSessionOutcome(observation, expectation, fixture);

        console.log(`# cross-platform test [${platform}]: outcome is the expected ${expectation.kind}`);
      } finally {
        // -- Cleanup ----------------------------------------------------------
        if (ctProcess?.pid) {
          killProcessTree(ctProcess.pid);
        }
        await sleep(PORT_RELEASE_DELAY_MS);

        if (browser) {
          try {
            await browser.close();
          } catch {
            // Already closed.
          }
        }

        // Remove the temporary trace folder.
        try {
          fs.rmSync(traceFolder, { recursive: true, force: true });
        } catch {
          // Best-effort cleanup.
        }

        // Clean up env vars that ct host may have set.
        // M-REC-6: legacy CODETRACER_TRACE_ID retired; delete both names.
        delete process.env.CODETRACER_TRACE_ID;
        delete process.env.CODETRACER_RECORDING_ID;
        delete process.env.CODETRACER_CALLER_PID;
        delete process.env.CODETRACER_IN_UI_TEST;
        delete process.env.CODETRACER_TEST;
      }
    });
  }
});
