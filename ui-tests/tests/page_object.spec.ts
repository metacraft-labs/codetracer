import { test } from "@playwright/test";
import { page, readyOnEntryTest as readyOnEntry, ctRun } from "./lib/ct_helpers";
import { LayoutPage } from "./page_objects/layout_page";
import { extractLayoutPageModel } from "./page_objects/layout_extractors";

// Use the noir example just like the other tests.
ctRun("noir_example/");

test("page object test", async () => {
  await readyOnEntry();

  const layout = new LayoutPage(page);

  // Access debug buttons
  await layout.runToEntryButton().isVisible();
  await layout.continueButton().isVisible();
  await layout.nextButton().isVisible();

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

