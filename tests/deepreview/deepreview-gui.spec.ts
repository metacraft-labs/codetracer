/**
 * E2E tests for the DeepReview GUI (M3: Local .dr file loading).
 *
 * These tests verify that the ``--deepreview <path>`` CLI argument correctly
 * loads a DeepReview JSON export file and renders it in the CodeTracer GUI.
 *
 * The test plan is documented in:
 *   src/frontend/tests/deepreview_test_plan.nim
 *
 * The tests launch CodeTracer in DeepReview mode using a JSON fixture and
 * interact with the standalone review view that displays coverage, inline
 * variable values, function execution sliders, loop iteration sliders,
 * and a call trace tree.
 *
 * Prerequisites:
 *   - A working ``ct`` Electron build (set CODETRACER_E2E_CT_PATH or use
 *     the default dev build path).
 *   - The JSON fixture files in ``tests/deepreview/fixtures/``.
 */

import { test, expect, wait } from "../../lib/fixtures";
import * as path from "node:path";
import * as fs from "node:fs";

import { DeepReviewPage } from "./page-objects/deepreview-page";

// ---------------------------------------------------------------------------
// Fixture paths
// ---------------------------------------------------------------------------

const fixturesDir = path.join(__dirname, "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const emptyReviewPath = path.join(fixturesDir, "empty-review.json");
const noCalltracePath = path.join(fixturesDir, "no-calltrace-review.json");

// ---------------------------------------------------------------------------
// Skip guard: the fixtures must exist for the tests to be meaningful.
// ---------------------------------------------------------------------------

const fixturesExist =
  fs.existsSync(sampleReviewPath) &&
  fs.existsSync(emptyReviewPath) &&
  fs.existsSync(noCalltracePath);

// Note: expected values in assertions below are derived from the fixture
// data in sample-review.json. If the fixture changes, update the assertions.

// ---------------------------------------------------------------------------
// Test suite: main DeepReview features (uses sample-review.json)
// ---------------------------------------------------------------------------

test.describe("DeepReview GUI - main features", () => {
  // Skip the entire suite if fixtures are missing (e.g. in a checkout
  // that hasn't pulled the test data yet).
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // Launch CodeTracer in DeepReview mode for each test in this suite.
  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  // -----------------------------------------------------------------------
  // Test 1: CLI argument parsing
  // -----------------------------------------------------------------------

  test("Test 1: CLI argument parsing - deepreview container renders", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    await expect(dr.container()).toBeVisible();
    await expect(dr.errorMessage()).toBeHidden();

    const commitText = await dr.commitDisplay().textContent();
    expect(commitText).toBeTruthy();
    expect(commitText).toContain("a1b2c3d4e5f6...");

    const statsText = await dr.statsDisplay().textContent();
    expect(statsText).toContain("3 files");
    expect(statsText).toContain("2 recordings");
    expect(statsText).toContain("1542ms");
  });

  // -----------------------------------------------------------------------
  // Test 2: File list sidebar rendering
  // -----------------------------------------------------------------------

  test("Test 2: file list sidebar shows all files with correct basenames", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();
    expect(items.length).toBe(3);

    const expectedBasenames = ["main.rs", "utils.rs", "config.rs"];
    for (let i = 0; i < expectedBasenames.length; i++) {
      const name = await items[i].name();
      expect(name).toBe(expectedBasenames[i]);
    }

    const firstSelected = await items[0].isSelected();
    expect(firstSelected).toBe(true);

    const secondSelected = await items[1].isSelected();
    expect(secondSelected).toBe(false);
    const thirdSelected = await items[2].isSelected();
    expect(thirdSelected).toBe(false);
  });

  // -----------------------------------------------------------------------
  // Test 2b: Diff status indicators on file list items
  // -----------------------------------------------------------------------

  test("Test 2b: file list items show diff status indicators with correct labels", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();
    expect(items.length).toBe(3);

    // src/main.rs is Modified ("M")
    const mainStatus = await items[0].diffStatus();
    expect(mainStatus).toBe("M");

    // src/utils.rs is Added ("A")
    const utilsStatus = await items[1].diffStatus();
    expect(utilsStatus).toBe("A");

    // src/config.rs is Deleted ("D")
    const configStatus = await items[2].diffStatus();
    expect(configStatus).toBe("D");
  });

  // -----------------------------------------------------------------------
  // Test 2c: Diff status styling (colour classes)
  // -----------------------------------------------------------------------

  test("Test 2c: diff status indicators have correct colour classes", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();

    // VCS panel uses vcs-status-* classes instead of deepreview-diff-* classes.
    const mainClasses = await items[0].diffStatusClasses();
    expect(mainClasses).toContain("vcs-status-modified");

    const utilsClasses = await items[1].diffStatusClasses();
    expect(utilsClasses).toContain("vcs-status-added");

    const configClasses = await items[2].diffStatusClasses();
    expect(configClasses).toContain("vcs-status-deleted");
  });

  // -----------------------------------------------------------------------
  // Test 2d: Modified line counts
  // -----------------------------------------------------------------------

  test("Test 2d: file list items show added/removed line counts", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();

    // src/main.rs: +8 / -3
    const mainLines = await items[0].diffLines();
    expect(mainLines).toContain("+8");
    expect(mainLines).toContain("-3");

    // src/utils.rs: +8 / -0 (UI omits zero counts)
    const utilsLines = await items[1].diffLines();
    expect(utilsLines).toContain("+8");
    expect(utilsLines).not.toContain("-");

    // src/config.rs: +0 / -7 (UI omits zero counts)
    const configLines = await items[2].diffLines();
    expect(configLines).not.toContain("+");
    expect(configLines).toContain("-7");
  });

  // -----------------------------------------------------------------------
  // Test 3: Coverage highlighting
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (Monaco editor) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 3: coverage decorations are applied to the editor", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(2000);

    const executedCount = await dr.executedLines().count();
    expect(executedCount).toBeGreaterThan(0);

    const unreachableCount = await dr.unreachableLines().count();
    expect(unreachableCount).toBeGreaterThan(0);

    const partialCount = await dr.partialLines().count();
    expect(partialCount).toBeGreaterThan(0);
  });

  // -----------------------------------------------------------------------
  // Test 4: Inline variable values
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (Monaco editor) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 4: inline variable values appear as decorations", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(2000);

    const inlineCount = await dr.inlineValues().count();
    expect(inlineCount).toBeGreaterThan(0);

    const normalize = (s: string) => s.replace(/\u00a0/g, " ");

    const allInlineTexts: string[] = [];
    const inlineLocators = await dr.inlineValues().all();
    for (const loc of inlineLocators) {
      const text = await loc.textContent();
      if (text) allInlineTexts.push(normalize(text));
    }
    const combined = allInlineTexts.join(" | ");
    const hasKnownVar =
      combined.includes("x =") ||
      combined.includes("y =") ||
      combined.includes("result =");
    expect(hasKnownVar).toBe(true);
  });

  // -----------------------------------------------------------------------
  // Test 5: File switching
  // -----------------------------------------------------------------------

  test("Test 5: clicking a file in the VCS panel updates selection", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const firstItem = dr.fileItemByIndex(0);
    expect(await firstItem.isSelected()).toBe(true);

    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();

    await wait(500);

    expect(await secondItem.isSelected()).toBe(true);
    expect(await firstItem.isSelected()).toBe(false);

    await firstItem.click();
    await wait(500);
    expect(await firstItem.isSelected()).toBe(true);
  });

  // -----------------------------------------------------------------------
  // Test 6: Execution slider
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (execution slider) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 6: execution slider navigates between function executions", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    await expect(dr.executionSlider()).toBeVisible();

    const initialInfo = await dr.executionSliderInfo().textContent();
    expect(initialInfo).toBeTruthy();
    expect(initialInfo).toContain("1/3");
    expect(initialInfo).toContain("main");

    await dr.setExecutionSliderValue(1);
    await wait(500);

    const secondInfo = await dr.executionSliderInfo().textContent();
    expect(secondInfo).toContain("2/3");
    expect(secondInfo).toContain("main");

    await dr.setExecutionSliderValue(2);
    await wait(500);

    const thirdInfo = await dr.executionSliderInfo().textContent();
    expect(thirdInfo).toContain("3/3");
    expect(thirdInfo).toContain("compute");

    await dr.setExecutionSliderValue(0);
    await wait(300);
  });

  // -----------------------------------------------------------------------
  // Test 7: Loop iteration slider
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (loop slider) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 7: loop slider is visible and navigable for files with loops", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    const loopSlider = dr.loopSlider();
    await expect(loopSlider).toBeVisible();

    const initialInfo = await dr.loopSliderInfo().textContent();
    expect(initialInfo).toBeTruthy();
    expect(initialInfo).toContain("1/6");

    await dr.setLoopSliderValue(3);
    await wait(500);

    const updatedInfo = await dr.loopSliderInfo().textContent();
    expect(updatedInfo).toContain("4/6");

    await dr.setLoopSliderValue(0);
    await wait(300);
  });

  // -----------------------------------------------------------------------
  // Test 10: Unified diff - file headers
  // -----------------------------------------------------------------------

  test("Test 10: unified diff shows file headers for all files with hunks", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // Switch to unified diff mode.
    await dr.switchToUnifiedDiff();
    await wait(500);

    // Verify the unified diff container is visible.
    await expect(dr.unifiedDiff()).toBeVisible();

    // All 3 files in the fixture have hunks, so we expect 3 file headers.
    const fileHeaders = dr.unifiedFileHeaders();
    const headerCount = await fileHeaders.count();
    expect(headerCount).toBe(3);

    // Check that file paths are displayed.
    const filePaths = dr.unifiedFilePaths();
    const pathTexts: string[] = [];
    for (let i = 0; i < headerCount; i++) {
      const text = await filePaths.nth(i).textContent();
      pathTexts.push(text ?? "");
    }
    expect(pathTexts).toContain("src/main.rs");
    expect(pathTexts).toContain("src/utils.rs");
    expect(pathTexts).toContain("src/config.rs");
  });

  // -----------------------------------------------------------------------
  // Test 11: Unified diff - added/removed line decorations
  // -----------------------------------------------------------------------

  test("Test 11: unified diff shows added and removed lines with correct classes", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // The fixture has:
    //   src/main.rs: 3 removed, 8 added, 2 context = 13 lines
    //   src/utils.rs: 0 removed, 8 added, 0 context = 8 lines
    //   src/config.rs: 7 removed, 0 added, 0 context = 7 lines
    // Total added: 16, total removed: 10, total context: 2

    const addedCount = await dr.unifiedAddedLines().count();
    expect(addedCount).toBe(16);

    const removedCount = await dr.unifiedRemovedLines().count();
    expect(removedCount).toBe(10);

    const contextCount = await dr.unifiedContextLines().count();
    expect(contextCount).toBe(2);
  });

  // -----------------------------------------------------------------------
  // Test 12: Unified diff - multiple files in scroll view
  // -----------------------------------------------------------------------

  test("Test 12: unified diff shows multiple file sections in a scrollable view", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // Verify all hunk headers are present (one per file since each has one hunk).
    const hunkHeaders = dr.unifiedHunkHeaders();
    const hunkCount = await hunkHeaders.count();
    expect(hunkCount).toBe(3);

    // Verify hunk header content (the @@ lines).
    const firstHunkText = await hunkHeaders.nth(0).textContent();
    expect(firstHunkText).toContain("@@ -2,5 +2,10 @@");

    const secondHunkText = await hunkHeaders.nth(1).textContent();
    expect(secondHunkText).toContain("@@ -0,0 +1,8 @@");

    const thirdHunkText = await hunkHeaders.nth(2).textContent();
    expect(thirdHunkText).toContain("@@ -1,7 +0,0 @@");

    // Verify total lines across all files.
    const totalLines = await dr.unifiedAllLines().count();
    expect(totalLines).toBe(28);  // 13 + 8 + 7

    // Verify the unified diff container itself is scrollable
    // (has overflow-y auto in CSS).
    await expect(dr.unifiedDiff()).toBeVisible();
  });

  // -----------------------------------------------------------------------
  // Test 13: Mode toggle switches between views
  // -----------------------------------------------------------------------

  // Skip: Full Files mode and mode toggle are not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 13: mode toggle switches between full files and unified diff views", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    // Default mode should be Full Files (editor is visible, no unified diff).
    await expect(dr.editor()).toBeVisible();

    // Switch to unified diff.
    await dr.switchToUnifiedDiff();
    await wait(500);

    await expect(dr.unifiedDiff()).toBeVisible();

    // Switch back to full files.
    await dr.switchToFullFiles();
    await wait(500);

    // The editor area should be back. The editor div is present.
    await expect(dr.editor()).toBeVisible();
  });

  // -----------------------------------------------------------------------
  // Test 19: Diff decorations in Full Files Mode
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (Monaco diff decorations) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 19: diff decorations appear in Full Files Mode for modified file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(2000);

    // The first file (src/main.rs) has status "M" with both removed and
    // added lines, so the added lines should get "modified" (yellow)
    // decorations. The hunk has 8 added lines at newLine 3-10.
    const modifiedCount = await dr.diffModifiedLines().count();
    expect(modifiedCount).toBeGreaterThan(0);
  });

  // -----------------------------------------------------------------------
  // Test 20: Added lines have green decoration class
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (Monaco diff decorations) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 20: added lines have green decoration class for purely added file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    // Switch to the second file (src/utils.rs) which has status "A" — all
    // lines are purely added (no removals in the hunk), so they should get
    // the green "added" decoration class.
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(1000);

    const addedCount = await dr.diffAddedLines().count();
    expect(addedCount).toBeGreaterThan(0);

    // Verify at least one element actually has the correct CSS class.
    const firstAdded = dr.diffAddedLines().first();
    const classes = await firstAdded.getAttribute("class");
    expect(classes).toContain("deepreview-diff-line-added");
  });

  // -----------------------------------------------------------------------
  // Test 21: Diff decorations are removed when switching files
  // -----------------------------------------------------------------------

  // Skip: Full Files mode (Monaco diff decorations) is not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 21: diff decorations are removed when switching to a file without diff data", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    // Start on the first file (src/main.rs, modified) — should have diff decorations.
    const initialModified = await dr.diffModifiedLines().count();
    expect(initialModified).toBeGreaterThan(0);

    // Switch to the second file (src/utils.rs, added) — decorations should
    // change. The modified decorations from the first file should be gone.
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(1000);

    // src/utils.rs is purely added, so it should have added decorations
    // but no modified decorations.
    const addedCount = await dr.diffAddedLines().count();
    expect(addedCount).toBeGreaterThan(0);

    const modifiedCount = await dr.diffModifiedLines().count();
    expect(modifiedCount).toBe(0);

    // Switch to the third file (src/config.rs, deleted) — all lines are
    // removed, so there should be no diff decorations at all (removed
    // lines have no position in the new file).
    const thirdItem = dr.fileItemByIndex(2);
    await thirdItem.click();
    await wait(1000);

    const deletedAdded = await dr.diffAddedLines().count();
    const deletedModified = await dr.diffModifiedLines().count();
    expect(deletedAdded).toBe(0);
    expect(deletedModified).toBe(0);
  });

  // -----------------------------------------------------------------------
  // Test 22: DR-6 - Mode switch preserves file selection
  // -----------------------------------------------------------------------

  // Skip: Full Files mode and mode toggle are not available in GL-embedded mode.
  // Restore when the VCS panel's "Open File" mode is implemented.
  test.skip("Test 22: mode switch preserves the selected file index", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    // Select the second file (src/utils.rs).
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(500);
    expect(await secondItem.isSelected()).toBe(true);

    // Switch to unified diff mode.
    await dr.switchToUnifiedDiff();
    await wait(500);

    // The second file should still be selected in the sidebar.
    expect(await secondItem.isSelected()).toBe(true);
    expect(await dr.fileItemByIndex(0).isSelected()).toBe(false);

    // Switch back to full files mode.
    await dr.switchToFullFiles();
    await wait(500);

    // The second file should still be selected.
    expect(await secondItem.isSelected()).toBe(true);
  });

  // -----------------------------------------------------------------------
  // Test 23: DR-6 - Trace context selector is present
  // -----------------------------------------------------------------------

  test("Test 23: trace context selector is visible with correct options", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // The fixture has 2 trace contexts, so the selector should be visible.
    await expect(dr.traceContextSelector()).toBeVisible();
    await expect(dr.traceContextSelect()).toBeVisible();

    // Verify the dropdown has the correct number of options.
    const options = dr.traceContextSelect().locator("option");
    const optionCount = await options.count();
    expect(optionCount).toBe(2);

    // Verify option labels match fixture data.
    const firstLabel = await options.nth(0).textContent();
    expect(firstLabel).toContain("latest passing run");

    const secondLabel = await options.nth(1).textContent();
    expect(secondLabel).toContain("previous run");
  });

  // -----------------------------------------------------------------------
  // Test 24: DR-6 - Header shows session title
  // -----------------------------------------------------------------------

  test("Test 24: header bar displays the session title", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // The fixture has sessionTitle "DeepReview: parser cleanup".
    await expect(dr.sessionTitle()).toBeVisible();
    const titleText = await dr.sessionTitle().textContent();
    expect(titleText).toContain("DeepReview: parser cleanup");
  });

  // -----------------------------------------------------------------------
  // Test 14: Context expansion - expand buttons visible
  // -----------------------------------------------------------------------

  test("Test 14: expand buttons are visible around hunks in unified diff", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // The fixture has sourceContent for all 3 files. The first file
    // (src/main.rs) has a hunk starting at newLine 2, so there is 1 line
    // above (line 1 "fn main() {") to expand, and lines below (12+).
    // We expect expand rows to be present in the unified diff.
    const expandRows = dr.expandRows();
    const expandCount = await expandRows.count();
    expect(expandCount).toBeGreaterThan(0);

    // Verify the expand label text is correct.
    const firstExpandText = await expandRows.first().textContent();
    expect(firstExpandText).toContain("Expand 10 lines");
  });

  // -----------------------------------------------------------------------
  // Test 15: Context expansion - clicking expand above reveals lines
  // -----------------------------------------------------------------------

  test("Test 15: clicking expand above reveals additional context lines", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // Before expanding, no expanded context lines should exist.
    const initialExpanded = await dr.expandedContextLines().count();
    expect(initialExpanded).toBe(0);

    // Expand above the first hunk of the first file (src/main.rs).
    // The hunk starts at newLine 2, and there is 1 line above (line 1).
    // So expanding should reveal 1 context line ("fn main() {").
    await dr.expandAbove(0, 0);
    await wait(500);

    const expandedCount = await dr.expandedContextLines().count();
    expect(expandedCount).toBeGreaterThan(0);

    // The expanded line should be a context line (not added/removed).
    const expandedLine = dr.expandedContextLines().first();
    const classes = await expandedLine.getAttribute("class");
    expect(classes).toContain("deepreview-unified-line-context");
  });

  // -----------------------------------------------------------------------
  // Test 16: Context expansion - clicking expand below reveals lines
  // -----------------------------------------------------------------------

  test("Test 16: clicking expand below reveals additional context lines", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // Expand below the first hunk of the first file (src/main.rs).
    // The hunk ends at newLine 11, and the file has 25 lines, so
    // expanding should reveal up to 10 more context lines.
    await dr.expandBelow(0, 0);
    await wait(500);

    const expandedCount = await dr.expandedContextLines().count();
    expect(expandedCount).toBeGreaterThan(0);

    // The expanded lines should contain source content from the file.
    const firstExpandedContent = await dr.expandedContextLines().first()
      .locator(".deepreview-unified-line-content").textContent();
    expect(firstExpandedContent).toBeTruthy();
    // Line 12 of main.rs is "}" (closing brace of fn main).
    expect(firstExpandedContent).toContain("}");
  });

  // -----------------------------------------------------------------------
  // Test 17: Omniscience overlay - inline values appear on diff lines
  // -----------------------------------------------------------------------

  test("Test 17: omniscience inline values appear on unified diff lines with flow data", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    // The fixture has flow data for src/main.rs and src/utils.rs. Lines
    // in the unified diff that match flow step line numbers should have
    // an omniscience overlay span appended.
    const omniscienceCount = await dr.omniscienceValues().count();
    expect(omniscienceCount).toBeGreaterThan(0);
  });

  // -----------------------------------------------------------------------
  // Test 18: Omniscience overlay - values match fixture flow data
  // -----------------------------------------------------------------------

  test("Test 18: omniscience inline values match the flow data from the fixture", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await dr.switchToUnifiedDiff();
    await wait(500);

    const normalize = (s: string) => s.replace(/\u00a0/g, " ");

    const allTexts: string[] = [];
    const locators = await dr.omniscienceValues().all();
    for (const loc of locators) {
      const text = await loc.textContent();
      if (text) allTexts.push(normalize(text));
    }
    const combined = allTexts.join(" | ");

    // From the fixture flow data for src/main.rs (first execution):
    //   line 2: x = 10
    //   line 3: x = 10, y = 20
    //   line 4: result = 55
    //   line 10: result = 55
    // For src/utils.rs (format_output execution):
    //   line 2: trimmed = "hello world"
    //   line 6: result = "[hello world]"
    // Lines 2, 3, 4 of main.rs are in the hunk (newLine 2, 3, 4).
    // Line 10 of main.rs is also in the hunk (newLine 10).
    //
    // Flow values are now rendered using the standard flow CSS classes:
    //   <span class="flow-parallel-value-name"><x></span>
    //   <span class="flow-parallel-value-box">10</span>
    // so textContent reads as "<x>10" rather than "x = 10".
    expect(combined).toContain("<x>");
    expect(combined).toContain("10");
    expect(combined).toContain("<y>");
    expect(combined).toContain("20");
    expect(combined).toContain("<result>");
    expect(combined).toContain("55");

    // Verify src/utils.rs flow values are also present.
    expect(combined).toContain("<trimmed>");
  });

  // -----------------------------------------------------------------------
  // Test 8: Call trace panel
  // -----------------------------------------------------------------------

  // Skip: Call trace panel is rendered by a separate GL panel in GL-embedded
  // mode, not by the DeepReview component itself.
  // Restore when the calltrace GL panel is testable.
  test.skip("Test 8: call trace panel renders the tree with correct structure", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await expect(dr.callTracePanel()).toBeVisible();

    const headerText = await dr.callTraceHeader().textContent();
    expect(headerText).toContain("Call Trace");

    await expect(dr.callTraceEmpty()).toBeHidden();

    await expect(dr.callTraceBody()).toBeVisible();

    const entries = dr.callTraceEntries();
    const entryCount = await entries.count();
    expect(entryCount).toBeGreaterThanOrEqual(1);

    const firstEntryText = await entries.first().textContent();
    expect(firstEntryText).toContain("main");
    expect(firstEntryText).toContain("x1");

    let foundCompute = false;
    let foundFormatOutput = false;
    for (let i = 0; i < entryCount; i++) {
      const text = await entries.nth(i).textContent();
      if (text?.includes("compute")) foundCompute = true;
      if (text?.includes("format_output")) foundFormatOutput = true;
    }
    expect(foundCompute).toBe(true);
    expect(foundFormatOutput).toBe(true);

    for (let i = 0; i < entryCount; i++) {
      const text = await entries.nth(i).textContent();
      if (text?.includes("compute")) {
        const style = await entries.nth(i).getAttribute("style");
        expect(style).toContain("16px");
        break;
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Test suite: empty/missing data handling (Test 9)
// ---------------------------------------------------------------------------

test.describe("DeepReview GUI - empty data handling", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // -----------------------------------------------------------------------
  // Test 9a: Empty files array
  // -----------------------------------------------------------------------

  test.describe("empty files array", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: emptyReviewPath });

    test("Test 9a: renders without errors when files array is empty", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.container()).toBeVisible();
      await expect(dr.errorMessage()).toBeHidden();

      const commitText = await dr.commitDisplay().textContent();
      expect(commitText).toBeTruthy();

      const statsText = await dr.statsDisplay().textContent();
      expect(statsText).toContain("0 files");

      const items = await dr.fileItems();
      expect(items.length).toBe(0);

      // Note: execution slider is not rendered in GL-embedded mode.
      // The empty state is verified by the 0 file items above.
    });
  });

  // -----------------------------------------------------------------------
  // Test 9b: Missing call trace (null)
  // -----------------------------------------------------------------------

  test.describe("missing call trace", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: noCalltracePath });

    // Skip: Call trace panel is rendered by a separate GL panel in
    // GL-embedded mode, not by the DeepReview component itself.
    // Restore when the calltrace GL panel is testable.
    test.skip("Test 9b: renders without crash when callTrace is null", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.container()).toBeVisible();

      await expect(dr.callTracePanel()).toBeVisible();
      await expect(dr.callTraceEmpty()).toBeVisible();
      const emptyText = await dr.callTraceEmpty().textContent();
      expect(emptyText).toContain("No call trace data");
    });

    test("Test 9c: file without coverage shows '--' badge", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      const items = await dr.fileItems();
      expect(items.length).toBe(1);

      const badge = await items[0].coverageBadge();
      if (badge !== "") {
        expect(badge).toBe("--");
      }

      const name = await items[0].name();
      expect(name).toBe("lib.rs");
    });
  });
});

