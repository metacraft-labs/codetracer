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

  /**
   * The watch-expression input.
   *
   * `#watch-0`, NOT `#watch`. The view renders
   * `input#watch-{componentId}` (`isonim_state_view.nim`, and the legacy
   * `StateComponent.watchInputId` before it), so the bare `#watch` this
   * used to ask for has never matched an element in any product. Nothing
   * caught it because no spec ever typed into the box — the locator was
   * defined and never asserted through.
   */
  watchExpressionTextBox(): Locator {
    return this.root.locator("#watch-0");
  }

  /** The Locals / Globals / Watches tab strip inside the pane. */
  stateTabButton(which: "locals" | "globals" | "watches"): Locator {
    return this.root.locator(`.state-tabs .tab-${which}`).first();
  }

  /**
   * Switch the pane to one of its three tabs.
   *
   * This is a click on the product's own button, deliberately, and not a
   * `vm.selectTab` call: until the tab strip was added to the WebRenderer
   * panel the Watches tab could ONLY be reached from a ViewModel call, so
   * a test that reached it that way would have passed against a product
   * in which no user could get there.
   */
  async selectStateTab(which: "locals" | "globals" | "watches"): Promise<void> {
    const btn = this.stateTabButton(which);
    await btn.waitFor({ state: "visible", timeout: 15_000 });
    try {
      await btn.click({ timeout: 5_000 });
    } catch {
      await btn.dispatchEvent("click");
    }
  }

  /**
   * Type an expression into the watch box and submit it.
   *
   * Typed as KEYSTROKES and submitted with Enter, because the form's
   * `submit` handler is what calls `StateVM.addWatch` — setting the
   * input's `value` property would bypass the only path a user has.
   */
  async addWatchExpression(expression: string): Promise<void> {
    const box = this.watchExpressionTextBox();
    await box.waitFor({ state: "visible", timeout: 15_000 });
    await box.click();
    await box.fill("");
    await box.type(expression, { delay: 10 });
    await box.press("Enter");
  }

  variableRow(name: string): Locator {
    return this.root.locator(`[data-variable-name="${name}"]`).first();
  }

  /**
   * Text of a variable row, or `""` when the pane holds no such row.
   *
   * The `""` return is load-bearing, not a convenience: every caller
   * uses `variableValueText(x) !== ""` as an *existence* probe inside a
   * stepping loop ("keep stepping until `balance` is bound"). Playwright's
   * `Locator.textContent()` auto-waits, so on an absent row it does not
   * return `null` — it throws `TimeoutError` after the default 30s. That
   * made the very first probe of every such loop fatal, so none of those
   * loops was reachable: the specs could not wait for a value that takes
   * more than zero steps to appear. `waitFor` with a short cap restores
   * the intended semantics while still tolerating a row that is a beat
   * behind the step it belongs to.
   */
  async variableValueText(name: string, timeoutMs = 1_000): Promise<string> {
    const row = this.variableRow(name);
    try {
      await row.waitFor({ state: "attached", timeout: timeoutMs });
    } catch {
      return "";
    }
    return ((await row.textContent()) ?? "").trim();
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
