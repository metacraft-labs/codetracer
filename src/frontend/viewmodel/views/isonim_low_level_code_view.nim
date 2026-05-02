## views/isonim_low_level_code_view.nim
##
## IsoNim DOM-rendering view for the Low Level Code panel.
##
## Renders a live, reactive DOM tree driven by ``LowLevelCodeVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/low_level_code.nim`` (the IsoNim view is the single
## source of truth for the panel's outer DOM).  In production the
## actual asm-listing buffer is rendered by Monaco inside the editor
## sub-tree; this view exposes the parity-faithful container shell so
## existing CSS keeps applying and a fallback row list so headless
## tests can exercise the same data flow without Monaco.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy ``componentContainerClass(
## "low-level-code")`` layout::
##
##   div.component-container.low-level-code
##     div.low-level-code-error                            (when errorMessage.len > 0)
##       text "<errorMessage>"
##     div.low-level-code-address                          (when address > 0)
##       text "Originating address: 0x<hex>"
##     div.low-level-code-instructions
##       div.low-level-code-instruction[.active-instruction]   (one per row)
##         span.low-level-code-instruction-offset           text "<offset>" / "StepId(<offset>)"
##         span.low-level-code-instruction-name             text "<name>" / "<no instructions>"
##         span.low-level-code-instruction-args             text "<args>"
##         span.low-level-code-instruction-other            text "<other>"
##         span.low-level-code-instruction-source           text "<highLevelPath>:<highLevelLine>"   (when present)
##
## Reactive surface: a single outer ``createRenderEffect`` rebuilds
## the ``.low-level-code-instructions`` body whenever ``instructions``,
## ``activeOffset`` or ``noirProject`` change.  ``isActiveRow`` (in
## ``viewmodels/low_level_code_vm.nim``) drives the
## ``active-instruction`` modifier on rows — same offset-equality the
## legacy ``findHighlight`` used.  Click handlers on rows dispatch
## ``LowLevelCodeVM.jumpToInstruction``.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/low_level_code_vm

