/**
 * THE FLOW'S VALUE LABELS FOLLOW A ZOOM: AFTER EVERY ZOOM STEP EACH LABEL SITS
 * BESIDE ITS OWN LINE'S CODE, AT THE EDITOR'S NEW SIZE (#908).
 *
 * `Omniscience-Flow.md` § Inline Value Display: "Values appear as labels next
 * to their expressions in the code"; § Long values: a chip "stays one editor
 * line tall and never draws over the source lines beneath it".
 * `CUA-Keymap.md` § Window zoom: `window.zoom-in` / `window.zoom-out` "scale
 * the whole UI". The reporter's symptom: after `Ctrl+=` the labels kept their
 * old position and size and covered the code of their own line and of the
 * line below, until some other action redrew the view.
 *
 * WHAT IS ASSERTED. In the real Electron app, for every rendered flow value
 * chip on a line L of the editor:
 *
 *   - its left edge is at or right of the right edge of line L's source text;
 *   - its box lies inside line L's band: not above line L's top and not below
 *     line L+1's top (it never draws over the line beneath it);
 *   - its value text is drawn at the editor's font size minus 2 px, the size
 *     `ui/flow.nim` derives the labels from (`calculateLineHeight`).
 *
 * That holds at the default size, after the desktop's own `zoomIn` key
 * (`Ctrl+=` in `default_config.yaml`), and after `zoomOut` twice (one step
 * below the default).
 *
 * WHY GEOMETRIC AND RELATIVE. Every number is read off the live layout and
 * compared with another number read off it: the text's right edge is the
 * rendered `.view-line` span's box, the line bands are the rendered lines'
 * boxes, and the font size is the rendered line's computed size. No pixel
 * constant appears, so a stylesheet change that legitimately moves a label
 * does not fail this file. Reads happen after two animation frames, and each
 * post-zoom read is retried for a few seconds, so a redraw that is merely a
 * frame late passes; one that waits for an unrelated action does not. All
 * three phases are read before anything is asserted, and the failure lists
 * each one with the worst offender's numbers.
 *
 * WHY THE REPORTER'S RUBY TRACE, AND NOT ONLY PYTHON. The zoom redraws every
 * open editor's flow in turn (`ui_js.updateEditors`). In the Ruby trace the
 * entry file's flow holds a step at line 0 (the `<top-level>` frame's entry),
 * which names no line of the file. The desktop drew a flow line for it, Monaco
 * threw "Illegal value for lineNumber" when asked about line 0, and the throw
 * ended the loop: `priority_queue.rb`'s editor, after it, was never redrawn,
 * so its `empty?` labels kept the 14 px of a 16 px editor through a zoom to
 * 18 px and to 14 px, and sat over `@elements.empty?` and the `end` below it.
 * Measured at codetracer `c62a20163`: the Ruby case failed every post-zoom
 * reading for five seconds, while the Python trace, which has no such step,
 * fit on the first reading of every phase. The Python case stays as the
 * control that the geometry itself follows a zoom.
 *
 * The model for this file is `calltrace/calltrace_guides_follow_rows.spec.ts`
 * (#849), the same zoom path with a different drawer.
 *
 * NO MOCKS: the recording is made by the fixture with the real recorder, and
 * the measured view is the real renderer.
 */
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import * as path from "node:path";

// A recording, then three measured layout phases, each retried while the
// view re-renders: the multi-phase budget `calltrace_guides_follow_rows`
// takes.
test.setTimeout(180_000);

/** One phase's reading: every chip's fit, and the worst offender. */
interface LabelFit {
  editorFontSize: number;
  lineHeight: number;
  chips: number;
  /** Chips that failed a check, with what was measured, worst first. */
  misses: string[];
}

/**
 * Read every rendered flow value chip and the source line it belongs to off
 * the live layout, and compare them.
 *
 * A chip's line is the number in its step container's id
 * (`flow-<mode>-value-<line>`, `renderFlowComplexStep`). Line L's text box is
 * the rendered `.view-line` whose top is Monaco's top for L; its right edge is
 * the right edge of the span that holds the text, so it is the glyphs the
 * browser drew, not a number Monaco computed.
 */
