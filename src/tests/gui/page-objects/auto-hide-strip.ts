/**
 * Single source of truth for the auto-hide strip selectors.
 *
 * The DOM these name is emitted by
 * `src/frontend/viewmodel/views/isonim_auto_hide_bottom_strip_view.nim`
 * (tabs) into the host `#auto-hide-bottom-strip`, which
 * `src/frontend/viewmodel/views/isonim_status_view.nim` renders as a child
 * of `#status-base`.
 *
 * Why this file exists: commit b27da3947 ("feat: Redesign of the status
 * bar") replaced the old bottom-tabs container.  Tabs used to be wrapped in
 * a `div.auto-hide-bottom-tabs`; they are now **direct children** of
 * `#auto-hide-bottom-strip`.  The wrapper class survived only in
 * `isonim_auto_hide_bottom_tabs_view.nim`, a second renderer nothing but
 * storybook imported, so it disappeared from the live app while roughly 48
 * locator sites across 8 spec files kept asking for it — every one of them
 * a silent no-match rather than a failure, because `.first().waitFor()` and
 * `toHaveCount(n)` on a dead selector fail late and blame the wrong thing.
 * That renderer has since been retired.  Keeping the selectors here means
 * the next rename in the Nim view has one place to land, the way
 * `debug-toolbar-ids.ts` does for the debug toolbar.
 *
 * See Value-Origin-Tracking milestone M47.
 */

import { expect, type Locator, type Page } from "@playwright/test";

/** Host element id for the bottom strip inside the status bar footer. */
export const BOTTOM_STRIP_ID = "auto-hide-bottom-strip";

/** `#`-prefixed selector for the bottom strip host. */
export const BOTTOM_STRIP_SELECTOR = `#${BOTTOM_STRIP_ID}`;

/**
 * The bottom strip is a child of `#status-base`, per `Auto-Hide-Panes.md`
 * §3.1: "The bottom auto-hide labels are rendered INSIDE the existing status
 * bar / footer element."  Specs that mean to assert the strip's *placement*
 * should use this form.
 *
 * Note the design says this "avoids adding a separate bottom strip element";
 * the implementation does have a host element, it is simply nested inside
 * the footer rather than being a fourth top-level strip.  What §3.1 rules
 * out — and what `strip-layout-verify.spec.ts` asserts the absence of — is a
 * `.auto-hide-strip-bottom` sibling of the layout row.
 */
export const BOTTOM_STRIP_IN_FOOTER_SELECTOR = `#status-base ${BOTTOM_STRIP_SELECTOR}`;

/**
 * Class shared by every strip tab, bottom and side alike
 * (`AutoHideBottomStripTabClass` / `AutoHideSideStripTabClass`).
 */
export const STRIP_TAB_CLASS = "auto-hide-strip-tab";

/** Tabs of the bottom strip — direct children of the host. */
export const BOTTOM_STRIP_TAB_SELECTOR = `${BOTTOM_STRIP_SELECTOR} > .${STRIP_TAB_CLASS}`;

/** Class the strip host carries while it holds at least one tab. */
export const BOTTOM_STRIP_HAS_TABS_CLASS = "has-tabs";

/**
 * The retired wrapper class.  Exported so the one spec that legitimately
 * asserts its *absence* — and the guard that forbids it everywhere else —
 * can name it without re-introducing the literal into locator code.
 */
export const RETIRED_BOTTOM_TABS_SELECTOR = ".auto-hide-bottom-tabs";

