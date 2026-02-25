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
   * Tries multiple hit targets and click strategies.
   */
  async activate(): Promise<void> {
    const functionName = await this.functionName();
    debugLogger.log(`CallTraceEntry[${functionName}]: Begin activate`);

    const targets: [string, Locator][] = [
      ["call-text", this.callTextLocator()],
      ["child-box", this.childBoxLocator()],
      ["root", this.root],
    ];

    const clickStrategies: [string, { clickCount?: number; delay?: number; force?: boolean }][] = [
      ["single-click", { clickCount: 1 }],
      ["double-click", { clickCount: 2, delay: ACTIVATE_DOUBLE_CLICK_DELAY_MS }],
      ["forced-click", { clickCount: 1, force: true }],
    ];

    for (const [targetLabel, target] of targets) {
      try {
        await target.scrollIntoViewIfNeeded();
      } catch {
        debugLogger.log(`CallTraceEntry[${functionName}]: scroll failed for ${targetLabel}`);
      }

      for (const [clickLabel, options] of clickStrategies) {
        try {
          debugLogger.log(`CallTraceEntry[${functionName}]: clicking ${targetLabel} with ${clickLabel}`);
          await target.click(options);
          try {
            await retry(() => this.isSelected(), {
              maxAttempts: ACTIVATE_RETRY_ATTEMPTS,
              delayMs: ACTIVATE_RETRY_DELAY_MS,
            });
            debugLogger.log(
              `CallTraceEntry[${functionName}]: activation succeeded via ${targetLabel}/${clickLabel}`,
            );
            return;
          } catch {
            debugLogger.log(
              `CallTraceEntry[${functionName}]: selection timeout after ${targetLabel}/${clickLabel}`,
            );
          }
        } catch {
          debugLogger.log(
            `CallTraceEntry[${functionName}]: click failed on ${targetLabel}/${clickLabel}`,
          );
        }
      }
    }

    throw new Error("Failed to activate call trace entry via any known target.");
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
