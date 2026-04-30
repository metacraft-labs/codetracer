/**
 * Benchmark: Progressive panel loading times.
 *
 * Measures how long each GUI panel takes to load after opening a trace replay.
 * The key insight is that with the seek-based reader, the backend returns only
 * what each panel needs -- it should NOT need to load the full trace. So panel
 * population should be fast.
 *
 * Measured panels:
 *   - Editor panel: source code loaded in Monaco (view-lines visible)
 *   - Call trace panel: at least one call tree entry rendered
 *   - Event log panel: at least one IO event row rendered
 *   - Program state panel: at least one variable entry rendered
 *   - Status location: location path (file:line#step) shown in status bar
 *
 * Output format: JSON array compatible with github-action-benchmark:
 *   [{ "name": "...", "unit": "ms", "value": <number> }, ...]
 *
 * The test uses py_console_logs as the trace fixture -- it is a small program
 * with multiple function calls, console output, and local variables.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { debugLogger } from "../../lib/debug-logger";

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/**
 * Maximum acceptable time (ms) for any individual panel to populate after
 * the trace window is open. This is deliberately generous for CI; the real
 * goal is to track the numbers over time via the benchmark output.
 */
const PANEL_LOAD_LIMIT_MS = 45_000;

/**
 * Stricter per-panel target (ms) used for informational reporting.
 * Panels exceeding this are flagged as SLOW but do not fail the test,
 * since recording + Electron startup dominate the wall clock.
 * The interesting metric is the *delta* between the first and last panel.
 */
