## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## test_value_provenance_affordance.nim — PLAT-2 deliverable 4, the half that
## was open: "a user can ask which presenter rendered a value and get an
## answer".
##
## ## WHAT WAS MISSING, AND WHAT THIS ASSERTS
##
## `Attribution` has ridden every `Presentation` since PLAT-2 landed, and
## `describeAttribution` has rendered it since PLAT-2 landed. Neither had a
## PRODUCT call site — grep, 2026-09-07: `describeAttribution` appeared in two
## test files and in comments, and nowhere a reader could see it. A field only
## a test can reach does not satisfy Project-Definitions §5.4's reason for the
## field, which is a claim about a reader ("a formatting layer that cannot
## explain itself becomes untrustworthy the first time it is wrong").
##
## The affordance is the variables pane's title row. This file asserts that it
## is REACHED — that painting the pane, through the same `titleRowSpans` the
## pane paints with, puts the winning presenter's id on screen — and that it
## degrades to the short form rather than to a clipped one.
##
## ## NO MOCKS
##
## The `VariablesModel` below is built from `VarNode`s carrying real `PValue`s,
## which is the same object `variables_binding.varNodeFor` puts there from a
## `store/types.Variable`. Nothing is stubbed; `NodeChildren` is not used
## because these nodes are top-level and materialised.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[strutils, unittest]

import ../../../../common/value_presentation
import ../views/variables

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 39

proc recordValue(): PValue =
  PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
         members: @[member("x", PValue(kind: pvkInt, text: "10",
                                       typeName: "int", sourceKind: "Int")),
                    member("y", PValue(kind: pvkInt, text: "20",
                                       typeName: "int", sourceKind: "Int"))])

proc intValue(): PValue =
  PValue(kind: pvkInt, text: "306", typeName: "int", sourceKind: "Int")

proc modelWith(selected: string): VariablesModel =
  ## One available `Locals` scope holding two variables, with the cursor where
  ## the caller asks. Built through `initVariablesModel` and a `NodeChildren`
  ## closure, which is the only door the pane has.
  let nodes = @[
    VarNode(path: "locals.p", name: "p", typeName: "Point",
            value: "Point{x: 10, y: 20}", memberCount: 2,
            presented: recordValue()),
    VarNode(path: "locals.n", name: "n", typeName: "int", value: "306",
            memberCount: 0, presented: intValue())]
  let children = proc(path: string; offset, limit: int):
      tuple[nodes: seq[VarNode]; total: int] =
    if path == scopePath(skLocals): (nodes, nodes.len) else: (@[], 0)
  result = initVariablesModel(
    scopes = @[Scope(kind: skLocals, availability: savaAvailable)],
    children = children)
  result.expandNode(scopePath(skLocals))
  result.selected = selected
  result.focused = selected

suite "PLAT-2 deliverable 4: the affordance exists and is reached":

  test "the pane title names the presenter that drew the row under the cursor":
    var model = modelWith("locals.p")
    let line = model.provenanceOf()
    checkpoint "provenance: " & line
    ck line.len > 0
    ck line.contains("builtin.record")
    ck line.contains("tier=builtin")
    ck line.contains("budget=")
    # THE PANE, not the helper. `titleRowText` is what `paintVariables` uses,
    # so this is the assertion that the affordance is on screen rather than
    # merely available — the exact gap PLAT-2 recorded.
    let title = model.titleRowText(120)
    checkpoint "title: " & title
    ck title.startsWith("VARIABLES")
    ck title.contains("builtin.record")
    ck title.contains("tier=builtin")

  test "moving the cursor changes the answer":
    # A title that named the same presenter whatever row the cursor was on
    # would satisfy every `contains` above while answering nothing.
    var onRecord = modelWith("locals.p")
    var onInt = modelWith("locals.n")
    ck onRecord.titleRowText(120).contains("builtin.record")
    ck not onRecord.titleRowText(120).contains("builtin.scalar")
    ck onInt.titleRowText(120).contains("builtin.scalar")
    ck not onInt.titleRowText(120).contains("builtin.record")
    ck onRecord.provenanceOf() != onInt.provenanceOf()

  test "a row with no value contributes no attribution":
    # A scope header and a `… n more` marker are not values, and an
    # attribution invented for one would be a presenter that never ran.
    var onScope = modelWith(scopePath(skLocals))
    ck onScope.selectedPresented().isNil
    ck onScope.provenanceOf() == ""
    ck onScope.provenanceBadgeOf() == ""
    ck onScope.titleRowText(120).startsWith("VARIABLES")
    ck not onScope.titleRowText(120).contains("builtin.")
    var nothingSelected = modelWith("")
    ck nothingSelected.provenanceOf() == ""

  test "a narrow pane shows the SHORT form, never a clipped one":
    var model = modelWith("locals.p")
    let full = model.provenanceOf()
    let badge = model.provenanceBadgeOf()
    ck badge == "via builtin.record"
    ck badge.len < full.len
    # Wide: the full line.
    ck model.fitProvenance(200, 20).contains("tier=builtin")
    # Middling: the badge, whole.
    let middling = model.fitProvenance(20 + badge.len + 6, 20)
    checkpoint "middling: '" & middling & "'"
    ck middling.strip == badge
    ck not middling.contains("tier=")
    # Narrow: nothing at all. A CLIPPED presenter id is worse than none —
    # `builtin.reco…` names nothing a reader can grep for — so the span is
    # dropped rather than truncated.
    ck model.fitProvenance(28, 20) == ""
    ck model.fitProvenance(4, 20) == ""
    # And the pane agrees: at 28 cells the title is a title and nothing else.
    let narrowTitle = model.titleRowText(28)
    checkpoint "narrow title: '" & narrowTitle & "'"
    ck not narrowTitle.contains("builtin")
    ck not narrowTitle.contains("…")
    ck narrowTitle.startsWith("VARIABLES")

  test "the title still ends in a rule, so the pane still looks like a pane":
    var model = modelWith("locals.p")
    for width in [40, 80, 120, 200]:
      let title = model.titleRowText(width)
      ck title.endsWith("─")
      ck title.len > 0

  test "the two forms are the value_presentation package's, not this pane's":
    # `attributionBadge` and `describeAttribution` both live beside
    # `Attribution` itself, so a second surface that wants to report the same
    # fact spells it the same way. PLAT-2's survey found five spellings of one
    # error value; this is the arrangement that stops the sixth.
    var model = modelWith("locals.n")
    let p = present(intValue(), tuiRowBudget(40, focused = true),
                    measure = terminalMeasure)
    ck model.provenanceOf() == describeAttribution(p)
    ck model.provenanceBadgeOf() == attributionBadge(p)
    ck attributionBadge(p) == "via builtin.scalar"

suite "PLAT-2 deliverable 4: assertion tally":

  test "every assertion above ran":
    if countedAssertions != ExpectedAssertions:
      checkpoint "assertion count is " & $countedAssertions &
        ", expected " & $ExpectedAssertions
    check countedAssertions == ExpectedAssertions
