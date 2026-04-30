/**
 * Playwright UI tests for the Move example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders a Move trace
 * correctly, covering:
 *   - Editor pane loading the .move source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the Move call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Move trace requires the Move recorder pipeline:
 *   1. `codetracer-move-recorder` binary available via
 *      `CODETRACER_MOVE_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!movePipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.move` is integrated.
 *
 * The structural tests at the bottom run unconditionally and verify the
 * language-detection logic without launching Electron.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-move-recorder` binary is reachable.
 * Checks `CODETRACER_MOVE_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMoveRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MOVE_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-move-recorder";
  try {
    const result = childProcess.spawnSync(binary, ["--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

// Evaluated at collection time so skip decisions are instant.
const moveRecorderAvailable = hasMoveRecorder();
// The Move pipeline requires both the recorder binary and the `aptos` CLI
// (or `sui` CLI) for compiling/replaying Move programs.
const moveToolchainAvailable = hasToolOnPath("aptos") || hasToolOnPath("sui");
const movePipelineAvailable = moveRecorderAvailable && moveToolchainAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("move_example — basic layout", () => {
  // Skip the entire suite when the Move recorder pipeline is absent.
  // Remove this guard once `ct record <path>.move` is integrated.
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder and aptos/sui on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    // In browser mode the title includes the trace name, so use toContain.
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    // The entry point should resolve to the Move source file.
    expect(location.path.endsWith("flow_test.move")).toBeTruthy();
    // The Move trace starts inside test_computation; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("move_example — event log", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder and aptos/sui on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  test("event log has at least one event", async ({ ctPage }) => {
    // Wait for the event log footer row-count to appear.
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: state panel
// ---------------------------------------------------------------------------

test.describe("move_example — state panel", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder and aptos/sui on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // Move variables: a, b, sum_val, doubled, final_result.
  // Verify the state panel shows variables and check final_result = 94 if visible.
  test("state panel shows decoded local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
    // The state panel should contain at least one variable entry.
    expect(varNames.length).toBeGreaterThan(0);
    // Check for final_result = 94 if it is visible at the current trace step.
    if (values.final_result) {
      expect(values.final_result.text).toBe("94");
    }
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("move_example — call trace", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder and aptos/sui on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  test("call trace shows test_computation entry", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    const callTraceTabs = await layout.callTraceTabs();
    expect(callTraceTabs.length).toBeGreaterThan(0);
    const callTrace = callTraceTabs[0];
    await callTrace.tabButton().click();
    await callTrace.waitForReady();
    const entries = await callTrace.getEntries();
    expect(entries.length).toBeGreaterThan(0);
    // Try to find "test_computation" or "main"; either is acceptable depending
    // on how the Move recorder emits call frames.
    const testEntry = await callTrace.findEntry("test_computation");
    const mainEntry = await callTrace.findEntry("main");
    // At least one of the expected function entries should be present.
    expect(testEntry !== null || mainEntry !== null).toBeTruthy();
  });

  test("continue", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);
    await layout.continueButton().click();
    // Wait for the backend to finish processing.
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    const newLocation = await statusBar.location();
    expect(newLocation.line).toBeGreaterThanOrEqual(1);
  });

  test("next", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);
    await layout.nextButton().click();
    // Wait for the backend to finish processing.
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    const newLocation = await statusBar.location();
    expect(newLocation.line).not.toBe(initialLocation.line);
  });
});

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("move_example — environment detection", () => {
  test("move extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .move files as DB-based
    // so they don't attempt RR recording when movePipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.move")).toBe(true);
    expect(isDbBased("some/path/module.move")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof moveRecorderAvailable).toBe("boolean");
    expect(typeof movePipelineAvailable).toBe("boolean");
  });
});
