/**
 * THE FOOTER'S RANGE DOES NOT OUTLIVE THE PROVISIONAL ROW PITCH.
 *
 * Reported as a one-in-six failure of
 * `tests/welcome-screen/new_file_with_open_replay.spec.ts`: its "before"
 * snapshot recorded the Event Log's footer at 15 rows, and the pane then went
 * to 14 with no input (codetracer-pm issue 2026-10-25). The contract is
 * `GUI/Core-Panes/Event-Log-Pane.md` § "Table Display": the footer's range
 * reflects the measured row pitch, and a provisional size used to ask for the
 * first rows does not outlive the first measurement.
 *
 * WHY THE WINDOW EXISTS. Before any row is rendered there is no pitch to
 * measure, so the pane reports its size at a fallback pitch (24 px) to get the
 * first rows. The rows' real pitch is 26.79 px, so a 355 px body is 15 rows
 * until they arrive and 14 after. Measured at `c12d777ef`, the report carrying
 * the 14 went through the viewport debounce (100 ms), and long main-thread work
 * delayed that timer: the footer still said 15 about 0.8 s after the rows had
 * been measured.
 *
 * THE MECHANISM, AND WHY IT IS DETERMINISTIC. Long main-thread work during
 * startup is what the issue profiled (trace JSON parsing), and its timing is
 * what made the original failure intermittent. This spec places that work
 * itself. A MutationObserver sees the first event row, and a 30 ms timer then
 * blocks the main thread for 1500 ms. Thirty milliseconds orders after the
 * measure's 0 ms timer (so the measurement has happened) and before the 100 ms
 * debounce (so a debounced report cannot have been applied). It is that ORDER
 * that holds, not the wall clock: timers overdue together run by due time, and
 * the page is often busy here anyway (at `c12d777ef` the block started 950 ms
 * after the first row). The footer read as the block ends is therefore what
 * the pane shows between the measurement and whenever the page next gets to
 * run its timers.
 *
 * WHAT IS REAL. Everything: the real `ct`, a real recorded Python trace
 * (`py_console_logs/main.py`), a real `replay-server` and the real Electron
 * renderer with its own timers. There are no mocks. The only thing the test
 * adds is the busy loop, which stands for the real startup work, and the
 * footer's end is read from the class the view writes.
 *
 * CONTROLS, because the assertion is vacuous without them:
 *   - the observer must be installed before the first row exists, or the block
 *     would not follow the measurement; existing rows fail by name;
 *   - the block must really have run for its full length;
 *   - the measurement must have reached the pane before the block ended. The
 *     scroll area's height is the log's size times the pitch, written as soon
 *     as a report arrives, so at the block's end it must already be its final
 *     height: a stale footer beside it is the defect, and a stale height would
 *     only mean the block ran too early;
 *   - the fallback and the measured pitch must imply different row counts at
 *     this pane's height, or the case could not tell a stale range from a
 *     correct one.
 */

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";

test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });
test.setTimeout(180_000);

/** `EventRowFallbackPx` in `views/pane_measure_dom.nim`. */
const FALLBACK_ROW_PX = 24;
/** After the measure's 0 ms timer, before `ViewportDebounceMs` (100 ms). */
const BLOCK_DELAY_MS = 30;
/** A layout rounding allowance when comparing scroll heights, in px. */
const SCROLL_HEIGHT_SLACK_PX = 1;
/** Comfortably past the debounce; the issue measured about 800 ms of delay. */
const BLOCK_MS = 1500;

const EVENT_LOG_PANE = "#session-container-0 [id^='eventLogComponent']";

interface BlockRecord {
  /** The footer's end as the first row appeared, before the measure. */
  footerEndAtFirstRow: number;
  /** The footer's end as the block ended: the reading under test. */
  footerEndAfterBlock: number;
  /** The scroll area's height as the block ended, in px. */
  scrollHeightAfterBlock: number;
  /** From the first row to the block starting, in ms: reported, not asserted. */
  startedAfterMs: number;
  /** How long the block held the main thread, in ms. */
  heldForMs: number;
}

interface PaneReading {
  footerEnd: number;
  total: number;
  /** Rows partly or fully visible, by `pixelPaneViewport`'s own arithmetic. */
  visibleRows: number;
  /** The same count at the fallback pitch. */
  visibleRowsAtFallback: number;
  bodyHeightPx: number;
  scrollHeightPx: number;
  rowPitchPx: number;
}

/**
 * Arm the block. The observer watches the whole document because at this point
 * the pane may not be mounted yet. Rows already present fail by name: the case
 * could not then place the block relative to the measurement.
 */
