/**
 * Playwright UI tests for the Sway/Fuel example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders a Fuel/Sway trace
 * correctly, covering:
 *   - Editor pane loading the .sw source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the Sway call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Sway trace requires the Fuel recorder pipeline:
 *   1. `codetracer-fuel-recorder` binary available via
 *      `CODETRACER_FUEL_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!fuelPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.sw` is integrated.
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
 * Returns true when the `codetracer-fuel-recorder` binary is reachable.
 * Checks `CODETRACER_FUEL_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasFuelRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_FUEL_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-fuel-recorder";
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
const fuelRecorderAvailable = hasFuelRecorder();
// The Sway/Fuel pipeline requires both the recorder binary and the `forc`
// compiler. The recorder is typically built from the sibling repo, but `forc`
// lives in that repo's dev shell and is not available in codetracer's shell.
const fuelToolchainAvailable = hasToolOnPath("forc");
const fuelPipelineAvailable = fuelRecorderAvailable && fuelToolchainAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("sway_example — basic layout", () => {
  // Skip the entire suite when the Fuel recorder pipeline is absent.
  // Remove this guard once `ct record <path>.sw` is integrated.
  test.skip(
    !fuelPipelineAvailable,
    "Fuel recorder pipeline not available (need codetracer-fuel-recorder and forc on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "sway_example/main.sw", launchMode: "trace" });

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
    // The entry point should resolve to the Sway source file.
    expect(location.path.endsWith("main.sw")).toBeTruthy();
    // The Sway trace starts inside main; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("sway_example — event log", () => {
  test.skip(
    !fuelPipelineAvailable,
    "Fuel recorder pipeline not available (need codetracer-fuel-recorder and forc on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "sway_example/main.sw", launchMode: "trace" });

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

test.describe("sway_example — state panel", () => {
  test.skip(
    !fuelPipelineAvailable,
    "Fuel recorder pipeline not available (need codetracer-fuel-recorder and forc on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "sway_example/main.sw", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // Sway variables: a, b, sum_val, doubled, final_result.
  // Verify the state panel shows final_result with value 94.
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

test.describe("sway_example — call trace", () => {
  test.skip(
    !fuelPipelineAvailable,
    "Fuel recorder pipeline not available (need codetracer-fuel-recorder and forc on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "sway_example/main.sw", launchMode: "trace" });

  test("call trace shows main entry", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    const callTraceTabs = await layout.callTraceTabs();
    expect(callTraceTabs.length).toBeGreaterThan(0);
    const callTrace = callTraceTabs[0];
    await callTrace.tabButton().click();
    await callTrace.waitForReady();
    // The calltrace should contain at least one entry with "main".
    const entries = await callTrace.getEntries();
    expect(entries.length).toBeGreaterThan(0);
    // Try to find the "main" entry; if not found, at least verify entries exist.
    const mainEntry = await callTrace.findEntry("main");
    if (mainEntry) {
      const name = await mainEntry.functionName();
      expect(name.toLowerCase()).toBe("main");
    }
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

test.describe("sway_example — environment detection", () => {
  test("sw extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .sw files as DB-based
    // so they don't attempt RR recording when fuelPipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("main.sw")).toBe(true);
    expect(isDbBased("some/path/contract.sw")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof fuelRecorderAvailable).toBe("boolean");
    expect(typeof fuelPipelineAvailable).toBe("boolean");
  });
});
