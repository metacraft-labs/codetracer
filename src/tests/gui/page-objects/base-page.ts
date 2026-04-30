import type { Locator, Page } from "@playwright/test";

/**
 * Base page abstraction. All page objects that need a Page reference
 * should extend this class.
 */
export class BasePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }
}

/**
 * Representation of a generic pane/tab within the Golden Layout container.
 *
 * Provides the tab button locator and visibility check shared by all
 * specialized pane page objects.
 */
export class TabObject {
  readonly page: Page;
  readonly root: Locator;
  tabButtonText: string;

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  tabButton(): Locator {
    return this.page
      .locator(".lm_title", { hasText: this.tabButtonText })
      .first();
  }

  /**
   * Click the tab button, working around the "element is outside of the
   * viewport" issue that occurs on Windows (and Xvfb headless Linux)
   * where the Electron window is maximized but GoldenLayout tab
   * buttons are positioned beyond Playwright's perceived viewport.
   *
   * Three layered attempts:
   *
   *   1. plain `click()` — succeeds in most ordinary cases.
   *   2. `scrollIntoView` + `click({ force: true })` — handles the
   *      common case where the element is rendered but Playwright's
   *      viewport detection rejects it.
   *   3. `dispatchEvent('click')` — bypasses Playwright's viewport
   *      handling entirely. Required under Xvfb where step 2 still
   *      fails with "outside of the viewport"; GoldenLayout's tab
   *      handler runs from a synthetic click event just fine.
   */
  async clickTab(): Promise<void> {
    const btn = this.tabButton();
    try {
      await btn.click({ timeout: 5_000 });
    } catch {
      try {
        // Force-scroll into view and retry with force click
        await btn.evaluate((el: HTMLElement) => {
          el.scrollIntoView({ block: "center", inline: "center" });
        });
        await btn.click({ force: true, timeout: 5_000 });
      } catch {
        // Final fallback: synthetic dispatch — GoldenLayout's tab
        // handler doesn't care whether the click came from real input
        // or a synthetic event, and dispatching sidesteps Playwright's
        // viewport rejection entirely.
        await btn.dispatchEvent("click");
      }
    }
  }

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !(style?.includes("none"));
  }
}
