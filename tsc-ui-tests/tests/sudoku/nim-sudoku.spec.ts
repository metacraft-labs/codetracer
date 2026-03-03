import { test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Nim Sudoku Solver (nim_sudoku_solver).
 * RR-based trace. Initial position is inside Nim runtime (stdlib), not user code.
 *
 * Tests accept any `.nim` file in the editor, search for Nim runtime entries
 * in the call trace, and verify the state pane has at least one variable.
 *
 * Port of ui-tests/Tests/ProgramSpecific/NimSudokuTests.cs
 */
test.describe("NimSudoku", () => {
  test.skip(!process.env.CODETRACER_RR_BACKEND_PRESENT, "requires ct-rr-support");
  test.setTimeout(900_000);
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace" });

  test("editor loads a .nim file", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, ".nim");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace has Nim runtime entries", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().click();

    let nimEntryFound = false;

    await retry(
      async () => {
        callTrace.invalidateEntries();
        const nimEntry =
          (await callTrace.findEntry("NimMainModule", true)) ??
          (await callTrace.findEntry("NimMain", true)) ??
          (await callTrace.findEntry("main", true));
        if (nimEntry !== null) {
          nimEntryFound = true;
          return true;
        }
        return false;
      },
      { maxAttempts: 60, delayMs: 1000 },
    );

    if (!nimEntryFound) {
      throw new Error(
        "Call trace did not contain any expected Nim runtime entries " +
          "(NimMainModule, NimMain, main).",
      );
    }
  });

  test("variable inspection - state pane has variables", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const statePane = (await layout.programStateTabs())[0];
    await statePane.tabButton().click();

    await retry(
      async () => {
        const variables = await statePane.programStateVariables(true);
        return variables.length > 0;
      },
      { maxAttempts: 60, delayMs: 1000 },
    );
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
