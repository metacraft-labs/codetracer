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
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";
import {
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  FIND_IN_FILES_TAB_TITLE,
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

    // Click the Find in Files auto-hide tab to dock the panel. The title
    // comes from the page object, not a literal: `layout.nim` renamed this
    // pane's tab and the old string went on compiling here as a dead
    // locator. See FIND_IN_FILES_TAB_TITLE.
    await openBottomPanel(ctPage, FIND_IN_FILES_TAB_TITLE);

    // TWO ASSERTIONS, BOTH UNCONDITIONAL, AND THE SECOND IS THE POINT.
    //
    // `#searchResultsComponent-0` is the auto-hide container: its visibility
    // proves the tab was activated and the panel was DOCKED. `.search-results`
    // is the pane itself, rendered inside it by
    // `viewmodel/views/isonim_search_results_view.nim`.
    //
    // These used to be one `retry` closure that returned the container's
    // visibility when the container existed and only "fell back" to the panel
    // otherwise. The container always exists once docked, so the fallback was
    // UNREACHABLE — the panel was never looked at, and a rename of
    // `.search-results` left both cases in this file green while asserting
    // nothing about the pane. Measured: renaming that class alone kept this
    // file at "2 passed". That is the same defect class this spec was repaired
    // for (a renamed identifier surviving as a dead locator), in the spec doing
    // the repairing, and this lane is the only behavioural coverage the
    // Find-in-Files Web renderer arm has.
    //
    // `expect(...).toBeVisible()` rather than a hand-rolled poll: it retries
    // natively AND names the locator that failed. The old form collapsed both
    // locators into one boolean, so the failure read "expected true, received
    // false" and said nothing about which element was missing.
    const searchContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #searchResultsComponent-0`,
    );
    const searchPanel = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .search-results`,
    );
    await expect(searchContainer.first()).toBeVisible({ timeout: 10_000 });
    await expect(searchPanel.first()).toBeVisible({ timeout: 10_000 });
  });

  test("Empty state when no search performed", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the Find in Files auto-hide tab to dock the panel. The title
    // comes from the page object, not a literal: `layout.nim` renamed this
    // pane's tab and the old string went on compiling here as a dead
    // locator. See FIND_IN_FILES_TAB_TITLE.
    await openBottomPanel(ctPage, FIND_IN_FILES_TAB_TITLE);

    // The docking and the pane, asserted the same way as the case above and
    // for the same reason — see the long note there.
    const searchContainer = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} #searchResultsComponent-0`,
    );
    const searchPanel = ctPage.locator(
      `${DOCKED_BOTTOM_CONTENT_SELECTOR} .search-results`,
    );
    await expect(searchContainer.first()).toBeVisible({ timeout: 10_000 });
    await expect(searchPanel.first()).toBeVisible({ timeout: 10_000 });

    // THE EMPTY STATE: no match rows, because no search has been performed.
    //
    // THIS IS THE ONLY ASSERTION THAT DISTINGUISHES THIS CASE FROM THE ONE
    // ABOVE, and it used to sit inside `if ((await searchPanel.count()) > 0)`.
    // A guard like that cannot fail — it can only decline to ask — so a rename
    // of `.search-results` did not redden this case, it silently reduced it to
    // a duplicate of "Search results panel renders".
    //
    // The `toBeVisible` on `searchPanel` above is what keeps the count below
    // honest, and the ORDER is load-bearing: `toHaveCount(0)` on rows scoped to
    // a panel that does not exist is also 0, so this line ALONE would pass
    // vacuously against a renamed panel exactly as the old `if` did. The
    // visibility assertion fails first and names the panel.
    await expect(
      searchPanel.first().locator(".search-results-match-row"),
    ).toHaveCount(0);
  });
});