const PANEL_TARGET_MS = 5_000;

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Panel loading times", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("measure progressive panel loading after trace open", async ({
    ctPage,
  }) => {
    const timings: Record<string, number> = {};

    // -----------------------------------------------------------------------
    // Baseline: wait for the trace to register in the document title.
    // This is the earliest signal that the frontend has connected to the
    // backend and received trace metadata.
    // -----------------------------------------------------------------------
    const layout = new LayoutPage(ctPage);
    const traceStart = Date.now();

    await layout.waitForTraceLoaded();
    timings["trace_metadata_loaded"] = Date.now() - traceStart;
    debugLogger.log(
      `Benchmark: trace metadata loaded in ${timings["trace_metadata_loaded"]}ms`,
    );

    // -----------------------------------------------------------------------
    // Measure each panel independently. We start a fresh timer from the
    // trace-loaded baseline so that recording time is excluded.
    // -----------------------------------------------------------------------
    const panelStart = Date.now();

    // -- Editor panel: Monaco view-lines visible --
    // The editor component container appears first, then Monaco populates
    // the .view-lines with actual source code lines.
    await layout.waitForEditorLoaded();
    await retry(
      async () => {
        const editors = await layout.editorTabs(true);
        if (editors.length === 0) return false;
        // Check that Monaco has rendered at least one view-line with content
        const lineCount = await editors[0].lineElements().count();
        return lineCount > 0;
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    timings["editor_loaded"] = Date.now() - panelStart;
    debugLogger.log(`Benchmark: editor loaded in ${timings["editor_loaded"]}ms`);

    // -- Call trace panel: at least one calltrace-call-line visible --
    await layout.waitForCallTraceLoaded();
    const callTraces = await layout.callTraceTabs(true);
    if (callTraces.length > 0) {
      await callTraces[0].waitForReady();
    }
    timings["call_trace_loaded"] = Date.now() - panelStart;
    debugLogger.log(
      `Benchmark: call trace loaded in ${timings["call_trace_loaded"]}ms`,
    );

    // -- Event log panel: at least one event row visible --
    await layout.waitForEventLogLoaded();
    const eventLogs = await layout.eventLogTabs(true);
    if (eventLogs.length > 0) {
      await retry(
        async () => {
          const events = await eventLogs[0].eventElements(true);
          return events.length > 0;
        },
        { maxAttempts: 60, delayMs: 500 },
      );
    }
    timings["event_log_loaded"] = Date.now() - panelStart;
    debugLogger.log(
      `Benchmark: event log loaded in ${timings["event_log_loaded"]}ms`,
    );

    // -- Program state (variables) panel: at least one .value-expanded --
    // Variables may be empty at the initial entry point for Python DB traces.
    // We check that the component itself is mounted; if variables are present
    // that is a bonus.
    await layout.waitForStateLoaded();
    const statePanes = await layout.programStateTabs(true);
    let variableCount = 0;
    if (statePanes.length > 0) {
      // Give the state pane a short window to populate variables.
      // If none appear within 3 seconds, record the time anyway -- the
      // component being mounted is the primary signal.
      try {
        await retry(
          async () => {
            const vars = await statePanes[0].programStateVariables(true);
            variableCount = vars.length;
            return vars.length > 0;
          },
          { maxAttempts: 6, delayMs: 500 },
        );
      } catch {
        // Variables may legitimately be empty at the entry point.
        debugLogger.log(
          "Benchmark: program state component loaded but no variables visible (expected at entry)",
        );
      }
    }
    timings["program_state_loaded"] = Date.now() - panelStart;
    debugLogger.log(
      `Benchmark: program state loaded in ${timings["program_state_loaded"]}ms (${variableCount} variable(s))`,
    );

    // -- Status location: the .location-path element shows file:line#step --
    // This indicates the debugger has completed its initial move.
    await retry(
      async () => {
        const locationEl = ctPage.locator(".location-path");
        const count = await locationEl.count();
        if (count === 0) return false;
        const text = (await locationEl.textContent()) ?? "";
        // A populated location looks like "path/file.py:10#1234"
        return text.includes("#") && text.includes(":");
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    timings["status_location_loaded"] = Date.now() - panelStart;
    debugLogger.log(
      `Benchmark: status location loaded in ${timings["status_location_loaded"]}ms`,
    );

    // -----------------------------------------------------------------------
    // Also measure the "all components loaded" aggregate for comparison
    // -----------------------------------------------------------------------
    timings["all_panels_loaded"] = Date.now() - panelStart;

    // -----------------------------------------------------------------------
    // Output: JSON array for github-action-benchmark consumption
    // -----------------------------------------------------------------------
    const benchmarkResults = [
      {
        name: "panel_trace_metadata",
        unit: "ms",
        value: timings["trace_metadata_loaded"],
      },
      { name: "panel_editor", unit: "ms", value: timings["editor_loaded"] },
      {
        name: "panel_call_trace",
        unit: "ms",
        value: timings["call_trace_loaded"],
      },
      {
        name: "panel_event_log",
        unit: "ms",
        value: timings["event_log_loaded"],
      },
      {
        name: "panel_program_state",
        unit: "ms",
        value: timings["program_state_loaded"],
      },
      {
        name: "panel_status_location",
        unit: "ms",
        value: timings["status_location_loaded"],
      },
      {
        name: "panel_all_loaded",
        unit: "ms",
        value: timings["all_panels_loaded"],
      },
    ];

    // Print the JSON on a single line, prefixed with a marker so CI can
    // extract it from the test output.
    console.log(
      `BENCHMARK_RESULTS: ${JSON.stringify(benchmarkResults)}`,
    );

    // -----------------------------------------------------------------------
    // Informational: flag slow panels (does not fail the test)
    // -----------------------------------------------------------------------
    for (const [panel, ms] of Object.entries(timings)) {
      const status =
        ms > PANEL_LOAD_LIMIT_MS
          ? "EXCEEDED"
          : ms > PANEL_TARGET_MS
            ? "SLOW"
            : "ok";
      console.log(
        `# benchmark: ${panel}: ${ms}ms (target: ${PANEL_TARGET_MS}ms) [${status}]`,
      );
    }

    // -----------------------------------------------------------------------
    // Assertions: each panel must load within the generous limit.
    // The real regression detection happens in CI via benchmark comparison,
    // but we still want a hard upper bound to catch catastrophic regressions.
    // -----------------------------------------------------------------------
    for (const [panel, ms] of Object.entries(timings)) {
      expect(
        ms,
        `${panel} took ${ms}ms which exceeds the ${PANEL_LOAD_LIMIT_MS}ms limit`,
      ).toBeLessThan(PANEL_LOAD_LIMIT_MS);
    }

    // -----------------------------------------------------------------------
    // Progressive loading check: the spread between the first and last panel
    // should be reported. A large spread means panels are loading sequentially
    // rather than progressively.
    // -----------------------------------------------------------------------
    const panelTimingsOnly = Object.entries(timings).filter(
      ([key]) => key !== "trace_metadata_loaded" && key !== "all_panels_loaded",
    );
    const values = panelTimingsOnly.map(([, v]) => v);
    const fastest = Math.min(...values);
    const slowest = Math.max(...values);
    const spread = slowest - fastest;
    console.log(
      `# benchmark: panel spread: ${spread}ms (fastest: ${fastest}ms, slowest: ${slowest}ms)`,
    );
    console.log(
      `BENCHMARK_RESULTS_SPREAD: ${JSON.stringify({ name: "panel_loading_spread", unit: "ms", value: spread })}`,
    );
  });
});
