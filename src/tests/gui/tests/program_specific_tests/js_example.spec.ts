/**
 * Playwright UI tests for the JavaScript example.
 *
 * These tests verify that the CodeTracer UI renders a JavaScript trace
 * correctly, covering:
 *   - Editor pane loading the .js source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the JavaScript call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a JavaScript trace requires the JS recorder pipeline:
 *   1. `codetracer-js-recorder` binary available via
 *      `CODETRACER_JS_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!jsPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.js` is integrated.
 *
 * The structural tests at the bottom run unconditionally and verify the
 * tool-detection logic without launching Electron.
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
 * Returns true when the `codetracer-js-recorder` binary is reachable.
 * Checks `CODETRACER_JS_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasJsRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_JS_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-js-recorder";
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
const jsRecorderAvailable = hasJsRecorder();
// Test program lives in the codetracer-js-recorder sibling repo.
const jsTestProgram = resolveRecorderTestProgram("js", "js/flow_test.js");
const jsPipelineAvailable = jsRecorderAvailable && jsTestProgram !== null;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

// TODO(skipped): All 8 UI tests skipped because jsPipelineAvailable is false.
//   The codetracer-js-recorder binary is detected as a sibling, but the test program
//   resolution (resolveRecorderTestProgram("js", "js/flow_test.js")) likely fails because
//   the test program path does not exist in the sibling repo's expected location.
//   Hypothesis: Verify the test program exists at codetracer-js-recorder/test-programs/js/flow_test.js
//   or update the path passed to resolveRecorderTestProgram().
test.describe("js_example — basic layout", () => {
  test.skip(
    !jsPipelineAvailable,
    "JS recorder pipeline not available (need codetracer-js-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: jsTestProgram ?? "", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    expect(location.path.endsWith("flow_test.js")).toBeTruthy();
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("js_example — event log", () => {
  test.skip(
    !jsPipelineAvailable,
    "JS recorder pipeline not available (need codetracer-js-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: jsTestProgram ?? "", launchMode: "trace" });

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

test.describe("js_example — state panel", () => {
  test.skip(
    !jsPipelineAvailable,
    "JS recorder pipeline not available (need codetracer-js-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: jsTestProgram ?? "", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  test("state panel shows decoded local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
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

test.describe("js_example — call trace", () => {
  test.skip(
    !jsPipelineAvailable,
    "JS recorder pipeline not available (need codetracer-js-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: jsTestProgram ?? "", launchMode: "trace" });

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

test.describe("js_example — environment detection", () => {
  // JavaScript is NOT classified as DB-based in the Nim backend (common_lang.nim).
  // The JS recorder is a standalone pipeline tool, similar to Solana.
  test("js extension is NOT classified as DB-based (JS uses pipeline detection)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.js")).toBe(false);
    expect(isDbBased("some/path/app.js")).toBe(false);
    // Sanity-check: DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof jsRecorderAvailable).toBe("boolean");
    expect(typeof jsPipelineAvailable).toBe("boolean");
  });
});
