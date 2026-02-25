import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the D Sudoku Solver (d_sudoku_solver).
 * RR-based trace. D runtime (LDC) shows entrypoint.d at initial position.
 *
 * Port of ui-tests/Tests/ProgramSpecific/DSudokuTests.cs
 */
test.describe("DSudoku", () => {
  test.skip(!process.env.CODETRACER_RR_BACKEND_PRESENT, "requires ct-rr-support");
  test.setTimeout(900_000);
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

  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
