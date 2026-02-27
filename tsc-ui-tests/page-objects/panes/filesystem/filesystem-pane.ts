import type { Locator, Page } from "@playwright/test";
import { ContextMenu, createJsTreeContextMenu } from "../../components/context-menu";
import { FilesystemNode } from "./filesystem-node";
import { retry } from "../../../lib/retry-helpers";

const TREE_SELECTOR = ".filesystem";
const DEFAULT_CONTEXT_MENU_ENTRIES = ["Create", "Rename", "Delete", "Edit"];
const CHILD_WAIT_ATTEMPTS = 20;
const CHILD_WAIT_DELAY_MS = 200;

/**
 * Page object encapsulating the filesystem tree component.
 *
 * Port of ui-tests/PageObjects/Panes/Filesystem/FilesystemPane.cs
 */
export class FilesystemPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private readonly contextMenu: ContextMenu;

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
    this.contextMenu = createJsTreeContextMenu(page);
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  get treeLocator(): Locator {
    return this.root.locator(TREE_SELECTOR);
  }

  get expectedContextMenuEntries(): readonly string[] {
    return DEFAULT_CONTEXT_MENU_ENTRIES;
  }

  async waitForReady(): Promise<void> {
    await this.treeLocator.waitFor({ state: "visible" });
  }

  private nodeSelectorForLevel(level: number): string {
    return `li.jstree-node[aria-level='${level}']`;
  }

  private anchorSelectorForLevel(level: number): string {
    return `${this.nodeSelectorForLevel(level)} > a.jstree-anchor`;
  }

  private async locateNode(name: string, level: number): Promise<Locator> {
    const anchors = await this.treeLocator
      .locator(this.anchorSelectorForLevel(level))
      .filter({ hasText: name })
      .all();

    for (const anchor of anchors) {
      const node = anchor.locator("..");
      if ((await node.count()) > 0) {
        return node;
      }
    }

    throw new Error(`Filesystem node '${name}' at level ${level} was not found.`);
  }

  private async nodeBySegments(
    segments: string[],
    expandIntermediate: boolean,
  ): Promise<FilesystemNode> {
    if (segments.length === 0) {
      throw new Error("At least one segment must be provided.");
    }

    await this.waitForReady();

    let currentNodeLocator: Locator | null = null;

    for (let index = 0; index < segments.length; index++) {
      const level = index + 1;
      const name = segments[index];
      currentNodeLocator = await this.locateNode(name, level);
      const node = new FilesystemNode(this, this.page, currentNodeLocator, this.contextMenu);

      if (expandIntermediate && index < segments.length - 1) {
        await node.expand();
        const childSelector = this.nodeSelectorForLevel(level + 1);
        await retry(
          async () => {
            return (
              (await currentNodeLocator!
                .locator(`> ul > ${childSelector}`)
                .count()) > 0
            );
          },
          { maxAttempts: CHILD_WAIT_ATTEMPTS, delayMs: CHILD_WAIT_DELAY_MS },
        );
      }
    }

    return new FilesystemNode(this, this.page, currentNodeLocator!, this.contextMenu);
  }

  async nodeByPath(...segments: string[]): Promise<FilesystemNode> {
    return this.nodeBySegments(segments, true);
  }

  async visibleNodes(): Promise<FilesystemNode[]> {
    await this.waitForReady();
    const nodes = await this.treeLocator.locator("li.jstree-node").all();
    return nodes.map(
      (l) => new FilesystemNode(this, this.page, l, this.contextMenu),
    );
  }
}
