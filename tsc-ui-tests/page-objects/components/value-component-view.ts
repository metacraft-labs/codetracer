import type { Locator } from "@playwright/test";

/**
 * Lightweight wrapper around the reusable value component markup used across
 * panes, including scratchpad entries, tooltips, and inline state values.
 *
 * Port of ui-tests/PageObjects/Components/ValueComponentView.cs
 */
export class ValueComponentView {
  readonly root: Locator;

  constructor(root: Locator) {
    this.root = root;
  }

  private nameContainer(): Locator {
    return this.root.locator(".value-name-container");
  }

  private expandButton(): Locator {
    return this.nameContainer().locator(".value-expand-button");
  }

  private addToScratchpadButton(): Locator {
    return this.nameContainer().locator(".add-to-scratchpad-button");
  }

  /** toggle-value-history is a sibling of value-name-container, not inside it */
  private historyToggle(): Locator {
    return this.root.locator(".toggle-value-history");
  }

  private valueTypeNode(): Locator {
    return this.root.locator(".value-type");
  }

  private valueTextNode(): Locator {
    return this.root.locator(".value-expanded-text").first();
  }

  /**
   * Extracts the label rendered before the value (e.g. `remaining_shield:`).
   */
  async name(): Promise<string> {
    const nameText = await this.nameContainer().locator(".value-name").innerText();
    return nameText.trim().replace(/:$/, "").trim();
  }

  /**
   * Returns the textual representation of the value body.
   */
  async valueText(): Promise<string> {
    return (await this.valueTextNode().innerText()).trim();
  }

  /**
   * Returns the type annotation if the component exposes one.
   */
  async valueType(): Promise<string | null> {
    if ((await this.valueTypeNode().count()) === 0) {
      return null;
    }
    return (await this.valueTypeNode().first().innerText()).trim();
  }

  /**
   * Indicates whether the value supports nested expansion.
   */
  async isExpandable(): Promise<boolean> {
    return (
      (await this.expandButton().locator(".caret-expand, .caret-collapse").count()) > 0
    );
  }

  /**
   * Attempts to expand the value component (no-op if not expandable).
   */
  async expand(): Promise<void> {
    if (await this.isExpandable()) {
      await this.expandButton().click();
    }
  }

  /**
   * Determines whether the inline "Add to scratchpad" button is available.
   */
  async hasAddToScratchpadButton(): Promise<boolean> {
    return (await this.addToScratchpadButton().count()) > 0;
  }

  /**
   * Clicks the inline "Add to scratchpad" button.
   */
  async clickAddToScratchpad(): Promise<void> {
    if (!(await this.hasAddToScratchpadButton())) {
      throw new Error(
        "This value component does not expose an inline Add to scratchpad button.",
      );
    }
    await this.addToScratchpadButton().click();
  }

  /**
   * Indicates whether the value component offers a history toggle.
   */
  async hasHistoryToggle(): Promise<boolean> {
    return (await this.historyToggle().count()) > 0;
  }

  /**
   * Invokes the history toggle.
   */
  async toggleHistory(): Promise<void> {
    if (!(await this.hasHistoryToggle())) {
      throw new Error(
        "No history toggle is available for this value component.",
      );
    }
    await this.historyToggle().click();
  }
}
