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
 * WHAT IS ASSERTED. In the real Electron app, over a materialized and a native
 * (MCR) recording, for every pair of adjacent rendered rows k and k+1: the
 * horizontal connector between them lies on row k+1's top edge, and its ends
 * lie on the two rows' toggle centres, each within 1 px. Then the desktop's
 * own zoom key (`zoomIn`, CTRL+= in `default_config.yaml`) is pressed, which
 * changes only the root font size, and the same holds at the new size; then
 * the same for `zoomOut`.
 *
 * WHY GEOMETRIC AND RELATIVE. Every number is read off the live layout and
 * compared with another number read off it; no pixel constant appears here,
 * so a stylesheet change that moves the rows legitimately does not fail this
 * file. Reads happen after two animation frames, and the post-zoom read is
 * retried for a short while, because the view re-measures on a
 * ResizeObserver notification. All three phases are read before anything is
 * asserted, and the failure lists each one, so a drawer that is already off
 * before the zoom is still shown failing to follow it.
 *
 * BOTH TRACE KINDS, because they failed differently. Before the fix, on a
 * native (MCR) trace the guides kept their 25 px grid through a zoom (6.24 px
 * off by the third row at 18 px), while on a materialized one a second,
 * DOM-measured drawer repainted the rows' y on zoom and only the x stayed
 * 2 px off. Either kind alone would have hidden half of it.
 *
 * The same property is held, without Electron, by
 * `src/frontend/tests/calltrace_guides_chromium_test.nim` (renderer-chromium
 * lane), which drives the drawer at an advance that is neither the row box
 * nor a whole number of pixels, and runs in seconds.
 */
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import type { CallTracePane } from "../../page-objects/panes/call-trace/call-trace-pane";

// Recording, then three measured layout phases (default, zoomed in, zoomed
// out), each read after two animation frames and retried while the view
// re-measures. That is about 80 s on an idle-ish host and has run past the
// 90 s default on a loaded one, so this file takes the 180 s the other
// multi-phase specs take.
test.setTimeout(180_000);

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

/**
 * Wait (bounded) until the guides fit the rows, and return the last reading
 * whether they do or not. The caller asserts every phase together at the
 * end, so a drawer that is off before the zoom still has its behaviour
 * THROUGH the zoom reported: that is the half of the defect a first-phase
 * failure would hide.
 */
async function readGuideFit(page: import("@playwright/test").Page, label: string): Promise<GuideFit> {
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
    // Reported by the caller with the last reading.
  }
  const f = last ?? (await measureGuideFit(page));
  console.log(`${label}: ${describeFit(f)}`);
  return f;
}

interface TraceCase {
  kind: string;
  sourcePath: string;
  /** Rows the pane must render before the guides are measured. */
  minRows: number;
  /** How to get there; see `reachRows`. */
  deepen: "expand" | "step-in";
  /** For "step-in": the line of the first call into the program's own code. */
  callLine?: number;
}

// Both trace kinds. The view draws the guides the same way for either, but the
// desktop used to run a second, DOM-measured drawer over the same layer for
// materialized traces only, so a check on one kind could not vouch for the
// other. `py_sudoku_solver` records a materialized trace; `c_sudoku_solver`
// records a native (MCR) one and needs the native recorder and replay
// (`just build-siblings`); the fixture skips it where no `ct-native-replay`
// is configured.
const TRACES: TraceCase[] = [
  { kind: "materialized", sourcePath: "py_sudoku_solver/main.py", minRows: 10, deepen: "expand" },
  {
    kind: "native (MCR)", sourcePath: "c_sudoku_solver/main.c", minRows: 3, deepen: "step-in",
    // `if (solve_sudoku(test_boards[i]))` in `main`; stepping in from there
    // reaches `solve_sudoku` and then `find_empty_cell`: a stack of 3.
    callLine: 186,
  },
];

const rowCount = (pane: CallTracePane): Promise<number> =>
  pane.root.locator(".calltrace-call-line").count();

/** Expand collapsed calls until at least `minRows` rows render (bounded). */
async function expandUntilRows(pane: CallTracePane, minRows: number): Promise<void> {
  for (let pass = 0; pass < 4 && (await rowCount(pane)) < minRows; pass++) {
    for (const entry of await pane.getEntries(true)) {
      if ((await rowCount(pane)) >= minRows) break;
      await entry.expandChildren();
    }
  }
}

const currentLine = (layout: LayoutPage): Promise<number | null> =>
  layout.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    return loc && typeof loc.line === "number" ? loc.line : null;
  });

