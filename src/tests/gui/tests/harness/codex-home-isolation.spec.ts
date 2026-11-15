/**
 * The agent a GUI test launch starts never gets the developer's Codex state.
 *
 * codetracer-pm issue 2026-11-12, "GUI test launches let `codex-acp` read the
 * real Codex login and write its sessions". Every launch mounts the Agent
 * Activity pane, the pane sends `CODETRACER::acp-session-init`, and the app
 * spawns `codex-acp` from `PATH` (`src/frontend/index/ipc_subsystems/acp_ipc.nim`,
 * `ensureAcpConnection`) with its own environment. The fixtures isolated
 * `CODETRACER_HOME` and `XDG_CONFIG_HOME` and nothing else, so `CODEX_HOME`
 * was the runner's: unset, Codex used `~/.codex` — the developer's ChatGPT
 * login and their session list, into which the test runs wrote 31 rollouts.
 *
 * What this spec holds the harness to, for both front ends (Electron and
 * `ct host`): the agent a launch starts is handed a `CODEX_HOME` that
 *   - is set (unset means `~/.codex`);
 *   - is the worker's own scratch Codex home (`process.env.CODEX_HOME` here,
 *     which `lib/fixtures.ts` set on import), not the developer's `~/.codex`
 *     and not whatever the runner inherited;
 *   - exists and holds no login, so a turn a spec might send fails instead of
 *     billing anyone.
 * Spec: codetracer-specs `spec/Architecture/Per-User-State-Locations.md`,
 * "Third-party agents a test launch starts".
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). The double is the agent, and
 * only the agent: the `codex-acp` wrapper of `acp-stub-agent-harness.ts`,
 * which records the `CODEX_HOME` it was started with and then runs the stub
 * ACP agent. The real agent is what this spec keeps away from the
 * developer's account; starting it to observe that would be the defect
 * itself. Everything that decides the agent's environment is production
 * code: `ct`, the Electron main process or `ct host`, and the pane that asks
 * for the session.
 *
 * Positive control: the stub logs every method it receives, and each test
 * waits for `session/new` — the agent really was started, by the pane, in
 * this launch — before it reads the recorded environment.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import {
  isWindows,
  makeStubAgentDir,
  openAgentActivity,
  stubAgentLaunchEnv,
  waitForMethodCount,
} from "../agent-activity/acp-stub-agent-harness";

const stub = makeStubAgentDir();

/** The `CODEX_HOME` of every start of the stub agent, in order. */
function recordedCodexHomes(): string[] {
  try {
    return fs
      .readFileSync(stub.envLogPath, "utf8")
      .split("\n")
      .filter((line) => line.startsWith("CODEX_HOME="))
      .map((line) => line.slice("CODEX_HOME=".length));
  } catch {
    return [];
  }
}

function realCodexHome(): string {
  return path.join(os.homedir(), ".codex");
}

for (const deploymentMode of ["electron", "web"] as const) {
  test.describe(`harness: the agent a ${deploymentMode} launch starts gets a scratch CODEX_HOME`, () => {
    // eslint-disable-next-line @typescript-eslint/no-unused-expressions
    test.skip(isWindows, "the stub codex-acp wrapper is a POSIX shell script");

    test.use({
      sourcePath: "py_console_logs/main.py",
      launchMode: "trace",
      deploymentMode,
      // A runner whose own CODEX_HOME points somewhere real must not pass it
      // on either: the test's `launchEnv` stands in for that runner.
      launchEnv: { ...stubAgentLaunchEnv(stub), CODEX_HOME: realCodexHome() },
    });

    test.setTimeout(240_000);

    // Fixture-free, so it runs before `ctPage` launches the app (and its agent).
    test.beforeEach(() => {
      fs.writeFileSync(stub.logPath, "");
      fs.writeFileSync(stub.envLogPath, "");
    });

    test("codex-acp is started with the worker's scratch Codex home", async ({ ctPage }) => {
      await openAgentActivity(ctPage);
      // Positive control: the pane really started the agent in this launch.
      await waitForMethodCount(stub.logPath, "session/new", 1);

      const homes = recordedCodexHomes();
      expect(homes.length, "the stub recorded its environment").toBeGreaterThanOrEqual(1);
      // The issue's own condition first: the agent was handed the
      // developer's Codex state (unset means `~/.codex`).
      for (const home of homes) {
        expect(home, "unset CODEX_HOME means the developer's ~/.codex").not.toBe("<unset>");
        expect(path.resolve(home), "the developer's own ~/.codex").not.toBe(path.resolve(realCodexHome()));
      }
      const workerCodexHome = process.env.CODEX_HOME;
      expect(workerCodexHome, "lib/fixtures.ts sets a worker CODEX_HOME").toBeDefined();
      for (const home of homes) {
        expect(home).toBe(workerCodexHome);
        expect(fs.statSync(home).isDirectory(), `${home} exists`).toBe(true);
        expect(fs.existsSync(path.join(home, "auth.json")), "no login in the scratch home").toBe(false);
      }
    });
  });
}