/**
 * Standalone bottom panes registered at boot by `ui/layout.nim` (search for
 * `standaloneAutoHidePanels`).  They are not GoldenLayout tabs — they exist only in the
 * auto-hide state — so they are present on every trace open regardless of
 * the recorded program, and they are the baseline any "and then I pinned
 * one more" count is measured against.
 *
 * There are **four**, not three.  `REQUESTS`
 * (`Content.RequestPanel` / `requestPanelComponent-0`) joined the list in
 * `layout.nim` and no spec noticed, because every spec that asserted the
 * count was counting the children of a wrapper element the status-bar
 * redesign had already deleted — `toHaveCount(3)` against a dead selector
 * fails on the 3, not on the selector, and these specs were failing for
 * other reasons first.  Derived from the live DOM by
 * `verify_bottom_strip_renders_its_tabs_as_direct_children`.
 *
 * Be clear about what this list is evidence of.  `Auto-Hide-Panes.md` does
 * NOT specify a default bottom-pane set — §6.1 only lists which panels are
 * *candidates* for auto-hiding, and §6.2 gives one illustrative layout.  So
 * this constant is a behavioural baseline read off the app, not a contract
 * read off the design, and it is only as correct as `layout.nim`'s
 * `standaloneAutoHidePanels`.  Its job is to keep the count in ONE place, so
 * that changing the pane set is a deliberate two-file edit instead of eight
 * specs failing on an arithmetic mismatch.  It is not evidence that four is
 * the right number.
 *
 * THE TITLES ARE MATCHED AGAINST, not merely counted, so a stale one here is
 * a dead locator rather than a cosmetic error.  `bottomStripTab(page, label)`
 * filters by `hasText`, so a title that no longer exists yields an empty
 * locator, and the click that follows times out blaming the panel rather than
 * the name.
 *
 * That is not hypothetical.  Commit 529c8dd1 ("feat: Add find in files
 * component") renamed `Content.SearchResults`' title in `layout.nim` from
 * `SEARCH RESULTS` to `FIND IN FILES`, and the literal survived here and
 * across several specs.  Both cases of `tests/build/search-results-e2e.spec.ts`
 * went red — which is the whole of the Find-in-Files Web renderer arm's
 * behavioural coverage — and `status-bar-render-stability.spec.ts`'s
 * per-title loop asserted `toHaveCount(1)` for a tab that no longer exists.
 * The count stayed 4 throughout, so the one constant that WAS checked went on
 * agreeing with the app while the names it held did not.
 *
 * Each title is therefore also exported on its own below, so a spec names the
 * pane through this file instead of retyping the string — the same reason the
 * selectors live here.
 *
 * DO NOT WRITE A COUNT OR A SPEC LIST INTO THIS NOTE.  The first version of it
 * said the literal survived "in three specs", having fixed three — and two more
 * call sites were still live, one of them NINE LINES below a call site the same
 * commit had just fixed (`visual-audit/comprehensive-v2.spec.ts` closed the
 * panel by the old name after opening it by the new one).  An enumeration that
 * reads as complete is worse than no enumeration, because it is exactly what
 * stops the next reader grepping.  The check is:
 *
 *     grep -rn "SEARCH RESULTS" src/tests/gui --include=*.ts
 *
 * and every surviving hit must be prose, a test title, or a self-contained
 * fixture that builds its own DOM — never an argument to a locator helper.
 *
 * AND THAT GREP FINDS ONLY HALF OF WHAT THE RENAME BROKE.  It looks for the
 * name that went away; the same rename also broke specs by what the new name
 * ADDS — "FIND IN FILES" *contains* "FILES", which is a different pane — and
 * none of those specs mentions either literal, because the title they match
 * arrives at runtime from a GoldenLayout tab.  That class of breakage is now
 * structurally impossible rather than greppable: every tab matcher here is
 * exact.  See `exactTabText`.
 */
export const BUILD_TAB_TITLE = "BUILD";
export const PROBLEMS_TAB_TITLE = "PROBLEMS";
/**
 * `Content.SearchResults`, whose pane the product calls **Find in Files**.
 * The component id is still `searchResultsComponent-0` and the CSS class is
 * still `.search-results`; only the user-facing tab title moved.  Keep the
 * two apart when reading a spec: a DOM id that says `searchResults` is not
 * evidence that the tab does.
 */
export const FIND_IN_FILES_TAB_TITLE = "FIND IN FILES";
export const REQUESTS_TAB_TITLE = "REQUESTS";

export const DEFAULT_BOTTOM_TAB_TITLES = [
  BUILD_TAB_TITLE,
  PROBLEMS_TAB_TITLE,
  FIND_IN_FILES_TAB_TITLE,
  REQUESTS_TAB_TITLE,
] as const;

/** Number of tabs the strip holds before a test pins anything. */
export const DEFAULT_BOTTOM_TAB_COUNT = DEFAULT_BOTTOM_TAB_TITLES.length;

/** The bottom strip host. */
export function bottomStrip(page: Page): Locator {
  return page.locator(BOTTOM_STRIP_SELECTOR);
}

/** All tabs currently in the bottom strip. */
export function bottomStripTabs(page: Page): Locator {
  return page.locator(BOTTOM_STRIP_TAB_SELECTOR);
}

