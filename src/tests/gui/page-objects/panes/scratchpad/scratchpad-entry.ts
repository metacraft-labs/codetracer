import type { Locator } from "@playwright/test";
import { ValueComponentView } from "../../components/value-component-view";

/**
 * Represents a single scratchpad record rendered inside the scratchpad pane.
 *
 * Port of ui-tests/PageObjects/Panes/Scratchpad/ScratchpadEntry.cs
 */
export class ScratchpadEntry {
  readonly root: Locator;
  readonly valueComponent: ValueComponentView;

  constructor(root: Locator) {
    this.root = root;
    this.valueComponent = new ValueComponentView(
      root.locator(".value-expanded").first(),
    );
  }

  closeButton(): Locator {
    return this.root.locator(".scratchpad-value-close");
  }

  async close(): Promise<void> {
    await this.closeButton().click();
  }

  async expression(): Promise<string> {
    const name = await this.valueComponent.name();
    return name.replace(/:$/, "").trim();
  }

  async valueText(): Promise<string> {
    return this.valueComponent.valueText();
  }

  async valueType(): Promise<string | null> {
    return this.valueComponent.valueType();
  }
}
