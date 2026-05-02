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

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderLineRowMock(r: MockRenderer; vm: StepListVM;
                       line: StepLine; isCurrent: bool): MockNode =
  ## One ``Line`` row.  Carries the source-line text inside
  ## ``<pre><code>`` plus the inline flow values.  Click handler maps
  ## to ``vm.jumpToStepLine``.
  let onClick = onLineClick(vm, line)
  let panel = ui(r):
    tdiv(class = rowClass(isCurrent), onclick = onClick):
      span(class = "step-line-column step-line-delta"):
        text deltaText(line)
      span(class = "step-line-column step-line-location"):
        text locationText(line.location)
      span(class = "step-line-column step-line-source-code"):
        pre(class = preClasses(isCurrent)):
          code:
            text line.sourceLine
      span(class = "step-line-column step-line-flow-values"):
        discard
  # Append flow-value spans imperatively because the count is dynamic
  # and the DSL macro cannot iterate over a runtime ``seq`` directly.
  # Index into the seq (rather than ``for fv in line.values``) so the
  # captured value is a plain copy — Nim 2's iterator yields a
  # ``lent StepLineFlowValue`` which cannot be captured by the closure
  # the ``text`` helper records.
  let flowsSpan = panel.children[^1]
  for i in 0 ..< line.values.len:
    let fv = line.values[i]
    let entry = ui(r):
      span(class = "step-line-flow-value"):
        span(class = "step-line-flow-value-expression"):
          text fv.expression
        span(class = "step-line-flow-value-repr"):
          text fv.value
    r.appendChild(flowsSpan, entry)
  panel

proc renderCallRowMock(r: MockRenderer; vm: StepListVM;
                       line: StepLine): MockNode =
  ## One ``Call`` row.  Renders the description text (the call site
  ## source line) plus a list of ``arg = repr`` pairs.
  let panel = ui(r):
    tdiv(class = "step-line step-line-call"):
      span(class = "step-line-description step-line-call-description"):
        text line.sourceLine
      span(class = "step-line-args"):
        discard
  let argsSpan = panel.children[^1]
  for i in 0 ..< line.values.len:
    let arg = line.values[i]
    let entry = ui(r):
      span(class = "step-line-value"):
        span(class = "step-line-value-expression"):
          text arg.expression
        span(class = "step-line-value-repr"):
          text arg.value
    r.appendChild(argsSpan, entry)
  panel

proc renderReturnRowMock(r: MockRenderer; vm: StepListVM;
                         line: StepLine): MockNode =
  ## One ``Return`` row.  Same description shape as ``Call`` but only
  ## the first ``values`` entry is rendered, mirroring the legacy
  ## ``if lineStep.values.len > 0: ... text values[0].expression`` guard.
  let panel = ui(r):
    tdiv(class = "step-line step-line-return"):
      span(class = "step-line-description step-line-return-description"):
        text line.sourceLine
  if line.values.len > 0:
    let arg = line.values[0]
    let retSpan = ui(r):
      span(class = "step-line-return-value"):
        span(class = "step-line-return-value-expression"):
          text arg.expression
        span(class = "step-line-return-value-repr"):
          text arg.value
    r.appendChild(panel, retSpan)
  panel

