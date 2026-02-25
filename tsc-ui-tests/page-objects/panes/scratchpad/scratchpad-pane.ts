import type { Locator, Page } from "@playwright/test";
import { ScratchpadEntry } from "./scratchpad-entry";
import { retry } from "../../../lib/retry-helpers";

/**
 * Page object wrapping the scratchpad pane and its stored values.
 *
 * Port of ui-tests/PageObjects/Panes/Scratchpad/ScratchpadPane.cs
 */
export class ScratchpadPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private entries_: ScratchpadEntry[] = [];

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !(style?.includes("none"));
  }

  entriesContainer(): Locator {
    return this.root.locator(".value-components-container");
  }

  async entries(forceReload = false): Promise<ScratchpadEntry[]> {
    if (forceReload || this.entries_.length === 0) {
      const roots = await this.entriesContainer()
        .locator(".scratchpad-value-view")
        .all();
      this.entries_ = roots.map((l) => new ScratchpadEntry(l));
    }
    return this.entries_;
  }

  async entryCount(): Promise<number> {
    return this.entriesContainer().locator(".scratchpad-value-view").count();
  }

  async waitForEntryCount(count: number): Promise<void> {
    await retry(async () => (await this.entryCount()) >= count);
  }

  async waitForNewEntry(previousCount: number): Promise<void> {
    await this.waitForEntryCount(previousCount + 1);
  }

  async findEntry(
    expression: string,
    forceReload = false,
  ): Promise<ScratchpadEntry | null> {
    const entries = await this.entries(forceReload);
    for (const entry of entries) {
      const expr = await entry.expression();
      if (expr === expression) {
        return entry;
      }
    }
    return null;
  }

  async entryMap(forceReload = false): Promise<Map<string, ScratchpadEntry>> {
    const map = new Map<string, ScratchpadEntry>();
    const entries = await this.entries(forceReload);
    for (const entry of entries) {
      const expr = await entry.expression();
      map.set(expr, entry);
    }
    return map;
  }

  invalidateCache(): void {
    this.entries_ = [];
  }

  async waitForEntry(expression: string): Promise<ScratchpadEntry> {
    let found: ScratchpadEntry | null = null;
    await retry(async () => {
      this.invalidateCache();
      found = await this.findEntry(expression, true);
      return found !== null;
    });
    return found!;
  }
}
