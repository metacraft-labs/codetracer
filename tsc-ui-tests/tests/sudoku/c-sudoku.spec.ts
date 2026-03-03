import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the C Sudoku Solver (c_sudoku_solver).
 * RR-based trace with `main` as entry point.
 *
 * Port of ui-tests/Tests/ProgramSpecific/CSudokuTests.cs
 */
test.describe("CSudoku", () => {
  test.skip(!process.env.CODETRACER_RR_BACKEND_PRESENT, "requires ct-rr-support");
  test.setTimeout(900_000);
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("editor loads main.c", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.c");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "main.c");
  });

  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
