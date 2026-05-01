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

  // FAILING (2026-05-01): the Ruby DB recorder is currently
  // emitting an empty calltrace for rb_sudoku_solver — the
  // frontend's `[PIPELINE] syncCalltraceData` log reports
  // `received 0 lines, totalCalls=0` for every CtUpdatedCalltrace
  // response, so the IsoNim calltrace view renders an empty
  // `.calltrace-lines` container and `waitForReady` (60-attempt
  // retry on `.calltrace-call-line` count > 0) times out without
  // the test issuing a search.  Editor + event-log tests pass for
  // the same trace, so this is recorder-side.  See TODO 5.2(m).
  // Calltrace fan-out batching is in place (commit 27dcef26 /
  // section 1.15) so once the recorder produces calls the tests
  // should run cleanly.
  test("call trace navigation to SudokuSolver#solve", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(
      ctPage,
      "SudokuSolver#solve",
      "sudoku_solver.rb",
    );
  });

  // PASSING after 1.22 (CTFS register_call_arg pipeline):
  // the Ruby native recorder now stages each method parameter via
  // `TraceWriter::register_call_arg` immediately after the matching
  // `register_variable_cbor`, so the call record's args field
  // reaches the frontend non-empty.  CallTraceEntry.arguments()
  // returns the `board` argument as expected.
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
