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
// As of 2026-05-01 the Python recorder venv is healthy again. The
// editor / event-log smoke tests pass.
//
// FAILING (3 of 5 tests as of 2026-05-01):
//   - "call trace navigation to solve_sudoku" — after CtCalltraceJump
//     the loaded section is anchored INSIDE solve_sudoku's body, so
//     the visible entries are children (`_box_index #0/#1/...`).
//     `findEntry("solve_sudoku")` returns null and `navigateToEntry`
//     falls back to the first child as a proxy; the editor-tab
//     retry then times out.  See TODO 5.1(a) — fix is recorder-side
//     (widen the response window upward to include the parent call)
//     OR test-side (recognise "search jumped me into the body" via
//     debugger location).
//   - "variable inspection board via call trace argument" — same
//     navigation issue PLUS missing `.call-arg` rendering — IsoNim
//     view emits "()" instead of per-arg DOM elements; see TODO 5.2(l).
//   - "terminal output shows solved board" — terminal pane never gets
//     populated for this DB trace; separate from calltrace.
//
// Structural calltrace fixes already in place (kept here for reference
// because the failure mode is now distinct):
//   * caa8155d (1.14): `syncCalltraceData` passes the backend's
//     `startCallLineIndex` instead of 0; IsoNim WebRenderer renders
//     the FULL store window; autoLoad expands totalHeight to
//     totalCallsCount once it is known.
//   * 27dcef26 (1.15): the entire CtCompleteMove fan-out is now
//     wrapped in an `isonim/core/batch.batch`, so the autoLoad effect
//     fires ONCE per move with coherent params.  Verified via
//     `[PIPELINE] CalltraceVM.autoLoad` log entries.
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
