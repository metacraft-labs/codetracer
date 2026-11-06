## views/isonim_constraints_view.nim
##
## IsoNim view for the Constraints pane (`Content.Constraints`).
##
## Structure, both renderers::
##
##   div.component-container.constraints[.stale]
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
##
## ## The rows are the ViewModel's, and each one leads to its source (PLAT-62)
##
## Every row this view draws is one of `ConstraintsVM.rows`, in that order —
## the list the terminal's pane and the GPUI window's leaf draw too. A
## function's row names where it is declared (`constraints-where`) and its
## title says where a press goes, or why it goes nowhere; a press selects it
## and opens that line (`activateRow`), and a right press opens the row menu
## the native panes show (`rowMenu`). `data-ct-row` is the row's index in
## `rows`, which is what a reader of the DOM compares across front-ends.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The DSL's calls on a `WebRenderer` resolve where the generic view is
  # instantiated; the overloads must be in scope there.
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import kdom
  from ./context_menu_bridge import showContextMenu
  from ../../context_menu_item import ContextMenuItem

import ../viewmodels/constraints_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

const ConstraintsContainerClass* = "component-container constraints"

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
# The panel, under any renderer (Shared-DOM-Front-Ends D3)
# ---------------------------------------------------------------------------

proc rowElementClass*(row: ConstraintRow; selected: bool): string =
  ## A row's classes: its kind's, `selected`, and `linked` when a press goes
  ## to a source line.
  result = case row.kind
           of crkFunction:
             "constraints-row " & row.kindLabel
           of crkOpcode:
             opcodeRowClass()
  if row.source.linked:
    result.add " linked"
  if selected:
    result.add " selected"

when defined(js):
  proc eventClientX(ev: isonim_dom.Event): int {.importjs: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importjs: "(#.clientY || 0)".}
  proc preventMenuDefault(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc stopMenuPropagation(ev: isonim_dom.Event) {.importjs: "#.stopPropagation()".}
  proc writeConstraintText(text: cstring) {.importjs:
    "(navigator.clipboard ? navigator.clipboard.writeText(#).catch(function(){}) : null)".}

  proc rowMenuHandler(vm: ConstraintsVM; index: int;
                      action: ConstraintMenuAction): proc(ev: kdom.Event) =
    ## One entry's handler — a FACTORY, so each entry runs its own action
    ## under the JS backend (codetracer#860).
    result = proc(ev: kdom.Event) =
      let outcome = vm.runRowMenu(index, action)
      if outcome.copied.len > 0:
        writeConstraintText(cstring(outcome.copied))

  proc rowMenuItems(vm: ConstraintsVM; index: int): seq[ContextMenuItem] =
    ## The row's context menu, the ViewModel's entries (`rowMenu`) — the same
    ## the terminal's and GPUI's panes show.
    for e in vm.rowMenu(index):
      result.add ContextMenuItem(
        name: cstring(e.label), hint: cstring"",
        disabled: not e.enabled, disabledReason: cstring(e.reason),
        handler: rowMenuHandler(vm, index, e.action))

  proc wireRowMenu(row: isonim_dom.Element; vm: ConstraintsVM; index: int) =
    ## A right press selects the row and opens its menu.
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.preventMenuDefault()
        ev.stopMenuPropagation()
        vm.selectRow(index)
        showContextMenu(rowMenuItems(vm, index), ev.eventClientX(),
                        ev.eventClientY()))

proc onRowPress(vm: ConstraintsVM; index: int): proc() =
  ## A press: select the row and open its source. A FACTORY so each row's
  ## handler holds its own index.
  let captured = index
  result = proc() = discard vm.activateRow(captured)

proc renderRow[R, N](r: R; vm: ConstraintsVM; row: ConstraintRow;
                     index: int; selected: bool): N =
  ## One function's row: its name, its kind, its count and where it is
  ## declared.
  let count = row.count
  let label = row.kindLabel
  let where = whereText(row.source)
  result = ui(r):
    tdiv(class = rowElementClass(row, selected), `data-ct-row` = $index,
         title = rowTitle(row), onclick = onRowPress(vm, index)):
      span(class = "constraints-name"):
        text row.name
      span(class = "constraints-kind"):
        text label
      span(class = "constraints-count"):
        text count
      span(class = "constraints-where"):
        text where
  when defined(js):
    when N is isonim_dom.Element:
      wireRowMenu(result, vm, index)

proc renderOpcode[R, N](r: R; vm: ConstraintsVM; row: ConstraintRow;
                        index: int; selected: bool): N =
  let name = row.name
  let args = row.args
  result = ui(r):
    tdiv(class = rowElementClass(row, selected), `data-ct-row` = $index,
         title = rowTitle(row), onclick = onRowPress(vm, index)):
      span(class = "low-level-code-instruction-offset"):
        text row.count
      span(class = "low-level-code-instruction-name"):
        text name
      span(class = "low-level-code-instruction-args"):
        text args
  when defined(js):
    when N is isonim_dom.Element:
      wireRowMenu(result, vm, index)

proc renderFunctions[R, N](r: R; vm: ConstraintsVM; into: N) =
  ## ONE FUNCTION per block: its count row, then its opcodes — the rows of
  ## `vm.rows`, in order.
  ##
  ## The count row is KEPT and kept FIRST. A listing with a total above it is
  ## strictly more than either alone, and the total is the part that survived a
  ## measurement campaign — removing it to make room for the rows would discard
  ## the one number in this pane that is known to match `nargo info` on both
  ## halves. It doubles as the listing's heading, which is why the rows sit
  ## under it rather than beside it.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild
  let rows = vm.rows.val
  let selected = vm.selected.val
  var i = 0
  while i < rows.len:
    let listing = ui(r):
      tdiv(class = "constraints-function"):
        discard
    r.appendChild(listing, renderRow[R, N](r, vm, rows[i], i, i == selected))
    inc i
    if i < rows.len and rows[i].kind == crkOpcode:
      let body = ui(r):
        tdiv(class = "constraints-opcodes low-level-code-instructions"):
          discard
      while i < rows.len and rows[i].kind == crkOpcode:
        r.appendChild(body, renderOpcode[R, N](r, vm, rows[i], i,
                                               i == selected))
        inc i
      r.appendChild(listing, body)
    r.appendChild(into, listing)

proc renderConstraintsPanel*[R, N](r: R; vm: ConstraintsVM): N =
  ## The Constraints panel, mounted on the desktop by `ui/panel_host`.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild, setAttribute, createTextNode
  var headlineNode, bodyContainer, noticeNode, provenanceNode,
      absenceNode: N

  let panel = ui(r):
    tdiv(class = ConstraintsContainerClass, tabIndex = "-1"):
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
    renderFunctions[R, N](r, vm, bodyContainer)

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
