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
    // The results list is `div.command-results` inside the palette
    // (`CommandPaletteResultsClass`, `views/isonim_command_palette_view.nim`).
    // It has had no `command-results` id since the palette moved to that
    // view, so the old `#command-results` matched nothing and every wait
    // for results timed out.
    return this.root.locator(".command-results");
  }

  private get resultItems(): Locator {
    return this.resultsContainer.locator(".command-result");
  }

  private get matchingResultItems(): Locator {
    return this.resultsContainer.locator(".command-result:not(.empty)");
  }

  /**
   * Whether the palette is open. `#command-view` is the omnibox in the
   * window's header and is always on screen; the palette is OPEN when its
   * `.command-container` lacks the `hidden` modifier
   * (`CommandPaletteHiddenModifier`, `views/isonim_command_palette_view.nim`).
   */
  private openState(): Promise<boolean> {
    return this.page.evaluate(() => {
      const c = document.getElementById("command-view")?.closest(".command-container");
      return !!c && !c.classList.contains("hidden");
    });
  }

  private async waitOpen(open: boolean): Promise<void> {
    await retry(async () => (await this.openState()) === open);
  }

  async open(): Promise<void> {
    await this.page.keyboard.press("Control+KeyP");
    await this.waitOpen(true);
  }

  async close(): Promise<void> {
    await this.page.keyboard.press("Escape");
    await this.waitOpen(false);
  }

  async isVisible(): Promise<boolean> {
    return this.openState();
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
    await this.waitOpen(false);
  }

  async executeSymbolSearch(symbolQuery: string, resultIndex = 0): Promise<void> {
    await this.ensureVisible();
    await this.queryInput.fill(`:sym ${symbolQuery}`);
    await this.waitForResults();
    await this.resultItems.nth(resultIndex).click();
    await this.waitOpen(false);
  }

  private async ensureVisible(): Promise<void> {
    if (!(await this.isVisible())) {
      await this.open();
    }
  }
}
