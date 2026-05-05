## views/isonim_step_list_view.nim
##
## IsoNim DOM-rendering view for the Step List panel.
##
## Renders a live, reactive DOM tree driven by ``StepListVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/step_list.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy view's class hooks so any CSS
## styling and DOM-based tests keep working::
##
##   div.step-list
##     div.step-list-lines-box
##       div.step-lines
##         div.step-line[.active-step-line]               Line rows
##           span.step-line-column.step-line-delta        text "<delta>"
##           span.step-line-column.step-line-location     text "<file>:<line>[<fn>]"
##           span.step-line-column.step-line-source-code
##             pre.step-line-pre[.active-step-line-pre|.inactive-step-line-pre]
##               code   text "<source>"
##           span.step-line-column.step-line-flow-values
##             span.step-line-flow-value (one per value)
##               span.step-line-flow-value-expression
##                 text "<expr>"
##               span.step-line-flow-value-repr
##                 text "<value>"
##         div.step-line.step-line-call                   Call rows
##           span.step-line-description.step-line-call-description
##             text "<source>"
##           span.step-line-args
##             span.step-line-value
##               span.step-line-value-expression
##                 text "<expr>"
##               span.step-line-value-repr
##                 text "<value>"
##         div.step-line.step-line-return                 Return rows
##           span.step-line-description.step-line-return-description
##             text "<source>"
##           span.step-line-return-value (only when values.len > 0)
##             span.step-line-return-value-expression
##               text "<values[0].expression>"
##             span.step-line-return-value-repr
##               text "<values[0].value>"
##
## Reactive surface: a single outer ``createRenderEffect`` rebuilds the
## ``.step-lines`` body whenever ``vm.lineSteps`` or
## ``vm.currentLocation`` changes.  ``isCurrentRow`` (in
## ``viewmodels/step_list_vm.nim``) drives the ``active-step-line``
## modifier on Line rows — same triple-equality the legacy view used
## (``rrTicks`` + ``path`` + ``line``).  Click handlers on Line rows
## dispatch ``StepListVM.jumpToStepLine`` so the live debugger
## advances to the corresponding step.

import std/os

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/step_list_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc deltaText(line: StepLine): string =
  ## Mirrors the legacy ``text $lineStep.delta`` rendering inside the
  ## ``.step-line-delta`` span.
  $line.delta

proc locationText(loc: StepLineLocation): string =
  ## Mirrors the legacy ``"{filename}:{line}[{functionName}]"`` label
  ## (``filename = path.extractFilename``) rendered inside the
  ## ``.step-line-location`` span.
  let filename = loc.path.extractFilename()
  filename & ":" & $loc.line & "[" & loc.functionName & "]"

proc preClasses(isCurrent: bool): string =
  ## ``active-step-line-pre`` vs. ``inactive-step-line-pre`` — same
  ## branching the legacy view used for the ``<pre>`` wrapping the
  ## source-code text.
  if isCurrent: "active-step-line-pre step-line-pre"
  else: "inactive-step-line-pre step-line-pre"

proc rowClass(isCurrent: bool): string =
  ## Outer ``.step-line`` modifier applied to Line rows.  The legacy
  ## view added ``"active-step-line"`` (note the leading space) when
  ## the row is current.  We mirror that exactly so any CSS rule keyed
  ## on either class still applies.
  if isCurrent: "step-line active-step-line"
  else: "step-line"

proc onLineClick(vm: StepListVM; line: StepLine): proc() =
  ## Closure factory so each row captures its own ``StepLine`` value.
  ## Without this the loop variable would be shared across all click
  ## handlers (same DSL closure-sharing concern as the search-results
  ## and errors views).
  let captured = line
  result = proc() = vm.jumpToStepLine(captured)

template renderLineRow(r, vm, line, isCurrent: untyped): untyped =
  ui(r):
    tdiv(class = rowClass(isCurrent),
         onclick = onLineClick(vm, line)):
      span(class = "step-line-column step-line-delta"):
        text deltaText(line)
      span(class = "step-line-column step-line-location"):
        text locationText(line.location)
      span(class = "step-line-column step-line-source-code"):
        pre(class = preClasses(isCurrent)):
          code:
            text line.sourceLine
      span(class = "step-line-column step-line-flow-values"):
        for valueIndex in 0 ..< line.values.len:
          let fv = line.values[valueIndex]
          span(class = "step-line-flow-value"):
            span(class = "step-line-flow-value-expression"):
              text fv.expression
            span(class = "step-line-flow-value-repr"):
              text fv.value

template renderCallRow(r, line: untyped): untyped =
  ui(r):
    tdiv(class = "step-line step-line-call"):
      span(class = "step-line-description step-line-call-description"):
        text line.sourceLine
      span(class = "step-line-args"):
        for valueIndex in 0 ..< line.values.len:
          let arg = line.values[valueIndex]
          span(class = "step-line-value"):
            span(class = "step-line-value-expression"):
              text arg.expression
            span(class = "step-line-value-repr"):
              text arg.value

template renderReturnRow(r, line: untyped): untyped =
  ui(r):
    tdiv(class = "step-line step-line-return"):
      span(class = "step-line-description step-line-return-description"):
        text line.sourceLine
      if line.values.len > 0:
        let arg = line.values[0]
        span(class = "step-line-return-value"):
          span(class = "step-line-return-value-expression"):
            text arg.expression
          span(class = "step-line-return-value-repr"):
            text arg.value

template renderStepListShell(r, linesContainer: untyped): untyped =
  ui(r):
    tdiv(class = "step-list"):
      tdiv(class = "step-list-lines-box"):
        tdiv(ref = linesContainer, class = "step-lines"):
          discard

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderStepListPanel*(r: MockRenderer; vm: StepListVM): MockNode =
  ## Render the Step List panel for the Mock renderer.
  var linesContainer: MockNode

  let panel = renderStepListShell(r, linesContainer)

  createRenderEffect proc() =
    let lines = vm.lineSteps.val
    let loc = vm.currentLocation.val
    r.clearChildren(linesContainer)
    for lineIndex in 0 ..< lines.len:
      let line = lines[lineIndex]
      let row = case line.kind
        of slkLine:
          renderLineRow(r, vm, line, isCurrentRow(line, loc))
        of slkCall:
          renderCallRow(r, line)
        of slkReturn:
          renderReturnRow(r, line)
      r.appendChild(linesContainer, row)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderStepListPanel*(r: WebRenderer; vm: StepListVM): isonim_dom.Element =
    ## Render the Step List panel for the real DOM.
    var linesContainer: isonim_dom.Element

    let panel = renderStepListShell(r, linesContainer)

    createRenderEffect proc() =
      let lines = vm.lineSteps.val
      let loc = vm.currentLocation.val
      r.clearChildren(linesContainer)
      for lineIndex in 0 ..< lines.len:
        let line = lines[lineIndex]
        let row = case line.kind
          of slkLine:
            renderLineRow(r, vm, line, isCurrentRow(line, loc))
          of slkCall:
            renderCallRow(r, line)
          of slkReturn:
            renderReturnRow(r, line)
        r.appendChild(linesContainer, row)

    panel

  proc mountIsoNimStepList*(container: isonim_dom.Element;
                            vm: StepListVM) =
    ## Mount the IsoNim step-list panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderStepListPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
