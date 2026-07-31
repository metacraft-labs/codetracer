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
 */
export const DEFAULT_BOTTOM_TAB_TITLES = [
  "BUILD",
  "PROBLEMS",
  "SEARCH RESULTS",
  "REQUESTS",
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

/** Bottom-strip tabs whose label contains `label` (e.g. "BUILD"). */
export function bottomStripTab(page: Page, label: string): Locator {
  return page.locator(BOTTOM_STRIP_TAB_SELECTOR, { hasText: label });
}

/** Every strip tab on the page — bottom strip plus both side strips. */
export function allStripTabs(page: Page): Locator {
  return page.locator(`.${STRIP_TAB_CLASS}`);
}

/**
 * Wait until the bottom strip has finished mounting its standalone panes.
 *
 * `layout.nim` registers BUILD / PROBLEMS / SEARCH RESULTS from a
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
