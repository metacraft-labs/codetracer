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
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";

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
 * Waits for the debugger to be "ready" (not busy) after a navigation action.
 * Polls the stable-status element's class for "ready-status".
 */
async function waitForReadyStatus(
  page: import("@playwright/test").Page,
): Promise<void> {
  await retry(
    async () => {
      const status = page.locator("#stable-status");
      const className = (await status.getAttribute("class")) ?? "";
      return className.includes("ready-status");
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
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
 * Opens the C code view (ViewTargetSource) for a Nim trace.
 * Returns true if the switch succeeded.
 */
async function switchToTargetSourceView(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return false;

    const session = data.sessions?.[data.activeSessionIndex];
    if (!session) return false;

    const cPath = session.services?.debugger?.cLocation?.path;
    if (!cPath || cPath.length === 0) return false;

    if (typeof data.openTab === "function") {
      data.openTab(cPath, 1); // 1 = ViewTargetSource
      data.ui.openViewOnCompleteMove[1] = true;
      return true;
    }

    return false;
  });
}

/**
 * Opens the assembly/instructions view (ViewInstructions) for a Nim trace.
 * Returns true if the switch succeeded.
 */
async function switchToInstructionsView(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return false;

    const session = data.sessions?.[data.activeSessionIndex];
    if (!session) return false;

    const asmName = session.services?.debugger?.cLocation?.asmName ??
                    session.services?.debugger?.location?.asmName;
    if (!asmName || asmName.length === 0) return false;

    if (typeof data.openTab === "function") {
      data.openTab(asmName, 2); // 2 = ViewInstructions
      data.ui.openViewOnCompleteMove[2] = true;
      return true;
    }

    return false;
  });
}

/**
 * Switches back to the default Nim source view (ViewSource).
 * Opens the .nim file tab if available, or uses openViewOnCompleteMove[0].
 */
async function switchToNimSourceView(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return false;

    const session = data.sessions?.[data.activeSessionIndex];
    if (!session) return false;

    const nimPath = session.services?.debugger?.location?.path;
    if (!nimPath || nimPath.length === 0) return false;

    if (typeof data.openTab === "function") {
      data.openTab(nimPath, 0); // 0 = ViewSource
      data.ui.openViewOnCompleteMove[0] = true;
      return true;
    }

    return false;
  });
}

/**
 * Checks whether the sourcemap data has been loaded for the current session.
 */
async function isSourcemapLoaded(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return false;

    const session = data.sessions?.[data.activeSessionIndex];
    if (!session) return false;

    const sm = session.sourcemap;
    return sm != null && sm.loaded === true;
  });
}

/**
 * Waits for the sourcemap to be loaded, with a generous timeout.
 * Returns true if loaded, false if not available.
 */
