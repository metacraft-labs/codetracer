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
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/build_vm

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

proc renderBuildPanel*(r: MockRenderer; vm: BuildVM): MockNode =
  ## Render the build panel for the Mock renderer.
  ##
  ## The header / controls section is built once via the DSL with
  ## reactive attributes (header class, label text, button modifiers).
  ## An outer ``createRenderEffect`` rebuilds the
  ## ``#build`` output container whenever ``vm.output`` changes — this
  ## is the same shape the ``isonim_terminal_output_view`` uses for the
  ## ``<pre>`` body, and lets per-line click handlers capture the
  ## right ``BuildOutputLine`` without leaking shared state.
  var outputContainer: MockNode

  let panel = ui(r):
    tdiv(class = "build-panel"):
      tdiv(class = headerClass(vm)):
        tdiv(class = "build-command-label"):
          text headerLabel(vm)
        tdiv(class = "build-header-controls"):
          tdiv(class = stopButtonClass(vm),
               title = "Stop build",
               onclick = proc() =
                 if vm.isRunning.val: vm.cancelBuild()):
            text "■"
          tdiv(class = "build-ctrl-btn build-clear-btn",
               title = "Clear build output",
               onclick = proc() = vm.clearOutput()):
            text "✕"
          tdiv(class = scrollButtonClass(vm),
               title = "Toggle auto-scroll",
               onclick = proc() = vm.toggleAutoScroll()):
            text "↓"
          tdiv(class = "build-duration",
               display = displayIf(vm.isRunning.val)):
            text vm.command.val
      tdiv(ref = outputContainer,
           id = "build",
           class = "build-output-container"):
        discard

  createRenderEffect proc() =
    let lines = vm.output.val
    r.clearChildren(outputContainer)
    for line in lines:
      # Capture loop-local value so DSL closures don't share state.
      let lineCopy = line
      let lineNode = ui(r):
        tdiv(class = lineClass(lineCopy)):
          text lineCopy.htmlText
      r.appendChild(outputContainer, lineNode)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderBuildPanel*(r: WebRenderer; vm: BuildVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  Uses ``innerHTML`` for each
    ## line because the legacy view inserts ANSI-decorated ``<span>``
    ## runs via Karax's ``verbatim``, and the page-object tests inspect
    ## the resulting ``build-stdout`` / ``build-stderr`` classes on the
    ## per-line div itself, not its children.
    var outputContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "build-panel isonim-build"):
        tdiv(class = headerClass(vm)):
          tdiv(class = "build-command-label"):
            text headerLabel(vm)
          tdiv(class = "build-header-controls"):
            tdiv(class = stopButtonClass(vm),
                 title = "Stop build",
                 onclick = proc() =
                   if vm.isRunning.val: vm.cancelBuild()):
              text "■"
            tdiv(class = "build-ctrl-btn build-clear-btn",
                 title = "Clear build output",
                 onclick = proc() = vm.clearOutput()):
              text "✕"
            tdiv(class = scrollButtonClass(vm),
                 title = "Toggle auto-scroll",
                 onclick = proc() = vm.toggleAutoScroll()):
              text "↓"
            tdiv(class = "build-duration",
                 display = displayIf(vm.isRunning.val)):
              text vm.command.val
        tdiv(ref = outputContainer,
             id = "build",
             class = "build-output-container"):
          discard

    createRenderEffect proc() =
      let lines = vm.output.val
      let autoScrollOn = vm.autoScroll.val
      # Tear down the previous body.  IsoNim's reactive root cleans up
      # the closures attached to the discarded line nodes.
      let containerAsNode = isonim_dom.Node(outputContainer)
      while not isonim_dom.isNodeNil(containerAsNode.firstChild):
        discard isonim_dom.removeChild(containerAsNode, containerAsNode.firstChild)
      for line in lines:
        let lineNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
        isonim_dom.setAttribute(lineNode, cstring"class", cstring(lineClass(line)))
        # innerHTML — the htmlText carries ANSI-decorated <span> runs
        # from ansi_up (legacy view used Karax's `verbatim`).
        lineNode.innerHTML = cstring(line.htmlText)
        isonim_dom.appendChild(isonim_dom.Node(outputContainer),
                               isonim_dom.Node(lineNode))
      # Auto-scroll: keep the latest line visible.  Mirrors the legacy
      # ``scrollBuildToBottom`` behaviour when the auto-scroll button
      # is on.  ``scrollHeight`` / ``scrollTop`` are not in IsoNim's
      # narrow ``Element`` surface, so we touch them via JS emit on the
      # element handle.
      if autoScrollOn:
        let containerJs = outputContainer
        {.emit: """if (`containerJs`) { `containerJs`.scrollTop = `containerJs`.scrollHeight; }""".}

    panel

  proc mountIsoNimBuild*(container: isonim_dom.Element; vm: BuildVM) =
    ## Mount the IsoNim build panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderBuildPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
