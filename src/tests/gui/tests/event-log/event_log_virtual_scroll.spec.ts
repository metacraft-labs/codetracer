/**
 * THE EVENT LOG'S VIRTUAL SCROLL KEEPS THE FOOTER, THE ROWS AND THE SCROLL
 * POSITION IN STEP — TO THE VERY END OF THE LOG (#850, Pxor-Bugs M80).
 *
 * Reported: "the Event Log contains 73 rows, but reaching the bottom shows only
 * Rows 19 to 34 of 73", the viewport sometimes blank, and "scrolling toward
 * row 30 may result in rows starting around 21 being rendered instead".
 *
 * The contract: `GUI/Core-Panes/Event-Log-Pane.md` § "The scrollbar is a
 * scrubber over the whole log" (the scroll range spans the WHOLE filtered log,
 * `recordsFiltered`) and `GUI/Layout-And-Navigation/Scrollbar-Scrubbers.md`
 * § 3 item 3 (a newer position supersedes an older one; the pane is never
 * drawn empty).
 *
 * WHAT IS UNDER TEST. The desktop list is the generic IsoNim view
 * (`viewmodel/views/isonim_event_log_view.nim`) over `EventLogVM`, which asks
 * the engine for the window the pane shows (`ct/event-load`). Its scroll
 * area is as tall as the whole list at the rows' measured pitch, the held
 * window sits at its place in it, and the footer ("Rows X to Y of Z") reports
 * the viewport the panel host measured. So the footer is only true when the
 * pitch the area is laid out with is the rows' own. These cases therefore
 * compare three independent readings:
 *
 *   * the FOOTER, as the user reads it (the input, the end-row and the count);
 *   * the ROWS IN VIEW: the drawn `<tr>`s whose box intersects the scroll
 *     body's box, each at the absolute position in the log it carries
 *     (`data-position`), so no scroll arithmetic is involved;
 *   * the LOG'S SIZE, the scroll area's height over the rows' pitch.
 *
 * WHY THREE CASES. (a) is the reported end-of-log symptom. (b) is the
 * "jumped, and the wrong window is on screen" symptom, driven as a scrub
 * would drive it: two positions in successive frames, so the viewport's
 * coalescing has to land on the second. (c) is the "repeating the same
 * scrolling action can produce different results" claim: the same gestures,
 * ten times, must read identically.
 *
 * No mocks: a real `noir_space_ship` recording (70 events, the population
 * PLAT-51's capture also uses), the real `ct`, a real `replay-server` and the
 * real Electron app.
 *
 * READINESS. These cases wait on the Event Log itself (its table answered
 * with a non-empty log), not on `readyOnEntryTest`: that helper waits for the
 * status bar's `.location-path`, which `status_bar.styl` currently hides on
 * purpose, and what is under test here is the event log, not the status bar.
 */

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });
test.setTimeout(300_000);

/** The issue's population is 73; the milestone asks for at least 70. */
const MIN_EVENTS = 70;

type Reading = {
  /** "Rows <start> to <end> of <of>", as the footer shows it (1-based). */
  footer: { start: number; end: number; of: number };
  /** The whole list's size, from the scroll area's geometry. */
  total: number;
  /** Absolute 0-based positions of the drawn rows whose box is in view. */
  inView: number[];
  /** Rows drawn in the `tbody` (in view or not), and where that window starts. */
  drawn: number;
  displayStart: number;
  /** The scroll body's geometry, for the failure message. */
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
  /** The pane's loading indicator is up: a window is in flight. */
  processing: boolean;
  /**
   * An animated scroll is running on the scroll body. The list does not
   * animate its scroll (the DataTables Scroller it replaced did), so this is
   * always false; kept so a reading's shape, and `settled`, stay as they were.
   */
  animating: boolean;
};

