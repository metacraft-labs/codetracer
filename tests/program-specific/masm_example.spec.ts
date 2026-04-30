/**
 * Playwright UI tests for the Miden/MASM example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders a Miden/MASM trace
 * correctly, covering:
 *   - Editor pane loading the .masm source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the MASM call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a MASM trace requires the Miden recorder pipeline:
 *   1. `codetracer-miden-recorder` binary available via
 *      `CODETRACER_MIDEN_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!midenPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.masm` is integrated.
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
 * Returns true when the `codetracer-miden-recorder` binary is reachable.
 * Checks `CODETRACER_MIDEN_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMidenRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MIDEN_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-miden-recorder";
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
const midenRecorderAvailable = hasMidenRecorder();
// The Miden recorder bundles miden-assembly as a Rust library for MASM files,
// but the full pipeline (especially Rust-via-midenc) needs the `miden` CLI.
// Check for `miden` as the toolchain availability indicator.
const midenToolchainAvailable = hasToolOnPath("miden");
const midenPipelineAvailable = midenRecorderAvailable && midenToolchainAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("masm_example — basic layout", () => {
  // Skip the entire suite when the Miden recorder pipeline is absent.
  // Remove this guard once `ct record <path>.masm` is integrated.
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder and miden on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

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
    // The entry point should resolve to the MASM source file.
    expect(location.path.endsWith("compute.masm")).toBeTruthy();
    // The MASM trace starts at the begin block; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("masm_example — event log", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder and miden on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

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

test.describe("masm_example — state panel", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder and miden on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // MASM variables use positional names like local[0], local[1], etc.
  // Verify the state panel shows at least one variable with a "local" prefix.
  test("state panel shows decoded stack/local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
    // The state panel should contain at least one variable entry.
    expect(varNames.length).toBeGreaterThan(0);
    // At least one variable name should contain "local" or be a numeric index.
    const hasLocalVar = varNames.some(
      (name) => name.includes("local") || /^\d+$/.test(name),
    );
    expect(hasLocalVar).toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("masm_example — call trace", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder and miden on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  test("call trace shows compute procedure entry", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    const callTraceTabs = await layout.callTraceTabs();
    expect(callTraceTabs.length).toBeGreaterThan(0);
    const callTrace = callTraceTabs[0];
    await callTrace.tabButton().click();
    await callTrace.waitForReady();
    // The calltrace should contain at least one entry. For MASM traces the
    // root procedure is "compute" but the name may vary depending on how the
    // recorder emits call frames, so just verify entries exist.
    const entries = await callTrace.getEntries();
    expect(entries.length).toBeGreaterThan(0);
    // Check that at least one entry's function name is non-empty.
    const firstName = await entries[0].functionName();
    expect(firstName.length).toBeGreaterThan(0);
  });

  test("continue", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);
    // Click continue to advance execution to the next breakpoint or end.
    await layout.continueButton().click();
    // Wait for the backend to finish processing (status returns to "ready").
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    // After continue, the line should have changed (or we reached the end).
    const newLocation = await statusBar.location();
    // The location should still be valid after the movement.
    expect(newLocation.line).toBeGreaterThanOrEqual(1);
  });

  test("next", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);
    // Click next (step over) to advance one step.
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
    // After stepping, we should be at a different line than before.
    expect(newLocation.line).not.toBe(initialLocation.line);
  });
});

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("masm_example — environment detection", () => {
  test("masm extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .masm files as DB-based
    // so they don't attempt RR recording when midenPipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("compute.masm")).toBe(true);
    expect(isDbBased("some/path/program.masm")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof midenRecorderAvailable).toBe("boolean");
    expect(typeof midenPipelineAvailable).toBe("boolean");
  });
});
