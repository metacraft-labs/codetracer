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

  test("call trace navigation to SudokuSolver#solve", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(
      ctPage,
      "SudokuSolver#solve",
      "sudoku_solver.rb",
    );
  });

  test("variable inspection board via call trace argument", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().click();
    callTrace.invalidateEntries();

    // Locate SudokuSolver#initialize in the call trace.
    let targetFound = false;
    let targetEntry: Awaited<
      ReturnType<typeof callTrace.findEntry>
    > = null;

    await retry(
      async () => {
        callTrace.invalidateEntries();
        targetEntry = await callTrace.findEntry(
          "SudokuSolver#initialize",
          true,
        );
        if (targetEntry !== null) {
          targetFound = true;
          return true;
        }

        const allEntries = await callTrace.getEntries(true);
        for (const entry of allEntries) {
          try {
            await entry.expandChildren();
          } catch {
            // entry not in viewport
          }
        }
        return false;
      },
      { maxAttempts: 60, delayMs: 1000 },
    );

    if (!targetFound || targetEntry === null) {
      throw new Error(
        "Call trace entry 'SudokuSolver#initialize' was not found when trying to inspect the 'board' argument.",
      );
    }

    // Verify the initialize entry has a 'board' argument.
    await retry(
      async () => {
        const args = await targetEntry!.arguments();
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
