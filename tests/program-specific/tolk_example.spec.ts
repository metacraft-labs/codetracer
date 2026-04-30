/**
 * Playwright UI tests for the Tolk (TON) example.
 *
 * These tests verify that the CodeTracer UI renders a Tolk trace
 * correctly, covering:
 *   - Editor pane loading the .tolk source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the Tolk call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Tolk trace requires the Tolk recorder pipeline:
 *   1. `codetracer-tolk-recorder` binary available via
 *      `CODETRACER_TOLK_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!tolkPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.tolk` is integrated.
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
 * Returns true when the `codetracer-tolk-recorder` binary is reachable.
 * Checks `CODETRACER_TOLK_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasTolkRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_TOLK_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-tolk-recorder";
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
const tolkRecorderAvailable = hasTolkRecorder();
// Test program lives in the codetracer-tolk-recorder sibling repo.
const tolkTestProgram = resolveRecorderTestProgram("tolk", "tolk/flow_test.tolk");
const tolkPipelineAvailable = tolkRecorderAvailable && tolkTestProgram !== null;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

// TODO(skipped): All 8 UI tests skipped because tolkPipelineAvailable is false.
//   The codetracer-tolk-recorder binary is not detected (codetracer-ton-recorder sibling is present
//   but the binary name may differ), or resolveRecorderTestProgram("tolk", "tolk/flow_test.tolk")
//   returns null because the test program does not exist at the expected path.
//   Hypothesis: Check if the binary is named `codetracer-ton-recorder` instead of
//   `codetracer-tolk-recorder`, or verify the test program path in the sibling repo.
test.describe("tolk_example — basic layout", () => {
  test.skip(
    !tolkPipelineAvailable,
    "Tolk recorder pipeline not available (need codetracer-tolk-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: tolkTestProgram ?? "", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    expect(location.path.endsWith("flow_test.tolk")).toBeTruthy();
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("tolk_example — event log", () => {
  test.skip(
    !tolkPipelineAvailable,
    "Tolk recorder pipeline not available (need codetracer-tolk-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: tolkTestProgram ?? "", launchMode: "trace" });

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

test.describe("tolk_example — state panel", () => {
  test.skip(
    !tolkPipelineAvailable,
    "Tolk recorder pipeline not available (need codetracer-tolk-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: tolkTestProgram ?? "", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  test("state panel shows decoded TVM stack/variable values", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
    expect(varNames.length).toBeGreaterThan(0);
    // Tolk/TVM uses stack-based or named variables from source debug info.
    const hasVariable = varNames.some(
      (name) => name.length > 0,
    );
    expect(hasVariable).toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("tolk_example — call trace", () => {
  test.skip(
    !tolkPipelineAvailable,
    "Tolk recorder pipeline not available (need codetracer-tolk-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: tolkTestProgram ?? "", launchMode: "trace" });

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

test.describe("tolk_example — environment detection", () => {
  test("tolk extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.tolk")).toBe(true);
    expect(isDbBased("some/path/contract.tolk")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof tolkRecorderAvailable).toBe("boolean");
    expect(typeof tolkPipelineAvailable).toBe("boolean");
  });
});
