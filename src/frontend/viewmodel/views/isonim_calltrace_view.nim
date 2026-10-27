## views/isonim_calltrace_view.nim
##
## IsoNim DOM-rendering view for the Calltrace panel.
##
## Renders a live, reactive DOM tree driven by `CalltraceVM` signals.
## When the VM's signals change (visible lines, selected entry,
## scroll indicators, search query), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## ONE view, generic over the renderer (Shared-DOM-Front-Ends D3): the same
## proc renders under `MockRenderer` in the headless lanes and under
## `WebRenderer` in Electron, the web page and every VS Code webview. Its
## markup is the class names, ids and hierarchy the Playwright page objects
## (`CallTracePane`, `CallTraceEntry`) expect:
##     `.calltrace-view.isonim-calltrace` (inside the host `#calltraceComponent-<n>`)
##     `.calltrace-call-line.calltrace-row[.event-selected]`
##     `.call-child-box#local-call-{index}`
##     `.toggle-call > .{dot|collapse}-call-img`
##     `.call-text#local-call-text-{index}` (click = select / double-click = jump;
##       an `a.call-text[href]` when the host passes a link builder, D10)
##     `.calltrace-search > form > input.calltrace-search-input`
##     `.call-search-summary` (when the window held fewer matches than the trace)
##     `.call-search-results > .search-result`
##
## Structure that changes is a control-flow component, never a subtree
## cleared and rebuilt in an effect: the rows are an `indexEach` over the
## section the store holds, each row's arguments an `indexEach` over its
## call's arguments, the search results an `indexEach` over the answer.
##
## What only a browser has — the scroll position, the measured row height,
## context menus, the search form's submit, the connector SVG, the
## scrollbar scrubber and the tab's busy mark — is attached afterwards on the
## web renderer, as leaves over elements captured with `ref = …`.

