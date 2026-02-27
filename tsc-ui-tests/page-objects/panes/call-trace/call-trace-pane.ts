import type { Locator, Page } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";
import { ValueComponentView } from "../../components/value-component-view";
import { CallTraceEntry } from "./call-trace-entry";
import { retry } from "../../../lib/retry-helpers";

/**
 * Pane representing the call trace view and its rendered call hierarchy.
 *
 * Port of ui-tests/PageObjects/Panes/CallTrace/CallTracePane.cs
 */
export class CallTracePane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private readonly contextMenu: ContextMenu;
  private entries: CallTraceEntry[] = [];

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
    this.contextMenu = new ContextMenu(page);
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  linesContainer(): Locator {
    return this.root.locator(".calltrace-lines");
  }

  searchInput(): Locator {
    return this.root.locator(".calltrace-search-input");
  }

  searchResultsContainer(): Locator {
    return this.root.locator(".call-search-results");
  }

  async waitForReady(): Promise<void> {
    await retry(
      async () =>
        (await this.linesContainer().locator(".calltrace-call-line").count()) > 0,
    );
  }

  async getEntries(forceReload = false): Promise<CallTraceEntry[]> {
    if (forceReload || this.entries.length === 0) {
      await this.waitForReady();
      const roots = await this.linesContainer()
        .locator(".calltrace-call-line")
        .all();
      this.entries = roots.map(
        (l) => new CallTraceEntry(this, l, this.contextMenu),
      );
    }
    return this.entries;
  }

  invalidateEntries(): void {
    this.entries = [];
  }

  /**
   * Finds the first call trace entry matching the function name.
   * Entries scrolled out of the virtualized viewport are silently skipped.
   */
  async findEntry(
    functionName: string,
    forceReload = false,
  ): Promise<CallTraceEntry | null> {
    const entries = await this.getEntries(forceReload);
    for (const entry of entries) {
      try {
        const name = await entry.functionName();
        if (name.toLowerCase() === functionName.toLowerCase()) {
          return entry;
        }
      } catch {
        // Entry may be scrolled out of the virtualized viewport
      }
    }
    return null;
  }

  async search(query: string): Promise<void> {
    await this.searchInput().fill(query);
    await this.searchInput().press("Enter");
    await retry(
      async () =>
        (await this.searchResultsContainer().locator(".search-result").count()) > 0,
    );
  }

  async clearSearch(): Promise<void> {
    await this.searchInput().fill("");
    await retry(
      async () =>
        (await this.searchResultsContainer().locator(".search-result").count()) === 0,
    );
  }

  async activeTooltip(): Promise<ValueComponentView | null> {
    const tooltip = this.root.locator(".call-tooltip");
    if ((await tooltip.count()) === 0) return null;
    return new ValueComponentView(tooltip.locator(".value-expanded").first());
  }
}
