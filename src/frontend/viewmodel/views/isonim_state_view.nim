## views/isonim_state_view.nim
##
## IsoNim DOM-rendering view for the State (Locals / Globals / Watches)
## panel — primary renderer.
##
## Renders a live, reactive DOM tree driven by `StateVM` signals.
## When the VM's signals change (active tab, variable list, loading
## state, watch expressions), the DOM updates automatically via
## IsoNim's `createRenderEffect`.
##
## Two structures are produced:
##
## - `MockRenderer` — simple test-friendly DOM used by headless unit
##   tests (see `src/tests/gui/tests/views/isonim_views_test.nim`).
##
## - `WebRenderer` — Karax-compatible DOM for the real browser. The
##   DOM matches the legacy Karax `value-component` markup so that
##   Playwright tests (which query `.value-expanded`, `.value-name`,
##   `.value-expanded-text`, etc.) continue to work unchanged.
##
## In both cases the panel structure is expressed in single `ui()`
## blocks; per-row content is also expressed via the DSL inside the
## `indexEach` body so the structure is visible at a glance.

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/state_vm
import ../viewmodels/origin_chain_types
import ../views/state_view

# Re-export the shared origin types so the headless tests that ``import
# views/isonim_state_view`` can read ``OriginSummary`` / ``placeholderSummary``
# without an extra import line (same convenience the scratchpad view uses).
export origin_chain_types

# ---------------------------------------------------------------------------
# Static label / class helpers
# ---------------------------------------------------------------------------

proc tabCssClass(tab: StateTab): string =
  ## CSS class name for a tab button — used both for the static class
  ## and for the dynamic active-modifier expression.
  case tab
  of stLocals:  "tab-locals"
  of stGlobals: "tab-globals"
  of stWatches: "tab-watches"

proc tabLabel(tab: StateTab): string =
  case tab
  of stLocals:  "Locals"
  of stGlobals: "Globals"
  of stWatches: "Watches"

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc displayFlexIf(cond: bool): string =
  if cond: "flex" else: "none"

# ---------------------------------------------------------------------------
# Code-state-line helpers
# ---------------------------------------------------------------------------
#
# The legacy Karax ``StateComponent.excerpt`` rendered the active source
# line above the variables list as
#   <div id="code-state-line-{id}" class="code-state-line">
#     <span>{line} | {sourceCode}</span>
#     <ul class="code-tooltip">...</ul>
#   </div>
# falling back to ``class="code-state-line no-code"`` and a blank span
# when the source for the current file was not yet loaded.  Keeping the
# `#code-state-line-{id}` element in the DOM regardless of source
# availability is important because Playwright tests assert
# ``locator('#code-state-line-0')`` exists before they read its text.
# Only the *class* changes between the populated and fallback states,
# matching the legacy behaviour.

proc codeStateLineClass(vm: StateVM): string =
  if vm.codeStateLine.val.len == 0: "code-state-line no-code"
  else: "code-state-line"

proc codeStateLineText(vm: StateVM): string =
  ## The formatted text rendered inside the inner ``<span>``. Empty
  ## when there is no source for the current position — matching the
  ## legacy ``excerpt`` proc's no-code branch which emitted an empty
  ## ``<span>`` so the outer wrapper still occupies a stable slot in
  ## the layout.
  vm.codeStateLine.val

# ---------------------------------------------------------------------------
# Reactive expressions (used inside DSL attributes)
# ---------------------------------------------------------------------------
#
# Each helper reads one or more signals and returns a string. The DSL
# attribute that calls the helper is detected as dynamic, so the macro
# wraps the call in a `createRenderEffect` and tracks its signal reads
# automatically.

proc tabClass(vm: StateVM; tab: StateTab): string =
  ## Tab button class with the optional `active` modifier.
  let cls = tabCssClass(tab)
  if vm.activeTab.val == tab: cls & " active" else: cls

proc atomOrCompoundClass(item: proc(): VariableViewState): string =
  ## "value-expanded-compound-parent" when the variable is an expanded
  ## compound; otherwise "value-expanded-atom-parent". Mirrors the
  ## legacy Karax value-component class branching.
  let v = item()
  if v.hasChildren and v.isExpanded:
    "value-expanded-compound-parent"
  else:
    "value-expanded-atom-parent"

proc rowClass(item: proc(): VariableViewState): string =
  ## Outer row class with depth-borders class.
  "value-expanded value-expanded-name border-value-" & $item().depth

