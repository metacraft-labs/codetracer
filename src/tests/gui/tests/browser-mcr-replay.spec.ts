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

  // FLAKY IN SWEEP, PASSES SOLO: 2026-04-30 — `clickTab()` on the
  // CALLTRACE tab fails with "Element is outside of the viewport" on
  // about half of full-suite runs. The targeted run
  // `just test-gui tests/browser-mcr-replay.spec.ts` passes 5/5
  // consistently; the failure surfaces only after a few hundred prior
  // tests have left Electron / Xvfb in a degraded state.
  // TODO: harden `CallTracePane.clickTab` for this specific
  // viewport-clipping case under sweep load. The page object already
  // catches the exception and retries with `force: true` for the tab
  // click; extend the same pattern (or `dispatchEvent("click")`) to
  // any subsequent expand/activate calls inside this test, and add a
  // short `waitForLoadState("networkidle")` before the first click so
  // the GoldenLayout tab strip has settled.
  test("call trace navigation to main", async ({ ctPage }) => {
    await helpers.assertCallTraceNavigation(ctPage, "main", "main.c");
  });

  // FLAKY IN SWEEP, PASSES SOLO: 2026-04-30 — same root cause as
  // "call trace navigation to main"; flaky under sweep load only.
  // See TODO above.
  test("variable inspection test_boards", async ({ ctPage }) => {
    await helpers.assertFlowValueVisible(ctPage, "test_boards");
  });

  test("output contains Solved", async ({ ctPage }) => {
    await helpers.assertEventLogContainsText(ctPage, "Solved");
  });
});
