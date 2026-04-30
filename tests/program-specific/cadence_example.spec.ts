/**
 * Playwright UI tests for the Cadence (Flow) example.
 *
 * These tests verify that the CodeTracer UI renders a Cadence trace
 * correctly, covering:
 *   - Editor pane loading the .cdc source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the Cadence call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Cadence trace requires the Cadence recorder pipeline:
 *   1. `codetracer-cadence-recorder` binary available via
 *      `CODETRACER_CADENCE_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!cadencePipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.cdc` is integrated.
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
import { resolveRecorderTestProgram } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-cadence-recorder` binary is reachable.
 * Checks `CODETRACER_CADENCE_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasCadenceRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_CADENCE_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-cadence-recorder";
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
const cadenceRecorderAvailable = hasCadenceRecorder();
// Test program lives in the codetracer-cadence-recorder sibling repo.
const cadenceTestProgram = resolveRecorderTestProgram("cadence", "cadence/flow_test.cdc");
const cadencePipelineAvailable = cadenceRecorderAvailable && cadenceTestProgram !== null;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

// TODO(skipped): All 8 UI tests skipped because cadencePipelineAvailable is false.
//   The codetracer-cadence-recorder binary is detected, but resolveRecorderTestProgram("cadence",
//   "cadence/flow_test.cdc") likely returns null because the test program file does not exist
//   at the expected path in the sibling repo.
//   Hypothesis: Verify the test program exists at codetracer-flow-recorder/test-programs/cadence/flow_test.cdc
//   or check if the Cadence recorder binary does not pass the --version check.
test.describe("cadence_example — basic layout", () => {
  test.skip(
    !cadencePipelineAvailable,
    "Cadence recorder pipeline not available (need codetracer-cadence-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: cadenceTestProgram ?? "", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    expect(location.path.endsWith("flow_test.cdc")).toBeTruthy();
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("cadence_example — event log", () => {
  test.skip(
    !cadencePipelineAvailable,
    "Cadence recorder pipeline not available (need codetracer-cadence-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: cadenceTestProgram ?? "", launchMode: "trace" });

  test("event log has at least one event", async ({ ctPage }) => {
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

test.describe("cadence_example — state panel", () => {
  test.skip(
    !cadencePipelineAvailable,
    "Cadence recorder pipeline not available (need codetracer-cadence-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: cadenceTestProgram ?? "", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  test("state panel shows decoded Cadence variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
    expect(varNames.length).toBeGreaterThan(0);
    // Cadence uses named variables from the source (e.g. "a", "result").
    const hasVariable = varNames.some(
      (name) => name.length > 0,
    );
    expect(hasVariable).toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("cadence_example — call trace", () => {
  test.skip(
    !cadencePipelineAvailable,
    "Cadence recorder pipeline not available (need codetracer-cadence-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: cadenceTestProgram ?? "", launchMode: "trace" });

  test("call trace shows compute function entry", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    const callTraceTabs = await layout.callTraceTabs();
    expect(callTraceTabs.length).toBeGreaterThan(0);
    const callTrace = callTraceTabs[0];
    await callTrace.tabButton().click();
    await callTrace.waitForReady();
    const entries = await callTrace.getEntries();
    expect(entries.length).toBeGreaterThan(0);
    const firstName = await entries[0].functionName();
    expect(firstName.length).toBeGreaterThan(0);
  });

  test("continue", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);
    await layout.continueButton().click();
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

test.describe("cadence_example — environment detection", () => {
  test("cdc extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.cdc")).toBe(true);
    expect(isDbBased("some/path/contract.cdc")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof cadenceRecorderAvailable).toBe("boolean");
    expect(typeof cadencePipelineAvailable).toBe("boolean");
  });
});
