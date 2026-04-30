## views/isonim_calltrace_view.nim
##
## IsoNim DOM-rendering view for the Calltrace panel.
##
## Renders a live, reactive DOM tree driven by `CalltraceVM` signals.
## When the VM's signals change (visible lines, selected entry,
## scroll indicators, search query), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## Two structures are produced:
##
## - `MockRenderer` — simple test-friendly DOM used by headless unit
##   tests (see `src/tests/gui/tests/views/isonim_views_test.nim`).
##
## - `WebRenderer` — Karax-compatible DOM that preserves the exact
##   class names, IDs, and hierarchy that Playwright page objects
##   (`CallTracePane`, `CallTraceEntry`) expect:
##     `.component-container.calltrace-view.isonim-calltrace`
##     `.calltrace-call-line.calltrace-row[.event-selected]`
##     `.call-child-box#local-call-{index}`
##     `.toggle-call > .{dot|collapse}-call-img`
##     `.call-text#local-call-text-{index}` (click = select / double-click = jump)
##     `.calltrace-search > form > input.calltrace-search-input`
##     `.call-search-results > .search-result`
##
## Both renderers share the `forIn` / `indexEach` reactive list logic
## but render row contents differently to satisfy each contract.
##
## The DSL is used to express structure in single `ui()` blocks per
## logical region; reactive attributes (class, style, text) are wrapped
## automatically by the macro. Only behaviour that the DSL cannot
## express directly — `addEventListener` for handlers that need the
## raw `Event` object, scroll listeners — uses imperative wiring on
## elements captured via `ref = var`.

import std/[json, options]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../backend/backend_service
import ../viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Per-row click handlers
# ---------------------------------------------------------------------------
#
# The DSL attaches handlers via `onclick = expr` which expects `proc()`.
# Each row's handler must read the *current* line value so that updates
# to a row's underlying CallLine (via `indexEach`) are reflected in the
# action the click triggers. We achieve this by closing over the
# `item()` accessor: the handler reads the live signal value when fired,
# rather than capturing a stale snapshot.

type
  RowHandlers = object
    onSelect:    proc()
    onDblClick:  proc()
    onToggle:    proc()

proc rowHandlers(vm: CalltraceVM; item: proc(): CallLine): RowHandlers =
  ## Build the trio of click handlers used by both Mock and Web row
  ## bodies. Each handler reads the latest CallLine via `item()` so it
  ## stays correct under indexEach signal updates.
  let getLine = item
  RowHandlers(
    onSelect: proc() =
      let line = getLine()
      # Single click in the legacy Karax calltrace selects the row AND
      # navigates to the source location (calltraceJump). Without the
      # navigation, Playwright `activate()` selects the row but the
      # editor never opens the target file.
      vm.selectEntry(some(line.index))
      vm.doubleClickEntry(line.index),
    onDblClick: proc() =
      vm.doubleClickEntry(getLine().index),
    onToggle: proc() =
      vm.toggleExpandCallChildren(getLine().index),
  )

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc selectedRowClass(base: string; vm: CalltraceVM; item: proc(): CallLine): string =
  ## Compute the row class with the optional selected modifier.
  ## Wrapping this in a proc keeps the DSL attribute expression short.
  let sel = vm.selectedEntry.val
  let line = item()
  if sel.isSome and sel.get == line.index:
    base & " selected"
  else:
    base

proc paddingForDepth(item: proc(): CallLine; pxPerLevel: int): string =
  let depth = item().depth
  if depth > 0: $(depth * pxPerLevel) & "px" else: "0px"

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

# ---------------------------------------------------------------------------
# MockRenderer renderer — simple structure for headless unit tests
# ---------------------------------------------------------------------------

proc renderCallLineRowMock(r: MockRenderer; vm: CalltraceVM;
                           item: proc(): CallLine): MockNode =
  ## Render a single calltrace row in the Mock-friendly structure.
  ## Only the row class, padding, name text and click handlers are
  ## reactive; all attribute updates are wired via the DSL.
  let h = rowHandlers(vm, item)
  ui(r):
    tdiv(class = selectedRowClass("calltrace-call-line", vm, item),
         padding_left = paddingForDepth(item, 16),
         onclick = h.onSelect,
         ondblclick = h.onDblClick):
      span(class = "call-name"):
        text item().name