/**
 * Step over to `callLine`, then step in until the call stack shown is
 * `minRows` deep. Stepping OVER first keeps the walk out of libc: a step in
 * at `c_sudoku_solver`'s `printf` lines descends into code without debug
 * information. Both walks are bounded; the pattern is
 * `flow-loop-controls.spec.ts`'s (look, and step only while the target is not
 * reached, giving each step time to land).
 */
async function stepInUntilRows(
  layout: LayoutPage, pane: CallTracePane, minRows: number, callLine: number,
): Promise<void> {
  await retry(
    async () => {
      if ((await currentLine(layout)) === callLine) return true;
      await layout.clickNextButton();
      return false;
    },
    { maxAttempts: 120, delayMs: 500 },
  ).catch(() => {});
  await retry(
    async () => {
      if ((await rowCount(pane)) >= minRows) return true;
      await layout.clickStepInButton();
      return false;
    },
    { maxAttempts: 60, delayMs: 500 },
  ).catch(() => {});
}

/**
 * Get the pane to `trace.minRows` rows. More rows show more of a per-row
 * error, which is cumulative.
 *
 * - A materialized trace's pane holds the trace's calls: expand collapsed
 *   ones. `py_sudoku_solver` usually renders enough already, and then this
 *   does nothing.
 * - A non-materialized trace's pane holds the CALL STACK at the current point
 *   (`load_calltrace_section` in `src/db-backend/src/dap_handler.rs` answers
 *   other trace kinds with `load_callstack`), which is just `main` at entry.
 *   Step to the program's first call and in, until the stack is deep enough.
 *
 * Both are bounded, and the final wait fails with the count reached.
 */
async function reachRows(layout: LayoutPage, pane: CallTracePane, trace: TraceCase): Promise<void> {
  if (trace.deepen === "expand") {
    await expandUntilRows(pane, trace.minRows);
  } else {
    await stepInUntilRows(layout, pane, trace.minRows, trace.callLine ?? 0);
  }
  await retry(async () => (await rowCount(pane)) >= trace.minRows, { maxAttempts: 60, delayMs: 500 })
    .catch(() => {});
  expect(
    await rowCount(pane),
    `${trace.kind}: call-trace rows reached (stopped at line ${await currentLine(layout)})`,
  ).toBeGreaterThanOrEqual(trace.minRows);
}

for (const trace of TRACES) {
  test.describe(`CallTrace guide lines follow the rows (#849), ${trace.kind} trace`, () => {
    test.use({ sourcePath: trace.sourcePath, launchMode: "trace" });

    test("guides meet every rendered row, before and after a zoom in and out", async ({ ctPage }) => {
      // The fixture sets 120 s for a native (RR-based) test on Linux and macOS,
      // which overrides the file's 180 s; this one also steps through the
      // program to grow its call stack, one native step at a time (about 150 s
      // in all on Linux). Never shorten a longer fixture budget (720 s on
      // Windows).
      if (trace.deepen === "step-in") test.setTimeout(Math.max(test.info().timeout, 360_000));

      const layout = new LayoutPage(ctPage);
      await layout.waitForBaseComponentsLoaded();

      const callTrace = (await layout.callTraceTabs())[0];
      await callTrace.clickTab();
      await callTrace.waitForReady();

      await reachRows(layout, callTrace, trace);

      const before = await readGuideFit(ctPage, "default zoom");

      // The desktop's zoom: `zoomIn` (CTRL+=) changes only the root font size.
      await ctPage.locator(".calltrace-search-input").first().blur().catch(() => {});
      await ctPage.keyboard.press("Control+Equal");
      await retry(
        async () => (await measureGuideFit(ctPage)).rootFontSize !== before.rootFontSize,
        { maxAttempts: 20, delayMs: 250 },
      );
      const zoomedIn = await readGuideFit(ctPage, "after zoom in");

      await ctPage.keyboard.press("Control+Minus");
      await ctPage.keyboard.press("Control+Minus");
      await retry(
        async () => (await measureGuideFit(ctPage)).rootFontSize !== zoomedIn.rootFontSize,
        { maxAttempts: 20, delayMs: 250 },
      );
      const zoomedOut = await readGuideFit(ctPage, "after zoom out");

      // The zoom really moved the rows (else the later phases test nothing)...
      expect(zoomedIn.advance).toBeGreaterThan(before.advance);
      expect(zoomedOut.advance).toBeLessThan(before.advance);
      // ...and the guides met them in every phase.
      const phases: [string, GuideFit][] = [
        ["default zoom", before], ["after zoom in", zoomedIn], ["after zoom out", zoomedOut],
      ];
      const report = phases.map(([l, f]) => `${fits(f) ? "ok  " : "MISS"} ${l}: ${describeFit(f)}`).join("\n");
      expect(phases.every(([, f]) => fits(f)), `guide lines vs rows:\n${report}`).toBe(true);
    });
  });
}
