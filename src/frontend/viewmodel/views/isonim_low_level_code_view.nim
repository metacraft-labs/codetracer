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

# ---------------------------------------------------------------------------
# Anchoring, rendered.
#
# `Generated-Code-Listing.md` GCL-F1 recorded the defect these exist to fix: the
# anchoring model was complete and correct, with 336 counted assertions behind
# it, and NOTHING IN THIS FILE READ ANY OF IT. A grep for `anchors`,
# `syncSettings`, `fidelityAtRow`, `countLabel` and eight siblings across `src/`
# returned only the two unit suites. A capability that is present, correct and
# unreachable is indistinguishable from one that was never built.
# ---------------------------------------------------------------------------

proc fidelityClass*(f: MappingFidelity): string =
  ## Per-row badge class. §4's table is a claim about each row, so it is
  ## rendered per row rather than summarised — a listing whose rows all look
  ## alike cannot show that its middle is exact and its tail is unmapped.
  "low-level-code-instruction-fidelity fidelity-" & label(f).replace(" ", "-")

proc syncToggleLabel*(enabled: bool): string =
  ## §3: "unlocking is a deliberate act with a visible state". This IS the
  ## visible state.
  if enabled: "sync on" else: "sync off"

proc syncToggleClass*(enabled: bool): string =
  "low-level-code-sync " & (if enabled: "sync-on" else: "sync-off")

proc mappingNotice*(vm: LowLevelCodeVM): string =
  ## The one line that says why synchronisation is not going to align, or "" if
  ## nothing is wrong.
  ##
  ## THE THREE CASES ARE DELIBERATELY NOT COLLAPSED. `soDisabled` and
  ## `soSuspended` are distinct outcomes in the model precisely because "you
  ## turned it off" and "the mapping ran out here" are different things to show,
  ## and a REFUSED mapping is a third: `anchorsRejected` is not `not hasAnchors`,
  ## because an artefact with no debug info and a producer whose output was
  ## rejected both leave the anchor list empty and must not look the same.
  if not vm.syncSettings.val.enabled:
    return "synchronisation is off"
  if vm.anchorsRejected.val:
    let defects = vm.anchorDefects.val
    return "the mapping for this artefact was refused (" & $defects.len &
      (if defects.len == 1: " defect); " else: " defects); ") &
      "synchronisation suspended"
  if not vm.hasAnchors.val and vm.instructions.val.len > 0:
    return "no source mapping for this artefact; synchronisation suspended"
  ""

proc noticeClass*(vm: LowLevelCodeVM): string =
  ## The class differs with the CAUSE, not merely with presence, so a
  ## screenshot can tell the three apart and so can a test.
  if not vm.syncSettings.val.enabled:
    "low-level-code-notice notice-disabled"
  elif vm.anchorsRejected.val:
    "low-level-code-notice notice-refused"
  elif not vm.hasAnchors.val and vm.instructions.val.len > 0:
    "low-level-code-notice notice-suspended"
  else:
    "low-level-code-notice hidden"

