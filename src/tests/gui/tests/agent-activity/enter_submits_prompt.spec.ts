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
 *   - the box grows with the lines typed into it, and shrinks back to one
 *     line whenever the app empties it: after Enter has sent it, and after
 *     Stop has ended a turn the user was typing a follow-up during. The app
 *     empties the box programmatically (VM -> element, `syncInputValue` in
 *     `isonim_agent_activity_view.nim`), which fires no `input` event, so
 *     the sync has to resize the box itself (codetracer 4bf805322); on Stop
 *     nothing else does. Nothing headless can hold this: `MockRenderer` has
 *     no layout;
 *   - that programmatic clear dispatches no `input` event either: only the
 *     user's keystrokes reach the prompt (`prompt-input-counter.ts` tells
 *     the two apart by `isTrusted`). `MockRenderer` dispatches no DOM events,
 *     so this too is held only here, and, for a review's replay, in
 *     `../agent-activity-deepreview/agent-activity-prompt-sync.spec.ts`;
 *   - once a turn has finished (the stub refuses the first, #862), Enter
 *     submits the next prompt and its answer appears.
 * Enter during a running turn does not submit: the view's handler checks
 * `isLoading`, which is also when Send gives way to Stop. The stub can hold a
 * turn open (`HOLD_MARKER`, used by the Stop test), but no test here presses
 * Enter during one, so that guard is covered by the view rather than claimed
 * by this spec.
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

import type { Locator, Page } from "@playwright/test";

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
import {
  promptInputCounts,
  startCountingPromptInput,
} from "./prompt-input-counter";

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

/**
 * The textarea's laid-out height in whole CSS pixels. Rounded because the
 * resize writes the height in `em`, and the `px` it lays out to can carry a
 * sub-pixel remainder that differs between two sizings of the same content.
 */
async function renderedHeight(input: Locator): Promise<number> {
  return input.evaluate((el) => Math.round(el.getBoundingClientRect().height));
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

  test("the prompt box grows with typed lines and shrinks back when Enter clears it", async ({
    ctPage,
  }) => {
    await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);
    const input = promptInput(ctPage);

    // The single-line height is the box auto-sized to one line of typing,
    // not its pre-typing CSS height, so both ends of the comparison come
    // from the same resize routine.
    await typePrompt(ctPage, "first line");
    const singleLine = await renderedHeight(input);

    // Typing goes through the host's own resize (`onInputChange`), so this
    // half holds whatever `syncInputValue` does; it shows the box really
    // grows, which is what makes the shrink below observable.
    for (const line of ["second line", "third line", "fourth line"]) {
      await input.press("Shift+Enter");
      await input.pressSequentially(line);
    }
    await expect(input).toHaveValue(
      "first line\nsecond line\nthird line\nfourth line",
    );
    await expect
      .poll(() => renderedHeight(input), {
        message: "the four-line prompt box is taller than one line",
      })
      .toBeGreaterThan(singleLine);

    // Enter submits, and the app empties the box programmatically: first the
    // VM -> element sync (`syncInputValue`, `isonim_agent_activity_view.nim`)
    // when `updateAgentUi` republishes an empty prompt, then the host's own
    // `clear(AgentActivityComponent)`. Both resize, so this holds the
    // behaviour, not either routine; the Stop test below is the one path
    // that only the sync serves.
    await input.press("Enter");
    // Positive control: the multi-line prompt really reached the agent.
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(input).toHaveValue("");
    await expect
      .poll(() => renderedHeight(input), {
        message: "the emptied prompt box is back to its single-line height",
      })
      .toBe(singleLine);
  });

  test("Stop empties a multi-line follow-up and the box shrinks back to one line", async ({
    ctPage,
  }) => {
    const panel = await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);
    const input = promptInput(ctPage);

    // A turn the stub holds open until it is cancelled (`HOLD_MARKER`), so
    // Stop is on offer. Its one line also gives the single-line height.
    const heldPrompt = `Explain ${stubAgent.HOLD_MARKER}`;
    await typePrompt(ctPage, heldPrompt);
    const singleLine = await renderedHeight(input);
    await input.press("Enter");
    // Positive control: the held prompt really reached the agent.
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(panel.locator(".agent-stop-button")).toHaveCount(1);

    // While the turn runs, the user types a follow-up over several lines;
    // the host's `onInputChange` grows the box.
    await input.click();
    await input.pressSequentially("follow-up");
    for (const line of ["second line", "third line"]) {
      await input.press("Shift+Enter");
      await input.pressSequentially(line);
    }
    await expect(input).toHaveValue("follow-up\nsecond line\nthird line");
    await expect
      .poll(() => renderedHeight(input), {
        message: "the three-line follow-up is taller than one line",
      })
      .toBeGreaterThan(singleLine);

    // Stop (`onStopPrompt` in `src/frontend/ui/agent_activity.nim`) empties
    // the host's prompt and republishes it, and nothing on the host resizes
    // the box: the VM -> element sync (`syncInputValue`) is the only thing
    // that writes the textarea here, so it has to resize it too.
    await panel.locator(".agent-stop-button").click();
    // Positive control: the stop really reached the agent.
    await waitForMethodCount(stub.logPath, "session/cancel", 1);
    await expect(input).toHaveValue("");
    await expect
      .poll(() => renderedHeight(input), {
        message: "the emptied prompt box is back to its single-line height",
      })
      .toBe(singleLine);
  });

  test("Enter's clear writes the box without dispatching an input event", async ({
    ctPage,
  }) => {
    await openAgentActivity(ctPage);
    await waitForMethodCount(stub.logPath, "session/new", 1);
    await startCountingPromptInput(ctPage);

    // Every typed letter is one trusted `input` event, and nothing else.
    await typePrompt(ctPage, "Explain");
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 7,
      synthetic: 0,
      errors: [],
    });

    // Enter's clear is the path on which the VM -> element sync really
    // writes the textarea (`updateAgentUi` republishes an empty prompt while
    // the box still holds the text; see the resize test above). A write that
    // dispatched `input` would run the panel's listener and the host's
    // `onInputChange` again, which is how the sync used to loop.
    await promptInput(ctPage).press("Enter");
    // Positive control: the prompt really reached the agent.
    await waitForMethodCount(stub.logPath, "session/prompt", 1);
    await expect(promptInput(ctPage)).toHaveValue("");
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 7,
      synthetic: 0,
      errors: [],
    });

    // Positive control: a synthetic `input` event on the prompt is counted.
    await promptInput(ctPage).evaluate((el) =>
      el.dispatchEvent(new Event("input")),
    );
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 7,
      synthetic: 1,
      errors: [],
    });
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
