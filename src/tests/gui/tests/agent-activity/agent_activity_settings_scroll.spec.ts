/**
 * #861: the Agent Activity settings panel keeps its scroll position while the
 * user works its dropdowns.
 *
 * The reporter scrolled the settings panel down to DELIVERY, opened "Mode" and
 * chose a value, and the panel jumped back to the top. The panel's scroll
 * container is `div.agent-settings-panel`; the view used to build a new one on
 * every dropdown open, close and change, and a new element starts at
 * `scrollTop = 0`.
 *
 * What this spec holds the product to, in the real Electron app:
 *   - opening a dropdown, choosing from it, and closing one by clicking
 *     elsewhere in the panel leave `scrollTop` where the user put it;
 *   - the scroll container is the SAME element throughout (a marker set on it
 *     before the first click is still there after the last);
 *   - the chosen value is on screen, so the panel did not simply stop
 *     updating.
 *
 * No test doubles: the app, its renderer and the pane are production code.
 * The window is made short before the panel opens, so the panel overflows and
 * has somewhere to scroll to; the spec asserts that precondition rather than
 * assuming it.
 *
 * Headless counterpart (headless-first policy):
 *   src/tests/gui/tests/agent-activity/agent_activity_settings_panel_view_test.nim
 *   (node identity of the panel over MockRenderer).
 */

import type { Locator, Page } from "@playwright/test";

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

/** Bring the Agent Activity tab forward and return its panel. */
async function openAgentActivity(page: Page): Promise<Locator> {
  const layout = new LayoutPage(page);
  await layout.waitForTraceLoaded();
  const tab = page.locator(".lm_title", { hasText: /agent activity/i }).first();
  await expect(tab).toBeAttached({ timeout: 30_000 });
  try {
    await tab.click({ timeout: 5_000 });
  } catch {
    // Xvfb can report GoldenLayout tabs as outside the viewport; the tab's
    // handler runs from a synthetic click just as well (see
    // `TabObject.clickTab`).
    await tab.dispatchEvent("click");
  }
  const pane = page.locator(".agent-ha-container").first();
  await expect(pane).toBeVisible({ timeout: 30_000 });
  return pane;
}

/** The settings panel's scroll position. */
function scrollTopOf(settings: Locator): Promise<number> {
  return settings.evaluate((el) => el.scrollTop);
}

/** The select wrapper whose trigger currently shows `value`. */
function selectShowing(settings: Locator, value: string): Locator {
  return settings
    .locator(".agent-settings-select-wrapper")
    .filter({
      has: settings.page().locator(".agent-settings-select-text", {
        hasText: new RegExp(`^${value}$`),
      }),
    })
    .first();
}

test.describe("#861 - the Agent Activity settings panel keeps its scroll position", () => {
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // A trace launch on a shared host dominates the time; the pane steps are
  // quick.
  test.setTimeout(240_000);

  test("scrolled to DELIVERY, changing Mode leaves the panel where it was", async ({
    ctPage,
    electronApp,
  }) => {
    // A short window, so the settings panel overflows its pane.
    expect(electronApp, "the Electron application handle").not.toBeNull();
    await electronApp!.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows()) {
        win.setSize(1280, 560);
      }
    });

    const pane = await openAgentActivity(ctPage);
    await pane.locator(".agent-settings-button").first().click();
    const settings = pane.locator(".agent-settings-panel");
    await expect(settings).toHaveCount(1);

    // Precondition: there is somewhere to scroll to.
    const overflow = await settings.evaluate(
      (el) => el.scrollHeight - el.clientHeight,
    );
    expect(overflow, "the settings panel overflows its pane").toBeGreaterThan(40);

    // Mark the element, then scroll down until "Mode" sits near the top of
    // the panel. Short of the bottom on purpose: at the very bottom, a list
    // closing would shrink the content and the browser would clamp
    // `scrollTop`, which is not the defect under test.
    await settings.evaluate((el) => el.setAttribute("data-spec-861", "same"));
    const mode = selectShowing(settings, "New branch");
    await mode.evaluate((wrapper) => {
      const el = wrapper.closest(".agent-settings-panel") as HTMLElement;
      const offset =
        wrapper.getBoundingClientRect().top -
        el.getBoundingClientRect().top +
        el.scrollTop;
      const max = el.scrollHeight - el.clientHeight;
      el.scrollTop = Math.max(1, Math.min(offset - 100, max - 1));
    });
    const scrolled = await scrollTopOf(settings);
    expect(scrolled, "the panel is scrolled down").toBeGreaterThan(0);
    await expect(mode).toBeInViewport();

    // Open "Mode".
    await mode.locator(".agent-settings-select-trigger").click();
    await expect(mode.locator(".agent-settings-dropdown-list")).toBeVisible();
    expect(await scrollTopOf(settings)).toBe(scrolled);

    // Choose "Existing branch".
    await mode
      .locator(".agent-settings-dropdown-item", { hasText: "Existing branch" })
      .click();
    const changed = selectShowing(settings, "Existing branch");
    await expect(changed).toHaveCount(1);
    await expect(changed.locator(".agent-settings-dropdown-list")).toHaveCount(0);
    expect(await scrollTopOf(settings)).toBe(scrolled);

    // Open "Mode" again and close it by clicking elsewhere in the panel (the
    // document-level click-outside path).
    await changed.locator(".agent-settings-select-trigger").click();
    await expect(changed.locator(".agent-settings-dropdown-list")).toBeVisible();
    expect(await scrollTopOf(settings)).toBe(scrolled);
    await settings
      .locator(".agent-settings-section-header", { hasText: "DELIVERY" })
      .click();
    await expect(changed.locator(".agent-settings-dropdown-list")).toHaveCount(0);
    expect(await scrollTopOf(settings)).toBe(scrolled);

    // The same element throughout.
    await expect(settings).toHaveAttribute("data-spec-861", "same");

    // Done still closes the panel.
    await settings.locator(".agent-settings-done").click();
    await expect(pane.locator(".agent-settings-panel")).toHaveCount(0);
  });
});
