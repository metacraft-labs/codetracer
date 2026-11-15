/**
 * E2E tests for 3-way view switching in Nim traces: Nim source <-> C code <-> Assembly.
 *
 * The Nim compiler (with --sourcemap:on) produces C code as an intermediate step.
 * CodeTracer exposes three editor views for Nim programs:
 *   - ViewSource (0): The original .nim file
 *   - ViewTargetSource (1): The generated .c file (via Nim-to-C sourcemap)
 *   - ViewInstructions (2): Disassembled machine instructions
 *
 * View switching is triggered via the frontend's `openTargetSource` and
 * `openInstructions` functions (accessed through `window.data`), or through
 * the internal `openViewOnCompleteMove` mechanism.
 *
 * These tests use the `nim_sudoku_solver` test program which is an RR-based
 * Nim trace. They require:
 *   - The RR backend to be available (ct-native-replay)
 *   - The trace to have been recorded with a sourcemap-enabled Nim compiler
 *
 * The Nim source view, the C view and the assembly view are scenarios now
 * (src/tests/scenarios/nim-views/generated-c-opens-at-the-stop.yaml,
 * disassembly-steps-by-instruction.yaml), opened from the View menu. The
 * view-synchronization test stays until its scenario passes
 * (codetracer-pm issues/2026-11-15-a-step-replaces-the-generated-c-listing-with-the-disassembly.md
 * carries it).
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";
import { moveAndSettle, waitForNotBusy } from "../../lib/operation-settled";
import {
  ViewTargetSource,
  openAlternativeView,
} from "../../lib/alternative-views";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Reads the debugger's high-level (Nim) and generated-C positions in one shot.
 *
 * All four reads are plain fields on `DebuggerService`
 * (`location*`/`cLocation*: Location`, src/frontend/types.nim:306-308),
 * reachable from JS through the session-forwarding `services` accessor
 * installed on `window.data` (src/frontend/types.nim:2519+).  No Nim proc is
 * called, so nothing here depends on method-style dispatch.
 */
async function readDebuggerPosition(
  page: import("@playwright/test").Page,
): Promise<{
  path: string;
  line: number;
  rrTicks: number;
  cPath: string;
  cLine: number;
}> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const dbg = w.data?.services?.debugger;
    const str = (v: unknown): string => (typeof v === "string" ? v : "");
    const num = (v: unknown): number => (typeof v === "number" ? v : -1);
    return {
      path: str(dbg?.location?.path),
      line: num(dbg?.location?.line),
      rrTicks: num(dbg?.location?.rrTicks),
      cPath: str(dbg?.cLocation?.path),
      cLine: num(dbg?.cLocation?.line),
    };
  });
}

/**
 * Waits for the Nim-to-C sourcemap to be loaded for the current session.
 * Returns whether it arrived.
 *
 * This is a *diagnostic wait*, not a skip gate: the alternative views are
 * opened through `openAlternativeView`, which names the precise missing
 * precondition (sourcemap state included) when it cannot open a view.
 */
