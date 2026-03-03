import type { Locator, Page } from "@playwright/test";
import { retry } from "../../lib/retry-helpers";

/**
 * Playwright abstraction over the command palette component.
 *
 * Port of ui-tests/PageObjects/CommandPalette/CommandPalette.cs
 */
export class CommandPalette {
  private readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  private get root(): Locator {
    return this.page.locator("#command-view");
  }

  private get queryInput(): Locator {
    return this.page.locator("#command-query-text");
  }

  private get resultsContainer(): Locator {
    return this.page.locator("#command-results");
  }

  private get resultItems(): Locator {
    return this.resultsContainer.locator(".command-result");
  }

  private get matchingResultItems(): Locator {
    return this.resultsContainer.locator(".command-result:not(.empty)");
  }

  async open(): Promise<void> {
    await this.page.keyboard.press("Control+KeyP");
    await this.root.waitFor({ state: "visible" });
  }

  async close(): Promise<void> {
    await this.page.keyboard.press("Escape");
    await this.root.waitFor({ state: "hidden" });
  }

  async isVisible(): Promise<boolean> {
    return this.root.isVisible();
  }

  async resultTexts(): Promise<string[]> {
    const items = await this.resultItems.all();
    const results: string[] = [];
    for (const item of items) {
      results.push((await item.innerText()).trim());
    }
    return results;
  }

  async waitForResults(count = 1): Promise<void> {
    await retry(async () => (await this.resultItems.count()) >= count);
  }

  async waitForMatchingResults(count = 1): Promise<void> {
    await retry(async () => (await this.matchingResultItems.count()) >= count);
  }

  async executeCommand(commandText: string): Promise<void> {
    await this.ensureVisible();
    await this.queryInput.fill(`:${commandText}`);
    await this.waitForMatchingResults();
    await this.queryInput.press("Enter");
    await this.root.waitFor({ state: "hidden" });
  }

  async executeSymbolSearch(symbolQuery: string, resultIndex = 0): Promise<void> {
    await this.ensureVisible();
    await this.queryInput.fill(`:sym ${symbolQuery}`);
    await this.waitForResults();
    await this.resultItems.nth(resultIndex).click();
    await this.root.waitFor({ state: "hidden" });
  }

  private async ensureVisible(): Promise<void> {
    if (!(await this.isVisible())) {
      await this.open();
    }
  }
}