/**
 * A regex matching a strip tab's text EXACTLY, modulo surrounding whitespace.
 *
 * **Why every tab matcher here is exact and none is `hasText: string`.**
 * Playwright's string `hasText` is a SUBSTRING match, and pane titles are not
 * mutually prefix-free: "FIND IN FILES" contains "FILES", so a locator aimed
 * at the FILESYSTEM pane resolved to two tabs and every strict-mode assertion
 * on it failed with `Received: 2`.  That is the SECOND failure mode of the
 * rename in `529c8dd1` ("SEARCH RESULTS" -> "FIND IN FILES"), and it is the
 * one the note on `DEFAULT_BOTTOM_TAB_TITLES` cannot catch: the first mode
 * broke by what the old name STOPPED matching, so grepping for the surviving
 * literal found it; this one breaks by what the new name ADDS, in specs that
 * never mention either name because the title arrives at runtime from a
 * GoldenLayout tab.
 *
 * So substring is the wrong default for a tab matcher outright — it is a
 * latent collision for every future pane name, not a fact about these four.
 * A caller that genuinely wants a prefix or a fragment should pass its own
 * `RegExp` to `filter()` and say why.
 *
 * The title reaching the DOM is `AutoHideBottomStripRecord.title`, which
 * `pinPanel` in `ui/auto_hide.nim` copies verbatim out of
 * `contentItem.tab.titleElement.textContent`, so it can carry the layout's
 * incidental whitespace; the tab element itself holds nothing but the label
 * span, so its `textContent` is the title alone.  Hence `\s*` at both ends and
 * nothing else.
 */
