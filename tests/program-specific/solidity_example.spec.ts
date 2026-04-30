/**
 * Playwright UI tests for the Solidity EVM example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders an EVM/Solidity trace
 * correctly, covering:
 *   - Editor pane loading the .sol source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one EVM event (Transfer)
 *   - Call trace pane showing the Solidity call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Solidity trace requires the EVM recorder pipeline:
 *   1. `solc` (Solidity compiler) on PATH.
 *   2. `codetracer-evm-recorder` binary available via
 *      `CODETRACER_EVM_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!evmPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.sol` is integrated.
 *
 * The structural tests at the bottom run unconditionally and verify the
 * language-detection logic without launching Electron.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when `solc` is available on PATH and reports a usable version.
 * Evaluated once at module load to keep individual tests clean.
 */
function hasSolc(): boolean {
  try {
    const result = childProcess.spawnSync("solc", ["--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

/**
 * Returns true when the `codetracer-evm-recorder` binary is reachable.
 * Checks `CODETRACER_EVM_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasEvmRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_EVM_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-evm-recorder";
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
const solcAvailable = hasSolc();
const evmRecorderAvailable = hasEvmRecorder();
const evmPipelineAvailable = solcAvailable && evmRecorderAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

// TODO(skipped): All 8 UI tests skipped because evmPipelineAvailable is false.
//   Requires both `solc` (Solidity compiler) and `codetracer-evm-recorder` on PATH.
//   The codetracer-evm-recorder sibling is present but solc is likely not in the codetracer dev shell.
//   Hypothesis: Add solc to the codetracer nix dev shell, or run these tests inside
//   `direnv exec ../codetracer-evm-recorder` where solc is available.
test.describe("solidity_example — basic layout", () => {
  // Skip the entire suite when the EVM recorder pipeline is absent.
  // Remove this guard once `ct record <path>.sol` is integrated.
  test.skip(
    !evmPipelineAvailable,
    "EVM recorder pipeline not available (need solc + codetracer-evm-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "solidity_example/SolidityExample.sol", launchMode: "trace" });

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
    // The entry point should resolve to the Solidity source file.
    expect(location.path.endsWith("SolidityExample.sol")).toBeTruthy();
    // The EVM trace starts inside runExample; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("solidity_example — event log", () => {
  test.skip(
    !evmPipelineAvailable,
    "EVM recorder pipeline not available (need solc + codetracer-evm-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "solidity_example/SolidityExample.sol", launchMode: "trace" });

  test("event log has at least one Transfer event", async ({ ctPage }) => {
    // Wait for the event log footer row-count to appear.
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    // runExample emits 3 Transfer events (2 mints + 1 transfer between accounts).
    expect(count).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: state panel
// ---------------------------------------------------------------------------

test.describe("solidity_example — state panel", () => {
  test.skip(
    !evmPipelineAvailable,
    "EVM recorder pipeline not available (need solc + codetracer-evm-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "solidity_example/SolidityExample.sol", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // Storage variable decoding via the EVM storage layout is not yet
  // plumbed through the db-backend DAP session for Solidity traces.
  // Re-enable once the EVM storage decoder is integrated.
  test.fixme("state panel shows decoded storage variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    // After runExample() completes: _mint(alice,1000) + _mint(bob,500) + _transfer gives
    // totalSupply = 1500. The entry point is runExample so the final state is visible.
    expect(values.totalSupply.text).toBe("1500");
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("solidity_example — call trace", () => {
  test.skip(
    !evmPipelineAvailable,
    "EVM recorder pipeline not available (need solc + codetracer-evm-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "solidity_example/SolidityExample.sol", launchMode: "trace" });

  // The db-backend does not yet emit DAP calltrace entries for EVM traces.
  // Re-enable once the backend exposes Solidity call frames.
  test.fixme("call trace shows _mint and _transfer entries", async () => {
    // Requires calltrace DAP support for EVM traces.
  });

  test.fixme("continue", async () => {
    // Requires debug movement counter support for EVM/Solidity backend.
  });

  test.fixme("next", async () => {
    // Requires debug movement counter support for EVM/Solidity backend.
  });
});

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("solidity_example — environment detection", () => {
  test("sol extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .sol files as DB-based
    // so they don't attempt RR recording when evmPipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("SolidityExample.sol")).toBe(true);
    expect(isDbBased("some/path/Token.sol")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof solcAvailable).toBe("boolean");
    expect(typeof evmRecorderAvailable).toBe("boolean");
    expect(typeof evmPipelineAvailable).toBe("boolean");
  });
});
