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

  // FAILING: 2026-05-01 — Go RR trace's initial position has zero
  // flow annotations rendered (likely `runtime.main` / `runtime.rt0_go`
  // chain in Go's startup). Editor loads `sudoku.go` (test 1 passes)
  // but `assertFlowValueVisible`'s 5 step-overs don't descend into
  // user `main.main` where `testBoards` is in scope.
  // TODO: extend `assertFlowValueVisible` to accept an optional
  // `functionName` argument and navigate via the call trace first
  // (mirroring `assertVariableVisible`). See handoff TODO 5.1(c).
  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