async function measureLabelFit(page: import("@playwright/test").Page): Promise<LabelFit> {
  return page.evaluate(
    () =>
      new Promise<LabelFit>((resolve) => {
        requestAnimationFrame(() =>
          requestAnimationFrame(() => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const w = window as any;
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const editors: any[] = Object.values(w.data?.ui?.editors ?? {})
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              .filter((e: any) => e && e.monacoEditor && typeof e.monacoEditor.getDomNode === "function");
            const misses: { score: number; text: string }[] = [];
            let chips = 0;
            let editorFontSize = NaN;
            let lineHeight = NaN;
            const steps = Array.from(document.querySelectorAll(
              "[id^='flow-parallel-value-'], [id^='flow-inline-value-'], [id^='flow-multiline-value-']"));
            for (const step of steps) {
              const m = /^flow-(?:parallel|inline|multiline)-value-(\d+)/.exec(step.id);
              if (!m) continue;
              const line = Number(m[1]);
              const editor = editors.find((e) => e.monacoEditor.getDomNode()?.contains(step));
              if (!editor) continue;
              const me = editor.monacoEditor;
              const root: HTMLElement = me.getDomNode();
              const rootRect = root.getBoundingClientRect();
              const lineTop = (n: number) => rootRect.top + me.getTopForLineNumber(n) - me.getScrollTop();
              const viewLines = Array.from(root.querySelectorAll(".view-lines > .view-line")) as HTMLElement[];
              const viewLineAt = (n: number) =>
                viewLines.find((v) => Math.abs(v.getBoundingClientRect().top - lineTop(n)) < 1);
              const own = viewLineAt(line);
              if (!own) continue; // the line is scrolled out of view
              const ownRect = own.getBoundingClientRect();
              const textSpan = own.firstElementChild as HTMLElement | null;
              const textRight = textSpan ? textSpan.getBoundingClientRect().right : ownRect.left;
              const next = viewLineAt(line + 1);
              const bandBottom = next ? next.getBoundingClientRect().top : ownRect.bottom;
              editorFontSize = parseFloat(getComputedStyle(own).fontSize);
              lineHeight = ownRect.height;
              // A chip is the name and value pair `renderFlowVariableChip`
              // draws: `.ct-omni-value` (the older `.flow-*-value` wrappers
              // are kept for the inline and multiline modes).
              const boxes = Array.from(step.querySelectorAll(
                ".ct-omni-value, .flow-inline-value, .flow-multiline-value")) as HTMLElement[];
              for (const chip of boxes) {
                const r = chip.getBoundingClientRect();
                if (r.width === 0 && r.height === 0) continue; // not drawn
                chips += 1;
                const valueBox = chip.querySelector(
                  ".flow-parallel-value-box, .flow-inline-value-box, .flow-multiline-value-box") as HTMLElement | null;
                const fontSize = parseFloat(getComputedStyle(valueBox ?? chip).fontSize);
                const overText = textRight - r.left;           // > 0: drawn over its line's code
                const aboveTop = ownRect.top - r.top;          // > 0: drawn over the line above
                const belowBand = r.bottom - bandBottom;       // > 0: drawn over the line beneath
                const fontOff = Math.abs(fontSize - (editorFontSize - 2));
                const score = Math.max(overText, aboveTop, belowBand, fontOff * 10);
                if (overText > 0.5 || aboveTop > 0.5 || belowBand > 0.5 || fontOff > 0.01) {
                  misses.push({
                    score,
                    text: `line ${line} chip "${(chip.textContent ?? "").trim().slice(0, 40)}": ` +
                      `left ${r.left.toFixed(1)} vs text right ${textRight.toFixed(1)}, ` +
                      `top ${r.top.toFixed(1)} / bottom ${r.bottom.toFixed(1)} vs band ` +
                      `${ownRect.top.toFixed(1)}..${bandBottom.toFixed(1)}, ` +
                      `font ${fontSize}px vs editor ${editorFontSize}px - 2`,
                  });
                }
              }
            }
            misses.sort((a, b) => b.score - a.score);
            resolve({ editorFontSize, lineHeight, chips, misses: misses.map((x) => x.text) });
          }));
      }),
  );
}

function fits(f: LabelFit): boolean {
  return f.chips > 0 && f.misses.length === 0;
}

function describeFit(f: LabelFit): string {
  return `${f.chips} chips at editor font ${f.editorFontSize}px, line height ${f.lineHeight}px; ` +
    (f.misses.length === 0 ? "all fit" : `${f.misses.length} misplaced, worst: ${f.misses.slice(0, 3).join("; ")}`);
}

/**
 * Wait (bounded) until every label fits, and return the last reading whether
 * it does or not: the caller asserts every phase together, so a drawer that
 * is already off before the zoom still has its behaviour THROUGH the zoom
 * reported.
 */
async function readLabelFit(page: import("@playwright/test").Page, label: string): Promise<LabelFit> {
  let last: LabelFit | null = null;
  let attempts = 0;
  try {
    await retry(
      async () => {
        last = await measureLabelFit(page);
        attempts += 1;
        if (attempts === 1 && !fits(last)) console.log(`${label} (first reading): ${describeFit(last)}`);
        return fits(last);
      },
      { maxAttempts: 20, delayMs: 250 },
    );
  } catch {
    // Reported by the caller with the last reading.
  }
  const f = last ?? (await measureLabelFit(page));
  console.log(`${label} (after ${attempts} reading(s)): ${describeFit(f)}`);
  return f;
}

