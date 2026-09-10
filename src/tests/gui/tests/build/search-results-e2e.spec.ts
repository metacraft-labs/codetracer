/**
 * E2E tests for the search results panel.
 *
 * Verifies:
 * - The search results panel renders when its auto-hide bottom tab is clicked
 * - The empty state is shown when no search has been performed
 *
 * Clicking a strip tab DOCKS the panel into `#auto-hide-docked-bottom`; it
 * does not open `#auto-hide-overlay`, which is the hover-preview surface.
 * See the contract note in `page-objects/auto-hide-strip.ts`.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.  The
 * search-results pane is a standalone auto-hide pane `layout.nim` registers
 * for every recorded language — see `lib/js-trace-fixture.ts`.
 */

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";
import {
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  openBottomPanel,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const fixture = recordChromeTraceFixture("search-results-e2e");

test.describe("Search Results Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("Search results panel renders", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the SEARCH RESULTS auto-hide tab to dock the panel.
    await openBottomPanel(ctPage, "SEARCH RESULTS");

    // The search results panel renders `.search-results` inside
    // `#searchResultsComponent-0`. Check the container element
    // visibility first, which proves the auto-hide tab was activated and
    // the panel was docked, and fall back to the panel itself.
    //
    // (The container-first order dates from when `.search-results`
    // carried a `.search-results-non-active` `display: none` modifier
    // before a search. The Find in Files redesign retired that modifier
    // — the panel owns the query input, so hiding it would hide the only
    // way to start a search — so the panel is visible from the start
    // now. The order is kept because the container is still the thing
    // that proves the DOCKING, which is what this case is about.)
    const searchContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #searchResultsComponent-0`,
    );
    const searchPanel = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .search-results`,
    );
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
    await waitForDefaultBottomTabs(ctPage);

    // Click the SEARCH RESULTS auto-hide tab to dock the panel.
    await openBottomPanel(ctPage, "SEARCH RESULTS");

    // Wait for the panel container to be visible inside the docked panel.
    // The container is checked first because it is what proves the
    // docking; see the note in the case above for why the panel itself
    // is no longer hidden before a search.
    const searchContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #searchResultsComponent-0`,
    );
    const searchPanel = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .search-results`,
    );
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