// ---------------------------------------------------------------------------
// Test suite: DR-8 comprehensive workflow (uses all 3 fixtures)
// ---------------------------------------------------------------------------

test.describe("DeepReview comprehensive workflow", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // -----------------------------------------------------------------------
  // Full workflow: exercises the entire feature end-to-end
  // -----------------------------------------------------------------------

  test.describe("full workflow", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

    test("DR-8: full end-to-end workflow through all DeepReview features", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      // Step 1-2: Verify header shows session title.
      await expect(dr.sessionTitle()).toBeVisible();
      const titleText = await dr.sessionTitle().textContent();
      expect(titleText).toContain("DeepReview: parser cleanup");

      // Step 3: Verify VCS panel file list shows 3 files with correct diff statuses.
      const items = await dr.fileItems();
      expect(items.length).toBe(3);

      const expectedStatuses = ["M", "A", "D"];
      for (let i = 0; i < items.length; i++) {
        const status = await items[i].diffStatus();
        expect(status).toBe(expectedStatuses[i]);
      }

      // Verify the first file is selected by default.
      expect(await items[0].isSelected()).toBe(true);

      // Step 4: Click the second file in the VCS panel and verify selection.
      await wait(500);

      const secondItem = dr.fileItemByIndex(1);
      await secondItem.click();
      await wait(500);

      expect(await secondItem.isSelected()).toBe(true);
      expect(await dr.fileItemByIndex(0).isSelected()).toBe(false);

      // Step 5: In GL-embedded mode the unified diff is always shown.
      await expect(dr.unifiedDiff()).toBeVisible();

      // Step 6: Verify hunks are rendered with correct added/removed counts.
      // Totals across all files: 16 added, 10 removed.
      const addedCount = await dr.unifiedAddedLines().count();
      expect(addedCount).toBe(16);

      const removedCount = await dr.unifiedRemovedLines().count();
      expect(removedCount).toBe(10);

      // Verify all 3 hunk headers are present.
      const hunkHeaders = dr.unifiedHunkHeaders();
      expect(await hunkHeaders.count()).toBe(3);

      // Step 7-8: Expand context above the first hunk and verify expanded
      // lines appear.
      const initialExpanded = await dr.expandedContextLines().count();
      expect(initialExpanded).toBe(0);

      await dr.expandAbove(0, 0);
      await wait(500);

      const expandedCount = await dr.expandedContextLines().count();
      expect(expandedCount).toBeGreaterThan(0);

      // Verify expanded lines have the context class.
      const expandedClasses = await dr.expandedContextLines().first().getAttribute("class");
      expect(expandedClasses).toContain("deepreview-unified-line-context");

      // Step 9: Verify Omniscience inline values on diff lines.
      const omniscienceCount = await dr.omniscienceValues().count();
      expect(omniscienceCount).toBeGreaterThan(0);

      const normalize = (s: string) => s.replace(/\u00a0/g, " ");
      const allOmnTexts: string[] = [];
      const omnLocators = await dr.omniscienceValues().all();
      for (const loc of omnLocators) {
        const text = await loc.textContent();
        if (text) allOmnTexts.push(normalize(text));
      }
      const combinedOmn = allOmnTexts.join(" | ");
      // Flow values use standard flow CSS classes; textContent reads
      // "<x>10" rather than the old "x = 10" format.
      expect(combinedOmn).toContain("<x>");
      expect(combinedOmn).toContain("10");
      expect(combinedOmn).toContain("<y>");
      expect(combinedOmn).toContain("20");

      // Step 10: Switch trace context if the selector is available.
      const selectorVisible = await dr.traceContextSelector().isVisible();
      if (selectorVisible) {
        const options = dr.traceContextSelect().locator("option");
        const optionCount = await options.count();
        expect(optionCount).toBe(2);

        // Switch to the second trace context.
        await dr.setTraceContext(1);
        await wait(500);
      }

      // Note: Steps 11-13 (Full Files mode, mode toggle, Monaco diff
      // decorations) are not applicable in GL-embedded mode. They will be
      // restored when the VCS panel's "Open File" mode is implemented.
    });
  });

  // -----------------------------------------------------------------------
  // Empty review data: no crash, no file items, editor shows empty state
  // -----------------------------------------------------------------------

  test.describe("empty review data", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: emptyReviewPath });

    test("DR-8: empty review loads without crash and shows empty state", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      // Verify no crash: container visible, no error message.
      await expect(dr.container()).toBeVisible();
      await expect(dr.errorMessage()).toBeHidden();

      // Verify no file items in the VCS panel.
      const items = await dr.fileItems();
      expect(items.length).toBe(0);

      // Verify stats reflect empty data.
      const statsText = await dr.statsDisplay().textContent();
      expect(statsText).toContain("0 files");

      // Note: execution slider is not rendered in GL-embedded mode.
      // The empty state is verified by the 0 file items and stats above.
    });
  });

  // -----------------------------------------------------------------------
  // No calltrace review data: everything works except calltrace is empty
  // -----------------------------------------------------------------------

  test.describe("no calltrace review data", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: noCalltracePath });

    test("DR-8: no-calltrace review loads and shows file in VCS panel", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      // Verify the container renders without errors.
      await expect(dr.container()).toBeVisible();
      await expect(dr.errorMessage()).toBeHidden();

      // Verify the VCS panel file list works (1 file in the fixture).
      const items = await dr.fileItems();
      expect(items.length).toBe(1);

      const name = await items[0].name();
      expect(name).toBe("lib.rs");

      // Note: Call trace panel is rendered by a separate GL panel in
      // GL-embedded mode. Calltrace assertions are skipped here; they
      // will be restored when the calltrace GL panel is testable.
    });
  });
});
