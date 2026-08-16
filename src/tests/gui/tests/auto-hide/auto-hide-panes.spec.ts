/**
 * Auto-hide panes E2E tests.
 *
 * Verifies the pin-to-edge workflow: pinning panels to edge strips, docking
 * a panel by clicking its strip tab, previewing it in the slide-in overlay by
 * hovering the tab, unpinning back to the GL layout, and dismissing the
 * overlay via Escape / backdrop click.
 *
 * **Click docks, hover previews.**  Every test below that opens
 * `#auto-hide-overlay` does so by *hovering* a strip tab.  A click reparents
 * the panel into `#auto-hide-docked-<edge>-content` instead and never touches
 * the overlay — see the contract note in `page-objects/auto-hide-strip.ts`
 * for why (commit `03b787734`).
 *
 * DOM elements under test (defined in index.html and rendered by
 * auto_hide.nim / auto_hide_overlay.nim):
 *   #auto-hide-layout-row        — flex row: left strip + #ROOT + right strip
 *   #auto-hide-strip-left        — left edge strip (ID, flex item beside GL)
 *   #auto-hide-strip-right       — right edge strip (ID, flex item beside GL)
 *   #auto-hide-bottom-strip      — bottom strip hosted inside #status-base;
 *                                  its tabs are DIRECT children (the pre-
 *                                  redesign wrapper element is retired —
 *                                  see page-objects/auto-hide-strip.ts)
 *   .auto-hide-strip-tab         — individual tab within a strip
 *   #auto-hide-docked-bottom     — inline docked container a tab CLICK opens
 *   #auto-hide-overlay           — slide-in overlay container a tab HOVER opens
 *   #auto-hide-overlay-title     — title text inside the (hidden) overlay
 *                                  header; readable in the DOM, never painted
 *   #context-menu-container      — right-click menu on a strip tab; its
 *                                  "Unpin" item is the ONLY unpin affordance
 *                                  left (the overlay header is display:none
 *                                  since a6151510e, and the per-tab buttons
 *                                  that replaced it were deleted in 1af471302)
 *   #auto-hide-backdrop          — click-to-dismiss backdrop behind overlay
 *   .layout-buttons-container    — GL stack header dropdown toggle
 *   .layout-dropdown-node        — individual item inside the dropdown
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.
 * The strip/overlay DOM is built by `layout.nim` the same way for every
 * recorded language — see `lib/js-trace-fixture.ts`
 * `recordChromeTraceFixture`.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  DEFAULT_BOTTOM_TAB_COUNT,
  DOCKED_OPEN_CLASS,
  OVERLAY_BACKDROP_SELECTOR,
  OVERLAY_CONTENT_SELECTOR,
  OVERLAY_SELECTOR,
  OVERLAY_TITLE_SELECTOR,
  allStripTabs,
  bottomStripTab,
  bottomStripTabs,
  dockedContainer,
  dockedContent,
  openDockedPanelFromTab,
  openOverlayFromTab,
  unpinFromStripTabContextMenu,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

/** Timeout for waiting on UI elements/transitions. */
const WAIT_TIMEOUT_MS = 15000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Open the dropdown menu on the first visible GL stack header and click
 * the menu item whose text matches `itemText` (e.g. "Pin to Bottom").
 *
 * The dropdown is a `.layout-buttons-container` div rendered in each
 * stack header. Clicking it toggles a child `.layout-dropdown` between
 * hidden and visible. Menu items are `.layout-dropdown-node` elements.
 *
 * Returns the title text of the active tab in the stack that was acted
 * upon, so tests can assert which panel was pinned.
 */
