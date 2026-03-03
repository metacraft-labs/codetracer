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

  gutterTraceIcon(): Locator {
    return this.gutterElement().locator(".gutter-trace");
  }

  gutterDisabledTraceIcon(): Locator {
    return this.gutterElement().locator(".gutter-disabled-trace");
  }

  gutterBreakpointEnabledIcon(): Locator {
    return this.gutterElement().locator(".gutter-breakpoint-enabled");
  }

  gutterBreakpointDisabledIcon(): Locator {
    return this.gutterElement().locator(".gutter-breakpoint-disabled");
  }

  gutterBreakpointErrorIcon(): Locator {
    return this.gutterElement().locator(".gutter-breakpoint-error");
  }

  gutterNoBreakpointPlaceholder(): Locator {
    return this.gutterElement().locator(".gutter-no-breakpoint");
  }

  gutterNoTracePlaceholder(): Locator {
    return this.gutterElement().locator(".gutter-no-trace");
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
      ".flow-parallel-value-box, .flow-inline-value-box, .flow-loop-value-box, .flow-multiline-value-box";
    const locators = await this.root.locator(selector).all();
    const menu = new ContextMenu(this.parentPane.root.page()!);
    return locators.map((l) => new FlowValue(l, menu));
  }

  async hasBreakpoint(): Promise<boolean> {
    const locator = this.gutterElement().locator(
      ".gutter-breakpoint-enabled, .gutter-breakpoint-disabled, .gutter-breakpoint-error",
    );
    return (await locator.count()) > 0;
  }

  async hasTracepoint(): Promise<boolean> {
    const locator = this.gutterElement().locator(".gutter-trace, .gutter-disabled-trace");
    return (await locator.count()) > 0;
  }

  async isTracepointDisabled(): Promise<boolean> {
    if (!(await this.hasTracepoint())) {
      return false;
    }
    return (await this.gutterDisabledTraceIcon().count()) > 0;
  }

  async hasErrorIcon(): Promise<boolean> {
    return (await this.gutterBreakpointErrorIcon().count()) > 0;
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
