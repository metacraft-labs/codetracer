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
import ../../../../common/value_visualisers
import ../../../../common/project_definitions
import ../views/variables

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 59
  ## Was 39 before 2026-09-12. PLAT-12 added four cases (+20) asserting that
  ## the same affordance reports a VISUALISER and its degradation, each with
  ## its own named control.

proc recordValue(): PValue =
  PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
         members: @[member("x", PValue(kind: pvkInt, text: "10",
                                       typeName: "int", sourceKind: "Int")),
                    member("y", PValue(kind: pvkInt, text: "20",
                                       typeName: "int", sourceKind: "Int"))])

proc intValue(): PValue =
  PValue(kind: pvkInt, text: "306", typeName: "int", sourceKind: "Int")

proc imageValue(): PValue =
  ## PLAT-12: a value a §5.2 media declaration can point into. The bytes are a
  ## byte buffer, which is what a recorder produces for a `bytes` field.
  var acc: seq[PMember] = @[]
  for k in 0 ..< 40:
    acc.add member("", PValue(kind: pvkInt, text: $k, typeName: "int",
                              sourceKind: "Int"))
  PValue(kind: pvkRecord, typeName: "Image", sourceKind: "Instance",
         members: @[member("width", PValue(kind: pvkInt, text: "64",
                                           typeName: "int", sourceKind: "Int")),
                    member("pixels",
                           PValue(kind: pvkSequence, typeName: "bytes",
                                  sourceKind: "Seq", members: acc))])

proc declaredVisualisers(text: string): seq[Visualiser] =
  ## A declaration, as TOML text, through the product's own loader. Not a stub:
  ## `loadProjectDefinitions` is the function `project_definitions_dir.nim`
  ## hands a checkout's bytes to, and `presentersFor` is the function a
  ## front-end calls once a checkout has been read.
  presentersFor(loadProjectDefinitions(@[
    DefinitionFile(kind: dfkVisualisers, origin: doProject,
                   path: definitionPath("", dfkVisualisers),
                   text: text)])).visualisers

proc modelWith(selected: string): VariablesModel =
  ## One available `Locals` scope holding two variables, with the cursor where
  ## the caller asks. Built through `initVariablesModel` and a `NodeChildren`
  ## closure, which is the only door the pane has.
  let nodes = @[
    VarNode(path: "locals.p", name: "p", typeName: "Point",
            value: "Point{x: 10, y: 20}", memberCount: 2,
            presented: recordValue()),
    VarNode(path: "locals.n", name: "n", typeName: "int", value: "306",
            memberCount: 0, presented: intValue()),
    # PLAT-12's subject. A third node rather than a second model, so the
    # "moving the cursor changes the answer" case above keeps its shape.
    VarNode(path: "locals.img", name: "img", typeName: "Image",
            value: "Image{width: 64}", memberCount: 2,
            presented: imageValue())]
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

suite "PLAT-12: the pane reports the VISUALISER, and says what it beat":

  test "a declared visualiser renders the row and the title names it":
    # PLAT-12's "which visualiser rendered this?" answerable in the UI, on the
    # surface that already answers "which presenter". The row's TEXT and the
    # title's PROVENANCE come from one presentation (`TreeRowSpec.presentation`),
    # so the pane cannot report a rule it did not draw with.
    var model = modelWith("locals.p")
    model.visualisers = declaredVisualisers("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
summary = "({x}, {y})"
""")
    let spec = model.rowSpecFor(model.paneRows()[1], 120)
    ck spec.formattedValue(40) == "(10, 20)"
    let title = model.titleRowText(160)
    checkpoint "title: " & title
    ck title.contains("project:.codetracer/visualisers.toml#0")
    ck title.contains("tier=project-definition")
    ck title.contains("over=builtin.record")
    ck model.provenanceBadgeOf() ==
       "via project:.codetracer/visualisers.toml#0"

  test "with no declaration the same pane reports the built-in, unopposed":
    # The control for the case above, and it is the whole of PLAT-12's
    # compatibility claim at this surface: the field's zero value is `@[]` and
    # `@[]` is the pre-PLAT-12 behaviour exactly.
    var model = modelWith("locals.p")
    ck model.visualisers.len == 0
    let spec = model.rowSpecFor(model.paneRows()[1], 120)
    ck spec.formattedValue(40) == "Point(x:10, y:20)"
    ck model.titleRowText(160).contains("builtin.record")
    ck not model.titleRowText(160).contains("project:")
    ck model.provenanceOf().contains("unopposed")

  test "a media declaration this terminal cannot draw is REPORTED, not blank":
    # §8.2's "what is missing and how to get it", at the surface a reader is
    # looking at. The row still shows the value — a degradation that blanked it
    # would hide data the reader could have had — and `degradationOf` carries
    # the name and the remedy.
    var model = modelWith("locals.img")
    model.visualisers = declaredVisualisers("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "image/png"
mediaFrom = "pixels"
""")
    let spec = model.rowSpecFor(model.paneRows()[3], 200)
    let shown = spec.formattedValue(120)
    checkpoint "row: " & shown
    ck shown.startsWith("Image(")
    ck shown.contains("width:64")
    let detail = model.degradationOf()
    checkpoint "degradation: " & detail
    ck detail.contains("image/png")
    ck detail.contains("To see it:")
    ck not detail.contains("unavailable")
    # The one-line provenance carries the marker, so the long form is an
    # elaboration rather than the only place the fact appears.
    ck model.provenanceOf().contains("media-degraded=image/png")

  test "a declaration this terminal CAN draw leaves nothing to report":
    # The control. `degradationOf` returning a sentence whatever happened would
    # be a report satisfied by a presenter that drew nothing.
    var model = modelWith("locals.img")
    model.visualisers = declaredVisualisers("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "application/octet-stream"
mediaFrom = "pixels"
""")
    let spec = model.rowSpecFor(model.paneRows()[3], 200)
    ck spec.formattedValue(120) == "<application/octet-stream, 40 bytes>"
    ck model.degradationOf() == ""
    ck not model.provenanceOf().contains("media-degraded")
    # And a row with no value at all has nothing to report either.
    var onScope = modelWith(scopePath(skLocals))
    ck onScope.degradationOf() == ""

suite "PLAT-2 deliverable 4: assertion tally":

  test "every assertion above ran":
    if countedAssertions != ExpectedAssertions:
      checkpoint "assertion count is " & $countedAssertions &
        ", expected " & $ExpectedAssertions
    check countedAssertions == ExpectedAssertions
