import type { Locator } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";
import type { ValueComponentView } from "../../components/value-component-view";
import type { CallTracePane } from "./call-trace-pane";
import { retry } from "../../../lib/retry-helpers";

const DEFAULT_CONTEXT_MENU_ENTRIES = ["Add value to scratchpad"];

/**
 * Represents a single argument entry within a call trace record.
 *
 * Port of ui-tests/PageObjects/Panes/CallTrace/CallTraceArgument.cs
 */
export class CallTraceArgument {
  private readonly pane: CallTracePane;
  readonly root: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(pane: CallTracePane, root: Locator, contextMenu: ContextMenu) {
    this.pane = pane;
    this.root = root;
    this.contextMenu = contextMenu;
  }

  private nameLocator(): Locator {
    return this.root.locator(".call-arg-name");
  }

  private valueLocator(): Locator {
    return this.root.locator(".call-arg-text");
  }

  async name(): Promise<string> {
    const text = await this.nameLocator().innerText();
    return text.replace(/=$/, "").trim();
  }

  async value(): Promise<string> {
    return (await this.valueLocator().innerText()).trim();
  }

  async openContextMenu(): Promise<ContextMenu> {
    await this.root.click({ button: "right" });
    await this.contextMenu.waitForVisible();
    return this.contextMenu;
  }

  async contextMenuEntries(): Promise<string[]> {
    const menu = await this.openContextMenu();
    const entries = await menu.getEntries();
    await menu.dismiss();
    return entries.map((e) => e.text);
  }

  get expectedContextMenuEntries(): readonly string[] {
    return DEFAULT_CONTEXT_MENU_ENTRIES;
  }

  async addToScratchpad(): Promise<void> {
    const menu = await this.openContextMenu();
    await menu.select(DEFAULT_CONTEXT_MENU_ENTRIES[0]);
  }

  async openTooltip(): Promise<ValueComponentView | null> {
    await this.root.click();
    await retry(async () => (await this.pane.activeTooltip()) !== null);
    return this.pane.activeTooltip();
  }
}
