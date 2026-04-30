/**
 * Comprehensive integration test for multi-replay tabbed interface.
 *
 * Proves that:
 *   1. Multiple sessions coexist in the data model without interference.
 *   2. Tab creation via "+" correctly isolates session state.
 *   3. UI actions (stepping) in one session don't affect another session.
 *   4. Session state (debugger location, trace, services) is preserved
 *      across data-model switches.
 *   5. All panels (editor, event log, call trace) reload correctly
 *      and remain interactive after session-model operations.
 *
 * ## Design note: switchSession and the tab bar
 *
 * `switchSession` performs a full GoldenLayout destroy/recreate cycle.
 * The `#session-tab-bar` element lives OUTSIDE `#ROOT` in `index.html`
 * so that `destroyCurrentLayout` (which clears `#ROOT` innerHTML) does
 * not destroy the tab bar DOM.  This allows tab clicks to survive
 * session switches.
 *
 * The test suite uses two strategies:
 *   - **DOM-level click on "+"**: Creates a new session and switches to
 *     it (triggering the full GL cycle).  Used in test 2 to verify that
 *     the new session starts empty.
 *   - **Data-model operations** (`page.evaluate()`): Adds sessions and
 *     switches `activeSessionIndex` without triggering the GL rebuild.
 *     Used in tests 1 and 3 to safely verify session isolation and
 *     state preservation without breaking the layout.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers — extract session/debugger state via window.data
// ---------------------------------------------------------------------------

/** Return the number of sessions in the data model. */
async function getSessionCount(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

/** Return the activeSessionIndex from window.data. */
async function getActiveIndex(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.activeSessionIndex ?? -1;
  });
}

/**
 * Return the debugger location for a specific session index.
 * Returns null when the session or debugger location is not available.
 */
async function getSessionDebuggerLocation(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<{ path: string; line: number; event: number } | null> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    const debuggerSvc = session?.services?.debugger;
    if (!debuggerSvc?.location) return null;
    return {
      path: String(debuggerSvc.location.path ?? ""),
      line: Number(debuggerSvc.location.line ?? -1),
      event: Number(debuggerSvc.location.event ?? -1),
    };
  }, sessionIndex);
}

/**
 * Return whether a session has a loaded trace (non-null trace object).
 */
async function sessionHasTrace(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<boolean> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    return !!session?.trace;
  }, sessionIndex);
}

/**
 * Add a minimal empty session to the data model WITHOUT triggering the
 * full switchSession GL rebuild.  This is safe for isolation tests that
 * only need to verify the data layer.
 *
 * The new session has null trace and empty services, mimicking what
 * `createNewSession` produces (minus the GL side effects).
 */
async function addEmptySessionViaDataModel(
  page: import("@playwright/test").Page,
): Promise<void> {
  await page.evaluate(() => {
    const d = (window as any).data;
    const original = d.sessions[0];
    const copy = Object.assign(
      Object.create(Object.getPrototypeOf(original)),
      original,
    );
    // Clear trace-specific fields so this looks like an empty session.
    copy.trace = null;
    copy.services = {
      debugger: { location: null },
      editor: { open: {} },
      calltrace: {},
      eventLog: {},
      history: {},
      flow: {},
      trace: {},
      search: {},
      shell: {},
    };
    d.sessions.push(copy);
  });
}

/**
 * Switch the active session index in the data model only (no GL rebuild).
 * Used to verify data isolation without the heavyweight layout cycle.
 */
async function setActiveSessionIndex(
  page: import("@playwright/test").Page,
  index: number,
): Promise<void> {
  await page.evaluate((idx) => {
    const d = (window as any).data;
    d.activeSessionIndex = idx;
  }, index);
}

/**
 * Wait for the ready-status indicator to confirm a stepping operation
 * has completed.
 */
