## views/isonim_terminal_output_view.nim
##
## IsoNim DOM-rendering view for the Terminal Output panel.
##
## Renders a live, reactive DOM tree driven by ``TerminalOutputVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/terminal_output.nim`` (the IsoNim view is the single
## source of truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure; the per-fragment text body differs only in how the HTML
## body is set:
## - Mock: the fragment's ``htmlText`` lands as ``textContent`` so
##   headless tests can assert text equality directly.
## - Web: the same string lands as ``innerHTML`` because the legacy
##   Karax view used ``verbatim`` to insert ANSI-decorated ``<span>``
##   runs from the ``ansi_up`` library.
##
## Structure (per the Playwright contract in
## ``src/tests/gui/page-objects/panes/terminal/terminal-output-pane.ts``)::
##
##   div.component-container.terminal[.isonim-terminal-output]
##     pre
##       div.terminal-line#terminal-line-{lineIndex}
##         div.{past|active|future}                ← fragment, click → jumpToEvent
##           [innerHTML / textContent = fragment.htmlText]
##       div.empty-overlay[display reactive]
##         text "Loading..." | "no terminal output ..."
##
## The ``<pre>`` body is reactive: an outer ``createRenderEffect``
## tears it down and rebuilds it from the latest signal values
## whenever ``vm.lines`` or ``vm.currentRRTicks`` changes.  The
## per-line / per-fragment loops are nested inside the same effect so
## colour classes track the debugger position automatically — the
## legacy code achieved the same outcome via a full ``redraw()``
## after every ``CtCompleteMove`` event.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/terminal_output_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  ## ``block``-style display toggling for the empty-overlay div.
  ## Keeps the overlay on its own row so the Loading / empty text
  ## sits where the legacy Karax view placed it.
  if cond: "block" else: "none"

proc emptyOverlayVisible(vm: TerminalOutputVM): bool =
  ## Empty overlay is shown whenever there are no rendered lines —
  ## both during the initial pre-load and after a load that produced
  ## no terminal output.  The text content distinguishes the two
  ## states reactively (see ``emptyOverlayText``).
  vm.lines.val.len == 0

proc emptyOverlayText(vm: TerminalOutputVM): string =
  ## "Loading record output..." while ``initialLoad`` is true; the
  ## post-load fallback otherwise.  Matches the strings the legacy
  ## Karax view emits so any tests that scrape the overlay text keep
  ## working.
  if vm.initialLoad.val:
    "Loading record output..."
  else:
    "The current record does not print anything to the terminal."

proc fragmentClass(focusRRTicks, fragRRTicks: uint64): string =
  ## past / active / future based on the debugger's current position.
  ## Mirrors ``terminalEventView`` in the legacy view.  Pure helper so
  ## both renderers share the comparison.
  if fragRRTicks < focusRRTicks: "past"
  elif fragRRTicks == focusRRTicks: "active"
  else: "future"

proc onFragmentClick(vm: TerminalOutputVM; eventIndex: int): proc() =
  ## Closure factory so each fragment captures its own event index.
  let idx = eventIndex
  result = proc() = vm.jumpToEvent(idx)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderTerminalOutputPanel*(r: MockRenderer;
                                vm: TerminalOutputVM): MockNode =
  ## Render the terminal output panel for the Mock renderer.
  ##
  ## The panel shell is built once via the DSL; an outer
  ## ``createRenderEffect`` rebuilds the ``<pre>`` body whenever the
  ## lines signal or the current rrTicks signal changes.  That keeps
  ## fragment colour classes in sync with the debugger position
  ## without needing a separate per-fragment effect.
  var preNode: MockNode

  let panel = ui(r):
    tdiv(class = "component-container terminal"):
      pre(ref = preNode):
        discard
      tdiv(class = "empty-overlay",
           display = displayIf(emptyOverlayVisible(vm))):
        text emptyOverlayText(vm)

  createRenderEffect proc() =
    let lines = vm.lines.val
    let focus = vm.currentRRTicks.val
    r.clearChildren(preNode)
    for line in lines:
      # Capture loop locals so DSL closures don't share state.
      let lineIdx = line.lineIndex
      let lineNode = ui(r):
        tdiv(class = "terminal-line",
             id = "terminal-line-" & $lineIdx):
          discard
      r.appendChild(preNode, lineNode)
      for frag in line.fragments:
        let fragText = frag.htmlText
        let fragRRTicks = frag.rrTicks
        let onClick = onFragmentClick(vm, frag.eventIndex)
        let fragNode = ui(r):
          tdiv(class = fragmentClass(focus, fragRRTicks),
               onclick = onClick):
            text fragText
        r.appendChild(lineNode, fragNode)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderTerminalOutputPanel*(r: WebRenderer;
                                  vm: TerminalOutputVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  Uses ``innerHTML`` for the
    ## fragment body because the legacy view inserts ANSI-decorated
    ## ``<span>`` runs via Karax's ``verbatim``, and the page-object
    ## tests inspect the resulting CSS classes (.past/.active/.future)
    ## on the fragment ``div`` itself, not its children.
    var preNode: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "component-container terminal isonim-terminal-output"):
        pre(ref = preNode):
          discard
        tdiv(class = "empty-overlay",
             display = displayIf(emptyOverlayVisible(vm))):
          text emptyOverlayText(vm)

    createRenderEffect proc() =
      let lines = vm.lines.val
      let focus = vm.currentRRTicks.val
      # Tear down the previous body.  IsoNim's reactive root cleans up
      # the closures attached to the discarded fragment nodes.
      let preNodeAsNode = isonim_dom.Node(preNode)
      while not isonim_dom.isNodeNil(preNodeAsNode.firstChild):
        discard isonim_dom.removeChild(preNodeAsNode, preNodeAsNode.firstChild)
      for line in lines:
        let lineNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
        isonim_dom.setAttribute(lineNode, cstring"class", cstring"terminal-line")
        isonim_dom.setAttribute(lineNode, cstring"id",
                                cstring("terminal-line-" & $line.lineIndex))
        for frag in line.fragments:
          let fragNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
          isonim_dom.setAttribute(fragNode, cstring"class",
                                  cstring(fragmentClass(focus, frag.rrTicks)))
          # innerHTML — the htmlText carries ANSI-decorated <span>
          # runs from ansi_up (legacy view used Karax's `verbatim`).
          fragNode.innerHTML = cstring(frag.htmlText)
          let handler = onFragmentClick(vm, frag.eventIndex)
          isonim_dom.addEventListener(isonim_dom.Node(fragNode), cstring"click",
                                      proc(ev: isonim_dom.Event) = handler())
          isonim_dom.appendChild(isonim_dom.Node(lineNode),
                                 isonim_dom.Node(fragNode))
        isonim_dom.appendChild(isonim_dom.Node(preNode),
                               isonim_dom.Node(lineNode))

    panel

  proc mountIsoNimTerminalOutput*(container: isonim_dom.Element;
                                  vm: TerminalOutputVM) =
    ## Mount the IsoNim terminal-output panel as a child of
    ## ``container``.  Reactive effects handle every subsequent
    ## update — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderTerminalOutputPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
