import type { Locator, Page } from "@playwright/test";
import { ValueComponentView } from "../../components/value-component-view";

/**
 * Program state pane holding variables and watch expressions.
 *
 * Port of ui-tests/PageObjects/Panes/VariableState/VariableStatePane.cs
 * Absorbs the existing state.ts StatePanel.
 */
export class VariableStatePane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  private variables: ValueComponentView[] = [];

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  watchExpressionTextBox(): Locator {
    return this.root.locator("#watch");
  }

  async programStateVariables(forceReload = false): Promise<ValueComponentView[]> {
    if (forceReload || this.variables.length === 0) {
      const locators = await this.root.locator(".value-expanded").all();
      this.variables = locators.map((l) => new ValueComponentView(l));
    }
    return this.variables;
  }
}