proc rowPaddingLeft(item: proc(): VariableViewState; pxPerLevel: int): string =
  let depth = item().depth
  if depth > 0: $(depth * pxPerLevel) & "px" else: "0px"

proc caretClass(item: proc(): VariableViewState): string =
  if item().isExpanded: "caret-expand" else: "caret-collapse"

proc compoundTypeVisible(item: proc(): VariableViewState): bool =
  ## Show the type annotation next to the name when the row is an
  ## expanded compound with a non-empty type name.
  let v = item()
  v.hasChildren and v.isExpanded and v.typeName.len > 0

proc atomTypeVisible(item: proc(): VariableViewState): bool =
  ## Show the type annotation next to the value when the row is NOT an
  ## expanded compound and has a non-empty type name.
  let v = item()
  (not (v.hasChildren and v.isExpanded)) and v.typeName.len > 0

# ---------------------------------------------------------------------------
# Value Origin Tracking (M4 deliverable #3 + #4) — per-row badge helpers.
# The badge component (`ui/origin_badge.nim::renderBadgeDom`) is JS-only
# because it touches `std/dom`. The IsoNim DSL is renderer-agnostic, so
# we emit the same DOM shape directly from the DSL block using the pure
# logic helpers exposed by `origin_chain_types` (`badgeClassFor`,
# `badgeTextForSummary`, `ariaLabelForSummary`, `tokenForSummary`).
# This keeps the Mock + Web renderers in lock-step with what the legacy
# `renderBadgeDom` proc would produce per spec §3.2.3.
# ---------------------------------------------------------------------------

proc badgeRowId*(item: VariableViewState): VariableId =
  ## Composite identity used for ``expandedOrigins`` lookups. The path
  ## doubles as the scope path so shadowed locals stay distinct.
  VariableId(name: item.name, scopePath: item.path)

proc summaryFor(vm: StateVM; item: VariableViewState): Option[OriginSummary] =
  ## Per-row summary lookup. Keyed by ``item.name`` to match the wire
  ## shape ``ct/load-locals`` emits (see ``syncOriginSummaries`` in
  ## ``ui/state.nim``).
  vm.originSummaryFor(item.name)

proc rowHasBadge(vm: StateVM; item: VariableViewState): bool =
  vm.summaryFor(item).isSome

proc badgeClassForRow(vm: StateVM; item: VariableViewState): string =
  ## Compose the CSS class string for the badge button. Returns an
  ## empty string when the row has no summary so the DSL block emits a
  ## hidden button (display: none) and Playwright tests can still
  ## select on the wrapper.
  let summary = vm.summaryFor(item)
  if summary.isNone:
    return ""
  badgeClassFor(summary.get)

proc badgeTextForRow(vm: StateVM; item: VariableViewState): string =
  let summary = vm.summaryFor(item)
  if summary.isNone:
    return ""
  badgeTextForSummary(summary.get, vm.originPreferences.val)

proc badgeAriaForRow(vm: StateVM; item: VariableViewState): string =
  let summary = vm.summaryFor(item)
  if summary.isNone:
    return ""
  ariaLabelForSummary(summary.get, vm.originPreferences.val)

proc badgeTokenForRow(vm: StateVM; item: VariableViewState): string =
  let summary = vm.summaryFor(item)
  if summary.isNone:
    return ""
  tokenForSummary(summary.get)

proc badgeDisplay(vm: StateVM; item: VariableViewState): string =
  ## Used by the DSL's ``display = …`` attribute so the badge button is
  ## hidden when no summary is available without removing it from the
  ## DOM (lets reactive updates pick it back up).
  if vm.rowHasBadge(item): "inline-flex" else: "none"

proc onToggleOriginBadge(vm: StateVM; item: proc(): VariableViewState): proc() =
  ## Per-row click handler. For eager summaries this just toggles the
  ## in-row expansion (spec §3.2.1); for placeholder summaries it ALSO
  ## enqueues the placeholder token for the next batched
  ## ``ct/originSummary`` fill (spec §3.2.3) via the host-provided
  ## bridge. The bridge is installed by ``state.nim`` once the
  ## ``OriginChainVM`` is available — without it the click just toggles
  ## expansion, which is the desired fallback when running headless.
  result = proc() =
    let row = item()
    let id = badgeRowId(row)
    vm.toggleOriginExpansion(id)
    let summary = vm.summaryFor(row)
    if summary.isSome and summary.get.isPlaceholder:
      # Bridge into the OriginChainVM via the host-installed
      # ``onShowOriginProc``; ``state.nim`` wires it so the placeholder
      # click both expands the row AND resolves the placeholder.
      if not vm.onShowOriginProc.isNil and not vm.store.isNil:
        let loc = vm.store.debugger.val.location
        vm.onShowOriginProc(row.name, loc)

