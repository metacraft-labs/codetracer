/**
 * Real tab switching test with GL destroy/recreate cycle.
 *
 * This test proves that clicking actual tab DOM elements (not just
 * data-model manipulation) correctly switches sessions, destroys and
 * recreates GoldenLayout, and restores all panel content.
 *
 * The sequence:
 *   1. Load a Python trace, wait for all panels.
 *   2. Record panel content (editor filename, event log text, call trace
 *      text, debugger line number).
 *   3. Step forward to establish a non-initial position.
 *   4. Click "+" to create a new empty tab (GL rebuild #1).
 *   5. Verify we are on the new empty tab (session 1).
 *   6. Click the FIRST tab (session 0) — this triggers switchSession
 *      with GL destroy/recreate.
 *   7. Wait for GL to rebuild.
 *   8. Verify ALL panel content matches what we recorded in step 2/3.
 *
 * ## Known issues found by this test
 *
 * 1. After `createNewSession -> switchSession` for the empty session,
 *    `data.ui.layout` is null — GoldenLayout was NOT rebuilt for the
 *    empty session. The `initLayout` call in `restoreSessionLayout`
 *    either fails silently or the conditions are not met.
 *
 * 2. Clicking a tab to switch sessions causes a JS error:
 *    `Cannot set properties of null (setting 'active')`.
 *    This prevents `switchSession` from completing, leaving the UI
 *    in a broken state where the active session index does not change
 *    and the original session's panels are not restored.
 *
 * The tab bar DOM DOES correctly render 2 tabs (karax re-renders
 * properly). The issue is in the switchSession/restoreSessionLayout
 * flow when handling transitions involving empty (no-trace) sessions.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { StatusBar } from "../../page-objects/status_bar";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getActiveIndex(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.activeSessionIndex ?? -1;
  });
}

async function getSessionCount(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

async function waitForStepComplete(page: import("@playwright/test").Page): Promise<void> {
  await retry(
    async () => {
      const status = page.locator("#stable-status");
      const className = (await status.getAttribute("class")) ?? "";
      return className.includes("ready-status");
    },
    { maxAttempts: 60, delayMs: 500 },
  );
}

/**
 * Wait for the editor component to have a non-empty data-label attribute
 * (the filename). The attribute is set asynchronously after the backend
 * sends the initial CtCompleteMove, so it may lag behind component visibility.
 */
