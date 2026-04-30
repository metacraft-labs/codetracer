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
// As of 2026-05-01 the Python recorder venv is healthy again (the
// "module not installed" error documented above is fixed). The two
// editor / event-log smoke tests pass.
//
// FAILING (3 of 5 tests as of 2026-05-01):
//   - "call trace navigation to solve_sudoku"
//   - "variable inspection board via call trace argument"
//   - "terminal output shows solved board" (90s timeout)
//
// All three depend on the calltrace pane populating before
// `navigateToEntry` runs. For Python DB traces the calltrace lines
// arrive slowly (the recorder is correct, the loader is slow), and
// `CallTracePane.waitForReady` exhausts its 60×1s budget before the
// first `.calltrace-call-line` row appears.
//
// TODO: speed up Python DB-trace calltrace loading (or raise the
// `waitForReady` budget specifically for Python). Two leads:
//   1. The IsoNim calltrace view already requests data via
//      `requestCalltraceSection` on each viewport / position change;
//      check whether the initial request fires before the editor is
//      ready, then refires unnecessarily after each position update.
//   2. The DB-backend may be batching event-log + calltrace into a
//      single response — splitting them would let calltrace become
//      visible while the (much larger) event-log keeps streaming.
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
    await callTrace.tabButton().dispatchEvent("click");

    const targetEntry = await callTrace.navigateToEntry("solve_sudoku");

    // Verify the solve_sudoku entry has a 'board' argument.
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
