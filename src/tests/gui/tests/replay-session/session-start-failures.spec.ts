/* eslint-disable @typescript-eslint/no-magic-numbers -- path lengths are the subject */

/**
 * A session the desktop cannot start FAILS, naming the cause, instead of
 * waiting for ever or drawing its panes over no backend.
 *
 * Three ways a desktop session's start fails before any replay runs, each
 * observed on the real product:
 *
 * 1. The session manager cannot bind its socket: under a `CODETRACER_HOME`
 *    deep enough that `<home>/tmp/session-manager/<pid>.sock` is longer than
 *    a Unix socket address holds (`sockaddr_un.sun_path`), the session
 *    manager refuses it by name and exits. The main process used to retry
 *    its connection for ever, so no window ever opened and a spec failed on
 *    `firstWindow`'s timeout. It must exit non-zero, naming the socket path
 *    and the session manager's exit status.
 * 2. The session manager cannot be started at all (its binary is missing):
 *    the same, naming the binary.
 * 3. A replay cannot be started for the trace (its replay command is
 *    missing): the session manager answers `ct/start-replay` with
 *    `success: false`, and the GUI must show that answer
 *    (`CODETRACER::trace-load-error`, an error notification) rather than an
 *    editor with no backend behind it.
 *
 * What is real: the build's `ct`, Electron, main process, renderer and
 * session manager. Cases 1 and 2 start `ct` directly rather than through the
 * fixture's launch, because the fixture refuses the very home case 1 needs
 * (`lib/socket-path-bound.ts`) and both cases end before a window exists.
 * Cases 2 and 3 run from a prefix that mirrors the build's through symbolic
 * links and leaves one binary out (`lib/prefix-without.ts`): that is the
 * missing prerequisite under test, and nothing else is replaced.
 *
 * POSIX only: on Windows the session manager listens on TCP (no socket path
 * to be too long) and Electron is launched directly rather than through
 * `ct`, which a mirrored prefix relies on.
 */

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import {
  test,
  expect,
  codetracerInstallDir,
  codetracerPath,
  codetracerPrefix,
} from "../../lib/fixtures";
import { prefixWithout } from "../../lib/prefix-without";
import { maxUnixSocketPathBytes, scratchBase } from "../../lib/socket-path-bound";
import { StatusBar } from "../../page-objects/status_bar";

const isWindows = process.platform === "win32";

/**
 * How long a refusal may take. Both start-up failures are decided within a
 * second or two of the session manager starting; the bound is wide for a
 * loaded host, and is what turns the defect (no exit at all) into a failure.
 */
const REFUSAL_DEADLINE_MS = 60_000;

/** How often a wait looks again. */
const POLL_MS = 200;

/**
 * A checked-in recording every host replays: no rr, no recorder. Opened from
 * a scratch copy, because importing a folder writes beside the recording.
 */
const TRACE_FIXTURE = path.join(
  codetracerInstallDir,
  "src/db-backend/tests/fixtures/gdscript/gf_values",
);

interface Exit {
  /** True when `ct` was still running at `REFUSAL_DEADLINE_MS` (then stopped). */
  stillRunning: boolean;
  code: number | null;
  signal: NodeJS.Signals | null;
  output: string;
}

/** Variables of the test's environment a launch must not inherit. */
const NOT_INHERITED = new Set([
  "CODETRACER_RECORDING_ID",
  "CODETRACER_TRACE_ID",
  "CODETRACER_CALLER_PID",
  "CODETRACER_PREFIX",
]);

/** Stop `pid`'s process group (Electron's helpers, the session manager). */
function killGroup(pid: number | undefined): void {
  if (pid === undefined) return;
  try {
    process.kill(-pid, "SIGKILL");
  } catch {
    // Already gone.
  }
}

/**
 * Run `ct` (the welcome screen, no trace) with `env` over the test's own
 * environment, and wait for it to exit, or for `REFUSAL_DEADLINE_MS`; then
 * stop everything it started (its own process group).
 */