const chipCount = (page: import("@playwright/test").Page): Promise<number> =>
  page.locator(".ct-omni-value, .flow-inline-value, .flow-multiline-value").count();

interface TraceCase {
  kind: string;
  sourcePath: string;
  /** Step over until this many chips are drawn, before measuring. */
  minChips: number;
  /**
   * Go into this function through the call trace first, and wait until the
   * debugger stands in `file`. Without it the labels measured are the entry
   * point's.
   */
  enter?: { functionName: string; file: string };
}

const REPO_ROOT = path.resolve(__dirname, "../../../../..");

// `py_sudoku_solver` records a materialized (Python) trace whose module body
// draws single-line labels (`SIZE = 9`, the `Board` / `Coordinate` aliases)
// from the first stop.
//
// The Ruby case is the reporter's own (#908): `examples/ruby_maze_solver`,
// `PriorityQueue#empty?` in `lib/maze_solver/priority_queue.rb`, whose three
// lines (`def empty?`, `@elements.empty?`, `end`) carry a return value's
// labels.
const TRACES: TraceCase[] = [
  { kind: "Python", sourcePath: "py_sudoku_solver/main.py", minChips: 2 },
  {
    kind: "Ruby (the reporter's empty?)",
    sourcePath: path.join(REPO_ROOT, "examples/ruby_maze_solver/bin/smoke_test.rb"),
    minChips: 1,
    enter: { functionName: "MazeSolver::PriorityQueue#empty?", file: "priority_queue.rb" },
  },
];

const currentPath = (page: import("@playwright/test").Page): Promise<string> =>
  page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    return loc ? String(loc.path ?? loc.highLevelPath ?? "") : "";
  });

for (const trace of TRACES) {
  test.describe(`Flow value labels follow a zoom (#908), ${trace.kind} trace`, () => {
    test.use({ sourcePath: trace.sourcePath, launchMode: "trace" });

    test("every label sits beside its own line's code at each zoom step", async ({ ctPage }) => {
      const layout = new LayoutPage(ctPage);
      await layout.waitForBaseComponentsLoaded();

      if (trace.enter) {
        const callTrace = (await layout.callTraceTabs())[0];
        await callTrace.clickTab();
        await callTrace.waitForReady();
        const entry = await callTrace.navigateToEntry(trace.enter.functionName);
        await entry.activate().catch(() => {});
        await retry(
          async () => (await currentPath(ctPage)).endsWith(trace.enter!.file),
          { maxAttempts: 60, delayMs: 500 },
        ).catch(() => {});
        expect(await currentPath(ctPage), "the debugger stands in the entered function's file")
          .toMatch(new RegExp(`${trace.enter.file.replace(".", "\\.")}$`));
      }

      // The flow arrives after the first stop; step over (bounded) until the
      // editor draws enough labels to measure.
      await retry(
        async () => {
          if ((await chipCount(ctPage)) >= trace.minChips) return true;
          await layout.clickNextButton();
          return false;
        },
        { maxAttempts: 40, delayMs: 750 },
      ).catch(() => {});
      expect(await chipCount(ctPage), "flow value chips drawn").toBeGreaterThanOrEqual(trace.minChips);

      const before = await readLabelFit(ctPage, "default zoom");

      // The desktop's zoom key: `zoomIn` (CTRL+= in `default_config.yaml`).
      await ctPage.keyboard.press("Control+Equal");
      await retry(
        async () => (await measureLabelFit(ctPage)).editorFontSize !== before.editorFontSize,
        { maxAttempts: 20, delayMs: 250 },
      ).catch(() => {});
      const zoomedIn = await readLabelFit(ctPage, "after zoom in");

      await ctPage.keyboard.press("Control+Minus");
      await ctPage.keyboard.press("Control+Minus");
      await retry(
        async () => (await measureLabelFit(ctPage)).editorFontSize < before.editorFontSize,
        { maxAttempts: 20, delayMs: 250 },
      ).catch(() => {});
      const zoomedOut = await readLabelFit(ctPage, "after zoom out");

      // The zoom really changed the editor (else the later phases test nothing)...
      expect(zoomedIn.editorFontSize).toBeGreaterThan(before.editorFontSize);
      expect(zoomedOut.editorFontSize).toBeLessThan(before.editorFontSize);
      // ...and the labels fit their lines in every phase.
      const phases: [string, LabelFit][] = [
        ["default zoom", before], ["after zoom in", zoomedIn], ["after zoom out", zoomedOut],
      ];
      const report = phases.map(([l, f]) => `${fits(f) ? "ok  " : "MISS"} ${l}: ${describeFit(f)}`).join("\n");
      expect(phases.every(([, f]) => fits(f)), `flow value labels vs their lines:\n${report}`).toBe(true);
    });
  });
}
