/**
 * Omniscience loop controls — end-to-end coverage for issues #562, #593, #595.
 *
 * Specification
 * -------------
 * `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md`. The control is
 * specified by what it renders and by one interaction:
 *
 *   * "Loop Visualization — When code is inside a loop, Omniscience shows
 *     values across iterations", drawn as `# [Iteration: 1 of 5]` and, in the
 *     "Loop Slider Control" and wireframe sections, as `[Iteration: 3/8]` /
 *     `[Iteration 3/8] [<====@=>]` for a `for i in range(8)`.
 *
 *     Two obligations follow. The left number identifies WHICH iteration is on
 *     screen, so it must follow the debugger rather than sit at a constant
 *     (#593). The right number is the loop's iteration count — "of 5", "/8" —
 *     a property of the loop, so it must not change as the cursor moves inside
 *     it (#595: "0 from 10 -> 0 from 8 -> 0 from 6").
 *
 *   * "Loop Slider Control — ... Click arrows for previous/next": one click is
 *     one iteration.
 *
 *   * "A slider appears above loop constructs to navigate iterations" and
 *     "Drag slider to jump between iterations" — the slider has to exist and
 *     be draggable, i.e. occupy a real box (#562).
 *
 * The spec's sketches number iterations from 1 while the implementation indexes
 * them from 0, and the spec does not say which is normative. These tests
 * therefore assert relative movement and total invariance only, and never a
 * particular origin.
 *
 * These are the GUI-layer counterparts of two headless suites, per the
 * headless-first policy:
 *   * `src/tests/gui/tests/flow/flow_loop_math_test.nim` — the iteration
 *     arithmetic (containing-interval search, one-step arrow clamping).
 *   * `src/db-backend/tests/flow_loop_iteration_window_test.rs` — the flow
 *     window those numbers are derived from, asserted to be invariant as the
 *     cursor moves.
 *
 * What only this layer can see:
 *
 *   #562 — the noUiSlider is created at all, and has a non-zero on-screen box.
 *          `.flow-loop-slider` is our own container and exists regardless, so
 *          asserting on it is what let #562 be declared fixed three times; the
 *          assertions here are on `.noUi-base` (proof `noUiSlider.create()`
 *          ran) AND on `boundingBox().width` (proof it was laid out).
 *
 *   #595 — N clicks on the forward arrow move the counter 1, 2, 3, ... and the
 *          "from M" total does not change while they do. A shrinking total was
 *          the reporter's "0 from 10 -> 0 from 8 -> 0 from 6".
 *
 *   #593 — that the counter keeps advancing past the SECOND click. The last
 *          cause to be found was a component-lifecycle one and is invisible to
 *          every layer below: `EditorViewComponent.loadFlow` builds a fresh
 *          `FlowComponent` per move, and the retired one's deferred
 *          `scheduleFlowRedraw` timer still fired, repainting the loop control
 *          from the PREVIOUS debugger position roughly 100 ms into the new
 *          load. The third click then read that stale number, re-selected the
 *          iteration the debugger was already on, and the counter froze. Only
 *          a real Monaco editor with real timers reproduces it, which is why
 *          this assertion clicks more than twice.
 *
 * Fixture: `test-programs/noir_flow_loop`, a Noir program whose `main` opens a
 * single unambiguous ten-iteration `for` loop.
 *
 * Why Noir and not Python or JavaScript.  The iteration counter is produced by
 * `process_loops` in the db-backend, which counts an iteration every time a
 * step lands back on the loop header line.  This spec originally recorded
 * `examples/fibonacci.py`, which made it unrunnable wherever the Python
 * recorder (a PyO3/maturin extension, not a pure-Python package) is not
 * installed — and it had therefore never executed.  Retargeting it at the
 * JavaScript recorder, the cheapest required sibling, does not work either:
 * that recorder emits the `for`/`while` header exactly once per loop, so the
 * flow update comes back with a single entry in `rrTicksForIterations`, the
 * control renders as "iteration 0 from 0" with both arrows disabled, and there
 * is nothing for these assertions to observe.  Noir re-enters the header on
 * every iteration and is recorded by `nargo`, which the dev shell provides.
 *
 * When `nargo` is absent the whole suite skips with a reason rather than
 * failing inside `ct record` — the same contract the rest of the suite follows
 * for recorders it cannot assume.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { OmniscientLoopControls } from "../../page-objects/panes/editor/omniscient-loop-controls";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const fixtureDir = path.join(repoRoot, "test-programs", "noir_flow_loop");

/**
 * Whether `nargo` — the Noir recorder `ct record` shells out to — is on PATH.
 * Resolved once at load time so the skip reason is decided before any Electron
 * process is started.
 */
