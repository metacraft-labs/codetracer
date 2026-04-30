import type { Locator, Page } from "@playwright/test";
import { LayoutPage } from "../page-objects/layout-page";
import { retry } from "./retry-helpers";
import { debugLogger } from "./debug-logger";

/**
 * Click a golden-layout tab button, working around the "element is outside
 * of the viewport" issue that occurs on Windows when the Electron window is
 * maximized but some tab buttons are positioned beyond the visible viewport.
 *
 * Falls back to dispatchEvent('click') when a normal click fails.
 */
async function clickTabButton(btn: Locator): Promise<void> {
  try {
    await btn.click({ timeout: 5_000 });
  } catch {
    // When the element is outside the viewport (common on Windows where
    // the maximized Electron window may be clipped), dispatch a click
    // event directly via JavaScript which bypasses all viewport checks.
    await btn.dispatchEvent("click");
  }
}

/**
 * Wait for the backend to settle on its current position.
 *
 * The naive "wait until #stable-status has class `ready-status`" check
 * races against operation dispatch: after clicking a debug button the
 * `InternalNewOperation` event reaches the status component asynchronously,
 * so the status may still read "ready" for a few ms before flipping to
 * "busy". This helper first observes the status flip to "busy" (or a
 * short timeout if the operation completes too quickly) and then waits
 * for it to come back to "ready".
 */
async function waitForStableReady(
  page: Page,
  maxSeconds = 15,
): Promise<void> {
  const status = page.locator("#stable-status");

  // Best-effort wait for the busy transition. An operation that completes
  // in <100ms may never flip to busy; in that case we proceed straight
  // to the ready check.
  for (let i = 0; i < 20; i++) {
    const className = (await status.getAttribute("class")) ?? "";
    if (className.includes("busy-status")) break;
    if (className.includes("ready-status") && i >= 3) break;
    await page.waitForTimeout(50);
  }

  await retry(
    async () => {
      const className = (await status.getAttribute("class")) ?? "";
      return className.includes("ready-status");
    },
    { maxAttempts: maxSeconds, delayMs: 1000 },
  );
}

/**
 * Language-agnostic smoke test helpers that verify core CodeTracer UI
 * functionality against any traced program.
 *
 * Port of ui-tests/Tests/ProgramSpecific/LanguageSmokeTestHelpers.cs
 */

/**
 * Verify the editor loads the expected source file tab.
 * Uses a case-insensitive substring match to accommodate path prefixes.
 */
