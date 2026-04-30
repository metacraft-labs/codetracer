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
   * viewport" issue that occurs on Windows when the Electron window is
   * maximized but golden-layout tab buttons are positioned beyond the
   * visible viewport.
   *
   * Scrolls the element into view via JavaScript first, then uses a
   * force-click as a fallback if the normal click still fails.
   */
  async clickTab(): Promise<void> {
    const btn = this.tabButton();
    try {
      await btn.click({ timeout: 5_000 });
    } catch {
      // Force-scroll into view and retry with force click
      await btn.evaluate((el: HTMLElement) => {
        el.scrollIntoView({ block: "center", inline: "center" });
      });
      await btn.click({ force: true, timeout: 5_000 });
    }
  }

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !(style?.includes("none"));
  }
}