import std/[json, options, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import ../store/replay_data_store
  import ./isonim_activation
  from ./row_link_dom import attachRowLinkClicks
  from ./context_menu_bridge import showContextMenu
  from ../../context_menu_item import ContextMenuItem
  import kdom except Location
  import std/jsffi
  import ./list_scrubber_dom
  # PLAT-70 Part I (Horizontal-Overflow.md §5.5.5): the rows fit or scroll,
  # and fitted rows are table cells (Part B's cut, hover, detail and copy).
  from ./table_fit_dom import attachCallTraceFit, CalleeAttribute
  from ./table_overflow_dom import attachTableOverflow
  from ../viewmodels/table_overflow import CallTraceTablePane

import ../store/types
import ./row_links
import ../backend/backend_service
import ../viewmodels/calltrace_vm
import ../viewport   # `withRows` / `withCols`

# A generic view is instantiated where it is called, and the `ui` macro's
# expansion names `createRenderEffect` and the control-flow components there:
# exported so a caller needs no IsoNim import of its own to render this view.
export signals, computation, components

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

# ---------------------------------------------------------------------------
# Guide-line geometry
# ---------------------------------------------------------------------------
#
# The guides are an SVG layer laid over the rows (`renderTraceSvg` below). A
# guide connects two rows only if it is drawn where the browser put them, and
# the browser lays the rows out from em-based CSS: their advance follows the
# root font size (zoom) and need not be a whole number of pixels (the row box
# is 1.5625em, so 20.3125 px at a 13 px root). So nothing here is a pixel
# constant except the depth indent, which the row renderer itself writes in
# pixels. The rest is measured from the rendered rows and passed in.

const CallDepthIndentPx* = float(CallRowIndentPx)
  ## Width of one level of nesting: `renderCallLineRow` writes a spacer of
  ## `depth * CallDepthIndentPx` px before each row's toggle, so a toggle's
  ## centre moves right by exactly this much per level
  ## (`calltrace_vm.CallRowIndentPx`, GPUI's too).

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

when defined(js):
  proc createSvgElement(tag: cstring): isonim_dom.Element {.importjs: "document.createElementNS('http://www.w3.org/2000/svg', #)".}
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc eventKeyCode(ev: isonim_dom.Event): int {.importjs: "(#.keyCode || 0)".}
  proc setScrollTop(node: isonim_dom.Element; value: float) {.importjs: "#.scrollTop = #".}

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
    ## next — which is what positions every row. The shipped stylesheet makes
    ## it equal to the row box (`calltrace.styl` keeps every part of a row
    ## within the toggle's 1.5625em; codetracer-pm issue 2026-10-18 records
    ## the return value that once grew rows past it), but the advance is
    ## still MEASURED rather than assumed: it is the quantity the guides and
    ## the virtual scroll depend on, and a theme or a later rule that let a
    ## row grow would otherwise drift them by the difference every row.
    ## Averaged over all rendered rows, so a sub-pixel advance is recovered
    ## exactly rather than rounded per row. With one row the box is all there
    ## is; with none, 0.0.
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

  var addToScratchpadHook*: proc(name, text: string)
    ## Where "Add value to scratchpad" on a call argument goes. The host that
    ## mounts the view installs it: the desktop sends the value over its event
    ## bus (`ui/panel_host`), a VS Code webview to its mirror's
    ## `ScratchpadVM.addValue` (`entries/vscode_panel`). A page with no
    ## scratchpad leaves it unset and the entry does nothing. The view itself
    ## knows no host, so it can be rendered outside the desktop
    ## (`codetracer_ui_components`).

  proc addCallArgToScratchpad(name, text: string) =
    if not addToScratchpadHook.isNil:
      addToScratchpadHook(name, text)

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

  proc eventKeyName(ev: isonim_dom.Event): cstring {.importjs: "(#.key || '')".}
  proc eventRepeats(ev: isonim_dom.Event): bool {.importjs: "(#.repeat === true)".}

  proc wireResultKeys(el: isonim_dom.Element; jump: proc()) =
    ## A search result jumps on `mousedown`, not on a click, so the
    ## document's Enter/Space-is-click (`isonim_activation`) would reach
    ## nothing: its keys run the jump here.
    isonim_dom.addEventListener(isonim_dom.Node(el), cstring"keydown",
      proc(ev: isonim_dom.Event) =
        if ev.eventRepeats() or not isActivationKey($ev.eventKeyName()):
          return
        ev.preventDefault()
        ev.stopPropagation()
        jump())

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

  proc decorateCalltracePanel(panel, formEl, inputEl, scrollContainer,
                              linesContainer: isonim_dom.Element;
                              vm: CalltraceVM) =
    ## The browser's half of the panel: the connector SVG behind the rows,
    ## the guide geometry measured from the rows, the tab's busy mark, the
    ## search form, the reveal scroll and the scrollbar scrubber.
    let r = WebRenderer()
    let svgContainer = createSvgElement(cstring"svg")
    isonim_dom.setAttribute(svgContainer, cstring"id", cstring"svg-content-0")
    isonim_dom.setAttribute(svgContainer, cstring"class",
                            cstring"calltrace-svg-line")
    isonim_dom.setAttribute(svgContainer, cstring"width", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"height", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"viewBox", cstring"0 0 1 1")
    isonim_dom.appendChild(isonim_dom.Node(linesContainer),
                           isonim_dom.Node(svgContainer))
    # The rows' advance and the toggle anchor are measured from the layout:
    # the virtual-scroll math and the guide lines are drawn from them. New
    # rows are measured one tick after they arrive (so `indexEach` has added
    # them); a layout change with no new data — a zoom, a theme, a font —
    # resizes the rows' container, and the ResizeObserver reports it before
    # paint, so the guides move in the same frame as the rows.
    let guideAnchor = createSignal(none(CallGuideAnchor))
    createEffect proc() =
      discard vm.store.calltrace.lines.val
      calltraceSetTimeout(proc() =
        remeasureCallRows(vm, linesContainer, svgContainer, guideAnchor)
      , 0)
    calltraceObserveResize(linesContainer, proc() =
      remeasureCallRows(vm, linesContainer, svgContainer, guideAnchor))
    renderTraceSvg(r, svgContainer, vm, guideAnchor)

    # The discreet loading indicator, in the tab rather than across the pane.
    createEffect proc() =
      setCalltraceTabBusy(vm.isLoading.val)

    wireSearchForm(formEl, inputEl, vm)
    # PLAT-70 Part I (Horizontal-Overflow.md §5.5.5 — OQ-H5, proposed,
    # awaiting the user's confirmation): the rows are cut at the pane while
    # every row's indent and callee name fit, and scroll sideways only when
    # they do not; a cut row's whole text is on hover, under it, and copied.
    attachCallTraceFit(cast[JsObject](scrollContainer),
                       cast[JsObject](linesContainer))
    discard attachTableOverflow(cast[JsObject](panel), CallTraceTablePane,
                                cstring".calltrace-call-line")
    # What the pane shows — its rows, the row it is scrolled to, the depth
    # levels across it — is reported by the panel host that mounted it
    # (`ui/panel_host`, HSF-V2), not measured here.
    # codetracer#860: a search result's reveal (`CalltraceVM.revealScroll`)
    # scrolls the container to the row the ViewModel revealed. The scroll
    # listener then reports the same first row back, so the viewport and the
    # DOM agree. Nothing else scrolls the pane on the ViewModel's initiative
    # (Scrollbar-Scrubbers.md §3.5).
    var revealSerial = 0
    createEffect proc() =
      let req = vm.revealScroll.val
      if req.serial == 0 or req.serial == revealSerial:
        return
      revealSerial = req.serial
      let measured = measureCallRowPitch(linesContainer)
      let rowH = if measured > 0.0: measured else: vm.rowHeightPx.val
      setScrollTop(scrollContainer, float(req.firstRow) * rowH)
    # PLAT-51: THE SCROLLBAR IS A SCRUBBER over the WHOLE trace
    # (Scrollbar-Scrubbers.md): a click on its track jumps the view there, the
    # thumb drags it, a tick marks the debugger's call.
    var lastCurrent = -1
    var lastTicks = high(uint64)
    discard attachListScrubber(
      cast[JsObject](scrollContainer), cast[JsObject](panel),
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
        let h = measureCallRowPitch(linesContainer)
        if h > 0.0: h else: vm.rowHeightPx.val,
      paneId = "calltrace")

# ---------------------------------------------------------------------------
# One row
# ---------------------------------------------------------------------------
#
#   div.calltrace-call-line.calltrace-row [.event-selected]
#     span                                           depth offset (min-width)
#     div.calltrace-child.call-depth
#       div.call-child-box#local-call-{index}
#         span.toggle-call                           click = expand/collapse
#           div.{collapse|dot}-call-img
#         div.call-text#local-call-text-{index}      click = select and go
#           text "{name} #{index}"
#         div.call-args                              "(" a=1, b=2 ")"
#         span.return > span.return-arrow + span.return-text
#
# `indexEach` reuses a row's element as the section shifts, so everything
# derived from the line — ids included — reads `item()` reactively.

proc rowClass(vm: CalltraceVM; item: proc(): CallLine): string =
  let sel = vm.selectedEntry.val
  if sel.isSome and sel.get == item().index:
    "calltrace-call-line calltrace-row event-selected"
  else:
    "calltrace-call-line calltrace-row"

proc callCellKey(item: proc(): CallLine): string =
  ## PLAT-70 Part I: the row's call box is a TABLE CELL of the Call Trace —
  ## `<pane>|<key>|<column>`, the terminal's and GPUI's key (the call's
  ## trace index).
  "call-trace|" & $item().index & "|call"

proc callFullText(vm: CalltraceVM; item: proc(): CallLine): string =
  ## The row's whole text — the shared `callRowText` over the ViewModel's
  ## row (name, `#index`, arguments, return), the text the terminal and GPUI
  ## fit and show in full.
  callRowText(callRowOf(item(), argsForRow(vm, item)))

proc childBoxClass(vm: CalltraceVM; item: proc(): CallLine): string =
  let sel = vm.selectedEntry.val
  if sel.isSome and sel.get == item().index: "call-current call-child-box"
  else: "call-child-box"

proc toggleClass(vm: CalltraceVM; item: proc(): CallLine): string =
  let base = toggleIconClass(item)
  let sel = vm.selectedEntry.val
  if sel.isSome and sel.get == item().index: base & " active" else: base

proc renderCallArg[R, N](r: R; line: proc(): CallLine;
                         arg: proc(): CallArg; index: int): N =
  ## One argument: `.call-arg > .call-arg-header > .call-arg-name +
  ## .call-arg-text`, preceded by the ", " that separates it from the one
  ## before (the page object reads the name and the text, not the commas).
  ui(r):
    span(class = "call-arg-slot"):
      span(class = "call-arg-separator"):
        text (if index > 0: ", " else: "")
      tdiv(class = "call-arg",
           id = "call-arg-" & $line().index & "-" & arg().name,
           `data-arg-name` = arg().name):
        tdiv(class = "call-arg-header",
             id = "call-arg-header-" & $line().index & "-" & arg().name):
          tdiv(class = "call-arg-name",
               id = "call-arg-name-" & $line().index & "-" & arg().name):
            text arg().name & "="
          tdiv(class = "call-arg-text",
               id = "call-arg-text-" & $line().index & "-" & arg().name):
            text arg().text

proc toggleRole(item: proc(): CallLine): string =
  ## A call with children has a control that expands or collapses them; a
  ## leaf's dot is a picture of having none, and is not a control.
  if item().hasChildren: "button" else: "presentation"

proc toggleTabIndex(item: proc(): CallLine): string =
  if item().hasChildren: "0" else: "-1"

proc toggleExpanded(item: proc(): CallLine): string =
  ## `aria-expanded` of the toggle (https://www.w3.org/TR/wai-aria-1.2/#aria-expanded);
  ## empty on a leaf, which removes the attribute.
  let line = item()
  if not line.hasChildren: ""
  elif line.isExpanded: "true"
  else: "false"

proc callTextLink(vm: CalltraceVM; links: RowLinks; row: int): string =
  ## The call text's `href`: what the host's builder makes of the address of
  ## the held row at `row` (Shared-DOM-Front-Ends D10); empty when it makes
  ## nothing.
  links.linkOf(vm.rowAddress(row))

proc renderCallText[R, N](r: R; vm: CalltraceVM; item: proc(): CallLine;
                          h: RowHandlers; links: RowLinks; row: int;
                          callTextEl: var N): N =
  ## The call's text: the row's main control. Without a link builder it is a
  ## `role="button"` with a tab stop. With one (a host that can address a row,
  ## D10) it is an `<a href>` to the builder's URL, so focus, Enter,
  ## middle-click, "open in new tab" and "copy link" are the platform's; a
  ## plain click still selects and goes (`row_link_dom`).
  ##
  ## Chosen once per row, outside `ui`: whether a host passed a builder does
  ## not change while the view lives.
  if links.isNil:
    result = ui(r):
      tdiv(ref = callTextEl,
           id = "local-call-text-" & $item().index, class = "call-text",
           role = "button", tabindex = "0",
           onclick = h.onSelect, ondblclick = h.onDblClick):
        text callDisplayName(item()) & " #" & $item().index
  else:
    result = ui(r):
      a(ref = callTextEl,
        id = "local-call-text-" & $item().index, class = "call-text",
        onclick = h.onSelect, ondblclick = h.onDblClick):
        text callDisplayName(item()) & " #" & $item().index
    # A row the builder made no URL for has no `href` at all (an empty one
    # would link to the page itself) and stays a button with a tab stop.
    let el = result
    bindLinkAttributes[R, N](r, el, proc(): string =
      callTextLink(vm, links, row), asButtonWhenUnlinked = true)

proc renderCallLineRow*[R, N](r: R; vm: CalltraceVM;
                              item: proc(): CallLine;
                              links: RowLinks = nil; slot = -1): N =
  ## One call-trace row (see the markup above).
  ##
  ## The call's text and its toggle are the row's two controls, and each is a
  ## `role="button"` with a tab stop, and Enter or Space on it is its click
  ## (`isonim_activation`): the call text selects the call and goes to it, the
  ## toggle expands or collapses its children. A leaf's dot is neither. With a
  ## host's link builder the call text is a link instead (`renderCallText`) to
  ## the address of the held row at `slot`, the position this row is drawn at.
  let h = rowHandlers(vm, item)
  var argsHost, callTextEl, childBoxEl, callArgsEl: N
  let row = ui(r):
    tdiv(class = rowClass(vm, item),
         `data-function` = item().name,
         `data-path` = item().location.file,
         `data-line` = $item().location.line,
         `data-source-generation` = $item().location.sourceGeneration,
         `data-source-digest` = item().location.sourceDigest,
         `data-code-generation` = $item().codeGeneration,
         `data-rr-ticks` = $item().rrTicks,
         `data-call-key` = item().callKey):
      span(min_width = $(item().depth * int(CallDepthIndentPx)) & "px"):
        discard
      tdiv(class = "calltrace-child call-depth"):
        tdiv(ref = childBoxEl, id = "local-call-" & $item().index,
             class = childBoxClass(vm, item),
             `data-ct-cell` = callCellKey(item),
             `data-ct-full` = callFullText(vm, item),
             `data-ct-callee` = callDisplayName(item())):
          span(class = "toggle-call",
               role = toggleRole(item), tabindex = toggleTabIndex(item),
               `aria-expanded` = toggleExpanded(item),
               `aria-label` = "Show or hide the calls it makes",
               onclick = h.onToggle):
            tdiv(class = toggleClass(vm, item)):
              discard
          # The call text goes here, between the toggle and the arguments
          # (`renderCallText`, inserted below).
          tdiv(ref = callArgsEl, class = "call-args",
               id = "call-args-false-" & $item().index):
            span:
              text "("
            span(ref = argsHost, class = "call-args-list"):
              discard
            span:
              text ")"
          span(class = "return"):
            span(class = "return-arrow"):
              text returnArrowForRow(vm, item)
            span(class = "return-text"):
              text returnValueForRow(vm, item)
  r.insertBefore(childBoxEl,
                 renderCallText[R, N](r, vm, item, h, links, slot,
                                      callTextEl),
                 callArgsEl)
  indexEach[CallArg, R, N](r, argsHost,
    proc(): seq[CallArg] = argsForRow(vm, item),
    proc(arg: proc(): CallArg, index: int): N =
      let slot = renderCallArg[R, N](r, item, arg, index)
      when defined(js):
        when N is isonim_dom.Element:
          isonim_dom.addEventListener(isonim_dom.Node(slot),
            cstring"contextmenu",
            proc(ev: isonim_dom.Event) =
              showMenu(ev, callArgContextItems(arg().name, arg().text)))
      slot)
  when defined(js):
    when N is isonim_dom.Element:
      isonim_dom.addEventListener(isonim_dom.Node(callTextEl),
        cstring"contextmenu",
        proc(ev: isonim_dom.Event) =
          showMenu(ev, calltraceRowContextItems(vm, item)))
      if not links.isNil:
        attachRowLinkClicks(row)
  row

proc searchResultsClass(vm: CalltraceVM): string =
  if vm.backendSearchResults.val.len == 0: "call-search-results hidden"
  else: "call-search-results"

proc searchSummaryDisplay(vm: CalltraceVM): string =
  if vm.backendSearchTotal.val > vm.backendSearchResults.val.len: "block"
  else: "none"

proc searchSummaryText(vm: CalltraceVM): string =
  "Showing " & $vm.backendSearchResults.val.len & " of " &
    $vm.backendSearchTotal.val & " matching calls"

proc searchResultJumpHandler(vm: CalltraceVM; index: int): proc() =
  ## A search result row's `mousedown`: jump to THIS result's frame
  ## (`CalltraceVM.jumpToSearchResult`). A factory, so each row's closure owns
  ## its index (Nim closures capture variables by reference:
  ## https://nim-lang.org/docs/manual.html#procedures-closures).
  result = proc() = vm.jumpToSearchResult(index)

proc searchResultLabel(res: CalltraceSearchResult): string =
  ## A result row's text: `#<call key> - stepId(<tick>): <function>`, the
  ## legacy Karax search-results label.
  "#" & res.key & " - stepId(" & $res.rrTicks & "): " & res.name

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderCalltracePanel*[R, N](r: R; vm: CalltraceVM;
                                 links: RowLinks = nil): N =
  ## The Call Trace panel — the markup of the legacy Karax calltrace, which
  ## the Playwright page objects find unchanged.
  ##
  ## `links` is a host's link builder (Shared-DOM-Front-Ends D10): with one,
  ## each row's call text is a link to what it builds from the row's address.
  ## CodeTracer's own front-ends pass none.
  ##
  ## The rows are the section the store holds, positioned by `translateY`
  ## inside a scroll area as tall as the whole trace (`totalCallsCount` rows),
  ## so a scrolled-to section sits where it belongs.
  var
    formEl, inputEl, resultsHost: N
    scrollContainer, linesContainer: N
  let panel = ui(r):
    # No id: the host the panel is mounted into carries the pane's id
    # (`calltraceComponent-<n>`), and an id names one element.
    tdiv(class = "calltrace-view isonim-calltrace",
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
          # The window held fewer matches than the trace has (HSF-V1).
          tdiv(class = "call-search-summary",
               display = searchSummaryDisplay(vm)):
            text searchSummaryText(vm)
          tdiv(ref = resultsHost, class = searchResultsClass(vm)):
            discard
      tdiv(ref = scrollContainer,
           id = "calltraceScroll-0",
           class = "local-calltrace-view"):
        tdiv(class = "local-calltrace",
             height = $(int(float(vm.store.calltrace.totalCallsCount.val.int) *
                            vm.rowHeightPx.val)) & "px"):
          tdiv(ref = linesContainer, class = "calltrace-lines",
               transform = "translateY(" &
                 $(int(vm.store.calltrace.startLineIndex.val.float *
                       vm.rowHeightPx.val)) & "px)"):
            discard
      # The calltrace's loading state, drawn by `calltrace.styl` as a
      # hairline along the pane's top edge (the user asked for a discreet
      # indicator; the tab's busy mark is the other half).
      tdiv(class = "calltrace-loading",
           id = "calltrace-toggle-loading-0",
           display = displayIf(vm.isLoading.val)):
        discard

  indexEach[CallLine, R, N](r, linesContainer,
    proc(): seq[CallLine] = vm.store.calltrace.lines.val,
    proc(item: proc(): CallLine, index: int): N =
      renderCallLineRow[R, N](r, vm, item, links, index))

  indexEach[CalltraceSearchResult, R, N](r, resultsHost,
    proc(): seq[CalltraceSearchResult] = vm.backendSearchResults.val,
    proc(res: proc(): CalltraceSearchResult; index: int): N =
      var resultEl: N
      result = ui(r):
        tdiv(ref = resultEl, class = "search-result",
             role = "button", tabindex = "0",
             onmousedown = searchResultJumpHandler(vm, index)):
          text searchResultLabel(res())
      when defined(js):
        when N is isonim_dom.Element:
          wireResultKeys(resultEl, searchResultJumpHandler(vm, index)))

  when defined(js):
    when N is isonim_dom.Element:
      decorateCalltracePanel(panel, formEl, inputEl, scrollContainer,
                             linesContainer, vm)
  panel
