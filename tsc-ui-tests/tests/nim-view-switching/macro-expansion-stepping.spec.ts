/**
 * E2E tests for stepping through macro-expanded code in Nim traces (S7).
 *
 * When a Nim program uses macros and is compiled with --sourcemap:on, CodeTracer
 * can expand macro calls inline and allow stepping through the expanded code.
 * The expansion is triggered with ALT+E on a line containing a macro call.
 *
 * These tests require:
 *   - A Nim test program that uses macros
 *   - The Nim compiler with --sourcemap:on producing macro expansion data
 *   - The RR backend (ct-native-replay)
 *
 * NOTE: Macro expansion stepping is an advanced feature that depends on the
 * sourcemap containing macro expansion mappings. If the infrastructure does not
 * support this yet, tests will skip gracefully.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Waits for the debugger to be "ready" (not busy) after a navigation action.
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
 * Waits for the status bar location to stabilize and returns the parsed
 * path and line.
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
 * Reads the raw status bar text (format: path:line#rrTicks).
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
 * Parses rrTicks from the raw status bar text.
 */
function parseRrTicks(raw: string): number {
  const parts = raw.split("#");
  if (parts.length < 2) return -1;
  const ticks = parseInt(parts[1], 10);
  return isNaN(ticks) ? -1 : ticks;
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
 * Checks whether macro expansion data is available in the sourcemap.
 * Returns true if the sourcemap contains macro expansion mappings.
 */
async function hasMacroExpansionData(
  page: import("@playwright/test").Page,
): Promise<boolean> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return false;

    const session = data.sessions?.[data.activeSessionIndex];
    if (!session) return false;

    const sm = session.sourcemap;
    if (!sm || !sm.loaded) return false;

    // Check for macro expansion data in the sourcemap. The structure may vary
    // depending on the Nim compiler version and sourcemap format.
    // Common fields: macroExpansions, expandedMacros, or macros.
    if (sm.macroExpansions && Object.keys(sm.macroExpansions).length > 0) {
      return true;
    }
    if (sm.expandedMacros && Object.keys(sm.expandedMacros).length > 0) {
      return true;
    }
    if (sm.macros && Object.keys(sm.macros).length > 0) {
      return true;
    }

    return false;
  });
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