proc onSyncToggle(vm: LowLevelCodeVM): proc() =
  result = proc() = vm.setSyncEnabled(not vm.syncSettings.val.enabled)

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
                              active: bool; noir: bool;
                              fidelity: MappingFidelity;
                              count: ExecutedCount): MockNode =
  ## One asm-listing row.  Carries the offset / name / args / other
  ## column spans plus an optional source-cross-reference span.
  ## Click handler maps to ``vm.jumpToInstruction``.
  let onClick = onInstructionClick(vm, instr)
  let crossRef = sourceCrossRef(instr)
  let countText = countLabel(count)
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
      span(class = fidelityClass(fidelity)):
        text label(fidelity)
  if crossRef.len > 0:
    let crossSpan = ui(r):
      span(class = "low-level-code-instruction-source"):
        text crossRef
    r.appendChild(row, crossSpan)
  # NO COUNT COLUMN FOR `cpNone`, and that is the rule rather than an
  # optimisation: `countLabel` returns "" there, and a rendered `0` would read
  # as "never ran" — a measurement the pane did not make. See GCL-D3.
  if countText.len > 0:
    let countSpan = ui(r):
      span(class = "low-level-code-instruction-count"):
        text countText
    r.appendChild(row, countSpan)
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

  # Header overlays (error + address + sync state + mapping notice) — rebuilt
  # whenever any of them change.  Every signal is read inside the effect so the
  # subscription edge is established for all of them.
  createRenderEffect proc() =
    let err = vm.errorMessage.val
    let addrVal = vm.address.val
    let syncOn = vm.syncSettings.val.enabled
    let notice = mappingNotice(vm)
    let noticeCls = noticeClass(vm)
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
    let toggle = ui(r):
      tdiv(class = syncToggleClass(syncOn), onclick = onSyncToggle(vm)):
        text syncToggleLabel(syncOn)
    r.appendChild(headerContainer, toggle)
    let noticeDiv = ui(r):
      tdiv(class = noticeCls):
        text notice
    r.appendChild(headerContainer, noticeDiv)

  # Instruction list — rebuilt whenever any of the row-affecting
  # signals change.
  createRenderEffect proc() =
    let instructions = vm.instructions.val
    let activeOffset = vm.activeOffset.val
    let noir = vm.noirProject.val
    let anchors = vm.anchors.val
    r.clearChildren(listContainer)
    for i, instr in instructions:
      let active = isActiveRow(instr, activeOffset)
      # ROW INDEX, not offset. Anchors are ranges of generated-row indices, and
      # `Generated-Code-Listing.md` GCL-D6 makes `row index == opcode index` an
      # invariant of this pane — using the offset here would be off by whatever
      # the artefact's first offset happens to be.
      let fidelity = vm.fidelityAtRow(i)
      var count = ExecutedCount(value: 0, provenance: cpNone)
      let idx = anchorIndexAtRow(anchors, i)
      if idx != NoAnchor:
        count = anchors[idx].count
      let row = renderInstructionRowMock(r, vm, instr, active, noir,
                                         fidelity, count)
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
                               active: bool; noir: bool;
                               fidelity: MappingFidelity;
                               count: ExecutedCount): isonim_dom.Element =
    ## Build an asm-listing row in the real DOM.  Same shape as the
    ## Mock variant; click handler is wired imperatively via
    ## ``addEventListener``.
    ##
    ## PARITY WITH THE MOCK ARM IS THE POINT. A mock-only assertion is green
    ## over a surface nobody sees (`Verification-Harness-Traps.md` trap 3), so
    ## every span the mock arm emits is emitted here too, with the same classes.
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

    let fidelitySpan = createWebTextElement("span", label(fidelity),
                                            fidelityClass(fidelity))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(fidelitySpan))

    let crossRef = sourceCrossRef(instr)
    if crossRef.len > 0:
      let crossSpan = createWebTextElement("span", crossRef,
                                            "low-level-code-instruction-source")
      isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(crossSpan))

    let countText = countLabel(count)
    if countText.len > 0:
      let countSpan = createWebTextElement("span", countText,
                                           "low-level-code-instruction-count")
      isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(countSpan))

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
      let syncOn = vm.syncSettings.val.enabled
      let notice = mappingNotice(vm)
      let noticeCls = noticeClass(vm)
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

      let toggle = createWebTextElement("div", syncToggleLabel(syncOn),
                                        syncToggleClass(syncOn))
      let toggleHandler = onSyncToggle(vm)
      isonim_dom.addEventListener(isonim_dom.Node(toggle), cstring"click",
                                  proc(ev: isonim_dom.Event) = toggleHandler())
      isonim_dom.appendChild(isonim_dom.Node(headerContainer),
                             isonim_dom.Node(toggle))

      let noticeDiv = createWebTextElement("div", notice, noticeCls)
      isonim_dom.appendChild(isonim_dom.Node(headerContainer),
                             isonim_dom.Node(noticeDiv))

    createRenderEffect proc() =
      let instructions = vm.instructions.val
      let activeOffset = vm.activeOffset.val
      let noir = vm.noirProject.val
      let anchors = vm.anchors.val
      clearWebChildren(listContainer)
      for i, instr in instructions:
        let active = isActiveRow(instr, activeOffset)
        let fidelity = vm.fidelityAtRow(i)
        var count = ExecutedCount(value: 0, provenance: cpNone)
        let idx = anchorIndexAtRow(anchors, i)
        if idx != NoAnchor:
          count = anchors[idx].count
        let row = renderInstructionRowWeb(vm, instr, active, noir,
                                          fidelity, count)
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
