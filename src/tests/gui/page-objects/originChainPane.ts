/**
 * M5 page-object — Value Origin Tracking Origin Chain Panel.
 *
 * Wraps the inline-badge + in-row chain affordances on Variable State
 * Pane rows AND the dedicated Origin Chain side-panel mounted as an
 * overlay on `document.body` per `ui/state.nim::ensureOriginSidePanelHost`.
 *
 * Selectors are sourced from the production Nim renderers so changes
 * to the DOM structure surface here as type-checked test failures
 * rather than silent rendering breakage:
 *
 * - State Pane row badge:
 *     viewmodel/views/isonim_state_view.nim::renderVariableRowImpl
 *     → button.ct-origin-badge[.ct-origin-icon-...][.ct-origin-badge-placeholder]
 * - State Pane in-row chain:
 *     same renderer, div.ct-origin-inline-chain
 *     → ol > li.ct-origin-inline-chain-hop  (one per hop)
 *     → li.ct-origin-inline-chain-terminator
 * - Side-panel overlay:
 *     ui/state.nim::ensureOriginSidePanelHost  →  aside#ct-origin-chain-side-panel
 *     ui/isonim_origin_chain.nim::renderPanelDom  →  section/nav/ol/li...
 * - Side-panel hop operand details:
 *     same renderer  →  details > summary "<n> operand snapshots"
 *
 * The helpers below match the M5 deliverable list verbatim
 * (`clickBadge`, `expandedChainHops`, `clickHop`,
 * `expandComputationalOperands`, `pinChain`, `copyAsMarkdown`,
 * `breadcrumbChips`, `keyboardNavigate`).
 */
import type { Locator, Page } from "@playwright/test";

export const ORIGIN_SIDE_PANEL_SELECTOR = "aside#ct-origin-chain-side-panel";

export class OriginChainPanePageObject {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // ---- State Pane inline badge + in-row chain --------------------------

  /**
   * Inline badge button on the State Pane variable row identified by
   * `variableName`. Always returns a Locator — visibility check is on
   * the caller (use `.toBeVisible()` from Playwright's `expect`).
   */
  badge(variableName: string): Locator {
    return this.page
      .locator(`[data-variable-name="${variableName}"]`)
      .locator("button.ct-origin-badge")
      .first();
  }

  /**
   * Click the inline badge on the named row. The production click
   * handler toggles the in-row chain expansion AND opens the dedicated
   * side panel per spec §3.2.1 / §3.2.2.
   */
  async clickBadge(variableName: string): Promise<void> {
    await this.badge(variableName).click();
  }

  /**
   * In-row chain container for the named row.
   */
  inlineChain(variableName: string): Locator {
    return this.page
      .locator(`[data-variable-name="${variableName}"]`)
      .locator(".ct-origin-inline-chain")
      .first();
  }

  /**
   * Hop locators inside the row's in-row chain. Returns one Locator per
   * `<li class="ct-origin-inline-chain-hop">`.
   */
  expandedChainHops(variableName: string): Locator {
    return this.inlineChain(variableName).locator(".ct-origin-inline-chain-hop");
  }

  /**
   * Terminator row of the in-row chain (no per-hop list entry — spec
   * §3.2.2 calls for a single terminator row at the bottom of the
   * chain with the terminator icon + expression).
   */
  inlineChainTerminator(variableName: string): Locator {
    return this.inlineChain(variableName)
      .locator(".ct-origin-inline-chain-terminator")
      .first();
  }

  /**
   * Click the n-th hop inside the in-row chain (0-based). Triggers
   * `OriginChainVM.onSeekToHop` → `ct/history-jump` → editor scrolls.
   */
  async clickHop(variableName: string, index: number): Promise<void> {
    await this.expandedChainHops(variableName).nth(index).click();
  }

  // ---- Dedicated side panel (`aside#ct-origin-chain-side-panel`) -------

  /**
   * The dedicated side panel host element. Visibility flips when
   * `OriginChainVM.sidePanelOpen` toggles.
   */
  sidePanel(): Locator {
    return this.page.locator(ORIGIN_SIDE_PANEL_SELECTOR);
  }

  /** Hop list inside the side panel. */
  sidePanelHops(): Locator {
    return this.sidePanel().locator("section > ol > li").filter({
      hasNot: this.page.locator(".ct-origin-terminator-row"),
    });
  }

  /** Side-panel terminator row (final `<li class="ct-origin-terminator-row">`). */
  sidePanelTerminator(): Locator {
    return this.sidePanel().locator(".ct-origin-terminator-row").first();
  }

