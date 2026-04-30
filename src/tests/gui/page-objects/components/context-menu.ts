import type { Locator, Page } from "@playwright/test";

const DEFAULT_CONTAINER_SELECTOR = "#context-menu-container";
const DEFAULT_ITEM_SELECTOR = ".context-menu-item";
const DEFAULT_HINT_SELECTOR = ".context-menu-hint";

export interface ContextMenuEntry {
  text: string;
  hint: string;
}

export interface ContextMenuSelectors {
  container?: string;
  item?: string;
  hint?: string;
}

/**
 * Utility wrapper for interacting with the global CodeTracer context menu.
 *
 * Port of ui-tests/PageObjects/Components/ContextMenu.cs
 */
export class ContextMenu {
  private readonly page: Page;
  private readonly containerSelector: string;
  private readonly itemSelector: string;
  private readonly hintSelector: string;

  constructor(page: Page, selectors?: ContextMenuSelectors) {
    this.page = page;
    this.containerSelector = selectors?.container ?? DEFAULT_CONTAINER_SELECTOR;
    this.itemSelector = selectors?.item ?? DEFAULT_ITEM_SELECTOR;
    this.hintSelector = selectors?.hint ?? DEFAULT_HINT_SELECTOR;
  }

  get container(): Locator {
    return this.page.locator(this.containerSelector);
  }

  async waitForVisible(): Promise<void> {
    await this.container.waitFor({ state: "visible" });
  }

  async waitForHidden(): Promise<void> {
    await this.container.waitFor({ state: "hidden" });
  }

  /**
   * Retrieves the menu entries currently displayed.
   *
   * Context menu items may contain a hint element (e.g., keyboard shortcut)
   * nested inside the item. Since innerText() returns the combined text of all
   * child elements, we subtract the hint text to get just the action name.
   */
  async getEntries(): Promise<ContextMenuEntry[]> {
    const items = await this.container.locator(this.itemSelector).all();
    const entries: ContextMenuEntry[] = [];

    for (const item of items) {
      const fullText = (await item.innerText()).trim();
      if (fullText.length === 0) {
        continue;
      }

      const hintLocator = item.locator(this.hintSelector);
      const hintCount = await hintLocator.count();
      const hint = hintCount > 0
        ? (await hintLocator.first().innerText()).trim()
        : "";

      let actionText = fullText;
      if (hint.length > 0) {
        const hintIndex = actionText.indexOf(hint);
        if (hintIndex >= 0) {
          actionText = actionText.substring(0, hintIndex).trim();
        }
      }

      entries.push({ text: actionText, hint });
    }

    return entries;
  }

  /**
   * Selects an entry whose text matches `entryText`.
   * Throws when the entry cannot be found.
   *
   * Uses startsWith comparison because menu items may contain
   * hint text after the main action text.
   */
  async select(entryText: string): Promise<void> {
    const items = this.container.locator(this.itemSelector);
    const count = await items.count();

    for (let i = 0; i < count; i++) {
      const item = items.nth(i);
      const text = (await item.innerText()).trim();
      if (text.toLowerCase().startsWith(entryText.toLowerCase())) {
        await item.click();
        await this.waitForHidden();
        return;
      }
    }

    throw new Error(
      `Context menu entry '${entryText}' was not found. Available items: ${count}`,
    );
  }

  /**
   * Attempts to close the context menu by pressing Escape.
   */
  async dismiss(): Promise<void> {
    if (await this.container.isVisible()) {
      await this.page.keyboard.press("Escape");
      await this.waitForHidden();
    }
  }

  /**
   * Asserts that the current menu matches the expected set of entries (by text).
   */
  async ensureEntries(expectedEntries: string[]): Promise<void> {
    const actual = await this.getEntries();

    if (actual.length !== expectedEntries.length) {
      const actualTexts = actual.map((e) => e.text).join(", ");
      throw new Error(
        `Context menu mismatch: expected ${expectedEntries.length} entries but saw ${actual.length}. ` +
        `Actual entries: ${actualTexts}`,
      );
    }

    for (let i = 0; i < expectedEntries.length; i++) {
      const expected = expectedEntries[i];
      const actualEntry = actual[i];
      if (actualEntry.text.toLowerCase() !== expected.toLowerCase()) {
        throw new Error(
          `Context menu mismatch at index ${i}: expected '${expected}' but found '${actualEntry.text}'.`,
        );
      }
    }
  }
}

/**
 * ContextMenu factory for jstree context menus (different selectors).
 */
export function createJsTreeContextMenu(page: Page): ContextMenu {
  return new ContextMenu(page, {
    container: ".vakata-context",
    item: "li:not(.vakata-context-separator)",
    hint: ".vakata-contextmenu-shortcut",
  });
}
