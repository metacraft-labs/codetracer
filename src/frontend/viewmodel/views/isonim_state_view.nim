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

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/state_vm
import ../views/state_view

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
  ##         showIf hasChildren:
  ##           span.value-expand-button > div.{caret-expand|caret-collapse}
  ##         span.value-name : "{name}: "
  ##         showIf compoundTypeVisible:
  ##           span.value-type : "{typeName}"
  ##       div
  ##         span.value-view
  ##           span.value-expanded-text : "{value}"
  ##           showIf atomTypeVisible:
  ##             span.value-type : "{typeName}"
  ##
  ## Every attribute and text expression that reads `item()` becomes
  ## reactive via the DSL macro — the row is rebuilt incrementally as
  ## the underlying VariableViewState signal updates.
  let onToggle = onToggleExpand(vm, item)
  ui(r):
    tdiv(class = rowClass(item),
         padding_left = rowPaddingLeft(item, 16)):
      tdiv(class = atomOrCompoundClass(item)):
        tdiv(class = "value-name-container"):
          showIf item().hasChildren:
            span(class = "value-expand-button", onclick = onToggle):
              tdiv(class = caretClass(item)):
                discard
          span(class = "value-name"):
            text item().name & ": "
          showIf compoundTypeVisible(item):
            span(class = "value-type"):
              text item().typeName
        tdiv:
          span(class = "value-view"):
            span(class = "value-expanded-text"):
              text item().value
            showIf atomTypeVisible(item):
              span(class = "value-type"):
                text item().typeName

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
    tdiv(class = "state-component"):
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
      tdiv(class = "watch-input-container",
           display = displayIf(vm.activeTab.val == stWatches)):
        input(class = "watch-input",
              placeholder = "Add watch expression...")
      tdiv(class = "loading-indicator",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(class = "value-components-container"):
        tdiv(class = "empty-overlay",
             display = displayIf(getStateViewState(vm).variables.len == 0)):
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

  proc wireWatchInputForm(form, input: isonim_dom.Element; vm: StateVM) =
    ## Read the input value on submit, push it to the VM, then clear
    ## the input. Uses raw `dom_api` so the handler can call
    ## `preventDefault` on the event object.
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        {.emit: "`ev`.preventDefault();".}
        {.emit: "`ev`.stopPropagation();".}
        var expression: cstring
        {.emit: "`expression` = `inputNode`.value || '';".}
        if expression.len > 0:
          vm.addWatch($expression)
          {.emit: "`inputNode`.value = '';".})

  proc renderStatePanel*(r: WebRenderer; vm: StateVM): isonim_dom.Element =
    ## Render the State panel using real DOM elements.
    var
      formEl, inputEl: isonim_dom.Element
      rowContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "state-component isonim-state"):
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
               display = displayIf(getStateViewState(vm).variables.len == 0)):
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
