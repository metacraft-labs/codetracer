import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Pascal Sudoku Solver (pascal_sudoku_solver).
 * RR-based trace with `$main` as entry point (Free Pascal convention).
 *
 * Port of ui-tests/Tests/ProgramSpecific/PascalSudokuTests.cs
 *
 * The rest of this suite (editor, event log, call trace, output) is the
 * scenario `src/tests/scenarios/languages/pascal-sudoku.yaml`. The flow value stays here: no flow
 * value is drawn yet: the flow renderer fails on main's nested loops (codetracer-pm
 * issues/2026-11-14-the-flow-renderer-fails-on-the-pascal-sudoku-mains-nested-loops.md).
 */
test.describe("PascalSudoku", () => {
  test.use({
    sourcePath: "pascal_sudoku_solver/sudoku.pas",
    launchMode: "trace",
  });

  test("variable inspection boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "boards");
  });
});
