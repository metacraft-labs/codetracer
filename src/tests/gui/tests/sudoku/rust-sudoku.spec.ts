import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Rust Sudoku Solver (rs_sudoku_solver).
 * RR-based trace with `main::main` as entry point (module-qualified).
 *
 * Port of ui-tests/Tests/ProgramSpecific/RustSudokuTests.cs
 *
 * The rest of this suite (editor, event log, call trace, output) is the
 * scenario `src/tests/scenarios/languages/rust-sudoku.yaml`. The flow value stays here: no flow
 * value is drawn in main on an rr recording (codetracer-pm
 * issues/2026-11-13-rr-rust-and-pascal-sudoku-show-no-flow-values-at-main.md).
 */
test.describe("RustSudoku", () => {
  test.use({ sourcePath: "rs_sudoku_solver/main.rs", launchMode: "trace" });

  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });
});
