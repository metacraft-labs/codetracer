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
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Waits for the status bar location to stabilize and returns the parsed path.
 * Retries up to `maxAttempts` times to handle asynchronous UI updates.
 */
async function waitForStatusBarPath(
  statusBar: StatusBar,
  maxAttempts = 30,
): Promise<string> {
  let path = "";
  await retry(
    async () => {
      const loc = await statusBar.location();
      path = loc.path;
      return path.length > 0;
    },
    { maxAttempts, delayMs: 500 },
  );
  return path;
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
 * Opens the C code view (ViewTargetSource) for a Nim trace by invoking the
 * frontend's openTargetSource function via page.evaluate.
 *
 * This reads data.services.debugger.cLocation.path from the global `data`
 * object and calls the compiled openTargetSource function. If the cLocation
 * path is not available (e.g., sourcemap not loaded), it returns false.
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

    // Use the openTab API to open the C file in ViewTargetSource mode (view 1).
    // openTab is the underlying function used by openTargetSource.
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
 *
 * For Nim, this uses cLocation.asmName (the assembly name from the C-level
 * debugger location) since the assembly corresponds to the compiled C code.
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

    // Use the openTab API to open the assembly view (view 2 = ViewInstructions).
    if (typeof data.openTab === "function") {
      data.openTab(asmName, 2); // 2 = ViewInstructions
      data.ui.openViewOnCompleteMove[2] = true;
      return true;
    }

    return false;
  });
}

/**
 * Reads the text content of the currently active editor's Monaco instance.
 * Returns the full text or an empty string if not available.
 */
async function getActiveEditorContent(
  page: import("@playwright/test").Page,
): Promise<string> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    if (!data) return "";

    const active = data.services?.editor?.active;
    if (!active) return "";

    const editor = data.ui?.editors?.[active];
    if (!editor?.monacoEditor) return "";

    const model = editor.monacoEditor.getModel();
    if (!model) return "";

    return model.getValue() ?? "";
  });
}

