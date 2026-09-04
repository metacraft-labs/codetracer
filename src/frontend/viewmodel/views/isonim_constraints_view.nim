## views/isonim_constraints_view.nim
##
## IsoNim view for the Constraints pane (`Content.Constraints`).
##
## Structure, both renderers::
##
##   div.component-container.constraints[.stale][.compiling]
##     div.constraints-headline    text "17 ACIR opcodes, 17 unconstrained"
##     div.constraints-listing-notice[.hidden]
##       text  why this report has totals and no rows
##     div.constraints-body
##       div.constraints-function
##         div.constraints-row.acir
##           span.constraints-name     "func 0"
##           span.constraints-count    "17"
##         div.constraints-opcodes.low-level-code-instructions
##           div.low-level-code-instruction.constraints-opcode
##             span.low-level-code-instruction-offset  "0"
##             span.low-level-code-instruction-name    "BRILLIG"
##             span.low-level-code-instruction-args    "CALL func: 0, ..."
##     div.constraints-provenance  text how the counts were obtained
##     div.constraints-absence[.hidden]
##       text  why there are no counts
##
## ## THE PANE SHOWS THE GENERATED CODE, and the count is its heading
##
## This pane counted for its whole first life. `reportFromAcirListing` parsed
## `VfsResponse.acir_listing` — the compiler's own printed opcodes — and kept
## only how many rows it had seen, so a user who opened CONSTRAINTS to read
## what their circuit compiled to was shown a three-row summary of a document
## the pane had already read and thrown away. Every commit on that thread says
## "count" in its subject, and the goal it was closed against asked for a
## listing.
##
## So each function now renders as a heading followed by its opcodes.
## `Noir-Studio.md` §9.2 settles the shape: the constraint view IS a
## generated-code listing, and "the Low Level Code pane already exists … what
## Noir adds is a producer, in the shape the pane already consumes, not a new
## pane". The opcode rows therefore carry that pane's classes verbatim —
## `low-level-code-instruction`, `-offset`, `-name`, `-args` — so this is the
## product's existing disassembly row, fed a different producer, and §1a.1's
## "no pane is invented for the web" holds.
##
## THE COUNTS ARE KEPT, deliberately and in place. They are the part of this
## pane that was measured against `nargo info` on both halves and all three
## numbers; a listing with a total above it is strictly better than either
## alone, and dropping the total to make room would retire hard-won work to
## satisfy a complaint that was never about the total being there.
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

proc opcodeRowClass*(): string =
  ## THE GENERATED-CODE ROW, BORROWED RATHER THAN REINVENTED.
  ##
  ## `Noir-Studio.md` §9.2 says the constraint view IS a generated-code listing
  ## and that "the Low Level Code pane already exists … what Noir adds is a
  ## producer, in the shape the pane already consumes, not a new pane". §1a.1
  ## says the same thing one level up: "no pane is invented for the web".
  ##
  ## So an opcode row here carries the Low Level Code pane's own classes, and
  ## the CSS that styles a disassembly row styles this one. A `constraints-`
  ## prefixed clone would have been a second vocabulary for the same object,
  ## and the two would have drifted the first time either was restyled.
  "low-level-code-instruction constraints-opcode"

proc opcodeIndexText*(op: ConstraintOpcode): string =
  ## The gutter. Right-aligned by CSS so a column of indices reads as one.
  $op.index

proc listingNoticeFor*(report: ConstraintReport): string =
  ## The line that appears when the pane has counts but NO rows, and "" when
  ## there is nothing to explain.
  ##
  ## THIS IS THE STATE THE LIVE SITE IS ACTUALLY IN, and it is why this notice
  ## exists rather than an empty listing body. The bundled report comes from
  ## `nargo info`, which prints totals and no opcodes at all, so there is
  ## genuinely nothing to list until something compiles. A pane that rendered a
  ## blank listing area for that would look broken; one that says which of the
  ## two answers it is holding is merely honest about a real difference.
  if report.absence.len > 0:
    return ""
  if report.functions.len == 0:
    return ""
  # PROGRESS OUTRANKS EVERY OTHER CAPTION, INCLUDING SILENCE.
  #
  # This branch is above the `hasListing` return on purpose. A recompile over
  # a listing an earlier compile produced would otherwise say nothing at all
  # while it ran, so the rows would sit there looking current until they were
  # silently replaced — and `stale` already tells the reader those rows may not
  # describe the source, without telling them anything is being done about it.
  #
  # It is above `listingAbsence` for the same reason in the other direction: a
  # caption left over from the previous compile ("this build's compiler does
  # not print a constraint listing") describes a finished attempt, and showing
  # it during the next one would report the past as the present.
  if report.compiling:
    return "Compiling this project with the Noir compiler this page runs. " &
      "The generated code will appear here when it finishes."
  if report.hasListing():
    return ""
  # WHAT THE PANE WAS TOLD BEATS WHAT IT CAN INFER. A compile that succeeded
  # without emitting a listing knows why; the default sentence below is a
  # guess that would be wrong in exactly that case, and wrong in the
  # reassuring direction — it would tell a user to press Build when Build is
  # what had just failed to produce a listing.
  if report.listingAbsence.len > 0:
    return report.listingAbsence
  "These are totals, not the generated code: they come from `nargo info`, " &
    "which reports how many opcodes a circuit has and does not print them. " &
    "Build the project to see the compiler's own listing here."