async function clickDropdownItem(
  ctPage: import("@playwright/test").Page,
  itemText: string,
  stackIndex = 0,
): Promise<string> {
  // Find the stack's active tab title before acting, so we know
  // which panel will be pinned.
  const stacks = ctPage.locator(".lm_stack");
  const stack = stacks.nth(stackIndex);
  await expect(stack).toBeVisible({ timeout: 10_000 });

  // The active tab label lives inside .lm_tab.lm_active .lm_title
  const activeTitle = await stack
    .locator(".lm_tab.lm_active .lm_title")
    .first()
    .textContent();

  // Click the dropdown toggle (the container div in the stack header).
  const toggle = stack.locator(".layout-buttons-container").first();
  await toggle.click();

  // Wait for the dropdown to become visible (hidden class removed).
  const dropdown = stack.locator(".layout-dropdown").first();
  await expect(dropdown).not.toHaveClass(/hidden/, { timeout: WAIT_TIMEOUT_MS });

  // Wait for the desired menu item to be visible so the DOM is populated.
  const menuItem = dropdown.locator(".layout-dropdown-node", {
    hasText: itemText,
  });
  await expect(menuItem).toBeVisible({ timeout: WAIT_TIMEOUT_MS });

  const layoutUpdatedPromise = ctPage.evaluate(() => {
    return new Promise<void>((resolve) => {
      window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
    });
  });

  // Click via page.evaluate() to avoid the blur race condition: the
  // dropdown's onblur handler closes the menu before Playwright's
  // click() can land. Using the DOM API fires the click synchronously.
  // We scope the search to the correct stack (by index) since all
  // stacks have identical menu items.
  await ctPage.evaluate(
    ({ text, idx }) => {
      const stacks = document.querySelectorAll(".lm_stack");
      const stack = stacks[idx];
      if (!stack) return;
      const items = stack.querySelectorAll(".layout-dropdown-node");
      for (const item of items) {
        if (item.textContent?.trim() === text) {
          (item as HTMLElement).click();
          return;
        }
      }
    },
    { text: itemText, idx: stackIndex },
  );

  // Wait for the deterministic layoutUpdated signal before returning
  await layoutUpdatedPromise;

  return (activeTitle ?? "").trim();
}

/**
 * Pin the active tab of a given GL stack to the specified edge.
 * Returns the title of the panel that was pinned.
 */
