/**
 * The Agent Activity prompt's VM -> element sync never looks like typing.
 *
 * codetracer-pm issue 2026-10-21, "agent-activity input sync recurses and
 * replayed transcripts stay on Thinking". The prompt box is a two-way
 * binding: the textarea's `input` listener writes the view model and tells
 * the host (`onInputChange`), and an effect writes the view model's value
 * back into the textarea (`syncInputValue`, in
 * `src/frontend/viewmodel/views/isonim_agent_activity_view.nim`). The sync
 * used to finish by dispatching a synthetic `input` event. That event ran the
 * listener, the host republished its whole state into the view model
 * (`syncLegacyAgentActivityIntoVM`), and the republish re-ran the effect. On a
 * review launch every republish changed the conversation and the loading
 * flag, so the cycle never settled: the renderer died with "Maximum call
 * stack size exceeded" (2 runs in 5), and the replayed transcript was left on
 * "Thinking" headers. codetracer 4bf805322 made the sync write the element
 * only when it differs and update the box's dependents itself.
 *
 * The headless counterpart, `agent-activity/agent_activity_input_sync_view_test.nim`,
 * runs the view on `MockRenderer`, which has no DOM event dispatch: a
 * `dispatchEvent` put back into the WebRenderer write would pass it. This
 * spec watches the real textarea instead. An event the page dispatches has
 * `isTrusted === false`
 * (https://dom.spec.whatwg.org/#dom-event-istrusted); one the user causes,
 * which is what Playwright's keyboard input produces, has `isTrusted ===
 * true`. Only the second kind may reach the prompt. The counter
 * (`../agent-activity/prompt-input-counter.ts`) is a capture-phase listener
 * on `document` that records every `input` event whose target is the prompt,
 * before the panel's own listener sees it, plus a wrapper on `dispatchEvent`
 * for an event dispatched on the prompt before it is attached, which never
 * reaches `document`. Counting the events, rather than waiting for the
 * RangeError, is what makes this deterministic: the loop did not always run
 * long enough to overflow the stack, but every turn of it dispatched one such
 * event.
 *
 * Two windows are watched:
 *   - the review launch, while the referenced session is replayed into the
 *     panel. The window has already painted the session when `ctPage` is
 *     handed over, so the counter is installed as the fixture's
 *     `rendererInitScript`, which runs at document start; the spec checks
 *     that it ran in this document, so the replay is really observed. The
 *     view runs the sync once while it builds the panel, on a textarea not
 *     yet attached (the counter's `dispatchEvent` wrapper sees that one),
 *     and, measured at codetracer 579592234, the replay itself does not
 *     re-run it;
 *   - typing into the prompt. Each keystroke changes the view model's value
 *     and so re-runs the sync, independently of how the launch went.
 * The same script keeps the uncaught errors, so the launch is also checked
 * for the RangeError itself. A positive control at the end dispatches one
 * synthetic `input` event from the test and expects the counter to see
 * exactly it.
 *
 * Neither window makes the sync WRITE the textarea: the view model's value
 * and the element's agree throughout (empty during the replay, and the typed
 * text while typing), so a dispatch that came back only on the write itself
 * would pass here. `../agent-activity/enter_submits_prompt.spec.ts` holds
 * that case, on the one path that writes: Enter emptying the box.
 *
 * Nothing is added to the product for this spec: the instrumentation is a
 * plain DOM listener in the test's own init script.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double is used: the
 * agent, `fixtures/acp-replay-agent.js`, as in `agent-activity-session.spec.ts`.
 * Its own header explains why a production agent cannot serve (credentials,
 * minutes per run, and no way to make it hold a known prior session). The
 * spec needs a session that replays into the panel on a review launch, and
 * that agent's default session is one. Every CodeTracer-side layer, from
 * `ct review` through `session/load` to the renderer, is production code.
 *
 * The dataset is written at module load rather than checked in, because a
 * session reference to a stdio ACP agent names an absolute path to it.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import {
  PROMPT_SELECTOR,
  promptInputCounterScript,
  promptInputCounts,
} from "../agent-activity/prompt-input-counter";
import { DeepReviewPage } from "../deepreview/page-objects/deepreview-page";

const fixturesDir = path.join(__dirname, "..", "deepreview", "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const replayAgentPath = path.join(__dirname, "fixtures", "acp-replay-agent.js");
const fixturesExist =
  fs.existsSync(sampleReviewPath) && fs.existsSync(replayAgentPath);

/** The session `acp-replay-agent.js` holds by default, and its length. */
const HELD_SESSION_ID = "session-fixture";
const HELD_SESSION_MESSAGES = 5;

// Its own directory, so this spec and `agent-activity-session.spec.ts` never
// rewrite each other's dataset when both run in one Playwright process.
const fixtureDir = path.join(os.tmpdir(), "ct-agent-activity-prompt-sync");
const datasetPath = path.join(fixtureDir, "review.json");

if (fixturesExist) {
  fs.mkdirSync(fixtureDir, { recursive: true });
  const dataset = JSON.parse(fs.readFileSync(sampleReviewPath, "utf8"));
  // The reference `ct review collect` stamps (see agent-activity-session.spec.ts).
  dataset.session = {
    sessionId: HELD_SESSION_ID,
    backend: "acp",
    workspacePath: fixtureDir,
    taskId: "",
    agentCommand: replayAgentPath,
    agentArgs: [],
    endpoint: "",
  };
  fs.writeFileSync(datasetPath, JSON.stringify(dataset, null, 2));
}

const MESSAGE_SELECTOR = ".agent-ha-container .msg-content";

test.describe("Agent Activity - the prompt sync dispatches no input event", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: datasetPath,
    rendererInitScript: promptInputCounterScript,
  });

  test("a review's session replays, and typing syncs, without a synthetic input event", async ({
    ctPage,
  }) => {
    // Window 1: the review launch, which replays the session into the panel.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await expect(ctPage.locator(MESSAGE_SELECTOR)).toHaveCount(
      HELD_SESSION_MESSAGES,
      { timeout: 15_000 },
    );
    // Non-null: the counter ran at the start of THIS document, so it was on
    // before the replay painted anything.
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 0,
      synthetic: 0,
      errors: [],
    });

    // Window 2: typing. Every keystroke changes the view model's value and
    // re-runs the sync; only the keystrokes themselves may reach the prompt.
    const prompt = ctPage.locator(PROMPT_SELECTOR).first();
    await prompt.click();
    await prompt.pressSequentially("why");
    await expect(prompt).toHaveValue("why");
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 3,
      synthetic: 0,
      errors: [],
    });

    // Positive control: a synthetic `input` event on the prompt is counted.
    await prompt.evaluate((el) => el.dispatchEvent(new Event("input")));
    expect(await promptInputCounts(ctPage)).toEqual({
      trusted: 3,
      synthetic: 1,
      errors: [],
    });
  });
});
