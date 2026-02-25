import { test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Fortran Sudoku Solver (fortran_sudoku_solver).
 * RR-based trace with limited LLDB support for gfortran DWARF debug info.
 *
 * Function names often appear as "<can't extract function name>", source
 * path mapping doesn't work, and flow values / state pane are unavailable.
 * Most tests fall back to verifying the event log is populated.
 *
 * Port of ui-tests/Tests/ProgramSpecific/FortranSudokuTests.cs
 */
test.describe("FortranSudoku", () => {
  test.setTimeout(900_000);
  test.use({
    sourcePath: "fortran_sudoku_solver/sudoku.f90",
    launchMode: "trace",
  });

  test("editor loads (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace has entries", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().click();
    callTrace.invalidateEntries();

    // Wait for any call trace entry to appear. getEntries() has its own
    // internal retry that may throw before entries appear; catch and retry.
    await retry(
      async () => {
        try {
          callTrace.invalidateEntries();
          const entries = await callTrace.getEntries(true);
          return entries.length > 0;
        } catch {
          // Internal retry in getEntries timed out — keep the outer retry going.
          return false;
        }
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
  });

  test("variable inspection (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("output (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });
});
