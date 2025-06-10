import { test, expect } from "@playwright/test";
import { page, readyOnEntryTest as readyOnEntry, ctRun } from "../lib/ct_helpers";
import { LayoutPage } from "../page_objects/layout_page";

// run the Ruby program located in programs/rb_checklist/data_types.rb
ctRun("rb_checklist/data_types.rb");

const TARGET_LINE = 33;
const EXPECTED_VARIABLE_COUNT = 9;

test("data_types.rb state variables", async () => {
  // wait until debugger is ready at entry point
  await readyOnEntry();

  const layout = new LayoutPage(page);

  // there should be one editor opened for data_types.rb
  const [editor] = await layout.editorTabs();
  // jump to the target line to populate state panel
  await editor.gotoLine(TARGET_LINE);

  const [stateTab] = await layout.programStateTabs();
  const vars = await stateTab.programStateVariables(true);
  expect(vars.length).toBe(EXPECTED_VARIABLE_COUNT);
});
