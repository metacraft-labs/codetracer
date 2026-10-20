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

import std/[json, options, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import ../store/replay_data_store
  from ./context_menu_bridge import showContextMenu
  from ../../types import ContextMenuItem, RAW_TYPE, TypeKind, Value,
    ValueWithExpression
  when defined(ctRenderer):
    from ../../../common/ct_event import InternalAddToScratchpad
    from ../../communication import emit
    from ../../types import data
  import kdom except Location
  import std/jsffi
  import ./list_scrubber_dom

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
      # Select the row's CALL, so the mark stays on it when a collapse or
      # a filter change moves it to another row (#811).
      if line.callKey.len > 0:
        vm.selectCall(line.callKey)
      else:
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

proc callDisplayName*(line: CallLine): string =
  ## Rendering stays backward-compatible: existing traces use ``name``.
  if line.displayName.len > 0: line.displayName else: line.name

proc toggleIconClass*(item: proc(): CallLine): string =
  let line = item()
  if line.hasChildren:
    if line.isExpanded: "collapse-call-img"
    else: "expand-call-img"
  else: "dot-call-img"

# ---------------------------------------------------------------------------
# MockRenderer renderer — simple structure for headless unit tests
# ---------------------------------------------------------------------------

proc argsForRow(vm: CalltraceVM; item: proc(): CallLine): seq[CallArg] =
  ## Look up the per-call argument list for the row's CallLine. Reads
  ## ``vm.store.calltrace.args.val`` reactively so views that wrap this
  ## inside a ``createRenderEffect`` re-run whenever the args map
  ## changes (a new calltrace section was loaded), or whenever the row's
  ## underlying CallLine swaps to a different ``callKey`` (indexEach
  ## reuses row elements as the visible-lines slice shifts).
  let line = item()
  let argsTable = vm.store.calltrace.args.val
  if line.callKey.len == 0:
    return @[]
  if line.callKey notin argsTable:
    return @[]
  for arg in argsTable[line.callKey]:
    if arg.name != "__return":
      result.add arg

proc returnValueForRow(vm: CalltraceVM; item: proc(): CallLine): string =
  ## Storybook fixtures can carry a synthetic ``__return`` arg so the
  ## IsoNim visual surface mirrors the Karax calltrace's ``=> value`` spans.
  ## Real calltrace rows that do not provide this sentinel render unchanged.
  let line = item()
  let argsTable = vm.store.calltrace.args.val
  if line.callKey.len == 0 or line.callKey notin argsTable:
    return ""
  for arg in argsTable[line.callKey]:
    if arg.name == "__return":
      return arg.text
  ""

proc returnArrowForRow(vm: CalltraceVM; item: proc(): CallLine): string =
  if returnValueForRow(vm, item).len > 0: " => " else: ""

proc renderCallLineRowMock(r: MockRenderer; vm: CalltraceVM;
                           item: proc(): CallLine): MockNode =
  ## Render a single calltrace row in the Mock-friendly structure.
  ## Only the row class, padding, name text and click handlers are
  ## reactive; all attribute updates are wired via the DSL.
  let h = rowHandlers(vm, item)
  var argsContainer: MockNode
  let row = ui(r):
    tdiv(class = selectedRowClass("calltrace-call-line", vm, item),
         `data-function` = item().name,
         `data-source-generation` = $item().location.sourceGeneration,
         `data-source-digest` = item().location.sourceDigest,
         `data-code-generation` = $item().codeGeneration,
         `data-rr-ticks` = $item().rrTicks,
         padding_left = paddingForDepth(item, 16),
         onclick = h.onSelect,
         ondblclick = h.onDblClick):
      tdiv(class = toggleIconClass(item), onclick = h.onToggle):
        discard
      span(class = "call-name"):
        text callDisplayName(item())
      tdiv(class = "call-args", ref = argsContainer):
        discard

  # Reactively populate the args container with one ``.call-arg`` element
  # per call argument. Mirrors the historical Karax call-argument markup
  # so headless tests can assert the same DOM contract Playwright relies on.
  # We rebuild children from
  # scratch on each fire — this stays cheap because typical call-arg
  # counts are small (<10) and the effect only fires when the row's args
  # actually change.
  createRenderEffect proc() =
    let line = item()
    let callArgs = argsForRow(vm, item)
    r.clearChildren(argsContainer)
    # Iterate by index and copy the arg value into a local ``let``: the
    # DSL macro emits closures for each dynamic attribute, which can't
    # capture a ``lent T`` (Nim's default iteration view for ref-free
    # value types).  A plain ``let`` decouples the closures from the seq.
    for idx in 0 ..< callArgs.len:
      let argName = callArgs[idx].name
      let argText = callArgs[idx].text
      let argEl = ui(r):
        tdiv(class = "call-arg",
             id = "call-arg-" & line.callKey & "-" & argName):
          tdiv(class = "call-arg-header"):
            tdiv(class = "call-arg-name"):
              text argName & "="
            tdiv(class = "call-arg-text"):
              text argText
      r.appendChild(argsContainer, argEl)

  row

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
# Guide-line geometry
# ---------------------------------------------------------------------------
#
# The guides are an SVG layer laid over the rows (`renderTraceSvg` below). A
# guide connects two rows only if it is drawn where the browser put them, and
# the browser lays the rows out from em-based CSS: their advance follows the
# root font size (zoom) and is not a whole number of pixels (about 25.28 px
# against a 25 px row box at 16 px on the desktop). So nothing here is a pixel
# constant except the depth indent, which the row renderer itself writes in
# pixels. The rest is measured from the rendered rows and passed in.

const CallDepthIndentPx* = 8.0
  ## Width of one level of nesting: `renderCallLineRowWeb` writes a spacer of
  ## `depth * CallDepthIndentPx` px before each row's toggle, so a toggle's
  ## centre moves right by exactly this much per level.

type
  CallGuideAnchor* = object
    ## Where a row's toggle sits, measured from a rendered row. Both values
    ## are in CSS px and scale with the root font size.
    originX*: float
      ## Toggle centre x of a depth-0 row, relative to `.calltrace-lines`.
    centerY*: float
      ## Toggle centre y relative to its row's top edge.

  CallGuideSegment* = tuple[x1, y1, x2, y2: float]

func defaultCallGuideAnchor*(pitch: float): CallGuideAnchor =
  ## Used until a row has been measured: the toggle of the default stylesheet
  ## at the 16 px root font size, vertically centred in the row.
  CallGuideAnchor(originX: 13.0, centerY: pitch / 2.0)

func callGuideSegments*(depths: openArray[int]; pitch: float;
                        anchor: CallGuideAnchor): seq[CallGuideSegment] =
  ## The guide segments for rows `0 ..< depths.len`, row `i` at depth
  ## `depths[i]`, the rows `pitch` px apart (the measured row ADVANCE, top to
  ## top — not the row box).
  ##
  ## Row `i` gets a vertical segment over its own extent `[i*pitch,
  ## (i+1)*pitch]` at its toggle's x, cut to the toggle centre for the first
  ## and the last row, and a horizontal connector on its bottom edge (the next
  ## row's top) from its toggle's x to the next row's. Fewer than two rows draw
  ## nothing: there is nothing to connect.
  if depths.len < 2 or pitch <= 0.0:
    return
  proc xOf(depth: int): float =
    anchor.originX + float(max(depth, 0)) * CallDepthIndentPx
  for i in 0 ..< depths.len:
    let x = xOf(depths[i])
    let topY = float(i) * pitch
    let bottomY = topY + pitch
    let startY = if i == 0: topY + anchor.centerY else: topY
    let endY = if i == depths.high: topY + anchor.centerY else: bottomY
    if endY > startY:
      result.add (x, startY, x, endY)
    if i < depths.high:
      result.add (x, bottomY, xOf(depths[i + 1]), bottomY)

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
  proc createSvgElement(tag: cstring): isonim_dom.Element {.importjs: "document.createElementNS('http://www.w3.org/2000/svg', #)".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc eventKeyCode(ev: isonim_dom.Event): int {.importjs: "(#.keyCode || 0)".}
  proc scrollTop(node: isonim_dom.Element): float {.importjs: "(#.scrollTop || 0)".}

  # DOM helpers for measuring the actual rendered row height.
  # `querySelector` returns null when no match is found; the importjs guard
  # (`|| null`) prevents undefined leaking into Nim's nil-check path.
  proc calltraceQuerySelector(el: isonim_dom.Element; sel: cstring): isonim_dom.Element
    {.importjs: "(#.querySelector(#) || null)".}
  proc calltraceElementHeight(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().height".}

  proc setCalltraceTabBusy(busy: bool) =
    ## Add or remove `lm_tab_busy` on the CALLTRACE tab.
    ##
    ## The tab is found by `data-ct-panel-content`, stamped by
    ## `ui/layout.nim`'s `markPanelTab`, NOT by its title text — see the note
    ## there for why the title is not available as a handle.
    ##
    ## `querySelectorAll` rather than `querySelector`: a session can hold more
    ## than one calltrace panel (multi-replay, and a panel pinned to an
    ## auto-hide edge keeps its tab), and leaving the others latched on would
    ## show a permanent busy state on a panel that finished loading.
    ##
    ## Silent when no tab matches. That is the ordinary state during start-up
    ## — the panel mounts and this effect first runs before GoldenLayout has
    ## emitted `tab` — and the effect re-runs on the next state change.
    {.emit: """
      var _tabs = document.querySelectorAll("[data-ct-panel-content='Calltrace']");
      for (var _i = 0; _i < _tabs.length; _i++) {
        if (`busy`) {
          _tabs[_i].classList.add('lm_tab_busy');
        } else {
          _tabs[_i].classList.remove('lm_tab_busy');
        }
      }
    """.}

  proc calltraceRowElements(el: isonim_dom.Element): seq[isonim_dom.Element]
    {.importjs: "Array.from(#.querySelectorAll('.calltrace-call-line'))".}
  proc calltraceElementTop(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().top".}
  proc calltraceElementLeft(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().left".}
  proc calltraceElementWidth(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().width".}
  proc calltraceFirstElementChild(el: isonim_dom.Element): isonim_dom.Element
    {.importjs: "(#.firstElementChild || null)".}
  proc calltraceObserveResize(el: isonim_dom.Element; onResize: proc())
    {.importjs: "((el, cb) => { if (typeof ResizeObserver !== 'undefined') { new ResizeObserver(() => cb()).observe(el); } })(#, #)".}

  proc measureCallRowPitch(linesContainer: isonim_dom.Element): float =
    ## The rows' ADVANCE in CSS px — the distance from one row's top to the
    ## next — which is what positions every row, and not the row box: on the
    ## desktop the advance is ~25.28 px against a 25 px box (codetracer-pm
    ## issue 2026-10-18), and a layout built on the box drifts by the
    ## difference every row. Averaged over all rendered rows, so a sub-pixel
    ## advance is recovered exactly rather than rounded per row. With one row
    ## the box is all there is; with none, 0.0.
    ##
    ## Read from the live layout, so it follows the root font size (zoom) and
    ## the theme.
    let rows = linesContainer.calltraceRowElements()
    case rows.len
    of 0: 0.0
    of 1: rows[0].calltraceElementHeight()
    else:
      (rows[^1].calltraceElementTop() - rows[0].calltraceElementTop()) /
        float(rows.len - 1)

  proc measureCallGuideAnchor(linesContainer, svgContainer: isonim_dom.Element):
      Option[CallGuideAnchor] =
    ## Where the first rendered row's toggle sits relative to the guide layer
    ## (`svgContainer`, whose user units are its CSS px), with that row's depth
    ## spacer subtracted so the result is a depth-0 row's. `none` until a row
    ## with a toggle exists.
    let row = linesContainer.calltraceQuerySelector(cstring".calltrace-call-line")
    if isonim_dom.isNodeNil(isonim_dom.Node(row)):
      return none(CallGuideAnchor)
    let toggle = row.calltraceQuerySelector(cstring".toggle-call")
    if isonim_dom.isNodeNil(isonim_dom.Node(toggle)):
      return none(CallGuideAnchor)
    let spacer = row.calltraceFirstElementChild()
    let spacerWidth =
      if isonim_dom.isNodeNil(isonim_dom.Node(spacer)): 0.0
      else: spacer.calltraceElementWidth()
    some(CallGuideAnchor(
      originX: toggle.calltraceElementLeft() +
               toggle.calltraceElementWidth() / 2.0 -
               svgContainer.calltraceElementLeft() - spacerWidth,
      centerY: toggle.calltraceElementTop() +
               toggle.calltraceElementHeight() / 2.0 -
               row.calltraceElementTop()))

  proc remeasureCallRows(vm: CalltraceVM;
                         linesContainer, svgContainer: isonim_dom.Element;
                         anchor: Signal[Option[CallGuideAnchor]]) =
    ## Re-read the row advance and the toggle anchor from the layout and
    ## publish them: the advance to `vm.rowHeightPx` (the virtual-scroll
    ## height, the window's `translateY`, and the guides), the anchor to the
    ## guides. A value that has not moved is not re-published, so a
    ## re-measure of an unchanged layout redraws nothing.
    let pitch = measureCallRowPitch(linesContainer)
    if pitch > 0.0:
      vm.setRowHeightPx(pitch)
    let measured = measureCallGuideAnchor(linesContainer, svgContainer)
    if measured.isSome:
      let prev = anchor.val
      if prev.isNone or
          abs(prev.get.originX - measured.get.originX) > RowHeightEpsilonPx or
          abs(prev.get.centerY - measured.get.centerY) > RowHeightEpsilonPx:
        anchor.val = measured

  proc calltraceSetTimeout(fn: proc(); delay: int) {.importjs: "setTimeout(#, #)", discardable.}

  proc appendTraceLine(svg: isonim_dom.Element; x1, y1, x2, y2: float) =
    let line = createSvgElement(cstring"line")
    isonim_dom.setAttribute(line, cstring"x1", cstring($x1))
    isonim_dom.setAttribute(line, cstring"y1", cstring($y1))
    isonim_dom.setAttribute(line, cstring"x2", cstring($x2))
    isonim_dom.setAttribute(line, cstring"y2", cstring($y2))
    isonim_dom.setAttribute(line, cstring"stroke-width", cstring"0.5")
    isonim_dom.appendChild(isonim_dom.Node(svg), isonim_dom.Node(line))

  proc rowClassWeb(vm: CalltraceVM; item: proc(): CallLine): string =
    let sel = vm.selectedEntry.val
    let line = item()
    if sel.isSome and sel.get == line.index:
      "calltrace-call-line calltrace-row event-selected"
    else:
      "calltrace-call-line calltrace-row"

  proc selectedChildBoxClass(vm: CalltraceVM; item: proc(): CallLine): string =
    let sel = vm.selectedEntry.val
    let line = item()
    if sel.isSome and sel.get == line.index:
      "call-current call-child-box"
    else:
      "call-child-box"

  proc selectedToggleIconClass(vm: CalltraceVM; item: proc(): CallLine): string =
    let base = toggleIconClass(item)
    let sel = vm.selectedEntry.val
    let line = item()
    if sel.isSome and sel.get == line.index:
      base & " active"
    else:
      base

  proc rawScratchpadValue(text: string): Value =
    Value(
      kind: TypeKind.Raw,
      typ: RAW_TYPE,
      r: cstring(text),
      isLiteral: false)

  proc addCallArgToScratchpad(name, text: string) =
    when defined(ctRenderer):
      if data.sessions.len == 0:
        return
      let api =
        data.sessions[data.activeSessionIndex].viewsApi
      api.emit(InternalAddToScratchpad, ValueWithExpression(
        expression: cstring(name),
        value: rawScratchpadValue(text)))
    else:
      discard

  proc showMenu(ev: isonim_dom.Event; items: seq[ContextMenuItem]) =
    ev.preventDefault()
    ev.stopPropagation()
    showContextMenu(items, ev.eventClientX(), ev.eventClientY())

  proc calltraceRowContextItems(vm: CalltraceVM; item: proc(): CallLine):
      seq[ContextMenuItem] =
    let line = item()
    let toggleName =
      if line.hasChildren and line.isExpanded:
        cstring"Collapse Call Children"
      else:
        cstring"Expand Call Children"
    let lineIndex = line.index
    result.add(ContextMenuItem(
      name: toggleName,
      hint: cstring"",
      handler: proc(ev: kdom.Event) =
        vm.toggleExpandCallChildren(lineIndex)))
    # PLAT-50: no "Expand Full Callstack". Its handler was empty here; what
    # the original sent (`ct/expand-calls` with `CallstackInternal`) unfolds
    # the calls the engine AUTO-collapses, and no view asks the engine to
    # auto-collapse (`autoCollapsing` is false on every load), so the entry
    # could change nothing — measured on this desktop, deep in a recording.

  proc callArgContextItems(argName, argText: string):
      seq[ContextMenuItem] =
    result.add(ContextMenuItem(
      name: cstring"Add value to scratchpad",
      hint: cstring"",
      handler: proc(ev: kdom.Event) =
        addCallArgToScratchpad(argName, argText)))

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
    var argsContainer, callTextEl: isonim_dom.Element
    let row = ui(r):
      tdiv(class = rowClassWeb(vm, item),
           `data-function` = item().name,
           `data-path` = item().location.file,
           `data-line` = $item().location.line,
           `data-source-generation` = $item().location.sourceGeneration,
           `data-source-digest` = item().location.sourceDigest,
           `data-code-generation` = $item().codeGeneration,
           `data-rr-ticks` = $item().rrTicks):
        span(min_width = $(float(item().depth) * CallDepthIndentPx) & "px"):
          discard
        tdiv(class = "calltrace-child call-depth"):
          tdiv(id = "local-call-" & $item().index,
               class = selectedChildBoxClass(vm, item)):
            span(class = "toggle-call", onclick = h.onToggle):
              tdiv(class = selectedToggleIconClass(vm, item)):
                discard
            tdiv(ref = callTextEl,
                 id = "local-call-text-" & $item().index, class = "call-text",
                 onclick = h.onSelect, ondblclick = h.onDblClick):
              text callDisplayName(item()) & " #" & $item().index
            tdiv(ref = argsContainer, class = "call-args",
                 id = "call-args-false-" & $item().index):
              discard
            span(class = "return"):
              span(class = "return-arrow"):
                text returnArrowForRow(vm, item)
              span(class = "return-text"):
                text returnValueForRow(vm, item)

    isonim_dom.addEventListener(isonim_dom.Node(callTextEl), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        showMenu(ev, calltraceRowContextItems(vm, item)))

    # Reactively populate the args container with one ``.call-arg``
    # element per argument. Mirrors the historical Karax call-argument
    # markup so Playwright's
    # ``CallTraceEntry.arguments()`` (page object) can locate each
    # arg via ``.call-arg`` and read the name from ``.call-arg-name``
    # (with the trailing ``=`` stripped) and the value from
    # ``.call-arg-text``. The effect re-runs whenever the args signal
    # changes (new section loaded) or the row's underlying CallLine
    # swaps to a different ``callKey`` (indexEach reuse on scroll).
    createRenderEffect proc() =
      let line = item()
      let callArgs = argsForRow(vm, item)
      r.clearChildren(argsContainer)
      # Opening "(": the legacy view emitted these as bare text nodes
      # inside the same ``.call-args`` container so the rendered string
      # reads ``(name=value, name2=value2)``.  Tests only locate the
      # ``.call-arg`` children, but the parens are part of the legacy
      # contract so we preserve them.
      let openParen = ui(r):
        span:
          text "("
      r.appendChild(argsContainer, openParen)
      # Iterate by index and copy each arg's fields into local ``let``s
      # so the DSL closures can capture them.  See the matching comment
      # in ``renderCallLineRowMock`` above for the lent-capture rationale.
      for i in 0 ..< callArgs.len:
        let argName = callArgs[i].name
        let argText = callArgs[i].text
        let argEl = ui(r):
          tdiv(class = "call-arg",
               id = "call-arg-" & $line.index & "-" & argName):
            tdiv(class = "call-arg-header",
                 id = "call-arg-header-" & $line.index & "-" & argName):
              tdiv(class = "call-arg-name",
                   id = "call-arg-name-" & $line.index & "-" & argName):
                text argName & "="
              tdiv(class = "call-arg-text",
                   id = "call-arg-text-" & $line.index & "-" & argName):
                text argText
        isonim_dom.addEventListener(isonim_dom.Node(argEl), cstring"contextmenu",
          proc(ev: isonim_dom.Event) =
            showMenu(ev, callArgContextItems(argName, argText)))
        r.appendChild(argsContainer, argEl)
        if i < callArgs.len - 1:
          let sep = ui(r):
            span:
              text ", "
          r.appendChild(argsContainer, sep)
      let closeParen = ui(r):
        span:
          text ")"
      r.appendChild(argsContainer, closeParen)

    row

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
        let key = res.key
        let name = res.name
        let resultEl = ui(r):
          tdiv(class = "search-result",
               onmousedown = proc() =
                 vm.store.requestHistoricalNavigation(
                   "ct/calltrace-jump",
                   %*{"rrTicks": capturedRrTicks})):
            text "#" & key & " - stepId(" & $capturedRrTicks & "): " & name
        r.appendChild(container, resultEl)

  proc wireSearchForm(form, input: isonim_dom.Element; vm: CalltraceVM) =
    ## Wire up search form submission and Enter-key handling on the
    ## input. The DSL's `onclick` handler shape is `proc()`, but here
    ## we need access to the raw `Event` to call `preventDefault`, so
    ## these handlers are attached imperatively.
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        ev.preventDefault()
        ev.stopPropagation()
        let query = inputNode.inputValue()
        vm.setSearchQuery($query))
    isonim_dom.addEventListener(inputNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        if ev.eventKeyCode() == 13:
          ev.preventDefault()
          ev.stopPropagation()
          let query = inputNode.inputValue()
          vm.setSearchQuery($query))

  proc wireScrollContainer(scrollContainer, linesContainer: isonim_dom.Element;
                            vm: CalltraceVM) =
    ## Wire scroll events to the VM. The DSL renderer-API `onscroll`
    ## variant exists, but the handler needs access to `scrollTop` from
    ## the element, so this is attached imperatively.
    ##
    ## The row advance is measured from the DOM on every scroll event so that
    ## the row-index calculation is always consistent with the actual
    ## em/rem-derived advance, regardless of zoom level or theme changes.
    ## If no rows have been rendered yet (advance = 0), the cached VM value
    ## is used as a fallback to avoid a divide-by-zero.
    isonim_dom.addEventListener(isonim_dom.Node(scrollContainer),
      cstring"scroll",
      proc(ev: isonim_dom.Event) =
        let h = measureCallRowPitch(linesContainer)
        let rowH = if h > 0.0: h else: vm.rowHeightPx.val
        # Keep the VM's cached advance in sync; setRowHeightPx only updates
        # the signal when the value moves, so this is a no-op on every
        # scroll tick where the layout is stable.
        if h > 0.0:
          vm.setRowHeightPx(h)
        if rowH > 0.0:
          vm.setViewport(vm.viewport.val.scrolledTo(
            int(scrollContainer.scrollTop() / rowH))))

  proc renderTraceSvg(r: WebRenderer; svgContainer: isonim_dom.Element;
                      vm: CalltraceVM;
                      anchor: Signal[Option[CallGuideAnchor]]) =
    ## Draw the guide lines (`callGuideSegments`) for the rows the store
    ## holds, into the absolutely positioned SVG layer that sits at the top
    ## of `.calltrace-lines` and so moves with the rendered window.
    ##
    ## The effect depends on the rows, on the measured row advance
    ## (`vm.rowHeightPx`) and on the measured toggle anchor, so it redraws
    ## when any of them changes — a zoom changes the last two, through
    ## `remeasureCallRows`. It is the only drawer of this layer.
    createRenderEffect proc() =
      let lines = vm.store.calltrace.lines.val
      let pitch = vm.rowHeightPx.val
      let a = anchor.val.get(defaultCallGuideAnchor(pitch))
      r.clearChildren(svgContainer)
      # Size the SVG exactly as wide as the deepest row's guide needs: a
      # hard-coded wide value inflates the scroll container horizontally.
      var depths = newSeq[int](lines.len)
      var maxDepth = 0
      for i, line in lines:
        depths[i] = line.depth
        maxDepth = max(maxDepth, line.depth)
      let width = a.originX + float(maxDepth) * CallDepthIndentPx + 16.0
      let height = max(float(lines.len) * pitch, 1.0)
      isonim_dom.setAttribute(svgContainer, cstring"width", cstring($width))
      isonim_dom.setAttribute(svgContainer, cstring"height", cstring($height))
      isonim_dom.setAttribute(svgContainer, cstring"viewBox",
                              cstring("0 0 " & $width & " " & $height))
      for s in callGuideSegments(depths, pitch, a):
        appendTraceLine(svgContainer, s.x1, s.y1, s.x2, s.y2)

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
      svgContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(id = "calltraceComponent-0",
           class = "component-container calltrace-view isonim-calltrace",
           `data-label` = "calltrace-data-label-0", tabindex = "2"):
        tdiv:
          tdiv(class = "calltrace-search"):
            form(ref = formEl, class = "calltrace-search-form-0"):
              input(ref = inputEl,
                    id = "calltrace-search-input-0",
                    class = "calltrace-search-input calltrace-search-input-0 " &
                            "ct-input-panel ct-input-search-image",
                    `type` = "text", placeholder = "Search", tabindex = "0",
                    value = vm.searchQuery.val)
            tdiv(ref = resultsContainer, class = "call-search-results hidden"):
              discard
        tdiv(ref = scrollContainer,
             id = "calltraceScroll-0",
             class = "local-calltrace-view"):
          tdiv(ref = innerContainer,
               class = "local-calltrace",
               height = $(int(float(vm.store.calltrace.totalCallsCount.val.int) * vm.rowHeightPx.val)) & "px"):
            tdiv(ref = linesContainer, class = "calltrace-lines",
                 transform = "translateY(" & $(int(vm.store.calltrace.startLineIndex.val.float * vm.rowHeightPx.val)) & "px)"):
              discard
        # NO TEXT. This used to read "Loading..." at `font-size: 3ch`,
        # absolutely positioned across the middle of the pane, and the user
        # asked for it to go: "a 'Loading' indicator (which really needs to be
        # redesigned to be more discreet — for example, some appropriate
        # visual change in the call trace tab title can indicate the loading
        # state)".
        #
        # The element STAYS, empty, keeping its id and its `isLoading`
        # binding, because it is the DOM's single statement of whether the
        # calltrace is loading and three other things read or write it: the
        # two imperative `style.display` writes in `ui/calltrace.nim`
        # (`registerCalltrace`, `eventuallyScroll`) and the unit tests over
        # the Mock renderer. `calltrace.styl` now draws it as a 2px hairline
        # along the pane's top edge instead of a headline.
        tdiv(class = "calltrace-loading",
             id = "calltrace-toggle-loading-0",
             display = displayIf(vm.isLoading.val)):
          discard

    # Render the full window the store currently holds.  The `.calltrace-lines`
    # container is positioned with `translateY(startLineIndex * rowHeightPx)` so
    # the rendered window sits at the correct offset inside the virtual scroll
    # area (`.local-calltrace` at `totalCallsCount * rowHeightPx` tall), where
    # `rowHeightPx` is the measured row advance (`remeasureCallRows`).  This mirrors the
    # legacy Karax translateY-based virtual scrolling.
    #
    # All lines in the current store window are kept in the DOM so Playwright's
    # `findEntry` (which queries `.calltrace-call-line` elements) can see them.
    # For traces with ≤ FULL_WINDOW_CAP (500) calls the auto-load effect loads
    # the entire trace at startIndex=0, so translateY(0) applies naturally.
    # For larger traces only a scrolled window is loaded; translateY positions
    # it correctly.  See:
    # `vm.visibleLines` (calltrace_vm.nim) — the slicing memo the Mock renderer
    # uses for viewport-aware unit tests, and
    # `syncCalltraceData` (calltrace.nim) — which feeds the store.
    svgContainer = createSvgElement(cstring"svg")
    isonim_dom.setAttribute(svgContainer, cstring"id", cstring"svg-content-0")
    isonim_dom.setAttribute(svgContainer, cstring"class",
                            cstring"calltrace-svg-line")
    isonim_dom.setAttribute(svgContainer, cstring"width", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"height", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"viewBox", cstring"0 0 1 1")
    isonim_dom.appendChild(isonim_dom.Node(linesContainer),
                           isonim_dom.Node(svgContainer))

    indexEach[CallLine, WebRenderer, isonim_dom.Element](r, linesContainer,
      proc(): seq[CallLine] = vm.store.calltrace.lines.val,
      proc(item: proc(): CallLine, index: int): isonim_dom.Element =
        renderCallLineRowWeb(r, vm, item))

    # Measure the rows' advance and toggle anchor from the layout, which is
    # what the virtual-scroll math (container height and translateY) and the
    # guide lines are drawn from. Two prompts:
    #
    # - new rows: the effect subscribes to `calltrace.lines` and defers the
    #   DOM read by one tick (setTimeout 0) so `indexEach` has finished adding
    #   the row elements before their rects are queried;
    # - a layout change with no new data — a zoom (`zoomInEditors` /
    #   `zoomOutEditors` only change the root font size), a theme, a font:
    #   the rows' container changes size, and the ResizeObserver reports it
    #   after layout and before paint, so the guides are redrawn in the same
    #   frame the rows move in.
    let guideAnchor = createSignal(none(CallGuideAnchor))
    createEffect proc() =
      discard vm.store.calltrace.lines.val  # reactive dependency
      calltraceSetTimeout(proc() =
        remeasureCallRows(vm, linesContainer, svgContainer, guideAnchor)
      , 0)
    calltraceObserveResize(linesContainer, proc() =
      remeasureCallRows(vm, linesContainer, svgContainer, guideAnchor))

    # The discreet indicator the user asked for, in the tab rather than
    # across the pane. Toggles a class; adds no element and changes no text,
    # so `.lm_tabs` keeps its child shape (asserted by
    # `tests/layout/tab_strip_geometry.spec.ts`), the tab keeps its width,
    # and every exact-match on `.lm_title` text — the several Playwright
    # specs comparing "CALLTRACE", and the auto-hide code that uses the title
    # as a panel's identity — keeps resolving.
    createEffect proc() =
      setCalltraceTabBusy(vm.isLoading.val)

    renderSearchResultsList(r, resultsContainer, vm)
    renderTraceSvg(r, svgContainer, vm, guideAnchor)
    wireSearchForm(formEl, inputEl, vm)
    wireScrollContainer(scrollContainer, linesContainer, vm)
    # PLAT-51: THE SCROLLBAR IS A SCRUBBER over the WHOLE trace
    # (Scrollbar-Scrubbers.md): a click on its track jumps the view there, the
    # thumb drags it, a tick marks the debugger's call. It scrolls the
    # container, which `wireScrollContainer` turns into the section load.
    let scroller = scrollContainer
    let lines = linesContainer
    # The debugger's call, by tick, over the section held (the ViewModel's
    # rule); remembered while a scrubbed-away section is held, and asked again
    # when the debugger moves.
    var lastCurrent = -1
    var lastTicks = high(uint64)
    discard attachListScrubber(
      cast[JsObject](scroller), cast[JsObject](panel),
      total = proc(): int = int(vm.store.calltrace.totalCallsCount.val),
      current = proc(): int =
        let ticks = vm.store.debugger.val.rrTicks
        let held = vm.store.calltrace.lines.val
        let at = currentCallOf(held, ticks, @[])
        var coversAfter = false
        for l in held:
          if l.rrTicks > ticks:
            coversAfter = true
            break
        # Only a section that reaches PAST "now" can say which call "now" is
        # in: one that ends before it would name its own last call.
        if at.isSome and coversAfter:
          lastCurrent = int(at.get)
          lastTicks = ticks
        elif ticks != lastTicks:
          lastCurrent = -1
        lastCurrent,
      rowHeight = proc(): float =
        let h = measureCallRowPitch(lines)
        if h > 0.0: h else: vm.rowHeightPx.val,
      paneId = "calltrace")

    panel

  proc mountIsoNimCalltrace*(container: isonim_dom.Element;
                             vm: CalltraceVM) =
    ## Mount the IsoNim calltrace panel as a child of `container`.
    ## Reactive effects then handle every subsequent update — no manual
    ## redraw is needed. Call once, after the `CalltraceVM` exists.
    let r = WebRenderer()
    let panel = renderCalltracePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