function hasNargo(): boolean {
  const pathEntries = (process.env.PATH ?? "").split(path.delimiter);
  const names = process.platform === "win32" ? ["nargo.exe", "nargo"] : ["nargo"];
  return pathEntries.some((dir) =>
    dir.length > 0 && names.some((name) => fs.existsSync(path.join(dir, name))),
  );
}

const nargoAvailable = hasNargo();

/** Line of `for i in 0..10 {` in test-programs/noir_flow_loop/src/main.nr. */
const LOOP_HEADER_LINE = 8;

/** Line of the closing `}` of that loop. */
const LOOP_LAST_LINE = 16;

/** `0..10` — the loop body runs ten times. */
const LOOP_BODY_EXECUTIONS = 10;

/** Where the debugger currently is, as the frontend sees it. */
async function debuggerLine(ctPage: Page): Promise<number> {
  return await ctPage.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    return Number(w.data?.services?.debugger?.location?.line ?? -1);
  });
}

/**
 * Open the fixture's editor, put the debugger inside the loop and return the
 * loop control that appears for it.
 *
 * Stepping is part of the setup, not a workaround: the flow — and with it the
 * loop control's Monaco view zone — is computed for the function the debugger
 * is stopped in, so a recording that opens at the first line of `main` has no
 * loop control to click on yet no matter which line is selected.
 */
async function openLoopControls(ctPage: Page): Promise<OmniscientLoopControls> {
  const layout = new LayoutPage(ctPage);
  await layout.waitForTraceLoaded();
  await layout.waitForEditorLoaded();

  let editor: any; // eslint-disable-line @typescript-eslint/no-explicit-any
  await retry(
    async () => {
      const tabs = await layout.editorTabs(true);
      editor = tabs.find((t) => t.tabButtonText.toLowerCase().includes("main.nr"));
      return Boolean(editor);
    },
    { maxAttempts: 60, delayMs: 1000 },
  );

  await editor.tabButton().click();
  await expect(editor.root.locator(".monaco-editor")).toBeVisible({ timeout: 30_000 });

  await retry(
    async () => {
      const line = await debuggerLine(ctPage);
      if (line >= LOOP_HEADER_LINE && line <= LOOP_LAST_LINE) return true;
      await layout.clickStepInButton();
      return false;
    },
    { maxAttempts: 40, delayMs: 500 },
  );

  const reached = await debuggerLine(ctPage);
  expect(
    reached,
    "the fixture must let us reach the loop body by stepping in",
  ).toBeGreaterThanOrEqual(LOOP_HEADER_LINE);

  // Selecting the loop header line is what focuses the flow on that loop.
  await editor.clickSourceLine(LOOP_HEADER_LINE);

  // `.flow-multiline-value-container` is shared with plain multiline value
  // boxes (`ui/flow.nim`, `makeMultilineValueDom`), so qualify it by the
  // iteration textarea that only the loop control has. Without this the
  // assertions could bind to a value box in FlowMultiline mode and fail for a
  // reason that has nothing to do with the loop counter.
  const container = editor.root
    .locator(".flow-multiline-value-container:has(.flow-loop-textarea)")
    .first();
  await container.waitFor({ state: "visible", timeout: 60_000 });

  return new OmniscientLoopControls(container);
}

