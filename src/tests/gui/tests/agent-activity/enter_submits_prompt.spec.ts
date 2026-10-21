/**
 * Pressing Enter in the Agent Activity prompt submits it, exactly when the
 * Send button would; Shift+Enter is a newline.
 *
 * codetracer-pm issue 2026-10-21, "Pressing Enter in the Agent Activity
 * prompt box does not submit the prompt". The desktop routes every key
 * through ONE capture-phase listener (`src/frontend/ui/key_router.nim`,
 * Base-Keymaps-And-Layer-Stack.md §6.2), which reads the scope path off the
 * DOM focus chain. The prompt textarea carried no scope attribute, so the
 * focus was the pane `agentActivity` — a list pane — and `Enter` resolved to
 * `list.activate`; the desktop ran it and stopped the event, so the
 * textarea's own handler (`isonim_agent_activity_view.nim`,
 * `attachInputEvents`) never saw the key. The same held for a real keypress.
 * The fix makes every native text field an input element of the scope path
 * (§4.2: `textInputFocus` is "the focused element accepts text … a prompt"),
 * and the prompt names itself `input:agent-prompt`.
 *
 * What this spec holds the product to:
 *   - typing a prompt and pressing Enter sends it to the agent and clears the
 *     field, and the router does not run `list.activate` for it;
 *   - Shift+Enter inserts a newline and sends nothing;
 *   - once a turn has finished (the stub refuses the first, #862), Enter
 *     submits the next prompt and its answer appears.
 * Enter during a running turn does not submit: the view's handler checks
 * `isLoading`, which is also when Send gives way to Stop. The stub answers
 * each prompt at once, so that window is not reachable here; it is covered by
 * the view's own guard rather than claimed by this spec.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double is used: the agent
 * itself. The pane spawns `codex-acp` from `PATH`; this spec puts a
 * `codex-acp` wrapper around `fixtures/acp-refusing-agent.js` first on the
 * launched app's `PATH` (`acp-stub-agent-harness.ts`). The real agent needs a
 * paid account and network access and cannot be driven deterministically,
 * and nothing about it decides whether Enter submits — the defect is wholly
 * on the CodeTracer side — so the agent is the one thing worth replacing.
 * Everything else is production code: the key router, the pane's view, the
 * main process's `@agentclientprotocol/sdk` client speaking real JSON-RPC over
 * the stub's real stdin/stdout.
 *
 * Positive control: the stub logs every method it receives. Each submission
 * is asserted by the `session/prompt` that really reached it, never by the
 * pane's own echo of the prompt.
 *
 * Headless counterparts (headless-first policy):
 *   src/frontend/viewmodel/tests/unit/test_native_text_field_scope.nim
 *     (which focused element is a text field; Enter in one is the field's);
 *   src/tests/gui/tests/agent-activity/agent_activity_prompt_scope_view_test.nim
 *     (the prompt carries `data-scope-kind=input` / `data-scope-id=agent-prompt`).
 */

import * as fs from "node:fs";

import type { Page } from "@playwright/test";

import { test, expect } from "../../lib/fixtures";
import {
  isWindows,
  makeStubAgentDir,
  methodCount,
  openAgentActivity,
  promptInput,
  stubAgent,
  stubAgentLaunchEnv,
  waitForMethodCount,
} from "./acp-stub-agent-harness";

/** Every operation the desktop router ran since the last `clearKeyTrace`. */
async function keyTrace(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    (((globalThis as any).__ctKeyTrace ?? []) as string[]).slice(),
  );
}

async function clearKeyTrace(page: Page): Promise<void> {
  await page.evaluate(() => {
    (globalThis as any).__ctKeyTrace = [];
  });
}

/**
 * Focus the prompt and type `text` key by key — real keydowns through the
 * router, so a letter the router took (Debug mode's `n` steps over) would
 * be missing from the field.
 */
async function typePrompt(page: Page, text: string): Promise<void> {
  const input = promptInput(page);
  await input.click();
  await input.pressSequentially(text);
  await expect(input).toHaveValue(text);
}

const stub = makeStubAgentDir();

test.describe("Agent Activity - Enter submits the prompt", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(isWindows, "the stub codex-acp wrapper is a POSIX shell script");

  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
    launchEnv: stubAgentLaunchEnv(stub),
  });

  // A trace launch plus up to two agent turns, as in acp_prompt_failure.spec.ts.
  test.setTimeout(240_000);

  // Fixture-free, so it runs before `ctPage` launches the app (and its agent).
  test.beforeEach(() => {
    fs.writeFileSync(stub.logPath, "");
  });

  test("Enter sends the typed prompt to the agent and clears the field", async ({
    ctPage,
  }) => {
    await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);

    await typePrompt(ctPage, "Explain this trace");
    await clearKeyTrace(ctPage);
    await promptInput(ctPage).press("Enter");

    // Positive control: the prompt really reached the agent.
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(promptInput(ctPage)).toHaveValue("");
    // The key was the field's: the router did not activate a list row.
    expect(await keyTrace(ctPage)).not.toContain("list.activate");
  });

  test("Shift+Enter inserts a newline and sends nothing", async ({ ctPage }) => {
    await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);

    await typePrompt(ctPage, "first line");
    await promptInput(ctPage).press("Shift+Enter");
    await promptInput(ctPage).pressSequentially("second line");
    await expect(promptInput(ctPage)).toHaveValue("first line\nsecond line");
    expect(methodCount(stub.logPath, "session/prompt")).toBe(0);

    // Then Enter sends the two-line prompt — once. A Shift+Enter that had
    // also submitted would show here as a second `session/prompt`.
    await promptInput(ctPage).press("Enter");
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(promptInput(ctPage)).toHaveValue("");
    expect(methodCount(stub.logPath, "session/prompt")).toBe(1);
  });

  test("after a finished turn, Enter submits the next prompt and it is answered", async ({
    ctPage,
  }) => {
    const panel = await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);

    await typePrompt(ctPage, "Explain this trace");
    await promptInput(ctPage).press("Enter");
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    // The stub refuses the first turn (#862); wait until it is over, which is
    // when Send is offered again.
    await expect(panel.locator(".agent-turn-failed")).toHaveCount(1, {
      timeout: 30_000,
    });
    await expect(panel.locator(".agent-start-button")).toHaveCount(1);

    await typePrompt(ctPage, "Try again");
    await clearKeyTrace(ctPage);
    await promptInput(ctPage).press("Enter");
    await waitForMethodCount(stub.logPath, "session/prompt", 2);
    await expect(panel.locator(".agent-com")).toContainText(
      stubAgent.SECOND_TURN_TEXT,
      { timeout: 30_000 },
    );
    expect(await keyTrace(ctPage)).not.toContain("list.activate");
  });
});
