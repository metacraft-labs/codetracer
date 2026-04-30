/**
 * Playwright UI tests for the PolkaVM example.
 *
 * These tests verify that the CodeTracer UI renders a PolkaVM trace
 * correctly, covering:
 *   - Editor pane loading the .rs source file (Rust compiled to PolkaVM)
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the PolkaVM call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a PolkaVM trace requires the PolkaVM recorder pipeline:
 *   1. `codetracer-polkavm-recorder` binary available via
 *      `CODETRACER_POLKAVM_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!polkavmPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.rs` (PolkaVM) is integrated.
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
import { resolveRecorderTestProgram, hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-polkavm-recorder` binary is reachable.
 * Checks `CODETRACER_POLKAVM_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasPolkavmRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_POLKAVM_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-polkavm-recorder";
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
const polkavmRecorderAvailable = hasPolkavmRecorder();
// Test program lives in the codetracer-polkavm-recorder sibling repo.
const polkavmTestProgram = resolveRecorderTestProgram("polkavm", "rust/flow_test.rs");
// The PolkaVM recorder bundles polkavm-linker as a Rust library, but compiling
// Rust source to a PolkaVM blob requires the PolkaVM toolchain (`polkatool` or
// a RISC-V cross-compilation target). Check for `polkatool` as the indicator.
const polkavmToolchainAvailable = hasToolOnPath("polkatool");
const polkavmPipelineAvailable = polkavmRecorderAvailable && polkavmTestProgram !== null && polkavmToolchainAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("polkavm_example — basic layout", () => {
  test.skip(
    !polkavmPipelineAvailable,
    "PolkaVM recorder pipeline not available (need codetracer-polkavm-recorder and polkatool on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: polkavmTestProgram ?? "", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    expect(location.path.endsWith("flow_test.rs")).toBeTruthy();
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("polkavm_example — event log", () => {
  test.skip(
    !polkavmPipelineAvailable,
    "PolkaVM recorder pipeline not available (need codetracer-polkavm-recorder and polkatool on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: polkavmTestProgram ?? "", launchMode: "trace" });

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

test.describe("polkavm_example — state panel", () => {
  test.skip(
    !polkavmPipelineAvailable,
    "PolkaVM recorder pipeline not available (need codetracer-polkavm-recorder and polkatool on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: polkavmTestProgram ?? "", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  test("state panel shows decoded register/local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    const varNames = Object.keys(values);
    expect(varNames.length).toBeGreaterThan(0);
    // PolkaVM uses register-based names like A0, A1 or local indices.
    const hasRegisterVar = varNames.some(
      (name) => /^[Aa]\d+$/.test(name) || /^\d+$/.test(name) || name.includes("local"),
    );
    expect(hasRegisterVar).toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("polkavm_example — call trace", () => {
  test.skip(
    !polkavmPipelineAvailable,
    "PolkaVM recorder pipeline not available (need codetracer-polkavm-recorder and polkatool on PATH)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: polkavmTestProgram ?? "", launchMode: "trace" });

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

test.describe("polkavm_example — environment detection", () => {
  test("pvm extension is classified as DB-based; rs is NOT (PolkaVM uses pipeline detection)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    // .pvm (compiled PolkaVM bytecode) is DB-based.
    expect(isDbBased("flow_test.pvm")).toBe(true);
    expect(isDbBased("some/path/program.pvm")).toBe(true);
    // .rs files are RR-based (native Rust); PolkaVM detection is via the recorder pipeline.
    expect(isDbBased("flow_test.rs")).toBe(false);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof polkavmRecorderAvailable).toBe("boolean");
    expect(typeof polkavmPipelineAvailable).toBe("boolean");
  });
});
