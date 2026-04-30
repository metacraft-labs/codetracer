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

  // FAILING: 2026-05-01 — calltrace navigation to `main.main` lands
  // the debugger on line 78 (`func main() {` — the function header
  // of `main.main`), where Go's RR backend exposes zero local
  // variables (state pane shows "No local variables are present in
  // the current point of execution.") and step-overs from this
  // position do not visibly advance the gutter-highlighted line.
  // The trace successfully navigates the editor to `sudoku.go` (test
  // 3 above passes), but `testBoards` (declared on line 82) remains
  // out of scope.
  // TODO: investigate why RR step-over from a Go function-header
  // line (with no expression on it) is a no-op. Likely the
  // db-backend / native-backend dap step handler needs Go-specific
  // handling: at a function header, skip to the first executable
  // line of the body. See codetracer-native-backend run_to_entry's
  // language heuristics for an existing pattern.
  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards", "main.main");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
