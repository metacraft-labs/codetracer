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
  private readonly _page: Page;
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
    this._page = page;
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
    await this.anchorLocator.click();
  }

  /**
   * Opens the context menu using jstree's $.vakata.context.show() API.
   * Direct DOM right-click doesn't trigger jQuery-bound jstree handlers.
   */
  async openContextMenu(): Promise<ContextMenu> {
    await this.anchorLocator.scrollIntoViewIfNeeded();
    await sleep(POST_EXPAND_DELAY_MS);

    const nodeId = await this.nodeLocator.getAttribute("id");

    await this._page.evaluate((nid: string) => {
      const jq = (window as any).$ || (window as any).jQuery; // eslint-disable-line @typescript-eslint/no-explicit-any
      if (!jq) throw new Error("jQuery is not available");
      if (!jq.vakata?.context?.show) {
        throw new Error("$.vakata.context is not available");
      }

      const tree = jq(".filesystem").jstree(true);
      if (!tree) throw new Error("jstree instance not found");

      const node = tree.get_node(nid);
      if (!node) throw new Error("jstree node not found: " + nid);

      const itemsFn = tree.settings.contextmenu.items;
      const items = typeof itemsFn === "function" ? itemsFn.call(tree, node) : itemsFn;
      if (!items || typeof items !== "object") {
        throw new Error("contextmenu items is empty or not an object");
      }

      const anchor = document.getElementById(nid + "_anchor");
      if (!anchor) throw new Error("anchor element not found for node: " + nid);
      const rect = anchor.getBoundingClientRect();

      jq(anchor).addClass("jstree-context");
      tree._data.contextmenu.visible = true;

      jq.vakata.context.show(jq(anchor), {
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height,
      }, items);
    }, nodeId!);

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
