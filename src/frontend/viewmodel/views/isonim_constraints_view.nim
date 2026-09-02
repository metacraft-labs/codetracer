## views/isonim_constraints_view.nim
##
## IsoNim view for the Constraints pane (`Content.Constraints`).
##
## Structure, both renderers::
##
##   div.component-container.constraints[.stale]
##     div.constraints-headline    text "17 ACIR opcodes, 17 unconstrained"
##     div.constraints-body
##       div.constraints-row.acir
##         span.constraints-name     "main"
##         span.constraints-count    "17"
##       div.constraints-row.unconstrained
##         span.constraints-name     "directive_invert"
##         span.constraints-count    "9"
##     div.constraints-provenance  text how the counts were obtained
##     div.constraints-absence[.hidden]
##       text  why there are no counts
##
## ## Totals are per KIND, and nothing sums across them
##
## `nargo info` reports two different currencies — constrained ACIR opcodes,
## which govern proving cost, and unconstrained Brillig opcodes, which do not.
## A single "total" row would add a number to a different number. §1a's
## mock-up has one because it predates the measurement; see
## `common/noir_constraints.nim` for the whole account, including why there is
## no `utils::check` row.
##
## ## The provenance line is content, not chrome
##
## "17" measured a second ago and "17" shipped in a bundle are different
## claims, and only one of them survives an edit. The pane always says which
## it has.
##
## ## The `(stale)` half, and what it took to reach it
##
## `headlineFor` appends `(stale)` whenever `report.stale` is set, and the
## container carries a `stale` class so the rows can be dimmed beside the
## label. The flag is set by `constraints_vm.markStale`, which is reached from
## `constraints_vm.noteSourceEdited` — the editor's change hook, at last
## actually wired. See that module's header for the three decisions behind it:
## which edits invalidate, what the pane keeps while stale, and why an
## in-flight recompile does NOT clear the mark.
##
## THE LABEL WAS UNREACHABLE FOR THE WHOLE OF ITS FIRST LIFE, and the way its
## test stayed green is worth keeping in view: `test_ns9_panes_vm`'s staleness
## case assigns `report.stale = true` itself and checks the suffix. That covers
## `headlineFor` and cannot cover a caller that is not there — so the pane's
## actual behaviour was the failure mode the paragraph above argues against,
## an unlabelled stale count, for as long as the branch was green.
##
## Any check on this has to START FROM AN EDIT and end at painted text, which
## is what `test_constraints_stale_on_edit.nim` does. A check that sets the
## flag, and a spy that watches `markStale` get called, are both blind in the
## same way: they move with the thing they measure.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/constraints_vm

const ConstraintsContainerClass* = "component-container constraints"

proc rowClass*(kind: ConstraintFunctionKind): string =
  "constraints-row " & $kind

proc kindLabel*(kind: ConstraintFunctionKind): string =
  case kind
  of cfkAcir: "acir"
  of cfkUnconstrained: "unconstrained"

proc containerClass*(report: ConstraintReport): string =
  ## `stale` beside the base class, so CSS can dim the rows while the headline
  ## says why they are dim.
  ##
  ## THE CLASS IS NOT THE EVIDENCE. `headlineFor`'s `(stale)` suffix is the
  ## part a reader without CSS still gets, and it is what the checks assert;
  ## this only exists so the dimming and the label cannot disagree about which
  ## state the pane is in.
  if report.stale and report.absence.len == 0:
    ConstraintsContainerClass & " stale"
  else:
    ConstraintsContainerClass

# ---------------------------------------------------------------------------
# Mock renderer
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; fn: ConstraintFunction): MockNode =
  let count = $fn.opcodes
  let label = kindLabel(fn.kind)
  ui(r):
    tdiv(class = rowClass(fn.kind)):
      span(class = "constraints-name"):
        text fn.name
      span(class = "constraints-kind"):
        text label
      span(class = "constraints-count"):
        text count