/** One reading of the list, straight from the DOM. */
async function read(page: Page): Promise<Reading> {
  return page.evaluate(() => {
    const pane = document.querySelector("[id^='eventLogComponent']");
    const body = pane?.querySelector(".eventLog-scroll-body") as HTMLElement | null;
    const space = pane?.querySelector(".eventLog-scroll-space") as HTMLElement | null;
    const footer = pane?.querySelector(".data-tables-footer") as HTMLElement | null;
    if (!pane || !body || !space || !footer) {
      throw new Error("event log: the list, its scroll area or its footer is missing");
    }
    const box = body.getBoundingClientRect();
    // Each drawn row carries its absolute position in the list.
    const rows = Array.from(
      pane.querySelectorAll(".eventLog-dense-table tbody tr.eventLog-row"),
    ) as HTMLElement[];
    const positions = rows.map((tr) => parseInt(tr.dataset.position ?? "-1", 10));
    const inView: number[] = [];
    rows.forEach((tr, i) => {
      const r = tr.getBoundingClientRect();
      // A row counts as in view when at least a pixel of it is inside the body.
      if (r.bottom > box.top + 1 && r.top < box.bottom - 1) {
        inView.push(positions[i]);
      }
    });
    inView.sort((x, y) => x - y);
    // The LOG'S SIZE, read from the geometry rather than from the footer: the
    // scroll area is as tall as the whole list at the rows' pitch.
    const pitch = rows.length > 1
      ? (rows[rows.length - 1].getBoundingClientRect().top - rows[0].getBoundingClientRect().top) /
        (rows.length - 1)
      : rows.length === 1 ? rows[0].getBoundingClientRect().height : 0;
    const total = pitch > 0 ? Math.round(space.getBoundingClientRect().height / pitch) : 0;
    const num = (el: Element | null) => parseInt((el?.textContent ?? "").trim(), 10);
    const input = footer.querySelector(".data-tables-footer-input") as HTMLInputElement | null;
    const loading = pane.querySelector(".event-log-loading") as HTMLElement | null;
    return {
      footer: {
        start: parseInt(input?.value ?? "", 10),
        end: num(footer.querySelector(".data-tables-footer-end-row")),
        of: num(footer.querySelector(".data-tables-footer-rows-count")),
      },
      total,
      inView,
      drawn: rows.length,
      displayStart: positions.length > 0 ? Math.min(...positions) : 0,
      scrollTop: body.scrollTop,
      scrollHeight: body.scrollHeight,
      clientHeight: body.clientHeight,
      processing: !!loading && getComputedStyle(loading).display !== "none",
      animating: false,
    };
  });
}

/**
 * Wait until the table has stopped moving: nothing in flight (no window being
 * fetched, no animated scroll running) and three consecutive readings, 250 ms
 * apart, identical. The viewport report is debounced and
 * the reply is asynchronous, so "settled" is a property of the readings, not a
 * fixed delay.
 */
async function settled(page: Page): Promise<Reading> {
  const deadline = Date.now() + 30_000;
  let last = "";
  let same = 0;
  let reading = await read(page);
  while (Date.now() < deadline) {
    await page.waitForTimeout(250);
    reading = await read(page);
    const key = JSON.stringify(reading);
    same = key === last && !reading.processing && !reading.animating ? same + 1 : 0;
    last = key;
    if (same >= 2) return reading;
  }
  throw new Error(`event log: the table never settled; last reading ${JSON.stringify(reading)}`);
}

/**
 * Put the scroll body at `fractions[0]`, then each next fraction one
 * animation frame later — the way a scrubber's drag feeds positions — and
 * return once the table has settled.
 */
async function scrollThrough(page: Page, fractions: number[]): Promise<Reading> {
  await page.evaluate(async (fs: number[]) => {
    const body = document.querySelector("[id^='eventLogComponent'] .eventLog-scroll-body") as HTMLElement;
    for (let i = 0; i < fs.length; i++) {
      if (i > 0) await new Promise((r) => requestAnimationFrame(() => r(null)));
      body.scrollTop = fs[i] * (body.scrollHeight - body.clientHeight);
    }
  }, fractions);
  return settled(page);
}

/** Open the trace's Event Log and wait for the whole-log count to arrive. */
async function openEventLog(page: Page): Promise<Reading> {
  const layout = new LayoutPage(page);
  await layout.waitForEventLogLoaded();
  await (await layout.eventLogTabs())[0].clickTab();
  const deadline = Date.now() + 120_000;
  let reading = await read(page);
  while (Date.now() < deadline && !(reading.total > 0 && reading.inView.length > 0)) {
    await page.waitForTimeout(500);
    reading = await read(page);
  }
  reading = await settled(page);
  // CONTROL — the defect needs a log long enough to be virtualised.
  expect(
    reading.total,
    `control: the recording must hold at least ${MIN_EVENTS} events; it holds ${reading.total}`,
  ).toBeGreaterThanOrEqual(MIN_EVENTS);
  return reading;
}

