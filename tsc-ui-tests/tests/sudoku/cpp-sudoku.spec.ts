import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the C++ Sudoku Solver (cpp_sudoku_solver).
 * RR-based trace with `main` as entry point.
 *
 * Port of ui-tests/Tests/ProgramSpecific/CppSudokuTests.cs
 */
test.describe("CppSudoku", () => {
  test.use({ sourcePath: "cpp_sudoku_solver/main.cpp", launchMode: "trace" });

  test("editor loads main.cpp", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.cpp");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "main.cpp");
  });

  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
