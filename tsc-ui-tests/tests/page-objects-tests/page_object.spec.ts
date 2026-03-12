import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout_page";
import { extractLayoutPageModel } from "../../page-objects/layout_extractors";

// Use the noir example just like the other tests.
test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

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

test("Event Log Rows", async ({ ctPage }) => {
  await readyOnEntry(ctPage);

  const layoutPage = new LayoutPage(ctPage);

  const eventLogTab = (await layoutPage.eventLogTabs())[0];
  const rows = await eventLogTab.getRows();

  expect(rows).toBeGreaterThanOrEqual(1);

});
