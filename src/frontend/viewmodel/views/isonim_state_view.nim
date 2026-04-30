## views/isonim_state_view.nim
##
## IsoNim DOM-rendering view for the State panel — primary renderer.
##
## Renders a live, reactive DOM tree driven by StateVM signals.
## When the StateVM's signals change (active tab, variable list,
## loading state, watch expressions), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## The DOM structure matches the legacy Karax value-component markup
## so that Playwright tests (which query `.value-expanded`,
## `.value-name`, `.value-expanded-text`, etc.) work without changes.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
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
import isonim/dsl/ui
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
# Variable row renderer — Karax-compatible DOM structure
# ---------------------------------------------------------------------------
#
# Each variable row matches the Karax value-component DOM:
#
#   div.value-expanded.value-expanded-name.border-value-{depth}
#     div.value-expanded-atom-parent          (or -compound-parent)
#       div.value-name-container
#         span.value-expand-button            (if expandable)
#           div.caret-expand or .caret-collapse
#         span.value-name                     "varname: "
#         span.value-type                     (if expanded compound)
#       div                                   (value wrapper)
#         span.value-view
#           span.value-expanded-text          "value text"
#
# Playwright tests query:
#   .value-expanded          — locates each variable row
#   .value-name              — reads the variable name
#   .value-expanded-text     — reads the value text
#   .value-type              — reads the type annotation
#   .value-name-container    — parent of name/expand button
#   .value-expand-button     — click target for expand/collapse
#   .caret-expand/.caret-collapse — presence check for expandability
#   .value-expanded-atom-parent   — atom variable parent

proc makeExpandClickHandler(vm: StateVM; path: string): proc() =
  ## Factory for expand/collapse click handlers. Creates a separate
  ## closure per variable path to avoid the Nim closure-in-loop
  ## capture issue.
  let p = path
  result = proc() =
    vm.toggleExpand(p)

proc renderVariableRow*[R, N](r: R; parent: N;
                               v: proc(): VariableViewState;
                               vm: StateVM) =
  ## Render a single variable row into `parent` using the Karax-compatible
  ## DOM structure. Wrapped in a createRenderEffect so the row updates
  ## reactively when `v` changes.
  let row = r.createElement("div")
  r.appendChild(parent, row)

  createRenderEffect proc() =
    let vs = v()
    r.clearChildren(row)

    # Outer row: div.value-expanded.value-expanded-name.border-value-{depth}
    r.setAttribute(row, "class",
      "value-expanded value-expanded-name border-value-" & $vs.depth)

    # Atom vs compound parent wrapper
    let atomClass = if vs.hasChildren and vs.isExpanded:
      "value-expanded-compound-parent"
    else:
      "value-expanded-atom-parent"
    let atomDiv = r.createElement("div")
    r.setAttribute(atomDiv, "class", atomClass)
    r.appendChild(row, atomDiv)

    # Name container
    let nameContainer = r.createElement("div")
    r.setAttribute(nameContainer, "class", "value-name-container")
    r.appendChild(atomDiv, nameContainer)

    # Expand/collapse button (only for expandable variables)
    if vs.hasChildren:
      let expandBtn = r.createElement("span")
      r.setAttribute(expandBtn, "class", "value-expand-button")
      r.appendChild(nameContainer, expandBtn)

      let caretDiv = r.createElement("div")
      if vs.isExpanded:
        r.setAttribute(caretDiv, "class", "caret-expand")
      else:
        r.setAttribute(caretDiv, "class", "caret-collapse")
      r.appendChild(expandBtn, caretDiv)

      # Wire up expand/collapse click
      r.addEventListener(expandBtn, "click",
        makeExpandClickHandler(vm, vs.path))

    # Variable name: span.value-name with trailing ": "
    let nameSpan = r.createElement("span")
    r.setAttribute(nameSpan, "class", "value-name")
    r.setTextContent(nameSpan, vs.name & ": ")
    r.appendChild(nameContainer, nameSpan)

    # Type annotation (shown next to name when expanded compound)
    if vs.hasChildren and vs.isExpanded and vs.typeName.len > 0:
      let typeSpan = r.createElement("span")
      r.setAttribute(typeSpan, "class", "value-type")
      r.setTextContent(typeSpan, vs.typeName)
      r.appendChild(nameContainer, typeSpan)

    # Value wrapper div
    let valueWrapper = r.createElement("div")
    r.appendChild(atomDiv, valueWrapper)

    let valueView = r.createElement("span")
    r.setAttribute(valueView, "class", "value-view")
    r.appendChild(valueWrapper, valueView)

    # Value text: span.value-expanded-text (or div depending on type)
    let valueText = r.createElement("span")
    r.setAttribute(valueText, "class", "value-expanded-text")
    r.setTextContent(valueText, vs.value)
    r.appendChild(valueView, valueText)

    # Type annotation for atoms (shown after value)
    if not (vs.hasChildren and vs.isExpanded) and vs.typeName.len > 0:
      let typeSpan = r.createElement("span")
      r.setAttribute(typeSpan, "class", "value-type")
      r.setTextContent(typeSpan, vs.typeName)
      r.appendChild(valueView, typeSpan)

    # Indentation via padding-left style for nested variables
    if vs.depth > 0:
      r.setStyle(row, "padding-left", $(vs.depth * 16) & "px")
    else:
      r.setStyle(row, "padding-left", "0px")

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
  let tabBar = ui(r):
    tdiv(class = "state-tabs"):
      discard
  r.appendChild(parent, tabBar)

  for tab in [stLocals, stGlobals, stWatches]:
    let btn = ui(r):
      button(class = tabCssClass(tab), onclick = makeTabClickHandler(vm, tab)):
        text tabLabel(tab)
    r.appendChild(tabBar, btn)

    # Reactive "active" class update — uses dynamic class toggling
    # which must stay imperative.
    createRenderEffect makeTabActiveEffect(r, btn, vm, tab)