/** What a reading claims, as text for the failure messages. */
const show = (r: Reading) =>
  `footer "Rows ${r.footer.start} to ${r.footer.end} of ${r.footer.of}", ` +
  `rows in view ${r.inView.length ? `${r.inView[0] + 1}..${r.inView[r.inView.length - 1] + 1}` : "none"} ` +
  `(1-based), log ${r.total}, window ${r.displayStart}+${r.drawn}, ` +
  `scrollTop ${Math.round(r.scrollTop)}/${r.scrollHeight - r.clientHeight}`;

/** The checks of case (a) on one reading taken at the end of the log. */
function expectAtTheEnd(r: Reading): void {
  const n = r.total;
  expect(r.inView.length, `at the end, the body is empty: ${show(r)}`).toBeGreaterThan(0);
  expect(r.footer.of, `the footer's count is the whole log: ${show(r)}`).toBe(n);
  expect(r.footer.end, `at the end, the footer must read "… to ${n} of ${n}": ${show(r)}`).toBe(n);
  expect(
    r.inView[r.inView.length - 1],
    `at the end, the log's last event (row ${n}) must be drawn in view: ${show(r)}`,
  ).toBe(n - 1);
  expect(
    r.footer.start,
    `the footer's first row must be the first row in view: ${show(r)}`,
  ).toBe(r.inView[0] + 1);
}

/** The checks of case (b) on one reading taken after the 40% → 80% jump. */
function expectAtEightyPercent(r: Reading): void {
  expect(r.inView.length, `after the jump, the body is empty: ${show(r)}`).toBeGreaterThan(0);
  const viewport = r.inView.length;
  // The row the scroll position names: 80% of the way through the positions
  // the first visible row can take.
  const target = Math.round(0.8 * (r.total - viewport));
  expect(
    Math.abs(r.footer.start - 1 - target),
    `the footer's start row must be within one viewport (${viewport} rows) of row ${target + 1}: ${show(r)}`,
  ).toBeLessThanOrEqual(viewport);
  expect(
    Math.abs(r.inView[0] - target),
    `the rows in view must be within one viewport (${viewport} rows) of row ${target + 1}: ${show(r)}`,
  ).toBeLessThanOrEqual(viewport);
  expect(
    r.footer.start,
    `the footer's first row must be the first row in view: ${show(r)}`,
  ).toBe(r.inView[0] + 1);
}

test("scrolled to the end, the footer reads '… to N of N' over the rows in view, the last event among them", async ({
  ctPage,
}) => {
  await openEventLog(ctPage);
  expectAtTheEnd(await scrollThrough(ctPage, [1.0]));
});

test("a jump to 40% and then 80% within one frame settles on the 80% window, drawn and described", async ({
  ctPage,
}) => {
  await openEventLog(ctPage);
  expectAtEightyPercent(await scrollThrough(ctPage, [0.4, 0.8]));
});

test("the same gestures, ten times over, give the same correct result every time", async ({
  ctPage,
}) => {
  await openEventLog(ctPage);
  const ends: Reading[] = [];
  const jumps: Reading[] = [];
  for (let i = 0; i < 10; i++) {
    await scrollThrough(ctPage, [0.0]);
    ends.push(await scrollThrough(ctPage, [1.0]));
    await scrollThrough(ctPage, [0.0]);
    jumps.push(await scrollThrough(ctPage, [0.4, 0.8]));
  }
  ends.forEach(expectAtTheEnd);
  jumps.forEach(expectAtEightyPercent);
  // What the user sees — the footer and the rows in view — is identical on
  // every repetition. (The window the pane fetched may legitimately differ
  // in its buffer, so it is not compared.)
  const seen = (r: Reading) => JSON.stringify({ footer: r.footer, inView: r.inView });
  expect(ends.map(seen), "scrolling to the end must read the same every time").toEqual(
    Array(10).fill(seen(ends[0])),
  );
  expect(jumps.map(seen), "the 40% → 80% jump must read the same every time").toEqual(
    Array(10).fill(seen(jumps[0])),
  );
});
