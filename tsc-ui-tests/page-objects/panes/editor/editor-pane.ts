import type { Locator, Page } from "@playwright/test";
import { EditorLine } from "./editor-line";
import { FlowValue } from "./flow-value";
import { OmniscientLoopControls } from "./omniscient-loop-controls";
import { TraceLogPanel } from "./trace-log-panel";
import { ContextMenu } from "../../components/context-menu";

const FLOW_VALUE_SELECTOR =
  ".flow-parallel-value-box, .flow-inline-value-box, .flow-loop-value-box, .flow-multiline-value-box";

/**
 * Page object representing a Monaco editor pane within the layout view.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/EditorPane.cs
 */
export class EditorPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  readonly idNumber: number;
  readonly filePath: string;
  readonly fileName: string;

  constructor(
    page: Page,
    root: Locator,
    tabButtonText: string,
    idNumber: number,
    filePath: string,
    fileName: string,
  ) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
    this.idNumber = idNumber;
    this.filePath = filePath;
    this.fileName = fileName;
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  // ---- Locators ----

  lineElements(): Locator {
    return this.root.locator(".monaco-editor .view-lines > .view-line");
  }

  lineElement(lineNumber: number): Locator {
    return this.root.locator(
      `.monaco-editor .view-lines > .view-line[data-line-number='${lineNumber}']`,
    );
  }

  gutterElement(lineNumber: number): Locator {
    return this.root.locator(
      `.monaco-editor .margin-view-overlays > .gutter[data-line='${lineNumber}']`,
    );
  }

  currentLineOverlay(): Locator {
    return this.root.locator(".monaco-editor .view-overlays .current-line");
  }

  activeLineNumberLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .margin .line-numbers.active-line-number",
    );
  }

  highlightedLineElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .view-lines > .view-line.line-flow-hit, " +
        ".monaco-editor .view-lines > .view-line.highlight",
    );
  }

  grayedOutLineElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .view-lines > .view-line.line-flow-skip, " +
        ".monaco-editor .view-lines > .view-line.line-flow-unknown",
    );
  }

  gutterHighlightElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .margin-view-overlays > .gutter.gutter-highlight-active",
    );
  }

  omniscientLoopContainersLocator(): Locator {
    return this.root.locator(".flow-loop-step-container");
  }

  flowValueElementById(valueBoxId: string): Locator {
    return this.root.locator(`#${valueBoxId}`);
  }

  flowValueElementByName(valueName: string): Locator {
    const nameLocator = this.root
      .locator(".flow-parallel-value-name, .flow-loop-value-name")
      .filter({ hasText: valueName });

    return nameLocator
      .locator(
        "xpath=following-sibling::*[contains(@class,'flow-parallel-value-box') or contains(@class,'flow-loop-value-box')]",
      )
      .first();
  }

  // ---- Methods ----

  async lines(): Promise<EditorLine[]> {
    const locators = await this.lineElements().all();
    const lines: EditorLine[] = [];
    for (const locator of locators) {
      const attr = await locator.getAttribute("data-line-number");
      const lineNumber = attr ? parseInt(attr, 10) : -1;
      lines.push(new EditorLine(this, locator, isNaN(lineNumber) ? -1 : lineNumber));
    }
    return lines;
  }

  lineByNumber(lineNumber: number): EditorLine {
    return new EditorLine(this, this.lineElement(lineNumber), lineNumber);
  }

  async hasActiveLine(): Promise<boolean> {
    if ((await this.activeLineNumberLocator().count()) > 0) {
      return true;
    }
    return (await this.currentLineOverlay().count()) > 0;
  }

  private async tryReadViewLineFromState(): Promise<number | null> {
    if (!this.filePath) {
      return null;
    }

    try {
      return await this.page.evaluate(({ path }) => {
        const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        const data = w?.data;
        if (!data?.services?.editor) return null;

        const editorService = data.services.editor;
        const openTabs = editorService.open;
        if (!openTabs || !Object.prototype.hasOwnProperty.call(openTabs, path)) {
          return null;
        }

        const tab = openTabs[path];
        if (!tab) return null;

        const viewLine = tab.viewLine;
        if (typeof viewLine === "number" && Number.isFinite(viewLine) && viewLine > 0) {
          return viewLine;
        }

        const monacoEditor = tab.monacoEditor;
        if (monacoEditor && typeof monacoEditor.getPosition === "function") {
          const position = monacoEditor.getPosition();
          if (
            position &&
            typeof position.lineNumber === "number" &&
            Number.isFinite(position.lineNumber) &&
            position.lineNumber > 0
          ) {
            return position.lineNumber;
          }
        }

        if (editorService.active === path && typeof editorService.activeTabInfo === "function") {
          const activeTab = editorService.activeTabInfo();
          if (
            activeTab &&
            typeof activeTab.viewLine === "number" &&
            Number.isFinite(activeTab.viewLine) &&
            activeTab.viewLine > 0
          ) {
            return activeTab.viewLine;
          }
        }

        return null;
      }, { path: this.filePath });
    } catch {
      return null;
    }
  }

  async activeLineNumber(): Promise<number | null> {
    const viewLine = await this.tryReadViewLineFromState();
    if (viewLine !== null && viewLine > 0) {
      return viewLine;
    }

    if ((await this.activeLineNumberLocator().count()) === 0) {
      return null;
    }

    const text = await this.activeLineNumberLocator().first().textContent();
    return text ? parseInt(text, 10) || null : null;
  }

  async highlightedLines(): Promise<EditorLine[]> {
    const lineNumbers = new Set<number>();

    const lineLocators = await this.highlightedLineElementsLocator().all();
    for (const locator of lineLocators) {
      const attr = await locator.getAttribute("data-line-number");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    const gutterLocators = await this.gutterHighlightElementsLocator().all();
    for (const gutter of gutterLocators) {
      const attr = await gutter.getAttribute("data-line");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    return [...lineNumbers].map((n) => this.lineByNumber(n));
  }

  async grayedOutLines(): Promise<EditorLine[]> {
    const lineNumbers = new Set<number>();

    const lineLocators = await this.grayedOutLineElementsLocator().all();
    for (const locator of lineLocators) {
      const attr = await locator.getAttribute("data-line-number");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    return [...lineNumbers].map((n) => this.lineByNumber(n));
  }

  /**
   * Toggles a tracepoint at the requested line through the frontend API.
   */
  async openTrace(lineNumber: number): Promise<void> {
    if (lineNumber <= 0) {
      throw new Error("Line number must be positive.");
    }
    if (!this.filePath) {
      throw new Error("Editor pane does not expose a valid file path.");
    }

    const editorLine = this.lineByNumber(lineNumber);
    if (await editorLine.hasTracepoint()) {
      return;
    }

    await this.page.evaluate(
      ({ path, line }) => {
        const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        if (typeof w.toggleTracepoint !== "function") {
          throw new Error("toggleTracepoint is not available.");
        }
        w.toggleTracepoint(path, line);
      },
      { path: this.filePath, line: lineNumber },
    );
  }

  /**
   * Runs all configured tracepoints via the exposed frontend helper.
   */
  async runTracepointsJs(): Promise<void> {
    await this.page.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      if (typeof w.runTracepoints !== "function") {
        throw new Error("runTracepoints is not available.");
      }

      const globalData = w.data;
      if (!globalData) {
        throw new Error("Global data object is not available.");
      }

      w.runTracepoints(globalData);
    });
  }

  /**
   * Returns currently active omniscient loop control groups.
   */
  async activeLoopControls(): Promise<OmniscientLoopControls[]> {
    const containers = await this.omniscientLoopContainersLocator().all();
    return containers.map((l) => new OmniscientLoopControls(l));
  }

  /**
   * Gathers all flow values currently rendered in the editor.
   */
  async flowValues(): Promise<FlowValue[]> {
    const locators = await this.root.locator(FLOW_VALUE_SELECTOR).all();
    const menu = new ContextMenu(this.page);
    return locators.map((l) => new FlowValue(l, menu));
  }

  /**
   * Opens the trace log panel for the provided line.
   */
  async openTracePoint(lineNumber: number): Promise<TraceLogPanel> {
    const line = this.lineByNumber(lineNumber);
    await line.gutterElement().click();
    const panel = new TraceLogPanel(this, lineNumber);
    await panel.root.waitFor({ state: "visible" });
    return panel;
  }

  async highlightedLineNumber(): Promise<number> {
    return (await this.activeLineNumber()) ?? -1;
  }
}