async function armBlockOnFirstRow(page: Page): Promise<void> {
  await page.evaluate(
    ({ pane, blockDelayMs, blockMs }) => {
      const firstRowSelector = "#session-container-0 tr.eventLog-row";
      const existing = document.querySelectorAll(firstRowSelector).length;
      if (existing > 0) {
        throw new Error(
          `the Event Log already holds ${existing} rows when the probe is installed: ` +
            "the fixture handed the page over too late to observe the first measurement",
        );
      }
      const footerEnd = (): number => {
        const footer = document.querySelector(`${pane} .data-tables-footer`);
        const match = /(\d+)to(\d+)/.exec(footer?.className ?? "");
        return match ? Number(match[2]) : -1;
      };
      const observer = new MutationObserver(() => {
        if (document.querySelector(firstRowSelector) === null) return;
        observer.disconnect();
        const appeared = performance.now();
        const footerEndAtFirstRow = footerEnd();
        setTimeout(() => {
          const started = performance.now();
          while (performance.now() - started < blockMs) {
            // Hold the main thread, as the startup work the issue profiled did.
          }
          // Read before yielding: no timer can have run during the block.
          (window as any).__eventLogFooterBlock = {
            footerEndAtFirstRow,
            footerEndAfterBlock: footerEnd(),
            scrollHeightAfterBlock:
              (document.querySelector(`${pane} .eventLog-scroll-body`) as HTMLElement | null)?.scrollHeight ?? -1,
            startedAfterMs: started - appeared,
            heldForMs: performance.now() - started,
          };
        }, blockDelayMs);
      });
      observer.observe(document, { childList: true, subtree: true });
    },
    { pane: EVENT_LOG_PANE, blockDelayMs: BLOCK_DELAY_MS, blockMs: BLOCK_MS },
  );
}

/** The pane as it is now, with the count `pixelPaneViewport` would derive. */
async function readPane(page: Page): Promise<PaneReading> {
  return page.evaluate(
    ({ pane, fallbackRowPx }) => {
      const host = document.querySelector(pane);
      if (!host) throw new Error(`the Event Log pane (${pane}) is missing`);
      const body = host.querySelector(".eventLog-scroll-body") as HTMLElement | null;
      if (!body) throw new Error("the Event Log's .eventLog-scroll-body is missing");
      const footer = host.querySelector(".data-tables-footer");
      const match = /(\d+)to(\d+)/.exec(footer?.className ?? "");
      if (!match) throw new Error(`no <start>to<end> in the footer's class: "${footer?.className}"`);
      const rows = Array.from(body.querySelectorAll(".eventLog-row"));
      // The rows' ADVANCE, top to top, as `rowPitchIn` measures it.
      const rowPitchPx =
        rows.length > 1
          ? (rows[rows.length - 1].getBoundingClientRect().top - rows[0].getBoundingClientRect().top) /
            (rows.length - 1)
          : 0;
      // `pixelPaneViewport` with `countPartialRow`, and its tolerance.
      const partialRows = (px: number) => (px > 0 ? Math.max(1, Math.ceil(body.clientHeight / px - 1e-6)) : 0);
      const total = Number(host.querySelector(".data-tables-footer-rows-count")?.textContent ?? -1);
      return {
        footerEnd: Number(match[2]),
        total,
        visibleRows: Math.min(total, partialRows(rowPitchPx)),
        visibleRowsAtFallback: Math.min(total, partialRows(fallbackRowPx)),
        bodyHeightPx: body.clientHeight,
        scrollHeightPx: body.scrollHeight,
        rowPitchPx,
      };
    },
    { pane: EVENT_LOG_PANE, fallbackRowPx: FALLBACK_ROW_PX },
  );
}

/** Poll until two readings a second apart agree on a populated footer. */
async function settledPane(page: Page): Promise<PaneReading> {
  let previous = JSON.stringify(await readPane(page));
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1000);
    const current = await readPane(page);
    if (JSON.stringify(current) === previous && current.footerEnd > 0) return current;
    previous = JSON.stringify(current);
  }
  throw new Error(`the Event Log never settled; last reading: ${previous}`);
}

test("the footer's range is the measured one straight after the first rows are measured", async ({ ctPage }) => {
  await armBlockOnFirstRow(ctPage);

  await retry(() => ctPage.evaluate(() => (window as any).__eventLogFooterBlock !== undefined), {
    maxAttempts: 240,
    delayMs: 250,
  });
  const block = (await ctPage.evaluate(() => (window as any).__eventLogFooterBlock)) as BlockRecord;
  const settled = await settledPane(ctPage);
  const measurements = JSON.stringify({ block, settled });

  // The controls: without these the comparison below says nothing.
  expect(block.heldForMs, `the block held the main thread: ${measurements}`).toBeGreaterThanOrEqual(BLOCK_MS);
  expect(
    Math.abs(block.scrollHeightAfterBlock - settled.scrollHeightPx),
    `the measurement reached the pane before the block ended: ${measurements}`,
  ).toBeLessThanOrEqual(SCROLL_HEIGHT_SLACK_PX);
  expect(
    settled.visibleRowsAtFallback,
    `the fallback and the measured pitch imply different row counts: ${measurements}`,
  ).not.toBe(settled.visibleRows);

  // The claim. Nothing happened between these two readings but timers, so a
  // difference is a range the pane leaves again without any input.
  expect(block.footerEndAfterBlock, `the footer's end after the block equals its final end: ${measurements}`).toBe(
    settled.footerEnd,
  );
  // And that end is what the rows' own pitch says fits, not merely stable.
  expect(settled.footerEnd, `the final footer end is the rows the viewport shows: ${measurements}`).toBe(
    settled.visibleRows,
  );
});
