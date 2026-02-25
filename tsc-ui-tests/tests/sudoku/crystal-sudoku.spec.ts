import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Crystal Sudoku Solver (crystal_sudoku_solver).
 * RR-based trace. Crystal runtime wraps user code in `main` (crystal/main.cr).
 *
 * Port of ui-tests/Tests/ProgramSpecific/CrystalSudokuTests.cs
 */
test.describe("CrystalSudoku", () => {
  test.setTimeout(900_000);
  test.use({
    sourcePath: "crystal_sudoku_solver/sudoku.cr",
    launchMode: "trace",
  });

  test("editor loads main.cr", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.cr");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "main.cr");
  });

  test("variable inspection status", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "status");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