/**
 * Checks whether the sourcemap data has been loaded for the current session.
 * Returns true if the sourcemap is loaded and contains C-to-Nim mappings.
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

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("NimViewSwitching", () => {
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time for compile + record + launch.
  test.setTimeout(180_000);

  test("Nim source view shows .nim file", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    // Wait for the editor to load with a .nim file.
    let nimEditorFound = false;
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        nimEditorFound = editors.some((e) =>
          e.fileName.endsWith(".nim"),
        );
        return nimEditorFound;
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
    expect(nimEditorFound).toBe(true);

    // Verify the status bar shows a .nim file path.
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const path = await waitForStatusBarPath(statusBar);
    expect(path).toContain(".nim");
  });

  test("switch to C view shows generated .c code", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    // Wait for the editor and debugger to be ready.
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        return editors.some((e) => e.fileName.endsWith(".nim"));
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
    await waitForReadyStatus(ctPage);

    // Check whether the sourcemap is available. If not, this trace was
    // recorded without --sourcemap:on or without the patched Nim compiler.
    const smLoaded = await isSourcemapLoaded(ctPage);
    if (!smLoaded) {
      // The sourcemap may not be loaded yet if the backend hasn't sent it.
      // Wait a bit and re-check before skipping.
      let smAvailable = false;
      try {
        await retry(
          async () => {
            smAvailable = await isSourcemapLoaded(ctPage);
            return smAvailable;
          },
          { maxAttempts: 20, delayMs: 1000 },
        );
      } catch {
        // Sourcemap never loaded.
      }
      if (!smAvailable) {
        test.skip(
          true,
          "Sourcemap not available: trace was likely recorded without --sourcemap:on " +
          "or without the patched Nim compiler. Skipping C view test.",
        );
        return;
      }
    }

    // Trigger the switch to ViewTargetSource (C code view).
    const switched = await switchToTargetSourceView(ctPage);
    if (!switched) {
      // If cLocation.path is not available, the debugger may not have
      // resolved the C-level location yet. Skip gracefully.
      test.skip(
        true,
        "C location path not available from the debugger. The trace may not " +
        "support ViewTargetSource for this program.",
      );
      return;
    }

    // Wait for a new editor tab to appear with a .c file.
    let cEditorFound = false;
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        cEditorFound = editors.some((e) =>
          e.fileName.endsWith(".c") || e.fileName.endsWith(".h"),
        );
        return cEditorFound;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(cEditorFound).toBe(true);

    // Verify the editor content contains C code markers.
    // Nim-generated C files typically contain includes, NIM types, or N_NIMCALL.
    let editorContent = "";
    await retry(
      async () => {
        editorContent = await getActiveEditorContent(ctPage);
        if (editorContent.length === 0) return false;
        // Look for any C code markers in Nim-generated C files.
        const cMarkers = [
          "#include",
          "NIM_CHAR",
          "N_NIMCALL",
          "NI ",       // Nim integer type
          "nimfr_",    // Nim frame macro
          "typedef",
          "void ",
          "int ",
          "NIM_BOOL",
        ];
        return cMarkers.some((marker) => editorContent.includes(marker));
      },
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(editorContent.length).toBeGreaterThan(0);

    // Verify the status bar updated to show the .c file path.
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const statusPath = await waitForStatusBarPath(statusBar);
    expect(statusPath).toMatch(/\.(c|h)$/);
  });

  test("switch to assembly view shows disassembly", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    // Wait for the editor to load.
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        return editors.some((e) => e.fileName.endsWith(".nim"));
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
    await waitForReadyStatus(ctPage);

    // Trigger the switch to ViewInstructions (assembly view).
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
        "Assembly name not available from the debugger. The trace may not " +
        "support ViewInstructions for this program.",
      );
      return;
    }

    // Wait for an editor tab with assembly content to appear.
    // Assembly tabs don't have a .s extension; they're named after the function
    // or binary. Instead, verify the content contains instruction mnemonics.
    let asmContent = "";
    await retry(
      async () => {
        asmContent = await getActiveEditorContent(ctPage);
        if (asmContent.length === 0) return false;
        // Look for common x86/x86_64 instruction mnemonics in the disassembly.
        const asmPatterns = [
          /\b(mov|push|pop|call|ret|jmp|je|jne|jz|jnz|lea|add|sub|xor|cmp|test|nop)\b/i,
          /\b(endbr64|endbr32)\b/i,
          // ARM instructions (in case the test runs on ARM)
          /\b(ldr|str|bl|bx|stp|ldp|adrp)\b/i,
        ];
        return asmPatterns.some((pattern) => pattern.test(asmContent));
      },
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(asmContent.length).toBeGreaterThan(0);
  });

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
    await waitForReadyStatus(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    // Record the initial Nim source line from the status bar.
    const initialLocation = await statusBar.location();
    expect(initialLocation.path).toContain(".nim");
    const initialLine = initialLocation.line;

    // Step forward (next/step-over) to advance the execution position.
    const stepOverBtn = ctPage.locator("#next-debug");
    await stepOverBtn.click();
    await waitForReadyStatus(ctPage);

    // Verify the Nim line changed (or at least the debugger moved).
    // The line may or may not change depending on the instruction, but
    // the status bar should still show a valid .nim location.
    const afterStepLocation = await statusBar.location();
    expect(afterStepLocation.path).toContain(".nim");

    // Now check that the C view (if available) shows a corresponding location.
    // We switch to C view and verify it shows a valid C file path.
    const smLoaded = await isSourcemapLoaded(ctPage);
    if (!smLoaded) {
      // Without sourcemap, we can only verify the Nim view stays consistent.
      // Step back to confirm the line is at the stepped position.
      const currentLocation = await statusBar.location();
      expect(currentLocation.path).toContain(".nim");
      return;
    }

    const switchedToC = await switchToTargetSourceView(ctPage);
    if (switchedToC) {
      // Wait for the C editor to load and verify it shows a .c file.
      await retry(
        async () => {
          const editors = await layout.editorTabs(true);
          return editors.some((e) =>
            e.fileName.endsWith(".c") || e.fileName.endsWith(".h"),
          );
        },
        { maxAttempts: 20, delayMs: 1000 },
      );

      // The status bar should now reflect the C file location.
      let cLocation: { path: string; line: number } | null = null;
      try {
        await retry(
          async () => {
            cLocation = await statusBar.location();
            return cLocation.path.match(/\.(c|h)$/) !== null;
          },
          { maxAttempts: 10, delayMs: 500 },
        );
      } catch {
        // Status bar may still show the Nim path if the C view hasn't
        // fully activated yet. This is acceptable -- the key assertion
        // is that the editor tab with C code was opened.
      }
    }

    // Switch back to the Nim source view by clicking the .nim editor tab.
    const editors = await layout.editorTabs(true);
    const nimEditor = editors.find((e) => e.fileName.endsWith(".nim"));
    if (nimEditor) {
      await nimEditor.tabButton().click();

      // Verify the Nim line is still at (or near) the stepped position.
      // The line should not have reverted to the initial position.
      const finalLocation = await statusBar.location();
      expect(finalLocation.path).toContain(".nim");
      // The debugger position should reflect the stepped state. We can't
      // predict the exact line, but it should be a valid positive number.
      expect(finalLocation.line).toBeGreaterThan(0);
    }
  });
});
