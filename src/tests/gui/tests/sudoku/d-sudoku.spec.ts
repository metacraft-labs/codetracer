import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the D Sudoku Solver (d_sudoku_solver).
 * RR-based trace.  After commit d04b78de@codetracer-native-backend
 * (TODO 5.2(j)), `run_to_entry` skips past the C-style trampoline
 * in entrypoint.d and stops at the user-defined `_Dmain` inside
 * sudoku.d, so the editor and call trace expose user code from the
 * very first frame.
 *
 * Port of ui-tests/Tests/ProgramSpecific/DSudokuTests.cs
 */
test.describe("DSudoku", () => {
  test.use({ sourcePath: "d_sudoku_solver/sudoku.d", launchMode: "trace" });

  test("editor loads sudoku.d", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "sudoku.d");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "sudoku.d");
  });

  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards", "main");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
