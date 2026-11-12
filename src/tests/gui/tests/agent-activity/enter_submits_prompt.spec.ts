/**
 * Ported to the scenarios src/tests/scenarios/agent-activity/enter-sends-prompt.yaml,
 * shift-enter-adds-newline.yaml, prompt-box-resizes.yaml and
 * stop-empties-follow-up.yaml; kept for the one case no input can show — that
 * the app's own clear of the box dispatches no `input` event (it counts the
 * events with an injected listener, and its positive control dispatches one).
 *
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

import type { Page } from "@playwright/test";

import { test, expect } from "../../lib/fixtures";
import {
  isWindows,
  makeStubAgentDir,
  openAgentActivity,
  promptInput,
  stubAgentLaunchEnv,
  waitForMethodCount,
} from "./acp-stub-agent-harness";
import {
  promptInputCounts,
  startCountingPromptInput,
} from "./prompt-input-counter";

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

  // A trace launch plus one agent turn.
  test.setTimeout(240_000);

  // Fixture-free, so it runs before `ctPage` launches the app (and its agent).
  test.beforeEach(() => {
    fs.writeFileSync(stub.logPath, "");
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
    // the box still holds the text; the scenario prompt-box-resizes.yaml). A write that
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

});