async function waitForEditorFileName(
  page: import("@playwright/test").Page,
): Promise<string> {
  let fileName = "";
  await retry(
    async () => {
      const label = await page
        .locator("div[id^='editorComponent']")
        .first()
        .getAttribute("data-label");
      if (label && label.length > 0) {
        const segments = label.split("/").filter(Boolean);
        fileName = segments[segments.length - 1] ?? "";
        return fileName.length > 0;
      }
      return false;
    },
    { maxAttempts: 30, delayMs: 500 },
  );
  return fileName;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Real tab switching with GL rebuild", () => {
  test.setTimeout(180_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("click tab to switch — panels show correct content after GL rebuild", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    // ==================================================================
    // 1. Wait for trace to fully load with all panels
    // ==================================================================

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await getActiveIndex(ctPage)).toBe(0);

    // ==================================================================
    // 2. Record initial panel content
    // ==================================================================

    // Editor filename — wait for the data-label attribute to be populated
    const initialEditorFileName = await waitForEditorFileName(ctPage);
    expect(initialEditorFileName).toContain(".py");

    // Editor has real source lines
    const editorTabs = await layout.editorTabs(true);
    expect(editorTabs.length).toBeGreaterThan(0);
    const editorLines = await editorTabs[0].lines();
    expect(editorLines.length).toBeGreaterThan(0);

    // Event log: get first row text
    const eventLogTabs = await layout.eventLogTabs(true);
    expect(eventLogTabs.length).toBeGreaterThan(0);
    const initialEventRowCount = await eventLogTabs[0].rowCount();
    expect(initialEventRowCount).toBeGreaterThan(0);
    const initialEventRows = await eventLogTabs[0].eventElements(true);
    expect(initialEventRows.length).toBeGreaterThan(0);
    const initialEventText = (await initialEventRows[0].root.textContent())?.trim() ?? "";
    expect(initialEventText.length).toBeGreaterThan(0);

    // Call trace: get first entry text
    const callTraceTabs = await layout.callTraceTabs(true);
    expect(callTraceTabs.length).toBeGreaterThan(0);
    await callTraceTabs[0].waitForReady();
    const initialCallEntries = await callTraceTabs[0].getEntries(true);
    expect(initialCallEntries.length).toBeGreaterThan(0);
    const initialCallText = await initialCallEntries[0].callText();
    expect(initialCallText.length).toBeGreaterThan(0);

    // Status bar: file path and line number
    const initialLocation = await statusBar.location();
    expect(initialLocation.path).toContain("main.py");
    expect(initialLocation.line).toBeGreaterThanOrEqual(1);

    // ==================================================================
    // 3. Step forward to establish a non-initial position
    // ==================================================================

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    await layout.nextButton().click();
    await waitForStepComplete(ctPage);

    // Record post-step location
    const steppedLocation = await statusBar.location();
    expect(steppedLocation.line).toBeGreaterThan(0);
    const steppedLine = steppedLocation.line;

    // ==================================================================
    // 4. Click "+" to create a new tab (triggers switchSession to
    //    session 1 with GL rebuild)
    // ==================================================================

    // Capture console logs during create+switch via page.on('console')
    const allSessionLogs: string[] = [];
    ctPage.on("console", (msg) => {
      const text = msg.text();
      if (text.includes("session_switch") || text.includes("switchSession") ||
          text.includes("restoreSession") || text.includes("initLayout") ||
          text.includes("createNewSession") || text.includes("destroyCurrentLayout")) {
        allSessionLogs.push(text);
      }
    });

    await ctPage.locator(".session-tab-add").click();

    // Wait for session count to become 2 in the data model
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 30, delayMs: 500 },
    );

    // ==================================================================
    // 5. Verify we are on session 1 (the new empty tab)
    // ==================================================================

    await retry(
      async () => (await getActiveIndex(ctPage)) === 1,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(1);

    // Verify the tab bar DOM shows 2 tabs (this proves karax re-rendered)
    await retry(
      async () => {
        const count = await ctPage.locator(".session-tab").count();
        return count >= 2;
      },
      { maxAttempts: 20, delayMs: 500 },
    );

    // Print captured console logs from createNewSession
    console.log("  Session logs after create:", JSON.stringify(allSessionLogs, null, 2));

    // Diagnostic: check if GL was created for the empty session.
    // This is the first sign of trouble — if layoutNil is true, the
    // subsequent switchSession back to session 0 will fail.
    const layoutNilAfterCreate = await ctPage.evaluate(() => {
      const d = (window as any).data;
      return d?.ui?.layout == null;
    });
    if (layoutNilAfterCreate) {
      console.log(
        "  [BUG] data.ui.layout is null after createNewSession — " +
        "GoldenLayout was not rebuilt for the empty session. " +
        "Switching back to session 0 will likely fail with a JS error.",
      );
    }

    // ==================================================================
    // 6. Click the FIRST tab (session 0) to switch back (GL rebuild #2)
    // ==================================================================

    // Collect JS errors during the switch
    const errorsBeforeSwitch = await ctPage.evaluate(() => {
      (window as any).__tabSwitchErrors = [];
      window.addEventListener("error", (e: ErrorEvent) => {
        (window as any).__tabSwitchErrors.push(e.message);
      });
      return true;
    });

    // Check tab bar DOM state before clicking
    const tabBarDiag = await ctPage.evaluate(() => {
      const bar = document.getElementById("session-tab-bar");
      const tabs = document.querySelectorAll(".session-tab");
      return {
        barExists: bar !== null,
        barInnerHTML: bar?.innerHTML?.substring(0, 200) ?? "",
        tabCount: tabs.length,
        tabClasses: Array.from(tabs).map(t => t.className),
      };
    });
    console.log("  Tab bar state before click:", JSON.stringify(tabBarDiag, null, 2));

    // Click the first tab — no JS fallback. If the click does not
    // switch sessions, the test fails (proving a real tab bar bug).
    const tabsForSwitch = ctPage.locator(".session-tab");
    expect(await tabsForSwitch.count()).toBeGreaterThan(0);
    await tabsForSwitch.first().click();
    await ctPage.waitForTimeout(500);

    // ==================================================================
    // 7. Wait for GL to rebuild and session 0 to become active
    // ==================================================================

    // Allow time for the switch to complete (or fail)
    await ctPage.waitForTimeout(3000);

    const activeAfterSwitch = await getActiveIndex(ctPage);
    const switchErrors = await ctPage.evaluate(() =>
      (window as any).__tabSwitchErrors ?? [],
    );
    // Print all session-related console logs (collected from page.on)
    console.log("  All session logs:", JSON.stringify(allSessionLogs, null, 2));

    if (activeAfterSwitch !== 0) {
      // The switch did NOT complete — this is the known bug.
      // Report all the diagnostic information.
      const diagState = await ctPage.evaluate(() => {
        const d = (window as any).data;
        return {
          sessionCount: d?.sessions?.length ?? 0,
          activeIndex: d?.activeSessionIndex ?? -1,
          layoutNil: d?.ui?.layout == null,
        };
      });

      const errorMsg = [
        "switchSession from session 1 to session 0 FAILED.",
        `  activeSessionIndex after switch: ${diagState.activeIndex} (expected 0)`,
        `  data.ui.layout is null: ${diagState.layoutNil}`,
        `  JS errors during switch: ${JSON.stringify(switchErrors)}`,
        `  All session logs: ${JSON.stringify(allSessionLogs, null, 2)}`,
        "",
        "Root cause: After createNewSession creates an empty session and switches to it,",
        "data.ui.layout remains null (GoldenLayout was not rebuilt for the empty session).",
        "When clicking a tab to switch back to session 0, switchSession crashes with:",
        "  'Cannot set properties of null (setting \\'active\\')'",
        "",
        "This is a bug in the switchSession/restoreSessionLayout flow —",
        "it does not handle the case where the current session has no GL instance.",
      ].join("\n");

      // Fail with a detailed message describing the bug
      expect(activeAfterSwitch, errorMsg).toBe(0);
    }

    // If we get here, the switch succeeded — verify panel content
    expect(activeAfterSwitch).toBe(0);

    // Wait for all components to re-render after GL rebuild
    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    // ==================================================================
    // 8. Verify ALL panel content matches what we recorded
    // ==================================================================

    // --- Editor: same filename ---
    const restoredEditorFileName = await waitForEditorFileName(ctPage);
    expect(restoredEditorFileName).toBe(initialEditorFileName);

    // Editor has real rendered source lines
    const editorTabsAfter = await layout.editorTabs(true);
    expect(editorTabsAfter.length).toBeGreaterThan(0);
    const editorLinesAfter = await editorTabsAfter[0].lines();
    expect(editorLinesAfter.length).toBeGreaterThan(0);
    const firstLineText = await editorLinesAfter[0].root.textContent();
    expect(firstLineText).toBeTruthy();
    expect(firstLineText!.trim().length).toBeGreaterThan(0);

    // --- Event log: same row count and first row text ---
    const eventLogTabsAfter = await layout.eventLogTabs(true);
    expect(eventLogTabsAfter.length).toBeGreaterThan(0);
    const eventRowCountAfter = await eventLogTabsAfter[0].rowCount();
    expect(eventRowCountAfter).toBeGreaterThan(0);
    expect(eventRowCountAfter).toBe(initialEventRowCount);

    const eventRowsAfter = await eventLogTabsAfter[0].eventElements(true);
    expect(eventRowsAfter.length).toBeGreaterThan(0);
    const eventTextAfter = (await eventRowsAfter[0].root.textContent())?.trim() ?? "";
    expect(eventTextAfter.length).toBeGreaterThan(0);
    expect(eventTextAfter).toBe(initialEventText);

    // --- Call trace: same first entry text ---
    const callTraceTabsAfter = await layout.callTraceTabs(true);
    expect(callTraceTabsAfter.length).toBeGreaterThan(0);
    await callTraceTabsAfter[0].waitForReady();
    const callEntriesAfter = await callTraceTabsAfter[0].getEntries(true);
    expect(callEntriesAfter.length).toBeGreaterThan(0);
    const callTextAfter = await callEntriesAfter[0].callText();
    expect(callTextAfter.length).toBeGreaterThan(0);
    expect(callTextAfter).toBe(initialCallText);

    // --- Status bar: line number preserved from stepped position ---
    let finalLine = -1;
    await retry(
      async () => {
        const loc = await statusBar.location();
        finalLine = loc.line;
        return loc.path.includes("main.py") && loc.line > 0;
      },
      { maxAttempts: 30, delayMs: 500 },
    );
    expect(finalLine).toBe(steppedLine);
  });
});
