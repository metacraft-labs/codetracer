/**
 * The Agent Activity specs' shared harness around the stub ACP agent
 * `fixtures/acp-refusing-agent.js`: the `codex-acp` wrapper that puts it on
 * the launched app's `PATH`, its method log (each spec's positive control),
 * and opening the pane.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). The double is the agent, and
 * only the agent. The pane spawns `codex-acp` from `PATH`
 * (`src/frontend/index/ipc_subsystems/acp_ipc.nim`, `defaultCmd`); the real
 * agent needs a paid account and network access and cannot be made to answer
 * on demand, and everything these specs test sits on the CodeTracer side of
 * the ACP boundary. The main process's `@agentclientprotocol/sdk` client
 * speaks real JSON-RPC over the stub's real stdin/stdout, and the renderer
 * runs the real pane. The stub's own header gives the protocol it implements.
 *
 * Users: `acp_prompt_failure.spec.ts` (#862, a refused prompt) and
 * `enter_submits_prompt.spec.ts` (Enter in the prompt submits it).
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import type { Locator, Page } from "@playwright/test";

import { expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

// eslint-disable-next-line @typescript-eslint/no-require-imports
export const stubAgent = require("./fixtures/acp-refusing-agent.js") as {
  REFUSAL_DETAIL: string;
  SECOND_TURN_TEXT: string;
};

const stubAgentPath = path.join(__dirname, "fixtures", "acp-refusing-agent.js");
export const isWindows = process.platform === "win32";

export interface StubAgent {
  /** The directory holding the `codex-acp` wrapper; prepend it to `PATH`. */
  dir: string;
  /** Where the stub appends the method of every message it receives. */
  logPath: string;
}

/**
 * A directory holding one executable, `codex-acp`, that runs the stub agent
 * with the Node that runs the spec. `child_process.spawn` without a shell
 * resolves the bare name from `PATH`, so this is the binary the pane starts.
 *
 * `test.use` needs the path when the file loads, so there is one directory
 * per spec file; each spec empties the method log before every test (see its
 * `beforeEach`) so one launch cannot satisfy the next one's positive control.
 *
 * On Windows nothing is created: `spawn("codex-acp")` with no shell cannot
 * run a `.cmd` wrapper, and the specs skip there.
 */
export function makeStubAgentDir(): StubAgent {
  if (isWindows) return { dir: "", logPath: "" };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ct-acp-stub-codex-acp-"));
  const logPath = path.join(dir, "methods.log");
  const wrapper = path.join(dir, "codex-acp");
  fs.writeFileSync(
    wrapper,
    `#!/bin/sh\nexec "${process.execPath}" "${stubAgentPath}" "$@"\n`,
  );
  fs.chmodSync(wrapper, 0o755);
  return { dir, logPath };
}

/** The `launchEnv` that makes the launched app start `stub`. */
export function stubAgentLaunchEnv(stub: StubAgent): Record<string, string> {
  return {
    PATH: `${stub.dir}${path.delimiter}${process.env.PATH ?? ""}`,
    CT_FAKE_ACP_LOG: stub.logPath,
  };
}

export function receivedMethods(logPath: string): string[] {
  try {
    return fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

export function methodCount(logPath: string, method: string): number {
  return receivedMethods(logPath).filter((m) => m === method).length;
}

export async function waitForMethodCount(
  logPath: string,
  method: string,
  count: number,
): Promise<void> {
  await expect
    .poll(() => methodCount(logPath, method), {
      message: `the stub agent received ${count} ${method}`,
      timeout: 60_000,
    })
    .toBeGreaterThanOrEqual(count);
}

/** Bring the Agent Activity tab forward and return its panel. */
export async function openAgentActivity(page: Page): Promise<Locator> {
  const layout = new LayoutPage(page);
  await layout.waitForTraceLoaded();
  const tab = page.locator(".lm_title", { hasText: /agent activity/i }).first();
  await expect(tab).toBeAttached({ timeout: 30_000 });
  try {
    await tab.click({ timeout: 5_000 });
  } catch {
    // Xvfb can report GoldenLayout tabs as outside the viewport; the tab's
    // handler runs from a synthetic click just as well (see
    // `TabObject.clickTab`).
    await tab.dispatchEvent("click");
  }
  const panel = page.locator(".agent-ha-container").first();
  await expect(panel).toBeVisible({ timeout: 30_000 });
  return panel;
}

/** The pane's prompt textarea. */
export function promptInput(page: Page): Locator {
  return page.locator(".agent-ha-container textarea.agent-command-input").first();
}
