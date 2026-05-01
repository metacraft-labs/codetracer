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
// editor / event-log / calltrace navigation smoke tests pass.
//
// FAILING (1 of 5 tests as of 2026-05-01):
//   - "terminal output shows solved board" — terminal pane never gets
//     populated for this DB trace; separate from calltrace.
//
// PASSING after 1.22 (CTFS register_call_arg pipeline):
//   - "variable inspection board via call trace argument" — args now
//     reach `CallTraceEntry.arguments()` via the
//     `trace_writer_register_call_arg` Nim FFI and the new
//     `ct_reader_call_arg` reader path.
//
// Structural calltrace fixes already in place:
//   * caa8155d (1.14): `syncCalltraceData` passes the backend's
//     `startCallLineIndex` instead of 0; IsoNim WebRenderer renders
//     the FULL store window; autoLoad expands totalHeight to
//     totalCallsCount once it is known.
//   * 27dcef26 (1.15): the entire CtCompleteMove fan-out is now
//     wrapped in an `isonim/core/batch.batch`, so the autoLoad effect
//     fires ONCE per move with coherent params.  Verified via
//     `[PIPELINE] CalltraceVM.autoLoad` log entries.
//   * post-1.15 (TODO 5.1(a)): three concurrent
//     `requestCalltraceSection` paths (the fallback in
//     `syncCalltraceDebuggerPosition`, the legacy `loadLines`, and the
//     auto-load effect) were producing different-sized responses that
//     clobbered the store mid-render.  Removed the legacy paths and
//     pinned `bufferStart=0` whenever `autoLoad` expands `totalHeight`
//     to `totalCalls` (≤ FULL_WINDOW_CAP), so post-jump section
//     anchoring no longer drops the parent function's row.
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
