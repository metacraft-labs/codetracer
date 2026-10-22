/**
 * A COLUMN CHANGE MUST NOT SHRINK THE EVENT LOG'S SCROLL RANGE.
 *
 * Reported (codetracer#853): after changing the visibility and order of Event
 * Log columns a few times through the Columns menu, a 73-row log could only be
 * scrolled to roughly its 20th-30th row.
 *
 * Column presentation must preserve the filtered log's row count and range.
 *
 * ORIGINAL FAILURE (cdeb13b12). Every column change destroys the dense
 * DataTable and builds a new one (`events` in `ui/event_log.nim`, on `redrawColumns`). The new table is
 * built with `scrollY: 2000`, so its scroll body is 2000px tall until something
 * sizes it to the pane. That step (`resizeTable` -> `resizeTableScrollArea` +
 * `syncScrollerMeasurements` in `ui/datatable.nim`) ran on the data path only
 * for the first reply the component ever received. A rebuilt table therefore
 * kept a scroll body far taller than the pane: the pane clipped it after a few
 * dozen rows, while the Scroller believed all of them were on screen and left
 * only the difference between the log and 2000px to scroll. Measured on the
 * unfixed build with this fixture: an 80-row log in a 355px pane, rebuilt with a
 * 2000px scroll body and 211px of scroll range. The fix for #850 (907cafa16) now corrects
 * the row measurements and pane sizing, so these geometry checks already pass.
 *
 * REMAINING FAILURE (907cafa16). The once-per-component setup keeps the footer
 * from following a rebuilt table. The listener that writes the Scroller's window into the footer
 * on scroll was attached to the first table's scroll body element. DataTables
 * replaces that element on a rebuild, and a scroll that lands on rows already
 * loaded fetches nothing that would update the footer some other way. So once
 * the rebuilt table was sized correctly, scrolling it to the end still left the
 * footer at "Rows 1 to 14 of 80". This is the current red assertion after
 * three column changes. Attach the listener to each replacement scroll body;
 * The fix for #850 already supplies the measurement correction.
 *
 * WHAT IS ASSERTED, and why each part is there:
 *   - the scroll body's visible height is the same after three column changes as
 *     before them: a rebuilt table is sized to the pane, as the first one is;
 *   - the scroll body's `scrollHeight` (the Scroller's virtual height) is the
 *     same too, within one row: this is the scroll range itself;
 *   - after scrolling to the end, the footer reads `… to N of N` and the last
 *     event's row is VISIBLE inside the pane — not merely in the DOM, because an
 *     oversized scroll body renders rows the pane clips away. This is what the
 *     reporter could not reach.
 *
 * CONTROLS, because each assertion is vacuous without one:
 *   - the log must be longer than its viewport, or "the end is reachable" holds
 *     without any scrolling at all;
 *   - each column change must actually have rebuilt the header, or comparing the
 *     range before and after compares a table with itself;
 *   - the end-of-log check runs BEFORE the column changes too, so a failure
 *     after them is the column change's and not a scroll harness that never
 *     reaches the end.
 *
 * The fixture is `test-programs/py_long_event_log`: 80 numbered stdout writes,
 * the last one marked `[LAST]`.
 */

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import type { EventLogPane } from "../../page-objects/panes/event-log/event-log-pane";

test.use({ sourcePath: "py_long_event_log/main.py", launchMode: "trace" });
test.setTimeout(300_000);

const EVENT_COUNT = 80;
const LAST_MARK = "[LAST]";

type ScrollGeometry = {
  /** The Scroller's virtual height: the scroll body's full scrollable extent. */
  scrollHeight: number;
  /** The visible height of the scroll body. */
  clientHeight: number;
  /** The height of one rendered event row. */
  rowHeight: number;
};

/** Read the dense table's scroll body geometry from the DOM. */
async function scrollGeometry(page: Page): Promise<ScrollGeometry> {
  return page.evaluate(() => {
    const body = document.querySelector(
      ".eventLog-dense-table .dt-scroll-body",
    ) as HTMLElement | null;
    const row = body?.querySelector("tbody tr[data-rr-ticks]") as HTMLElement | null;
    return {
      scrollHeight: body?.scrollHeight ?? 0,
      clientHeight: body?.clientHeight ?? 0,
      rowHeight: row?.getBoundingClientRect().height ?? 0,
    };
  });
}

/** The visible column titles of the Event Log's header strip. */
async function headerTitles(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    Array.from(document.querySelectorAll(".eventLog-column-header > *"))
      .filter((e) => (e as HTMLElement).offsetParent !== null)
      .map((e) => (e.textContent ?? "").trim()),
  );
}

/**
 * Whether the row of the log's last event is visible: rendered, and inside both
 * the scroll body's box and the pane's (`.eventLog-dense-table`). The second box
 * is the one the user sees; a scroll body taller than the pane is clipped by it.
 */
async function lastRowVisible(page: Page): Promise<boolean> {
  return page.evaluate((mark) => {
    const pane = document.querySelector(".eventLog-dense-table") as HTMLElement | null;
    const body = pane?.querySelector(".dt-scroll-body") as HTMLElement | null;
    if (!pane || !body) return false;
    const row = Array.from(body.querySelectorAll("tbody tr")).find((tr) =>
      ((tr as HTMLElement).innerText ?? "").includes(mark),
    ) as HTMLElement | undefined;
    if (!row) return false;
    const r = row.getBoundingClientRect();
    const inside = (box: DOMRect) => r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
    return r.height > 0 && inside(body.getBoundingClientRect()) &&
      inside(pane.getBoundingClientRect());
  }, LAST_MARK);
}

/**
 * Scroll the dense table's body as far down as it goes, the way a wheel or a
 * dragged thumb would, until the Scroller has fetched and drawn the window
 * there. Returns once the scroll position has stopped moving.
 */
