/**
 * Counts the `input` events that reach the Agent Activity prompt, split by
 * whether the user caused them.
 *
 * The prompt is a two-way binding (`isonim_agent_activity_view.nim`): the
 * textarea's `input` listener writes the view model and tells the host
 * (`onInputChange`), and `syncInputValue` writes the view model's value back
 * into the textarea. That second half must never look like typing, because
 * an `input` event from it runs the first half again (codetracer-pm issue
 * 2026-10-21, "agent-activity input sync recurses and replayed transcripts
 * stay on Thinking"). An event the page dispatches itself has
 * `isTrusted === false` (https://dom.spec.whatwg.org/#dom-event-istrusted);
 * Playwright's keyboard input is trusted, like the user's. So a spec that
 * types and counts can say exactly how many `input` events the app made up.
 *
 * The listener is on `document` in the capture phase, so it runs before the
 * panel's own listener on the textarea, and needs no textarea to exist yet.
 * An event dispatched on an element that is not in the document never
 * reaches `document`, though, and the view runs its sync once while it is
 * still building the panel, before the textarea is attached. So the script
 * also wraps `EventTarget.prototype.dispatchEvent` and counts, as synthetic,
 * an `input` event the page dispatches on a DETACHED prompt; one on an
 * attached prompt is left to the listener, so nothing is counted twice.
 * Measured at codetracer 579592234 with a dispatch put back into the sync: the
 * one sync run of a review launch was on a detached textarea, and without
 * the wrapper a counter installed at document start saw nothing.
 * The script also keeps every uncaught error, for specs that install it
 * before the app starts (where a `pageerror` listener added by the test is
 * too late).
 *
 * Users: `enter_submits_prompt.spec.ts` (installs it with `page.evaluate`)
 * and `../agent-activity-deepreview/agent-activity-prompt-sync.spec.ts`
 * (installs it at document start, as the fixture's `rendererInitScript`).
 */

import type { Page } from "@playwright/test";

export const PROMPT_SELECTOR = ".agent-ha-container textarea.agent-command-input";

/**
 * The counter, as a self-contained script: plain JavaScript in a string,
 * because it runs in the page, not in the spec's runtime. Installing it twice
 * in one document keeps the first counter.
 */
export const promptInputCounterScript = `
(() => {
  if (globalThis.__ctPromptInputCounts !== undefined) return;
  const counts = { trusted: 0, synthetic: 0, errors: [] };
  globalThis.__ctPromptInputCounts = counts;
  const selector = ${JSON.stringify(PROMPT_SELECTOR)};
  const isPrompt = (target) => target instanceof Element && target.matches(selector);
  document.addEventListener("input", (event) => {
    if (!isPrompt(event.target)) return;
    if (event.isTrusted) counts.trusted += 1;
    else counts.synthetic += 1;
  }, { capture: true });
  // A dispatch on a detached prompt does not propagate to the listener
  // above; count it here. \`matches\` works on a detached subtree, so the
  // panel's container is found as long as the textarea is already in it.
  const dispatchEvent = EventTarget.prototype.dispatchEvent;
  EventTarget.prototype.dispatchEvent = function (event) {
    if (event instanceof Event && event.type === "input" &&
        isPrompt(this) && !this.isConnected) {
      counts.synthetic += 1;
    }
    return dispatchEvent.call(this, event);
  };
  window.addEventListener("error", (event) => {
    counts.errors.push(String(event.message));
  });
})();
`;

export interface PromptInputCounts {
  /** `input` events the user caused (`isTrusted`). */
  trusted: number;
  /** `input` events the page dispatched itself. */
  synthetic: number;
  /** Messages of the uncaught errors since the counter was installed. */
  errors: string[];
}

/** Install the counter in the page's current document. */
export async function startCountingPromptInput(page: Page): Promise<void> {
  await page.evaluate(promptInputCounterScript);
}

/** The counter's state, or null when it was not installed in this document. */
export async function promptInputCounts(
  page: Page,
): Promise<PromptInputCounts | null> {
  return page.evaluate(() => {
    const counts = (globalThis as any).__ctPromptInputCounts;
    return counts === undefined
      ? null
      : {
          trusted: counts.trusted as number,
          synthetic: counts.synthetic as number,
          errors: [...(counts.errors as string[])],
        };
  });
}
