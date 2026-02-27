import type { Page } from "@playwright/test";
import { LayoutPage } from "../page-objects/layout-page";
import { retry } from "./retry-helpers";
import { debugLogger } from "./debug-logger";

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
  await eventLog.tabButton().click();

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
 */
export async function assertCallTraceNavigation(
  page: Page,
  functionName: string,
  expectedFile: string,
): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();

  const callTrace = (await layout.callTraceTabs())[0];
  await callTrace.tabButton().click();
  callTrace.invalidateEntries();

  let targetFound = false;

  await retry(
    async () => {
      callTrace.invalidateEntries();
      const target = await callTrace.findEntry(functionName, true);
      if (target !== null) {
        await target.activate();
        targetFound = true;
        return true;
      }

      // Expand all visible entries to reveal nested functions.
      const allEntries = await callTrace.getEntries(true);
      for (const entry of allEntries) {
        try {
          await entry.expandChildren();
        } catch {
          // Entry may be scrolled out of the virtualized viewport
        }
      }

      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );

  if (!targetFound) {
    throw new Error(
      `Call trace entry '${functionName}' was not found after expanding all visible entries.`,
    );
  }

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
  await callTrace.tabButton().click();
  callTrace.invalidateEntries();

  let targetFound = false;

  await retry(
    async () => {
      callTrace.invalidateEntries();
      const target = await callTrace.findEntry(functionName, true);
      if (target !== null) {
        await target.activate();
        targetFound = true;
        return true;
      }

      const allEntries = await callTrace.getEntries(true);
      for (const entry of allEntries) {
        try {
          await entry.expandChildren();
        } catch {
          // Entry may be scrolled out of the virtualized viewport
        }
      }

      return false;
    },
    { maxAttempts: 60, delayMs: 1000 },
  );

  if (!targetFound) {
    throw new Error(
      `Call trace entry '${functionName}' was not found when trying to inspect variable '${variableName}'.`,
    );
  }

  if (stepForwardFirst) {
    const stepOverBtn = page.locator("#next-debug");
    await stepOverBtn.click();

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
  await statePane.tabButton().click();

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
 */
export async function assertFlowValueVisible(
  page: Page,
  variableName: string,
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
        await statePane.tabButton().click();
        statePaneOpened = true;
      }

      const variables = await statePane.programStateVariables(true);
      for (const variable of variables) {
        const name = await variable.name();
        if (name.toLowerCase() === variableName.toLowerCase()) {
          return true;
        }
      }

      // Step over once to advance past variable initialization.
      if (stepsPerformed < maxSteps) {
        const stepOverBtn = page.locator("#next-debug");
        await stepOverBtn.click();
        stepsPerformed++;

        await retry(
          async () => {
            const status = page.locator("#stable-status");
            const className = (await status.getAttribute("class")) ?? "";
            return className.includes("ready-status");
          },
          { maxAttempts: 30, delayMs: 1000 },
        );
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
  await terminal.tabButton().click();

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
  await eventLog.tabButton().click();

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

  const continueBtn = page.locator("#continue-debug");
  await continueBtn.click();

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
  await terminal.tabButton().click();

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
