import type { Locator, Page } from "@playwright/test";
import type { EditorPane } from "./editor-pane";
import { TraceLogRow } from "./trace-log-row";
import { ContextMenu } from "../../components/context-menu";

const SCROLL_TIMEOUT_MS = 3_000;
const VIEW_LINES_TIMEOUT_MS = 3_000;
const POST_SCROLL_DELAY_MS = 300;
const POST_CLICK_DELAY_MS = 150;
const POST_SELECT_ALL_DELAY_MS = 50;
const POST_TOGGLE_DELAY_MS = 400;
const TYPE_DELAY_MS = 30;

/**
 * Represents the trace log panel associated with a specific editor line.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/TraceLogPanel.cs
 */
export class TraceLogPanel {
  readonly parentPane: EditorPane;
  readonly lineNumber: number;

  constructor(parentPane: EditorPane, lineNumber: number) {
    this.parentPane = parentPane;
    this.lineNumber = lineNumber;
  }

  private get page(): Page {
    return this.parentPane.page;
  }

  get root(): Locator {
    return this.parentPane.root.locator(
      `xpath=//*[@id='edit-trace-${this.parentPane.idNumber}-${this.lineNumber}']/ancestor::*[@class='trace']`,
    );
  }

  monacoViewLines(): Locator {
    return this.root.locator(".monaco-editor .view-lines").first();
  }

  editTextBox(): Locator {
    return this.root.locator("textarea.inputarea, textarea.ime-text-area").first();
  }

  /**
   * Types text into the trace expression editor.
   * Tries Monaco API first, falls back to keyboard input.
   */
  async typeExpression(expression: string): Promise<void> {
    try {
      await this.root.scrollIntoViewIfNeeded({ timeout: SCROLL_TIMEOUT_MS });
      await sleep(POST_SCROLL_DELAY_MS);
    } catch {
      await sleep(POST_SCROLL_DELAY_MS);
    }

    const editId = `edit-trace-${this.parentPane.idNumber}-${this.lineNumber}`;

    // Try Monaco API first
    const setViaApi = await this.page.evaluate(
      ({ editId: eid, expression: expr }) => {
        const editDiv = document.getElementById(eid);
        if (!editDiv) return false;

        // Via global monaco API
        const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        const monacoEditors = w.monaco?.editor?.getEditors?.() || [];
        for (const editor of monacoEditors) {
          const domNode = editor.getDomNode();
          if (domNode && editDiv.contains(domNode)) {
            editor.setValue(expr);
            return true;
          }
        }

        // Via Monaco container's editor property
        const monacoContainer = editDiv.querySelector(".monaco-editor") as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        if (monacoContainer?._editorInstance) {
          monacoContainer._editorInstance.setValue(expr);
          return true;
        }

        return false;
      },
      { editId, expression },
    );

    if (setViaApi) {
      return;
    }

    // Keyboard fallback
    const viewLines = this.monacoViewLines();
    try {
      await viewLines.waitFor({ state: "visible", timeout: VIEW_LINES_TIMEOUT_MS });
      await viewLines.click();
    } catch {
      await viewLines.click({ force: true });
    }
    await sleep(POST_CLICK_DELAY_MS);

    await this.page.keyboard.press("Control+a");
    await sleep(POST_SELECT_ALL_DELAY_MS);
    await this.page.keyboard.press("Delete");
    await sleep(POST_SELECT_ALL_DELAY_MS);

    await this.page.keyboard.type(expression, { delay: TYPE_DELAY_MS });
  }

  /**
   * Rows rendered in the trace log panel.
   */
  async traceRows(): Promise<TraceLogRow[]> {
    let locators = await this.root.locator(".chart-table .trace-table tbody tr").all();
    if (locators.length === 0) {
      locators = await this.root.locator(".trace-view tbody tr").all();
    }
    const menu = new ContextMenu(this.page);
    return locators.map((l) => new TraceLogRow(l, menu));
  }

  hamburgerMenu(): Locator {
    return this.root.locator(".hamburger-dropdown");
  }

  dropdownList(): Locator {
    return this.root.locator(".dropdown-list");
  }

  toggleButton(): Locator {
    return this.root.locator(".trace-disable");
  }

  /**
   * Opens the hamburger menu and clicks the Disable/Enable toggle button.
   * Uses JavaScript to avoid race conditions with blur handlers.
   */
  async clickToggleButton(): Promise<void> {
    const editTraceId = `edit-trace-${this.parentPane.idNumber}-${this.lineNumber}`;

    await this.page.evaluate((eid: string) => {
      const editTrace = document.getElementById(eid);
      if (!editTrace) return;

      const trace = editTrace.closest(".trace");
      if (!trace) return;

      const hamburger = trace.querySelector(".hamburger-dropdown") as HTMLElement | null;
      if (hamburger) {
        hamburger.click();
        setTimeout(() => {
          const toggleBtn = trace.querySelector(".trace-disable") as HTMLElement | null;
          if (toggleBtn) {
            toggleBtn.click();
          }
        }, 150);
      }
    }, editTraceId);

    await sleep(POST_TOGGLE_DELAY_MS);
  }

  disabledOverlay(): Locator {
    return this.root.locator(".trace-disabled-overlay");
  }

  runButton(): Locator {
    return this.root.locator(".trace-run-button-svg").nth(0);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
