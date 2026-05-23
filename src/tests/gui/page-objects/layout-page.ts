import type { Locator, Page } from "@playwright/test";
import { BasePage } from "./base-page";
import { EditorPane } from "./panes/editor/editor-pane";
import { EventLogPane } from "./panes/event-log/event-log-pane";
import { CallTracePane } from "./panes/call-trace/call-trace-pane";
import { ScratchpadPane } from "./panes/scratchpad/scratchpad-pane";
import { FilesystemPane } from "./panes/filesystem/filesystem-pane";
import { TerminalOutputPane } from "./panes/terminal/terminal-output-pane";
import { TimelinePane } from "./panes/timeline/timeline-pane";
import { VariableStatePane } from "./panes/variable-state/variable-state-pane";
import { retry } from "../lib/retry-helpers";
import { debugLogger } from "../lib/debug-logger";
import {
  LIMIT_COMPONENTS_LOADED_MS,
  LIMIT_TRACE_LOADED_MS,
  timedVoid,
} from "../lib/performance-limits";

const EVENT_LOG_LOADING_RETRY_ATTEMPTS = 60;

// The editor component only appears after the backend sends `ct/complete-move`
// (backend startup -> DAP handshake -> run-to-entry), which can take >10s.
// Other components load from GoldenLayout immediately and use the default 10 attempts.
const EDITOR_COMPONENT_RETRY_ATTEMPTS = 60;

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
  private timelineTabsCache: TimelinePane[] = [];
  private callTraceTabsCache: CallTracePane[] = [];

  // ---------------------------------------------------------------------------
  // Component wait methods
  // ---------------------------------------------------------------------------

  private async waitForComponent(
    componentName: string,
    selector: string,
    retryOpts?: { maxAttempts?: number; delayMs?: number },
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
      }, retryOpts);
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

  /**
   * Wait until the call-trace store has actually populated lines.
   *
   * `waitForCallTraceLoaded()` only verifies that the GoldenLayout
   * `calltraceComponent` div has mounted; it does NOT wait for the
   * backend `ct/load-calltrace-section` round-trip to complete and
   * the `.calltrace-call-line` elements to render inside it.
   *
   * Tests that interact with the call-trace pane (clickTab → expand
   * → activate sequences) need this stronger signal: clicking a tab
   * before the lines exist races against the GoldenLayout reflow
   * and intermittently throws "Element is outside of the viewport"
   * under sweep load — see the noir-space-ship suite-level flake
   * (TODO 5.2(h)).
   *
   * This method polls until at least one `.calltrace-call-line`
   * exists inside any `calltraceComponent` div, or the retry budget
   * is exhausted (60 attempts × 1s = 60s).
   */
  async waitForCallTraceReady(): Promise<void> {
    const lines = this.page.locator(
      "div[id^='calltraceComponent'] .calltrace-lines .calltrace-call-line",
    );
    try {
      await retry(
        async () => (await lines.count()) > 0,
        { maxAttempts: 60, delayMs: 1000 },
      );
      debugLogger.log("LayoutPage: call-trace data ready (lines present).");
    } catch (ex) {
      const lineCount = await lines.count();
      throw new Error(
        `Call-trace data did not populate; final .calltrace-call-line count=${lineCount}.`,
        { cause: ex instanceof Error ? ex : undefined },
      );
    }
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
    await this.waitForComponent("editor", "div[id^='editorComponent']", {
      maxAttempts: EDITOR_COMPONENT_RETRY_ATTEMPTS,
    });
  }

  async waitForScratchpadLoaded(): Promise<void> {
    await this.waitForComponent("scratchpad", "div[id^='scratchpadComponent']");
  }

  async waitForTerminalLoaded(): Promise<void> {
    await this.waitForComponent("terminal", "div[id^='terminalComponent']");
  }

  async waitForTimelineLoaded(): Promise<void> {
    await this.waitForComponent("timeline", "div[id^='timelineComponent']");
  }

  /**
   * Waits for the trace to be fully loaded by checking the document title.
   */
  async waitForTraceLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for trace to be loaded (checking document title)");
    await timedVoid("trace loaded", LIMIT_TRACE_LOADED_MS, async () => {
      await retry(async () => {
        const title = await this.page.title();
        const isLoaded = title.toLowerCase().includes("trace");
        if (!isLoaded) {
          debugLogger.log(`LayoutPage: trace not yet loaded (title='${title}')`);
        }
        return isLoaded;
      });
    });
    debugLogger.log("LayoutPage: trace loaded confirmed via title");
  }

  async waitForAllComponentsLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for all components");
    await timedVoid("all components loaded", LIMIT_COMPONENTS_LOADED_MS, async () => {
      await Promise.all([
        this.waitForFilesystemLoaded(),
        this.waitForStateLoaded(),
        this.waitForCallTraceLoaded(),
        this.waitForEventLogLoaded(),
        this.waitForEditorLoaded(),
        this.waitForTerminalLoaded(),
        this.waitForScratchpadLoaded(),
      ]);
    });
  }

  /**
   * Waits for base components excluding the editor (which loads dynamically
   * after backend sends CtCompleteMove).
   */
  async waitForBaseComponentsLoaded(): Promise<void> {
    debugLogger.log("LayoutPage: waiting for base components (excluding editor)");
    await timedVoid("base components loaded", LIMIT_COMPONENTS_LOADED_MS, async () => {
      await Promise.all([
        this.waitForFilesystemLoaded(),
        this.waitForStateLoaded(),
        this.waitForCallTraceLoaded(),
        this.waitForEventLogLoaded(),
        this.waitForTerminalLoaded(),
        this.waitForScratchpadLoaded(),
      ]);
    });
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
  debugControlsRoot(): Locator {
    return this.page
      .locator("#isonim-debug-controls .isonim-debug-controls, .isonim-debug-controls")
      .first();
  }
  toolbarModeText(): Locator {
    return this.page.locator("#debug-toolbar-mode, .debug-toolbar-mode").first();
  }
  recordingHeadIndicator(): Locator {
    return this.page
      .locator("#recording-head-indicator, .recording-head-indicator")
      .first();
  }
  jumpToLiveButton(): Locator {
    return this.page.locator("#jump-to-live-debug, .jump-to-live").first();
  }
  async sessionModeAttr(): Promise<string | null> {
    return this.debugControlsRoot().getAttribute("data-session-mode");
  }
  async recordingHeadAttr(): Promise<string | null> {
    return this.debugControlsRoot().getAttribute("data-recording-head");
  }

  /**
   * Click a debug-toolbar button (next, continue, step-in/out, run-to-entry,
   * or any reverse variant) with a layered fallback for click-interception
   * issues.
   *
   * Under Xvfb the GoldenLayout strip overlap can leave a `jstree-icon` or
   * an absolutely-positioned filesystem-pane element on top of the
   * debug-toolbar buttons; Playwright then refuses the click with
   * "<i class=jstree-themeicon> from <#root-container> subtree intercepts
   * pointer events". The same three-step fallback that
   * `CallTracePane.clickTab` uses works here:
   *
   *   1. Plain `.click()` first — fastest path; succeeds in headed runs
   *      and on display configurations where the strip does not overlap.
   *   2. `.click({ force: true })` — bypasses actionability checks but
   *      Playwright still rejects when the element reports outside the
   *      viewport on Xvfb.
   *   3. `dispatchEvent('click')` — bypasses Playwright's pointer-event
   *      simulation entirely. The debug buttons attach plain `click`
   *      listeners (in `debug_controls.nim` / `event_jumper.nim`), so a
   *      synthesized click event still triggers the corresponding
   *      command without needing a real OS-level pointer event.
   *
   * The `name` argument is used purely for debug logging so failures in
   * the chain can be attributed to the right button.
   */
  async clickDebugButton(button: Locator, name: string): Promise<void> {
    try {
      await button.click({ timeout: 5_000 });
      return;
    } catch (ex) {
      debugLogger.log(
        `LayoutPage.clickDebugButton('${name}'): plain click failed (${(ex as Error).message ?? ex}); falling through to dispatchEvent`,
      );
    }
    // When the plain click is intercepted by an overlapping `lm_header`
    // (GoldenLayout tab strip) or jstree icon, `force:true` does NOT
    // redirect the click to the underlying button — it only bypasses
    // Playwright's actionability checks. The real OS mouse event still
    // lands on whatever is on top, so the button's `click` listener
    // never fires (the symptom that hid TODO 5.2(i): wasm `next` clicks
    // succeeded silently but the IsoNim handler was never invoked).
    //
    // `dispatchEvent('click')` synthesizes a click event directly on
    // the resolved element, bypassing the OS pointer layer entirely.
    // The IsoNim toolbar attaches plain `click` listeners via
    // `addEventListener`, so a synthesized event triggers the handler
    // reliably regardless of viewport / overlay state.
    await button.dispatchEvent("click");
  }

  async clickRunToEntryButton(): Promise<void> {
    await this.clickDebugButton(this.runToEntryButton(), "run-to-entry-debug");
  }
  async clickContinueButton(): Promise<void> {
    await this.clickDebugButton(this.continueButton(), "continue-debug");
  }
  async clickReverseContinueButton(): Promise<void> {
    await this.clickDebugButton(
      this.reverseContinueButton(),
      "reverse-continue-debug",
    );
  }
  async clickStepOutButton(): Promise<void> {
    await this.clickDebugButton(this.stepOutButton(), "step-out-debug");
  }
  async clickReverseStepOutButton(): Promise<void> {
    await this.clickDebugButton(
      this.reverseStepOutButton(),
      "reverse-step-out-debug",
    );
  }
  async clickStepInButton(): Promise<void> {
    await this.clickDebugButton(this.stepInButton(), "step-in-debug");
  }
  async clickReverseStepInButton(): Promise<void> {
    await this.clickDebugButton(
      this.reverseStepInButton(),
      "reverse-step-in-debug",
    );
  }
  async clickNextButton(): Promise<void> {
    await this.clickDebugButton(this.nextButton(), "next-debug");
  }
  async clickReverseNextButton(): Promise<void> {
    await this.clickDebugButton(this.reverseNextButton(), "reverse-next-debug");
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
        // Split on both POSIX and Windows path separators: editor tab
        // labels carry native absolute paths, so a `/`-only split would
        // treat a whole `D:\repo\src\main.nr` path as a single segment
        // and report the full path as the file name.
        const segments = filePath.split(/[/\\]/).filter(Boolean);
        const fileName = segments[segments.length - 1] ?? "";
        const tabButtonText =
          segments.length >= 2
            ? segments.slice(-2).join("/")
            : fileName;
        const idMatch = idAttr.match(/(\d+)/);
        const idNumber = idMatch ? parseInt(idMatch[1], 10) : -1;
        tabs.push(
          new EditorPane(
            this.page,
            r,
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

  async timelineTabs(forceReload = false): Promise<TimelinePane[]> {
    if (forceReload || this.timelineTabsCache.length === 0) {
      const roots = await this.page
        .locator("div[id^='timelineComponent']")
        .all();
      this.timelineTabsCache = roots.map(
        (r) => new TimelinePane(this.page, r, "TIMELINE"),
      );
    }
    return this.timelineTabsCache;
  }
}
