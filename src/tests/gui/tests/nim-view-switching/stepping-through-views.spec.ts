/**
 * E2E tests for single-stepping through different code views in Nim traces (S8).
 *
 * CodeTracer supports 3-way view switching for Nim: original Nim source,
 * generated C code, and assembly. The debugger should act as if debugging the
 * currently visible language:
 *   - In C view (ViewTargetSource), stepping uses `nextc`/`stepc` (C-level)
 *   - In assembly view (ViewInstructions), stepping moves by instructions
 *   - In Nim view (ViewSource), stepping moves by Nim source lines
 *
 * Backward stepping works via rr's time-travel debugging (reverse-next).
 *
 * These tests use the `nim_sudoku_solver` test program (RR-based Nim trace)
 * and require:
 *   - The RR backend (ct-native-replay)
 *   - The trace recorded with a sourcemap-enabled Nim compiler
 *
 * Stepping forward in the C view, in the assembly view and by Nim lines are
 * scenarios now (src/tests/scenarios/nim-views/generated-c-follows-the-nim-stop.yaml,
 * disassembly-steps-by-instruction.yaml, nim-step-moves-by-nim-lines.yaml).
 * The two backward steps stay until their scenarios pass (codetracer-pm issues
 * 2026-11-15-reverse-next-never-completes-on-an-rr-nim-recording.md,
 * 2026-11-14-desktop-low-level-code-reverse-instruction-step-leaves-the-function.md).
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";
import { moveAndSettle, waitForNotBusy } from "../../lib/operation-settled";
import {
  ViewInstructions,
  ViewTargetSource,
  openAlternativeView,
} from "../../lib/alternative-views";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Waits for the status bar location to stabilize and returns the parsed
 * path and line. Retries to handle asynchronous UI updates.
 */
async function waitForStatusBarLocation(
  statusBar: StatusBar,
  maxAttempts = 30,
): Promise<{ path: string; line: number }> {
  let result = { path: "", line: 0 };
  await retry(
    async () => {
      const loc = await statusBar.location();
      result = loc;
      return loc.path.length > 0 && loc.line > 0;
    },
    { maxAttempts, delayMs: 500 },
  );
  return result;
}

/**
 * Reads the raw status bar text which has format: path:line#rrTicks
 * Returns the full raw string so callers can extract the rrTicks portion.
 */
async function getRawStatusBarText(
  statusBar: StatusBar,
): Promise<string> {
  let raw = "";
  await retry(
    async () => {
      raw = await statusBar.rawLocation();
      return raw.length > 0 && raw.includes("#");
    },
    { maxAttempts: 20, delayMs: 500 },
  );
  return raw;
}

/**
 * Parses rrTicks from the raw status bar text (format: path:line#rrTicks).
 */
function parseRrTicks(raw: string): number {
  const parts = raw.split("#");
  if (parts.length < 2) return -1;
  const ticks = parseInt(parts[1], 10);
  return isNaN(ticks) ? -1 : ticks;
}

/**
 * Waits for the sourcemap to be loaded.  Returns whether it arrived.
 *
 * This is a *diagnostic*, not a gate: the C and assembly views are opened
 * through `openAlternativeView`, which reports the precise missing
 * precondition itself.  Waiting here just gives the backend time to deliver
 * the sourcemap before we look at `cLocation`.
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
      { maxAttempts: 30, delayMs: 1000 },
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * Waits for the initial editor and debugger to be ready with a .nim file.
 */
async function waitForNimEditorReady(
  layout: LayoutPage,
  page: import("@playwright/test").Page,
): Promise<void> {
  await layout.waitForBaseComponentsLoaded();
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      return editors.some((e) => e.fileName.endsWith(".nim"));
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
  await waitForNotBusy(page);
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("SteppingThroughViews", () => {
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time for compile + record + launch.
  test.setTimeout(180_000);

  test("step backward in C view (reverse stepping)", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    await waitForSourcemap(ctPage);

    await openAlternativeView(ctPage, ViewTargetSource, async () => {
      await moveAndSettle(ctPage, () => ctPage.locator("#next-image").click());
    });
    await waitForNotBusy(ctPage);

    // Step forward a few times to establish a position we can step back from.
    const nextBtn = ctPage.locator("#next-image");
    for (let i = 0; i < 3; i++) {
      await moveAndSettle(ctPage, () => nextBtn.click());
    }

    // Record the position after stepping forward.
    const beforeBackRaw = await getRawStatusBarText(statusBar);
    const beforeBackTicks = parseRrTicks(beforeBackRaw);
    const beforeBackLocation = await waitForStatusBarLocation(statusBar);

    // Step backward (reverse-next). In C view with rr, this should issue a
    // reverse nextc which moves back by one C source line.
    const reverseNextBtn = ctPage.locator("#reverse-next-image");
    await moveAndSettle(ctPage, () => reverseNextBtn.click());

    // Verify that the execution position moved backward. The rrTicks should
    // have decreased (or at least the line should have changed).
    const afterBackRaw = await getRawStatusBarText(statusBar);
    const afterBackTicks = parseRrTicks(afterBackRaw);
    const afterBackLocation = await waitForStatusBarLocation(statusBar);

    const positionChanged =
      afterBackLocation.line !== beforeBackLocation.line ||
      afterBackTicks !== beforeBackTicks;
    expect(positionChanged).toBe(true);

    // If we can reliably parse ticks, verify backward direction.
    if (beforeBackTicks > 0 && afterBackTicks > 0) {
      expect(afterBackTicks).toBeLessThanOrEqual(beforeBackTicks);
    }
  });

  // Was permanently skipped for the same reason as "step forward in assembly
  // view" above; same disposition.
  test("step backward in assembly view", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    await waitForNimEditorReady(layout, ctPage);
    await waitForSourcemap(ctPage);

    await openAlternativeView(ctPage, ViewInstructions, async () => {
      await moveAndSettle(ctPage, () => ctPage.locator("#next-image").click());
    });
    await waitForNotBusy(ctPage);

    // Step forward a few times first.
    const nextBtn = ctPage.locator("#next-image");
    for (let i = 0; i < 3; i++) {
      await moveAndSettle(ctPage, () => nextBtn.click());
    }

    // Record position before stepping back.
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);
    const beforeLocation = await waitForStatusBarLocation(statusBar);

    // Step backward in assembly view.
    const reverseNextBtn = ctPage.locator("#reverse-next-image");
    await moveAndSettle(ctPage, () => reverseNextBtn.click());

    // Verify backward movement.
    const afterRaw = await getRawStatusBarText(statusBar);
    const afterTicks = parseRrTicks(afterRaw);
    const afterLocation = await waitForStatusBarLocation(statusBar);

    const positionChanged =
      afterLocation.line !== beforeLocation.line ||
      afterTicks !== beforeTicks;
    expect(positionChanged).toBe(true);

    // Ticks should have decreased for backward stepping.
    if (beforeTicks > 0 && afterTicks > 0) {
      expect(afterTicks).toBeLessThanOrEqual(beforeTicks);
    }
  });

});
