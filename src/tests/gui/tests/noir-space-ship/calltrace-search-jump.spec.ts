/**
 * Call-trace search results land on their own call (codetracer#860).
 *
 * The Call Trace search lists every match of a query as a `.search-result`
 * row labelled `#<call key> - stepId(<tick>): <function>`. Each row names ONE
 * frame, so activating it must move the session into that frame AND mark that
 * frame's call-trace row as the one the session is in — both halves of
 * Click-Navigation.md §2.1 ("Activating a row moves the session into the
 * execution the row draws, and marks that row as the one the session is in").
 *
 * The reported defect: every result row's handler was created in a `for` loop
 * and read a loop-body variable — one variable for the whole loop under Nim's
 * by-reference closure capture — so a click on ANY result jumped to the LAST
 * match, while each row's label (computed eagerly) still read correctly.
 * Clicking only the first result would not catch every variant of that, and
 * clicking only the last would catch none, so this spec clicks the first, a
 * middle and the last result and requires each to land on the tick its own
 * label names, with distinct results landing on distinct ticks.
 *
 * The program is the Noir space-ship (`test-programs/noir_space_ship`), whose
 * `calculate_damage` is called once per asteroid. It has the shape the
 * report describes (one function, many calls at distinct ticks), which is
 * what this check needs.
 *
 * RUN IT WITH `CODETRACER_PERF_LIMIT_SCALE` (e.g. 8) where the Noir trace
 * opens slowly. On the host this was written on, opening the Noir trace froze
 * the renderer for 4-5 minutes, because the Filesystem pane rendered the whole
 * checkout as the trace's source folder, about 40,000 tree nodes fully
 * expanded. That is a defect of its own, filed separately, and it is NOT
 * what this spec checks, so the spec lets the documented knob scale its
 * budgets (see `perfLimitScale` below) instead of failing on load:
 *
 *   CODETRACER_PERF_LIMIT_SCALE=8 just test-gui-prebuilt \
 *     tests/noir-space-ship/calltrace-search-jump.spec.ts
 *
 * Nothing is mocked: the spec records the program with the real `ct record`,
 * opens it in the real Electron front end against the real replay backend, and
 * reads only what the user sees — the result labels, the status bar's
 * `path:line#tick` readout, and the call-trace row classes.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import type { Locator } from "@playwright/test";

/** One parsed `.search-result` label. */
interface SearchResultLabel {
  key: string;
  tick: number;
  name: string;
}

/**
 * Parse a result row's text, `#<key> - stepId(<tick>): <function>`, the label
 * `isonim_calltrace_view.searchResultLabel` renders. Throws on anything else,
 * so a changed label fails here with the text in hand rather than as a
 * confusing tick mismatch further down.
 */
function parseSearchResultLabel(text: string): SearchResultLabel {
  const match = /^#(\S+) - stepId\((\d+)\): (.+)$/.exec(text.trim());
  if (!match) {
    throw new Error(`unexpected .search-result label: ${JSON.stringify(text)}`);
  }
  return { key: match[1], tick: Number(match[2]), name: match[3] };
}

/**
 * Activate a search-result row the way a user does: one real click, whose
 * `mousedown` is what the row listens for. ONE activation, with no fallback:
 * a click whose `mousedown` has already been delivered can still time out
 * while the renderer is busy with the move it started, and a fallback that
 * then dispatched another `mousedown` activated the result twice (measured —
 * two `ct/calltrace-jump`s per row), which is not what a reader does.
 */
async function activateResult(row: Locator, timeoutMs: number): Promise<void> {
  await row.click({ timeout: timeoutMs });
}

/**
 * The test's budget follows `CODETRACER_PERF_LIMIT_SCALE`, the knob
 * `lib/performance-limits.ts` documents for lanes whose subject is not
 * performance: a host that needs the trace-open limits scaled needs the
 * test's own budget scaled with them, or the scaled limit is never reached.
 * Unset, or not a number >= 1, means 1 — the same reading that module uses.
 */
const perfLimitScale = (() => {
  const v = Number(process.env.CODETRACER_PERF_LIMIT_SCALE ?? "1");
  return Number.isFinite(v) && v >= 1 ? v : 1;
})();