test.describe("Omniscience loop controls", () => {
  test.setTimeout(240_000);
  test.skip(
    !nargoAvailable,
    "requires the Noir recorder (`nargo`), which is not on PATH — see the " +
      "spec header for why this fixture cannot be recorded with the " +
      "JavaScript recorder instead",
  );
  test.use({ sourcePath: fixtureDir, launchMode: "trace" });

  test("the iteration slider is created and has a non-zero width (#562)", async ({ ctPage }) => {
    const controls = await openLoopControls(ctPage);

    // The container our own code creates.
    await expect(controls.slider()).toHaveCount(1);

    // Proof that noUiSlider.create() actually ran: `.noUi-base` is injected by
    // the library, never by us.
    await expect(controls.sliderBase()).toBeVisible({ timeout: 30_000 });

    // Proof that it was laid out rather than created against a not-yet-attached
    // Monaco view zone (the 0 x 2 px, negatively offset slider of #562).
    await expect
      .poll(async () => controls.sliderWidth(), {
        timeout: 30_000,
        message: "the loop slider must have a non-zero on-screen width",
      })
      .toBeGreaterThan(0);

    // Exactly one slider container: the missing `#` in the id selector used to
    // append a duplicate `.flow-loop-slider` on every rebuild.
    await expect(controls.sliderContainer()).toHaveCount(1);
  });

  test("forward clicks advance the iteration by exactly one and keep the total (#593, #595)", async ({
    ctPage,
  }) => {
    const controls = await openLoopControls(ctPage);

    await expect(controls.iterationValue()).toBeVisible({ timeout: 30_000 });
    await expect(controls.iterationTotal()).toBeVisible({ timeout: 30_000 });

    const initialTotal = await controls.totalIterations();
    expect(
      initialTotal,
      `a for-loop over 0..${LOOP_BODY_EXECUTIONS} must report at least ` +
        `${LOOP_BODY_EXECUTIONS - 1} as its highest iteration index`,
    ).toBeGreaterThanOrEqual(LOOP_BODY_EXECUTIONS - 1);

    const start = await controls.currentIteration();
    expect(Number.isNaN(start)).toBe(false);

    const clicks = Math.min(5, initialTotal - start);
    expect(
      clicks,
      "the fixture must leave room for several forward clicks",
    ).toBeGreaterThan(0);

    const observed: number[] = [];
    const totals: number[] = [];

    for (let i = 1; i <= clicks; i++) {
      await controls.forwardButton().click();

      // The counter must reach exactly start + i — never skip.
      await expect
        .poll(async () => controls.currentIteration(), {
          timeout: 20_000,
          message: `click ${i} should select iteration ${start + i}`,
        })
        .toBe(start + i);

      observed.push(await controls.currentIteration());
      totals.push(await controls.totalIterations());
    }

    // 1, 2, 3, ... relative to where we started.
    expect(observed).toEqual(
      Array.from({ length: clicks }, (_, i) => start + i + 1),
    );

    // "from M" is a property of the loop, not of where the cursor is. It
    // shrinking is the #595 regression.
    for (const [i, total] of totals.entries()) {
      expect(
        total,
        `the iteration total changed after click ${i + 1}: ` +
          `${initialTotal} -> ${total} (window re-based under the cursor)`,
      ).toBe(initialTotal);
    }
  });

  test("backward clicks retreat by exactly one (#595)", async ({ ctPage }) => {
    const controls = await openLoopControls(ctPage);

    await expect(controls.iterationValue()).toBeVisible({ timeout: 30_000 });

    const total = await controls.totalIterations();
    const start = await controls.currentIteration();
    expect(Number.isNaN(start)).toBe(false);

    // Walk forward a few iterations so there is somewhere to come back from.
    const steps = Math.min(3, total - start);
    expect(
      steps,
      "the fixture must leave room for a forward-then-backward round trip",
    ).toBeGreaterThan(0);

    for (let i = 1; i <= steps; i++) {
      await controls.forwardButton().click();
      await expect.poll(async () => controls.currentIteration(), { timeout: 20_000 }).toBe(start + i);
    }

    for (let i = 1; i <= steps; i++) {
      await controls.backwardButton().click();
      await expect
        .poll(async () => controls.currentIteration(), {
          timeout: 20_000,
          message: `backward click ${i} should select iteration ${start + steps - i}`,
        })
        .toBe(start + steps - i);
    }

    // The total is still untouched after a full round trip.
    expect(await controls.totalIterations()).toBe(total);
  });
});