export function exactTabText(label: string): RegExp {
  // Titles are panel names today, but a path-derived title (see `showOverlay`'s
  // note in `ui/auto_hide.nim`) can contain regex metacharacters.
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^\\s*${escaped}\\s*$`);
}

/** Bottom-strip tabs whose label is exactly `label` (e.g. "BUILD"). */
export function bottomStripTab(page: Page, label: string): Locator {
  return page.locator(BOTTOM_STRIP_TAB_SELECTOR, {
    hasText: exactTabText(label),
  });
}

/** Every strip tab on the page — bottom strip plus both side strips. */
export function allStripTabs(page: Page): Locator {
  return page.locator(`.${STRIP_TAB_CLASS}`);
}

/**
 * A tab on ANY strip — bottom or either side — whose label is exactly `label`.
 *
 * Use this when the edge a panel ended up on is what the test is *observing*
 * rather than what it is asserting (a pin that could land left, right or
 * bottom), so the locator does not have to hard-code a strip selector.  It is
 * exact for the same reason `bottomStripTab` is; see `exactTabText`.
 */
export function stripTab(page: Page, label: string): Locator {
  return allStripTabs(page).filter({ hasText: exactTabText(label) });
}

/**
 * Wait until the bottom strip has finished mounting its standalone panes.
 *
 * `layout.nim` registers BUILD / PROBLEMS / FIND IN FILES from a
 * `setTimeout` that runs after GoldenLayout has created its component
 * containers, so the strip is briefly empty after the trace opens.  Waiting
 * for the full default set — rather than for "at least one tab" — means a
 * spec that then pins a panel is comparing against a settled baseline
 * instead of racing the registration.
 */
export async function waitForDefaultBottomTabs(
  page: Page,
  timeout = 15_000,
): Promise<void> {
  await expect(bottomStripTabs(page)).toHaveCount(DEFAULT_BOTTOM_TAB_COUNT, {
    timeout,
  });
}

// ---------------------------------------------------------------------------
// Activating a strip tab: docked panel (click) vs slide-in overlay (hover)
// ---------------------------------------------------------------------------

/**
 * **Read this before writing `#auto-hide-overlay` into a new spec.**
 *
 * A strip tab has had two distinct activation gestures with two distinct
 * results since commit `03b787734` ("feat: Add a hover and click handler for
 * the autohide panel"), which changed the strip callbacks' `onSelect` from
 * `showOverlay(panel)` to `showDockedPanel(panel)` in `ui/auto_hide.nim`:
 *
 * - **Click** -> the panel is *docked*.  Its live element is reparented into
 *   `#auto-hide-docked-{left,right,bottom}-content`, the container gains
 *   `docked-open`, and GoldenLayout is resized so the docked panel takes
 *   space from the GL area rather than floating over it (`showDockedPanel`
 *   calls `deferredUpdateGLSize`).  Clicking the same tab again collapses it.
 *   `#auto-hide-overlay` is NOT involved and never gains `visible`.
 * - **Hover** (200 ms, `HOVER_PREVIEW_DELAY_MS`) -> the panel is shown in the
 *   *slide-in overlay* of `Auto-Hide-Panes.md` §3.3: `#auto-hide-overlay`
 *   gains `visible`, `#auto-hide-overlay-title` gets the panel title, and the
 *   live element goes into `#auto-hide-overlay-content`.  The overlay floats
 *   over GL and is dismissed by Escape, a backdrop click, or (for a side
 *   strip) leaving the strip for 300 ms.  §3.3 also lists header close/pin
 *   buttons; those are gone — see `OVERLAY_HEADER_IS_RETIRED`.
 *
 * §3.2 of `Auto-Hide-Panes.md` still describes click as "toggles the panel
 * overlay"; that is the pre-`03b787734` design and the implementation has
 * deliberately moved on — hover took over the overlay and click took over
 * docking.  Every spec written before that commit asserts
 * `#auto-hide-overlay` becomes `visible` after a *click*, which cannot hold
 * against the shipped app.  Use `openDockedPanelFromTab` for the click
 * contract and `openOverlayFromTab` for the overlay contract instead of
 * hand-rolling either.
 */
export type AutoHideEdgeName = "left" | "right" | "bottom";

/** Class the docked container carries while it is expanded. */
export const DOCKED_OPEN_CLASS = "docked-open";

/** Docked container id per edge — `ui/auto_hide.nim` `dockedContainerId`. */
export function dockedContainerSelector(edge: AutoHideEdgeName): string {
  return `#auto-hide-docked-${edge}`;
}

/** Docked content host per edge — `ui/auto_hide.nim` `dockedContentId`. */
export function dockedContentSelector(edge: AutoHideEdgeName): string {
  return `#auto-hide-docked-${edge}-content`;
}

/**
 * Where a bottom-strip tab's panel lands when the tab is CLICKED — the host
 * to scope panel-content locators to.  (Before commit `03b787734` that host
 * was `#auto-hide-overlay-content`; a click no longer opens the overlay.)
 */
export const DOCKED_BOTTOM_CONTENT_SELECTOR = "#auto-hide-docked-bottom-content";

/** The docked container for `edge` (the element that gains `docked-open`). */
export function dockedContainer(page: Page, edge: AutoHideEdgeName): Locator {
  return page.locator(dockedContainerSelector(edge));
}

/** The docked content host for `edge` — where the live element is reparented. */
export function dockedContent(page: Page, edge: AutoHideEdgeName): Locator {
  return page.locator(dockedContentSelector(edge));
}

/** The slide-in overlay container. */
export const OVERLAY_SELECTOR = "#auto-hide-overlay";

/** Where the overlay reparents the active panel's live element. */
export const OVERLAY_CONTENT_SELECTOR = "#auto-hide-overlay-content";

/**
 * Title text in the overlay header.
 *
 * The header ROW is `display: none !important` (see
 * `OVERLAY_HEADER_IS_RETIRED` below), so this element carries the title in
 * the DOM but is never painted.  Assert its *text*, never its visibility.
 */
export const OVERLAY_TITLE_SELECTOR = "#auto-hide-overlay-title";

/**
 * `#auto-hide-overlay-header` — and with it `#auto-hide-overlay-unpin-btn`
 * and `#auto-hide-overlay-close-btn` — has been
 * `display: none !important` since commit `a6151510e` ("feat: Redesign
 * sidepanel tabs"), whose own comment states the replacement: "the active
 * strip tab acts as the panel header.  The close and unpin buttons are
 * embedded in the strip tab itself."
 *
 * A spec that waits for `#auto-hide-overlay-unpin-btn` to be *visible* is
 * therefore waiting for something the stylesheet forbids: the element
 * resolves, `toBeVisible` never passes.  Unpin through
 * `unpinFromStripTabContextMenu` instead — and note that the "embedded in
 * the strip tab" buttons that replaced the header were themselves deleted a
 * few days later in favour of the tab context menu; see that helper.
 */
export const OVERLAY_HEADER_IS_RETIRED = true;

/** Click-to-dismiss backdrop behind the overlay. */
export const OVERLAY_BACKDROP_SELECTOR = "#auto-hide-backdrop";

/**
 * Unpin a panel through the strip tab's right-click context menu.
 *
 * `requestAutoHideBottomStripRender` / `requestAutoHideSideStripRender` build
 * this menu in `ui/auto_hide.nim`; its "Unpin" item runs
 * `hideOverlay(); hideDockedPanel(); unpinPanel(...)`.
 *
 * **It is the only unpin affordance any strip tab has.**  There is no
 * per-tab Unpin button to click: `f214d703b` ("feat: Add context menu to
 * sidepanel tabs…") added this menu on 2026-07-10 and `1af471302` deleted the
 * inline `.auto-hide-strip-tab-close` / `.auto-hide-strip-tab-unpin` buttons
 * from `isonim_auto_hide_side_strip_view.nim` later the same day; the bottom
 * strip view lost its own copy in the same commit.  `auto_hide.styl` still styles those
 * classes and both view files still define the constants, so a spec that
 * locates `.auto-hide-strip-tab-unpin` looks plausible and matches nothing.
 * Nor is `#auto-hide-overlay-unpin-btn` a way in — see
 * `OVERLAY_HEADER_IS_RETIRED`.
 */
export async function unpinFromStripTabContextMenu(
  page: Page,
  tab: Locator,
  timeout = 15_000,
): Promise<void> {
  await tab.click({ button: "right" });
  const unpinItem = page.locator("#context-menu-container .context-menu-item", {
    hasText: /^Unpin$/,
  });
  await expect(unpinItem).toBeVisible({ timeout });
  await unpinItem.click();
}

/**
 * Click `tab` and wait for the panel to be docked at `edge`.
 *
 * This is the click contract: `docked-open` on the container, and the
 * panel's live element (`.auto-hide-standalone-container` for the standalone
 * panes, the reparented GL element otherwise) inside the content host.
 */
export async function openDockedPanelFromTab(
  page: Page,
  tab: Locator,
  edge: AutoHideEdgeName = "bottom",
  timeout = 15_000,
): Promise<void> {
  await expect(tab).toBeVisible({ timeout });
  await tab.click();
  await expect(dockedContainer(page, edge)).toHaveClass(
    new RegExp(`\\b${DOCKED_OPEN_CLASS}\\b`),
    { timeout },
  );
}

/**
 * Click the bottom-strip tab labelled `label` and wait for it to dock.
 * Returns the docked content host so callers can scope their locators to it.
 */
export async function openBottomPanel(
  page: Page,
  label: string,
  timeout = 15_000,
): Promise<Locator> {
  await openDockedPanelFromTab(page, bottomStripTab(page, label), "bottom", timeout);
  return dockedContent(page, "bottom");
}

/**
 * Collapse whatever is docked at `edge` by clicking its tab again.
 *
 * `showDockedPanel` toggles, so re-clicking the tab that opened the panel is
 * the documented way to close it; Escape and the backdrop only dismiss the
 * *overlay* and leave a docked panel open.  Used to return the app to a
 * neutral state between tests that share one Electron page.
 */
export async function closeDockedPanelFromTab(
  page: Page,
  tab: Locator,
  edge: AutoHideEdgeName = "bottom",
  timeout = 15_000,
): Promise<void> {
  await tab.click();
  await expect(dockedContainer(page, edge)).not.toHaveClass(
    new RegExp(`\\b${DOCKED_OPEN_CLASS}\\b`),
    { timeout },
  );
}

/**
 * Hover `tab` and wait for the slide-in overlay to appear.
 *
 * The mouse is deliberately left on the tab: for the left/right strips
 * `auto_hide_overlay.nim` arms a 300 ms dismissal timer on `mouseleave` of
 * the strip, so a test that moves the pointer away before asserting would be
 * racing the auto-dismiss rather than testing it.  When the caller then needs
 * to interact with the overlay itself, `enterOverlayHoverZone` moves the
 * pointer into the overlay first, which cancels that timer
 * (`attachHoverZone`'s `mouseenter` handler).
 */
export async function openOverlayFromTab(
  page: Page,
  tab: Locator,
  timeout = 15_000,
): Promise<void> {
  await expect(tab).toBeVisible({ timeout });
  await tab.hover();
  await expect(page.locator(OVERLAY_SELECTOR)).toHaveClass(/\bvisible\b/, {
    timeout,
  });
}

/**
 * Move the pointer into the overlay so the mouse-leave dismissal timer armed
 * by leaving a side strip is cancelled before the caller clicks inside it.
 */
export async function enterOverlayHoverZone(page: Page): Promise<void> {
  await page.locator(OVERLAY_SELECTOR).hover();
}