async function waitForSourcemap(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  try {
    await retry(
      async () =>
        page.evaluate(() => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          return w.data?.sourcemap?.loaded === true;
        }),
      { maxAttempts: 20, delayMs: 1000 },
    );
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("NimViewSwitching", () => {
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time for compile + record + launch.
  test.setTimeout(180_000);

  // The two up-front `test.skip` guards this test used to carry are gone.
  // They were justified as flake tolerance, but they turned "the Nim trace
  // never loaded" and "the status bar never showed a Nim file" — the suite's
  // own preconditions, which the three sibling tests in this file assert
  // rather than skip on — into passes.  Combined with the dead
  // `switchToTargetSourceView` below, this test could report success having
  // checked nothing at all.  Both are now hard failures, consistent with
  // "Nim source view shows .nim file" directly above.
  test("view synchronization - stepping updates views consistently", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    // Wait for the editor and debugger to be ready with a .nim file.
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        return editors.some((e) => e.fileName.endsWith(".nim"));
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
    await waitForNotBusy(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    // Record the initial Nim source line from the status bar.
    const initialLocation = await statusBar.location();
    expect(initialLocation.path).toContain(".nim");

    // Step forward (next/step-over) to advance the execution position.
    // Use `clickNextButton` so the layout-manager `lm_header` /
    // `jstree-themeicon` overlay (which intermittently intercepts
    // pointer events on this layout) falls through to a force-click
    // / dispatchEvent fallback rather than failing the click outright.
    await moveAndSettle(ctPage, () => layout.clickNextButton());

    // Verify the Nim line changed (or at least the debugger moved).
    // The line may or may not change depending on the instruction, but
    // the status bar should still show a valid .nim location.
    const afterStepLocation = await statusBar.location();
    expect(afterStepLocation.path).toContain(".nim");

    // ---------------------------------------------------------------------
    // The actual synchronization claim.
    //
    // Everything above only ever asserted that the Nim view was still the Nim
    // view.  The part that gave this test its name lived inside
    // `if (switchedToC) { ... }`, and `switchedToC` was the return value of a
    // helper gated on `typeof data.openTab === "function"` — permanently
    // false.  So the C view was never opened and *nothing* about
    // synchronization was ever checked.
    //
    // With the C view now openable, we can assert what the name claims:
    // the Nim view and the C view are two projections of ONE execution
    // position, so (1) they are open at the same time, (2) a step advances
    // the shared position and refreshes the C projection with it, and
    // (3) merely switching between the tabs does not move the debugger.
    // ---------------------------------------------------------------------
    await waitForSourcemap(ctPage);

    await openAlternativeView(ctPage, ViewTargetSource, async () => {
      await moveAndSettle(ctPage, () => layout.clickNextButton());
    });

    // (1) Both projections are open simultaneously.
    const tabsWithC = await layout.editorTabs(true);
    expect(tabsWithC.some((e) => e.fileName.endsWith(".nim"))).toBe(true);
    expect(
      tabsWithC.some(
        (e) => e.fileName.endsWith(".c") || e.fileName.endsWith(".h"),
      ),
    ).toBe(true);

    // (2) A step advances the shared position, and the C projection tracks it.
    const beforeStep = await readDebuggerPosition(ctPage);
    await moveAndSettle(ctPage, () => layout.clickNextButton());
    const afterStep = await readDebuggerPosition(ctPage);

    expect(afterStep.rrTicks).not.toBe(beforeStep.rrTicks);
    // The C projection must describe a real generated-C position, not a stale
    // or empty one — this is what "views update consistently" means.
    expect(afterStep.cPath).toMatch(/\.(c|h)$/);
    expect(afterStep.cLine).toBeGreaterThan(0);
    // And the high-level projection must still be the Nim source.
    expect(afterStep.path).toContain(".nim");
    expect(afterStep.line).toBeGreaterThan(0);

    // (3) Switching views is a presentation change, not a navigation: the
    // debugger position must be identical before and after clicking back to
    // the Nim tab.
    const editorsForSwitchBack = await layout.editorTabs(true);
    const nimEditor = editorsForSwitchBack.find((e) =>
      e.fileName.endsWith(".nim"),
    );
    if (!nimEditor) {
      throw new Error(
        "The .nim editor tab disappeared after opening the C view; cannot " +
          "check that switching views preserves the debugger position.",
      );
    }
    await nimEditor.tabButton().click();
    await waitForNotBusy(ctPage);

    const afterSwitchBack = await readDebuggerPosition(ctPage);
    expect(afterSwitchBack.rrTicks).toBe(afterStep.rrTicks);
    expect(afterSwitchBack.line).toBe(afterStep.line);
    expect(afterSwitchBack.path).toContain(".nim");

    const finalLocation = await statusBar.location();
    expect(finalLocation.path).toContain(".nim");
    expect(finalLocation.line).toBeGreaterThan(0);
  });
});