export async function assertEditorLoadsFile(
  page: Page,
  expectedFileName: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      return editors.some((e) =>
        e.tabButtonText.toLowerCase().includes(expectedFileName.toLowerCase()),
      );
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Verify the event log has at least one event entry.
 */
export async function assertEventLogPopulated(page: Page): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  const eventLog = (await layout.eventLogTabs())[0];
  await clickTabButton(eventLog.tabButton());

  await retry(
    async () => {
      const events = await eventLog.eventElements(true);
      return events.length > 0;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Navigate call trace to find a function by name, activate it, and verify
 * that the editor jumps to a tab whose name contains `expectedFile`.
 *
 * Uses `navigateToEntry` which first tries expanding visible entries, then
 * falls back to calltrace search to handle cases where the function is
 * buried under many stdlib calls (common in Python/Ruby traces).
 */
export async function assertCallTraceNavigation(
  page: Page,
  functionName: string,
  expectedFile: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  // Wait only for the calltrace component — not all base components.
  // Some traces (e.g. Python sudoku) have slow event-log loading which
  // would consume the entire test timeout if we waited for everything.
  await layout.waitForCallTraceLoaded();

  const callTrace = (await layout.callTraceTabs())[0];
  await clickTabButton(callTrace.tabButton());
  callTrace.invalidateEntries();

  const entry = await callTrace.navigateToEntry(functionName);
  await entry.activate();

  // After navigation the editor should show a tab containing the expected file name.
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      return editors.some((e) =>
        e.tabButtonText.toLowerCase().includes(expectedFile.toLowerCase()),
      );
    },
    { maxAttempts: 30, delayMs: 1000 },
  );
}

/**
 * Navigate to a function via the call trace and verify that a named variable
 * is visible in the Program State pane.
 *
 * When `stepForwardFirst` is true, clicks step-over once after activating
 * the call trace entry and waits for ready status.
 */
export async function assertVariableVisible(
  page: Page,
  functionName: string,
  variableName: string,
  stepForwardFirst = false,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  const callTrace = (await layout.callTraceTabs())[0];
  await clickTabButton(callTrace.tabButton());
  callTrace.invalidateEntries();

  const entry = await callTrace.navigateToEntry(functionName);
  await entry.activate();

  if (stepForwardFirst) {
    // Use the layered click helper — under Xvfb the jstree filesystem
    // panel can overlap the debug-toolbar and intercept the pointer
    // event, so we need the same fallback chain as CallTracePane.clickTab.
    await layout.clickNextButton();

    await retry(
      async () => {
        const status = page.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
  }

  // Open the state pane and look for the variable.
  const statePane = (await layout.programStateTabs())[0];
  await clickTabButton(statePane.tabButton());

  await retry(
    async () => {
      const variables = await statePane.programStateVariables(true);
      for (const variable of variables) {
        const name = await variable.name();
        if (name.toLowerCase() === variableName.toLowerCase()) {
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Verify that a named variable is visible, checking both flow value
 * annotations in the editor and the Program State pane.
 *
 * When `functionName` is supplied, the helper first navigates to that
 * call trace entry (mirroring `assertVariableVisible`). This is needed
 * for traces that start in a language-runtime entry trampoline (e.g.
 * Go's `runtime.rt0_go` chain) where the variables in scope at the
 * trace's initial position are runtime-internal and the user-program
 * variable only becomes visible after navigating into the user main.
 *
 * For RR traces that already start in user code (C, Rust) the default
 * (no `functionName`) is sufficient — the helper's step-over loop
 * reaches the variable's declaration line within `maxSteps`.
 */
export async function assertFlowValueVisible(
  page: Page,
  variableName: string,
  functionName?: string,
  maxSteps = 5,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  // Wait for the editor to appear.
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      return editors.length > 0;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );

  // If a user-main function name was supplied, navigate via the call
  // trace before searching for the variable. The function entry's
  // calltrace-jump moves the debugger into the function so the
  // step-over loop below operates from inside user code.
  if (functionName) {
    const callTrace = (await layout.callTraceTabs())[0];
    await clickTabButton(callTrace.tabButton());
    callTrace.invalidateEntries();

    const entry = await callTrace.navigateToEntry(functionName);
    await entry.activate();
    await waitForStableReady(page);
  }

  const flowSelector = `span[id*="-${variableName}"][class*="flow-parallel-value-box"]`;

  const statePane = (await layout.programStateTabs())[0];
  let statePaneOpened = false;
  let stepsPerformed = 0;

  await retry(
    async () => {
      // Check flow annotations first (cheap DOM query).
      const flowCount = await page.locator(flowSelector).count();
      if (flowCount > 0) {
        return true;
      }

      // Flow not ready yet — also check the state pane.
      if (!statePaneOpened) {
        await clickTabButton(statePane.tabButton());
        statePaneOpened = true;
      }

      const variables = await statePane.programStateVariables(true);
      for (const variable of variables) {
        const name = await variable.name();
        if (name.toLowerCase() === variableName.toLowerCase()) {
          return true;
        }
      }

      // Advance the debugger one step. We step OVER (next) so that we
      // walk through user code declarations one source line at a time
      // without descending into stdlib/runtime calls.
      //
      // Layered click helper — under Xvfb the jstree filesystem panel
      // can overlap the debug-toolbar and intercept the pointer event
      // ("jstree-icon ... intercepts pointer events"); without the
      // fallback every sudoku-variant flow-value test fails here.
      if (stepsPerformed < maxSteps) {
        await layout.clickNextButton();
        stepsPerformed++;

        await waitForStableReady(page);
      }

      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Verify that the terminal output pane contains the expected text.
 */
export async function assertTerminalOutputContains(
  page: Page,
  expectedText: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  const terminalTabs = await layout.terminalTabs();
  if (terminalTabs.length === 0) {
    throw new Error("No terminal output pane was found in the layout.");
  }

  const terminal = terminalTabs[0];
  await clickTabButton(terminal.tabButton());

  await retry(
    async () => {
      const lines = await terminal.lines(true);
      for (const line of lines) {
        const text = await line.text();
        if (text.toLowerCase().includes(expectedText.toLowerCase())) {
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Verify the event log contains at least one row whose text cell includes
 * the expected text.
 */
export async function assertEventLogContainsText(
  page: Page,
  expectedText: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  const eventLog = (await layout.eventLogTabs())[0];
  await clickTabButton(eventLog.tabButton());

  await retry(
    async () => {
      const events = await eventLog.eventElements(true);
      for (const ev of events) {
        const text = await ev.consoleOutput();
        if (text.toLowerCase().includes(expectedText.toLowerCase())) {
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}

/**
 * Navigate forward by clicking "continue", then verify the terminal output
 * pane contains the expected text.
 */
export async function assertTerminalOutputAfterContinue(
  page: Page,
  expectedText: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  // Use the layered click helper — see notes on assertFlowValueVisible
  // for why a plain click is not sufficient under Xvfb.
  await layout.clickContinueButton();

  // Wait for the backend to finish processing (status returns to "ready").
  await retry(
    async () => {
      const status = page.locator("#stable-status");
      const className = (await status.getAttribute("class")) ?? "";
      return className.includes("ready-status");
    },
    { maxAttempts: 120, delayMs: 1000 },
  );

  // Now check the terminal output.
  const terminalTabs = await layout.terminalTabs();
  if (terminalTabs.length === 0) {
    throw new Error("No terminal output pane was found in the layout.");
  }

  const terminal = terminalTabs[0];
  await clickTabButton(terminal.tabButton());

  await retry(
    async () => {
      const lines = await terminal.lines(true);
      for (const line of lines) {
        const text = await line.text();
        if (text.toLowerCase().includes(expectedText.toLowerCase())) {
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
}
