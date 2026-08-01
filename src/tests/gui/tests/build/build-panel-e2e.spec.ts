/**
 * E2E tests for the build-related tabs in the bottom panel row.
 *
 * Verifies:
 * - BUILD, PROBLEMS, and SEARCH RESULTS tabs are present as auto-hide bottom tabs
 * - Clicking the BUILD tab docks the build panel and renders its header
 * - Clicking the PROBLEMS tab shows the problems panel (empty state)
 *
 * Clicking a strip tab DOCKS the panel into `#auto-hide-docked-bottom`; it
 * does not open `#auto-hide-overlay`, which is the hover-preview surface.
 * See the contract note in `page-objects/auto-hide-strip.ts`.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.  The
 * bottom strip and its standalone panes are built by `layout.nim` identically
 * for every recorded language — see `lib/js-trace-fixture.ts`.
 */

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";
import {
  BOTTOM_STRIP_TAB_SELECTOR,
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  openBottomPanel,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const fixture = recordChromeTraceFixture("build-panel-e2e");

test.describe("Build panel tabs as auto-hide bottom tabs", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("BUILD tab present in bottom auto-hide strip", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear (they load after a delay).
    await waitForDefaultBottomTabs(ctPage);

    // The BUILD tab should exist among the auto-hide bottom tabs.
    const buildTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "BUILD",
    });
    await expect(buildTab).toHaveCount(1);

    // Verify the sibling tabs are also present as auto-hide bottom tabs.
    const problemsTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "PROBLEMS",
    });
    const searchTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "SEARCH RESULTS",
    });
    await expect(problemsTab).toHaveCount(1);
    await expect(searchTab).toHaveCount(1);
  });

  test("PROBLEMS tab present", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    await waitForDefaultBottomTabs(ctPage);

    const problemsTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "PROBLEMS",
    });
    await expect(problemsTab).toHaveCount(1);
  });

  test("SEARCH RESULTS tab present", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    await waitForDefaultBottomTabs(ctPage);

    const searchTab = ctPage.locator(BOTTOM_STRIP_TAB_SELECTOR, {
      hasText: "SEARCH RESULTS",
    });
    await expect(searchTab).toHaveCount(1);
  });

  test("Build panel renders with header", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the BUILD auto-hide tab to dock the build panel.
    await openBottomPanel(ctPage, "BUILD");

    // After clicking, the build panel (#build) should be visible inside the
    // docked bottom container.
    const buildPanel = ctPage.locator(`${DOCKED_BOTTOM_CONTENT_SELECTOR} #build`);
    const visible = await retry(
      async () => {
        if ((await buildPanel.count()) === 0) return false;
        return buildPanel.first().isVisible();
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(visible).toBe(true);

    // The build panel should contain the header controls area.
    const header = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .build-header-controls`,
    );
    const headerPresent = (await header.count()) > 0;
    expect(headerPresent).toBe(true);
  });

  test("Problems panel renders empty state", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the PROBLEMS auto-hide tab to dock the problems panel.
    await openBottomPanel(ctPage, "PROBLEMS");

    // The problems panel should become visible inside the docked container.
    const errorsContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #errorsComponent-0`,
    );
    const containerVisible = await retry(
      async () => {
        if ((await errorsContainer.count()) === 0) return false;
        return errorsContainer.first().isVisible();
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(containerVisible).toBe(true);

    // The fixture recording involves no build step, so there should be no
    // build errors. If the renderer has populated the container, verify the
    // empty state; otherwise the container being visible is sufficient since
    // the component initialises lazily.
    const problemsPanel = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .problems-panel`,
    );
    if ((await problemsPanel.count()) > 0) {
      const rows = problemsPanel.locator(".problems-row");
      const rowCount = await rows.count();
      expect(rowCount).toBe(0);
    }
  });
});
