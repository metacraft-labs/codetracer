## views/isonim_terminal_output_view.nim
##
## IsoNim DOM-rendering view for the Terminal Output panel — the desktop's
## view over ``TerminalOutputVM``, the ViewModel the terminal and GPUI
## front-ends draw too.
##
## Spec: `codetracer-specs/spec/GUI/Core-Panes/Terminal-Output-Pane.md`.
##
## ONE generic builder serves both renderers (Mock for the headless suites,
## Web for the product), so the tree a suite asserts is the tree the desktop
## mounts.
##
## ## No markup from the program reaches the DOM
##
## PLAT-52: a fragment carries its TEXT and its decoded SGR ATTRIBUTES
## (`types.TermAttrs`), not `ansi_up`'s HTML. Each fragment is a `<span>`
## whose `style` is built from the attributes (`terminal_output_model.cssOf`,
## the declarations `ansi_up` wrote) and whose text is a TEXT NODE — so a
## recorded program's `<img onerror=...>` is text, by construction, and this
## view has no `innerHTML` write left (`src/frontend/tests/htmlSinks.test.mjs`
## counts them).
##
## Structure (the Playwright contract in
## ``src/tests/gui/page-objects/panes/terminal/terminal-output-pane.ts``)::
##
##   div#terminalComponent-0.component-container.terminal[.isonim-terminal-output]
##     div.terminal-view-toggle               ← shown when the screen is offered
##       button.terminal-view-button[data-view=lines|screen][.active]
##     pre                                    ← the LINE view: the held
##                                               window, padded to every line
##       div.terminal-line#terminal-line-{lineIndex}
##         div.{past|active|future}[data-event-index]  ← click → jumpToEvent
##           div
##             span[style=<sgr css>] text
##     div.terminal-screen                    ← the SCREEN view (§3)
##       div.terminal-screen-viewport
##         div.terminal-screen-grid[data-cols][data-rows]
##           div.terminal-screen-row → span[style] text
##       div.terminal-scrubber
##         input.terminal-scrubber-range[type=range][min=0][max=n-1]
##         div.terminal-scrubber-marks → span.terminal-scrubber-mark[data-kind]
##         span.terminal-scrubber-label   "write i / n · tick t"
##     div.empty-overlay
##
## The scrubber is REAL-TIME: dragging it (`input` → `scrubTo`) moves the
## recording position to each write it crosses (`ct/event-jump`), the release
## (`change` → `releaseScrub`) ends the drag; ArrowLeft / ArrowRight on the
## screen step a write back / forward.

import std/[math, strutils, tables]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import std/jsffi
  import ./list_scrubber_dom

import ../store/types
import ../viewmodels/terminal_output_vm

# The generic procs expand reactive effects at their instantiation site.
export signals, computation

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc emptyOverlayText(vm: TerminalOutputVM): string =
  ## "Loading record output..." while ``initialLoad`` is true; the
  ## post-load fallback otherwise (the legacy view's strings).
  if vm.initialLoad.val:
    "Loading record output..."
  else:
    "The current record does not print anything to the terminal."

proc fragmentClass*(focusRRTicks, fragRRTicks: uint64): string =
  ## past / active / future, the class every desktop style keys on.
  $fragmentTense(focusRRTicks, fragRRTicks)

proc scrubberLabel*(vm: TerminalOutputVM): string =
  ## "write i / n · tick t" under the screen's scrubber.
  let n = vm.events.val.len
  let w = vm.shownWrite.val
  if n == 0:
    return "no writes"
  if w < 0:
    return "before the first write (" & $n & " writes)"
  "write " & $(w + 1) & " / " & $n & " · tick " &
    $vm.events.val[w].rrTicks &
    (if vm.scrubPreview.val >= 0: " · scrubbing" else: "")

