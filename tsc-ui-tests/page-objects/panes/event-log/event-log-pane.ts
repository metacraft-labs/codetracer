import type { Locator, Page } from "@playwright/test";
import { EventRow, EventElementType } from "./event-row";
import { debugLogger } from "../../../lib/debug-logger";

const POST_FILTER_DELAY_MS = 100;

/**
 * Event log pane containing multiple event rows.
 *
 * Port of ui-tests/PageObjects/Panes/EventLog/EventLogPane.cs
 */
export class EventLogPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private events: EventRow[] = [];

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

  footerContainer(): Locator {
    return this.root.locator(".data-tables-footer");
  }

  rowsInfoContainer(): Locator {
    return this.footerContainer().locator(".data-tables-footer-info");
  }

  async rows(): Promise<number> {
    const klass = (await this.footerContainer().getAttribute("class")) ?? "";
    const m = klass.match(/(\d*)to/);
    return m ? parseInt(m[1], 10) || 0 : 0;
  }

  async toRow(): Promise<number> {
    const text = (await this.rowsInfoContainer().textContent()) ?? "";
    const m = text.match(/(\d*)\sof/);
    return m ? parseInt(m[1], 10) || 0 : 0;
  }

  async ofRows(): Promise<number> {
    const text = (await this.rowsInfoContainer().textContent()) ?? "";
    const m = text.match(/of\s(\d*)/);
    return m ? parseInt(m[1], 10) || 0 : 0;
  }

  private eventElementRoots(): Locator {
    return this.root.locator(".eventLog-dense-table tbody tr");
  }

  async eventElements(forceReload = false): Promise<EventRow[]> {
    if (forceReload || this.events.length === 0) {
      const roots = await this.eventElementRoots().all();
      this.events = roots.map((r) => new EventRow(r, EventElementType.EventLog));
    }
    return this.events;
  }

  async rowCount(): Promise<number> {
    return this.eventElementRoots().count();
  }

  async rowByIndex(index: number, forceReload = false): Promise<EventRow> {
    debugLogger.log(`EventLogPane: locating row ${index} (forceReload=${forceReload})`);
    const rows = await this.eventElements(forceReload);
    for (const row of rows) {
      if ((await row.index()) === index) {
        debugLogger.log(`EventLogPane: found row ${index}`);
        return row;
      }
    }
    debugLogger.log(`EventLogPane: row ${index} not found`);
    throw new Error(`Event log row with index ${index} was not found.`);
  }

  private filterButton(): Locator {
    return this.root.getByText("Filter", { exact: true }).first();
  }

  private dropdownRoot(): Locator {
    return this.page.locator("#dropdown-container-id");
  }

  async activateTraceEventsFilter(): Promise<void> {
    await this.filterButton().click();
    const traceButton = this.dropdownRoot().getByText("Trace events", { exact: true });
    await traceButton.waitFor({ state: "visible" });
    await traceButton.click();
    await this.page.keyboard.press("Escape");
    await this.page.waitForTimeout(POST_FILTER_DELAY_MS);
  }

  async activateRecordedEventsFilter(): Promise<void> {
    await this.filterButton().click();
    const recordedButton = this.dropdownRoot().getByText("Recorded events", { exact: true });
    await recordedButton.waitFor({ state: "visible" });
    await recordedButton.click();
    await this.page.keyboard.press("Escape");
    await this.page.waitForTimeout(POST_FILTER_DELAY_MS);
  }
}
