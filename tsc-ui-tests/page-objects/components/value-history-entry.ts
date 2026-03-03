import type { Locator } from "@playwright/test";
import { ContextMenu } from "./context-menu";

/**
 * Represents a single entry in a value history timeline.
 *
 * Port of ui-tests/PageObjects/Components/ValueHistoryEntry.cs
 */
export class ValueHistoryEntry {
  readonly root: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(root: Locator, contextMenu: ContextMenu) {
    this.root = root;
    this.contextMenu = contextMenu;
  }

  /**
   * Returns the value text rendered in the entry.
   */
  async valueText(): Promise<string> {
    return (await this.root.innerText()).trim();
  }

  /**
   * Opens the context menu for this history entry.
   */
  async openContextMenu(): Promise<ContextMenu> {
    await this.root.click({ button: "right" });
    await this.contextMenu.waitForVisible();
    return this.contextMenu;
  }

  /**
   * Retrieves the visible context menu entry texts.
   */
  async contextMenuEntries(): Promise<string[]> {
    const menu = await this.openContextMenu();
    const entries = await menu.getEntries();
    await menu.dismiss();
    return entries.map((e) => e.text);
  }

  /**
   * Selects the "Add to scratchpad" option.
   */
  async addToScratchpad(): Promise<void> {
    const menu = await this.openContextMenu();
    await menu.select("Add to scratchpad");
  }
}
