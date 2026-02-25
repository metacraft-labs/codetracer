import type { Locator } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";

const DEFAULT_CONTEXT_MENU_ENTRIES = [
  "Jump to value",
  "Add value to scratchpad",
  "Add all values to scratchpad",
];

/**
 * Represents a single flow value rendered alongside the editor.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/FlowValue.cs
 */
export class FlowValue {
  readonly root: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(root: Locator, contextMenu: ContextMenu) {
    this.root = root;
    this.contextMenu = contextMenu;
  }

  /**
   * Checks if this flow value supports scratchpad operations.
   * Stdout flow values (with class flow-std-default-box) don't support scratchpad.
   */
  async supportsScratchpad(): Promise<boolean> {
    const classAttr = await this.root.getAttribute("class");
    if (classAttr?.includes("flow-std-default-box")) {
      return false;
    }

    const id = await this.root.getAttribute("id");
    if (!id) {
      return true;
    }

    // ID pattern: flow-{mode}-value-box-{i}-{step}-{expression}
    // Stdout pattern: flow-{mode}-value-box-{i}-{step}
    const parts = id.split("-");
    return parts.length >= 6;
  }

  /**
   * Friendly name associated with the flow value.
   */
  async name(): Promise<string> {
    const nameLocator = this.root.locator(
      "xpath=preceding-sibling::span[contains(@class,'value-name')]",
    );
    if ((await nameLocator.count()) > 0) {
      const text = await nameLocator.last().innerText();
      return text.replace(/:$/, "").trim();
    }

    const fallback = await this.root.getAttribute("data-expression");
    return fallback ?? "";
  }

  /**
   * Textual representation of the value.
   */
  async valueText(): Promise<string> {
    return (await this.root.innerText()).trim();
  }

  get expectedContextMenuEntries(): readonly string[] {
    return DEFAULT_CONTEXT_MENU_ENTRIES;
  }

  /**
   * Opens the context menu for this flow value.
   * Uses JavaScript event dispatch because Monaco content widgets
   * may not respond to standard Playwright right-click.
   */
  async openContextMenu(): Promise<ContextMenu> {
    await this.root.scrollIntoViewIfNeeded();

    await this.root.evaluate((element: Element) => {
      const rect = element.getBoundingClientRect();
      const event = new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        view: window,
        button: 2,
        buttons: 2,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
      });
      element.dispatchEvent(event);
    });

    await this.contextMenu.waitForVisible();
    return this.contextMenu;
  }

  /**
   * Reads the available context menu entries.
   */
  async contextMenuEntries(): Promise<string[]> {
    const menu = await this.openContextMenu();
    const entries = await menu.getEntries();
    await menu.dismiss();
    return entries.map((e) => e.text);
  }

  /**
   * Adds this flow value to the scratchpad using Ctrl+click.
   */
  async addToScratchpad(): Promise<void> {
    await this.root.scrollIntoViewIfNeeded();
    await this.root.click({ modifiers: ["Control"] });
  }

  /**
   * Selects a specific context menu option.
   */
  async selectContextMenuOption(option: string): Promise<void> {
    if (option.toLowerCase().includes("add value to scratchpad")) {
      await this.addToScratchpad();
      return;
    }
    const menu = await this.openContextMenu();
    await menu.select(option);
  }
}
