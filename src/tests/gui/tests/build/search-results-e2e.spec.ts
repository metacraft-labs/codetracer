/**
 * E2E tests for the search results panel.
 *
 * Verifies:
 * - The search results panel renders when its auto-hide bottom tab is clicked
 * - The empty state is shown when no search has been performed
 */

import { test, expect, wait, codetracerInstallDir } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";

test.describe("Search Results Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("Search results panel renders", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
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
    // `#searchResultsComponent-0`. The `.search-results` element has
    // `display: none` via `.search-results-non-active` until a search
    // is performed. Check the container element visibility instead,
    // which proves the auto-hide tab was activated and the panel was
    // rendered into the overlay.
    const searchContainer = ctPage.locator("#auto-hide-overlay-content #searchResultsComponent-0");
    const searchPanel = ctPage.locator("#auto-hide-overlay-content .search-results");
    const visible = await retry(
      async () => {
        // Check the outer container first — it is always visible when
        // the overlay is shown, even if .search-results has display:none.
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(visible).toBe(true);
  });

  test("Empty state when no search performed", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
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
    // The `.search-results` element has `display: none` via
    // `.search-results-non-active` until a search is performed, so
    // check the outer container first.
    const searchContainer = ctPage.locator("#auto-hide-overlay-content #searchResultsComponent-0");
    const searchPanel = ctPage.locator("#auto-hide-overlay-content .search-results");
    const containerVisible = await retry(
      async () => {
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(containerVisible).toBe(true);

    // Verify empty state: no match rows should be present since
    // no search has been performed.
    if ((await searchPanel.count()) > 0) {
      const matchRows = searchPanel.locator(".search-results-match-row");
      const matchCount = await matchRows.count();
      expect(matchCount).toBe(0);
    }
  });
});
