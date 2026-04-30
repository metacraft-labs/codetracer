/**
 * Auto-hide panes E2E tests.
 *
 * Verifies the pin-to-edge workflow: pinning panels to edge strips,
 * opening overlays via strip tabs, unpinning back to the GL layout,
 * and dismissing overlays via Escape / backdrop click.
 *
 * DOM elements under test (defined in index.html and rendered by
 * auto_hide.nim / auto_hide_overlay.nim):
 *   #auto-hide-layout-row        — flex row: left strip + #ROOT + right strip
 *   #auto-hide-strip-left        — left edge strip (ID, flex item beside GL)
 *   #auto-hide-strip-right       — right edge strip (ID, flex item beside GL)
 *   .auto-hide-bottom-tabs       — bottom tabs rendered inside #status-base
 *   .auto-hide-strip-tab         — individual tab within a strip
 *   #auto-hide-overlay           — slide-in overlay container
 *   #auto-hide-overlay-title     — title text inside overlay header
 *   #auto-hide-overlay-unpin-btn — "Unpin" button in overlay header
 *   #auto-hide-overlay-close-btn — close button in overlay header
 *   #auto-hide-backdrop          — click-to-dismiss backdrop behind overlay
 *   .layout-buttons-container    — GL stack header dropdown toggle
 *   .layout-dropdown-node        — individual item inside the dropdown
 */

import { test, expect, wait } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

/** Timeout for waiting on DOM mutations after pin/unpin actions. */
const ACTION_SETTLE_MS = 1500;

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
  await expect(dropdown).not.toHaveClass(/hidden/, { timeout: 5_000 });

  // Wait for the desired menu item to be visible so the DOM is populated.
  const menuItem = dropdown.locator(".layout-dropdown-node", {
    hasText: itemText,
  });
  await expect(menuItem).toBeVisible({ timeout: 5_000 });

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

  // Allow the pin action to settle (DOM removal + strip re-render).
  await wait(ACTION_SETTLE_MS);

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

