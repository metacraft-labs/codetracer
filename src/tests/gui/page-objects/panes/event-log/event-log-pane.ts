import type { Locator, Page } from "@playwright/test";
import { EventRow, EventElementType } from "./event-row";
import { debugLogger } from "../../../lib/debug-logger";
import { retry } from "../../../lib/retry-helpers";

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
    return this.page
      .locator(".lm_title", { hasText: this.tabButtonText })
      .first();
  }

  async clickTab(): Promise<void> {
    // Layered click: plain → force → dispatchEvent. The final
    // dispatchEvent fallback is required under Xvfb where Playwright
    // rejects even force-clicks with "outside of the viewport" — see
    // the same pattern in `TabObject.clickTab` (base-page.ts).
    const btn = this.tabButton();
    try {
      await btn.click({ timeout: 5_000 });
    } catch {
      try {
        await btn.click({ force: true, timeout: 5_000 });
      } catch {
        await btn.dispatchEvent("click");
      }
    }
  }

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !style?.includes("none");
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

  /**
   * The footer's "to" counter, read from its own element. The footer is
   * `<span>Rows</span><input/><span>to</span><div>END</div><span>of</span>
   * <div>COUNT</div>` (`isonim_event_log_view.nim`), whose `textContent` has
   * no whitespace between the words and the numbers ("Rowsto14of80"), so a
   * regex over the text cannot find them.
   */
  async toRow(): Promise<number> {
    const text =
      (await this.rowsInfoContainer()
        .locator(".data-tables-footer-end-row")
        .first()
        .textContent()) ?? "";
    return parseInt(text.trim(), 10) || 0;
  }

  /** The footer's total ("of") counter. See `toRow`. */
  async ofRows(): Promise<number> {
    const text =
      (await this.rowsInfoContainer()
        .locator(".data-tables-footer-rows-count")
        .first()
        .textContent()) ?? "";
    return parseInt(text.trim(), 10) || 0;
  }

  private eventElementRoots(): Locator {
    return this.root.locator(".eventLog-dense-table tbody tr");
  }

  rowByEventKind(kind: string): Locator {
    return this.root
      .locator(`.eventLog-dense-table tbody tr[data-event-kind="${kind}"]`)
      .first();
  }

  rowByGeneration(sourceGeneration: number): Locator {
    return this.root
      .locator(
        `.eventLog-dense-table tbody tr[data-source-generation="${sourceGeneration}"]`,
      )
      .first();
  }

  rowByKindAndGeneration(kind: string, sourceGeneration: number): Locator {
    return this.root
      .locator(
        `.eventLog-dense-table tbody tr[data-event-kind="${kind}"][data-source-generation="${sourceGeneration}"]`,
      )
      .first();
  }

  rowByKindGenerationAndText(
    kind: string,
    sourceGeneration: number,
    text: string,
  ): Locator {
    return this.root
      .locator(
        `.eventLog-dense-table tbody tr[data-event-kind="${kind}"][data-source-generation="${sourceGeneration}"]`,
      )
      .filter({ hasText: text })
      .first();
  }

  async eventElements(forceReload = false): Promise<EventRow[]> {
    if (forceReload || this.events.length === 0) {
      const roots = await this.eventElementRoots().all();
      this.events = roots.map(
        (r) => new EventRow(r, EventElementType.EventLog),
      );
    }
    return this.events;
  }

  async rowCount(): Promise<number> {
    return this.eventElementRoots().count();
  }

  async rowByIndex(index: number, forceReload = false): Promise<EventRow> {
    debugLogger.log(
      `EventLogPane: locating row ${index} (forceReload=${forceReload})`,
    );

    let found: EventRow | null = null;
    await retry(
      async () => {
        const rows = await this.eventElements(true);
        for (const row of rows) {
          if ((await row.index()) === index) {
            found = row;
            return true;
          }
        }
        debugLogger.log(
          `EventLogPane: row ${index} not found among ${rows.length} rows; retrying`,
        );
        return false;
      },
      { maxAttempts: 20, delayMs: 300 },
    );

    if (!found) {
      throw new Error(
        `Event log row with index ${index} was not found after retries.`,
      );
    }
    debugLogger.log(`EventLogPane: found row ${index}`);
    return found;
  }

  private filterButton(): Locator {
    return this.root.getByText("Filter", { exact: true }).first();
  }

  private dropdownRoot(): Locator {
    return this.page.locator("#dropdown-container-id");
  }

  async activateTraceEventsFilter(): Promise<void> {
    await this.filterButton().click();
    const traceButton = this.dropdownRoot().getByText("Trace events", {
      exact: true,
    });
    await traceButton.waitFor({ state: "visible" });
    await traceButton.click();
    await this.page.keyboard.press("Escape");
    await this.page.waitForTimeout(POST_FILTER_DELAY_MS);
  }

  async activateRecordedEventsFilter(): Promise<void> {
    await this.filterButton().click();
    const recordedButton = this.dropdownRoot().getByText("Recorded events", {
      exact: true,
    });
    await recordedButton.waitFor({ state: "visible" });
    await recordedButton.click();
    await this.page.keyboard.press("Escape");
    await this.page.waitForTimeout(POST_FILTER_DELAY_MS);
  }
}
