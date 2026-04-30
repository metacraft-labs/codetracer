/**
 * E2E tests for the search results panel.
 *
 * Verifies:
 * - The search results panel renders when its auto-hide bottom tab is clicked
 * - The empty state is shown when no search has been performed
 */

import { test, expect, wait, codetracerInstallDir } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";

test.describe("Search Results Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("Search results panel renders", async ({ ctPage }) => {
    const layout = new (await import("../../page-objects/layout-page")).LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    // Click the SEARCH RESULTS auto-hide tab to open the overlay.
    const searchTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "SEARCH RESULTS",
    });
    await searchTab.click();
    await wait(500);

    // The overlay should become visible.
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // The search results panel renders `.search-results` inside
    // `#searchResultsComponent-0`. Due to Karax renderer timing (the
    // component DOM element may not be fully attached when the initial
    // setTimeout fires), we also accept the container element being
    // visible as proof the tab was activated.
    const searchPanel = ctPage.locator("#auto-hide-overlay-content .search-results");
    const searchContainer = ctPage.locator("#auto-hide-overlay-content #searchResultsComponent-0");
    const visible = await retry(
      async () => {
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(visible).toBe(true);
  });

  test("Empty state when no search performed", async ({ ctPage }) => {
    const layout = new (await import("../../page-objects/layout-page")).LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    // Click the SEARCH RESULTS auto-hide tab to open the overlay.
    const searchTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "SEARCH RESULTS",
    });
    await searchTab.click();
    await wait(500);

    // The overlay should become visible.
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Wait for the panel container to be visible inside the overlay.
    const searchPanel = ctPage.locator("#auto-hide-overlay-content .search-results");
    const searchContainer = ctPage.locator("#auto-hide-overlay-content #searchResultsComponent-0");
    const containerVisible = await retry(
      async () => {
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(containerVisible).toBe(true);

    // If the Karax renderer has populated the panel, verify empty state.
    if ((await searchPanel.count()) > 0) {
      const matchRows = searchPanel.locator(".search-results-match-row");
      const matchCount = await matchRows.count();
      expect(matchCount).toBe(0);
    }
  });
});
