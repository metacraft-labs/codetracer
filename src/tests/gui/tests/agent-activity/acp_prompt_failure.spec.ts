/**
 * #862: a prompt the agent refuses must fail the turn in the Agent Activity
 * pane, not vanish into the main-process log.
 *
 * `codetracer-specs/DeepReview/Agentic-Coding-Integration.md` §3.2 defines
 * `AgentFailed` ("Task failed with error") and §3.3 gives it "Red X replaces
 * icon". pxor's Codex agent answered `session/prompt` with a JSON-RPC error
 * (`-32603 Internal error`, the backend's "model is not supported" refusal in
 * `data`). The Electron main process awaited the prompt with no handler, so
 * the rejection was logged as an unhandled promise rejection, nothing reached
 * the renderer, and the pane kept its "Thinking" spinner for ever.
 *
 * What this spec holds the product to, for a refused turn:
 *   - the pane shows the turn as failed, with a red X, and shows the agent's
 *     own message (the reporter's refusal text, verbatim);
 *   - the loading state ends: no spinner, no "Agent is working", the Stop
 *     button is back to Send;
 *   - the session survives: the next prompt runs and is answered.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double is used: the agent
 * itself. The pane spawns `codex-acp` from `PATH`; this spec puts a
 * `codex-acp` wrapper around `fixtures/acp-refusing-agent.js` first on the
 * launched app's `PATH`. The real agent needs a paid account and network
 * access and cannot be made to refuse a turn on demand, and the defect sits
 * exactly at the ACP boundary, so the agent is the one thing worth replacing.
 * Everything on the CodeTracer side is production code: the main process's
 * `@agentclientprotocol/sdk` client speaks real JSON-RPC over the stub's real
 * stdin/stdout, and the renderer runs the real pane. The stub's own header
 * gives the protocol it implements.
 *
 * Positive control: the stub logs every method it receives, and each test
 * asserts the `session/prompt` really reached it before asserting on what the
 * pane made of the answer.
 *
 * Headless counterpart (headless-first policy):
 *   src/tests/gui/tests/agent-activity/agent_activity_failed_turn_view_test.nim
 *   (the failed-turn rendering of the pane's view, over MockRenderer).
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import type { Page } from "@playwright/test";

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const stubAgent = require("./fixtures/acp-refusing-agent.js") as {
  REFUSAL_DETAIL: string;
  SECOND_TURN_TEXT: string;
};

const stubAgentPath = path.join(__dirname, "fixtures", "acp-refusing-agent.js");
const isWindows = process.platform === "win32";

/**
 * A directory holding one executable, `codex-acp`, that runs the stub agent
 * with the Node that runs this spec. `child_process.spawn` without a shell
 * resolves the bare name from `PATH`, so this is the binary the pane starts.
 *
 * `test.use` needs the path when the file loads, so there is one directory
 * per file; the method log in it is emptied before every test (see the
 * `beforeEach`) so one launch cannot satisfy the next one's positive control.
 */
function makeStubAgentDir(): { dir: string; logPath: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ct-862-codex-acp-"));
  const logPath = path.join(dir, "methods.log");
  const wrapper = path.join(dir, "codex-acp");
  fs.writeFileSync(
    wrapper,
    `#!/bin/sh\nexec "${process.execPath}" "${stubAgentPath}" "$@"\n`,
  );
  fs.chmodSync(wrapper, 0o755);
  return { dir, logPath };
}

function receivedMethods(logPath: string): string[] {
  try {
    return fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

async function waitForMethodCount(
  logPath: string,
  method: string,
  count: number,
): Promise<void> {
  await expect
    .poll(() => receivedMethods(logPath).filter((m) => m === method).length, {
      message: `the stub agent received ${count} ${method}`,
      timeout: 60_000,
    })
    .toBeGreaterThanOrEqual(count);
}

/** Bring the Agent Activity tab forward and return its panel. */
async function openAgentActivity(page: Page) {
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

/**
 * Type a prompt and press Send.
 *
 * The Send button rather than Enter: under this harness a Playwright
 * `press("Enter")` on the textarea never reached the pane's submit callback
 * (no `[agent-activity]` log line at all), which is a separate question from
 * #862 and must not decide whether this spec sees the refusal.
 */
async function sendPrompt(page: Page, text: string): Promise<void> {
  const input = page.locator(".agent-ha-container textarea.agent-command-input").first();
  await input.fill(text);
  await page.locator(".agent-ha-container .agent-start-button").first().click();
}

const stub = isWindows ? { dir: "", logPath: "" } : makeStubAgentDir();

test.describe("#862 - a refused ACP prompt fails the turn in Agent Activity", () => {
  // `spawn("codex-acp")` with no shell cannot run a `.cmd` wrapper, and a
  // POSIX shell script is what this spec writes. The defect and the fix are
  // platform-independent Nim, so Linux/macOS carry the coverage.
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(isWindows, "the stub codex-acp wrapper is a POSIX shell script");

  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
    launchEnv: {
      PATH: `${stub.dir}${path.delimiter}${process.env.PATH ?? ""}`,
      CT_FAKE_ACP_LOG: stub.logPath,
    },
  });

  // A trace launch plus one or two agent turns. The config's 90 s default is
  // mostly spent recording and opening the trace on a shared host, which left
  // the pane assertions no time of their own.
  test.setTimeout(240_000);

  // Fixture-free, so it runs before `ctPage` launches the app (and its agent).
  test.beforeEach(() => {
    fs.writeFileSync(stub.logPath, "");
  });

  test("a refused prompt shows the turn failed with the agent's message and stops loading", async ({
    ctPage,
  }) => {
    const panel = await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);

    await sendPrompt(ctPage, "Explain this trace");

    // Positive control: the refusal below answers a prompt that really
    // reached the agent.
    await waitForMethodCount(stub.logPath, "session/prompt", 1);

    // The turn is marked failed, with the red X …
    const failedTurn = panel.locator(".agent-turn-failed");
    await expect(failedTurn).toHaveCount(1, { timeout: 30_000 });
    await expect(failedTurn.locator(".agent-turn-failed-icon")).toBeVisible();
    // … and carries the agent's own reason, verbatim.
    const error = failedTurn.locator(".agent-turn-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(stubAgent.REFUSAL_DETAIL);
    await expect(error).toContainText("Internal error");

    // Loading has stopped: no spinner, no "working" row, and the Stop button
    // has turned back into Send.
    await expect(panel.locator(".ai-status")).toHaveCount(0);
    await expect(panel.locator(".agent-working-indicator")).toHaveCount(0);
    await expect(panel.locator(".agent-stop-button")).toHaveCount(0);
    await expect(panel.locator(".agent-start-button")).toHaveCount(1);
  });

  test("after a refused turn the next prompt runs and is answered", async ({
    ctPage,
  }) => {
    const panel = await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);

    await sendPrompt(ctPage, "Explain this trace");
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(panel.locator(".agent-turn-failed")).toHaveCount(1, {
      timeout: 30_000,
    });

    await sendPrompt(ctPage, "Try again");
    await waitForMethodCount(stub.logPath, "session/prompt", 2);
    await expect(panel.locator(".agent-com")).toContainText(
      stubAgent.SECOND_TURN_TEXT,
      { timeout: 30_000 },
    );
    // The answered turn is not painted as failed; only the refused one is.
    await expect(panel.locator(".agent-turn-failed")).toHaveCount(1);
    await expect(panel.locator(".agent-stop-button")).toHaveCount(0);
  });
});