test.describe("Auto-hide panes", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("strip tabs hidden when no panels pinned", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear (they load after a 500ms delay).
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });

    // BUILD, PROBLEMS, and SEARCH RESULTS are default bottom auto-hide tabs.
    // No user-pinned panels should be present, so only the 3 defaults exist.
    const bottomTabs = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab");
    await expect(bottomTabs).toHaveCount(3);

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
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });

    // Record the initial number of GL stacks so we can verify one was removed.
    const initialStackCount = await ctPage.locator(".lm_stack").count();

    // There are already 3 default bottom tabs (BUILD, PROBLEMS, SEARCH RESULTS).
    const bottomStrip = ctPage.locator(".auto-hide-bottom-tabs");
    const bottomTabs = bottomStrip.locator(".auto-hide-strip-tab");
    const initialBottomCount = await bottomTabs.count();

    // Pin the active tab of the first stack to the bottom edge.
    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // One more strip tab should now exist in the bottom tabs.
    await expect(bottomTabs).toHaveCount(initialBottomCount + 1, { timeout: 5_000 });

    // The pinned panel title should appear among the bottom tabs.
    const pinnedTab = bottomStrip.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await expect(pinnedTab).toHaveCount(1);

    // The panel should have been removed from the GL layout (one fewer
    // component, which may reduce the stack count or the tab count).
    const currentStackCount = await ctPage.locator(".lm_stack").count();
    // If the stack had only one tab, the entire stack is removed.
    // If it had multiple tabs, the stack remains but with fewer tabs.
    // Either way, the total visible tab count should have decreased.
    const remainingTabsWithTitle = ctPage.locator(".lm_tab .lm_title", {
      hasText: pinnedTitle,
    });
    await expect(remainingTabsWithTitle).toHaveCount(0);
  });

  test("strip tab click shows overlay", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Click the strip tab matching the pinned panel.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await expect(stripTab).toBeVisible({ timeout: 5_000 });
    await stripTab.click();
    await wait(500);

    // The overlay should become visible (has the "visible" CSS class).
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // The overlay title should match the pinned panel.
    const overlayTitle = ctPage.locator("#auto-hide-overlay-title");
    await expect(overlayTitle).toHaveText(pinnedTitle);
  });

  test("overlay unpin restores panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });
    const initialTabCount = await ctPage.locator(".auto-hide-strip-tab").count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by clicking the strip tab for the pinned panel.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Click "Unpin" to restore the panel back into GL.
    // Use evaluate() for a direct DOM click to avoid the mouse-leave
    // auto-dismiss race: Playwright's mouse movement to reach the button
    // can briefly exit the overlay bounds, triggering the 300ms dismiss
    // timer before the click lands.
    const unpinBtn = ctPage.locator("#auto-hide-overlay-unpin-btn");
    await expect(unpinBtn).toBeVisible();
    await ctPage.evaluate(() => {
      const btn = document.getElementById("auto-hide-overlay-unpin-btn");
      if (btn) btn.click();
    });
    await wait(ACTION_SETTLE_MS);

    // The overlay should no longer be visible.
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The pinned strip tab should have been removed (back to initial count).
    const remainingTabs = ctPage.locator(".auto-hide-strip-tab");
    await expect(remainingTabs).toHaveCount(initialTabCount);

    // The panel should be back in the GL layout — look for its title
    // among GL tab titles.
    const restoredTab = ctPage.locator(".lm_tab .lm_title", {
      hasText: pinnedTitle,
    });
    await expect(restoredTab.first()).toBeVisible({ timeout: 5_000 });
  });

  test("overlay dismisses on Escape", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });
    const initialTabCount = await ctPage.locator(".auto-hide-strip-tab").count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by clicking the pinned panel's strip tab.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Press Escape to dismiss.
    await ctPage.keyboard.press("Escape");
    await wait(500);

    // The overlay should be hidden (no "visible" class).
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The strip tab should still be present (Escape only hides the
    // overlay; it does not unpin the panel). Total count = initial + 1.
    const tabsAfter = ctPage.locator(".auto-hide-strip-tab");
    await expect(tabsAfter).toHaveCount(initialTabCount + 1);
  });

  test("overlay dismisses on backdrop click", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });
    const initialTabCount = await ctPage.locator(".auto-hide-strip-tab").count();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by clicking the pinned panel's strip tab.
    const stripTab = ctPage.locator(".auto-hide-strip-tab", { hasText: pinnedTitle });
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Click the backdrop to dismiss.
    const backdrop = ctPage.locator("#auto-hide-backdrop");
    // The backdrop may be zero-sized when not shown; force the click
    // at a known position to ensure the event fires.
    await backdrop.click({ force: true });
    await wait(500);

    // The overlay should be hidden.
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The strip tab should still be present. Total count = initial + 1.
    const tabsAfter = ctPage.locator(".auto-hide-strip-tab");
    await expect(tabsAfter).toHaveCount(initialTabCount + 1);
  });

  test.skip("multiple panels can be pinned to different edges", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for default bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 5_000 });
    const initialBottomCount = await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").count();

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
    await wait(ACTION_SETTLE_MS);

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
    await wait(ACTION_SETTLE_MS);
    // Force a strip redraw in case the onChanged callback didn't fire.
    await ctPage.evaluate(() => {
      if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
    });
    await wait(500);

    // Bottom tabs should have one more than the initial default count.
    const bottomTabs = ctPage
      .locator(".auto-hide-bottom-tabs .auto-hide-strip-tab");
    await expect(bottomTabs).toHaveCount(initialBottomCount + 1, { timeout: 5_000 });
    // The pinned panel should appear among bottom tabs.
    const pinnedBottomTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", { hasText: bottomTitle });
    await expect(pinnedBottomTab).toHaveCount(1);

    // Left strip should have exactly one tab.
    // Wait extra time for the Karax renderer + has-tabs class toggle.
    await wait(1000);
    const leftTabs = ctPage
      .locator("#auto-hide-strip-left .auto-hide-strip-tab");
    await expect(leftTabs).toHaveCount(1, { timeout: 10_000 });
    await expect(leftTabs.first()).toHaveText(leftTitle);

    // Neither panel should remain in the GL layout.
    const remainingBottom = ctPage.locator(".lm_tab .lm_title", {
      hasText: bottomTitle,
    });
    await expect(remainingBottom).toHaveCount(0);

    const remainingLeft = ctPage.locator(".lm_tab .lm_title", {
      hasText: leftTitle,
    });
    await expect(remainingLeft).toHaveCount(0);
  });
});