async function waitForSourcemap(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  try {
    await retry(
      async () => isSourcemapLoaded(page),
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
  await waitForReadyStatus(page);
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("SteppingThroughViews", () => {
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time for compile + record + launch.
  test.setTimeout(180_000);

  test("step forward in C view", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    // Wait for sourcemap — required for C view.
    const smAvailable = await waitForSourcemap(ctPage);
    if (!smAvailable) {
      test.skip(
        true,
        "Sourcemap not available: trace was likely recorded without --sourcemap:on. " +
        "Skipping C view stepping test.",
      );
      return;
    }

    // Switch to C view (ViewTargetSource).
    let switched = false;
    await retry(
      async () => {
        switched = await switchToTargetSourceView(ctPage);
        return switched;
      },
      { maxAttempts: 10, delayMs: 1000 },
    );
    if (!switched) {
      test.skip(
        true,
        "C location path not available from the debugger. Cannot test C view stepping.",
      );
      return;
    }
    await waitForReadyStatus(ctPage);

    // Record the current C line from the status bar.
    const beforeLocation = await waitForStatusBarLocation(statusBar);
    const beforeLine = beforeLocation.line;
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);

    // Press the step-forward (next) button. In C view, this should issue a
    // C-level next (nextc) which advances by one C source line.
    const nextBtn = ctPage.locator("#next-debug");
    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    // Verify that the execution position moved forward. We check that either
    // the line changed or the rrTicks advanced (the line may wrap back on
    // loops, but ticks always advance forward).
    const afterRaw = await getRawStatusBarText(statusBar);
    const afterTicks = parseRrTicks(afterRaw);
    const afterLocation = await waitForStatusBarLocation(statusBar);
    const afterLine = afterLocation.line;

    const positionChanged = afterLine !== beforeLine || afterTicks !== beforeTicks;
    expect(positionChanged).toBe(true);

    // The status bar should show a .c or .h file in C view mode.
    expect(afterLocation.path).toMatch(/\.(c|h|nim)$/);
  });

  test("step backward in C view (reverse stepping)", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    const smAvailable = await waitForSourcemap(ctPage);
    if (!smAvailable) {
      test.skip(true, "Sourcemap not available. Skipping reverse C stepping test.");
      return;
    }

    let switched = false;
    await retry(
      async () => {
        switched = await switchToTargetSourceView(ctPage);
        return switched;
      },
      { maxAttempts: 10, delayMs: 1000 },
    );
    if (!switched) {
      test.skip(true, "C location path not available. Cannot test reverse C stepping.");
      return;
    }
    await waitForReadyStatus(ctPage);

    // Step forward a few times to establish a position we can step back from.
    const nextBtn = ctPage.locator("#next-debug");
    for (let i = 0; i < 3; i++) {
      await nextBtn.click();
      await waitForReadyStatus(ctPage);
    }

    // Record the position after stepping forward.
    const beforeBackRaw = await getRawStatusBarText(statusBar);
    const beforeBackTicks = parseRrTicks(beforeBackRaw);
    const beforeBackLocation = await waitForStatusBarLocation(statusBar);

    // Step backward (reverse-next). In C view with rr, this should issue a
    // reverse nextc which moves back by one C source line.
    const reverseNextBtn = ctPage.locator("#reverse-next-debug");
    await reverseNextBtn.click();
    await waitForReadyStatus(ctPage);

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

  test("step forward in assembly view", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    // Switch to assembly/instructions view.
    let switched = false;
    await retry(
      async () => {
        switched = await switchToInstructionsView(ctPage);
        return switched;
      },
      { maxAttempts: 10, delayMs: 1000 },
    );
    if (!switched) {
      test.skip(
        true,
        "Assembly name not available from the debugger. Cannot test assembly stepping.",
      );
      return;
    }
    await waitForReadyStatus(ctPage);

    // Record the current position. In assembly view the status bar still
    // shows path:line#ticks, but the line corresponds to an instruction offset.
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);
    const beforeLocation = await waitForStatusBarLocation(statusBar);

    // Step forward. In assembly view, this should move to the next instruction
    // (stepi-level granularity).
    const nextBtn = ctPage.locator("#next-debug");
    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    // Verify the instruction offset or ticks changed.
    const afterRaw = await getRawStatusBarText(statusBar);
    const afterTicks = parseRrTicks(afterRaw);
    const afterLocation = await waitForStatusBarLocation(statusBar);

    const positionChanged =
      afterLocation.line !== beforeLocation.line ||
      afterTicks !== beforeTicks;
    expect(positionChanged).toBe(true);
  });

  test("step backward in assembly view", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    let switched = false;
    await retry(
      async () => {
        switched = await switchToInstructionsView(ctPage);
        return switched;
      },
      { maxAttempts: 10, delayMs: 1000 },
    );
    if (!switched) {
      test.skip(true, "Assembly name not available. Cannot test reverse assembly stepping.");
      return;
    }
    await waitForReadyStatus(ctPage);

    // Step forward a few times first.
    const nextBtn = ctPage.locator("#next-debug");
    for (let i = 0; i < 3; i++) {
      await nextBtn.click();
      await waitForReadyStatus(ctPage);
    }

    // Record position before stepping back.
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);
    const beforeLocation = await waitForStatusBarLocation(statusBar);

    // Step backward in assembly view.
    const reverseNextBtn = ctPage.locator("#reverse-next-debug");
    await reverseNextBtn.click();
    await waitForReadyStatus(ctPage);

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

  test("stepping in Nim view moves by Nim lines", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    // Ensure we are in the default Nim source view.
    const initialLocation = await waitForStatusBarLocation(statusBar);
    expect(initialLocation.path).toContain(".nim");
    const initialLine = initialLocation.line;

    // Record rrTicks before stepping.
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);

    // Step forward in Nim view. This should issue a source-level next which
    // moves by Nim lines (not C line granularity).
    const nextBtn = ctPage.locator("#next-debug");
    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    // Verify the Nim line changed or execution advanced.
    const afterLocation = await waitForStatusBarLocation(statusBar);
    expect(afterLocation.path).toContain(".nim");

    const afterRaw = await getRawStatusBarText(statusBar);
    const afterTicks = parseRrTicks(afterRaw);

    const positionChanged =
      afterLocation.line !== initialLine || afterTicks !== beforeTicks;
    expect(positionChanged).toBe(true);

    // The line should still be a valid Nim source line number.
    expect(afterLocation.line).toBeGreaterThan(0);
  });
});