async function pinToEdge(
  ctPage: import("@playwright/test").Page,
  edge: "Bottom" | "Left" | "Right",
  stackIndex = 0,
): Promise<string> {
  return clickDropdownItem(ctPage, `Pin to ${edge}`, stackIndex);
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

const fixture = recordChromeTraceFixture("auto-hide-panes");

test.describe("Auto-hide panes", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test("strip tabs hidden when no panels pinned", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for the standalone bottom panes to finish registering (they are
    // mounted from a setTimeout after GoldenLayout builds its containers).
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    // `layout.nim` registers BUILD, PROBLEMS, SEARCH RESULTS and REQUESTS as
    // default bottom auto-hide tabs.  No user-pinned panels should be
    // present, so only those defaults exist.
    const bottomTabs = bottomStripTabs(ctPage);
    await expect(bottomTabs).toHaveCount(DEFAULT_BOTTOM_TAB_COUNT);

    // Side strips should be empty (no panels pinned to left or right).
    for (const stripSelector of [
      "#auto-hide-strip-left",
      "#auto-hide-strip-right",
    ]) {
      const strip = ctPage.locator(stripSelector);
      const count = await strip.count();
      if (count > 0) {
        const innerTabs = strip.locator(".auto-hide-strip-tab");
        await expect(innerTabs).toHaveCount(0);
      }
    }
  });

  test("pin panel creates strip tab", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    // Record the initial number of GL stacks so we can verify one was removed.
    const initialStackCount = await ctPage.locator(".lm_stack").count();

    // The standalone bottom panes are already registered; this test measures
    // a pin as a delta against that settled baseline.
    const bottomTabs = bottomStripTabs(ctPage);
    const initialBottomCount = await bottomTabs.count();
    expect(
      initialBottomCount,
      "the standalone bottom panes must be registered before pinning",
    ).toBe(DEFAULT_BOTTOM_TAB_COUNT);

    // Pin the active tab of the first stack to the bottom edge.
    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    await expect(async () => {
      // One more strip tab should now exist in the bottom tabs.
      await expect(bottomTabs).toHaveCount(initialBottomCount + 1, { timeout: 1000 });

      // The pinned panel title should appear among the bottom tabs.
      const pinnedTab = bottomStripTab(ctPage, pinnedTitle);
      await expect(pinnedTab).toHaveCount(1, { timeout: 1000 });

      // The panel should have been removed from the GL layout
      const remainingTabsWithTitle = ctPage.locator(".lm_tab .lm_title", {
        hasText: pinnedTitle,
      });
      await expect(remainingTabsWithTitle).toHaveCount(0, { timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });

  test("strip tab click docks the panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Click the strip tab matching the pinned panel.  A click DOCKS: the
    // panel's live element is reparented into the inline bottom container,
    // which expands and takes space from GoldenLayout.  (Before commit
    // 03b787734 a click opened the floating overlay instead; this test used
    // to assert that, and could not have passed since.)
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await openDockedPanelFromTab(ctPage, stripTab, "bottom", WAIT_TIMEOUT_MS);

    // The pinned panel's live element now lives in the docked content host.
    await expect(
      dockedContent(ctPage, "bottom").locator("> *"),
    ).toHaveCount(1, { timeout: WAIT_TIMEOUT_MS });

    // And the floating overlay is NOT what a click produces.
    await expect(ctPage.locator(OVERLAY_SELECTOR)).not.toHaveClass(/\bvisible\b/);

    // Clicking the same tab again toggles the docked panel closed.
    await stripTab.click();
    await expect(dockedContainer(ctPage, "bottom")).not.toHaveClass(
      new RegExp(`\\b${DOCKED_OPEN_CLASS}\\b`),
      { timeout: WAIT_TIMEOUT_MS },
    );
  });

  test("strip tab hover shows overlay", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Hover the strip tab matching the pinned panel.  Hovering is what opens
    // the slide-in overlay of Auto-Hide-Panes.md §3.3.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await openOverlayFromTab(ctPage, stripTab, WAIT_TIMEOUT_MS);

    // The overlay title should match the previewed panel, and the panel's
    // live element should have been reparented into the overlay body.
    await expect(ctPage.locator(OVERLAY_TITLE_SELECTOR)).toHaveText(pinnedTitle, {
      timeout: WAIT_TIMEOUT_MS,
    });
    await expect(
      ctPage.locator(`${OVERLAY_CONTENT_SELECTOR} > *`),
    ).toHaveCount(1, { timeout: WAIT_TIMEOUT_MS });

    await ctPage.keyboard.press("Escape");
    await expect(ctPage.locator(OVERLAY_SELECTOR)).not.toHaveClass(/\bvisible\b/, {
      timeout: WAIT_TIMEOUT_MS,
    });
  });

  test("unpin from an open overlay restores the panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);
    const initialTabCount = await allStripTabs(ctPage).count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by hovering the strip tab for the pinned panel.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await openOverlayFromTab(ctPage, stripTab, WAIT_TIMEOUT_MS);

    const overlay = ctPage.locator(OVERLAY_SELECTOR);

    // Unpin to restore the panel back into GL.  This used to click
    // `#auto-hide-overlay-unpin-btn`; the overlay header row has been
    // `display: none !important` since commit a6151510e, which moved the
    // close/unpin affordances onto the strip tab itself.  The bottom strip's
    // tabs carry no buttons, so its unpin affordance is the tab context menu
    // — the same `hideOverlay(); hideDockedPanel(); unpinPanel(...)` handler.
    const layoutUpdatedPromise = ctPage.evaluate(() => {
      return new Promise<void>((resolve) => {
        window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
      });
    });

    await unpinFromStripTabContextMenu(ctPage, stripTab, WAIT_TIMEOUT_MS);

    await layoutUpdatedPromise;

    await expect(async () => {
      // The overlay should no longer be visible.
      await expect(overlay).not.toHaveClass(/visible/, { timeout: 1000 });

      // The pinned strip tab should have been removed (back to initial count).
      const remainingTabs = allStripTabs(ctPage);
      await expect(remainingTabs).toHaveCount(initialTabCount, { timeout: 1000 });

      // The panel should be back in the GL layout — look for its title
      // among GL tab titles.
      const restoredTab = ctPage.locator(".lm_tab .lm_title", {
        hasText: pinnedTitle,
      });
      await expect(restoredTab.first()).toBeVisible({ timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });

  test("overlay dismisses on Escape", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);
    const initialTabCount = await allStripTabs(ctPage).count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by hovering the pinned panel's strip tab.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await openOverlayFromTab(ctPage, stripTab, WAIT_TIMEOUT_MS);

    const overlay = ctPage.locator(OVERLAY_SELECTOR);

    // Press Escape to dismiss.  The pointer stays on the tab, so nothing
    // else can be dismissing the overlay at this moment.
    await ctPage.keyboard.press("Escape");

    await expect(async () => {
      // The overlay should be hidden (no "visible" class).
      await expect(overlay).not.toHaveClass(/visible/, { timeout: 1000 });

      // The strip tab should still be present (Escape only hides the
      // overlay; it does not unpin the panel). Total count = initial + 1.
      const tabsAfter = allStripTabs(ctPage);
      await expect(tabsAfter).toHaveCount(initialTabCount + 1, { timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });

  test("overlay dismisses on backdrop click", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);
    const initialTabCount = await allStripTabs(ctPage).count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by hovering the pinned panel's strip tab.  The panel
    // is on the BOTTOM edge, and `setupMouseLeaveDismissal` arms its
    // mouse-leave timer only on the overlay and the two SIDE strips — so
    // moving the pointer to the backdrop below cannot itself dismiss the
    // overlay, and the assertion still measures the backdrop click.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await openOverlayFromTab(ctPage, stripTab, WAIT_TIMEOUT_MS);

    const overlay = ctPage.locator(OVERLAY_SELECTOR);

    // Click the backdrop to dismiss.
    const backdrop = ctPage.locator(OVERLAY_BACKDROP_SELECTOR);
    // The backdrop may be zero-sized when not shown; force the click
    // at a known position to ensure the event fires.
    await backdrop.click({ force: true });

    await expect(async () => {
      // The overlay should be hidden.
      await expect(overlay).not.toHaveClass(/visible/, { timeout: 1000 });

      // The strip tab should still be present. Total count = initial + 1.
      const tabsAfter = allStripTabs(ctPage);
      await expect(tabsAfter).toHaveCount(initialTabCount + 1, { timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });

  test("multiple panels can be pinned to different edges", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Disable collapsed mode to prevent strips from hiding behind a 1px accent line
    await ctPage.evaluate(() => {
      if ((window as any).__ctForceCollapsedMode) (window as any).__ctForceCollapsedMode(false);
    });

    // Wait for default bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);
    const initialBottomCount = DEFAULT_BOTTOM_TAB_COUNT;

    const layoutUpdatedPromisePin1 = ctPage.evaluate(() => {
      return new Promise<void>((resolve) => {
        window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
      });
    });

    // Pin FILESYSTEM (Content=9) to the bottom using __ctPinPanel.
    const bottomTitle = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const comp = s.ui.componentMapping[9]?.[0];
      if (comp?.layoutItem && (window as any).__ctPinPanel) {
        (window as any).__ctPinPanel(comp.layoutItem, 2);  // 2 = Bottom
        return comp.layoutItem?.tab?.titleElement?.textContent?.trim() ?? "FILES";
      }
      return "FILES";
    }) as string;

    await layoutUpdatedPromisePin1;

    const layoutUpdatedPromisePin2 = ctPage.evaluate(() => {
      return new Promise<void>((resolve) => {
        window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
      });
    });

    // Pin STATE (Content=4) to the left using __ctPinPanel.
    const leftPinResult = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const comp = s.ui.componentMapping[4]?.[0];  // STATE
      if (!comp) return "no-component";
      if (!comp.layoutItem) return "no-layoutItem";
      if (!(window as any).__ctPinPanel) return "no-pin-helper";
      const title = comp.layoutItem?.tab?.titleElement?.textContent?.trim() ?? "STATE";
      try {
        (window as any).__ctPinPanel(comp.layoutItem, 0);  // 0 = Left
        return "pinned:" + title;
      } catch (e: any) {
        return "error:" + e.message;
      }
    }) as string;
    console.log("Left pin result:", leftPinResult);
    const leftTitle = leftPinResult.startsWith("pinned:") ? leftPinResult.slice(7) : "STATE";

    await layoutUpdatedPromisePin2;

    // Historical note: this used to be described as "force a strip redraw in
    // case the onChanged callback didn't fire".  It cannot do that.
    // `__ctRedrawAll` -> `renderer.redrawAll` -> `sharedDirectRedraw` refreshes
    // the menu, the status bar and the fixed search box only; the auto-hide
    // strips are rendered exclusively from `autoHideState.onChanged`.  The call
    // is kept because the status-bar refresh it triggers is what re-creates the
    // `#auto-hide-bottom-strip` host, which the bottom-tab assertions below
    // read — it does nothing for the left strip.
    await ctPage.evaluate(() => {
      if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
    });

    await expect(async () => {
      // Bottom tabs should have one more than the initial default count.
      const bottomTabs = bottomStripTabs(ctPage);
      await expect(bottomTabs).toHaveCount(initialBottomCount + 1, { timeout: 1000 });
      // The pinned panel should appear among bottom tabs.
      const pinnedBottomTab = bottomStripTab(ctPage, bottomTitle);
      await expect(pinnedBottomTab).toHaveCount(1, { timeout: 1000 });

      // Left strip should have exactly one tab.
      const leftTabs = ctPage
        .locator("#auto-hide-strip-left .auto-hide-strip-tab");
      await expect(leftTabs).toHaveCount(1, { timeout: 1000 });
      await expect(leftTabs.first()).toHaveText(leftTitle, { timeout: 1000 });

      // Neither panel should remain in the GL layout.
      const remainingBottom = ctPage.locator(".lm_tab .lm_title", {
        hasText: bottomTitle,
      });
      await expect(remainingBottom).toHaveCount(0, { timeout: 1000 });

      const remainingLeft = ctPage.locator(".lm_tab .lm_title", {
        hasText: leftTitle,
      });
      await expect(remainingLeft).toHaveCount(0, { timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });

  // Spec grounding for this test (issue #567 / milestone M18):
  //
  //  * `Planned-Features/Auto-Hide-Panes.md` §1.2.1 gives *every* Golden Layout
  //    stack a pin control, so an editor is a legitimate thing to pin.  §6.1's
  //    "Editor — Auto-Hide Candidate: No" is advice about which panes a default
  //    layout should auto-hide, not a restriction on the feature.
  //  * §3.2 "Right-click: opens the tab context menu (re-pin to another edge,
  //    Unpin).  This is the only unpin/close affordance a strip tab has."
  //  * §3.3 "Unpin, which restores the panel to GL" — unpinning must put the
  //    panel BACK IN THE LAYOUT, which is exactly what #567 reported it did not
  //    do ("closes instead of moving to layout").
  //  * §1.3 "Window not maximized: The strip must be wider (e.g., 28px) and use
  //    its standard text-label rendering" — the mode this test asks for below
  //    via `__ctForceCollapsedMode(false)`, so that the tab it hovers exists.
  //    Under Xvfb the window fills the virtual screen and
  //    `updateCollapsedMode`'s heuristic answers "maximized", which renders the
  //    strip as the 1px `collapsed-strip-line` with no tabs at all.  That
  //    override used to be silently reverted by the next `resize`, and both
  //    recorded failures of this test show the strip back in `collapsed-mode`
  //    at the moment `hover()` gave up.  The override is sticky now.
  //  * `GUI/Core-Panes/Editor-Pane.md`, "Tab Management": "Multiple files can be
  //    open simultaneously as tabs" — a second, independent defect on this path:
  //    `openLayoutTab` matched a pinned panel on its Content kind alone, so once
  //    ANY editor was pinned every later request to open a file resolved to that
  //    one panel, and each request became a `showOverlay` *toggle* that rebuilt
  //    the edge strip.  Covered headlessly by
  //    `auto-hide/auto_hide_routing_test.nim`.
  test("editor unpin behavior", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await layout.waitForEditorLoaded();

    // Disable collapsed mode to prevent strips from hiding behind a 1px accent line
    await ctPage.evaluate(() => {
      if ((window as any).__ctForceCollapsedMode) (window as any).__ctForceCollapsedMode(false);
    });

    // Verify there is an editor tab visible in GoldenLayout before pinning.
    const initialEditors = await layout.editorTabs(true);
    expect(initialEditors.length).toBeGreaterThan(0);

    const layoutUpdatedPromisePin = ctPage.evaluate(() => {
      return new Promise<void>((resolve) => {
        window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
      });
    });

    // Pin the active editor tab.
    const editorTitle = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const mapping = s.ui.componentMapping[2]; // Content.EditorView
      let activeComp = null;
      for (const id in mapping) {
        const comp = mapping[id];
        if (comp && comp.layoutItem && comp.layoutItem.tab && comp.layoutItem.tab.isActive) {
          activeComp = comp;
          break;
        }
      }
      if (activeComp && activeComp.layoutItem && (window as any).__ctPinPanel) {
        (window as any).__ctPinPanel(activeComp.layoutItem, 0);  // 0 = Left
        return activeComp.layoutItem?.tab?.titleElement?.textContent?.trim() ?? "main.py";
      }
      return "main.py";
    }) as string;

    await layoutUpdatedPromisePin;

    // NOTE: there is deliberately no `__ctRedrawAll()` call here.  It does not
    // render the strips at all — `renderer.redrawAll` only calls
    // `sharedDirectRedraw`, which `layout.nim` installs to refresh the menu, the
    // status bar and the fixed search box.  `#auto-hide-strip-left` is rendered
    // solely from `autoHideState.onChanged`, which `pinPanel` invokes.  A forced
    // redraw here would hide a missing render trigger rather than reveal one.

    const remainingEditor = ctPage.locator(".lm_tab .lm_title", {
      hasText: editorTitle,
    });
    const leftTabs = ctPage.locator("#auto-hide-strip-left .auto-hide-strip-tab");
    const overlay = ctPage.locator(OVERLAY_SELECTOR);

    await expect(async () => {
      // The editor tab should no longer be visible in the GL layout.
      await expect(remainingEditor).toHaveCount(0, { timeout: 1000 });

      // The Left edge strip should have exactly one tab with the editor title.
      await expect(leftTabs).toHaveCount(1, { timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });

    // The strip tab must be a STABLE DOM node that survives while nothing is
    // interacting with it.  `Auto-Hide-Panes.md` §3.2 makes the tab the panel's
    // only hover/click/right-click surface and §3.3 makes its right-click menu
    // the only unpin affordance — none of which a user (or the `hover()` below)
    // can reach if the node keeps being replaced.  Both known ways it was being
    // replaced fail here: collapsed mode re-asserting itself (which swaps the
    // tabs for a 1px line), and a spurious `autoHideState.onChanged` (which
    // rebuilds the whole strip).  Asserting node identity names the defect; the
    // hover that follows only fails by timeout, which reads like a slow app.
    const tabHandle = await leftTabs.first().elementHandle();
    expect(tabHandle).not.toBeNull();
    await ctPage.waitForTimeout(1500);
    const stillAttached = await tabHandle!.evaluate((el) => el.isConnected);
    expect(
      stillAttached,
      "the auto-hide strip tab was re-created while nothing interacted with " +
        "it — the edge strip is being rebuilt in a loop",
    ).toBe(true);
    await tabHandle!.dispose();

    // Hover the left strip tab to open the overlay (a click would dock the
    // editor inline instead — see page-objects/auto-hide-strip.ts).
    await openOverlayFromTab(ctPage, leftTabs.first(), WAIT_TIMEOUT_MS);

    // Unpin through the tab's context menu.  This used to click
    // `#auto-hide-overlay-unpin-btn`; a6151510e hid the overlay header row
    // outright ("the active strip tab acts as the panel header") and moved the
    // buttons onto the tab, then 1af471302 deleted those buttons too, leaving
    // the context menu f214d703b had just added as the only unpin affordance.
    // Right-clicking keeps the pointer inside the left strip, so the 300 ms
    // mouse-leave dismissal `auto_hide_overlay.nim` arms on strip exit is
    // never started and the "overlay hidden" assertion below still measures
    // the unpin rather than an auto-dismiss.
    const layoutUpdatedPromise = ctPage.evaluate(() => {
      return new Promise<void>((resolve) => {
        window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
      });
    });

    await unpinFromStripTabContextMenu(ctPage, leftTabs.first(), WAIT_TIMEOUT_MS);

    await layoutUpdatedPromise;

    await expect(async () => {
      // Overlay should be hidden.
      await expect(overlay).not.toHaveClass(/visible/, { timeout: 1000 });

      // Left strip should have zero tabs now.
      await expect(leftTabs).toHaveCount(0, { timeout: 1000 });

      // The editor tab should be restored in the GL layout.
      await expect(remainingEditor.first()).toBeVisible({ timeout: 1000 });
    }).toPass({ timeout: WAIT_TIMEOUT_MS });
  });
});

// ---------------------------------------------------------------------------
// #608 (M41) — the pinned set must survive a restart, and pinning FILES must
// not destroy the saved layout.
//
// Before the fix, `ui/layout.nim` posted the serialised auto-hide state to
// `CODETRACER::save-auto-hide-state` and NOTHING listened on that channel —
// the string occurred at exactly one site in the whole repository, the send —
// while `restoreAutoHideState` had zero call sites.  So a pinned panel was
// simply gone on the next launch, and because pinning removes the component
// from the GoldenLayout tree, pinning FILES additionally made
// `isValidLayoutConfig` reject the saved layout, at which point
// `resetLayoutToDefault` DELETED it.  That is the "customisations lost with
// no visible error" half of the report.
//
// The headless guard for the same invariants (the serialised shape, and the
// validator consulting the auto-hide state) is
// `src/tests/gui/tests/layout/layout_config_roundtrip_test.nim`.
// ---------------------------------------------------------------------------

/**
 * The isolated config directory the GUI fixtures point the app at.
 * `lib/fixtures.ts` assigns `process.env.XDG_CONFIG_HOME` at import time, so
 * this is already the per-run directory by the time the spec body runs.
 */
const userConfigDir = path.join(
  process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"),
  "codetracer",
);
const autoHideStatePath = path.join(userConfigDir, "auto_hide_state.json");
const editLayoutPath = path.join(userConfigDir, "default_edit_layout.json");
const editTestFolder = path.join(codetracerInstallDir, "test-programs");

/** Content ordinals from `common_types/codetracer_features/frontend.nim`. */
const CONTENT_FILESYSTEM = 9;
const CONTENT_EVENT_LOG = 8;
/** `AutoHideEdge` ordinals from `ui/auto_hide.nim`: Left = 0, Right = 1, Bottom = 2. */
const EDGE_LEFT = 0;

function removeIfPresent(target: string): void {
  if (fs.existsSync(target)) fs.unlinkSync(target);
}

function writeAutoHideState(panels: unknown[]): void {
  if (!fs.existsSync(userConfigDir)) {
    fs.mkdirSync(userConfigDir, { recursive: true });
  }
  fs.writeFileSync(autoHideStatePath, JSON.stringify({ panels }), "utf8");
}

function pinnedFilesystemPanel() {
  return {
    edge: EDGE_LEFT,
    title: "FILES",
    content: CONTENT_FILESYSTEM,
    componentId: 0,
    overlayWidth: 320,
    overlayHeight: 0,
    config: {
      type: "component",
      componentType: "genericUiComponent",
      componentState: {
        id: 0,
        label: "filesystemComponent-0",
        content: CONTENT_FILESYSTEM,
        isEditor: false,
      },
      title: "FILES",
    },
  };
}

test.describe("Auto-hide state survives a restart", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.afterEach(() => {
    // Never leak a pinned panel into a later test in this worker: the config
    // directory is shared and the fixture only resets `default_layout.json`.
    removeIfPresent(autoHideStatePath);
  });

  test("pinning a panel writes the auto-hide state to disk", async ({ ctPage }) => {
    removeIfPresent(autoHideStatePath);

    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    const pinnedTitle = await pinToEdge(ctPage, "Left", 0);

    // The write is an async IPC round trip through the index process, so poll
    // rather than assert once.
    await expect(() => {
      expect(fs.existsSync(autoHideStatePath)).toBe(true);
      const saved = JSON.parse(fs.readFileSync(autoHideStatePath, "utf8"));
      expect(Array.isArray(saved.panels)).toBe(true);
      const titles = saved.panels.map((panel: { title: string }) => panel.title);
      expect(titles).toContain(pinnedTitle);
    }).toPass({ timeout: WAIT_TIMEOUT_MS });

    // The persisted entry must carry everything a restore needs and nothing
    // that cannot survive a process boundary.
    const saved = JSON.parse(fs.readFileSync(autoHideStatePath, "utf8"));
    const entry = saved.panels.find(
      (panel: { title: string }) => panel.title === pinnedTitle,
    );
    expect(entry).toBeTruthy();
    expect(entry.config).toBeTruthy();
    expect(entry.config.componentState).toBeTruthy();
    expect(entry).toHaveProperty("edge");
    expect(entry).toHaveProperty("overlayWidth");
    expect(entry).toHaveProperty("overlayHeight");
    for (const transient of ["liveElement", "domTab", "containerElement", "isUnpinning"]) {
      expect(entry).not.toHaveProperty(transient);
    }
  });
});

test.describe("A persisted pinned panel is restored on the next launch", () => {
  test.setTimeout(120_000);
  // `preserveAutoHideState` keeps the launch fixture's config reset from
  // deleting the state this suite seeds below — the whole point here is that
  // a file written before launch survives into the app.
  test.use({
    sourcePath: fixture.traceDir,
    launchMode: "trace-folder",
    preserveAutoHideState: true,
  });

  // Written BEFORE the `ctPage` fixture launches the app — a hook that
  // requests no fixture runs first, which is what makes this a real restart
  // rather than a same-process reload.
  test.beforeEach(() => {
    writeAutoHideState([pinnedFilesystemPanel()]);
  });

  test.afterEach(() => {
    removeIfPresent(autoHideStatePath);
  });

  test("the pinned FILES panel comes back as a left strip tab", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    const leftTabs = ctPage.locator("#auto-hide-strip-left .auto-hide-strip-tab");
    await expect(leftTabs).toHaveCount(1, { timeout: WAIT_TIMEOUT_MS });
    await expect(leftTabs.first()).toHaveText(/FILES/i);

    // The standalone bottom panes must still register exactly once — the
    // restore runs before that 500 ms loop precisely so its
    // `findPanelByContent` skip can see restored entries.
    await expect(bottomStripTabs(ctPage)).toHaveCount(DEFAULT_BOTTOM_TAB_COUNT, {
      timeout: WAIT_TIMEOUT_MS,
    });
  });
});

test.describe("Pinning FILES does not reset the layout", () => {
  test.setTimeout(120_000);
  test.use({
    launchMode: "edit",
    editFolderPath: editTestFolder,
    preserveAutoHideState: true,
  });

  // Edit mode is used because the `ctPage` fixture copies the bundled default
  // over `default_layout.json` on every setup (`lib/layout-reset.ts`), which
  // would erase the scenario before the app saw it.  It leaves
  // `default_edit_layout.json` alone.
  test.beforeEach(() => {
    removeIfPresent(editLayoutPath + ".broken");
    // A saved layout with NO Filesystem component in the GoldenLayout tree —
    // exactly what the app writes once the user pins FILES to an edge …
    fs.mkdirSync(userConfigDir, { recursive: true });
    fs.writeFileSync(
      editLayoutPath,
      JSON.stringify(
        {
          settings: { constrainDragToContainer: true, reorderEnabled: true },
          dimensions: { borderWidth: 4, headerHeight: 32 },
          root: {
            type: "row",
            content: [
              {
                type: "stack",
                size: "100%",
                activeItemIndex: 0,
                content: [
                  {
                    type: "component",
                    componentType: "genericUiComponent",
                    componentState: {
                      id: 0,
                      label: "eventLogComponent-0",
                      content: CONTENT_EVENT_LOG,
                    },
                    title: "EVENTS",
                  },
                ],
              },
            ],
          },
        },
        null,
        2,
      ),
      "utf8",
    );
    // … together with the auto-hide state that says where FILES actually is.
    writeAutoHideState([pinnedFilesystemPanel()]);
  });

  test.afterEach(() => {
    removeIfPresent(autoHideStatePath);
    removeIfPresent(editLayoutPath);
    removeIfPresent(editLayoutPath + ".broken");
  });

  test("a layout whose Filesystem panel is pinned is not treated as corrupt", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

    // `resetLayoutToDefault` moves the file it rejects aside to `.broken`
    // before replacing it.  Its absence is the assertion that the validator
    // accepted the layout instead of destroying the user's arrangement.
    expect(fs.existsSync(editLayoutPath + ".broken")).toBe(false);

    // And FILES is present as a pinned strip tab rather than lost entirely.
    const leftTabs = ctPage.locator("#auto-hide-strip-left .auto-hide-strip-tab");
    await expect(leftTabs).toHaveCount(1, { timeout: WAIT_TIMEOUT_MS });
    await expect(leftTabs.first()).toHaveText(/FILES/i);
  });
});
