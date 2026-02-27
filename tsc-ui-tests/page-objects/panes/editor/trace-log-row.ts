import type { Locator } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";

/**
 * Represents a single trace log table row.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/TraceLogRow.cs
 */
export class TraceLogRow {
  readonly root: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(root: Locator, contextMenu: ContextMenu) {
    this.root = root;
    this.contextMenu = contextMenu;
  }

  async text(): Promise<string> {
    return (await this.root.innerText()).trim();
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

  async selectMenuOption(option: string): Promise<void> {
    const menu = await this.openContextMenu();
    await menu.select(option);
  }
}
