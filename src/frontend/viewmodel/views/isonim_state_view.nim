## views/isonim_state_view.nim
##
## IsoNim DOM-rendering view for the State panel.
##
## Renders a live, reactive DOM tree driven by StateVM signals.
## When the StateVM's signals change (active tab, variable list,
## loading state, watch expressions), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax state.nim
## component. It consumes the same StateVM but renders through
## IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderStatePanel(r, stateVM)
##   check panel.textContent.contains("Locals")
##
## Usage (web):
##   let panel = renderStatePanel(webRenderer, stateVM)
##   document.body.appendChild(panel)

import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom  # MockNode type used in generic signatures

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/state_vm
import ../views/state_view

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tabCssClass(tab: StateTab): string =
  ## CSS class name for a tab button, used for test queries.
  case tab
  of stLocals:  "tab-locals"
  of stGlobals: "tab-globals"
  of stWatches: "tab-watches"

proc tabLabel(tab: StateTab): string =
  ## Display label for a tab button.
  case tab
  of stLocals:  "Locals"
  of stGlobals: "Globals"
  of stWatches: "Watches"

# ---------------------------------------------------------------------------
# Variable row renderer
# ---------------------------------------------------------------------------

proc renderVariableRow*[R, N](r: R; parent: N;
                               v: proc(): VariableViewState) =
  ## Render a single variable row into `parent`.
  ## The row displays: indentation, expand toggle, name, value, and type.
  ## Wrapped in a createRenderEffect so the row updates when `v` changes.
  let row = r.createElement("div")
  r.setAttribute(row, "class", "variable-row")
  r.appendChild(parent, row)

  createRenderEffect proc() =
    let vs = v()
    # Clear previous children by rebuilding (simple approach).
    # For a production version we would use fine-grained effects per
    # text node, but this is correct and sufficient for the first cut.
    r.clearChildren(row)

    # Indentation via padding-left style
    if vs.depth > 0:
      r.setStyle(row, "padding-left", $(vs.depth * 16) & "px")
    else:
      r.setStyle(row, "padding-left", "0px")

    # Expand/collapse indicator
    if vs.hasChildren:
      let toggle = r.createElement("span")
      r.setAttribute(toggle, "class", "expand-toggle")
      let arrow = if vs.isExpanded: "▼ " else: "▶ "
      r.setTextContent(toggle, arrow)
      r.appendChild(row, toggle)

    # Name
    let nameSpan = r.createElement("span")
    r.setAttribute(nameSpan, "class", "var-name")
    r.setTextContent(nameSpan, vs.name)
    r.appendChild(row, nameSpan)

    # Separator
    let sep = r.createTextNode(" = ")
    r.appendChild(row, sep)

    # Value
    let valueSpan = r.createElement("span")
    r.setAttribute(valueSpan, "class", "var-value")
    r.setTextContent(valueSpan, vs.value)
    r.appendChild(row, valueSpan)

    # Type annotation
    if vs.typeName.len > 0:
      let typeSpan = r.createElement("span")
      r.setAttribute(typeSpan, "class", "var-type")
      r.setTextContent(typeSpan, " : " & vs.typeName)
      r.appendChild(row, typeSpan)

# ---------------------------------------------------------------------------
# Tab bar renderer
# ---------------------------------------------------------------------------

proc makeTabClickHandler(vm: StateVM; tab: StateTab): proc() =
  ## Factory to create a click handler with its own closure environment,
  ## avoiding the Nim closure-in-loop capture issue.
  let t = tab
  result = proc() =
    vm.selectTab(t)

proc makeTabActiveEffect[R, N](r: R; btn: N; vm: StateVM; tab: StateTab): proc() =
  ## Factory to create a reactive effect that updates the active CSS class.
  let t = tab
  result = proc() =
    let isActive = vm.activeTab.val == t
    let cls = tabCssClass(t) & (if isActive: " active" else: "")
    r.setAttribute(btn, "class", cls)

proc renderTabBar*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render the three tab buttons (Locals, Globals, Watches) into `parent`.
  ## The active tab gets the "active" CSS class reactively.
  let tabBar = r.createElement("div")
  r.setAttribute(tabBar, "class", "state-tabs")
  r.appendChild(parent, tabBar)

  for tab in [stLocals, stGlobals, stWatches]:
    let btn = r.createElement("button")
    r.setAttribute(btn, "class", tabCssClass(tab))
    r.setTextContent(btn, tabLabel(tab))

    r.addEventListener(btn, "click", makeTabClickHandler(vm, tab))

    # Reactive "active" class update
    createRenderEffect makeTabActiveEffect(r, btn, vm, tab)

    r.appendChild(tabBar, btn)

# ---------------------------------------------------------------------------
# Watch input renderer
# ---------------------------------------------------------------------------

proc renderWatchInput*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render the watch-expression input row.
  ## Only visible when the Watches tab is active (controlled by
  ## the caller via showIf or manual conditional rendering).
  let inputRow = r.createElement("div")
  r.setAttribute(inputRow, "class", "watch-input-row")
  r.appendChild(parent, inputRow)

  let input = r.createElement("input")
  r.setAttribute(input, "class", "watch-input")
  r.setAttribute(input, "placeholder", "Add watch expression...")
  r.appendChild(inputRow, input)

  let addBtn = r.createElement("button")
  r.setAttribute(addBtn, "class", "watch-add-btn")
  r.setTextContent(addBtn, "+")
  r.appendChild(inputRow, addBtn)

  # Note: In a real browser, we would read `input.value` on click.
  # With MockRenderer, the input value isn't tracked — the actual
  # addWatch call will come from the ViewModel action layer or a
  # higher-level integration. The button is wired up as a placeholder.
  r.addEventListener(addBtn, "click", proc() =
    # In production, read the input element's value here.
    # For now this is a no-op; tests exercise vm.addWatch directly.
    discard
  )

