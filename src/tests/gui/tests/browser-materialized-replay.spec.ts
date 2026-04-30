/**
 * Playwright E2E test for browser-based materialized (DB) trace replay.
 *
 * Verifies that a Python program traced via the standard recording
 * infrastructure can be replayed in the browser via `ct host`
 * (deploymentMode: "web"). This exercises the VFS-backed trace loading
 * path where trace data is loaded into the in-memory VFS and processed
 * by the WASM DAP server, bypassing filesystem access entirely.
 *
 * Uses `py_sudoku_solver/main.py` — a DB-based trace (not MCR/rr).
 * This mirrors `browser-mcr-replay.spec.ts` but for materialized traces.
 */

import { test } from "../lib/fixtures";
import * as helpers from "../lib/language-smoke-test-helpers";

test.describe("browser-materialized-replay — browser web mode for Python DB trace", () => {
  test.use({
    sourcePath: "py_sudoku_solver/main.py",
    launchMode: "trace",
    deploymentMode: "web",
  });

  // FAILING: 2026-04-30 (entire describe block) — the equivalent
  // C-trace web-mode tests (`browser-mcr-replay.spec.ts`) pass cleanly
  // for editor + event log, so the bug is specific to the Python DB
  // trace pipeline running through `ct host`. Fail mode: the editor
  // shell loads but `assertEditorLoadsFile` hits its timeout because
  // the trace bytes are loaded into the in-memory VFS but the WASM
  // DAP server never publishes a `loaded`/`stopped` event back to the
  // renderer for DB traces — Monaco never receives main.py contents.
  // The same trace replays fine in the native Electron path
  // (sudoku/python-sudoku.spec.ts records and replays it locally).
  // TODO: trace the WASM `replay-server` boot path for DB traces in
  // `src/db-backend/src/wasm.rs` / `dap_server.rs`. The `setup() ->
  // run_to_entry() -> complete_move()` sequence runs for `.ct` traces
  // (browser-mcr-replay passes); for materialized DB traces the same
  // sequence either is not invoked or its events do not propagate
  // through the WebSocket bridge. Compare the launch handler against
  // the MCR path and add the missing `complete_move()` emission.
  test("editor loads main.py", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.py");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to solve_sudoku", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(
      ctPage,
      "solve_sudoku",
      "main.py",
    );
  });
});