when defined(js):
  proc evKey(ev: isonim_dom.Event): cstring {.importjs: "(#.key || '')".}
  proc inputValue(n: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(n: isonim_dom.Node; v: cstring) {.importjs: "#.value = #".}
  proc stopEvent(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc fitScreenGrid(box, grid: isonim_dom.Node) {.importjs: """
    (function(box, grid) {
      var fit = function() {
        grid.style.transform = '';
        var gw = grid.scrollWidth, gh = grid.scrollHeight;
        var bw = box.clientWidth, bh = box.clientHeight;
        if (!gw || !gh || !bw || !bh) return;
        var s = Math.min(bw / gw, bh / gh);
        grid.style.transformOrigin = 'top left';
        grid.style.transform = 'scale(' + s + ')';
        grid.setAttribute('data-scale', String(Math.round(s * 1000) / 1000));
      };
      if (typeof requestAnimationFrame === 'function') requestAnimationFrame(fit);
      else fit();
    })(#, #)""".}

proc stepKey*(vm: TerminalOutputVM; key: string): bool =
  ## ArrowLeft / ArrowRight on the screen: the previous / next write.
  case key
  of "ArrowLeft":
    discard vm.stepWrite(-1)
    true
  of "ArrowRight":
    discard vm.stepWrite(1)
    true
  else: false

# The renderer-specific parts of the builder, one generic proc each: the
# event's key, a range input's value, the screen grid's fit. `N` names the
# renderer's node type; the browser's DOM element is the only one with a
# layout to fit and an `Event` to read.

proc valueOf[R, N](r: R; n: N): string =
  when defined(js):
    when N is isonim_dom.Element:
      return $inputValue(isonim_dom.Node(n))
    else:
      return n.attributes.getOrDefault("value", "")
  else:
    n.attributes.getOrDefault("value", "")

proc setValue[R, N](r: R; n: N; v: string) =
  when defined(js):
    when N is isonim_dom.Element:
      setInputValue(isonim_dom.Node(n), cstring(v))
    else:
      r.setAttribute(n, "value", v)
  else:
    r.setAttribute(n, "value", v)

proc fitGrid[R, N](r: R; box, grid: N) =
  ## Scale the screen's grid into its box — a layout only the browser has.
  when defined(js):
    when N is isonim_dom.Element:
      fitScreenGrid(isonim_dom.Node(box), isonim_dom.Node(grid))

proc wireStepKeys[R, N](r: R; node: N; vm: TerminalOutputVM) =
  ## ArrowLeft / ArrowRight on the screen step by write (`stepKey`).
  when defined(js):
    when N is isonim_dom.Element:
      r.addEventListener(node, "keydown", proc(ev: isonim_dom.Event) =
        if stepKey(vm, $evKey(ev)): stopEvent(ev))
    else:
      r.addEventListener(node, "keydown", proc(ev: MockEvent) =
        if stepKey(vm, ev.key): ev.preventDefault())
  else:
    r.addEventListener(node, "keydown", proc(ev: MockEvent) =
      if stepKey(vm, ev.key): ev.preventDefault())

proc wireLineClick[R, N](r: R; node: N; vm: TerminalOutputVM; write: int) =
  ## A click on a line PAST its text (on the line itself, not a fragment)
  ## goes to the write that completed the line.
  when defined(js):
    when N is isonim_dom.Element:
      r.addEventListener(node, "click", proc(ev: isonim_dom.Event) =
        if ev.target == isonim_dom.Node(node): vm.jumpToEvent(write))
    else:
      r.addEventListener(node, "click", proc(ev: MockEvent) =
        if ev.target == node: vm.jumpToEvent(write))
  else:
    r.addEventListener(node, "click", proc(ev: MockEvent) =
      if ev.target == node: vm.jumpToEvent(write))

proc jumpOnClick(vm: TerminalOutputVM; eventIndex: int): proc() =
  ## A fragment's click handler, made by a FACTORY so the write it goes to is
  ## this call's own: a closure written inside the line loop would capture
  ## the loop's variable, which Nim's JS backend shares across iterations —
  ## every fragment then went to the LAST write (measured on the real
  ## desktop: a click on line 10 sent the event-jump of write 129).
  let idx = eventIndex
  result = proc() = vm.jumpToEvent(idx)

# ---------------------------------------------------------------------------
# The builder, generic over the renderer
# ---------------------------------------------------------------------------

proc el[R](r: R; tag, class: string): auto =
  result = r.createElement(tag)
  if class.len > 0:
    r.setAttribute(result, "class", class)

proc styledSpan[R](r: R; text: string; style: TermAttrs): auto =
  result = r.createElement("span")
  let css = cssOf(style)
  if css.len > 0:
    r.setAttribute(result, "style", css)
  r.appendChild(result, r.createTextNode(text))

proc renderTerminalOutputPanel*[R, N](r: R; vm: TerminalOutputVM): N =
  ## The Terminal Output panel. It takes no id: the host it is mounted into
  ## carries the pane's (`terminalComponent-<n>`), and an id names one
  ## element.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class",
                 "component-container terminal isonim-terminal-output")

  let toggle = el(r, "div", "terminal-view-toggle")
  let linesButton = el(r, "button", "terminal-view-button")
  r.setAttribute(linesButton, "data-view", $tvLines)
  r.appendChild(linesButton, r.createTextNode("Lines"))
  let screenButton = el(r, "button", "terminal-view-button")
  r.setAttribute(screenButton, "data-view", $tvScreen)
  r.appendChild(screenButton, r.createTextNode("Screen"))
  r.addEventListener(linesButton, "click", proc() = vm.setView(tvLines))
  r.addEventListener(screenButton, "click", proc() = vm.setView(tvScreen))
  r.appendChild(toggle, linesButton)
  r.appendChild(toggle, screenButton)
  r.appendChild(panel, toggle)

  let pre = r.createElement("pre")
  r.appendChild(panel, pre)

  # The screen's layout is inline (no stylesheet rule has to be built for
  # it): a column — the viewport the grid is scaled into, then the scrubber —
  # and a grid of monospaced rows that keep every space (`pre`), so a row of
  # blanks is a row and a column is a column.
  let screenNode = el(r, "div", "terminal-screen")
  r.setAttribute(screenNode, "tabindex", "0")
  r.setStyle(screenNode, "flex-direction", "column")
  r.setStyle(screenNode, "height", "100%")
  r.setStyle(screenNode, "outline", "none")
  let viewport = el(r, "div", "terminal-screen-viewport")
  r.setStyle(viewport, "flex", "1 1 auto")
  r.setStyle(viewport, "overflow", "hidden")
  r.setStyle(viewport, "min-height", "0")
  let grid = el(r, "div", "terminal-screen-grid")
  r.setStyle(grid, "display", "inline-block")
  r.setStyle(grid, "white-space", "pre")
  r.setStyle(grid, "font-family", "\"SpaceMono\", monospace")
  r.setStyle(grid, "line-height", "1.25")
  r.appendChild(viewport, grid)
  r.appendChild(screenNode, viewport)
  let scrubber = el(r, "div", "terminal-scrubber")
  r.setStyle(scrubber, "flex", "0 0 auto")
  r.setStyle(scrubber, "padding", "4px 8px")
  let range = el(r, "input", "terminal-scrubber-range")
  r.setAttribute(range, "type", "range")
  r.setAttribute(range, "min", "0")
  r.setAttribute(range, "step", "1")
  r.setStyle(range, "width", "100%")
  let marks = el(r, "div", "terminal-scrubber-marks")
  r.setStyle(marks, "position", "relative")
  r.setStyle(marks, "height", "8px")
  let label = el(r, "span", "terminal-scrubber-label")
  r.setStyle(label, "opacity", "0.7")
  r.appendChild(scrubber, range)
  r.appendChild(scrubber, marks)
  r.appendChild(scrubber, label)
  r.appendChild(screenNode, scrubber)
  r.appendChild(panel, screenNode)

  # The scrubber: `input` while dragged previews, `change` on release jumps.
  r.addEventListener(range, "input", proc() =
    let v = valueOf[R, N](r, range)
    if v.len > 0:
      try: vm.scrubTo(parseInt(v)) except ValueError: discard)
  r.addEventListener(range, "change", proc() =
    let v = valueOf[R, N](r, range)
    if v.len > 0:
      try: vm.scrubTo(parseInt(v)) except ValueError: discard
    discard vm.releaseScrub())
  # The step-by-write keys, scoped to the screen.
  wireStepKeys[R, N](r, screenNode, vm)

  let overlay = el(r, "div", "empty-overlay")
  let overlayText = r.createTextNode("")
  r.appendChild(overlay, overlayText)
  r.appendChild(panel, overlay)

  # Toggle and visibility.
  createRenderEffect proc() =
    let offered = vm.screenOffered.val
    let view = vm.view.val
    let screenShown = offered and view == tvScreen
    r.setStyle(toggle, "display", displayIf(offered))
    r.setAttribute(linesButton, "class", "terminal-view-button" &
                   (if not screenShown: " active" else: ""))
    r.setAttribute(screenButton, "class", "terminal-view-button" &
                   (if screenShown: " active" else: ""))
    r.setStyle(pre, "display", displayIf(not screenShown))
    r.setStyle(screenNode, "display", if screenShown: "flex" else: "none")
    r.setAttribute(panel, "data-terminal-view",
                   (if screenShown: $tvScreen else: $tvLines))

  createRenderEffect proc() =
    let empty = vm.lineCount() == 0
    r.setStyle(overlay, "display", displayIf(empty))
    r.clearChildren(overlay)
    r.appendChild(overlay, r.createTextNode(emptyOverlayText(vm)))

  # The line view.
  createRenderEffect proc() =
    let lines = vm.lines.val
    let focus = vm.currentRRTicks.val
    r.clearChildren(pre)
    for line in lines:
      let lineNode = el(r, "div", "terminal-line")
      r.setAttribute(lineNode, "id", "terminal-line-" & $line.lineIndex)
      if line.fragments.len > 0:
        wireLineClick[R, N](r, lineNode, vm, line.fragments[^1].eventIndex)
      for frag in line.fragments:
        let fragNode = el(r, "div", fragmentClass(focus, frag.rrTicks))
        r.setAttribute(fragNode, "data-event-index", $frag.eventIndex)
        r.addEventListener(fragNode, "click", jumpOnClick(vm, frag.eventIndex))
        let content = r.createElement("div")
        r.appendChild(content, styledSpan(r, frag.text, frag.style))
        r.appendChild(fragNode, content)
        r.appendChild(lineNode, fragNode)
      r.appendChild(pre, lineNode)

  # The screen view and its scrubber.
  createRenderEffect proc() =
    let offered = vm.screenOffered.val
    let shown = vm.view.val == tvScreen
    let n = vm.events.val.len
    let write = vm.shownWrite.val
    discard vm.scrubPreview.val
    r.clearChildren(grid)
    r.clearChildren(marks)
    r.clearChildren(label)
    if not offered or not shown or vm.screen.isNil:
      return
    let screen = vm.shownScreen()
    r.setAttribute(grid, "data-cols", $screen.cols)
    r.setAttribute(grid, "data-rows", $screen.rows)
    r.setAttribute(grid, "data-write", $write)
    for row in 0 ..< screen.rows:
      let rowNode = el(r, "div", "terminal-screen-row")
      r.setStyle(rowNode, "white-space", "pre")
      r.setStyle(rowNode, "height", "1.25em")
      for run in screen.screenRowRuns(row):
        r.appendChild(rowNode, styledSpan(r, run.text, run.attrs))
      r.appendChild(grid, rowNode)
    r.setAttribute(range, "max", $max(0, n - 1))
    setValue[R, N](r, range, $max(0, write))
    r.setAttribute(range, "value", $max(0, write))
    for m in vm.screen.marks:
      let mark = el(r, "span", "terminal-scrubber-mark")
      r.setAttribute(mark, "data-kind", $m.kind)
      r.setAttribute(mark, "data-write", $m.write)
      r.setAttribute(mark, "title", markTitle(m.kind) & " (write " &
                     $(m.write + 1) & ")")
      r.setStyle(mark, "left",
                 formatFloat(100.0 * fractionOfWrite(n, m.write), ffDecimal,
                             3) & "%")
      r.setStyle(mark, "position", "absolute")
      r.setStyle(mark, "width", "3px")
      r.setStyle(mark, "height", "8px")
      r.setStyle(mark, "background-color",
                 case m.kind
                 of smClear: "rgb(187,187,0)"
                 of smAltEnter: "rgb(0,187,187)"
                 of smAltLeave: "rgb(0,187,0)")
      r.appendChild(marks, mark)
    r.appendChild(label, r.createTextNode(scrubberLabel(vm)))
    fitGrid[R, N](r, viewport, grid)

  panel

# ---------------------------------------------------------------------------
# The browser's half
# ---------------------------------------------------------------------------

when defined(js):
  proc terminalPreOf(panel: JsObject): JsObject {.importjs:
    "(#.querySelector(':scope > pre') || null)".}
  proc setStyles(el: JsObject; name, value: cstring) {.importjs:
    "#.style.setProperty(#, #)".}
  proc firstLineHeight(el: JsObject): float {.importjs:
    "(function(e){const l=e.querySelector('.terminal-line');return l ? l.getBoundingClientRect().height : 0;})(#)".}
  proc scrollTopOf(el: JsObject): float {.importjs: "#.scrollTop".}
  proc clientHeightOf(el: JsObject): float {.importjs: "#.clientHeight".}
  proc onScrollOrResize(el: JsObject; cb: proc()) {.importjs: """
    (function(e, cb) {
      e.addEventListener('scroll', function() { cb(); }, {passive: true});
      if (typeof ResizeObserver === 'function')
        new ResizeObserver(function() { cb(); }).observe(e);
    })(#, #)""".}

  const FallbackLineHeightPx = 18.0
    ## A line's height before one is drawn to measure.
  const
    LinesAboveProperty = cstring"--ct-terminal-lines-above"
      ## The height of the lines above the held window (`terminal.styl`
      ## draws it as the line view's `::before`).
    LinesBelowProperty = cstring"--ct-terminal-lines-below"
      ## The height of the lines below it (the `::after`).

  proc decorateTerminalOutput*(panel: isonim_dom.Element;
                               vm: TerminalOutputVM) =
    ## The line view's layout and its scrubbers. PLAT-51 (left by PLAT-52 to
    ## here): THE LINE VIEW'S SCROLLBAR IS A SCRUBBER over every line of the
    ## output (Scrollbar-Scrubbers.md §2), as it is on the terminal and GPUI.
    ## The lines' `pre` is the scroll container; the panel is a column so it
    ## fills what the toggle leaves. The lines it shows are reported by its
    ## host (`ui/panel_host`), or by `mountIsoNimTerminalOutput`.
    let p = cast[JsObject](panel)
    let pre = terminalPreOf(p)
    if pre.isNil:
      return
    setStyles(p, "display", "flex")
    setStyles(p, "flex-direction", "column")
    setStyles(pre, "flex", "1 1 auto")
    setStyles(pre, "min-height", "0")
    setStyles(pre, "overflow-y", "auto")
    proc lineHeight(): float =
      let h = firstLineHeight(pre)
      if h > 0.0: h else: FallbackLineHeightPx
    discard attachListScrubber(pre, p,
      total = proc(): int = vm.lineCount(),
      current = proc(): int = vm.currentLine(),
      rowHeight = lineHeight,
      paneId = "terminalOutput")
    # The held window sits at its own place in the output: the `pre` holds
    # SPACERS as tall as the lines above and below it, so its scroll range
    # is every line's. They are its `::before` / `::after` (`terminal.styl`),
    # sized by two custom properties — not padding: a box is never shorter
    # than its padding, so a padded `pre` grew past the panel whenever the
    # lines it did not hold were taller than the pane, the panel's flex
    # could not shrink it, and the press at the scrubber's end landed below
    # the window (measured: the `pre` alternating between 613 and 1992 px in
    # a 629 px panel as the window refilled). Content is what a scroll range
    # is made of; a spacer is content, and the flex shrinks the box around it.
    createEffect proc() =
      let held = vm.lines.val.len
      let start = vm.linesStart.val
      let total = vm.lineCount()
      let h = lineHeight()
      if vm.windowed:
        setStyles(pre, LinesAboveProperty, cstring($(float(start) * h) & "px"))
        setStyles(pre, LinesBelowProperty,
                  cstring($(float(max(0, total - start - held)) * h) & "px"))
      else:
        setStyles(pre, LinesAboveProperty, "0px")
        setStyles(pre, LinesBelowProperty, "0px")
    # PLAT-70 (Horizontal-Overflow.md §4): the line view's overflow-only
    # horizontal bar, under the lines, the corner left to neither track.
    discard attachHorizontalScrubber(pre, p, paneId = "terminalOutput",
                                     verticalTrack = true)

  proc mountIsoNimTerminalOutput*(container: isonim_dom.Element;
                                  vm: TerminalOutputVM) =
    ## Mount the panel as a child of ``container`` — for the VS Code
    ## extension's webview, which is not the panel host, so this also
    ## reports the lines it shows (Viewport-Driven-Loading Q3): the visible
    ## lines and the first of them, from the `pre`'s size and scroll.
    let r = WebRenderer()
    let panel = renderTerminalOutputPanel[WebRenderer, isonim_dom.Element](r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    decorateTerminalOutput(panel, vm)
    let pre = terminalPreOf(cast[JsObject](panel))
    if pre.isNil:
      return
    proc report() =
      let fh = firstLineHeight(pre)
      let h = if fh > 0.0: fh else: FallbackLineHeightPx
      let height = clientHeightOf(pre)
      vm.setViewport(Viewport(
        rows: (if height <= 0.0: 0 else: int(ceil(height / h))),
        firstRow: int(floor(scrollTopOf(pre) / h))))
    onScrollOrResize(pre, report)
    report()
