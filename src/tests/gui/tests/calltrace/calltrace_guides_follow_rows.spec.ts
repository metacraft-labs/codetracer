/**
 * THE CALL TRACE'S GUIDE LINES MEET THE ROWS THEY CONNECT, BEFORE AND AFTER A
 * ZOOM (#849).
 *
 * `Call-Trace-Pane.md` § Visual Design: "Vertical guides | Lines connecting
 * parent to children". The guides are an SVG layer (`#svg-content-0`) laid
 * over the rows; a guide connects two rows only if it is drawn where the
 * browser put them. The reporter's symptom was a growing vertical offset as
 * the trace scrolled down, and guides that stayed put through a zoom: the
 * layer was drawn at a hard-coded 25 px per row while the rows advance by
 * their em-derived pitch, and nothing redrew it when the root font size
 * changed.
 *
 * WHAT IS ASSERTED. In the real Electron app, over a real recording, for every
 * pair of adjacent rendered rows k and k+1: the horizontal connector between
 * them lies on row k+1's top edge, and its ends lie on the two rows' toggle
 * centres, each within 1 px. Then the desktop's own zoom key (`zoomIn`,
 * CTRL+= in `default_config.yaml`) is pressed, which changes only the root
 * font size, and the same holds at the new size; then the same for `zoomOut`.
 *
 * WHY GEOMETRIC AND RELATIVE. Every number is read off the live layout and
 * compared with another number read off it; no pixel constant appears here,
 * so a stylesheet change that moves the rows legitimately does not fail this
 * file. Reads happen after two animation frames, and the post-zoom read is
 * retried for a short while, because the view re-measures on a
 * ResizeObserver notification; a drawer that never follows the zoom fails by
 * timing out with the last mismatch in the message.
 *
 * The same property is held, without Electron, by
 * `src/frontend/tests/calltrace_guides_chromium_test.nim` (renderer-chromium
 * lane), which reproduces the 25.28 px advance and runs in seconds.
 */
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

interface GuideFit {
  rows: number;
  connectors: number;
  advance: number;
  rootFontSize: string;
  worstDy: number;
  worstDyRow: number;
  worstDx: number;
  worstDxRow: number;
}

/** Read the rows and the guide layer off the live layout and compare them. */
async function measureGuideFit(page: import("@playwright/test").Page): Promise<GuideFit> {
  return page.evaluate(
    () =>
      new Promise<GuideFit>((resolve) => {
        requestAnimationFrame(() =>
          requestAnimationFrame(() => {
            const pane = document.querySelector(".isonim-calltrace");
            const svg = pane?.querySelector("#svg-content-0");
            const rows = pane ? Array.from(pane.querySelectorAll(".calltrace-call-line")) : [];
            const rootFontSize = document.documentElement.style.fontSize;
            if (!svg || rows.length < 2) {
              resolve({
                rows: rows.length, connectors: 0, advance: 0, rootFontSize,
                worstDy: Infinity, worstDyRow: -1, worstDx: Infinity, worstDxRow: -1,
              });
              return;
            }
            const origin = svg.getBoundingClientRect();
            const connectors = Array.from(svg.querySelectorAll("line"))
              .map((l) => ({
                x1: Number(l.getAttribute("x1")), y1: Number(l.getAttribute("y1")),
                x2: Number(l.getAttribute("x2")), y2: Number(l.getAttribute("y2")),
              }))
              .filter((s) => Math.abs(s.y1 - s.y2) < 1e-6);
            const toggleCentre = (row: Element): number => {
              const t = row.querySelector(".toggle-call");
              if (!t) return NaN;
              const r = t.getBoundingClientRect();
              return r.left + r.width / 2 - origin.left;
            };
            let worstDy = 0, worstDyRow = -1, worstDx = 0, worstDxRow = -1;
            const pairs = Math.min(connectors.length, rows.length - 1);
            for (let k = 0; k < pairs; k++) {
              const boundary = rows[k + 1].getBoundingClientRect().top - origin.top;
              const dy = Math.abs(connectors[k].y1 - boundary);
              if (!(dy <= worstDy)) { worstDy = dy; worstDyRow = k; }
              const dx = Math.max(
                Math.abs(connectors[k].x1 - toggleCentre(rows[k])),
                Math.abs(connectors[k].x2 - toggleCentre(rows[k + 1])));
              if (!(dx <= worstDx)) { worstDx = dx; worstDxRow = k; }
            }
            const first = rows[0].getBoundingClientRect().top;
            const last = rows[rows.length - 1].getBoundingClientRect().top;
            resolve({
              rows: rows.length, connectors: connectors.length,
              advance: (last - first) / (rows.length - 1), rootFontSize,
              worstDy, worstDyRow, worstDx, worstDxRow,
            });
          }));
      }),
  );
}

function describeFit(f: GuideFit): string {
  return `${f.rows} rows, ${f.connectors} connectors, advance ${f.advance.toFixed(4)} px ` +
    `at root font ${f.rootFontSize || "(unset)"}; worst |dy| ${f.worstDy.toFixed(2)} at ` +
    `connector ${f.worstDyRow}, worst |dx| ${f.worstDx.toFixed(2)} at connector ${f.worstDxRow}`;
}

function fits(f: GuideFit): boolean {
  return f.rows >= 2 && f.connectors === f.rows - 1 && f.worstDy <= 1 && f.worstDx <= 1;
}

/** Wait (bounded) until the guides fit the rows; fail with the last reading. */
async function expectGuidesFitRows(page: import("@playwright/test").Page, label: string): Promise<GuideFit> {
  let last: GuideFit | null = null;
  try {
    await retry(
      async () => {
        last = await measureGuideFit(page);
        return fits(last);
      },
      { maxAttempts: 20, delayMs: 250 },
    );
  } catch {
    // Reported below with the last reading.
  }
  const f = last ?? (await measureGuideFit(page));
  console.log(`${label}: ${describeFit(f)}`);
  expect(fits(f), `${label}: ${describeFit(f)}`).toBe(true);
  return f;
}

test.describe("CallTrace guide lines follow the rows (#849)", () => {
  test.use({ sourcePath: "py_sudoku_solver/main.py", launchMode: "trace" });

  test("guides meet every rendered row, before and after a zoom in and out", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.clickTab();
    await callTrace.waitForReady();

    // Enough rows that a per-row error shows: the defect is cumulative.
    await retry(
      async () => (await callTrace.root.locator(".calltrace-call-line").count()) >= 10,
      { maxAttempts: 60, delayMs: 500 },
    );

    const before = await expectGuidesFitRows(ctPage, "default zoom");

    // The desktop's zoom: `zoomIn` (CTRL+=) changes only the root font size.
    await ctPage.locator(".calltrace-search-input").first().blur().catch(() => {});
    await ctPage.keyboard.press("Control+Equal");
    await retry(
      async () => (await measureGuideFit(ctPage)).rootFontSize !== before.rootFontSize,
      { maxAttempts: 20, delayMs: 250 },
    );
    const zoomedIn = await expectGuidesFitRows(ctPage, "after zoom in");
    expect(zoomedIn.advance).toBeGreaterThan(before.advance);

    await ctPage.keyboard.press("Control+Minus");
    await ctPage.keyboard.press("Control+Minus");
    await retry(
      async () => (await measureGuideFit(ctPage)).rootFontSize !== zoomedIn.rootFontSize,
      { maxAttempts: 20, delayMs: 250 },
    );
    const zoomedOut = await expectGuidesFitRows(ctPage, "after zoom out");
    expect(zoomedOut.advance).toBeLessThan(before.advance);
  });
});
