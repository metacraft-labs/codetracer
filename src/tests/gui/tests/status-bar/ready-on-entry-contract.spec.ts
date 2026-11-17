/**
 * The negative half of the entry-readiness contract.
 *
 * `readyOnEntryTest` (`lib/fixtures.ts`) is the readiness gate every Electron
 * spec goes through.  Ready means the trace opened, the debugger reported an
 * entry location, and an editor shows it: the gutter cell carrying the
 * execution-pointer arrow (`READY_ON_ENTRY_SELECTOR`) is visible.  A
 * positive spec cannot tell a correct wait from one that would also pass on a
 * broken launch, so this file pins the failures:
 *
 *   1. Nothing on the page shows an entry location: a wedged launch.  It must
 *      fail after the whole budget, and say that no location arrived.
 *   2. The arrow is in the DOM but has no box.  This is the shape of the
 *      b27da3947 regression on the old footer signal (a blanket
 *      `display: none !important` hid the readout suite-wide), and the reason
 *      the wait is a *visibility* wait rather than an attachment wait.
 *   3. The status bar holds a location, visible even, but no editor draws the
 *      execution line.  Readiness must not fall back to the footer: the
 *      design hides `.location-path` (`docs/UI-Design-Decisions.md` D-05), so
 *      a wait that accepted it would accept a session the user cannot see
 *      stopped anywhere.  The diagnosis must say the location arrived and the
 *      editor did not draw it.
 *
 * and, so that the three failures are not explained by a wait that can never
 * pass, one positive case on the same synthetic markup.
 *
 * All four run against a synthetic page rather than the real app,
 * deliberately: the property under test belongs to the wait, and reproducing
 * a wedged CodeTracer launch on demand is not possible.  This is the one
 * place in the suite where mocking the page is the point; every other spec
 * drives the real Electron app.  The markup is the shape the app renders:
 * `lib/monaco_appearance.editorGutterLineHtml` inside Monaco's line-number
 * cell, and the footer from `isonim_status_view.nim`.
 *
 * Each negative test costs one full budget of wall clock, which is the price
 * of asserting that the budget is really spent before the wait gives up.
 */
import {
  READY_ON_ENTRY_BUDGET_MS,
  readyOnEntryTest as readyOnEntry,
  test,
  expect,
} from "../../lib/fixtures";

test.setTimeout(180_000);

/** One editor gutter row, as `editorGutterLineHtml` renders it. */
function gutterRow(line: number, executionLine: boolean): string {
  const highlight = executionLine
    ? "<div class='gutter-highlight-active'></div>"
    : "<div class='gutter-no-highlight' style='display:none'></div>";
  return (
    `<div class='line-numbers' style='height:19px'>` +
    `<div class='gutter' data-line=${line} style='display:block;height:100%'>` +
    `${highlight}<div class='gutter-line'>${line}</div>` +
    `<div class='diff-line'></div></div></div>`
  );
}

/** A Monaco editor on `uri` whose arrow, if any, is on `executionLine`. */
function editor(uri: string, executionLine: number | null, style = ""): string {
  const rows = [1, 2, 3, 4]
    .map((line) => gutterRow(line, line === executionLine))
    .join("");
  return (
    `<div class='monaco-editor' data-uri='${uri}' style='width:400px;${style}'>` +
    `<div class='margin'><div class='margin-view-overlays'>${rows}</div></div></div>`
  );
}

/** The footer, with the location readout the design hides. */
function footer(locationText: string, hidden = true): string {
  return (
    "<div id='status'><div id='status-base'>" +
    "<div id='file-info-status'><span class='file-info-status-language'>Python</span></div>" +
    "<span class='status-right'><span id='location-status'>" +
    `<span class='location-path status-inline' style='${hidden ? "display:none" : ""}'>` +
    `${locationText}</span></span></span></div></div>`
  );
}

/** Run `readyOnEntryTest` against `html` and return [failure message, ms]. */
async function readiness(
  page: import("@playwright/test").Page,
  html: string,
): Promise<{ message: string; elapsedMs: number }> {
  await page.setContent(`<html><body>${html}</body></html>`);
  const started = Date.now();
  let message = "";
  try {
    await readyOnEntry(page);
  } catch (failure) {
    message = (failure as Error).message;
  }
  return { message, elapsedMs: Date.now() - started };
}

test("ready_on_entry_fails_when_no_entry_location_arrives", async ({ page }) => {
  // An editor is open (the app opens one before the first stop), the footer
  // is laid out, and nothing carries a location.
  const { message, elapsedMs } = await readiness(
    page,
    editor("file:///tmp/main.py", null) + footer(""),
  );
  expect(
    message,
    "readyOnEntryTest must fail when no entry location ever arrives",
  ).not.toBe("");
  // The whole budget must be spent before giving up — a wait that bails early
  // would turn slow launches back into failures.
  expect(elapsedMs).toBeGreaterThanOrEqual(READY_ON_ENTRY_BUDGET_MS - 500);
  // ...and the message must say which budget was spent and what it saw, or
  // the next person to hit this has a bare timeout again.
  expect(message).toContain(`Timeout ${READY_ON_ENTRY_BUDGET_MS}ms exceeded`);
  expect(message).toContain("readyOnEntry diagnosis:");
  expect(message).toContain("execution-line cells=0");
  expect(message).toContain("no entry location arrived");
});

test("ready_on_entry_fails_when_the_execution_line_is_drawn_but_hidden", async ({
  page,
}) => {
  const { message, elapsedMs } = await readiness(
    page,
    editor("file:///tmp/main.py", 3, "display:none") + footer("/tmp/main.py:3#1"),
  );
  expect(
    message,
    "an execution line in the DOM without a box must not count as ready",
  ).not.toBe("");
  expect(elapsedMs).toBeGreaterThanOrEqual(READY_ON_ENTRY_BUDGET_MS - 500);
  expect(message).toContain(`Timeout ${READY_ON_ENTRY_BUDGET_MS}ms exceeded`);
  expect(message).toContain("execution-line cells=1");
  // The diagnosis must name this as a boxless element, and name the element
  // whose style took the box away, rather than file it as a slow launch.
  expect(message).toContain("IS drawn but has no box");
  expect(message).toContain("div.monaco-editor { display: none");
});

test("ready_on_entry_does_not_accept_the_status_bar_location_alone", async ({
  page,
}) => {
  // The status bar's readout visible and filled, the editor on the entry
  // file, and no arrow: the location reached the footer and not the editor.
  const { message, elapsedMs } = await readiness(
    page,
    editor("file:///tmp/main.py", null) + footer("/tmp/main.py:3#1", false),
  );
  expect(
    message,
    "a location in the footer is not a session the user can see stopped",
  ).not.toBe("");
  expect(elapsedMs).toBeGreaterThanOrEqual(READY_ON_ENTRY_BUDGET_MS - 500);
  expect(message).toContain('status-bar location="/tmp/main.py:3#1"');
  expect(message).toContain("but none draws the execution line");
});

test("ready_on_entry_passes_when_the_execution_line_is_visible", async ({
  page,
}) => {
  // The control for the three above: the same markup with the arrow drawn
  // resolves at once, so their failures are the wait refusing, not a wait
  // that cannot pass.
  const { message, elapsedMs } = await readiness(
    page,
    editor("file:///tmp/main.py", 3) + footer("/tmp/main.py:3#1"),
  );
  expect(message).toBe("");
  expect(elapsedMs).toBeLessThan(10_000);
});
