## views/isonim_build_view.nim
##
## IsoNim DOM-rendering view for the Build panel.
##
## Renders a live, reactive DOM tree driven by ``BuildVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/build.nim`` (the IsoNim view is the single source of
## truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure (matching the Playwright contract in
## ``src/tests/gui/page-objects/panes/build/build-pane.ts``):
##
##   div.build-panel
##     div.build-header[.build-failed | .build-succeeded]
##       div.build-command-label                              text reactive
##       div.build-header-controls
##         div.build-ctrl-btn.build-run-btn                   click→runBuild
##         div.build-ctrl-btn.build-stop-btn[.disabled]       click→cancelBuild
##         div.build-ctrl-btn.build-clear-btn                 click→clearOutput
##         div.build-ctrl-btn.build-scroll-btn[.active]       click→toggleAutoScroll
##         div.build-duration[display reactive]               text reactive
##     div#build.build-output-container
##       div.build-output-line.build-clickable.build-line-{severity}
##         (innerHTML / textContent = htmlText)              click→jumpToLocation
##       OR div.build-stdout / div.build-stderr
##         (innerHTML / textContent = htmlText)
##
## The output container body is reactive: an outer ``createRenderEffect``
## tears it down and rebuilds it from the latest signal values whenever
## ``vm.output`` changes.  The header text + classes update
## reactively via DSL attribute expressions because the macro emits
## per-attribute ``createRenderEffect``s automatically.
##
## On the Web renderer the per-line div uses ``innerHTML`` because the
## legacy view inserts ANSI-decorated ``<span>`` runs via Karax's
## ``verbatim``.  The Mock renderer uses ``textContent`` so headless
## tests can assert on the text directly.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/build_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  ## ``inline-block``-style display toggling for the duration counter.
  if cond: "inline-block" else: "none"

proc headerClass(vm: BuildVM): string =
  ## ``build-header`` plus an optional success / failure modifier.
  ## Mirrors the legacy ``method render`` cascade so that CSS hooks like
  ## ``.build-header.build-failed`` keep matching.
  case vm.status.val
  of bsFailed:    "build-header build-failed"
  of bsSucceeded: "build-header build-succeeded"
  else:           "build-header"

proc headerLabel(vm: BuildVM): string =
  ## Reactive header text: "running ...", "build succeeded", or
  ## "build failed (exit code N)".  When the panel is idle we render an
  ## empty string (the legacy view did the same), so the controls row
  ## stays accessible without a visible heading.
  case vm.status.val
  of bsRunning:   "running " & vm.command.val
  of bsSucceeded: "build succeeded"
  of bsFailed:    "build failed (exit code " & $vm.code.val & ")"
  of bsIdle:      ""

proc stopButtonClass(vm: BuildVM): string =
  ## Stop button is disabled when no build is running.  The legacy view
  ## always rendered the button but added a ``disabled`` modifier when
  ## idle; we keep the same behaviour to preserve the page-object
  ## locators.
  if vm.isRunning.val:
    "build-ctrl-btn build-stop-btn"
  else:
    "build-ctrl-btn build-stop-btn disabled"

proc scrollButtonClass(vm: BuildVM): string =
  ## Auto-scroll button gets an ``active`` modifier when sticky-bottom
  ## scrolling is on.  Matches the legacy CSS contract.
  if vm.autoScroll.val:
    "build-ctrl-btn build-scroll-btn active"
  else:
    "build-ctrl-btn build-scroll-btn"

proc lineClass(line: BuildOutputLine): string =
  ## CSS class for a single output line.  Lines with a parsed location
  ## get the ``build-clickable`` modifier plus a severity colour class;
  ## plain output uses ``build-stdout`` / ``build-stderr``.
  if line.locationPath.len > 0:
    let severity = case line.severity
                   of blsError:   "build-line-error"
                   of blsWarning: "build-line-warning"
                   of blsInfo:    "build-line-info"
                   of blsNone:    ""
    if severity.len > 0:
      "build-output-line build-clickable " & severity
    else:
      "build-output-line build-clickable"
  elif line.isStdout:
    "build-stdout"
  else:
    "build-stderr"

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc lineJumpHandler(vm: BuildVM; line: BuildOutputLine): proc() =
  ## The click handler of one output row: open the location `line` names.
  ##
  ## A FACTORY, because the rows are built in a `for` loop and Nim closures
  ## capture by reference: a `let` in the loop body (or the loop variable) is
  ## ONE variable for the whole loop, so an inline `proc() = vm.jumpToLine(x)`
  ## made every row open the LAST row's location (codetracer#860 sweep;
  ## https://nim-lang.org/docs/manual.html#procedures-closures). `line` is
  ## this call's own parameter, so each row's closure owns its value.
  result = proc() = vm.jumpToLine(line)

proc renderPlainOutput[R, N](r: R; vm: BuildVM; outputContainer: N) =
  ## The output rows as text, rebuilt whenever ``vm.output`` changes — every
  ## renderer but the browser's, which decorates them (`renderBuildPanel`).
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild
  createRenderEffect proc() =
    let lines = vm.output.val
    r.clearChildren(outputContainer)
    for line in lines:
      # Copied out of the iterator: the DSL's attribute closures cannot
      # capture a `lent` value. The click goes through `lineJumpHandler`,
      # NOT a closure over this copy -- see that proc for why.
      let lineCopy = line
      let lineNode = ui(r):
        tdiv(class = lineClass(lineCopy),
             onclick = lineJumpHandler(vm, lineCopy)):
          text lineCopy.htmlText
      r.appendChild(outputContainer, lineNode)

