import type { Locator, Page } from "@playwright/test";
import { BasePage } from "./base-page";
import { EditorPane } from "./panes/editor/editor-pane";
import { EventLogPane } from "./panes/event-log/event-log-pane";
import { CallTracePane } from "./panes/call-trace/call-trace-pane";
import { ScratchpadPane } from "./panes/scratchpad/scratchpad-pane";
import { FilesystemPane } from "./panes/filesystem/filesystem-pane";
import { TerminalOutputPane } from "./panes/terminal/terminal-output-pane";
import { VariableStatePane } from "./panes/variable-state/variable-state-pane";
import { retry } from "../lib/retry-helpers";
import { debugLogger } from "../lib/debug-logger";

const EVENT_LOG_LOADING_RETRY_ATTEMPTS = 30;

/**
 * Main layout page that contains all pane tabs, debug buttons, and menu elements.
 *
 * Port of ui-tests/PageObjects/LayoutPage.cs with all enhanced pane accessors.
 */
export class LayoutPage extends BasePage {
  private eventLogTabsCache: EventLogPane[] = [];
  private programStateTabsCache: VariableStatePane[] = [];
  private editorTabsCache: EditorPane[] = [];
  private scratchpadTabsCache: ScratchpadPane[] = [];
  private filesystemTabsCache: FilesystemPane[] = [];
  private terminalTabsCache: TerminalOutputPane[] = [];
  private callTraceTabsCache: CallTracePane[] = [];

  // ---------------------------------------------------------------------------
  // Component wait methods
  // ---------------------------------------------------------------------------

  private async waitForComponent(
    componentName: string,
    selector: string,
  ): Promise<void> {
    const locator = this.page.locator(selector);
    try {
      await retry(async () => {
        const count = await locator.count();
        if (count === 0) {
          debugLogger.log(
            `LayoutPage: component '${componentName}' pending (selector='${selector}', count=0)`,
          );
          return false;
        }
        const visible = await locator.first().isVisible();
        debugLogger.log(
          `LayoutPage: component '${componentName}' ready (count=${count}, firstVisible=${visible})`,
        );
        return true;
      });
    } catch (ex) {
      const count = await locator.count();
      const candidateIds: string[] = await this.page.evaluate(() =>
        Array.from(document.querySelectorAll("div[id]"))
          .map((el) => el.id)
          .filter((id) => id.toLowerCase().includes("component"))
          .slice(0, 25),
      );
      const bodySummary: string = await this.page.evaluate(
        () => (document.body?.innerText ?? "").slice(0, 600),
      );
      const knownComponents =
        candidateIds.length === 0 ? "none" : candidateIds.join(", ");
      debugLogger.log(
        `LayoutPage: component '${componentName}' FAILED to load (selector='${selector}', final count=${count}, known=${knownComponents}, body='${bodySummary}')`,
      );
      throw new Error(
        `Component '${componentName}' (selector '${selector}') did not load; final count=${count}. ` +
          `Known component-like ids: ${knownComponents}. Body sample: ${bodySummary}`,
        { cause: ex instanceof Error ? ex : undefined },
      );
    }
  }

  async waitForFilesystemLoaded(): Promise<void> {
    await this.waitForComponent("filesystem", "div[id^='filesystemComponent']");
  }

  async waitForStateLoaded(): Promise<void> {
    await this.waitForComponent("state", "div[id^='stateComponent']");
  }

  async waitForCallTraceLoaded(): Promise<void> {
    await this.waitForComponent("calltrace", "div[id^='calltraceComponent']");
  }

  async waitForEventLogLoaded(): Promise<void> {
    await this.waitForComponent("event-log", "div[id^='eventLogComponent']");

    // Wait for "Loading..." placeholder cells to disappear
    const loadingCell = this.page
      .locator("div[id^='eventLogComponent'] td.dt-empty")
      .filter({ hasText: "Loading..." });

    try {
      await retry(
        async () => {
          const count = await loadingCell.count();
          if (count === 0) {
            debugLogger.log(
              "LayoutPage: event-log data loaded (no loading placeholders present).",
            );
            return true;
          }
          debugLogger.log(
            `LayoutPage: event-log still loading (placeholder count=${count}); waiting.`,
          );
          return false;
        },
        { maxAttempts: EVENT_LOG_LOADING_RETRY_ATTEMPTS },
      );
    } catch (ex) {
      const remaining = await loadingCell.count();
      throw new Error(
        `Event log did not finish loading; ${remaining} placeholder row(s) remained.`,
        { cause: ex instanceof Error ? ex : undefined },
      );
    }
  }

  async waitForEditorLoaded(): Promise<void> {
    await this.waitForComponent("editor", "div[id^='editorComponent']");
  }

  async waitForScratchpadLoaded(): Promise<void> {
    await this.waitForComponent("scratchpad", "div[id^='scratchpadComponent']");
  }

  async waitForTerminalLoaded(): Promise<void> {
    await this.waitForComponent("terminal", "div[id^='terminalComponent']");
  }

