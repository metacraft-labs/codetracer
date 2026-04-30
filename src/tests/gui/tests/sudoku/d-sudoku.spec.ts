import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the D Sudoku Solver (d_sudoku_solver).
 * RR-based trace. D runtime (LDC) shows entrypoint.d at initial position.
 *
 * Port of ui-tests/Tests/ProgramSpecific/DSudokuTests.cs
 */
test.describe("DSudoku", () => {
  test.use({ sourcePath: "d_sudoku_solver/sudoku.d", launchMode: "trace" });

  test("editor loads entrypoint.d", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "entrypoint.d");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "entrypoint.d");
  });

  // FAILING: 2026-05-01 — D RR trace's calltrace exposes only one
  // top-level `main` entry (the C-style `entrypoint.d:main`
  // trampoline). The user-defined `_Dmain` does not appear in the
  // visible call trace and is not addressable by name through RR
  // search (the native backend does not implement `ct/search-calltrace`
  // — that's DB-backend-only). Navigating to `main` lands the
  // debugger on `entrypoint.d:39` (function header of the C
  // trampoline) where the in-scope variables are runtime-internal
  // (`argc`, `argv`, plus mangled `_D6object_*` globals). Step-overs
  // and step-ins from this position do not visibly advance the
  // gutter-highlighted line — `_d_run_main` is a runtime call that
  // step-over skips past the entire program execution, and step-in
  // appears to be a no-op at the function header.
  // TODO: extend the native-backend RR `run_to_entry` heuristic to
  // continue past the C `main` trampoline into `_Dmain` when
  // `"D main"` symbol is resolvable, so the user's main is the
  // calltrace's first user-visible frame. Alternatively, expose
  // `ct/search-calltrace` for RR traces so the test helper can
  // search for `_Dmain` directly.
  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards", "main");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