proc containerClass*(report: ConstraintReport): string =
  ## `stale` beside the base class, so CSS can dim the rows while the headline
  ## says why they are dim.
  ##
  ## THE CLASS IS NOT THE EVIDENCE. `headlineFor`'s `(stale)` suffix is the
  ## part a reader without CSS still gets, and it is what the checks assert;
  ## this only exists so the dimming and the label cannot disagree about which
  ## state the pane is in.
  ##
  ## `compiling` joins it rather than replacing it, and the two are independent
  ## states: an edit marks the counts stale, and the compile that will refresh
  ## them is what `compiling` announces, so a visitor who types and presses
  ## Build is in both at once. A class that could only say one would have to
  ## pick, and picking would drop the half the reader most needs.
  if report.absence.len > 0:
    return ConstraintsContainerClass
  result = ConstraintsContainerClass
  if report.stale:
    result.add " stale"
  if report.compiling:
    result.add " compiling"

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

proc renderOpcodeMock(r: MockRenderer; op: ConstraintOpcode): MockNode =
  let index = opcodeIndexText(op)
  let name = op.name
  let args = op.args
  ui(r):
    tdiv(class = opcodeRowClass()):
      span(class = "low-level-code-instruction-offset"):
        text index
      span(class = "low-level-code-instruction-name"):
        text name
      span(class = "low-level-code-instruction-args"):
        text args

proc renderFunctionMock(r: MockRenderer; fn: ConstraintFunction): MockNode =
  ## ONE FUNCTION: its count row, then its opcodes.
  ##
  ## The count row is KEPT and kept FIRST. A listing with a total above it is
  ## strictly more than either alone, and the total is the part that survived a
  ## measurement campaign — removing it to make room for the rows would discard
  ## the one number in this pane that is known to match `nargo info` on both
  ## halves. It doubles as the listing's heading, which is why the rows sit
  ## under it rather than beside it.
  let listing = ui(r):
    tdiv(class = "constraints-function"):
      discard
  r.appendChild(listing, renderRowMock(r, fn))
  if fn.rows.len > 0:
    let body = ui(r):
      tdiv(class = "constraints-opcodes low-level-code-instructions"):
        discard
    for op in fn.rows:
      r.appendChild(body, renderOpcodeMock(r, op))
    r.appendChild(listing, body)
  listing

proc renderConstraintsPanel*(r: MockRenderer; vm: ConstraintsVM): MockNode =
  var headlineNode: MockNode
  var bodyContainer: MockNode
  var noticeNode: MockNode
  var provenanceNode: MockNode
  var absenceNode: MockNode

  let panel = ui(r):
    tdiv(class = ConstraintsContainerClass, tabIndex = "2"):
      tdiv(ref = headlineNode, class = "constraints-headline"):
        discard
      tdiv(ref = noticeNode, class = "constraints-listing-notice hidden"):
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

    let notice = listingNoticeFor(report)
    r.clearChildren(noticeNode)
    if notice.len > 0:
      r.appendChild(noticeNode, r.createTextNode(notice))
      r.setAttribute(noticeNode, "class", "constraints-listing-notice")
    else:
      r.setAttribute(noticeNode, "class", "constraints-listing-notice hidden")

    r.clearChildren(bodyContainer)
    for fn in report.functions:
      r.appendChild(bodyContainer, renderFunctionMock(r, fn))

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

  proc renderOpcodeWeb(op: ConstraintOpcode): isonim_dom.Element =
    let node = webElement("div", opcodeRowClass())
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", opcodeIndexText(op),
                                     "low-level-code-instruction-offset")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", op.name,
                                     "low-level-code-instruction-name")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", op.args,
                                     "low-level-code-instruction-args")))
    node

  proc renderFunctionWeb(fn: ConstraintFunction): isonim_dom.Element =
    ## Mirrors `renderFunctionMock` — see that proc for why the count row is
    ## kept and kept first.
    let wrapper = webElement("div", "constraints-function")
    isonim_dom.appendChild(isonim_dom.Node(wrapper),
                           isonim_dom.Node(renderRowWeb(fn)))
    if fn.rows.len > 0:
      let body = webElement("div",
                            "constraints-opcodes low-level-code-instructions")
      for op in fn.rows:
        isonim_dom.appendChild(isonim_dom.Node(body),
                               isonim_dom.Node(renderOpcodeWeb(op)))
      isonim_dom.appendChild(isonim_dom.Node(wrapper), isonim_dom.Node(body))
    wrapper

  proc renderConstraintsPanel*(r: WebRenderer;
                               vm: ConstraintsVM): isonim_dom.Element =
    var headlineNode: isonim_dom.Element
    var bodyContainer: isonim_dom.Element
    var noticeNode: isonim_dom.Element
    var provenanceNode: isonim_dom.Element
    var absenceNode: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = ConstraintsContainerClass, tabIndex = "2"):
        tdiv(ref = headlineNode, class = "constraints-headline"):
          discard
        tdiv(ref = noticeNode, class = "constraints-listing-notice hidden"):
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

      let notice = listingNoticeFor(report)
      setWebText(noticeNode, notice)
      isonim_dom.setAttribute(noticeNode, cstring"class",
        cstring(if notice.len > 0: "constraints-listing-notice"
                else: "constraints-listing-notice hidden"))

      clearWeb(bodyContainer)
      for fn in report.functions:
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(renderFunctionWeb(fn)))

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
