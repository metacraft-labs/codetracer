import type { Locator, Page } from "@playwright/test";
import { ContextMenu } from "../../components/context-menu";
import type { FilesystemPane } from "./filesystem-pane";
import { retry } from "../../../lib/retry-helpers";

const POST_EXPAND_DELAY_MS = 500;

/**
 * Represents a single filesystem entry rendered by the jstree component.
 *
 * Port of ui-tests/PageObjects/Panes/Filesystem/FilesystemNode.cs
 */
export class FilesystemNode {
  private readonly pane: FilesystemPane;
  readonly nodeLocator: Locator;
  readonly anchorLocator: Locator;
  private readonly contextMenu: ContextMenu;

  constructor(
    pane: FilesystemPane,
    page: Page,
    nodeLocator: Locator,
    contextMenu: ContextMenu,
  ) {
    this.pane = pane;
    this.nodeLocator = nodeLocator;
    this.anchorLocator = nodeLocator.locator("> a.jstree-anchor");
    this.contextMenu = contextMenu;
  }

  async name(): Promise<string> {
    return (await this.anchorLocator.innerText()).trim();
  }

  async level(): Promise<number> {
    const attr = await this.nodeLocator.getAttribute("aria-level");
    return attr ? parseInt(attr, 10) || -1 : -1;
  }

  async isExpanded(): Promise<boolean> {
    const classAttr = (await this.nodeLocator.getAttribute("class")) ?? "";
    return classAttr.split(/\s+/).includes("jstree-open");
  }

  async isLeaf(): Promise<boolean> {
    const classAttr = (await this.nodeLocator.getAttribute("class")) ?? "";
    return classAttr.split(/\s+/).includes("jstree-leaf");
  }

  private toggleLocator(): Locator {
    return this.nodeLocator.locator("> i.jstree-ocl");
  }

  async expand(): Promise<void> {
    if ((await this.isLeaf()) || (await this.isExpanded())) return;
    await this.toggleLocator().click();
    await retry(() => this.isExpanded());
  }

  async collapse(): Promise<void> {
    if ((await this.isLeaf()) || !(await this.isExpanded())) return;
    await this.toggleLocator().click();
    await retry(async () => !(await this.isExpanded()));
  }

  async leftClick(): Promise<void> {
    try {
      await this.anchorLocator.click({ timeout: 5_000 });
      return;
    } catch {
      // fall through to force: true
    }
    try {
      await this.anchorLocator.click({ force: true, timeout: 5_000 });
      return;
    } catch {
      // fall through to dispatchEvent
    }
    await this.anchorLocator.dispatchEvent("click");
  }

  /**
   * Opens the filesystem context menu.
   *
   * The production IsoNim filesystem view renders jstree-compatible DOM
   * classes but uses CodeTracer's shared context-menu widget rather than
   * the old $.vakata menu plugin.
   */
  async openContextMenu(): Promise<ContextMenu> {
    await this.anchorLocator.scrollIntoViewIfNeeded();
    await sleep(POST_EXPAND_DELAY_MS);

    await this.anchorLocator.evaluate((anchor: Element) => {
      const rect = anchor.getBoundingClientRect();
      anchor.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          view: window,
          button: 2,
          buttons: 2,
          clientX: rect.left + rect.width / 2,
          clientY: rect.top + rect.height,
        }),
      );
    });

    await this.contextMenu.container.waitFor({ state: "visible", timeout: 10_000 });
    return this.contextMenu;
  }

  async contextMenuOptions(): Promise<string[]> {
    const menu = await this.openContextMenu();
    const entries = await menu.getEntries();
    await menu.dismiss();
    return entries.map((e) => e.text);
  }

  async selectContextMenuOption(option: string): Promise<void> {
    const menu = await this.openContextMenu();
    await menu.select(option);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