  /**
   * Click the n-th side-panel hop (0-based). Production handler
   * dispatches `OriginChainVM.onSeekToHop`.
   */
  async clickSidePanelHop(index: number): Promise<void> {
    await this.sidePanelHops().nth(index).locator("button").first().click();
  }

  /**
   * Expand the `<details>` element of the focused Computational hop's
   * operand snapshots (spec §3.2.2: "For computational hops, a chevron
   * to the right of Line 1 expands a third group showing operand
   * snapshots").
   */
  async expandComputationalOperands(hopIndex: number): Promise<void> {
    const hop = this.sidePanelHops().nth(hopIndex);
    const details = hop.locator("details").first();
    if (!(await details.isVisible())) {
      return;
    }
    const summary = details.locator("summary").first();
    await summary.click();
  }

  /**
   * Operand snapshot rows inside the n-th hop's expanded operand
   * panel. Each row text reads `<name> = <value>`.
   */
  operandRows(hopIndex: number): Locator {
    return this.sidePanelHops()
      .nth(hopIndex)
      .locator("details > div");
  }

  /**
   * Pin the active chain to the Scratchpad pane. Production handler:
   * `OriginChainVM.onPinChain` → `onPinChainProc` → `ScratchpadVM.addChain`.
   *
   * The "Pin to scratchpad" button lives in the side-panel footer
   * (`ui/isonim_origin_chain.nim::renderPanelDom` appends one
   * `<footer><button>Pin to scratchpad</button></footer>`).
   */
  async pinChain(): Promise<void> {
    await this.sidePanel()
      .locator("footer button", { hasText: "Pin to scratchpad" })
      .first()
      .click();
  }

  /**
   * "Copy as markdown" affordance — the spec §3.3 right-click → "Copy
   * as markdown" routes through the side-panel's context menu. The
   * page-object exposes a single click helper so spec authors don't
   * have to navigate the menu themselves.
   *
   * NOTE: The production menu wiring is part of the M4 right-click
   * menu (see `ui/value.nim::createContextMenuItems` for the existing
   * "Copy as markdown" entry on value rows). On the side panel itself
   * the affordance is reached through a button under `footer`; this
   * helper falls back to a button matcher so either rendering passes.
   */
  async copyAsMarkdown(): Promise<void> {
    const footerButton = this.sidePanel()
      .locator("footer button", { hasText: "Copy as markdown" });
    if (await footerButton.count() > 0) {
      await footerButton.first().click();
      return;
    }
    // Fallback: open the side panel's contextual menu.
    await this.sidePanel().click({ button: "right" });
    await this.page.locator("text=Copy as markdown").first().click();
  }

  /**
   * Breadcrumb chip locators (one `<button>` per
   * `OriginChainVM.breadcrumbStack` entry per
   * `ui/isonim_origin_chain.nim::renderPanelDom`).
   */
  breadcrumbChips(): Locator {
    return this.sidePanel().locator("nav > button");
  }

  /**
   * Fire a single keyboard event against the side-panel host. The host
   * element installs a `keydown` listener (see
   * `ui/state.nim::ensureOriginSidePanelHost`) that routes:
   *
   *   ArrowDown / ArrowUp → focusNextHop / focusPrevHop
   *   Enter               → enterHop (seek)
   *   ArrowRight          → expandFocusedOperands
   *   ArrowLeft           → collapseFocusedOperands
   *   Escape              → dismissPanel + closeSidePanel
   *
   * The `key` argument matches Playwright's keyboard.press syntax.
   */
  async keyboardNavigate(key: string): Promise<void> {
    await this.sidePanel().focus();
    await this.page.keyboard.press(key);
  }

  /**
   * Convenience: open the right-click "Show value origin" menu on a
   * State Pane row. The production renderer attaches an
   * `oncontextmenu` handler that publishes the menu via
   * `StateVM.lastContextMenu` and, on JS, forwards into
   * `isonim_dom.showContextMenu`.
   */
  async rightClickRow(variableName: string): Promise<void> {
    await this.page
      .locator(`[data-variable-name="${variableName}"]`)
      .first()
      .click({ button: "right" });
  }

  /**
   * After the right-click menu opens, click the "Show value origin"
   * entry. The production code path: menu entry's `action()` invokes
   * `StateVM.onShowOrigin` → `OriginChainVM.onShowOrigin` (via the
   * bridge installed by `ui/state.nim::wireOriginChainBridges`).
   */
  async clickShowValueOriginMenuItem(): Promise<void> {
    await this.page.locator("text=Show value origin").first().click();
  }
}
