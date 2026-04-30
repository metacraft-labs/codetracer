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

  // FAILING: 2026-04-30 — `assertFlowValueVisible` clicks
  // `#next-debug` to step past the entry point so flow annotations
  // appear; under Xvfb the jstree filesystem panel intercepts the
  // pointer event ("jstree-icon jstree-themeicon ... intercepts pointer
  // events"). The same failure mode hits every sudoku variant that
  // depends on stepping (D, Go, Rust, Nim, Python, Ruby).
  // TODO: harden the helper by adding a `force: true` retry pass to
  // `nextDebugButton.click()` (or equivalent) inside
  // `assertFlowValueVisible`. The CallTracePane.clickTab page object
  // already implements this fallback; mirror the pattern there.
  test("variable inspection testBoards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "testBoards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
