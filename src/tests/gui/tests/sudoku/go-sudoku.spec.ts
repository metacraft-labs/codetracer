import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Go Sudoku Solver (go_sudoku_solver).
 * RR-based trace with `main.main` as entry point (Go fully-qualified).
 *
 * Port of ui-tests/Tests/ProgramSpecific/GoSudokuTests.cs
 */
test.describe("GoSudoku", () => {
  test.use({ sourcePath: "go_sudoku_solver/sudoku.go", launchMode: "trace" });

  test("editor loads sudoku.go", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "sudoku.go");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main.main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main.main", "sudoku.go");
  });

  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