# ---------------------------------------------------------------------------
# In-row expanded-chain helpers (spec §3.2.1 collapsed → expanded).
# Renders below the value cell when the row is in ``expandedOrigins``.
# The chain itself is looked up via the host bridge
# ``StateVM.originChainLookup`` so the State Pane does not need to
# import the OriginChainVM.
# ---------------------------------------------------------------------------

proc rowExpanded(vm: StateVM; item: VariableViewState): bool =
  vm.isOriginExpanded(badgeRowId(item))

proc chainForRow(vm: StateVM; item: VariableViewState): Option[OriginChain] =
  if vm.originChainLookup.isNil:
    return none(OriginChain)
  vm.originChainLookup(item.name)

proc hopLineText(hop: OriginHop): string =
  ## Single-line preview the in-row block emits per hop — matches the
  ## semantics the side-panel renders for the same data shape.
  hop.targetExpr & " = " & hop.sourceExpr

# ---------------------------------------------------------------------------
# Click handler factories
# ---------------------------------------------------------------------------

proc onSelectTab(vm: StateVM; tab: StateTab): proc() =
  let t = tab
  result = proc() = vm.selectTab(t)

proc onToggleExpand(vm: StateVM; item: proc(): VariableViewState): proc() =
  ## The expand-button only reacts when the variable has children.
  ## Reading `item()` inside the closure ensures the toggle targets the
  ## current variable at this row's position, even after `indexEach`
  ## reuses the row for a different item.
  result = proc() =
    let v = item()
    if v.hasChildren: vm.toggleExpand(v.path)

# ---------------------------------------------------------------------------
# Variable row component (shared between Mock and Web renderers)
# ---------------------------------------------------------------------------
#
# Implemented as a template so the body — which uses the `ui()` macro
# and therefore must know the renderer's concrete element type at
# compile time — can be expanded once per concrete renderer (Mock,
# Web) without duplicating the markup.