when defined(js):
  import std/jsffi
  import ./list_scrubber_dom

  proc buildSetTimeout(fn: proc(); ms: int) {.importjs: "setTimeout(#, #)".}
  proc scrollToBottom(node: isonim_dom.Element) {.importjs: "(function(node) { if (node) { node.scrollTop = node.scrollHeight; } })(#)".}
  proc outputContainerOf(panel: JsObject): JsObject {.importjs:
    "(#.querySelector('.build-output-container') || null)".}

  proc lineClickListener(vm: BuildVM;
                         line: BuildOutputLine): proc(ev: isonim_dom.Event) =
    ## `lineJumpHandler` in the shape a DOM listener takes: per row, for the
    ## same reason.
    let jump = lineJumpHandler(vm, line)
    result = proc(ev: isonim_dom.Event) = jump()


proc renderBuildPanel*[R, N](r: R; vm: BuildVM): N =
  ## The build panel, under any renderer (Shared-DOM-Front-Ends D3), mounted
  ## on the desktop by `ui/panel_host`.
  ##
  ## The header and controls are built once with reactive attributes. An
  ## effect rebuilds the ``#build`` output container whenever ``vm.output``
  ## changes. In a browser each line's ``innerHTML`` carries the
  ## ANSI-decorated ``<span>`` runs (the legacy view used Karax's
  ## ``verbatim``; the page objects read the ``build-stdout`` /
  ## ``build-stderr`` classes on the line itself), a located line opens its
  ## location on click, the output follows ``vm.autoScroll``, and the
  ## output's horizontal bar is the shared scrubber (PLAT-70,
  ## Horizontal-Overflow.md §4).
  var outputContainer: N

  let panel = ui(r):
    tdiv(class = "build-panel isonim-build"):
      tdiv(class = headerClass(vm)):
        tdiv(class = "build-command-label"):
          text headerLabel(vm)
        tdiv(class = "build-header-controls"):
          tdiv(class = "build-ctrl-btn build-run-btn",
               title = "Run build (no re-record)",
               onclick = proc() =
                 if not vm.runBuild.isNil: vm.runBuild()):
            discard
          tdiv(class = stopButtonClass(vm),
               title = "Stop build",
               onclick = proc() =
                 if vm.isRunning.val: vm.cancelBuild()):
            discard
          tdiv(class = "build-ctrl-btn build-clear-btn",
               title = "Clear build output",
               onclick = proc() = vm.clearOutput()):
            discard
          tdiv(class = scrollButtonClass(vm),
               title = "Toggle auto-scroll",
               onclick = proc() = vm.toggleAutoScroll()):
            discard
          tdiv(class = "build-duration",
               display = displayIf(vm.isRunning.val)):
            text vm.command.val
      tdiv(ref = outputContainer,
           id = "build",
           class = "build-output-container"):
        discard

  when defined(js):
    when N is isonim_dom.Element:
      createRenderEffect proc() =
        let lines = vm.output.val
        let autoScrollOn = vm.autoScroll.val
        # Tear down the previous body.  IsoNim's reactive root cleans up
        # the closures attached to the discarded line nodes.
        let containerAsNode = isonim_dom.Node(outputContainer)
        while not isonim_dom.isNodeNil(containerAsNode.firstChild):
          discard isonim_dom.removeChild(containerAsNode, containerAsNode.firstChild)
        for line in lines:
          let lineCopy = line
          let lineNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
          isonim_dom.setAttribute(lineNode, cstring"class", cstring(lineClass(lineCopy)))
          # innerHTML — the htmlText carries ANSI-decorated <span> runs
          # from ansi_up (legacy view used Karax's `verbatim`).
          lineNode.innerHTML = cstring(lineCopy.htmlText)
          # THE CLICK THE HEADER HAS ALWAYS DOCUMENTED. `build-clickable` and
          # its `cursor: pointer` have been on these rows since the Karax
          # migration dropped the handler; this is the handler.
          if lineCopy.locationPath.len > 0 and lineCopy.locationLine > 0:
            # A per-row factory, not an inline closure over `lineCopy` (one
            # variable for the whole loop): see `lineJumpHandler`.
            isonim_dom.addEventListener(isonim_dom.Node(lineNode), cstring"click",
              lineClickListener(vm, lineCopy))
          isonim_dom.appendChild(isonim_dom.Node(outputContainer),
                                 isonim_dom.Node(lineNode))
        if autoScrollOn:
          outputContainer.scrollToBottom()

      # Attached once the panel is in the document.
      let panelEl = panel
      buildSetTimeout(proc() =
        let output = outputContainerOf(cast[JsObject](panelEl))
        if not output.isNil:
          discard attachHorizontalScrubber(output, cast[JsObject](panelEl),
                                           paneId = "buildOutput")
      , 0)
    else:
      renderPlainOutput[R, N](r, vm, outputContainer)
  else:
    renderPlainOutput[R, N](r, vm, outputContainer)


  panel