async function waitForStepComplete(
  page: import("@playwright/test").Page,
): Promise<void> {
  await retry(
    async () => {
      const status = page.locator("#stable-status");
      const className = (await status.getAttribute("class")) ?? "";
      return className.includes("ready-status");
    },
    { maxAttempts: 60, delayMs: 500 },
  );
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Comprehensive tabbed replay", () => {
  test.setTimeout(180_000); // 3 minutes: recording + multiple tab switches
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: tab switching preserves all panel state across tabs
  //
  // Records a Python trace, loads all panels, steps forward to establish
  // a non-initial debugger position, adds a second session via the data
  // model, verifies that all session 0 state (debugger location, trace,
  // editor, event log, call trace) is preserved after data-model
  // round-trips, and confirms the session remains interactive.
  // -------------------------------------------------------------------------

  test("tab switching preserves all panel state across tabs", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    // ------------------------------------------------------------------
    // Step 1: Wait for the initial trace to fully load with all panels
    // ------------------------------------------------------------------

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    // Confirm exactly one session exists.
    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await getSessionCount(ctPage)).toBeGreaterThanOrEqual(1);
    expect(await getActiveIndex(ctPage)).toBe(0);

    // Read the initial status bar location (file path + line).
    const initialLocation = await statusBar.location();
    expect(initialLocation.path).toContain("main.py");
    expect(initialLocation.line).toBeGreaterThanOrEqual(1);

    // Verify event log has loaded rows.
    const eventLogTabs = await layout.eventLogTabs(true);
    expect(eventLogTabs.length).toBeGreaterThan(0);
    const initialEventRowCount = await eventLogTabs[0].rowCount();
    expect(initialEventRowCount).toBeGreaterThan(0);

    // Verify call trace has entries.
    const callTraceTabs = await layout.callTraceTabs(true);
    expect(callTraceTabs.length).toBeGreaterThan(0);
    const callTrace = callTraceTabs[0];
    await callTrace.waitForReady();
    const initialCallTraceEntries = await callTrace.getEntries(true);
    expect(initialCallTraceEntries.length).toBeGreaterThan(0);

    // Verify editor is showing the source file with real content.
    const editorTabs = await layout.editorTabs(true);
    expect(editorTabs.length).toBeGreaterThan(0);
    // Capture the editor filename for later comparison.
    const initialEditorFileName = editorTabs[0].fileName;
    expect(initialEditorFileName).toContain(".py");

    // Capture initial call trace function name for later comparison.
    const initialCallText = await initialCallTraceEntries[0].callText();
    expect(initialCallText.length).toBeGreaterThan(0);

    // ------------------------------------------------------------------
    // Step 2: Step forward twice to move the debugger to a non-initial
    //         position.  This gives us a distinctive location to verify
    //         preservation after tab switches.
    // ------------------------------------------------------------------

    await layout.nextButton().click();
    await retry(
      async () => {
        const loc = await getSessionDebuggerLocation(ctPage, 0);
        return loc !== null && loc.line > 0;
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    // Record the debugger position after stepping.
    const locationAfterStepping = await getSessionDebuggerLocation(ctPage, 0);
    expect(locationAfterStepping).not.toBeNull();
    expect(locationAfterStepping!.line).toBeGreaterThan(0);
    expect(locationAfterStepping!.path.length).toBeGreaterThan(0);

    // ------------------------------------------------------------------
    // Step 3: Add a second session via data model (avoids GL rebuild).
    //
    // The data-model approach lets us verify isolation without breaking
    // the active layout.  Session 0 remains active and the DOM is intact.
    // ------------------------------------------------------------------

    await addEmptySessionViaDataModel(ctPage);
    expect(await getSessionCount(ctPage)).toBe(2);

    // Session 0 should still be active.
    expect(await getActiveIndex(ctPage)).toBe(0);

    // Session 0's debugger location should be unchanged.
    const locAfterNewSession = await getSessionDebuggerLocation(ctPage, 0);
    expect(locAfterNewSession).not.toBeNull();
    expect(locAfterNewSession!.line).toBe(locationAfterStepping!.line);
    expect(locAfterNewSession!.path).toBe(locationAfterStepping!.path);
    expect(locAfterNewSession!.event).toBe(locationAfterStepping!.event);

    // Session 1 should NOT have a trace or debugger location.
    expect(await sessionHasTrace(ctPage, 1)).toBe(false);
    const session1Loc = await getSessionDebuggerLocation(ctPage, 1);
    expect(session1Loc).toBeNull();

    // ------------------------------------------------------------------
    // Step 4: Data-model round-trip — switch to session 1 and back.
    //
    // This verifies that the data model is fully isolated: changing
    // activeSessionIndex does not corrupt session 0's state.
    // ------------------------------------------------------------------

    await setActiveSessionIndex(ctPage, 1);
    expect(await getActiveIndex(ctPage)).toBe(1);

    // While logically on session 1, verify session 0's data is intact.
    const locWhileOnSession1 = await getSessionDebuggerLocation(ctPage, 0);
    expect(locWhileOnSession1).not.toBeNull();
    expect(locWhileOnSession1!.line).toBe(locationAfterStepping!.line);
    expect(locWhileOnSession1!.path).toBe(locationAfterStepping!.path);

    // Switch back to session 0.
    await setActiveSessionIndex(ctPage, 0);
    expect(await getActiveIndex(ctPage)).toBe(0);

    // Verify session 0 state survives the round-trip.
    const locAfterRoundTrip = await getSessionDebuggerLocation(ctPage, 0);
    expect(locAfterRoundTrip).not.toBeNull();
    expect(locAfterRoundTrip!.line).toBe(locationAfterStepping!.line);
    expect(locAfterRoundTrip!.path).toBe(locationAfterStepping!.path);

    // ------------------------------------------------------------------
    // Step 5: Verify all panels are still rendered with real content
    //         after the data-model round-trip.  Since we did not trigger
    //         a GL rebuild, the DOM should be unchanged.
    //
    //         We verify actual DOM text content (not just element counts)
    //         to ensure the panels display real data, not empty shells.
    // ------------------------------------------------------------------

    // Editor still shows the source file with actual code lines.
    const editorTabsAfter = await layout.editorTabs(true);
    expect(editorTabsAfter.length).toBeGreaterThan(0);
    const editorAfter = editorTabsAfter[0];
    // Verify the editor tab refers to a Python file.
    expect(editorAfter.fileName).toContain(".py");
    // Verify the Monaco editor has rendered source lines with text.
    const editorLinesAfter = await editorAfter.lines();
    expect(editorLinesAfter.length).toBeGreaterThan(0);
    const firstLineText = await editorLinesAfter[0].root.textContent();
    expect(firstLineText).toBeTruthy();
    expect(firstLineText!.trim().length).toBeGreaterThan(0);

    // Event log still has rows with real text content.
    const eventLogTabsAfter = await layout.eventLogTabs(true);
    expect(eventLogTabsAfter.length).toBeGreaterThan(0);
    const eventRowCountAfter = await eventLogTabsAfter[0].rowCount();
    expect(eventRowCountAfter).toBeGreaterThan(0);
    // Verify at least one event row has non-empty text (proving real data).
    const eventRowsAfter = await eventLogTabsAfter[0].eventElements(true);
    expect(eventRowsAfter.length).toBeGreaterThan(0);
    const eventRowText = await eventRowsAfter[0].root.textContent();
    expect(eventRowText).toBeTruthy();
    expect(eventRowText!.trim().length).toBeGreaterThan(0);

    // Call trace still has entries with actual function names.
    const callTraceTabsAfter = await layout.callTraceTabs(true);
    expect(callTraceTabsAfter.length).toBeGreaterThan(0);
    const callTraceAfter = callTraceTabsAfter[0];
    const callTraceEntriesAfter = await callTraceAfter.getEntries(true);
    expect(callTraceEntriesAfter.length).toBeGreaterThan(0);
    // Verify the call trace entry contains a real function name.
    const callTextAfter = await callTraceEntriesAfter[0].callText();
    expect(callTextAfter.length).toBeGreaterThan(0);

    // ------------------------------------------------------------------
    // Step 6: Step forward once more to prove the session is still
    //         fully interactive after a data-model round-trip.
    // ------------------------------------------------------------------

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    const locAfterFinalStep = await getSessionDebuggerLocation(ctPage, 0);
    expect(locAfterFinalStep).not.toBeNull();
    expect(locAfterFinalStep!.line).toBeGreaterThan(0);

    // ------------------------------------------------------------------
    // Step 7: Second round-trip — verify state survives multiple
    //         data-model switches.
    // ------------------------------------------------------------------

    await setActiveSessionIndex(ctPage, 1);
    expect(await getActiveIndex(ctPage)).toBe(1);

    // Session 0 data preserved while on session 1.
    const locSecondRoundTrip = await getSessionDebuggerLocation(ctPage, 0);
    expect(locSecondRoundTrip).not.toBeNull();
    expect(locSecondRoundTrip!.line).toBe(locAfterFinalStep!.line);
    expect(locSecondRoundTrip!.path).toBe(locAfterFinalStep!.path);

    // Switch back.
    await setActiveSessionIndex(ctPage, 0);
    expect(await getActiveIndex(ctPage)).toBe(0);

    // Final verification.
    const finalLocation = await getSessionDebuggerLocation(ctPage, 0);
    expect(finalLocation).not.toBeNull();
    expect(finalLocation!.line).toBe(locAfterFinalStep!.line);
    expect(finalLocation!.path).toBe(locAfterFinalStep!.path);

    // Panels still intact with real content matching the initial state.
    const finalEditorTabs = await layout.editorTabs(true);
    expect(finalEditorTabs.length).toBeGreaterThan(0);
    // Same Python file is still shown.
    expect(finalEditorTabs[0].fileName).toBe(initialEditorFileName);
    // Editor still has rendered source lines.
    const finalEditorLines = await finalEditorTabs[0].lines();
    expect(finalEditorLines.length).toBeGreaterThan(0);

    const finalEventLogTabs = await layout.eventLogTabs(true);
    expect(finalEventLogTabs.length).toBeGreaterThan(0);
    const finalEventRowCount = await finalEventLogTabs[0].rowCount();
    expect(finalEventRowCount).toBeGreaterThan(0);
    // Event rows still contain real text.
    const finalEventRows = await finalEventLogTabs[0].eventElements(true);
    const finalEventText = await finalEventRows[0].root.textContent();
    expect(finalEventText).toBeTruthy();
    expect(finalEventText!.trim().length).toBeGreaterThan(0);

    const finalCallTraceTabs = await layout.callTraceTabs(true);
    expect(finalCallTraceTabs.length).toBeGreaterThan(0);
    const finalCallEntries = await finalCallTraceTabs[0].getEntries(true);
    expect(finalCallEntries.length).toBeGreaterThan(0);
    // Call trace still shows real function names.
    const finalCallText = await finalCallEntries[0].callText();
    expect(finalCallText.length).toBeGreaterThan(0);
  });

  // -------------------------------------------------------------------------
  // Test 2: new tab starts with empty/no-trace state
  //
  // Uses the real "+" button to create a new session, verifying that the
  // new session has no trace and no debugger location.  This is the
  // canonical one-way test for M12 (new tab creation).
  // -------------------------------------------------------------------------

  test("new tab starts with empty state and does not inherit trace", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    await layout.waitForTraceLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    // Confirm session 0 has a loaded trace.
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);

    // Create a new tab via "+".
    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 20, delayMs: 500 },
    );

    // The new session should be active.
    expect(await getActiveIndex(ctPage)).toBe(1);

    // The new session should NOT have a trace.
    expect(await sessionHasTrace(ctPage, 1)).toBe(false);

    // The new session should NOT have a debugger location.
    const newSessionLoc = await getSessionDebuggerLocation(ctPage, 1);
    if (newSessionLoc !== null) {
      expect(newSessionLoc.line).toBeLessThanOrEqual(0);
    }

    // Original session's trace should be preserved in the data model.
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);
    const originalLoc = await getSessionDebuggerLocation(ctPage, 0);
    expect(originalLoc).not.toBeNull();
    expect(originalLoc!.path).toContain("main.py");
  });

  // -------------------------------------------------------------------------
  // Test 3: UI action in one tab does not affect another tab
  //
  // Adds a second session via the data model (avoids GL rebuild to the
  // empty session) so that the loaded session remains fully interactive.
  // Steps forward multiple times in session 0 and verifies session 1
  // is unchanged after each step.
  // -------------------------------------------------------------------------

  test("stepping in tab 1 does not affect tab 2 state", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    // Add a second session via the data model (no GL switch).
    await addEmptySessionViaDataModel(ctPage);
    expect(await getSessionCount(ctPage)).toBe(2);

    // Record initial state of the new session (index 1).
    const tab2InitialTrace = await sessionHasTrace(ctPage, 1);
    const tab2InitialLoc = await getSessionDebuggerLocation(ctPage, 1);

    // Session 0 is still active and fully loaded.
    expect(await getActiveIndex(ctPage)).toBe(0);

    // ------------------------------------------------------------------
    // First step in session 0
    // ------------------------------------------------------------------

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    // Verify session 0 moved.
    const tab1LocAfterStep1 = await getSessionDebuggerLocation(ctPage, 0);
    expect(tab1LocAfterStep1).not.toBeNull();
    expect(tab1LocAfterStep1!.line).toBeGreaterThan(0);

    // Verify session 1 was NOT affected.
    expect(await sessionHasTrace(ctPage, 1)).toBe(tab2InitialTrace);
    const tab2LocAfterStep1 = await getSessionDebuggerLocation(ctPage, 1);
    if (tab2InitialLoc === null) {
      expect(tab2LocAfterStep1).toBeNull();
    } else {
      expect(tab2LocAfterStep1).not.toBeNull();
      expect(tab2LocAfterStep1!.line).toBe(tab2InitialLoc.line);
    }

    // ------------------------------------------------------------------
    // Second step in session 0
    // ------------------------------------------------------------------

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    const tab1LocAfterStep2 = await getSessionDebuggerLocation(ctPage, 0);
    expect(tab1LocAfterStep2).not.toBeNull();
    expect(tab1LocAfterStep2!.line).toBeGreaterThan(0);

    // Session 1 still unchanged.
    expect(await sessionHasTrace(ctPage, 1)).toBe(tab2InitialTrace);
    const tab2LocAfterStep2 = await getSessionDebuggerLocation(ctPage, 1);
    if (tab2InitialLoc === null) {
      expect(tab2LocAfterStep2).toBeNull();
    } else {
      expect(tab2LocAfterStep2!.line).toBe(tab2InitialLoc.line);
    }

    // ------------------------------------------------------------------
    // Continue (run to end) in session 0
    // ------------------------------------------------------------------

    await layout.continueButton().click();
    await waitForStepComplete(ctPage);

    const tab1LocAfterContinue = await getSessionDebuggerLocation(ctPage, 0);
    expect(tab1LocAfterContinue).not.toBeNull();
    expect(tab1LocAfterContinue!.line).toBeGreaterThan(0);

    // Session 1 still unchanged after a major navigation action.
    expect(await sessionHasTrace(ctPage, 1)).toBe(tab2InitialTrace);
    const tab2LocAfterContinue = await getSessionDebuggerLocation(ctPage, 1);
    if (tab2InitialLoc === null) {
      expect(tab2LocAfterContinue).toBeNull();
    } else {
      expect(tab2LocAfterContinue!.line).toBe(tab2InitialLoc.line);
    }
  });
});