proc renderStepListPanel*(r: MockRenderer; vm: StepListVM): MockNode =
  ## Render the Step List panel for the Mock renderer.
  ##
  ## The static shell (``.step-list`` + ``.step-list-lines-box`` + the
  ## inner ``.step-lines`` container) is built once via the DSL.  An
  ## outer ``createRenderEffect`` rebuilds the row list whenever
  ## ``vm.lineSteps`` or ``vm.currentLocation`` changes.  Using
  ## imperative MockRenderer ops inside the effect keeps the dynamic
  ## dispatch over the three row variants straightforward — the DSL
  ## cannot express ``case lineStep.kind`` over a runtime list.
  var linesContainer: MockNode

  let panel = ui(r):
    tdiv(class = "step-list"):
      tdiv(class = "step-list-lines-box"):
        tdiv(ref = linesContainer, class = "step-lines"):
          discard

  createRenderEffect proc() =
    let lines = vm.lineSteps.val
    let loc = vm.currentLocation.val
    r.clearChildren(linesContainer)
    for line in lines:
      let row = case line.kind
        of slkLine:
          renderLineRowMock(r, vm, line, isCurrentRow(line, loc))
        of slkCall:
          renderCallRowMock(r, vm, line)
        of slkReturn:
          renderReturnRowMock(r, vm, line)
      r.appendChild(linesContainer, row)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element with an optional class attribute.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    n

  proc createWebTextElement(tag: string; textValue: string;
                            cssClass: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element + a text-node child in one shot.
    let n = createWebElement(tag, cssClass)
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderLineRowWeb(vm: StepListVM; line: StepLine;
                        isCurrent: bool): isonim_dom.Element =
    ## Build a Line row in the real DOM.  Same shape as the Mock
    ## variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(isCurrent))

    let deltaSpan = createWebTextElement("span", deltaText(line),
                                          "step-line-column step-line-delta")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(deltaSpan))

    let locSpan = createWebTextElement("span", locationText(line.location),
                                        "step-line-column step-line-location")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(locSpan))

    let srcSpan = createWebElement("span",
                                   "step-line-column step-line-source-code")
    let preEl = createWebElement("pre", preClasses(isCurrent))
    let codeEl = createWebTextElement("code", line.sourceLine)
    isonim_dom.appendChild(isonim_dom.Node(preEl), isonim_dom.Node(codeEl))
    isonim_dom.appendChild(isonim_dom.Node(srcSpan), isonim_dom.Node(preEl))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(srcSpan))

    let flowsSpan = createWebElement("span",
                                     "step-line-column step-line-flow-values")
    for fv in line.values:
      let entry = createWebElement("span", "step-line-flow-value")
      let exprSpan = createWebTextElement("span", fv.expression,
                                          "step-line-flow-value-expression")
      let reprSpan = createWebTextElement("span", fv.value,
                                          "step-line-flow-value-repr")
      isonim_dom.appendChild(isonim_dom.Node(entry), isonim_dom.Node(exprSpan))
      isonim_dom.appendChild(isonim_dom.Node(entry), isonim_dom.Node(reprSpan))
      isonim_dom.appendChild(isonim_dom.Node(flowsSpan), isonim_dom.Node(entry))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(flowsSpan))

    let handler = onLineClick(vm, line)
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) = handler())
    row

  proc renderCallRowWeb(vm: StepListVM;
                        line: StepLine): isonim_dom.Element =
    ## Build a Call row in the real DOM.
    let row = createWebElement("div", "step-line step-line-call")
    let descSpan = createWebTextElement("span", line.sourceLine,
        "step-line-description step-line-call-description")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(descSpan))

    let argsSpan = createWebElement("span", "step-line-args")
    for arg in line.values:
      let entry = createWebElement("span", "step-line-value")
      let exprSpan = createWebTextElement("span", arg.expression,
                                           "step-line-value-expression")
      let reprSpan = createWebTextElement("span", arg.value,
                                           "step-line-value-repr")
      isonim_dom.appendChild(isonim_dom.Node(entry), isonim_dom.Node(exprSpan))
      isonim_dom.appendChild(isonim_dom.Node(entry), isonim_dom.Node(reprSpan))
      isonim_dom.appendChild(isonim_dom.Node(argsSpan), isonim_dom.Node(entry))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(argsSpan))
    row

  proc renderReturnRowWeb(vm: StepListVM;
                          line: StepLine): isonim_dom.Element =
    ## Build a Return row in the real DOM.
    let row = createWebElement("div", "step-line step-line-return")
    let descSpan = createWebTextElement("span", line.sourceLine,
        "step-line-description step-line-return-description")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(descSpan))
    if line.values.len > 0:
      let arg = line.values[0]
      let retSpan = createWebElement("span", "step-line-return-value")
      let exprSpan = createWebTextElement("span", arg.expression,
                                          "step-line-return-value-expression")
      let reprSpan = createWebTextElement("span", arg.value,
                                          "step-line-return-value-repr")
      isonim_dom.appendChild(isonim_dom.Node(retSpan), isonim_dom.Node(exprSpan))
      isonim_dom.appendChild(isonim_dom.Node(retSpan), isonim_dom.Node(reprSpan))
      isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(retSpan))
    row

  proc renderStepListPanel*(r: WebRenderer; vm: StepListVM): isonim_dom.Element =
    ## Render the Step List panel for the real DOM.
    var linesContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "step-list"):
        tdiv(class = "step-list-lines-box"):
          tdiv(ref = linesContainer, class = "step-lines"):
            discard

    createRenderEffect proc() =
      let lines = vm.lineSteps.val
      let loc = vm.currentLocation.val
      clearWebChildren(linesContainer)
      for line in lines:
        let row = case line.kind
          of slkLine:
            renderLineRowWeb(vm, line, isCurrentRow(line, loc))
          of slkCall:
            renderCallRowWeb(vm, line)
          of slkReturn:
            renderReturnRowWeb(vm, line)
        isonim_dom.appendChild(isonim_dom.Node(linesContainer),
                               isonim_dom.Node(row))

    panel

  proc mountIsoNimStepList*(container: isonim_dom.Element;
                            vm: StepListVM) =
    ## Mount the IsoNim step-list panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderStepListPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
