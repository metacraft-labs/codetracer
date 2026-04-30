/**
 * Playwright UI tests for the Stylus (Arbitrum) example.
 *
 * These tests verify that the CodeTracer UI renders a Stylus/WASM trace
 * correctly, covering:
 *   - Editor pane loading the .rs source file (Rust compiled to WASM for Arbitrum)
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with transaction events
 *   - Call trace pane showing the Stylus call tree
 *
 * ## Prerequisites
 *
 * Stylus tracing has a unique workflow that differs from other languages:
 *   1. A local Arbitrum devnode must be running (`run-nitro-devnode`)
 *   2. The contract must be deployed via `ct arb deploy`
 *   3. Transactions must be sent via `cast send`
 *   4. Traces are viewed via `ct arb explorer`
 *
 * Because this workflow requires running infrastructure (devnode + deployment),
 * all tests are skipped unless the full Stylus pipeline is available.
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

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * The default Arbitrum devnode RPC endpoint.
 * Override with `STYLUS_RPC_URL` to point at a custom endpoint.
 */
const STYLUS_RPC_URL = process.env.STYLUS_RPC_URL ?? "http://localhost:8547";

/**
 * Returns true when the Stylus pipeline tools and infrastructure are available.
 * Requires `cast` (Foundry), `cargo-stylus`, and a running Arbitrum devnode.
 */
function hasStylusPipeline(): boolean {
  try {
    // Check for `cast` (Foundry tool for sending transactions).
    const castResult = childProcess.spawnSync("cast", ["--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    if (castResult.status !== 0) return false;

    // Check for `cargo-stylus` (Stylus CLI for building/deploying).
    const stylusResult = childProcess.spawnSync("cargo", ["stylus", "--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    if (stylusResult.status !== 0) return false;

    // Check that the Arbitrum devnode is actually running.  Without a live
    // devnode, contract deployment and transaction recording are impossible.
    // We probe the JSON-RPC endpoint with `cast chain-id`.
    const devnodeResult = childProcess.spawnSync(
      "cast",
      ["chain-id", "--rpc-url", STYLUS_RPC_URL],
      { encoding: "utf-8", timeout: 5_000 },
    );
    return devnodeResult.status === 0;
  } catch {
    return false;
  }
}

// Evaluated at collection time so skip decisions are instant.
const stylusPipelineAvailable = hasStylusPipeline();

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

// TODO(skipped): All 8 UI tests skipped because stylusPipelineAvailable is false.
//   Stylus tracing requires Foundry (cast), cargo-stylus, AND a running Arbitrum devnode.
//   The `cast chain-id --rpc-url http://localhost:8547` check fails because no devnode is running.
//   Hypothesis: These tests can only run in an environment with the full Stylus infrastructure
//   (devnode + deployed contract). Consider a CI workflow that starts a devnode before running tests,
//   or provide pre-recorded trace fixtures.
test.describe("stylus_example — basic layout", () => {
  // Stylus tests require a running devnode, deployed contract, and recorded
  // transactions. Skip unless the full pipeline is available and a trace
  // has been pre-recorded.
  test.skip(
    !stylusPipelineAvailable,
    "Stylus pipeline not available (need cast + cargo-stylus + running devnode)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "stylus_fund_tracker/", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    // Stylus contracts are Rust source files.
    expect(location.path.endsWith(".rs")).toBeTruthy();
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("stylus_example — event log", () => {
  test.skip(
    !stylusPipelineAvailable,
    "Stylus pipeline not available (need cast + cargo-stylus + running devnode)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "stylus_fund_tracker/", launchMode: "trace" });

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

test.describe("stylus_example — state panel", () => {
  test.skip(
    !stylusPipelineAvailable,
    "Stylus pipeline not available (need cast + cargo-stylus + running devnode)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "stylus_fund_tracker/", launchMode: "trace" });

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
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("stylus_example — call trace", () => {
  test.skip(
    !stylusPipelineAvailable,
    "Stylus pipeline not available (need cast + cargo-stylus + running devnode)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "stylus_fund_tracker/", launchMode: "trace" });

  test("call trace shows function entry", async ({ ctPage }) => {
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

test.describe("stylus_example — environment detection", () => {
  // Stylus source files are .rs (Rust) compiled to wasm32-unknown-unknown.
  // The .rs extension is NOT DB-based; Stylus uses a separate deployment
  // and tracing workflow via `ct arb deploy` / `ct arb explorer`.
  test("rs extension is NOT classified as DB-based (Stylus uses pipeline detection)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    // .rs files are RR-based (native Rust); Stylus detection is separate.
    expect(isDbBased("fund_tracker.rs")).toBe(false);
    expect(isDbBased("some/path/contract.rs")).toBe(false);
    // Sanity-check: DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof stylusPipelineAvailable).toBe("boolean");
  });
});
