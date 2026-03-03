import type { Locator } from "@playwright/test";

/**
 * Represents a single rendered line inside the terminal output pane.
 *
 * Port of ui-tests/PageObjects/Panes/Terminal/TerminalLine.cs
 */
export class TerminalLine {
  readonly root: Locator;

  constructor(root: Locator) {
    this.root = root;
  }

  private stateContainer(): Locator {
    return this.root.locator("> div").first();
  }

  async lineIndex(): Promise<number> {
    const idAttr = await this.root.getAttribute("id");
    if (!idAttr) return -1;
    const suffix = idAttr.split("-").pop();
    return suffix ? parseInt(suffix, 10) || -1 : -1;
  }

  /**
   * Returns the current temporal state (past, active, future) from CSS classes.
   */
  async state(): Promise<string> {
    const classAttr = (await this.stateContainer().getAttribute("class")) ?? "";
    return classAttr.split(/\s+/).filter(Boolean)[0] ?? "";
  }

  async isGrayedOut(): Promise<boolean> {
    const state = await this.state();
    return state.toLowerCase() === "future";
  }

  async text(): Promise<string> {
    return (await this.root.innerText()).trim();
  }

  async click(button: "left" | "right" = "left"): Promise<void> {
    await this.root.click({ button });
  }
}
