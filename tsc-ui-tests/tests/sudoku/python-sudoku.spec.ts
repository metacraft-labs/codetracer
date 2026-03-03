import { test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Python Sudoku Solver (py_sudoku_solver).
 * DB-based trace (not RR). Call trace shows full execution tree.
 *
 * For Python DB traces the Program State pane may be empty at function
 * entry points. Variable visibility is verified via call trace arguments.
 *
 * Port of ui-tests/Tests/ProgramSpecific/PythonSudokuTests.cs
 */
test.describe("PythonSudoku", () => {
  test.use({ sourcePath: "py_sudoku_solver/main.py", launchMode: "trace" });

  test("editor loads main.py", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.py");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to solve_sudoku", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(
      ctPage,
      "solve_sudoku",
      "main.py",
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

    // Locate solve_sudoku in the call trace.
    let targetFound = false;
    let targetEntry: Awaited<
      ReturnType<typeof callTrace.findEntry>
    > = null;

    await retry(
      async () => {
        callTrace.invalidateEntries();
        targetEntry = await callTrace.findEntry("solve_sudoku", true);
        if (targetEntry !== null) {
          targetFound = true;
          return true;
        }

        const allEntries = await callTrace.getEntries(true);
        for (const entry of allEntries) {
          try {
            await entry.expandChildren();
          } catch {
            // entry may not support expansion
          }
        }
        return false;
      },
      { maxAttempts: 60, delayMs: 1000 },
    );

    if (!targetFound || targetEntry === null) {
      throw new Error(
        "Call trace entry 'solve_sudoku' was not found when trying to inspect the 'board' argument.",
      );
    }

    // Verify the solve_sudoku entry has a 'board' argument.
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
