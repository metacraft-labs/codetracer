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

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  /**
   * Click the tab button with a layered fallback for viewport issues.
   * Mirrors CallTracePane.clickTab — see the rationale comment there.
   * Layered: normal click → click with force:true → dispatchEvent.
   */
  async clickTab(): Promise<void> {
    const btn = this.tabButton();
    try {
      await btn.click({ timeout: 5_000 });
      return;
    } catch {
      // fall through to force: true
    }
    try {
      await btn.click({ force: true, timeout: 5_000 });
      return;
    } catch {
      // fall through to dispatchEvent
    }
    await btn.dispatchEvent("click");
  }

  watchExpressionTextBox(): Locator {
    return this.root.locator("#watch");
  }

  variableRow(name: string): Locator {
    return this.root.locator(`[data-variable-name="${name}"]`).first();
  }

  async variableValueText(name: string): Promise<string> {
    return ((await this.variableRow(name).textContent()) ?? "").trim();
  }

  async programStateVariables(forceReload = false): Promise<ValueComponentView[]> {
    if (forceReload || this.variables.length === 0) {
      const locators = await this.root.locator(".value-expanded").all();
      this.variables = locators.map((l) => new ValueComponentView(l));
    }
    return this.variables;
  }

  // ---- M5: Value Origin Tracking — inline badge accessors ------------------
  //
  // The inline origin badge lives inside the variable row's outer
  // `tdiv` per `viewmodel/views/isonim_state_view.nim::renderVariableRowImpl`.
  // CSS classes asserted by the M4 ViewModel tests:
  //
  //   button.ct-origin-badge[.ct-origin-icon-{quotation,sigma,...}]
  //   span.ct-origin-badge-icon
  //   span.ct-origin-badge-text
  //
  // Placeholder pills carry the `ct-origin-badge-placeholder` modifier
  // and a `data-token` attribute; the host bridge resolves the token
  // by dispatching `ct/originSummary` (spec §3.2.3 lazy-fill).

  /** Origin badge button for the given variable row, if any. */
  originBadge(variableName: string): Locator {
    return this.variableRow(variableName).locator("button.ct-origin-badge").first();
  }

  /** Returns true when the row carries a placeholder origin badge. */
  async originBadgeIsPlaceholder(variableName: string): Promise<boolean> {
    const cls = (await this.originBadge(variableName).getAttribute("class")) ?? "";
    return cls.split(/\s+/).includes("ct-origin-badge-placeholder");
  }

  /** Click the inline badge on the named row to toggle the in-row chain. */
  async clickOriginBadge(variableName: string): Promise<void> {
    await this.originBadge(variableName).click();
  }

  /** Inline chain expansion container for the named row. */
  originInlineChain(variableName: string): Locator {
    return this.variableRow(variableName).locator(".ct-origin-inline-chain").first();
  }

  /** Hop rows inside the row's expanded inline chain. */
  originInlineChainHops(variableName: string): Locator {
    return this.originInlineChain(variableName).locator(".ct-origin-inline-chain-hop");
  }

  /** Terminator row inside the row's expanded inline chain. */
  originInlineChainTerminator(variableName: string): Locator {
    return this.originInlineChain(variableName).locator(".ct-origin-inline-chain-terminator").first();
  }
}
