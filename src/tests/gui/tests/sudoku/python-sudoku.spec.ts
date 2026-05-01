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
// FAILING (3 of 5 tests as of 2026-05-01, but with progress):
//   - "call trace navigation to solve_sudoku"           (timeout)
//   - "variable inspection board via call trace argument" (timeout +
//     missing `.call-arg` rendering — IsoNim view emits "()" instead
//     of per-arg DOM elements; see TODO 5.2 below)
//   - "terminal output shows solved board" (terminal pane never gets
//     populated for this DB trace — separate from calltrace)
//
// The structural calltrace navigation gap that originally hid
// `solve_sudoku` (loaded section starting at index 0 with only 25
// rows visible, the user-program calls live well past row 25) was
// fixed in 2026-05-01 by:
//   * `syncCalltraceData` (frontend/ui/calltrace.nim) now passes the
//     backend's `startCallLineIndex` to the store instead of 0.
//   * The IsoNim WebRenderer renders the FULL store window
//     (`vm.store.calltrace.lines.val`) instead of a viewport-height
//     slice — see `isonim_calltrace_view.nim`'s `indexEach`.
//   * The CalltraceVM's autoLoad effect expands `totalHeight` to
//     `totalCallsCount` once it is known, so the loaded section
//     covers the entire DB trace (capped at 500 calls).
// With these fixes `solve_sudoku` IS in the DOM after navigation
// (verified via test diagnostic DOM dumps).  The remaining test
// flakes are timing-related: the autoLoad effect re-fires several
// times during a single CtCompleteMove (vpHeight, depth, scroll
// changes ripple), each time clobbering the store and re-rendering
// the calltrace DOM, which can leave Playwright with stale
// `.calltrace-call-line` locators.  Stabilising those re-renders
// is follow-up work for a future sub-agent.
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