template renderVariableRowImpl(r, vm, item: untyped): untyped =
  ## Build a single variable row using the Karax-compatible markup.
  ##
  ## DOM structure (matches legacy `value-component`):
  ##   div.value-expanded.value-expanded-name.border-value-{depth}
  ##     div.value-expanded-{atom|compound}-parent
  ##       div.value-name-container
  ##         if hasChildren:
  ##           span.value-expand-button > div.{caret-expand|caret-collapse}
  ##         span.value-name : "{name}: "
  ##         if compoundTypeVisible:
  ##           span.value-type : "{typeName}"
  ##       div
  ##         span.value-view
  ##           span.value-expanded-text : "{value}"
  ##           if atomTypeVisible:
  ##             span.value-type : "{typeName}"
  ##           button#value-history
  ##           button.ct-origin-badge[.{terminator-icon}|.ct-origin-badge-placeholder]
  ##             span.ct-origin-badge-icon
  ##             span.ct-origin-badge-text
  ##         (when expandedOrigins contains row id)
  ##         div.ct-origin-inline-chain
  ##           ol > li.ct-origin-inline-chain-hop (one per hop) — text "lhs = rhs"
  ##           li.ct-origin-inline-chain-terminator
  ##
  ## Per spec §3.2.1 + M4 deliverable #3, the badge is appended to the
  ## value cell on every row. The placeholder variant (spec §3.2.1
  ## "[?]" pill) is emitted automatically by ``badgeClassFor`` when
  ## the row's ``OriginSummary.isPlaceholder`` is true. Per
  ## M4 deliverable #4 the in-row expanded chain is rendered below
  ## the value cell when the row is in ``StateVM.expandedOrigins``.
  ##
  ## Every attribute and text expression that reads `item()` becomes
  ## reactive via the DSL macro — the row is rebuilt incrementally as
  ## the underlying VariableViewState signal updates.
  let onToggle = onToggleExpand(vm, item)
  let onBadgeClick = onToggleOriginBadge(vm, item)
  ui(r):
    tdiv(class = rowClass(item),
         `data-variable-name` = item().name,
         padding_left = rowPaddingLeft(item, 16)):
      tdiv(class = atomOrCompoundClass(item)):
        tdiv(class = "value-name-container"):
          if item().hasChildren:
            span(class = "value-expand-button", onclick = onToggle):
              tdiv(class = caretClass(item)):
                discard
          span(class = "value-name"):
            text item().name & ": "
          if compoundTypeVisible(item):
            span(class = "value-type"):
              text item().typeName
        tdiv:
          span(class = "value-view"):
            span(class = "value-expanded-text"):
              text item().value
            if atomTypeVisible(item):
              span(class = "value-type"):
                text item().typeName
            button(id = "value-history",
                   class = "ct-button-image-sm-secondary ct-custom-button-size ct-ml-2",
                   onclick = proc() = vm.toggleHistory(item().path)):
              tdiv(class = "custom-tooltip"):
                text "Toggle history value"
            # per spec §3.2.1 + M4 deliverable #3: inline origin badge.
            # The badge is the same DOM contract that
            # ``ui/origin_badge.nim::renderBadgeDom`` would emit. We
            # build it via the DSL so both Mock + Web renderers stay
            # in lock-step and the headless tests can walk the tree.
            button(class = badgeClassForRow(vm, item()),
                   `aria-label` = badgeAriaForRow(vm, item()),
                   `data-token` = badgeTokenForRow(vm, item()),
                   `data-variable-name` = item().name,
                   display = badgeDisplay(vm, item()),
                   onclick = onBadgeClick):
              span(class = "ct-origin-badge-icon"):
                discard
              span(class = "ct-origin-badge-text"):
                text badgeTextForRow(vm, item())
          # per M4 deliverable #4: in-row expanded chain block. Hidden
          # via ``display: none`` while collapsed so the placeholder
          # stays present in the DOM (matches the empty-overlay /
          # loading-indicator pattern the same view already uses).
          tdiv(class = "ct-origin-inline-chain",
               display = (if rowExpanded(vm, item()): "block" else: "none")):
            let chain = chainForRow(vm, item())
            if chain.isSome:
              for i, hop in chain.get.hops:
                tdiv(class = "ct-origin-inline-chain-hop"):
                  span(class = iconClassForKind(hop.kind)):
                    discard
                  span(class = "ct-origin-inline-chain-hop-text"):
                    text hopLineText(hop)
              tdiv(class = "ct-origin-inline-chain-terminator"):
                span(class = iconClassForTerminator(chain.get.terminator.kind)):
                  discard
                span(class = "ct-origin-inline-chain-terminator-text"):
                  text chain.get.terminator.expression

proc renderVariableRow*(r: MockRenderer; vm: StateVM;
                        item: proc(): VariableViewState): MockNode =
  renderVariableRowImpl(r, vm, item)

when defined(js):
  proc renderVariableRow*(r: WebRenderer; vm: StateVM;
                          item: proc(): VariableViewState): isonim_dom.Element =
    renderVariableRowImpl(r, vm, item)

# ---------------------------------------------------------------------------
# MockRenderer panel
# ---------------------------------------------------------------------------

