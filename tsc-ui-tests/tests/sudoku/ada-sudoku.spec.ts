import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Ada Sudoku Solver (ada_sudoku_solver).
 * RR-based trace with limited LLDB Ada support (GNAT/GCC-based).
 *
 * Language detected as C, no editor tab, no call trace, no flow values,
 * no state variables at the initial RR position. All tests fall back to
 * event log verification.
 *
 * Port of ui-tests/Tests/ProgramSpecific/AdaSudokuTests.cs
 */
test.describe("AdaSudoku", () => {
  test.setTimeout(900_000);
  test.use({ sourcePath: "ada_sudoku_solver/sudoku.adb", launchMode: "trace" });

  test("editor loads (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("variable inspection (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("output (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });
});
