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
