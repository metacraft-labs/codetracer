/**
 * Playwright E2E test for browser-based C trace replay.
 *
 * Verifies that a C program traced via the standard recording infrastructure
 * can be replayed in the browser via `ct host` (deploymentMode: "web").
 * This exercises the same replay-worker code path as Electron, but through
 * the browser UI.
 *
 * Uses `c_sudoku_solver/main.c` — the same program used by c-sudoku.spec.ts,
 * but launched in web mode instead of Electron.
 */

import { test } from "../lib/fixtures";
import * as helpers from "../lib/language-smoke-test-helpers";

test.describe("browser-mcr-replay — browser web mode for C trace", () => {
  test.use({
    sourcePath: "c_sudoku_solver/main.c",
    launchMode: "trace",
    deploymentMode: "web",
  });

  test("editor loads main.c", async ({ ctPage }) => {
    await helpers.assertEditorLoadsFile(ctPage, "main.c");
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "main.c");
  });

  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
