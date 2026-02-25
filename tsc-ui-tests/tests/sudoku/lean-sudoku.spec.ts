import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Lean Sudoku Solver (lean_sudoku_solver).
 * RR-based trace with very limited LLDB support (compiled through C/LLVM).
 *
 * No editor tab, no call trace entries, no flow values, no state variables
 * at the initial RR position. All tests fall back to event log verification.
 *
 * Port of ui-tests/Tests/ProgramSpecific/LeanSudokuTests.cs
 */
test.describe("LeanSudoku", () => {
  test.use({ sourcePath: "lean_sudoku_solver/Main.lean", launchMode: "trace" });

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
