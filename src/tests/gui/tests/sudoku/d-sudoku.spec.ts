import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the D Sudoku Solver (d_sudoku_solver).
 * RR-based trace. D runtime (LDC) shows entrypoint.d at initial position.
 *
 * Port of ui-tests/Tests/ProgramSpecific/DSudokuTests.cs
 */
test.describe("DSudoku", () => {
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

  // FAILING: 2026-05-01 — D RR trace lands at `entrypoint.d` (D's
  // `extern(C) main` runtime trampoline). Flow annotations DO render
  // there, but the variables in scope are `argc`, `argv`, `_Dmain` —
  // not the user-program `testBoards` defined inside `_Dmain`.
  // `assertFlowValueVisible`'s 5 step-overs aren't enough to descend
  // through D's runtime into user code.
  // TODO: extend `assertFlowValueVisible` to accept an optional
  // `functionName` argument and navigate via the call trace first
  // (mirroring `assertVariableVisible`), then check the flow / state
  // pane. See handoff TODO 5.1(c).
  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
