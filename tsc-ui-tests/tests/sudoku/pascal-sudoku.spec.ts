import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Pascal Sudoku Solver (pascal_sudoku_solver).
 * RR-based trace with `$main` as entry point (Free Pascal convention).
 *
 * Port of ui-tests/Tests/ProgramSpecific/PascalSudokuTests.cs
 */
test.describe("PascalSudoku", () => {
  test.skip(!process.env.CODETRACER_RR_BACKEND_PRESENT, "requires ct-rr-support");
  test.setTimeout(900_000);
  test.use({
    sourcePath: "pascal_sudoku_solver/sudoku.pas",
    launchMode: "trace",
  });

  test("editor loads sudoku.pas", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "sudoku.pas");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to $main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "$main", "sudoku.pas");
  });

  test("variable inspection boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
