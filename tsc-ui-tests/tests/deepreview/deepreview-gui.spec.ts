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
  // Test 3: Coverage highlighting
  // -----------------------------------------------------------------------

  test("Test 3: coverage decorations are applied to the editor", async ({ ctPage }) => {
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

  test("Test 4: inline variable values appear as decorations", async ({ ctPage }) => {
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

  test("Test 5: clicking a file in the sidebar switches the editor", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.waitForEditorReady();
    await wait(500);

    const firstItem = dr.fileItemByIndex(0);
    expect(await firstItem.isSelected()).toBe(true);

    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();

    await wait(500);

    expect(await secondItem.isSelected()).toBe(true);
    expect(await firstItem.isSelected()).toBe(false);

    await expect(dr.editor()).toBeVisible();

    await firstItem.click();
    await wait(500);
    expect(await firstItem.isSelected()).toBe(true);
  });

  // -----------------------------------------------------------------------
  // Test 6: Execution slider
  // -----------------------------------------------------------------------

  test("Test 6: execution slider navigates between function executions", async ({ ctPage }) => {
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

  test("Test 7: loop slider is visible and navigable for files with loops", async ({ ctPage }) => {
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
  // Test 8: Call trace panel
  // -----------------------------------------------------------------------

  test("Test 8: call trace panel renders the tree with correct structure", async ({ ctPage }) => {
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

      const sliderLabel = await dr.executionSliderLabel().textContent();
      expect(sliderLabel).toContain("No execution data");
    });
  });

  // -----------------------------------------------------------------------
  // Test 9b: Missing call trace (null)
  // -----------------------------------------------------------------------

  test.describe("missing call trace", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: noCalltracePath });

    test("Test 9b: renders without crash when callTrace is null", async ({ ctPage }) => {
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
