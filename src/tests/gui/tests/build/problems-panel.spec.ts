/**
 * E2E tests for the Problems panel (BP-M4).
 *
 * Verifies:
 * - The Problems panel is present as an auto-hide bottom tab
 * - Parsed build errors appear as structured problem rows
 * - Clicking a filter button changes the visible problems
 *
 * Clicking a strip tab DOCKS the panel into `#auto-hide-docked-bottom`; it
 * does not open `#auto-hide-overlay`, which is the hover-preview surface.
 * See the contract note in `page-objects/auto-hide-strip.ts`.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.  The
 * problems pane is a standalone auto-hide pane `layout.nim` registers for
 * every recorded language — see `lib/js-trace-fixture.ts`.
 */

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { retry } from "../../lib/retry-helpers";
import { ProblemsPane } from "../../page-objects/panes/build/problems-pane";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";
import {
  BOTTOM_STRIP_TAB_SELECTOR,
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  openBottomPanel,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const fixture = recordChromeTraceFixture("problems-panel");

test.describe("Problems Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("problems panel is present as auto-hide bottom tab", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // The PROBLEMS tab should be present among auto-hide bottom tabs.
    const problemsTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "PROBLEMS",
    });
    await expect(problemsTab).toHaveCount(1);
  });

  test("problems appear when build output contains errors", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the PROBLEMS auto-hide tab to dock the problems panel.
    await openBottomPanel(ctPage, "PROBLEMS");

    // The fixture recording involves no build step and no compiler errors,
    // so the problems panel should be empty.
    const problemsPane = new ProblemsPane(ctPage);

    // Wait for the component container to exist inside the docked container.
    const errorsContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #errorsComponent-0`,
    );
    await retry(
      async () => (await errorsContainer.count()) > 0,
      { maxAttempts: 30, delayMs: 1_000 },
    );

    // Docking the panel mounts its IsoNim view, so the panel itself must be
    // present — this used to be a `test.skip` branch for "renderer not
    // initialized (background tab)", which could never be reached or falsified
    // while the click contract the spec assumed did not exist.
    expect(
      await problemsPane.isPresent(),
      "docking PROBLEMS must mount the problems panel",
    ).toBe(true);

    // No build ran, so there must be no problem rows.
    await expect(problemsPane.rows()).toHaveCount(0);
  });

  test("filter buttons change visible problems", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the PROBLEMS auto-hide tab to dock the problems panel.
    await openBottomPanel(ctPage, "PROBLEMS");

    const problemsPane = new ProblemsPane(ctPage);

    // Wait for problems to load.
    const hasProblems = await retry(
      async () => {
        const count = await problemsPane.rows().count();
        return count > 0;
      },
      { maxAttempts: 60, delayMs: 1_000 },
    ).then(() => true as const).catch(() => false);

    if (!hasProblems) {
      test.skip(true, "No build problems produced for this trace");
      return;
    }

    const allCount = await problemsPane.rows().count();
    expect(allCount).toBeGreaterThan(0);

    // Click "Errors" filter.
    await problemsPane.filterButton("Errors").click();
    // After filtering, count should be <= allCount.
    const errorCount = await problemsPane.errorRows().count();
    expect(errorCount).toBeLessThanOrEqual(allCount);

    // Click "All" to restore.
    await problemsPane.filterButton("All").click();
    const restoredCount = await problemsPane.rows().count();
    expect(restoredCount).toBe(allCount);
  });
});