test.describe("NoirSpaceShip — call-trace search results (codetracer#860)", () => {
  test.setTimeout(180_000 * perfLimitScale);
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  test.beforeEach(async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForCallTraceReady();
  });

  test("each search result jumps to its own call and marks that call's row", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.clickTab();

    // The query is typed into the pane's search field and the field's form is
    // SUBMITTED — the pane's own `submit` handler (`wireSearchForm`), the one
    // an Enter in the field is meant to reach. Not `press("Enter")`: on the
    // desktop a trusted Enter is taken by the key router's capture-phase
    // listener (`ui/key_router.nim`: Enter -> `list.activate` -> `aEnter`,
    // which does nothing while a field has focus, yet stops the event), so
    // neither the field's keydown handler nor the form's implicit submission
    // ever runs and no `ct/search-calltrace` is sent. That is a defect of its
    // own, recorded separately; this spec's subject is what a result does
    // once the list exists. (Nor `CallTracePane.search`, which presses Enter.)
    await callTrace.searchInput().fill("calculate_damage");
    await callTrace.searchInput().evaluate((input) => {
      const form = (input as HTMLInputElement).form;
      if (!form) throw new Error("the call-trace search field has no form");
      form.requestSubmit();
    });
    const results = callTrace.searchResultsContainer().locator(".search-result");
    await expect
      .poll(async () => results.count(), { timeout: 30_000 * perfLimitScale })
      .toBeGreaterThanOrEqual(3);

    const labels = (await results.allTextContents()).map(parseSearchResultLabel);
    for (const label of labels) {
      expect(label.name).toBe("calculate_damage");
    }
    // The results must name distinct calls at distinct ticks, or "landed on
    // its own tick" could not tell one row from another.
    expect(new Set(labels.map((l) => l.tick)).size).toBe(labels.length);

    const picks = [0, Math.floor(labels.length / 2), labels.length - 1];
    const landedTicks: number[] = [];
    const statusLocation = ctPage.locator("#status-base .location-path");
    const markedRows = callTrace
      .linesContainer()
      .locator(".calltrace-call-line.event-selected");

    for (const index of picks) {
      const wanted = labels[index];
      await test.step(`result #${index} (${wanted.key}, stepId ${wanted.tick})`, async () => {
        // The row is re-located each time: the list is rebuilt whenever the
        // results change, and a stale handle must not stand in for a fresh one.
        await activateResult(results.nth(index), 30_000 * perfLimitScale);

        // (a) The session moved to THIS result's tick. The status bar reads
        // `<path>:<line>#<tick>`; for this DB-backed trace the tick is the
        // step id the label prints as `stepId(N)`.
        await expect(statusLocation).toHaveText(new RegExp(`#${wanted.tick}$`), {
          timeout: 30_000 * perfLimitScale,
        });
        await expect(statusLocation).toContainText("shield.nr");

        // Record the tick the status bar actually shows, not the one wanted,
        // so the distinctness check below is about where the session went.
        const shown = /#(\d+)$/.exec((await statusLocation.textContent()) ?? "");
        expect(shown, "the status bar shows a tick").not.toBeNull();
        landedTicks.push(Number(shown![1]));

        // (b) Click-Navigation §2.1, second half: the call-trace row for that
        // call is the one marked as the call the session is in — exactly one
        // row, the `calculate_damage` call that starts at that tick. SOFT, so
        // one run reports both halves for every result: the test still fails
        // when a mark is missing, but (a) is still checked for the results
        // after it.
        await expect
          .soft(markedRows, `result #${index} marks its call-trace row`)
          .toHaveCount(1, { timeout: 60_000 });
        await expect
          .soft(markedRows, `result #${index}: the marked row is calculate_damage`)
          .toHaveAttribute("data-function", "calculate_damage", { timeout: 5_000 });
        await expect
          .soft(markedRows, `result #${index}: the marked row starts at stepId ${wanted.tick}`)
          .toHaveAttribute("data-rr-ticks", String(wanted.tick), { timeout: 5_000 });
        // The marked row is THE clicked call, by its key — the frame
        // identity of Click-Navigation.md §2.2. A tick alone is shared by every
        // frame a call chain collapses onto it.
        await expect
          .soft(markedRows, `result #${index}: the marked row is call #${wanted.key}`)
          .toHaveAttribute("data-call-key", wanted.key, { timeout: 5_000 });
        // And it is on screen: the row is brought into the Call Trace, not
        // merely loaded somewhere off the end of its scroll area.
        await expect
          .soft(markedRows, `result #${index}: the marked row is in view`)
          .toBeInViewport({ timeout: 5_000 });
      });
    }

    // Distinct results landed on distinct ticks — the property the bug broke.
    expect(new Set(landedTicks).size).toBe(picks.length);
  });
});
