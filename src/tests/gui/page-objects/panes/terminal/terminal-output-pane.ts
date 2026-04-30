import type { Locator, Page } from "@playwright/test";
import { TerminalLine } from "./terminal-line";

/**
 * Wraps the terminal output component within the layout.
 *
 * Port of ui-tests/PageObjects/Panes/Terminal/TerminalOutputPane.cs
 */
export class TerminalOutputPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private lines_: TerminalLine[] = [];

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  linesContainer(): Locator {
    return this.root.locator("pre");
  }

  async lines(forceReload = false): Promise<TerminalLine[]> {
    if (forceReload || this.lines_.length === 0) {
      const roots = await this.linesContainer().locator(".terminal-line").all();
      this.lines_ = roots.map((l) => new TerminalLine(l));
    }
    return this.lines_;
  }

  async lineByIndex(
    index: number,
    forceReload = false,
  ): Promise<TerminalLine | null> {
    const lines = await this.lines(forceReload);
    for (const line of lines) {
      if ((await line.lineIndex()) === index) {
        return line;
      }
    }
    return null;
  }
}