# ---------------------------------------------------------------------------
# Loading indicator
# ---------------------------------------------------------------------------

proc renderLoadingIndicator*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render a loading spinner/text that appears when isLoading is true.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "loading-indicator")
  r.setTextContent(indicator, "Loading...")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let loading = vm.isLoading.val
    r.setStyle(indicator, "display", if loading: "block" else: "none")

# ---------------------------------------------------------------------------
# Variable list renderer
# ---------------------------------------------------------------------------

proc renderVariableList*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render the variable list container.
  ## Uses indexEach for positional rendering: when the flattened variable
  ## list changes, rows are updated in place or added/removed.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "value-components-container")
  r.appendChild(parent, container)

  indexEach[VariableViewState, R, N](r, container,
    proc(): seq[VariableViewState] =
      getStateViewState(vm).variables,
    proc(item: proc(): VariableViewState, index: int): N =
      let row = r.createElement("div")
      r.setAttribute(row, "class", "variable-row")

      createRenderEffect proc() =
        let vs = item()

        # Clear and rebuild row content on each update.
        # A more optimised version would use per-field effects.
        r.clearChildren(row)

        # Indentation
        if vs.depth > 0:
          r.setStyle(row, "padding-left", $(vs.depth * 16) & "px")
        else:
          r.setStyle(row, "padding-left", "0px")

        # Expand/collapse indicator
        if vs.hasChildren:
          let toggle = r.createElement("span")
          r.setAttribute(toggle, "class", "expand-toggle")
          r.setTextContent(toggle, if vs.isExpanded: "▼ " else: "▶ ")
          r.appendChild(row, toggle)

        # Name
        let nameSpan = r.createElement("span")
        r.setAttribute(nameSpan, "class", "var-name")
        r.setTextContent(nameSpan, vs.name)
        r.appendChild(row, nameSpan)

        # Separator
        let sep = r.createTextNode(" = ")
        r.appendChild(row, sep)

        # Value
        let valueSpan = r.createElement("span")
        r.setAttribute(valueSpan, "class", "var-value")
        r.setTextContent(valueSpan, vs.value)
        r.appendChild(row, valueSpan)

        # Type
        if vs.typeName.len > 0:
          let typeSpan = r.createElement("span")
          r.setAttribute(typeSpan, "class", "var-type")
          r.setTextContent(typeSpan, " : " & vs.typeName)
          r.appendChild(row, typeSpan)

      row
  )

# ---------------------------------------------------------------------------
# Main panel renderer
# ---------------------------------------------------------------------------

proc renderStatePanel*(r: MockRenderer; vm: StateVM): MockNode =
  ## Render the complete State panel.
  ##
  ## Structure:
  ##   div.state-component
  ##     div.state-tabs
  ##       button.tab-locals
  ##       button.tab-globals
  ##       button.tab-watches
  ##     div.loading-indicator      (hidden when not loading)
  ##     div.watch-input-row        (hidden when not on Watches tab)
  ##     div.value-components-container
  ##       div.variable-row ...
  ##
  ## All content is reactive: changing StateVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "state-component")

  # Tab bar
  renderTabBar(r, panel, vm)

  # Loading indicator
  renderLoadingIndicator(r, panel, vm)

  # Watch input (visibility controlled reactively)
  let watchContainer = r.createElement("div")
  r.setAttribute(watchContainer, "class", "watch-input-container")
  r.appendChild(panel, watchContainer)
  renderWatchInput(r, watchContainer, vm)

  createRenderEffect proc() =
    let visible = vm.activeTab.val == stWatches
    r.setStyle(watchContainer, "display", if visible: "block" else: "none")

  # Variable list
  renderVariableList(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderStatePanel*(r: WebRenderer;
                          vm: StateVM): isonim_dom.Element =
    ## Render the complete State panel using real DOM elements.
    ##
    ## Returns an `isonim_dom.Element` that can be appended to any live
    ## DOM container. All content is reactive: changing StateVM signals
    ## automatically updates the DOM tree via `createRenderEffect`.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "state-component isonim-state")

    # Tab bar
    renderTabBar(r, panel, vm)

    # Loading indicator
    renderLoadingIndicator(r, panel, vm)

    # Watch input (visibility controlled reactively)
    let watchContainer = r.createElement("div")
    r.setAttribute(watchContainer, "class", "watch-input-container")
    r.appendChild(panel, watchContainer)
    renderWatchInput(r, watchContainer, vm)

    createRenderEffect proc() =
      let visible = vm.activeTab.val == stWatches
      r.setStyle(watchContainer, "display", if visible: "block" else: "none")

    # Variable list
    renderVariableList(r, panel, vm)

    panel

  proc mountIsoNimStatePanel*(container: isonim_dom.Element;
                               vm: StateVM) =
    ## Mount the IsoNim state panel view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    ##
    ## Call this once after the StateVM has been created.
    ## The Karax state component renders alongside this view during
    ## the transition period.
    let r = WebRenderer()
    let panel = renderStatePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