proc renderConstraintsPanel*(r: MockRenderer; vm: ConstraintsVM): MockNode =
  var headlineNode: MockNode
  var bodyContainer: MockNode
  var provenanceNode: MockNode
  var absenceNode: MockNode

  let panel = ui(r):
    tdiv(class = ConstraintsContainerClass, tabIndex = "2"):
      tdiv(ref = headlineNode, class = "constraints-headline"):
        discard
      tdiv(ref = bodyContainer, class = "constraints-body"):
        discard
      tdiv(ref = provenanceNode, class = "constraints-provenance hidden"):
        discard
      tdiv(ref = absenceNode, class = "constraints-absence hidden"):
        discard

  createRenderEffect proc() =
    let report = vm.report.val

    r.setAttribute(panel, "class", containerClass(report))

    r.clearChildren(headlineNode)
    r.appendChild(headlineNode, r.createTextNode(vm.headline.val))

    r.clearChildren(bodyContainer)
    for fn in report.functions:
      r.appendChild(bodyContainer, renderRowMock(r, fn))

    r.clearChildren(provenanceNode)
    if report.provenance.len > 0:
      r.appendChild(provenanceNode, r.createTextNode(report.provenance))
      r.setAttribute(provenanceNode, "class", "constraints-provenance")
    else:
      r.setAttribute(provenanceNode, "class", "constraints-provenance hidden")

    r.clearChildren(absenceNode)
    if report.absence.len > 0:
      r.appendChild(absenceNode, r.createTextNode(report.absence))
      r.setAttribute(absenceNode, "class", "constraints-absence")
    else:
      r.setAttribute(absenceNode, "class", "constraints-absence hidden")

  panel

# ---------------------------------------------------------------------------
# Web renderer
# ---------------------------------------------------------------------------

when defined(js):

  proc webElement(tag, cssClass: string): isonim_dom.Element =
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    n

  proc webTextElement(tag, textValue, cssClass: string): isonim_dom.Element =
    let n = webElement(tag, cssClass)
    isonim_dom.appendChild(isonim_dom.Node(n),
      isonim_dom.createTextNode(isonim_dom.document, cstring(textValue)))
    n

  proc clearWeb(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc setWebText(node: isonim_dom.Element; value: string) =
    clearWeb(node)
    if value.len > 0:
      isonim_dom.appendChild(isonim_dom.Node(node),
        isonim_dom.createTextNode(isonim_dom.document, cstring(value)))

  proc renderRowWeb(fn: ConstraintFunction): isonim_dom.Element =
    let node = webElement("div", rowClass(fn.kind))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", fn.name, "constraints-name")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", kindLabel(fn.kind),
                                     "constraints-kind")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", $fn.opcodes,
                                     "constraints-count")))
    node

  proc renderConstraintsPanel*(r: WebRenderer;
                               vm: ConstraintsVM): isonim_dom.Element =
    var headlineNode: isonim_dom.Element
    var bodyContainer: isonim_dom.Element
    var provenanceNode: isonim_dom.Element
    var absenceNode: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = ConstraintsContainerClass, tabIndex = "2"):
        tdiv(ref = headlineNode, class = "constraints-headline"):
          discard
        tdiv(ref = bodyContainer, class = "constraints-body"):
          discard
        tdiv(ref = provenanceNode, class = "constraints-provenance hidden"):
          discard
        tdiv(ref = absenceNode, class = "constraints-absence hidden"):
          discard

    createRenderEffect proc() =
      let report = vm.report.val

      isonim_dom.setAttribute(panel, cstring"class",
                              cstring(containerClass(report)))

      setWebText(headlineNode, vm.headline.val)

      clearWeb(bodyContainer)
      for fn in report.functions:
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(renderRowWeb(fn)))

      setWebText(provenanceNode, report.provenance)
      isonim_dom.setAttribute(provenanceNode, cstring"class",
        cstring(if report.provenance.len > 0: "constraints-provenance"
                else: "constraints-provenance hidden"))

      setWebText(absenceNode, report.absence)
      isonim_dom.setAttribute(absenceNode, cstring"class",
        cstring(if report.absence.len > 0: "constraints-absence"
                else: "constraints-absence hidden"))

    panel

  proc mountIsoNimConstraintsPanel*(container: isonim_dom.Element;
                                    vm: ConstraintsVM) =
    let r = WebRenderer()
    let panel = renderConstraintsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
