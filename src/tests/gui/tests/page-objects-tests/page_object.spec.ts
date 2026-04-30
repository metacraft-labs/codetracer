import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout_page";
import { extractLayoutPageModel } from "../../page-objects/layout_extractors";

// Use the noir example just like the other tests.
test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });
test.setTimeout(90_000);

test("page object test", async ({ ctPage }) => {
  await readyOnEntry(ctPage);

  const layout = new LayoutPage(ctPage);

  // Access debug buttons
  await layout.runToEntryButton().isVisible();
  await layout.continueButton().isVisible();
  await layout.nextButton().isVisible();

  //await ctPage.waitForTimeout(4000);
  // Iterate over event log tabs
  const eventLogs = await layout.eventLogTabs();
  for (const tab of eventLogs) {
    await tab.isVisible();
    const events = await tab.eventElements();
    for (const e of events) {
      await e.consoleOutput();
    }
  }

  // Program state
  const stateTabs = await layout.programStateTabs();
  for (const tab of stateTabs) {
    const vars = await tab.programStateVariables();
    for (const v of vars) {
      await v.name();
      await v.valueType();
      await v.value();
    }
  }

  // Editors
  const editors = await layout.editorTabs();
  for (const ed of editors) {
    await ed.highlightedLineNumber();
    await ed.visibleTextRows();
  }

  // Run extractor as final step
  await extractLayoutPageModel(layout);
});

// FAILING: 2026-05-01 — `getRows()` returns 0 because the test calls
// it immediately after `readyOnEntry`, before the noir trace's event
// log has finished streaming. The matching `expected event count`
// test in noir_example.spec.ts shows the same DataTables footer
// reads 0 even after a 30s wait, which is a deeper bug in the
// DB-trace event-log population path (also documented there).
// TODO: either (a) use the existing `loadedEventLog(ctPage)` helper
// in place of `readyOnEntry` so the test waits for the row count to
// reach > 0, or (b) wait until the underlying DB-trace event-log
// loader is fixed so the row count actually grows. Option (a) is the
// lighter fix and will start producing meaningful failures once the
// loader is correct.
test("Event Log Rows", async ({ ctPage }) => {
  await readyOnEntry(ctPage);

  const layoutPage = new LayoutPage(ctPage);

  const eventLogTab = (await layoutPage.eventLogTabs())[0];
  const rows = await eventLogTab.getRows();

  expect(rows).toBeGreaterThanOrEqual(1);

});