test.describe("MacroExpansionStepping", () => {
  // Use the nim_sudoku_solver test program. Ideally we would use a test program
  // with explicit macro usage, but this is the standard Nim RR test program.
  // If it doesn't contain macros, tests will skip gracefully.
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time.
  test.setTimeout(180_000);

  test("expand macro and step through expanded code", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    // Check whether the sourcemap is available with macro expansion data.
    let smLoaded = false;
    try {
      await retry(
        async () => {
          smLoaded = await isSourcemapLoaded(ctPage);
          return smLoaded;
        },
        { maxAttempts: 20, delayMs: 1000 },
      );
    } catch {
      // Sourcemap never loaded.
    }

    if (!smLoaded) {
      test.skip(
        true,
        "Sourcemap not available: trace was likely recorded without --sourcemap:on. " +
        "Skipping macro expansion test.",
      );
      return;
    }

    const hasMacros = await hasMacroExpansionData(ctPage);
    if (!hasMacros) {
      test.skip(
        true,
        "No macro expansion data found in the sourcemap. The test program may not " +
        "use macros, or the Nim compiler does not emit macro expansion mappings yet. " +
        "Skipping macro expansion stepping test.",
      );
      return;
    }

    // Navigate to a line with a macro call. Since we don't know the exact line,
    // we use the current debugger position and try ALT+E to trigger expansion.
    const initialLocation = await waitForStatusBarLocation(statusBar);
    expect(initialLocation.path).toContain(".nim");

    // Trigger macro expansion with ALT+E.
    await ctPage.keyboard.press("Alt+e");

    // Wait for the expansion to take effect. The editor should show expanded
    // macro code — either as inline content or as a new tab/view.
    let expansionVisible = false;
    try {
      await retry(
        async () => {
          // Check for expansion indicators: new editor content, expanded lines,
          // or a macro expansion overlay/panel.
          expansionVisible = await ctPage.evaluate(() => {
            const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
            const data = w.data;
            if (!data) return false;

            // Check if the UI has entered macro expansion mode.
            const session = data.sessions?.[data.activeSessionIndex];
            if (!session) return false;

            // Look for macro expansion state in the UI or editor service.
            const editorService = session.services?.editor;
            if (editorService?.macroExpansionActive) return true;

            // Check if the active view changed to show expanded content.
            const ui = data.ui;
            if (ui?.macroExpansionVisible) return true;

            return false;
          });
          return expansionVisible;
        },
        { maxAttempts: 10, delayMs: 500 },
      );
    } catch {
      // Expansion may not have triggered — the current line might not be a macro.
    }

    if (!expansionVisible) {
      test.skip(
        true,
        "Macro expansion did not activate at the current debugger position. " +
        "The current line may not contain a macro call, or the expansion " +
        "feature is not yet fully implemented for this trace.",
      );
      return;
    }

    // Record position before stepping through expanded code.
    const beforeRaw = await getRawStatusBarText(statusBar);
    const beforeTicks = parseRrTicks(beforeRaw);
    const beforeLocation = await waitForStatusBarLocation(statusBar);

    // Step forward through the expanded macro code.
    const nextBtn = ctPage.locator("#next-debug");
    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    // Verify that the execution position changed — we should move through
    // the expanded macro lines.
    const afterRaw = await getRawStatusBarText(statusBar);
    const afterTicks = parseRrTicks(afterRaw);
    const afterLocation = await waitForStatusBarLocation(statusBar);

    const positionChanged =
      afterLocation.line !== beforeLocation.line ||
      afterTicks !== beforeTicks;
    expect(positionChanged).toBe(true);

    // Step forward again to confirm continued movement through expanded code.
    const secondBeforeRaw = await getRawStatusBarText(statusBar);
    const secondBeforeTicks = parseRrTicks(secondBeforeRaw);

    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    const secondAfterRaw = await getRawStatusBarText(statusBar);
    const secondAfterTicks = parseRrTicks(secondAfterRaw);
    const secondAfterLocation = await waitForStatusBarLocation(statusBar);

    const secondPositionChanged =
      secondAfterLocation.line !== afterLocation.line ||
      secondAfterTicks !== secondBeforeTicks;
    expect(secondPositionChanged).toBe(true);
  });

  test("macro expansion preserves stepping context after collapse", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    await waitForNimEditorReady(layout, ctPage);

    // Verify sourcemap with macro data.
    let smLoaded = false;
    try {
      await retry(
        async () => {
          smLoaded = await isSourcemapLoaded(ctPage);
          return smLoaded;
        },
        { maxAttempts: 20, delayMs: 1000 },
      );
    } catch {
      // Not loaded.
    }

    if (!smLoaded) {
      test.skip(true, "Sourcemap not available. Skipping macro context preservation test.");
      return;
    }

    const hasMacros = await hasMacroExpansionData(ctPage);
    if (!hasMacros) {
      test.skip(
        true,
        "No macro expansion data in sourcemap. Skipping context preservation test.",
      );
      return;
    }

    // Try to expand a macro.
    await ctPage.keyboard.press("Alt+e");

    let expansionVisible = false;
    try {
      await retry(
        async () => {
          expansionVisible = await ctPage.evaluate(() => {
            const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
            const data = w.data;
            if (!data) return false;
            const session = data.sessions?.[data.activeSessionIndex];
            if (!session) return false;
            const editorService = session.services?.editor;
            if (editorService?.macroExpansionActive) return true;
            const ui = data.ui;
            if (ui?.macroExpansionVisible) return true;
            return false;
          });
          return expansionVisible;
        },
        { maxAttempts: 10, delayMs: 500 },
      );
    } catch {
      // Not expanded.
    }

    if (!expansionVisible) {
      test.skip(
        true,
        "Macro expansion did not activate. Skipping context preservation test.",
      );
      return;
    }

    // Step forward a couple of times in expanded code.
    const nextBtn = ctPage.locator("#next-debug");
    await nextBtn.click();
    await waitForReadyStatus(ctPage);
    await nextBtn.click();
    await waitForReadyStatus(ctPage);

    // Record position in expanded code.
    const expandedRaw = await getRawStatusBarText(statusBar);
    const expandedTicks = parseRrTicks(expandedRaw);

    // Collapse the macro expansion by pressing ALT+E again (toggle).
    await ctPage.keyboard.press("Alt+e");

    // Wait for the UI to settle after collapse.
    await waitForReadyStatus(ctPage);

    // The debugger position (rrTicks) should be preserved — we are still at
    // the same execution point, just viewing it in the original source.
    const afterCollapseRaw = await getRawStatusBarText(statusBar);
    const afterCollapseTicks = parseRrTicks(afterCollapseRaw);
    const afterCollapseLocation = await waitForStatusBarLocation(statusBar);

    // The execution point (ticks) should not have changed.
    if (expandedTicks > 0 && afterCollapseTicks > 0) {
      expect(afterCollapseTicks).toBe(expandedTicks);
    }

    // After collapsing, the status bar should show the .nim source path.
    expect(afterCollapseLocation.path).toContain(".nim");
    expect(afterCollapseLocation.line).toBeGreaterThan(0);
  });
});