# ---------------------------------------------------------------------------
# Watch input renderer — Karax-compatible DOM structure
# ---------------------------------------------------------------------------
#
# Matches the legacy Karax watchView() output:
#   div#gdb-evaluate
#     form
#       input#watch-0.ct-input-panel.ct-fill-available
#
# Playwright tests query `#watch` or `#watch-0` for the text box.

proc renderWatchInput*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render the watch-expression input form using the Karax-compatible
  ## DOM structure. The form is always present (same as legacy Karax).
  ##
  ## DOM structure produced:
  ##   div#gdb-evaluate
  ##     form
  ##       input#watch-0.ct-input-panel.ct-fill-available
  let gdbEvaluate = ui(r):
    tdiv(id = "gdb-evaluate"):
      form:
        input(`type` = "text", placeholder = "Enter a watch expression",
              id = "watch-0", class = "ct-input-panel ct-fill-available")
  r.appendChild(parent, gdbEvaluate)

  # Note: For MockRenderer, the submit/keydown wiring is a no-op.
  # Real browser wiring is done in mountIsoNimStatePanel via direct
  # DOM API calls on the created elements.

# ---------------------------------------------------------------------------
# Loading indicator
# ---------------------------------------------------------------------------

proc renderLoadingIndicator*[R, N](r: R; parent: N; vm: StateVM) =
  ## Render a loading spinner/text that appears when isLoading is true.
  let indicator = ui(r):
    tdiv(class = "loading-indicator"):
      text "Loading..."
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
  let container = ui(r):
    tdiv(class = "value-components-container"):
      discard
  r.appendChild(parent, container)

  # Empty overlay shown when there are no variables
  let emptyOverlay = ui(r):
    tdiv(class = "empty-overlay"):
      text "No local variables are present in the current point of execution."
  r.appendChild(container, emptyOverlay)

  createRenderEffect proc() =
    let vars = getStateViewState(vm).variables
    r.setStyle(emptyOverlay, "display",
      if vars.len == 0: "block" else: "none")

  # Variable rows rendered via indexEach for reactive list updates
  let rowContainer = r.createElement("div")
  r.appendChild(container, rowContainer)

  indexEach[VariableViewState, R, N](r, rowContainer,
    proc(): seq[VariableViewState] =
      getStateViewState(vm).variables,
    proc(item: proc(): VariableViewState, index: int): N =
      let row = r.createElement("div")

      createRenderEffect proc() =
        let vs = item()
        r.clearChildren(row)

        # Outer row: div.value-expanded.value-expanded-name.border-value-{depth}
        r.setAttribute(row, "class",
          "value-expanded value-expanded-name border-value-" & $vs.depth)

        # Atom vs compound parent wrapper
        let atomClass = if vs.hasChildren and vs.isExpanded:
          "value-expanded-compound-parent"
        else:
          "value-expanded-atom-parent"
        let atomDiv = r.createElement("div")
        r.setAttribute(atomDiv, "class", atomClass)
        r.appendChild(row, atomDiv)

        # Name container
        let nameContainer = r.createElement("div")
        r.setAttribute(nameContainer, "class", "value-name-container")
        r.appendChild(atomDiv, nameContainer)

        # Expand/collapse button (only for expandable variables)
        if vs.hasChildren:
          let expandBtn = r.createElement("span")
          r.setAttribute(expandBtn, "class", "value-expand-button")
          r.appendChild(nameContainer, expandBtn)

          let caretDiv = r.createElement("div")
          if vs.isExpanded:
            r.setAttribute(caretDiv, "class", "caret-expand")
          else:
            r.setAttribute(caretDiv, "class", "caret-collapse")
          r.appendChild(expandBtn, caretDiv)

          # Wire up expand/collapse click
          r.addEventListener(expandBtn, "click",
            makeExpandClickHandler(vm, vs.name))

        # Variable name: span.value-name with trailing ": "
        let nameSpan = r.createElement("span")
        r.setAttribute(nameSpan, "class", "value-name")
        r.setTextContent(nameSpan, vs.name & ": ")
        r.appendChild(nameContainer, nameSpan)

        # Type annotation (shown next to name when expanded compound)
        if vs.hasChildren and vs.isExpanded and vs.typeName.len > 0:
          let typeSpan = r.createElement("span")
          r.setAttribute(typeSpan, "class", "value-type")
          r.setTextContent(typeSpan, vs.typeName)
          r.appendChild(nameContainer, typeSpan)

        # Value wrapper div
        let valueWrapper = r.createElement("div")
        r.appendChild(atomDiv, valueWrapper)

        let valueView = r.createElement("span")
        r.setAttribute(valueView, "class", "value-view")
        r.appendChild(valueWrapper, valueView)

        # Value text
        let valueText = r.createElement("span")
        r.setAttribute(valueText, "class", "value-expanded-text")
        r.setTextContent(valueText, vs.value)
        r.appendChild(valueView, valueText)

        # Type annotation for atoms (shown after value)
        if not (vs.hasChildren and vs.isExpanded) and vs.typeName.len > 0:
          let typeSpan = r.createElement("span")
          r.setAttribute(typeSpan, "class", "value-type")
          r.setTextContent(typeSpan, vs.typeName)
          r.appendChild(valueView, typeSpan)

        # Indentation for nested variables
        if vs.depth > 0:
          r.setStyle(row, "padding-left", $(vs.depth * 16) & "px")
        else:
          r.setStyle(row, "padding-left", "0px")

      row
  )

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderStatePanel*(r: MockRenderer; vm: StateVM): MockNode =
  ## Render the complete State panel using Karax-compatible DOM structure.
  ##
  ## Structure:
  ##   div.state-component
  ##     div.state-tabs
  ##       button.tab-locals  (.active when selected)
  ##       button.tab-globals
  ##       button.tab-watches
  ##     div.watch-input-container        (visible only on Watches tab)
  ##       input.watch-input
  ##     div.loading-indicator            (visible only when loading)
  ##     div.value-components-container
  ##       div.empty-overlay              (hidden when variables present)
  ##       div                            (row container — indexEach)
  ##         div.value-expanded.value-expanded-name.border-value-0
  ##           ...
  ##
  ## All content is reactive: changing StateVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = ui(r):
    tdiv(class = "state-component"):
      discard

  # Tab bar (Locals / Globals / Watches)
  renderTabBar(r, panel, vm)

  # Watch input container — visible only when the Watches tab is active.
  block buildWatchInputContainer:
    let watchContainer = ui(r):
      tdiv(class = "watch-input-container"):
        input(class = "watch-input", placeholder = "Add watch expression...")
    r.appendChild(panel, watchContainer)

    createRenderEffect proc() =
      let visible = vm.activeTab.val == stWatches
      r.setStyle(watchContainer, "display", if visible: "block" else: "none")

  # Loading indicator
  renderLoadingIndicator(r, panel, vm)

  # Variable list
  renderVariableList(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderStatePanelWeb(r: WebRenderer;
                            vm: StateVM): isonim_dom.Element =
    ## Render the complete State panel using real DOM elements with
    ## Karax-compatible DOM structure for Playwright test compatibility.
    ##
    ## Returns an `isonim_dom.Element` that can be appended to any live
    ## DOM container. All content is reactive: changing StateVM signals
    ## automatically updates the DOM tree via `createRenderEffect`.
    let panel = ui(r):
      tdiv(class = "state-component isonim-state"):
        discard

    # Watch input (always visible, same as legacy Karax).
    # The form structure is built with the DSL but the submit handler
    # needs access to the input element reference, so we create the
    # input separately and wire it up imperatively.
    block buildWatchInput:
      let gdbEvaluate = ui(r):
        tdiv(id = "gdb-evaluate"):
          discard
      r.appendChild(panel, gdbEvaluate)

      let form = r.createElement("form")
      r.appendChild(gdbEvaluate, form)

      let input = ui(r):
        input(`type` = "text", placeholder = "Enter a watch expression",
              id = "watch-0", class = "ct-input-panel ct-fill-available")
      r.appendChild(form, input)

      # Wire up form submission. Prevent default and read the input
      # value directly from the element reference we already hold.
      let inputNode = isonim_dom.Node(input)
      isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
        proc(ev: isonim_dom.Event) =
          {.emit: "`ev`.preventDefault();".}
          {.emit: "`ev`.stopPropagation();".}
          var expression: cstring
          {.emit: "`expression` = `inputNode`.value || '';".}
          if expression.len > 0:
            vm.addWatch($expression)
            {.emit: "`inputNode`.value = '';".}
      )

    # Loading indicator
    renderLoadingIndicator(r, panel, vm)

    # Variable list
    renderVariableList(r, panel, vm)

    panel

  proc renderStatePanel*(r: WebRenderer;
                          vm: StateVM): isonim_dom.Element =
    ## Public overload — delegates to the internal web-specific builder.
    renderStatePanelWeb(r, vm)

  proc mountIsoNimStatePanel*(container: isonim_dom.Element;
                               vm: StateVM) =
    ## Mount the IsoNim state panel view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    ##
    ## This is the primary renderer for the State panel. The Karax
    ## state.nim `render()` method returns a minimal stub when this
    ## view is mounted.
    let r = WebRenderer()
    let panel = renderStatePanelWeb(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