proc renderStatePanel*(r: MockRenderer; vm: StateVM): MockNode =
  ## Render the full State panel for headless tests.
  ##
  ## Structure:
  ##   div.state-component
  ##     div.state-tabs
  ##       button.tab-locals[.active]   onclick = selectTab(stLocals)   "Locals"
  ##       button.tab-globals[.active]  onclick = selectTab(stGlobals)  "Globals"
  ##       button.tab-watches[.active]  onclick = selectTab(stWatches)  "Watches"
  ##     div.watch-input-container[display: block when activeTab == stWatches]
  ##       input.watch-input[placeholder = "Add watch expression..."]
  ##     div.loading-indicator[display: block when isLoading]
  ##       text "Loading..."
  ##     div.value-components-container
  ##       div.empty-overlay[display: block when no variables]
  ##         text "No local variables..."
  ##       div                                         (row container)
  ##         indexEach VariableViewState -> renderVariableRow(...)
  var rowContainer: MockNode

  let panel = ui(r):
    tdiv(id = "stateComponent-0",
         class = "component-container active-state state-component"):
      tdiv(class = "state-tabs"):
        button(class = tabClass(vm, stLocals),
               onclick = onSelectTab(vm, stLocals)):
          text tabLabel(stLocals)
        button(class = tabClass(vm, stGlobals),
               onclick = onSelectTab(vm, stGlobals)):
          text tabLabel(stGlobals)
        button(class = tabClass(vm, stWatches),
               onclick = onSelectTab(vm, stWatches)):
          text tabLabel(stWatches)
      # Code-state-line: always present in the DOM so Playwright can
      # locate `#code-state-line-0` regardless of trace kind. The
      # inner span text and outer class are reactive on
      # vm.codeStateLine.val (empty -> "no-code" fallback).
      tdiv(id = "code-state-line-0",
           class = codeStateLineClass(vm)):
        span:
          text codeStateLineText(vm)
      tdiv(class = "watch-input-container",
           display = displayIf(vm.activeTab.val == stWatches)):
        input(class = "watch-input",
              placeholder = "Add watch expression...")
      tdiv(class = "loading-indicator",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(class = "value-components-container"):
        tdiv(class = "empty-overlay",
             display = displayFlexIf(getStateViewState(vm).variables.len == 0)):
          text "No local variables are present in the current point of execution."
        tdiv(ref = rowContainer):
          discard

  indexEach[VariableViewState, MockRenderer, MockNode](r, rowContainer,
    proc(): seq[VariableViewState] = getStateViewState(vm).variables,
    proc(item: proc(): VariableViewState, index: int): MockNode =
      renderVariableRow(r, vm, item))

  panel

# ---------------------------------------------------------------------------
# WebRenderer panel
# ---------------------------------------------------------------------------
#
# The web version produces the same Karax-compatible markup the legacy
# component used. Notable differences from the Mock structure:
#
# - Watch input is always visible (matches the Karax behaviour).
# - The watch input lives inside `div#gdb-evaluate > form > input#watch-0`
#   and submitting the form calls `vm.addWatch(...)` then clears the
#   input. The form's `submit` event needs `preventDefault`, which the
#   DSL's `onclick = ...` shape (no event arg) cannot express; it is
#   wired imperatively after capturing the input via `ref = var`.

when defined(js):
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}

  proc wireWatchInputForm(form, input: isonim_dom.Element; vm: StateVM) =
    ## Read the input value on submit, push it to the VM, then clear
    ## the input. Uses raw `dom_api` so the handler can call
    ## `preventDefault` on the event object.
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        ev.preventDefault()
        ev.stopPropagation()
        let expression = inputNode.inputValue()
        if expression.len > 0:
          vm.addWatch($expression)
          inputNode.setInputValue(cstring""))

  proc renderStatePanel*(r: WebRenderer; vm: StateVM): isonim_dom.Element =
    ## Render the State panel using real DOM elements.
    var
      formEl, inputEl: isonim_dom.Element
      rowContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(id = "stateComponent-0",
           class = "component-container active-state state-component isonim-state"):
        # Code-state-line: rendered before the watch input so that the
        # Playwright `#code-state-line-0` lookup finds the populated
        # element (with text "<line> | <source>") matching the legacy
        # `excerpt` proc output. Outer class flips between
        # `code-state-line` and `code-state-line no-code` depending on
        # whether source is available; inner span text mirrors
        # `vm.codeStateLine.val`.
        tdiv(id = "code-state-line-0",
             class = codeStateLineClass(vm)):
          span:
            text codeStateLineText(vm)
        tdiv(id = "gdb-evaluate"):
          form(ref = formEl):
            input(ref = inputEl,
                  `type` = "text",
                  placeholder = "Enter a watch expression",
                  id = "watch-0",
                  class = "ct-input-panel ct-fill-available")
        tdiv(class = "loading-indicator",
             display = displayIf(vm.isLoading.val)):
          text "Loading..."
        tdiv(class = "value-components-container"):
          tdiv(class = "empty-overlay",
               display = displayFlexIf(getStateViewState(vm).variables.len == 0)):
            text "No local variables are present in the current point of execution."
          tdiv(ref = rowContainer):
            discard

    indexEach[VariableViewState, WebRenderer, isonim_dom.Element](r, rowContainer,
      proc(): seq[VariableViewState] = getStateViewState(vm).variables,
      proc(item: proc(): VariableViewState, index: int): isonim_dom.Element =
        renderVariableRow(r, vm, item))

    wireWatchInputForm(formEl, inputEl, vm)

    panel

  proc mountIsoNimStatePanel*(container: isonim_dom.Element;
                              vm: StateVM) =
    ## Mount the IsoNim State panel as a child of `container`. Reactive
    ## effects handle every subsequent update — no manual redraw is
    ## needed. Call once after the `StateVM` exists.
    let r = WebRenderer()
    let panel = renderStatePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