  /**
   * Waits for the trace to be fully loaded by checking the document title.
   */
  async waitForTraceLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for trace to be loaded (checking document title)");
    await retry(async () => {
      const title = await this.page.title();
      const isLoaded = title.toLowerCase().includes("trace");
      if (!isLoaded) {
        debugLogger.log(`LayoutPage: trace not yet loaded (title='${title}')`);
      }
      return isLoaded;
    });
    debugLogger.log("LayoutPage: trace loaded confirmed via title");
  }

  async waitForAllComponentsLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for all components");
    await Promise.all([
      this.waitForFilesystemLoaded(),
      this.waitForStateLoaded(),
      this.waitForCallTraceLoaded(),
      this.waitForEventLogLoaded(),
      this.waitForEditorLoaded(),
      this.waitForTerminalLoaded(),
      this.waitForScratchpadLoaded(),
    ]);
  }

  /**
   * Waits for base components excluding the editor (which loads dynamically
   * after backend sends CtCompleteMove).
   */
  async waitForBaseComponentsLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for base components (excluding editor)");
    await Promise.all([
      this.waitForFilesystemLoaded(),
      this.waitForStateLoaded(),
      this.waitForCallTraceLoaded(),
      this.waitForEventLogLoaded(),
      this.waitForTerminalLoaded(),
      this.waitForScratchpadLoaded(),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Debug buttons
  // ---------------------------------------------------------------------------

  runToEntryButton(): Locator {
    return this.page.locator("#run-to-entry-debug");
  }
  continueButton(): Locator {
    return this.page.locator("#continue-debug");
  }
  reverseContinueButton(): Locator {
    return this.page.locator("#reverse-continue-debug");
  }
  stepOutButton(): Locator {
    return this.page.locator("#step-out-debug");
  }
  reverseStepOutButton(): Locator {
    return this.page.locator("#reverse-step-out-debug");
  }
  stepInButton(): Locator {
    return this.page.locator("#step-in-debug");
  }
  reverseStepInButton(): Locator {
    return this.page.locator("#reverse-step-in-debug");
  }
  nextButton(): Locator {
    return this.page.locator("#next-debug");
  }
  reverseNextButton(): Locator {
    return this.page.locator("#reverse-next-debug");
  }

  // ---------------------------------------------------------------------------
  // Status indicators
  // ---------------------------------------------------------------------------

  operationStatus(): Locator {
    return this.page.locator("#operation-status");
  }

  statusBusyIndicator(): Locator {
    return this.page.locator(".status-notification.is-active");
  }

  // ---------------------------------------------------------------------------
  // Menu elements
  // ---------------------------------------------------------------------------

  menuRootButton(): Locator {
    return this.page.locator("#menu-root-name");
  }

  menuSearchTextBox(): Locator {
    return this.page.locator("#menu-search-text");
  }

  // ---------------------------------------------------------------------------
  // Pane tab accessors (cached with forceReload)
  // ---------------------------------------------------------------------------

  async eventLogTabs(forceReload = false): Promise<EventLogPane[]> {
    if (forceReload || this.eventLogTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='eventLogComponent-']")
        .all();
      this.eventLogTabsCache = roots.map(
        (r) => new EventLogPane(this.page, r, "EVENT LOG"),
      );
    }
    return this.eventLogTabsCache;
  }

  async programStateTabs(forceReload = false): Promise<VariableStatePane[]> {
    if (forceReload || this.programStateTabsCache.length === 0) {
      const roots = await this.page.locator("div[id^='stateComponent']").all();
      this.programStateTabsCache = roots.map(
        (r) => new VariableStatePane(this.page, r, "STATE"),
      );
    }
    return this.programStateTabsCache;
  }

  async editorTabs(forceReload = false): Promise<EditorPane[]> {
    if (forceReload || this.editorTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='editorComponent']")
        .all();
      const tabs: EditorPane[] = [];
      for (const r of roots) {
        const idAttr = (await r.getAttribute("id")) ?? "";
        const filePath = (await r.getAttribute("data-label")) ?? "";
        const segments = filePath.split("/").filter(Boolean);
        const fileName = segments[segments.length - 1] ?? "";
        const tabButtonText =
          segments.length >= 2
            ? segments.slice(-2).join("/")
            : fileName;
        const idMatch = idAttr.match(/(\d+)/);
        const idNumber = idMatch ? parseInt(idMatch[1], 10) : -1;
        const paneRoot = this.page.locator(`#${idAttr}`);
        tabs.push(
          new EditorPane(
            this.page,
            paneRoot,
            tabButtonText,
            idNumber,
            filePath,
            fileName,
          ),
        );
      }
      this.editorTabsCache = tabs;
    }
    return this.editorTabsCache;
  }

  async callTraceTabs(forceReload = false): Promise<CallTracePane[]> {
    if (forceReload || this.callTraceTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='calltraceComponent']")
        .all();
      this.callTraceTabsCache = roots.map(
        (r) => new CallTracePane(this.page, r, "CALLTRACE"),
      );
    }
    return this.callTraceTabsCache;
  }

  async scratchpadTabs(forceReload = false): Promise<ScratchpadPane[]> {
    if (forceReload || this.scratchpadTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='scratchpadComponent']")
        .all();
      this.scratchpadTabsCache = roots.map(
        (r) => new ScratchpadPane(this.page, r, "SCRATCHPAD"),
      );
    }
    return this.scratchpadTabsCache;
  }

  async filesystemTabs(forceReload = false): Promise<FilesystemPane[]> {
    if (forceReload || this.filesystemTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='filesystemComponent']")
        .all();
      this.filesystemTabsCache = roots.map(
        (r) => new FilesystemPane(this.page, r, "FILES"),
      );
    }
    return this.filesystemTabsCache;
  }

  async terminalTabs(forceReload = false): Promise<TerminalOutputPane[]> {
    if (forceReload || this.terminalTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='terminalComponent']")
        .all();
      this.terminalTabsCache = roots.map(
        (r) => new TerminalOutputPane(this.page, r, "TERMINAL"),
      );
    }
    return this.terminalTabsCache;
  }
}
