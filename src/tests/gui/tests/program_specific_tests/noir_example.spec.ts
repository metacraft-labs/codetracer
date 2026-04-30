import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar, } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";

const ENTRY_LINE = 17;

// Each describe block gets its own fixture scope (each test records + launches independently).

test.describe("noir example — basic layout", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "noir_example/", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    // In browser mode the page title includes the trace name (e.g.
    // "CodeTracer | Trace 42: noir_example"), so use toContain instead of toBe.
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const simpleLocation = await statusBar.location();
    expect(simpleLocation.path.endsWith("main.nr")).toBeTruthy();
    expect(simpleLocation.line).toBe(ENTRY_LINE);
  });
});

test.describe("noir example — state and navigation", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "noir_example/", launchMode: "trace" });

  // FAILING: 2026-04-30 — `loadedEventLog` waits 30s and times out
  // because the event log footer never reports a non-zero row count
  // for noir DB traces. Trace recording is fast (~170ms), Electron
  // launches fine, but the DataTables footer counter stays at 0 — the
  // same symptom the wasm_example "expected event count" test
  // documents (see test.fixme there).
  // TODO: The DB-trace event-log population path doesn't update the
  // `.data-tables-footer-rows-count` element for noir/wasm. Find where
  // the footer is updated for RR-based traces (likely in `event_log.nim`
  // / `eventLogAfterRedraws`) and ensure the same code runs after the
  // DB-trace event load handler in the IsoNim event_log_view too.
  test("expected event count", async ({ ctPage }) => {
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );

    // The noir_example program executes several events (println, assert).
    // Verify at least one event is recorded rather than hardcoding a count
    // that can change with nargo/debugger version updates.
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });

  // FAILING: 2026-04-30 — `readyOnEntry` waits up to 30s for
  // `.location-path` to appear in the status bar. For noir DB traces
  // the status bar never receives the entry-point location, so the
  // helper times out. The trace itself is recorded successfully and
  // Electron launches; the missing piece is the StatusBar path
  // update for DB traces (RR traces work fine in the same suite).
  // TODO: investigate the entry-point status update for DB traces in
  // `status.nim` / the StatusBar component. Likely conditioned on RR
  // tick events that DB traces never emit. The fix is to also update
  // the status bar from `CtCompleteMove` events (which DB traces do
  // emit) on initial load.
  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText("17 | ");
  });

  // TODO(skipped): The noir DB-based debugger does not expose local variables in the state
  //   panel when running in browser mode. Variables x, y are expected but not present.
  //   Hypothesis: nargo trace output does not include variable inspection data in browser mode.
  //   Re-enable once nargo trace support includes variable inspection.
  test.fixme("state panel supports integer values", async ({ ctPage }) => {
    // await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);

    const values = await statePanel.values();
    expect(values.x.text).toBe("0");
    expect(values.x.typeText).toBe("Field");

    expect(values.y.text).toBe("1");
    expect(values.y.typeText).toBe("Field");
  });

  // TODO(skipped): Debug movement (continue/next) does not work for noir traces in browser mode.
  //   The backend does not implement the `.test-movement` counter that the test helpers rely on.
  //   Hypothesis: The noir db-backend needs to emit a movement counter (or CtCompleteMove event)
  //   after each continue/next operation so the test can detect when the step has completed.
  test.fixme("continue", async () => {
    // Requires debug movement counter support in noir backend.
  });

  // TODO(skipped): Same as "continue" above -- debug movement counter not implemented for noir.
  //   Hypothesis: Needs CtCompleteMove event support in the noir db-backend.
  test.fixme("next", async () => {
    // Requires debug movement counter support in noir backend.
  });
});