async function scrollToEnd(page: Page): Promise<void> {
  let lastTop = -1;
  await retry(
    async () => {
      const top = await page.evaluate(() => {
        const body = document.querySelector(
          ".eventLog-dense-table .dt-scroll-body",
        ) as HTMLElement | null;
        if (!body) return -1;
        body.scrollTop = body.scrollHeight;
        body.dispatchEvent(new Event("scroll"));
        return body.scrollTop;
      });
      const settled = top === lastTop && top > 0;
      lastTop = top;
      return settled;
    },
    { maxAttempts: 40, delayMs: 500 },
  );
  // Let the Scroller's fetch for the final window land and draw.
  await page.waitForTimeout(1_500);
}

/** Bring the view back to the start of the log. */
async function scrollToStart(page: Page): Promise<void> {
  await page.evaluate(() => {
    const body = document.querySelector(
      ".eventLog-dense-table .dt-scroll-body",
    ) as HTMLElement | null;
    if (!body) return;
    body.scrollTop = 0;
    body.dispatchEvent(new Event("scroll"));
  });
  await page.waitForTimeout(1_500);
}

/** Assert that the end of the log is reachable by scrolling. */
async function expectEndReachable(
  page: Page,
  eventLog: EventLogPane,
  when: string,
): Promise<void> {
  await scrollToEnd(page);
  await retry(async () => (await eventLog.ofRows()) > 0, {
    maxAttempts: 20,
    delayMs: 250,
  });
  const ofRows = await eventLog.ofRows();
  const toRow = await eventLog.toRow();
  expect(ofRows, `${when}: the footer's total must count every event`).toBe(
    EVENT_COUNT,
  );
  expect(
    toRow,
    `${when}: scrolled to the end, the footer must read '… to ${ofRows} of ${ofRows}'`,
  ).toBe(ofRows);
  expect(
    await lastRowVisible(page),
    `${when}: scrolled to the end, the last event's row ('${LAST_MARK}') must be visible in the pane`,
  ).toBe(true);
}

/**
 * Click one control of the Columns menu and wait until the rebuilt table has
 * a header different from `before` and rows again.
 */
async function changeColumns(
  page: Page,
  selector: string,
  before: string[],
): Promise<string[]> {
  await page.locator(selector).first().click();
  let after: string[] = [];
  await retry(
    async () => {
      after = await headerTitles(page);
      const rows = await page
        .locator(".eventLog-dense-table .dt-scroll-body tbody tr[data-rr-ticks]")
        .count();
      return rows > 0 && JSON.stringify(after) !== JSON.stringify(before);
    },
    { maxAttempts: 40, delayMs: 250 },
  );
  // CONTROL — the change must have rebuilt the header.
  expect(after, `control: '${selector}' must change the header`).not.toEqual(
    before,
  );
  // Let the rebuilt table's first reply land and anything scheduled after it run.
  await page.waitForTimeout(2_000);
  return after;
}

test("column changes keep the Event Log's scroll range over the whole log", async ({
  ctPage,
}) => {
  // Readiness is the Event Log's own: it is the only pane this test reads.
  const layout = new LayoutPage(ctPage);
  await layout.waitForEventLogLoaded();
  const eventLog = (await layout.eventLogTabs())[0];
  await eventLog.clickTab();

  await retry(async () => (await eventLog.ofRows()) >= EVENT_COUNT, {
    maxAttempts: 60,
    delayMs: 500,
  });
  // Give the first-load re-measure its turn.
  await ctPage.waitForTimeout(1_500);

  const baseline = await scrollGeometry(ctPage);
  // CONTROL — a log that fits in its viewport needs no scroll range at all.
  expect(
    baseline.scrollHeight,
    "control: the log must be taller than its viewport",
  ).toBeGreaterThan(baseline.clientHeight);
  expect(baseline.rowHeight, "control: a row must be rendered").toBeGreaterThan(0);

  // CONTROL — the harness reaches the end of an untouched table.
  await expectEndReachable(ctPage, eventLog, "before any column change");
  await scrollToStart(ctPage);

  // The reporter's steps: change visibility and order through the Columns menu.
  const columnsButton = ctPage.locator(".eventLog-columns-button").first();
  await columnsButton.click();
  await ctPage.waitForTimeout(400);

  let header = await headerTitles(ctPage);
  header = await changeColumns(
    ctPage,
    '.eventLog-column-option[data-column="kind"] .eventLog-column-check',
    header,
  );
  header = await changeColumns(
    ctPage,
    '.eventLog-column-option[data-column="output"] .eventLog-column-left',
    header,
  );
  header = await changeColumns(
    ctPage,
    '.eventLog-column-option[data-column="location"] .eventLog-column-check',
    header,
  );

  await columnsButton.click();
  await ctPage.waitForTimeout(400);

  const after = await scrollGeometry(ctPage);
  expect(
    Math.abs(after.clientHeight - baseline.clientHeight),
    `a rebuilt table must be sized to the pane: the scroll body was ` +
      `${baseline.clientHeight}px tall before the column changes, ${after.clientHeight}px after`,
  ).toBeLessThanOrEqual(1);
  const tolerance = Math.max(baseline.rowHeight, after.rowHeight);
  expect(
    Math.abs(after.scrollHeight - baseline.scrollHeight),
    `the scroll range must not change with the columns: ` +
      `${baseline.scrollHeight}px before, ${after.scrollHeight}px after ` +
      `(rows ${baseline.rowHeight}px / ${after.rowHeight}px)`,
  ).toBeLessThanOrEqual(tolerance);

  await expectEndReachable(ctPage, eventLog, "after three column changes");
});
