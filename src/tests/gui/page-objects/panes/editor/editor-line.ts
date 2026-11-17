import { glyphMarksOn } from "../../../lib/glyph-column";
import type { Locator, Page } from "@playwright/test";
import type { EditorPane } from "./editor-pane";
import { FlowValue } from "./flow-value";
import { ContextMenu } from "../../components/context-menu";

/**
 * Represents a single rendered line inside an editor pane.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/EditorLine.cs
 */
export class EditorLine {
  readonly parentPane: EditorPane;
  readonly root: Locator;
  readonly lineNumber: number;

  constructor(parentPane: EditorPane, root: Locator, lineNumber: number) {
    this.parentPane = parentPane;
    this.root = root;
    this.lineNumber = lineNumber;
  }

  private ensureValidLineNumber(): void {
    if (this.lineNumber <= 0) {
      throw new Error("This editor line does not expose a valid line number.");
    }
  }

  gutterElement(): Locator {
    this.ensureValidLineNumber();
    return this.parentPane.gutterElement(this.lineNumber);
  }

  gutterLineNumberElement(): Locator {
    return this.gutterElement().locator(".gutter-line");
  }

  gutterHighlightMarker(): Locator {
    return this.gutterElement().locator(".gutter-highlight-active");
  }

  flowLoopValueElements(): Locator {
    return this.root.locator(".flow-loop-value");
  }

  flowParallelValueElements(): Locator {
    return this.root.locator(".flow-parallel-value");
  }

  flowLoopValueNameElements(): Locator {
    return this.root.locator(".flow-loop-value-name");
  }

  flowParallelValueNameElements(): Locator {
    return this.root.locator(".flow-parallel-value-name");
  }

  flowLoopTextarea(): Locator {
    return this.root.locator(".flow-loop-textarea");
  }

  flowMultilineValueBoxes(): Locator {
    return this.root.locator(".flow-multiline-value-box");
  }

  flowMultilineValuePointers(): Locator {
    return this.root.locator(".flow-multiline-value-pointer");
  }

  async flowValues(): Promise<FlowValue[]> {
    const selector =
      ".flow-parallel-value-box, .flow-inline-value-box, .flow-multiline-value-box";
    const locators = await this.root.locator(selector).all();
    const menu = new ContextMenu(this.parentPane.root.page()!);
    return locators.map((l) => new FlowValue(l, menu));
  }

  /** The glyph column's mark on this line (Editor-Pane.md MC.5). */
  private async glyphMarks(): Promise<string[]> {
    return glyphMarksOn(this.parentPane.root.page()!, this.lineNumber);
  }

  async hasBreakpoint(): Promise<boolean> {
    return (await this.glyphMarks()).some((m) => m.includes("breakpoint"));
  }

  async hasTracepoint(): Promise<boolean> {
    return (await this.glyphMarks()).some((m) => m.includes("tracepoint"));
  }

  async isTracepointDisabled(): Promise<boolean> {
    if (!(await this.hasTracepoint())) {
      return false;
    }
    return false;
  }

  async hasErrorIcon(): Promise<boolean> {
    return false;
  }

  async lineText(): Promise<string> {
    const text = await this.root.innerText();
    return text.replace(/\u00A0/g, " ");
  }

  async flowParallelValues(): Promise<string[]> {
    const values: string[] = [];
    const locators = await this.flowParallelValueElements().all();
    for (const locator of locators) {
      const text = await locator.textContent();
      if (text && text.trim().length > 0) {
        values.push(text.trim());
      }
    }
    return values;
  }
}
