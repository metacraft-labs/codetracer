import type { Locator } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";
import { CallTraceArgument } from "./call-trace-argument";
import type { CallTracePane } from "./call-trace-pane";
import { retry } from "../../../lib/retry-helpers";
import { debugLogger } from "../../../lib/debug-logger";

const EXPAND_CHILDREN_OPTIONS = ["Expand Call Children", "Expand Full Callstack"];
const COLLAPSE_CHILDREN_OPTIONS = ["Collapse Call Children", "Expand Full Callstack"];

const ACTIVATE_RETRY_ATTEMPTS = 5;
const ACTIVATE_RETRY_DELAY_MS = 50;
const ACTIVATE_DOUBLE_CLICK_DELAY_MS = 50;

/**
 * Represents a single call entry rendered within the call trace pane.
 *
 * Port of ui-tests/PageObjects/Panes/CallTrace/CallTraceEntry.cs
 */
export class CallTraceEntry {
  private readonly pane: CallTracePane;
  readonly root: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(pane: CallTracePane, root: Locator, contextMenu: ContextMenu) {
    this.pane = pane;
    this.root = root;
    this.contextMenu = contextMenu;
  }

  private offsetLocator(): Locator {
    return this.root.locator("> span").first();
  }

  private childBoxLocator(): Locator {
    return this.root.locator(".call-child-box");
  }

  private callTextLocator(): Locator {
    return this.childBoxLocator().locator(".call-text");
  }

  private toggleLocator(): Locator {
    return this.childBoxLocator().locator(".toggle-call");
  }

  private returnLocator(): Locator {
    return this.childBoxLocator().locator(".return-text");
  }

  private argumentContainer(): Locator {
    return this.childBoxLocator().locator(".call-args");
  }

  async callText(): Promise<string> {
    return (await this.callTextLocator().innerText()).trim();
  }

  /**
   * Extracts the function name from the call text.
   * Handles Ruby-style "Class#method #N" by finding the last " #N" pattern.
   */
  async functionName(): Promise<string> {
    const callText = await this.callText();
    for (let i = callText.length - 1; i >= 2; i--) {
      if (
        callText[i - 1] === "#" &&
        callText[i - 2] === " " &&
        /\d/.test(callText[i])
      ) {
        return callText.substring(0, i - 2).trim();
      }
    }
    return callText;
  }

  async callIdentifier(): Promise<string> {
    const callText = await this.callText();
    for (let i = callText.length - 1; i >= 2; i--) {
      if (
        callText[i - 1] === "#" &&
        callText[i - 2] === " " &&
        /\d/.test(callText[i])
      ) {
        return callText.substring(i).trim();
      }
    }
    return "";
  }

  /**
   * Depth inferred from the leading spacer element's min-width CSS.
   */
  async depth(): Promise<number> {
    const style = (await this.offsetLocator().getAttribute("style")) ?? "";
    const match = style.match(/min-width:\s*([\d.]+)px/);
    if (!match) return 0;
    return Math.round(parseFloat(match[1]) / 8);
  }

  private async hasClass(className: string): Promise<boolean> {
    const classAttr = (await this.root.getAttribute("class")) ?? "";
    return classAttr.split(/\s+/).includes(className);
  }

  async isSelected(): Promise<boolean> {
    return this.hasClass("event-selected");
  }

  async hasToggle(): Promise<boolean> {
    return (
      (await this.toggleLocator()
        .locator(".collapse-call-img, .dot-call-img")
        .count()) > 0
    );
  }

  async hasExpandedChildren(): Promise<boolean> {
    return (await this.toggleLocator().locator(".collapse-call-img").count()) > 0;
  }

  async expectedContextMenu(): Promise<readonly string[]> {
    return (await this.hasExpandedChildren())
      ? COLLAPSE_CHILDREN_OPTIONS
      : EXPAND_CHILDREN_OPTIONS;
  }

  async contextMenuEntries(): Promise<string[]> {
    await this.callTextLocator().click({ button: "right" });
    await this.contextMenu.waitForVisible();
    const entries = await this.contextMenu.getEntries();
    await this.contextMenu.dismiss();
    return entries.map((e) => e.text);
  }

  async expandChildren(): Promise<void> {
    if (!(await this.hasToggle())) return;
    if (!(await this.hasExpandedChildren())) {
      await this.toggleLocator().click();
      await retry(() => this.hasExpandedChildren());
    }
  }

  async collapseChildren(): Promise<void> {
    if (!(await this.hasToggle())) return;
    if (await this.hasExpandedChildren()) {
      await this.toggleLocator().click();
      await retry(async () => !(await this.hasExpandedChildren()));
    }
  }

  /**
   * Clicks the call entry to trigger jump navigation.
   * Uses multiple strategies to work around viewport/rendering issues on Windows.
   */
  async activate(): Promise<void> {
    const functionName = await this.functionName();
    debugLogger.log(`CallTraceEntry[${functionName}]: Begin activate`);

    const callText = this.callTextLocator();

    // Strategy 1: Use page.evaluate to directly click the DOM element
    // This bypasses all Playwright viewport/actionability checks
    try {
      debugLogger.log(`CallTraceEntry[${functionName}]: evaluate click on call-text`);
      await callText.evaluate((el: HTMLElement) => el.click());
      await this.pane.page.waitForTimeout(500);
      if (await this.isSelected()) {
        debugLogger.log(`CallTraceEntry[${functionName}]: activated via evaluate click`);
        return;
      }
    } catch {
      debugLogger.log(`CallTraceEntry[${functionName}]: evaluate click failed`);
    }

    // Strategy 2: dispatchEvent("click")
    try {
      debugLogger.log(`CallTraceEntry[${functionName}]: dispatchEvent click`);
      await callText.dispatchEvent("click");
      await this.pane.page.waitForTimeout(500);
      if (await this.isSelected()) {
        debugLogger.log(`CallTraceEntry[${functionName}]: activated via dispatchEvent`);
        return;
      }
    } catch {
      debugLogger.log(`CallTraceEntry[${functionName}]: dispatchEvent click failed`);
    }

    // Strategy 3: scrollIntoView + force click with short timeout
    try {
      await callText.scrollIntoViewIfNeeded({ timeout: 2_000 });
    } catch {
      // ignore scroll failure
    }
    try {
      debugLogger.log(`CallTraceEntry[${functionName}]: force click`);
      await callText.click({ force: true, timeout: 5_000 });
      await this.pane.page.waitForTimeout(500);
      if (await this.isSelected()) {
        debugLogger.log(`CallTraceEntry[${functionName}]: activated via force click`);
        return;
      }
    } catch {
      debugLogger.log(`CallTraceEntry[${functionName}]: force click failed`);
    }

    // If none of the above set the selection, log a warning but don't throw.
    // The caller may still succeed (e.g., the navigation jump already happened
    // as a side effect of the search result click).
    debugLogger.log(
      `CallTraceEntry[${functionName}]: WARNING: entry not selected after all strategies, proceeding anyway`,
    );
  }

  async arguments(): Promise<CallTraceArgument[]> {
    const args = await this.argumentContainer().locator(".call-arg").all();
    return args.map((l) => new CallTraceArgument(this.pane, l, this.contextMenu));
  }

  async returnValue(): Promise<string | null> {
    if ((await this.returnLocator().count()) === 0) return null;
    return (await this.returnLocator().first().innerText()).trim();
  }
}