proc renderCalltracePanel*(r: MockRenderer; vm: CalltraceVM): MockNode =
  ## Render the complete Calltrace panel for Mock-based tests.
  ##
  ## Structure (matches `isonim_views_test.nim` expectations):
  ##   div.calltrace-component
  ##     div.more-above              (display reactive on hasMoreAbove)
  ##     div.calltrace-loading       (display reactive on isLoading)
  ##     div.calltrace-lines         (populated reactively by indexEach)
  ##     div.more-below              (display reactive on hasMoreBelow)
  ##     div.calltrace-search-row
  ##       input.calltrace-search-input
  var linesContainer: MockNode

  let panel = ui(r):
    tdiv(class = "calltrace-component"):
      tdiv(class = "more-above",
           display = displayIf(vm.hasMoreAbove.val)):
        discard
      tdiv(class = "calltrace-loading",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(class = "calltrace-lines", ref = linesContainer):
        discard
      tdiv(class = "more-below",
           display = displayIf(vm.hasMoreBelow.val)):
        discard
      tdiv(class = "calltrace-search-row"):
        input(class = "calltrace-search-input",
              placeholder = "Search calltrace...")

  indexEach[CallLine, MockRenderer, MockNode](r, linesContainer,
    proc(): seq[CallLine] = vm.visibleLines.val,
    proc(item: proc(): CallLine, index: int): MockNode =
      renderCallLineRowMock(r, vm, item))

  panel

# ---------------------------------------------------------------------------
# WebRenderer renderer — Karax-compatible structure for Playwright tests
# ---------------------------------------------------------------------------
#
# Each row's DOM mirrors the legacy Karax calltrace component:
#
#   div.calltrace-call-line.calltrace-row [.event-selected]
#     span                                           depth offset (min-width)
#     div.calltrace-child.call-depth
#       div.call-child-box#local-call-{index}
#         span.toggle-call                           click = expand/collapse
#           div.{collapse|dot}-call-img
#         div.call-text#local-call-text-{index}      click = select; dbl = jump
#           text "{name} #{index}"
#         div.call-args
#           text "()"
#
# `.call-text` is the click target — a single click selects the row,
# a double click navigates to source.

when defined(js):

  proc rowClassWeb(vm: CalltraceVM; item: proc(): CallLine): string =
    let sel = vm.selectedEntry.val
    let line = item()
    if sel.isSome and sel.get == line.index:
      "calltrace-call-line calltrace-row event-selected"
    else:
      "calltrace-call-line calltrace-row"

  proc toggleIconClass(item: proc(): CallLine): string =
    let line = item()
    if line.hasChildren and line.isExpanded: "collapse-call-img"
    else: "dot-call-img"

  proc renderCallLineRowWeb(r: WebRenderer; vm: CalltraceVM;
                            item: proc(): CallLine): isonim_dom.Element =
    ## Render a single calltrace row using the Karax-compatible markup.
    ## All dynamic content (class, depth offset, expand state, IDs,
    ## name text, click handlers) is expressed in the DSL — the macro
    ## emits per-attr reactive effects so updates are fine-grained.
    ##
    ## NOTE: `indexEach` reuses the same row element across data changes
    ## (e.g. when scrolling shifts which CallLines are visible), so all
    ## per-line content — including IDs derived from `line.index` — must
    ## be reactive. Reading `item()` inside the DSL achieves that
    ## automatically.
    let h = rowHandlers(vm, item)
    ui(r):
      tdiv(class = rowClassWeb(vm, item)):
        span(min_width = $(item().depth * 8) & "px"):
          discard
        tdiv(class = "calltrace-child call-depth"):
          tdiv(id = "local-call-" & $item().index, class = "call-child-box"):
            span(class = "toggle-call", onclick = h.onToggle):
              tdiv(class = toggleIconClass(item)):
                discard
            tdiv(id = "local-call-text-" & $item().index, class = "call-text",
                 onclick = h.onSelect, ondblclick = h.onDblClick):
              text item().name & " #" & $item().index
            tdiv(class = "call-args"):
              text "()"

  proc renderSearchResultsList(r: WebRenderer; container: isonim_dom.Element;
                               vm: CalltraceVM) =
    ## Reactively populate the search-results container. The hide/show
    ## class flip is also reactive. On `mousedown`, the result emits a
    ## calltrace-jump command so the editor navigates to the entry.
    createRenderEffect proc() =
      let results = vm.backendSearchResults.val
      r.clearChildren(container)
      if results.len == 0:
        r.setAttribute(container, "class", "call-search-results hidden")
        return
      r.setAttribute(container, "class", "call-search-results")
      for res in results:
        let capturedRrTicks = res.rrTicks
        let resultEl = ui(r):
          tdiv(class = "search-result",
               onmousedown = proc() =
                 discard vm.store.backend.send(
                   "ct/calltrace-jump",
                   %*{"rrTicks": capturedRrTicks})):
            text "#" & res.key & " - rrTicks(" & $res.rrTicks & "): " & res.name
        r.appendChild(container, resultEl)

  proc wireSearchForm(form, input: isonim_dom.Element; vm: CalltraceVM) =
    ## Wire up search form submission and Enter-key handling on the
    ## input. The DSL's `onclick` handler shape is `proc()`, but here
    ## we need access to the raw `Event` to call `preventDefault`, so
    ## these handlers are attached imperatively.
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        {.emit: "`ev`.preventDefault();".}
        {.emit: "`ev`.stopPropagation();".}
        var query: cstring
        {.emit: "`query` = `inputNode`.value || '';".}
        vm.setSearchQuery($query))
    isonim_dom.addEventListener(inputNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        var keyCode: int
        {.emit: "`keyCode` = `ev`.keyCode || 0;".}
        if keyCode == 13:
          {.emit: "`ev`.preventDefault();".}
          {.emit: "`ev`.stopPropagation();".}
          var query: cstring
          {.emit: "`query` = `inputNode`.value || '';".}
          vm.setSearchQuery($query))

  proc wireScrollContainer(scrollContainer: isonim_dom.Element;
                            vm: CalltraceVM) =
    ## Wire scroll events to the VM. The DSL renderer-API `onscroll`
    ## variant exists, but the handler needs access to `scrollTop` from
    ## the element, so this is attached imperatively.
    const CALL_HEIGHT_PX = 24.0
    isonim_dom.addEventListener(isonim_dom.Node(scrollContainer),
      cstring"scroll",
      proc(ev: isonim_dom.Event) =
        var scrollTop: float
        {.emit: "`scrollTop` = `scrollContainer`.scrollTop || 0;".}
        vm.scroll(int64(scrollTop / CALL_HEIGHT_PX)))

  proc renderCalltracePanel*(r: WebRenderer;
                             vm: CalltraceVM): isonim_dom.Element =
    ## Render the complete Calltrace panel using real DOM elements.
    ##
    ## DOM matches the legacy Karax `calltrace.nim render()` output so
    ## that Playwright page objects (CallTracePane, CallTraceEntry)
    ## continue to find every selector unchanged.
    var
      formEl, inputEl: isonim_dom.Element
      resultsContainer: isonim_dom.Element
      scrollContainer, innerContainer, linesContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "component-container calltrace-view isonim-calltrace",
           `data-label` = "calltrace-data-label-0", tabindex = "2"):
        tdiv:
          tdiv(class = "calltrace-search"):
            form(ref = formEl, class = "calltrace-search-form-0"):
              input(ref = inputEl,
                    class = "calltrace-search-input calltrace-search-input-0 " &
                            "ct-input-panel ct-input-search-image",
                    `type` = "text", placeholder = "Search", tabindex = "0")
          tdiv(ref = resultsContainer, class = "call-search-results hidden"):
            discard
        tdiv(ref = scrollContainer,
             id = "calltraceScroll-0",
             class = "local-calltrace-view"):
          tdiv(ref = innerContainer,
               class = "local-calltrace",
               height = $(vm.store.calltrace.totalCallsCount.val.int * 24) & "px"):
            tdiv(ref = linesContainer, class = "calltrace-lines"):
              discard
        tdiv(class = "calltrace-loading",
             id = "calltrace-toggle-loading-0",
             display = displayIf(vm.isLoading.val)):
          text "Loading..."

    indexEach[CallLine, WebRenderer, isonim_dom.Element](r, linesContainer,
      proc(): seq[CallLine] = vm.visibleLines.val,
      proc(item: proc(): CallLine, index: int): isonim_dom.Element =
        renderCallLineRowWeb(r, vm, item))

    renderSearchResultsList(r, resultsContainer, vm)
    wireSearchForm(formEl, inputEl, vm)
    wireScrollContainer(scrollContainer, vm)

    panel

  proc mountIsoNimCalltrace*(container: isonim_dom.Element;
                             vm: CalltraceVM) =
    ## Mount the IsoNim calltrace panel as a child of `container`.
    ## Reactive effects then handle every subsequent update — no manual
    ## redraw is needed. Call once, after the `CalltraceVM` exists.
    let r = WebRenderer()
    let panel = renderCalltracePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