const LowLevelCodeContainerClass* = "component-container low-level-code"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "low-level-code")`` template produced (see
  ## ``frontend/renderer.nim::componentContainerClass`` — emits
  ## ``"component-container " & class``).  Exposed for headless tests
  ## so they assert against the exact class string without depending
  ## on the legacy template.

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc rowClass*(active: bool): string =
  ## Outer ``.low-level-code-instruction`` modifier for the active
  ## row.  Mirrors the legacy ``active-instruction`` CSS hook the
  ## Monaco view-zone applied for the highlighted offset.
  if active:
    "low-level-code-instruction active-instruction"
  else:
    "low-level-code-instruction"

proc addressText*(address: int): string =
  ## "Originating address: 0x..." formatting.  Mirrors the same line
  ## the no_source panel renders (see
  ## ``isonim_no_source_view.nim::renderAddressRow``).  ``address`` is
  ## treated as unsigned for hex formatting purposes.
  "Originating address: 0x" & toHex(address)

proc sourceCrossRef*(instr: LowLevelInstruction): string =
  ## ``<highLevelPath>:<highLevelLine>`` cross-reference text.
  ## Returns an empty string when no high-level mapping is available
  ## (``highLevelLine <= 0``); the row guards on this to suppress the
  ## span entirely (matching the legacy ``mapInstructions`` skip on
  ## missing line numbers).
  if instr.highLevelLine <= 0 or instr.highLevelPath.len == 0:
    ""
  else:
    instr.highLevelPath & ":" & $instr.highLevelLine

proc onInstructionClick(vm: LowLevelCodeVM;
                         instr: LowLevelInstruction): proc() =
  ## Closure factory so each row captures its own
  ## ``LowLevelInstruction`` value.  Without this the loop variable
  ## would be shared across all click handlers (same DSL closure-
  ## sharing concern as the search-results / step-list views).
  let captured = instr
  result = proc() = vm.jumpToInstruction(captured)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderInstructionRowMock(r: MockRenderer; vm: LowLevelCodeVM;
                              instr: LowLevelInstruction;
                              active: bool; noir: bool): MockNode =
  ## One asm-listing row.  Carries the offset / name / args / other
  ## column spans plus an optional source-cross-reference span.
  ## Click handler maps to ``vm.jumpToInstruction``.
  let onClick = onInstructionClick(vm, instr)
  let crossRef = sourceCrossRef(instr)
  let row = ui(r):
    tdiv(class = rowClass(active), onclick = onClick):
      span(class = "low-level-code-instruction-offset"):
        text formatOffset(instr, noir)
      span(class = "low-level-code-instruction-name"):
        text displayName(instr)
      span(class = "low-level-code-instruction-args"):
        text instr.args
      span(class = "low-level-code-instruction-other"):
        text instr.other
  if crossRef.len > 0:
    let crossSpan = ui(r):
      span(class = "low-level-code-instruction-source"):
        text crossRef
    r.appendChild(row, crossSpan)
  row

proc renderLowLevelCodePanel*(r: MockRenderer;
                              vm: LowLevelCodeVM): MockNode =
  ## Render the Low Level Code panel for the Mock renderer.
  ##
  ## The static shell (``.component-container.low-level-code``) is
  ## built once via the DSL.  Two outer ``createRenderEffect`` blocks
  ## handle dynamic content: one rebuilds the optional address /
  ## error overlays, the other rebuilds the row list whenever
  ## ``instructions`` / ``activeOffset`` / ``noirProject`` change.
  ## Using imperative MockRenderer ops inside the effects keeps the
  ## conditional DOM straightforward — the DSL cannot express
  ## ``if errorMessage.len > 0`` over a runtime signal.
  var headerContainer: MockNode
  var listContainer: MockNode

  let panel = ui(r):
    tdiv(class = LowLevelCodeContainerClass):
      tdiv(ref = headerContainer, class = "low-level-code-header"):
        discard
      tdiv(ref = listContainer, class = "low-level-code-instructions"):
        discard

  # Header overlays (error + address) — rebuilt whenever either
  # signal changes.  Both signals are read inside the effect so the
  # subscription edge is established for both.
  createRenderEffect proc() =
    let err = vm.errorMessage.val
    let addrVal = vm.address.val
    r.clearChildren(headerContainer)
    if err.len > 0:
      let errDiv = ui(r):
        tdiv(class = "low-level-code-error"):
          text err
      r.appendChild(headerContainer, errDiv)
    if addrVal > 0:
      let addrDiv = ui(r):
        tdiv(class = "low-level-code-address"):
          text addressText(addrVal)
      r.appendChild(headerContainer, addrDiv)

  # Instruction list — rebuilt whenever any of the row-affecting
  # signals change.
  createRenderEffect proc() =
    let instructions = vm.instructions.val
    let activeOffset = vm.activeOffset.val
    let noir = vm.noirProject.val
    r.clearChildren(listContainer)
    for instr in instructions:
      let active = isActiveRow(instr, activeOffset)
      let row = renderInstructionRowMock(r, vm, instr, active, noir)
      r.appendChild(listContainer, row)

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

  proc renderInstructionRowWeb(vm: LowLevelCodeVM;
                               instr: LowLevelInstruction;
                               active: bool; noir: bool): isonim_dom.Element =
    ## Build an asm-listing row in the real DOM.  Same shape as the
    ## Mock variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(active))

    let offsetSpan = createWebTextElement("span", formatOffset(instr, noir),
                                          "low-level-code-instruction-offset")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(offsetSpan))

    let nameSpan = createWebTextElement("span", displayName(instr),
                                         "low-level-code-instruction-name")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(nameSpan))

    let argsSpan = createWebTextElement("span", instr.args,
                                         "low-level-code-instruction-args")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(argsSpan))

    let otherSpan = createWebTextElement("span", instr.other,
                                          "low-level-code-instruction-other")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(otherSpan))

    let crossRef = sourceCrossRef(instr)
    if crossRef.len > 0:
      let crossSpan = createWebTextElement("span", crossRef,
                                            "low-level-code-instruction-source")
      isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(crossSpan))

    let handler = onInstructionClick(vm, instr)
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) = handler())
    row

  proc renderLowLevelCodePanel*(r: WebRenderer;
                                vm: LowLevelCodeVM): isonim_dom.Element =
    ## Render the Low Level Code panel for the real DOM.
    var headerContainer: isonim_dom.Element
    var listContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = LowLevelCodeContainerClass):
        tdiv(ref = headerContainer, class = "low-level-code-header"):
          discard
        tdiv(ref = listContainer, class = "low-level-code-instructions"):
          discard

    createRenderEffect proc() =
      let err = vm.errorMessage.val
      let addrVal = vm.address.val
      clearWebChildren(headerContainer)
      if err.len > 0:
        let errDiv = createWebTextElement("div", err,
                                           "low-level-code-error")
        isonim_dom.appendChild(isonim_dom.Node(headerContainer),
                               isonim_dom.Node(errDiv))
      if addrVal > 0:
        let addrDiv = createWebTextElement("div", addressText(addrVal),
                                            "low-level-code-address")
        isonim_dom.appendChild(isonim_dom.Node(headerContainer),
                               isonim_dom.Node(addrDiv))

    createRenderEffect proc() =
      let instructions = vm.instructions.val
      let activeOffset = vm.activeOffset.val
      let noir = vm.noirProject.val
      clearWebChildren(listContainer)
      for instr in instructions:
        let active = isActiveRow(instr, activeOffset)
        let row = renderInstructionRowWeb(vm, instr, active, noir)
        isonim_dom.appendChild(isonim_dom.Node(listContainer),
                               isonim_dom.Node(row))

    panel

  proc mountIsoNimLowLevelCode*(container: isonim_dom.Element;
                                vm: LowLevelCodeVM) =
    ## Mount the IsoNim low-level-code panel as a child of
    ## ``container``.  Reactive effects handle every subsequent
    ## update — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderLowLevelCodePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
