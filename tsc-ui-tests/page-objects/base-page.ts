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

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !(style?.includes("none"));
  }
}
