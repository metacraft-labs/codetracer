import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Rust Sudoku Solver (rs_sudoku_solver).
 * RR-based trace with `main::main` as entry point (module-qualified).
 *
 * Port of ui-tests/Tests/ProgramSpecific/RustSudokuTests.cs
 */
test.describe("RustSudoku", () => {
  test.setTimeout(900_000);
  test.use({ sourcePath: "rs_sudoku_solver/main.rs", launchMode: "trace" });

  test("editor loads main.rs", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.rs");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main::main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main::main", "main.rs");
  });

  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