async function runCtUntilExit(ct: string, env: Record<string, string>): Promise<Exit> {
  const childEnv: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !NOT_INHERITED.has(key)) childEnv[key] = value;
  }
  Object.assign(
    childEnv,
    {
      CODETRACER_IN_UI_TEST: "1",
      CODETRACER_TEST: "1",
      CT_HMR: "0",
      CODETRACER_NEW_TRACE_POLICY: "window",
    },
    env,
  );
  const child = childProcess.spawn(ct, [], {
    cwd: codetracerInstallDir,
    env: childEnv,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  const collect = (chunk: Buffer): void => {
    output += chunk.toString();
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  const deadline = Date.now() + REFUSAL_DEADLINE_MS;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) {
    await sleep(POLL_MS);
  }
  const stillRunning = child.exitCode === null && child.signalCode === null;
  killGroup(child.pid);
  return { stillRunning, code: child.exitCode, signal: child.signalCode, output };
}

/** A scratch home (and XDG config home) under `/tmp`, `homeLength` bytes deep. */
function scratchHomes(homeLength: number): { root: string; home: string; xdg: string } {
  const root = fs.mkdtempSync(path.join(scratchBase(), "ct-ssf-"));
  const xdg = path.join(root, "x");
  fs.mkdirSync(xdg);
  const home = path.join(root, "h".repeat(Math.max(1, homeLength - root.length - 1)));
  fs.mkdirSync(home);
  return { root, home, xdg };
}

test.describe("a desktop session that cannot start fails, naming the cause", () => {
  test.skip(isWindows, "the session manager uses TCP on Windows, and Electron is launched directly");

  test("a session manager that cannot bind its socket ends the desktop, naming the path", async () => {
    const max = maxUnixSocketPathBytes() ?? 0;
    // `<home>/tmp/session-manager/<pid>.sock` is past the bound for any pid
    // once `<home>` alone leaves fewer than 27 bytes.
    const { root, home, xdg } = scratchHomes(max - 20);
    try {
      const exit = await runCtUntilExit(codetracerPath, {
        CODETRACER_HOME: home,
        XDG_CONFIG_HOME: xdg,
      });
      const { stillRunning, code, output } = exit;
      expect(stillRunning, `ct was still running after ${REFUSAL_DEADLINE_MS} ms:\n${output}`).toBe(false);
      expect(code, output).not.toBe(0);
      expect(code, output).not.toBeNull();
      const socketDir = path.join(home, "tmp", "session-manager");
      // The session manager's own refusal, and the main process's.
      expect(output).toContain("sun_path");
      expect(output).toMatch(/session-manager .*exited/);
      expect(output).toContain(socketDir);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  test("a session manager that cannot be started ends the desktop, naming it", async () => {
    const { root, home, xdg } = scratchHomes(40);
    const prefix = prefixWithout(codetracerPrefix, ["session-manager"]);
    try {
      const exit = await runCtUntilExit(path.join(prefix, "bin", "ct"), {
        CODETRACER_HOME: home,
        XDG_CONFIG_HOME: xdg,
        CODETRACER_PREFIX: prefix,
      });
      const { stillRunning, code, output } = exit;
      expect(stillRunning, `ct was still running after ${REFUSAL_DEADLINE_MS} ms:\n${output}`).toBe(false);
      expect(code, output).not.toBe(0);
      expect(code, output).not.toBeNull();
      expect(output).toContain(path.join(prefix, "bin", "session-manager"));
    } finally {
      fs.rmSync(prefix, { recursive: true, force: true });
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

test.describe("a replay that cannot start is reported to the user", () => {
  test.skip(isWindows, "a mirrored prefix needs Electron to be launched through ct");

  // The prefix and the trace copy are made by fixture functions, when the
  // test runs, and removed after it: values made when the file is collected
  // would be made in every process that collects it (the runner too) and
  // removed in none that does not run the test.
  test.use({
    launchMode: "trace-folder",
    // eslint-disable-next-line no-empty-pattern -- Playwright reads a fixture's dependencies from this pattern; it has none
    sourcePath: async ({}, use) => {
      const traceFolder = fs.mkdtempSync(path.join(scratchBase(), "ct-ssf-trace-"));
      try {
        fs.cpSync(TRACE_FIXTURE, traceFolder, { recursive: true });
        await use(traceFolder);
      } finally {
        fs.rmSync(traceFolder, { recursive: true, force: true });
      }
    },
    // eslint-disable-next-line no-empty-pattern -- Playwright reads a fixture's dependencies from this pattern; it has none
    codetracerPrefixOverride: async ({}, use) => {
      const prefix = prefixWithout(codetracerPrefix, ["replay-server"]);
      try {
        await use(prefix);
      } finally {
        fs.rmSync(prefix, { recursive: true, force: true });
      }
    },
  });

  test("the session manager's refusal reaches the GUI as an error", async ({
    ctPage,
    codetracerPrefixOverride,
  }) => {
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const missing = path.join(codetracerPrefixOverride, "bin", "replay-server");
    const seen: string[] = [];
    const deadline = Date.now() + REFUSAL_DEADLINE_MS;
    // Toasts dismiss themselves after 3 s: poll, and keep every one seen.
    while (Date.now() < deadline && !seen.some((text) => text.includes(missing))) {
      for (const text of await statusBar.activeNotificationTexts()) {
        if (!seen.includes(text)) seen.push(text);
      }
      await ctPage.waitForTimeout(POLL_MS);
    }
    expect(
      seen.some((text) => text.includes(missing)),
      `no notification named the missing replay command ${missing}; shown: ${JSON.stringify(seen)}`,
    ).toBe(true);
  });
});
