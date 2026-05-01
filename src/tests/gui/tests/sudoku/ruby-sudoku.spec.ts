import { test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Ruby Sudoku Solver (rb_sudoku_solver).
 * DB-based trace (not RR). Uses Ruby naming convention `ClassName#method`.
 *
 * For Ruby DB traces the Program State pane may not expose instance variables.
 * Variable visibility is verified via call trace arguments on `SudokuSolver#initialize`.
 *
 * Port of ui-tests/Tests/ProgramSpecific/RubySudokuTests.cs
 */
test.describe("RubySudoku", () => {
  test.use({
    sourcePath: "rb_sudoku_solver/sudoku_solver.rb",
    launchMode: "trace",
  });

  test("editor loads sudoku_solver.rb", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "sudoku_solver.rb");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  // FAILING (timing, 2026-05-01): see python-sudoku.spec.ts.  The
  // structural calltrace-loading gap that originally hid the user-
  // program calls is fixed; remaining flakes are caused by the
  // CalltraceVM autoLoad effect re-firing several times per
  // CtCompleteMove and clobbering the store mid-render.
  test("call trace navigation to SudokuSolver#solve", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(
      ctPage,
      "SudokuSolver#solve",
      "sudoku_solver.rb",
    );
  });

  // FAILING (2026-05-01): same auto-load re-render flake as the
  // previous test, plus the IsoNim calltrace view does not yet
  // render the per-argument `.call-arg` DOM elements that
  // CallTraceEntry.arguments() expects (it emits a static "()"
  // placeholder).  See TODO 5.2 in handoff.
  test("variable inspection board via call trace argument", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().dispatchEvent("click");

    const targetEntry = await callTrace.navigateToEntry(
      "SudokuSolver#initialize",
    );

    // Verify the initialize entry has a 'board' argument.
    await retry(
      async () => {
        const args = await targetEntry.arguments();
        for (const arg of args) {
          const name = await arg.name();
          if (name.toLowerCase() === "board") {
            return true;
          }
        }
        return false;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );
  });

  test("terminal output shows solved board", async ({ ctPage }) => {
    await helpers.assertTerminalOutputContains(ctPage, "1");
  });
});
