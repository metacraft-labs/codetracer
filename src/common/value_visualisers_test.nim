## value_visualisers_test.nim — PLAT-12's contract suite: a DECLARATION, all
## the way to a rendered value, through the real pipeline.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is no mock in this file and nothing is standing in for anything:
##
##   * the declarations below are TOML TEXT, handed to the product's own
##     `loadProjectDefinitions` — the same function
##     `src/ct/launch/project_definitions_dir.nim` hands a checkout's bytes to.
##     Where a case needs a rule the grammar refuses, it constructs a
##     `VisualiserRule` directly, which is not a mock either: it is the value
##     that function produces, reached without a file, which is exactly the
##     path `admit` exists to guard (see `value_visualisers.admit`).
##   * the values are `PValue`s built the way `json_adapter.toPValue` and
##     `value_presentation_bridge.toPValue` build them —
##     `value_presentation_test`'s own header states the argument and it is
##     unchanged here.
##   * the presenter, the budgets and the resolution are the product's.
##
## THE REAL-RECORDING HALF is
## `src/frontend/tui/tests/test_value_presentation_corpus.nim`, which opens the
## fixture corpus through a real `replay-server` and renders a declared
## visualiser over values nobody in this file chose. Both are required for the
## same reason PLAT-2 needed both: this file can reach shapes no recorder in
## this workspace produces (a media declaration over a byte field, a tie
## between two rules) and that one can prove the declaration survives a real
## wire decode, which no constructed value can.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## Every assertion goes through `ck`, which is a TEMPLATE and not a `proc`
## (§13: a `check` inside a plain `proc` sets a module global and the test
## still reports `[OK]`). The last case asserts the tally against a number
## written from a run.

import std/[strutils, unittest]

import project_definitions
import value_presentation
import value_visualisers

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 903
  ## Written from a run. See the final case.

# ---------------------------------------------------------------------------
# Values, built the way an adapter builds them
# ---------------------------------------------------------------------------

proc i(text: string; typeName = "int"): PValue =
  PValue(kind: pvkInt, text: text, typeName: typeName, sourceKind: "Int")

proc str(text: string; typeName = "str"): PValue =
  PValue(kind: pvkString, text: text, typeName: typeName, sourceKind: "String")

proc bytesOf(n: int): PValue =
  ## A byte buffer as a recorder produces one: a sequence of small integers.
  var acc: seq[PMember] = @[]
  for k in 0 ..< n:
    acc.add member("", i($(k mod 251)))
  PValue(kind: pvkSequence, typeName: "bytes", sourceKind: "Seq", members: acc)

proc matrix(): PValue =
  ## The type Project-Definitions.md §1 opens with: "that this type is a matrix
  ## and should be shown as a grid".
  PValue(kind: pvkRecord, typeName: "Matrix", sourceKind: "Instance",
         members: @[member("rows", i("3")), member("cols", i("4")),
                    member("scratch", str("internal")),
                    member("data", bytesOf(12))])

proc point(): PValue =
  PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
         members: @[member("x", i("10")), member("y", i("20"))])

proc image(): PValue =
  PValue(kind: pvkRecord, typeName: "Image", sourceKind: "Instance",
         members: @[member("width", i("64")), member("height", i("64")),
                    member("pixels", bytesOf(40))])

# ---------------------------------------------------------------------------
# Declarations, as the text a repository checks in
# ---------------------------------------------------------------------------

proc visualisersFile(text: string; scope = ""; origin = doProject): DefinitionFile =
  DefinitionFile(kind: dfkVisualisers, origin: origin, scope: scope,
                 path: definitionPath(scope, dfkVisualisers), text: text)

proc loadedFrom(projectTexts: openArray[(string, string)];
                userText = ""): LoadedProjectDefinitions =
  ## `(scope, text)` pairs for the project, plus optionally the user's own.
  var project: seq[DefinitionFile] = @[]
  for (scope, text) in projectTexts:
    project.add visualisersFile(text, scope)
  var user: seq[DefinitionFile] = @[]
  if userText.len > 0:
    user.add visualisersFile(userText, origin = doUser)
  loadProjectDefinitions(project, user)

proc presentersFrom(text: string): PresenterSet =
  presentersFor(loadedFrom([("", text)]))

const TailRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Wide"
summary = "{tail}{tail}"
"""
  ## Two placeholders naming the LAST member, so `memberNamed`'s equality scan
  ## runs the whole list before it finds the field. See the work-charge case's
  ## part 4.

proc withFillers(n: int): PValue =
  ## `Wide { f0 … f<n-1>, tail }` — the named member last.
  var members: seq[PMember] = @[]
  for k in 0 ..< n: members.add member("f" & $k, i("7"))
  members.add member("tail", i("9"))
  PValue(kind: pvkRecord, typeName: "Wide", sourceKind: "Instance",
         members: members)

const MatrixRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "{rows}x{cols}"
hide = ["scratch"]
"""

const SiblingWidth = 50_000
  ## Wide enough that a charge over it is unmistakable against the 1 MiB bound
  ## — 199 siblings x 50,001 members is 9,950,199 units, so a rendering that
  ## pays it reports ten times the bound — and small enough that the value is
  ## built and rendered in a tenth of a second in a DEBUG build, which is what
  ## the mutation harness compiles.

proc siblingRules(): PresenterSet =
  ## Three rules, and each is load-bearing for the two cases that use them.
  ##
  ##   `Row`  — a ONE-BYTE summary. Without it the root's own inline rendering
  ##            spends the whole allowance and `renderNode` returns before its
  ##            child loop ever starts, which is the configuration in which
  ##            none of this is reachable. The declaration is what makes the
  ##            parent's line cheap enough for the loop to begin.
  ##   `Node` — the recursive summary, so the FIRST child exhausts the
  ##            allowance while 199 siblings are still to come.
  ##   `Wide` — a declared presentation and a declared media type on the
  ##            siblings, so an ELIDED node has something to report about the
  ##            rule that claimed it.
  var summary = ""
  for _ in 0 ..< MaxTemplatePlaceholders: summary.add "{next}"
  presentersFrom(
    "schema = \"codetracer.visualisers.v1\"\n\n" &
    "[[visualiser]]\nmatch = \"Row\"\nsummary = \"{{\"\n\n" &
    "[[visualiser]]\nmatch = \"Node\"\nsummary = \"" & summary & "\"\n\n" &
    "[[visualiser]]\nmatch = \"Wide\"\npresent = \"Image\"\n" &
    "media = \"image/png\"\nmediaFrom = \"pixels\"\n")

proc sharedWide(): PValue =
  ## `Wide { f0 … f49999, pixels }` — ONE value, referenced by every sibling.
  var members: seq[PMember] = @[]
  for k in 0 ..< SiblingWidth: members.add member("f" & $k, i($(k mod 7)))
  members.add member("pixels", bytesOf(8))
  PValue(kind: pvkRecord, typeName: "Wide", sourceKind: "Instance",
         members: members)

proc exhaustingRow(shared: PValue): PValue =
  ## `Row { boom: <a Node chain that exhausts the allowance>, s1 … s199 }`,
  ## every `s` the SAME `shared`. The DAG shape residue 4 names, arranged so
  ## the allowance runs out inside the first child of a loop with 199 left.
  var node = PValue(kind: pvkRecord, typeName: "Node", sourceKind: "Instance",
                    members: @[member("next", i("0"))])
  for _ in 0 ..< 5:
    node = PValue(kind: pvkRecord, typeName: "Node", sourceKind: "Instance",
                  members: @[member("next", node)])
  var members = @[member("boom", node)]
  for k in 1 ..< StatePanelBudget.members: members.add member("s" & $k, shared)
  PValue(kind: pvkRecord, typeName: "Row", sourceKind: "Instance",
         members: members)

# ---------------------------------------------------------------------------

suite "PLAT-12: §5.3's matching is data, and there is ONE predicate":

  test "the grammar and the presenter ask the same question of a rule":
    # Verification-Harness-Traps §14: `model.matches` and `presenter.resolve`
    # must not carry two copies of a three-armed string comparison. They do
    # not — `matches` forwards to `typeMatches` and so does
    # `winningVisualiser` — and this case asserts the AGREEMENT over a table
    # rather than asserting the forwarding, so a future second copy is caught
    # by its answers rather than by its shape.
    const Cases = [
      (mkTypeName, "Matrix", "", "Matrix", "", true),
      (mkTypeName, "Matrix", "", "Matrix2", "", false),
      (mkTypeName, "Matrix", "", "aMatrix", "", false),
      (mkTypePrefix, "Vec", "", "Vec3", "", true),
      (mkTypePrefix, "Vec", "", "Vec", "", true),
      (mkTypePrefix, "Vec", "", "AVec3", "", false),
      (mkTypePrefix, "Vec", "", "Ve", "", false),
      (mkTypeSuffix, "Buffer", "", "RingBuffer", "", true),
      (mkTypeSuffix, "Buffer", "", "Buffers", "", false),
      (mkTypeSuffix, "Buffer", "", "uffer", "", false),
      (mkTypeName, "Matrix", "rust", "Matrix", "rust", true),
      (mkTypeName, "Matrix", "rust", "Matrix", "python", false),
      (mkTypeName, "Matrix", "rust", "Matrix", "", false),
      (mkTypeName, "Matrix", "", "Matrix", "python", true),
    ]
    for (kind, match, ruleLang, typeName, valueLang, expected) in Cases:
      let rule = VisualiserRule(match: match, matchKind: kind,
                                language: ruleLang)
      ckEq rule.matches(typeName, valueLang), expected
      ckEq typeMatches(kind, match, ruleLang, typeName, valueLang), expected
      # And the third caller: the presenter, over a real value.
      let vis = visualiserFor(rule, doProject, 0)
      let v = PValue(kind: pvkRecord, typeName: typeName, sourceKind: "Instance")
      ckEq (winningVisualiser(v, withVisualisers(@[vis]), valueLang) >= 0),
           expected

  test "a rule matching by language never claims another language's type":
    # §5.3's "a language" as a match criterion, end to end: the SAME type name
    # recorded from two languages, one rule, two answers.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
language = "rust"
summary = "rust-matrix"
""")
    ckEq present(matrix(), StatePanelBudget, languageName = "rust",
                 presenters = presenters).root.text, "rust-matrix"
    ck present(matrix(), StatePanelBudget, languageName = "python",
               presenters = presenters).root.text.startsWith("Matrix(")
    # An unknown language is not every language. A rule that named one asked.
    ck present(matrix(), StatePanelBudget,
               presenters = presenters).root.text.startsWith("Matrix(")

suite "PLAT-12: a declaration reaches the pipeline and renders":

  test "a summary template renders on EVERY surface, within each budget":
    # PLAT-12's first integration test, in the form this file can make: one
    # visualiser, written once, on all seven declared budgets. The corpus suite
    # makes the same statement over a real recording.
    let presenters = presentersFrom(MatrixRule)
    ckEq SurfaceBudgets.len, 7
    for budget in SurfaceBudgets:
      let p = present(matrix(), budget, presenters = presenters)
      ckEq p.root.text, "3x4"
      ckEq p.attribution.tier, ptProjectDefinition
      ckEq p.attribution.presenter, "project:.codetracer/visualisers.toml#0"
      ckEq p.budget.name, budget.name
    # The tui-row budget is `tui-tree` narrowed to one row and is not an
    # eighth surface; it renders the same declaration.
    ckEq present(matrix(), tuiRowBudget(40, false),
                 presenters = presenters).root.text, "3x4"

  test "the template substitutes the value's OWN fields, through the presenter":
    # A placeholder is not a string splice: the field is rendered by the same
    # presenter, at the same budget, so a nested record inside a placeholder
    # reads the way it reads everywhere else.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Wrapper"
summary = "holds {inner}"
""")
    let v = PValue(kind: pvkRecord, typeName: "Wrapper", sourceKind: "Instance",
                   members: @[member("inner", point())])
    ckEq present(v, StatePanelBudget, presenters = presenters).root.text,
         "holds Point(x:10, y:20)"

  test "a placeholder naming a field the value lacks is REPORTED, not blanked":
    # PLAT-2's own header records what a blank costs: `annotationsFrom` DROPS a
    # variable whose rendering is empty, so a step-to-step diff cannot see a
    # change between two values that both render as "". A wrong rule has to be
    # visible to the person who wrote it.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
summary = "{x},{z}"
""")
    let text = present(point(), StatePanelBudget, presenters = presenters).root.text
    ckEq text, "10,<no field 'z'>"
    ck text.len > 0

  test "templating is one pass: a substituted value cannot make a placeholder":
    # §2.2's "templating is total and terminates by construction". The field's
    # own text contains `{x}`; the result is not re-scanned, so it is emitted
    # verbatim and no second substitution happens.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Sneaky"
summary = "<{payload}>"
""")
    let v = PValue(kind: pvkRecord, typeName: "Sneaky", sourceKind: "Instance",
                   members: @[member("payload", str("{payload}")),
                              member("x", i("1"))])
    ckEq present(v, StatePanelBudget, presenters = presenters).root.text,
         "<\"{payload}\">"

  test "a summary that re-enters its own type is bounded by WORK, not depth":
    # THE RECURSION THIS FILE'S FIRST DRAFT SAID DID NOT EXIST.
    # `substituteSummary` substitutes a placeholder by RENDERING the named
    # field through the whole pipeline, so
    # `substituteSummary -> inlineText -> winningVisualiser -> visualisedText
    # -> substituteSummary` is a cycle. A rule matching a type that contains
    # itself re-enters its own template once per placeholder: branching factor
    # `MaxTemplatePlaceholders` = 16, levels bounded only by `Budget.depth`.
    #
    # Measured on the tree BEFORE `MaxRenderWork`, release build, at the state
    # panel's own depth of 7: 4,294,967,296 bytes of text and 125 seconds, for
    # ONE value, from the 200-byte declaration below. Exactly ×16 per level.
    #
    # THE ASSERTION IS ON THE EFFECT AND NOT ON A FLAG. `p.expansion.reached`
    # is checked too, but a bound that set the flag and then did the work would
    # satisfy that and fail the BYTE COUNT below — which is the quantity the
    # attack multiplies.
    var summary = ""
    for _ in 0 ..< MaxTemplatePlaceholders: summary.add "{next}"
    let presenters = presentersFrom(
      "schema = \"codetracer.visualisers.v1\"\n\n[[visualiser]]\n" &
      "match = \"Node\"\nsummary = \"" & summary & "\"\n")
    ckEq presenters.visualisers.len, 1
    # FIVE LINKS, NOT TWENTY, AND THE REASON IS THE MUTATION ARMS. The attack
    # is `MaxTemplatePlaceholders ^ levels`, so a chain as deep as the deepest
    # budget (16) makes the case unrunnable the moment an arm REMOVES the
    # bound — which is precisely when it has to run and report. Five links is
    # 16^5 ≈ 1.05 M renderings and ~6.3 MB of text without the bound: six times
    # over it, so the assertions below still discriminate, and a few seconds
    # rather than a few hours when they are being killed. The depths the
    # BUDGETS allow (7, 10, 16) and what they cost are measured and tabled in
    # `vocabulary.ExpansionBound`; they are not re-run here.
    #
    # THE CHAIN TERMINATES IN A `next` THAT IS A SCALAR, NOT IN A `Node` THAT
    # HAS NO `next`. That is not a detail of the value; it is what makes the
    # `<no field` assertion below able to fail. With a bare `Node` at the
    # bottom the deepest sixteen placeholders name a field that really is
    # absent, so the rendering legitimately carries `<no field 'next'>` — 348
    # KB of it, measured — and an assertion that the STRING is absent could
    # never have been written here at all. Terminated this way every `Node` in
    # the chain has the field its own summary names, at every level, so the
    # string can only appear if a lookup started answering `nil`.
    var node = PValue(kind: pvkRecord, typeName: "Node", sourceKind: "Instance",
                      members: @[member("next", i("0"))])
    for _ in 0 ..< 5:
      node = PValue(kind: pvkRecord, typeName: "Node", sourceKind: "Instance",
                    members: @[member("next", node)])
    for budget in SurfaceBudgets:
      let p = present(node, budget, presenters = presenters)
      # 1. THE EFFECT. Unbounded this is 16^depth bytes — 4.3 GB at the state
      #    panel's 7, and 16^16 at the terminal tree's 16, which is not a
      #    number this machine can allocate.
      ck p.root.text.len <= MaxRenderWork
      # The counter overshoots the threshold by at most ONE frame's charge.
      #
      # CORRECTED 2026-09-12. This used to read "by at most one frame's OUTPUT,
      # and a frame's output was itself paid for a byte at a time, so it cannot
      # exceed what had already been spent" — an argument that made the factor
      # of two follow from the charges rather than from a run. It no longer
      # holds, because a frame's charge is no longer only its output: it also
      # carries `memberScanCost` and `mediaScanCost`, neither of which is paid
      # a byte at a time, and both of which are sized by the RECORDING. So the
      # factor of two is now a property of THIS value — whose members number
      # one per level — and not of the bound in general.
      #
      # CORRECTED AGAIN 2026-09-12, and the second correction is the one that
      # was wrong by a factor rather than by an argument. This comment went on
      # to say the general statement was "one frame's charge, multiplied by
      # nothing". It was one frame's charge multiplied by the siblings left in
      # every child loop on the stack — measured at **77x** the bound on a
      # 200-wide DAG over a 400,000-member shared child, because
      # `renderNode`'s hidden-member walk sat above its own exhaustion return.
      # The walk is guarded now and the number is pinned as an EQUALITY, not
      # an inequality, by "an exhausted rendering stops WALKING a sibling".
      # This value cannot reach that shape — it is one member per level — so
      # the factor of two below is still the right assertion for it, and it is
      # the right assertion for nothing wider.
      ck p.expansion.spent < 2 * MaxRenderWork
      # 2. IT IS REPORTED, and it names the rule to edit.
      ck p.expansion.reached
      ckEq p.expansion.visualiser, "project:.codetracer/visualisers.toml#0"
      ckEq p.expansion.bound, MaxRenderWork
      ckEq p.expansion.surface, budget.name
      ck p.truncated
      # 3. IT IS NOT A BLANK REGION (§8.2). The value renders as far as it got,
      #    marked with the surface's own elision glyph, and the sentence says
      #    what happened and what to change.
      ck p.root.text.len > 0
      ck p.root.text.contains(Ellipsis)
      # 3a. AND IT IS NOT A REPORT ABOUT THE DECLARATION EITHER.
      #
      # `chargedMemberNamed` stops CHARGING when the allowance runs out and
      # deliberately does not stop LOOKING UP, and its header states the
      # consequence of the other choice exactly: a `substituteSummary` loop
      # that started getting `nil` back half way through would emit
      # `<no field 'next'>` for placeholders whose field is right there —
      # turning a rendering that ran out of ALLOWANCE into a rendering that
      # reports a wrong DECLARATION, which is the one message that sends a
      # reader to edit a rule that is correct.
      #
      # Until this line the asymmetry was an argument with no evidence: the
      # whole 52-case suite is green over a `chargedMemberNamed` that returns
      # `nil` once exhausted. Measured with that mutation applied: 69
      # occurrences of `<no field`, over `next` — a field every `Node` above
      # carries at every level.
      #
      # THE POSITIVE TWIN (§4a) IS A SEPARATE CASE IN THIS FILE AND RUNS
      # THROUGH THE SAME `substituteSummary`: "a placeholder naming a field the
      # value lacks is REPORTED, not blanked" asserts the string IS produced
      # for a field that really is missing. A renderer that had stopped
      # emitting it at all would satisfy the line below for free and redden
      # that one.
      ck not p.root.text.contains("<no field")
      let detail = describeDegradation(p)
      ck detail.contains("work bound")
      ck detail.contains("To fix it:")
      ck not detail.contains("unavailable")
      ck describeAttribution(p).contains(
        "expansion-bounded=project:.codetracer/visualisers.toml#0")
    # 4. THE POSITIVE TWIN (§4a). A bound that refused everything would satisfy
    #    every assertion above. The SAME budget, the same depth of value, a
    #    summary naming a field that is not of the matched type: it renders in
    #    full, spends four figures, and reports nothing.
    let scalars = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "{rows}x{cols}"
""")
    let fine = present(matrix(), StatePanelBudget, presenters = scalars)
    ckEq fine.root.text, "3x4"
    ck not fine.expansion.reached
    ck fine.expansion.spent < 10_000
    ckEq describeDegradation(fine), ""
    ck not describeAttribution(fine).contains("expansion-bounded")
    # …and so does the whole of the rest of this file: no ordinary rendering
    # in this suite comes within three orders of magnitude of the bound.
    ck present(matrix(), StatePanelBudget).expansion.spent < 10_000

  test "the work bound is on the PRESENTATION, so a wide tree cannot buy depth":
    # The second way to reach the bound, and the reason `describeExpansionBound`
    # has two arms: no visualiser is involved at all. A recorded value that is
    # merely enormous is told what it spent and is NOT told to edit a rule it
    # does not have — the retry that cannot succeed, at value scale.
    #
    # The value here is a DAG: one shared child, referenced `members` times at
    # every level, which is what a recorder produces for a repeated reference
    # and what makes the rendered size exponential in the depth while the
    # recorded size is linear in it.
    var shared = PValue(kind: pvkRecord, typeName: "Leaf",
                        sourceKind: "Instance",
                        members: @[member("v", i("123456789"))])
    for _ in 0 ..< 7:
      var wide: seq[PMember] = @[]
      for k in 0 ..< 6: wide.add member("m" & $k, shared)
      shared = PValue(kind: pvkRecord, typeName: "Wide", sourceKind: "Instance",
                      members: wide)
    let p = present(shared, StatePanelBudget)
    ck p.root.text.len <= MaxRenderWork
    ck p.expansion.reached
    ckEq p.expansion.visualiser, ""
    let detail = describeDegradation(p)
    ck detail.contains("work bound")
    ck detail.contains("No visualiser was expanding")
    ck not detail.contains("To fix it:")
    ck detail.contains("To see more of it:")
    ck describeAttribution(p).contains("expansion-bounded=")
    # AND THE TREE STOPS TOO, which is a second mechanism and therefore needs
    # evidence of its own (§16a). `renderNode` descends children after the
    # node's own line is built, and every `inlineText` below an exhausted
    # rendering returns the elision glyph for free — so without the guard the
    # walk continues, building 6^7 nodes whose text is all "…". The members are
    # reported as ELIDED, which is what they are.
    ckEq p.root.children.len, 0
    ckEq p.root.elided, 6
    # AND THE COUNT BELOW IS THE VALUE'S OWN, not the hide list's, because this
    # node is elided and `renderNode` skips the hidden-member walk once the
    # allowance is gone. `Wide` declares no `hide`, so the two agree here; the
    # case below is where the choice is stated and asserted.
    ckEq p.root.totalMembers, 6
    ck p.root.expandable
    #
    # ## DISJOINT EVIDENCE FOR THE RETURN ITSELF (§16a), AND THIS CASE NEEDED IT
    #
    # The two lines above used to be the whole of the descent guard's evidence,
    # and a repair in this same pass took most of it away without moving a
    # needle — §16a in its exact shape, found by re-running the arms rather
    # than by re-recording the digests. Once the hidden-member walk is skipped
    # for an exhausted node, `visible` is EMPTY, so the record arm's child loop
    # runs `0 ..< min(cap, 0)` and adds nothing whether or not the return above
    # it exists. `p.root.children.len == 0` stopped being evidence about the
    # return and became evidence about the walk, and arm V41 scored
    # MIS-ATTRIBUTED: the case went red, and not for its reason.
    #
    # A MAP IS WHAT ONLY THIS RETURN REFUSES. `renderNode`'s map arm iterates
    # `v.entries` and never consults `visible` at all, so the walk guard does
    # not reach it — and neither does a pointer's `*` target. Below the return,
    # a map with one entry builds a key node and a child node under a
    # presentation that has already said it ran out.
    let asMap = PValue(kind: pvkMap, typeName: "Table", sourceKind: "Map",
                       entries: @[PEntry(key: i("1"), val: shared)])
    let m = present(asMap, StatePanelBudget)
    ck m.expansion.reached
    ckEq m.root.keys.len, 0
    ckEq m.root.children.len, 0
    ckEq m.root.totalMembers, 1
    ckEq m.root.elided, 1
    # THE POSITIVE TWIN (§4a): the same map, with an entry small enough that
    # nothing is exhausted, really does build its key and its child — so the
    # three zeros above are a refusal and not a map arm that never worked.
    let smallMap = present(
      PValue(kind: pvkMap, typeName: "Table", sourceKind: "Map",
             entries: @[PEntry(key: i("1"), val: point())]), StatePanelBudget)
    ck not smallMap.expansion.reached
    ckEq smallMap.root.keys.len, 1
    ckEq smallMap.root.children.len, 1

  test "an exhausted rendering stops WALKING a sibling, not only charging it":
    # WHAT THE FIRST VERSION OF THIS BOUND OVERSHOT BY, AND BY HOW MUCH.
    #
    # `renderNode` used to charge `memberScanCost(v)` and run the hidden-member
    # walk UNCONDITIONALLY, above its own `tally.exhausted` return. That return
    # stops the tree DESCENDING, and the walk is not in the descent — it is in
    # the CALLER's loop. So when a child exhausted the allowance, every
    # remaining sibling still got its own `renderNode`, whose `inlineText`
    # returned the elision glyph for free and whose walk then paid a full
    # frame's charge over a member list the RECORDING sizes. Up to
    # `Budget.depth * Budget.members` of them.
    #
    # Measured on this exact value. `spent` is integer arithmetic over a fixed
    # tree, so it is identical across runs and identical in debug and release —
    # which is why this table quotes it rather than milliseconds:
    #
    #   | `renderNode`'s walk | `spent`    | over the bound |
    #   |---|---|---|
    #   | unguarded (as shipped) | 10,998,786 | **x10.49** |
    #   | guarded (as now)       |  1,048,586 | **+10 units** |
    #
    # and the difference is 9,950,200 — which is 199 siblings x 50,001 members
    # (9,950,199) plus one unit for the root's own walk, so the mechanism is
    # derived rather than inferred from the shape of the number.
    # The residue that priced this said the overshoot was "one frame's charge,
    # multiplied by nothing"; it was one frame's charge multiplied by the
    # siblings left in every loop on the stack.
    #
    # THE EQUALITY IS THE ASSERTION AND NOT AN INEQUALITY, for the reason
    # part 1 of the charge case gives: `spent` is a number a reader is invited
    # to watch approaching, so what it says after the bound is reached is as
    # much a claim as what it says before, and `+ 10` catches a one-unit drift
    # that no inequality would. `< 2 * MaxRenderWork` would have caught this
    # particular 10.49x overshoot — the argument for the equality is the
    # reported number, not this defect's magnitude.
    let rules = siblingRules()
    let shared = sharedWide()
    let p = present(exhaustingRow(shared), StatePanelBudget, presenters = rules)
    ck p.expansion.reached
    ckEq p.expansion.spent, MaxRenderWork + 10
    # …over a rendering that really did run the whole loop. A guard that
    # stopped the LOOP instead of the walk would satisfy the line above and
    # lose 199 nodes, so the child count is asserted beside it.
    ckEq p.root.text, "{"
    ckEq p.root.children.len, StatePanelBudget.members
    # THE FIRST CHILD IS THE ONE THAT SPENT IT, and it rendered before it ran
    # out — so the case is not passing because nothing happened.
    ckEq p.root.children[0].label, "boom"
    ck p.root.children[0].text.len > 10_000
    # AND AN ELIDED SIBLING STILL REPORTS A MEMBER COUNT. This is what the
    # guard costs: the count is the value's OWN, because the scan that applies
    # `hide` is the thing being skipped. Reporting 0 instead would remove the
    # expansion caret from a node whose line is already the elision glyph —
    # telling a reader there is nothing here to open.
    ckEq p.root.children[1].totalMembers, SiblingWidth + 1
    ckEq p.root.children[1].elided, SiblingWidth + 1
    ck p.root.children[1].expandable
    ckEq p.root.children[1].children.len, 0
    # THE POSITIVE TWIN (§4a). The walk is SKIPPED, not removed: the same
    # shared value rendered on its own — nothing exhausted — walks its members,
    # pays for them, and reports what it found. A `renderNode` that had stopped
    # walking altogether would satisfy every line above and redden these.
    let alone = present(shared, StatePanelBudget, presenters = rules)
    ck not alone.expansion.reached
    ckEq alone.expansion.spent, 209_548
    ckEq alone.root.totalMembers, SiblingWidth + 1
    ckEq alone.root.children.len, StatePanelBudget.members
    ckEq alone.root.elided, SiblingWidth + 1 - StatePanelBudget.members

  test "an ELIDED node still reports the rule that claimed it":
    # `chargedWinner` stops CHARGING when the allowance runs out and
    # deliberately does not stop SCANNING, and until this case that asymmetry
    # was an argument with no evidence — the whole suite is green over a
    # `chargedWinner` that answers "no rule" once exhausted, byte for byte.
    #
    # It is demonstrable, and the reason it was not demonstrated before is that
    # it needs a node that is BOTH elided AND claimed by a rule with something
    # to declare. `renderNode`'s child loop does not stop when the allowance
    # does — only the descent below each node does — so the siblings after the
    # one that exhausted the budget are still built, and each is a node whose
    # own line is the elision glyph. What such a node says about itself comes
    # from the scan: §5.3's "how it presents" and §5.2's media type are both
    # stamped from the winner, above `renderNode`'s exhaustion return.
    let rules = siblingRules()
    let shared = sharedWide()
    let p = present(exhaustingRow(shared), StatePanelBudget, presenters = rules)
    ck p.expansion.reached
    let elided = p.root.children[1]
    ckEq elided.text, Ellipsis
    ckEq elided.kind, pkImage
    ckEq elided.mediaType, "image/png"
    # AND THE TWO ELIDED SIBLINGS GIVE DIFFERENT ANSWERS, which is what makes
    # this discriminate rather than merely pass. `boom` is elided under the
    # same exhausted rendering and is claimed by a rule that declares NEITHER,
    # so it keeps the value's own shape and has no media type. A scan that
    # answered "no rule" once exhausted would make the two agree.
    ckEq p.root.children[0].kind, pkTree
    ckEq p.root.children[0].mediaType, ""
    # THE SIZE IS THE OPPOSITE DECISION AND IS ASSERTED AS SUCH.
    # `chargedMediaBytes` stops WALKING, because a byte count shown beside a
    # line that is already the elision glyph is a number nobody is reading —
    # so the elided node reports the TYPE the project declared and 0 for the
    # size, and says "this rendering did not look" rather than guessing.
    ckEq elided.mediaBytes, 0
    # THE POSITIVE TWIN (§4a) for both halves at once: the same value rendered
    # with the allowance intact carries the same declared kind and type AND a
    # real size, so neither line above is passing because the rule is inert.
    let alone = present(shared, StatePanelBudget, presenters = rules)
    ckEq alone.root.kind, pkImage
    ckEq alone.root.mediaType, "image/png"
    ckEq alone.root.mediaBytes, 8
    ckEq alone.mediaGaps.len, 1

  test "the bound counts the WORK a frame does, not the bytes it returned":
    # THE CHARGES THE FIRST VERSION OF THIS BOUND DID NOT MAKE, and the case
    # that grades each of the six it makes now. Added 2026-09-12, after a
    # verification pass measured a rendering that spent 19.5 seconds on one
    # value while `expansion.spent` reported the same 1,048,582 it reports for
    # the same declaration over a field two hundred times smaller. A bound
    # whose report is CONSTANT in the quantity being multiplied is a bound on
    # the wrong quantity, and worse than a silent one: the presentation was
    # reporting that it had honoured an allowance it had never measured.
    #
    # `spent` IS ASSERTED AS AN EQUALITY, and that is deliberate rather than
    # brittle. Every term below corresponds to exactly one charge, so removing
    # any one of them moves the number and this case says which way — which is
    # the only instrument that can grade the PER-FRAME unit, for the reason
    # written out under part 1.
    #
    # ## PART 1 — no declaration at all, so every unit is the pipeline's own
    #
    # A 200-member tuple of one-character integers at the state panel's budget
    # (members 200, depth 7, a tree). Enumerated:
    #
    #   inlineText(root)    1 (enter)
    #                     200 (`memberScanCost`, in `builtinInlineText`)
    #                     400 (200 member frames, 1 enter + 1 byte each)
    #                     600 (the root's own `(7, 7, …, 7)`)
    #   renderNode(root)  200 (`memberScanCost`, the hidden-member scan)
    #                     400 (200 child nodes, 1 enter + 1 byte each)
    #                   = 1801, of which 401 is the FRAME term
    #
    # THE FRAME TERM CAN ONLY EVER BE A CONSTANT FACTOR, which is why an
    # inequality cannot grade it and why the arm that removes it survived every
    # assertion in this file until this case existed. No rendering in this
    # pipeline returns zero bytes — the shortest is one, a summary of `{{` —
    # so the byte charge is always at least the frame count, and dropping the
    # frame charge never does worse than halve the bound. The header of
    # `inlineText` used to justify the frame charge as "a rendering that
    # produces nothing is not free"; no such rendering is constructible, and
    # the real justification is this equality: `spent` is a number a reader is
    # invited to watch approaching, and an under-count is a false report.
    var wide: seq[PMember] = @[]
    for _ in 0 ..< 200: wide.add member("", i("7"))
    let flat = PValue(kind: pvkTuple, typeName: "", sourceKind: "Tuple",
                      members: wide)
    let plain = present(flat, StatePanelBudget)
    ckEq plain.expansion.spent, 1801
    ckEq plain.root.text.len, 600
    ckEq plain.root.children.len, 200
    ck not plain.expansion.reached
    #
    # ## PART 2 — ONE byte of output, and thousands of units of work
    #
    # The disjoint half (§16a). The same value under a rule whose whole summary
    # is `{{`, so every value it claims renders as a single `{`. The byte
    # charge therefore sees ONE unit per frame and can say almost nothing,
    # while the rendering still enters 401 frames and runs 402 visualiser scans
    # over a 3-byte match:
    #
    #   inlineText(root)    1 (enter) + 4 (scan) + 1 (the byte `{`)
    #   renderNode(root)    4 (scan) + 200 (`memberScanCost`)
    #   200 children       10 each — 4 (renderNode's scan) + 1 + 4 + 1
    #                   = 2210, from a presentation whose text is one byte
    #
    # `memberScanCost` is NOT charged for the root's inline rendering here and
    # that is the point of charging it where the walk happens: the summary
    # answered, so `builtinInlineText` never ran and no member was walked.
    let brace = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Tup"
summary = "{{"
""")
    ckEq brace.visualisers.len, 1
    let oneByte = present(PValue(kind: pvkTuple, typeName: "Tup",
                                 sourceKind: "Tuple", members: wide),
                          StatePanelBudget, presenters = brace)
    ckEq oneByte.root.text, "{"
    ckEq oneByte.expansion.spent, 2210
    ck not oneByte.expansion.reached
    # AND THE POSITIVE TWIN (§4a). A charge that simply refused everything
    # would satisfy both equalities by stopping; neither rendering stopped, and
    # both rendered every member they were asked for.
    ckEq oneByte.root.children.len, 200
    #
    # ## PART 3 — the §5.2 field, which neither of the above touches
    #
    # The DOMINANT term of the finding this case was written for, and the one
    # an equality over a whole presentation grades only by accident. Two
    # renderings identical in every respect but the SIZE of the field the rule
    # names — same rule, same budget, same shape, and, because the rule also
    # hides that field, the same output byte for byte. `declaredMediaBytes`
    # walks and allocates a `seq[int]` as long as it, twice per value (once for
    # the gap, once for the node), and before this charge existed the two
    # renderings reported the same `spent`.
    let media = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "image/png"
mediaFrom = "pixels"
hide = ["pixels"]
""")
    proc withPixels(n: int): PValue =
      PValue(kind: pvkRecord, typeName: "Image", sourceKind: "Instance",
             members: @[member("width", i("64")), member("height", i("64")),
                        member("pixels", bytesOf(n))])
    let small = present(withPixels(40), StatePanelBudget, presenters = media)
    let large = present(withPixels(400), StatePanelBudget, presenters = media)
    # Identical in everything a reader sees…
    ckEq small.root.text, "Image(width:64, height:64)"
    ckEq large.root.text, small.root.text
    ckEq large.root.children.len, small.root.children.len
    ckEq small.mediaGaps.len, 1
    ckEq large.mediaGaps.len, 1
    # …and ten times the walk, which `spent` now says and did not before. TWO
    # reads per value, so the difference is twice the difference in the field.
    ckEq large.expansion.spent - small.expansion.spent, 2 * (400 - 40)
    ckEq small.expansion.spent, 167
    ckEq large.expansion.spent, 887
    # THE POSITIVE TWIN AGAIN: the size is still REPORTED, so the charge did
    # not buy the bound by declining to look.
    ckEq small.mediaGaps[0].bytes, 40
    ckEq large.mediaGaps[0].bytes, 400
    ckEq large.root.mediaBytes, 400
    #
    # ## PART 4 — resolving the NAME, which is a scan of the same member list
    #
    # `memberNamed` is an equality scan over `v.members`, and its own header
    # said so from the day it was written — "the search space is `v.members`
    # and the cost is its length" — where it read as a reassurance. It is not
    # one: a summary makes one of these per PLACEHOLDER, up to sixteen per
    # frame, and `builtinInlineText` is never reached when a summary answers,
    # so part 1's member charge does not cover it. Measured before this charge,
    # sixteen placeholders over a 100,000-member record at the state panel's
    # depth: 4,118 ms for one value, against 6 ms after.
    #
    # Two renderings of the SAME two-character text, differing only in how many
    # members the scan passes before it reaches the one the placeholders name.
    # Three scans separate them: two placeholder lookups in the inline
    # rendering, and one hidden-member scan in `renderNode`.
    let tails = presentersFrom(TailRule)
    let near = present(withFillers(400), StatePanelBudget, presenters = tails)
    let far = present(withFillers(1000), StatePanelBudget, presenters = tails)
    ckEq near.root.text, "99"
    ckEq far.root.text, near.root.text
    # Both are over the budget's 200-member cap, so the CHILD list is the same
    # length too and nothing but the scan length differs.
    ckEq near.root.children.len, 200
    ckEq far.root.children.len, 200
    ckEq far.expansion.spent - near.expansion.spent, 3 * (1000 - 400)
    ck not far.expansion.reached

  test "the rule NAMED as exhausted is the deepest one, not the outermost":
    # §16a, and the arm that survived without it. `exhaustedIn` is documented
    # FIRST-WRITER-WINS, and the first writer is the deepest frame because the
    # stack unwinds from the point the bound was reached — that is the rule
    # whose author has something to change. Every case in this file until now
    # carried ONE rule, so deepest and outermost named the same id and the
    # guard was documented behaviour with no evidence.
    #
    # TWO NESTED RULES. `Outer` wins at the root and its summary renders a
    # field of type `Inner`; `Inner`'s summary re-enters its own type sixteen
    # times, so the allowance runs out inside `Inner` and the stack unwinds
    # through `Outer`. Without the `exhaustedIn.len == 0` guard the outermost
    # frame overwrites on the way out and the report blames `Outer` — a rule
    # whose summary names one field, once, and could not reach the bound if it
    # tried.
    var summary = ""
    for _ in 0 ..< MaxTemplatePlaceholders: summary.add "{next}"
    let nested = presentersFrom(
      "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"Outer\"\nsummary = \"{inner}\"\n\n" &
      "[[visualiser]]\nmatch = \"Inner\"\nsummary = \"" & summary & "\"\n")
    ckEq nested.visualisers.len, 2
    var inner = PValue(kind: pvkRecord, typeName: "Inner",
                       sourceKind: "Instance")
    for _ in 0 ..< 4:
      inner = PValue(kind: pvkRecord, typeName: "Inner",
                     sourceKind: "Instance", members: @[member("next", inner)])
    let p = present(PValue(kind: pvkRecord, typeName: "Outer",
                           sourceKind: "Instance",
                           members: @[member("inner", inner)]),
                    StatePanelBudget, presenters = nested)
    ck p.expansion.reached
    ckEq p.expansion.visualiser, "project:.codetracer/visualisers.toml#1"
    # AND THE TWO ANSWERS ARE DIFFERENT ANSWERS, which is what makes the case
    # discriminate rather than merely pass: the ATTRIBUTION names the rule that
    # won at the root (`Outer`, #0) and the EXPANSION names the rule that was
    # spending when the allowance ran out (`Inner`, #1). A report that
    # collapsed them would be answering the attribution's question twice.
    let attribution = describeAttribution(p)
    ck attribution.contains("project:.codetracer/visualisers.toml#0 tier=")
    ck attribution.contains(
      "expansion-bounded=project:.codetracer/visualisers.toml#1")
    ck describeDegradation(p).contains(
      "visualiser 'project:.codetracer/visualisers.toml#1'")
    # THE POSITIVE TWIN. `Outer` really is reachable and really does render —
    # a rule that never claimed anything would leave #1 named for free.
    let shallow = present(PValue(kind: pvkRecord, typeName: "Outer",
                                 sourceKind: "Instance",
                                 members: @[member("inner", i("5"))]),
                          StatePanelBudget, presenters = nested)
    ckEq shallow.root.text, "5"
    ck not shallow.expansion.reached
    ckEq shallow.expansion.visualiser, ""

  test "a doubled brace is a literal brace, as the parser's validator says":
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
summary = "{{x:{x}}"
""")
    # `{{` is the escape and there is no `}}` escape: a lone `}` is an ordinary
    # character, which is what `parse.templateProblem` validates and what makes
    # the substitution one pass with nothing to balance.
    ckEq present(point(), StatePanelBudget, presenters = presenters).root.text,
         "{x:10}"

suite "PLAT-12: §5.3's 'what it hides'":

  test "a hidden field leaves the line, the children AND the totals":
    # All three, because a pane reads all three: the inline text is what a
    # one-line surface shows, `children` is what the tree draws, and
    # `totalMembers` is what decides whether there is an expansion caret at
    # all. A rule that removed the field from only the first would leave it
    # visible one click away, which is worse than not hiding it.
    let presenters = presentersFrom(MatrixRule)
    let plain = present(matrix(), StatePanelBudget)
    let hidden = present(matrix(), StatePanelBudget, presenters =
      presentersFor(loadedFrom([("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
hide = ["scratch"]
""")])))
    ck plain.root.text.contains("scratch")
    ck not hidden.root.text.contains("scratch")
    ckEq plain.root.totalMembers, 4
    ckEq hidden.root.totalMembers, 3
    var plainLabels: seq[string] = @[]
    for c in plain.root.children: plainLabels.add c.label
    var hiddenLabels: seq[string] = @[]
    for c in hidden.root.children: hiddenLabels.add c.label
    ck "scratch" in plainLabels
    ck "scratch" notin hiddenLabels
    ckEq hiddenLabels, @["rows", "cols", "data"]

  test "a hidden member does not spend the budget's member cap":
    # Counting hidden fields against the cap would show the reader an elision
    # that is a fact about the RULE rather than about the surface, and
    # `Presentation.truncated` exists to keep those apart.
    let narrow = Budget(name: "narrow", lines: 1, cells: 0, depth: 4,
                        members: 3, media: {})
    let v = PValue(kind: pvkRecord, typeName: "Wide", sourceKind: "Instance",
                   members: @[member("a", i("1")), member("secret", i("2")),
                              member("b", i("3")), member("c", i("4"))])
    let plain = present(v, narrow)
    ck plain.truncated
    ck plain.root.text.contains(Ellipsis)
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Wide"
hide = ["secret"]
""")
    let hidden = present(v, narrow, presenters = presenters)
    ckEq hidden.root.text, "Wide(a:1, b:3, c:4)"
    ck not hidden.truncated

  test "hiding renumbers nothing: a positional label is the RECORDED index":
    # `[2]` must mean the third element of the recorded sequence whether or not
    # a rule hid the second, or a reader comparing the pane against a `print`
    # is comparing two different orderings. Positional members carry no label,
    # so this is asserted through a record whose members are labelled and a
    # sequence whose members are not.
    let v = PValue(kind: pvkRecord, typeName: "Holder", sourceKind: "Instance",
                   members: @[member("a", i("1")), member("b", i("2")),
                              member("c", i("3"))])
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Holder"
hide = ["b"]
""")
    let p = present(v, StatePanelBudget, presenters = presenters)
    ckEq p.root.children.len, 2
    ckEq p.root.children[0].label, "a"
    ckEq p.root.children[1].label, "c"

  test "an EMPTY hide entry hides nothing, so no rule can erase a sequence":
    # §16a's disjoint evidence for `isHidden`'s `label.len == 0` guard, which
    # had none: every other case in this file hides a NAMED field, and a rule
    # carrying an empty name is refused by `admit` — so the guard's only
    # reachable caller is a `Visualiser` that never came through `admit`.
    #
    # THAT IS THE SAME ARGUMENT `P_UNKNOWNMEDIA` ALREADY MAKES for
    # `describeMediaGap`'s `mcUnknown` arm, with a hand-built case, and the
    # standard is applied here rather than restated: a future in-program or
    # plugin tier constructs a `Visualiser` directly, and a positional member
    # carries the label "", so a rule hiding "" would erase every element of
    # every sequence and every tuple it matched — from the line, from the
    # children AND from the totals, which is the one shape a reader cannot
    # tell apart from an empty value.
    ck not admit(VisualiserRule(match: "Row", hide: @[""]))
    let hand = Visualiser(id: "hand-built", tier: ptProjectDefinition,
                          tierDeclared: true, typeMatch: "Row",
                          matchKind: mkTypeName, hide: @[""])
    let row = PValue(kind: pvkSequence, typeName: "Row", sourceKind: "Seq",
                     members: @[member("", str("a")), member("", str("b"))])
    let plain = present(row, StatePanelBudget)
    let ruled = present(row, StatePanelBudget,
                        presenters = withVisualisers(@[hand]))
    ckEq plain.root.text, "@[\"a\", \"b\"]"
    ckEq ruled.root.text, plain.root.text
    ckEq ruled.root.totalMembers, 2
    ckEq ruled.root.children.len, 2
    ck not ruled.truncated
    # …and the same rule hiding a NAMED field still hides it, so the guard is
    # about the empty name and not about hiding (§4a's positive twin).
    let named = Visualiser(id: "hand-built-named", tier: ptProjectDefinition,
                           tierDeclared: true, typeMatch: "Point",
                           matchKind: mkTypeName, hide: @["y"])
    ckEq present(point(), StatePanelBudget,
                 presenters = withVisualisers(@[named])).root.totalMembers, 1

  test "a rule hiding a field the value does not have changes nothing":
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
hide = ["nonexistent"]
""")
    ckEq present(point(), StatePanelBudget, presenters = presenters).root.text,
         present(point(), StatePanelBudget).root.text

suite "PLAT-12: §5.3's 'how it presents'":

  test "a declared presentation replaces the node's kind":
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
present = "Table"
""")
    ckEq present(point(), StatePanelBudget).root.kind, pkTree
    ckEq present(point(), StatePanelBudget, presenters = presenters).root.kind,
         pkTable

  test "a rule that declares NO presentation leaves the value's own shape":
    # The ambiguity `VisualiserRule.presentDeclared` exists to remove: `pkText`
    # is both the enum's zero value and a legitimate declaration, and reading
    # `present` alone would flatten every matched record to a leaf.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
hide = ["y"]
""")
    ckEq present(point(), StatePanelBudget, presenters = presenters).root.kind,
         pkTree
    # And `present = "Text"` written out IS honoured, which is the other half.
    let explicit = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
present = "Text"
""")
    ckEq present(point(), StatePanelBudget, presenters = explicit).root.kind,
         pkText

  test "a declaration cannot name a presentation a VALUE cannot inhabit":
    # PLAT-11 refuses it at parse; `admit` refuses it again at the presenter
    # boundary, where a rule that never saw a file arrives.
    let loaded = loadedFrom([("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
present = "Button"
""")])
    ck not loaded.isOk
    ckEq visualisersFor(loaded).len, 0
    ck not admit(VisualiserRule(match: "Point", present: pkButton))
    for k in PresentationKind:
      ckEq admit(VisualiserRule(match: "Point", present: k)),
           k in ValuePresentationKinds

suite "PLAT-12: §5.4's precedence, and it is REPORTABLE":

  test "a declaration beats a builtin, and the report names both":
    # PLAT-2 deliverable 4's gate, applied to the tier it was built for: a user
    # can ask which presenter rendered a value and get an answer, and the
    # answer says what it beat. A visualiser that silently won over a builtin
    # with no way to ask why fails the same test.
    let presenters = presentersFrom(MatrixRule)
    let p = present(matrix(), StatePanelBudget, presenters = presenters)
    let described = describeAttribution(p)
    ck described.contains("project:.codetracer/visualisers.toml#0")
    ck described.contains("tier=project-definition")
    ck described.contains("matched=type=Matrix (typeName)")
    ck described.contains("budget=state-panel")
    ck described.contains("over=builtin.record")
    ck not described.contains("unopposed")
    ckEq attributionBadge(p),
         "via project:.codetracer/visualisers.toml#0"
    # And the builtin it beat is named in the candidate list, in the order
    # precedence considered them, winner first.
    ckEq p.attribution.candidates[0],
         "project:.codetracer/visualisers.toml#0"
    ck "builtin.record" in p.attribution.candidates

  test "with no declarations the builtin wins and says it was unopposed":
    # The control for the case above. A report that said "over=…" whatever
    # happened would be a report that cannot distinguish a contest from a
    # walkover — which `Attribution.candidates`'s own doc comment names as two
    # different facts.
    let p = present(matrix(), StatePanelBudget)
    ckEq p.attribution.tier, ptBuiltin
    ckEq p.attribution.presenter, "builtin.record"
    ck describeAttribution(p).contains("unopposed")

  test "the more specific rule wins, and the loser is still reported":
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Mat"
matchKind = "typePrefix"
summary = "prefix"

[[visualiser]]
match = "Matrix"
summary = "exact"
""")
    let p = present(matrix(), StatePanelBudget, presenters = presenters)
    ckEq p.root.text, "exact"
    ckEq p.attribution.presenter, "project:.codetracer/visualisers.toml#1"
    ck describeAttribution(p).contains(
      "over=project:.codetracer/visualisers.toml#0")

  test "the winner is chosen by RANK, not by position in the list":
    # §16a's disjoint evidence, and it was earned: `visualisersFor` hands
    # `resolve` a list ALREADY ordered by §5.4, so a `winningVisualiser` that
    # simply took the first match agrees with it on every list this product
    # builds — and an arm removing the rank comparison survived exactly that
    # way. The two mechanisms are separated here: the list is built in the
    # WRONG order by hand, and the rank alone has to decide.
    let general = Visualiser(id: "general", tier: ptProjectDefinition, tierDeclared: true,
                             typeMatch: "Mat", matchKind: mkTypePrefix,
                             summary: "general", rank: 3)
    let specific = Visualiser(id: "specific", tier: ptProjectDefinition, tierDeclared: true,
                              typeMatch: "Matrix", matchKind: mkTypeName,
                              summary: "specific", rank: 1006)
    let wrongOrder = withVisualisers(@[general, specific])
    ckEq winningVisualiser(matrix(), wrongOrder, ""), 1
    ckEq present(matrix(), StatePanelBudget, presenters = wrongOrder).root.text,
         "specific"
    # …and the same two in the other order give the same answer, which is what
    # "the rank decides" MEANS.
    let rightOrder = withVisualisers(@[specific, general])
    ckEq winningVisualiser(matrix(), rightOrder, ""), 0
    ckEq present(matrix(), StatePanelBudget, presenters = rightOrder).root.text,
         "specific"

  test "SPECIFICITY decides on a list that reached `visualisersFor` unsorted":
    # §16a's disjoint evidence for the THIRD term of `rankOf`, and it is V7's
    # and V8's defect on the same expression: `load.rankVisualisers` hands
    # `visualisersFor` a seq ALREADY ordered by §5.4, so a rank that had lost
    # its specificity term still agreed with the list's order on every input a
    # FILE produces — and `P_BYRANK` sets `rank:` by hand and never reaches
    # `rankOf` at all. An arm removing `specificity(rule)` survived both.
    #
    # So the rules below are put in the WRONG order, in a
    # `LoadedProjectDefinitions` built by hand — the same construction the
    # `MaxVisualiserRules` case uses — and driven through `visualisersFor`, so
    # `rankOf` is what computes the number and only the number can decide.
    #
    # THE OTHER TWO TERMS ARE ZERO HERE, which is what makes the evidence
    # disjoint rather than merely additional: both rules are the PROJECT's
    # (V7's origin weight is 0 for both) and both are at the root scope (V8's
    # scope depth is 0 for both).
    let loose = VisualiserRule(match: "Mat", matchKind: mkTypePrefix,
                               summary: "loose", file: "f", order: 0)
    let exact = VisualiserRule(match: "Matrix", matchKind: mkTypeName,
                               summary: "exact", file: "f", order: 1)
    ck specificity(exact) > specificity(loose)
    ckEq scopeDepth(loose.scope), scopeDepth(exact.scope)
    var unsorted = LoadedProjectDefinitions()
    unsorted.project.visualisers = @[loose, exact]
    let visualisers = visualisersFor(unsorted)
    ckEq visualisers.len, 2
    # The seq's order is the one it was given: `visualisersFor` does not sort,
    # and that is the division of labour `rankOf`'s own header describes.
    ckEq visualisers[0].id, "project:f#0"
    ckEq visualisers[1].id, "project:f#1"
    ck visualisers[1].rank > visualisers[0].rank
    let presenters = withVisualisers(visualisers)
    ckEq winningVisualiser(matrix(), presenters, ""), 1
    ckEq present(matrix(), StatePanelBudget, presenters = presenters).root.text,
         "exact"

  test "a Visualiser that never declared a TIER competes at the bottom":
    # `Visualiser.tierDeclared`, and it is `presentDeclared`'s shape with a
    # worse blast radius: `ptInProgram` is the zero value of `PresenterTier`
    # AND §5.4's highest-precedence tier, so a producer that set every other
    # field and omitted `tier` would arrive with MAXIMUM privilege, silently.
    #
    # Nothing can do that today — `visualiserFor` is the only producer and sets
    # both fields — so this is latent, exactly as `present`/`pkText` was latent
    # until a rule that only hid a field flattened every value it matched. The
    # producers §5.1 still expects (a plugin tier, PLAT-13's executable tier)
    # are the ones that would build a `Visualiser` by hand.
    let silent = Visualiser(id: "tier-was-never-declared",
                            typeMatch: "Matrix", matchKind: mkTypeName,
                            summary: "the tier nobody declared", rank: 9_999)
    ckEq silent.tier, ptInProgram          # the zero value IS the top tier
    ck not silent.tierDeclared
    ckEq effectiveTier(silent), ptBuiltin  # …and it competes at the bottom
    let declared = Visualiser(id: "project-rule", tier: ptProjectDefinition,
                              tierDeclared: true, typeMatch: "Matrix",
                              matchKind: mkTypeName, summary: "the project's",
                              rank: 0)
    ckEq effectiveTier(declared), ptProjectDefinition
    # It loses in BOTH list orders, though its rank is 9,999 against 0 — so
    # neither the list's order nor the rank is what decided.
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[silent, declared])).root.text,
         "the project's"
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[declared, silent])).root.text,
         "the project's"
    # The REPORT reads the tier through the same function the ranking does, so
    # a visualiser cannot be ranked in one tier and reported in another (§14).
    let alone = present(matrix(), StatePanelBudget,
                        presenters = withVisualisers(@[silent]))
    ckEq alone.attribution.tier, ptBuiltin
    ckEq alone.attribution.presenter, "tier-was-never-declared"
    ck describeAttribution(alone).contains("tier=builtin")
    # AND THE LEGITIMATE CASE STILL WORKS, which is the half a tightening
    # repair owes (Verification-Harness-Traps §15): a tier that WAS declared
    # keeps its precedence, including the top one.
    let author = Visualiser(id: "in-program-fn", tier: ptInProgram,
                            tierDeclared: true, typeMatch: "Matrix",
                            matchKind: mkTypeName, summary: "the author's own",
                            rank: 0)
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[declared, author])).root.text,
         "the author's own"

  test "a TIER outranks a rank, which is the order §5.4 states":
    # §5.4: *in-program function -> project definition -> plugin -> built-in*,
    # and the program's own function ranks first deliberately — "it is the
    # author's stated intent about their own type, and anything overriding it
    # should be a conscious choice rather than a precedence accident".
    #
    # `ptInProgram` and `ptPlugin` have no PRODUCER in this build (§5.1
    # mechanism 1 is not implemented and the plugin host contributes no
    # visualisers), so this is the only place the ORDER between the tiers is
    # exercised at all. It is asserted over constructed `Visualiser`s for that
    # reason, and it is the assertion that makes `Visualiser.tier` a contract
    # rather than a field nothing reads.
    let project = Visualiser(id: "project-rule", tier: ptProjectDefinition, tierDeclared: true,
                             typeMatch: "Matrix", matchKind: mkTypeName,
                             summary: "the project's", rank: 9_999)
    let inProgram = Visualiser(id: "in-program-fn", tier: ptInProgram, tierDeclared: true,
                               typeMatch: "Matrix", matchKind: mkTypeName,
                               summary: "the author's own", rank: 0)
    let plugin = Visualiser(id: "plugin-rule", tier: ptPlugin, tierDeclared: true,
                            typeMatch: "Matrix", matchKind: mkTypeName,
                            summary: "a plugin's", rank: 9_999)
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[project, inProgram])).root.text,
         "the author's own"
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[plugin, project])).root.text,
         "the project's"
    ckEq present(matrix(), StatePanelBudget,
                 presenters = withVisualisers(@[plugin, inProgram])).root.text,
         "the author's own"
    let p = present(matrix(), StatePanelBudget,
                    presenters = withVisualisers(@[plugin, project, inProgram]))
    ckEq p.attribution.tier, ptInProgram
    ckEq p.attribution.candidates,
         @["in-program-fn", "plugin-rule", "project-rule", "builtin.record"]

  test "the user's origin outranks SPECIFICITY, not merely list order":
    # §16a again: `visualisersFor` puts the user's rules first, so an arm that
    # removed the origin's weight from the RANK survived on list order alone.
    # Disjoint evidence — the project's rule is the MORE specific one, so only
    # the origin can decide.
    ck specificity(VisualiserRule(match: "Matrix", matchKind: mkTypeName)) >
       specificity(VisualiserRule(match: "Mat", matchKind: mkTypePrefix))
    let presenters = presentersFor(loadedFrom([("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "the project's exact rule"
""")], """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Mat"
matchKind = "typePrefix"
summary = "my own loose rule"
"""))
    ckEq present(matrix(), StatePanelBudget, presenters = presenters).root.text,
         "my own loose rule"

  test "a nearer package outranks a MORE SPECIFIC rule further away":
    # §16a's disjoint evidence for the SCOPE term in the rank: `rankVisualisers`
    # already sorts by scope depth, so an arm that dropped the term from the
    # number survived on the seq's order. Here the root's rule is the more
    # specific one, so nearness and specificity disagree and only the number
    # can settle it — §6's rule 4, which says nearness first and specificity
    # after.
    let presenters = presentersFor(loadedFrom([
      ("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "root, exact"
"""),
      ("packages/core", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Mat"
matchKind = "typePrefix"
summary = "nested, loose"
""")]))
    ckEq present(matrix(), StatePanelBudget, presenters = presenters).root.text,
         "nested, loose"

  test "a nearer package's rule outranks an ancestor's at equal specificity":
    # §6's composition, as PRECEDENCE rather than as an override: visualiser
    # rules are not named, so there is nothing for an override to key on, and
    # `load.nim`'s rule 4 says they are ORDERED.
    let presenters = presentersFor(loadedFrom([
      ("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "root"
"""),
      ("packages/core", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "nested"
""")]))
    let p = present(matrix(), StatePanelBudget, presenters = presenters)
    ckEq p.root.text, "nested"
    ck p.attribution.presenter.contains("packages/core")
    ck describeAttribution(p).contains("over=project:.codetracer/")

  test "a tie is decided by declaration order and BOTH sides are reported":
    # §5.4: "ties broken by declaration order and reported". Two halves, and
    # they are asserted separately: `load.reportTies` reports the tie against
    # the DEFINITION, and `Attribution.candidates` reports it against the
    # RENDERED VALUE — which is the half a user can reach from a pane.
    let loaded = loadedFrom([("", """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "first"

[[visualiser]]
match = "Matrix"
summary = "second"
""")])
    var sawTie = false
    for problem in loaded.problems:
      if problem.code == pdnRuleTieReported: sawTie = true
    ck sawTie
    let p = present(matrix(), StatePanelBudget,
                    presenters = presentersFor(loaded))
    ckEq p.root.text, "first"
    ckEq p.attribution.candidates.len, 3
    ckEq p.attribution.candidates[0],
         "project:.codetracer/visualisers.toml#0"
    ckEq p.attribution.candidates[1],
         "project:.codetracer/visualisers.toml#1"

  test "the user's own rule ranks ahead of the project's, and the id says so":
    # §6 keeps the two sets apart so a local experiment never becomes a diff;
    # that is about STORAGE. Precedence is a separate question and the answer
    # is that a user's own machine wins — visibly, because the id carries the
    # origin and a user can therefore see that they are overriding the shared
    # rule rather than wondering why the project's did nothing.
    let presenters = presentersFor(loadedFrom([("", MatrixRule)], """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "mine"
"""))
    let p = present(matrix(), StatePanelBudget, presenters = presenters)
    ckEq p.root.text, "mine"
    ck p.attribution.presenter.startsWith("user:")
    ck describeAttribution(p).contains("over=project:")

suite "PLAT-12: §5.2's media, and it degrades HONESTLY":

  test "the one medium every surface honours is rendered as media":
    # `MediaCapabilityNote`. Raw bytes are what `builtin.byte-buffer` has drawn
    # since CTUI-7, so every budget claims `application/octet-stream` — which
    # is what keeps the "this surface draws it" arm live rather than dead code
    # beside a degradation path.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "application/octet-stream"
mediaFrom = "pixels"
""")
    const Label = "<application/octet-stream, 40 bytes>"
    var clippedSurfaces = 0
    for budget in SurfaceBudgets:
      let p = present(image(), budget, presenters = presenters)
      if budget.cells > 0:
        # `flow` is 30 cells. The media label is clipped by the BUDGET, the way
        # every other rendering on that surface is — a declaration does not buy
        # a project more of the pane than the surface offered.
        inc clippedSurfaces
        ck p.truncated
        ck Label.startsWith(p.root.text[0 ..< p.root.text.len - len(Ellipsis)])
      else:
        ckEq p.root.text, Label
      ckEq p.root.kind, pkImage
      ckEq p.root.class, pcMedia
      ckEq p.root.mediaType, "application/octet-stream"
      ckEq p.root.mediaBytes, 40
      ckEq p.mediaGaps.len, 0
      ckEq describeDegradation(p), ""
    ckEq clippedSurfaces, 1

  test "a media type this surface cannot draw degrades, and the value REMAINS":
    # The requirement in one case: "a media type the current front-end cannot
    # render degrades visibly, and the rest of the value still presents".
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "image/png"
mediaFrom = "pixels"
""")
    let p = present(image(), StatePanelBudget, presenters = presenters)
    # 1. The value still presents. Not "unavailable", not a blank region.
    ck p.root.text.startsWith("Image(")
    ck p.root.text.contains("width:64")
    ck p.root.text.contains("height:64")
    ckEq p.root.children.len, 3
    # 2. The gap is there, and it knows what and where.
    ckEq p.mediaGaps.len, 1
    ckEq p.mediaGaps[0].mediaType, "image/png"
    ckEq p.mediaGaps[0].class, mcImagePng
    ckEq p.mediaGaps[0].surface, "state-panel"
    ckEq p.mediaGaps[0].bytes, 40
    ck p.mediaGaps[0].fieldPresent
    # 3. The node still says what the project said it is, so a surface that
    #    later gains the capability has something to read.
    ckEq p.root.mediaType, "image/png"
    ckEq p.root.mediaBytes, 40
    ckEq p.root.kind, pkTree
    # 4. §8.2: a NAME and a REMEDY, both asserted as substrings.
    let detail = describeDegradation(p)
    ck detail.contains("image/png")
    ck detail.contains("state-panel")
    ck detail.contains("To see it:")
    ck not detail.contains("unavailable")
    # 5. And the provenance line carries the marker, so a reader asking which
    #    visualiser drew this is told it did not get what it asked for.
    ck describeAttribution(p).contains("media-degraded=image/png")

  test "a rule pointing at a field the value lacks is its own answer":
    # Three causes, three remedies — collapsing them would tell a user to
    # switch front-ends when the declaration is simply wrong.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Point"
media = "image/png"
mediaFrom = "pixels"
""")
    let p = present(point(), StatePanelBudget, presenters = presenters)
    ckEq p.mediaGaps.len, 1
    ck not p.mediaGaps[0].fieldPresent
    ckEq p.mediaGaps[0].bytes, 0
    let detail = describeDegradation(p)
    ck detail.contains("no such field")
    ck detail.contains("mediaFrom")
    ck not detail.contains("To see it:")
    ck p.root.text.startsWith("Point(")

  test "a rule whose field is absent degrades even where the surface CAN draw":
    # §16a's disjoint evidence for `surfaceDrawsMedia`'s THIRD condition, whose
    # own doc comment says "THREE CONDITIONS, ALL OF THEM NECESSARY" and which
    # had no case of its own. The other two have arms; this one's only existing
    # case (`a rule pointing at a field the value lacks is its own answer`)
    # declares `image/png`, which condition 2 — the budget's media set —
    # already refuses on every surface in the product. So the field test was
    # never the thing deciding, and an arm removing it survived.
    #
    # `application/octet-stream` is the one class every budget claims, so
    # conditions 1 and 2 both PASS here and only the missing field stands
    # between a repository's declaration and a drawn value. Without the third
    # condition this renders `<application/octet-stream, 0 bytes>` IN PLACE OF
    # the value and reports no gap at all — a blank region with a caption,
    # which is exactly what §8.2 forbids.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "application/octet-stream"
mediaFrom = "notAField"
""")
    ckEq mediaClassOf("application/octet-stream"), mcOctetStream
    ck mcOctetStream in StatePanelBudget.media
    let p = present(image(), StatePanelBudget, presenters = presenters)
    # 1. The VALUE is what is shown, not a label standing in for it.
    ck p.root.text.startsWith("Image(")
    ck p.root.text.contains("width:64")
    ck not p.root.text.startsWith("<application/octet-stream")
    ckEq p.root.kind, pkTree
    ckEq p.root.children.len, 3
    # 2. And the gap is reported, with the remedy for a WRONG RULE rather than
    #    for a surface that cannot draw.
    ckEq p.mediaGaps.len, 1
    ck not p.mediaGaps[0].fieldPresent
    ckEq p.mediaGaps[0].class, mcOctetStream
    ckEq p.mediaGaps[0].bytes, 0
    let detail = describeDegradation(p)
    ck detail.contains("no such field")
    ck detail.contains("mediaFrom")
    ck not detail.contains("To see it:")
    # 3. THE POSITIVE TWIN over the same two conditions: the same type, the
    #    same surface, the field that IS there — drawn, with no gap.
    let present2 = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "application/octet-stream"
mediaFrom = "pixels"
""")
    let drawn = present(image(), StatePanelBudget, presenters = present2)
    ckEq drawn.root.text, "<application/octet-stream, 40 bytes>"
    ckEq drawn.mediaGaps.len, 0

  test "a media type outside §5.2's list has a remedy of its own":
    # Reachable only from a `Visualiser` that did not come through `admit` —
    # which is the point of its being reportable at all. `admit` refuses it,
    # and `describeMediaGap` still has an arm for it, so a future tier that
    # builds one cannot produce a blank.
    ck not admit(VisualiserRule(match: "Image", mediaType: "image/tiff",
                                mediaFrom: "pixels"))
    let hand = Visualiser(id: "hand-built", tier: ptProjectDefinition, tierDeclared: true,
                          typeMatch: "Image", matchKind: mkTypeName,
                          mediaType: "image/tiff", mediaFrom: "pixels")
    let p = present(image(), StatePanelBudget,
                    presenters = withVisualisers(@[hand]))
    ckEq p.mediaGaps.len, 1
    ckEq p.mediaGaps[0].class, mcUnknown
    let detail = describeDegradation(p)
    ck detail.contains("no renderer for on ANY surface")
    ck detail.contains("image/png")
    ck p.root.text.startsWith("Image(")

  test "an unclassifiable type is refused even by a surface that claims it":
    # §16a's disjoint evidence. `surfaceDrawsMedia` has two refusals, and every
    # budget in the product narrows to the same eight classes — so the
    # budget-membership test alone answered for an unclassifiable type and an
    # arm removing the CLASS test survived. A budget can name `mcUnknown`: the
    # type permits it, it is the enum's zero value, and a future budget written
    # as a range or a full-enum fold would contain it. Then only the class test
    # stands between a repository's arbitrary string and a drawn value.
    var credulous = StatePanelBudget
    credulous.media = {mcUnknown, mcOctetStream}
    let hand = Visualiser(id: "hand-built", tier: ptProjectDefinition, tierDeclared: true,
                          typeMatch: "Image", matchKind: mkTypeName,
                          mediaType: "image/tiff", mediaFrom: "pixels")
    let p = present(image(), credulous, presenters = withVisualisers(@[hand]))
    ckEq p.mediaGaps.len, 1
    ckEq p.mediaGaps[0].class, mcUnknown
    ck p.root.text.startsWith("Image(")
    # …and the same budget DOES draw the class it legitimately claims, so the
    # refusal above is about the type and not about the budget.
    let known = Visualiser(id: "known", tier: ptProjectDefinition, tierDeclared: true,
                          typeMatch: "Image", matchKind: mkTypeName,
                          mediaType: "application/octet-stream",
                          mediaFrom: "pixels")
    ckEq present(image(), credulous,
                 presenters = withVisualisers(@[known])).mediaGaps.len, 0

  test "gaps are deduplicated and bounded":
    # A member is rendered twice in an ordinary presentation — once inside its
    # parent's inline text and once as its own node — so a gap that was merely
    # appended would report one declaration twice.
    let presenters = presentersFrom("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "image/png"
mediaFrom = "pixels"
""")
    let outer = PValue(kind: pvkRecord, typeName: "Album",
                       sourceKind: "Instance",
                       members: @[member("a", image()), member("b", image())])
    let p = present(outer, StatePanelBudget, presenters = presenters)
    # Two Images, identical in every field the gap records, so ONE gap.
    ckEq p.mediaGaps.len, 1
    ck p.root.text.contains("Image(")

  test "the gap list is bounded, so a declaration cannot allocate without limit":
    # `MaxMediaGaps`. The gap list is derived from attacker-controlled
    # declarations applied to an attacker-controlled recording, and each entry
    # is a string this process allocated on behalf of a repository nobody read.
    # Nine distinct undrawable declarations, one value, eight gaps.
    var text = "schema = \"codetracer.visualisers.v1\"\n"
    var members: seq[PMember] = @[]
    for k in 0 .. MaxMediaGaps:
      text.add "\n[[visualiser]]\nmatch = \"Pic" & $k & "\"\n" &
               "media = \"image/png\"\nmediaFrom = \"pixels\"\n"
      members.add member("p" & $k,
        PValue(kind: pvkRecord, typeName: "Pic" & $k, sourceKind: "Instance",
               members: @[member("pixels", bytesOf(k + 1))]))
    let album = PValue(kind: pvkRecord, typeName: "Album",
                       sourceKind: "Instance", members: members)
    let presenters = presentersFrom(text)
    ckEq presenters.visualisers.len, MaxMediaGaps + 1
    let p = present(album, StatePanelBudget, presenters = presenters)
    ckEq p.mediaGaps.len, MaxMediaGaps
    # …and the eight that ARE shown are still true, each naming its own rule.
    var seen: seq[string] = @[]
    for g in p.mediaGaps:
      ck g.visualiser notin seen
      seen.add g.visualiser
      ck g.fieldPresent
      ckEq g.class, mcImagePng

suite "PLAT-12: rendering does not reopen what parsing excluded":

  test "the closed media set is ONE set, in both packages":
    # The grammar's list and the renderer's classification were two literals in
    # the first draft. A type one accepted and the other did not know would be
    # accepted, ranked, matched — and then blank.
    ckEq DeclarativeMediaTypes, declarableMediaTypes()
    ckEq DeclarativeMediaTypes.len, 8
    for spelling in DeclarativeMediaTypes:
      ck mediaClassOf(spelling) != mcUnknown
      ckEq mediaTypeSpelling(mediaClassOf(spelling)), spelling
    ckEq ord(high(MediaClass)) + 1, DeclarativeMediaTypes.len + 1

  test "a media type is classified by EXACT equality, never by name-lookup":
    # The adversarial edge: a media type must not select a decoder by name. So
    # nothing is split on `/`, nothing is lowercased, no parameter is stripped
    # and no prefix is tested — every near-miss below is `mcUnknown`, which is
    # the honest answer because this build has no renderer for any of them.
    for spelling in ["image/png; charset=utf-8", "IMAGE/PNG", "Image/Png",
                     " image/png", "image/png ", "image/png\x00",
                     "image/pngX", "image/", "image", "png", "*/*",
                     "image/png/../../etc/passwd", "../image/png", ""]:
      ckEq mediaClassOf(spelling), mcUnknown

  test "every bound PLAT-11 checks, `admit` checks again from the same number":
    # §16a: two mechanisms guarding one property halve the older one's mutation
    # coverage unless each has evidence only it can satisfy. `admit`'s is a
    # `VisualiserRule` that never went through `parse.nim` — which is what
    # every rule below is.
    ck admit(VisualiserRule(match: "Matrix"))
    ck not admit(VisualiserRule(match: ""))
    ck not admit(VisualiserRule(match: repeat("M", MaxTypeMatchBytes + 1)))
    ck admit(VisualiserRule(match: repeat("M", MaxTypeMatchBytes)))
    ck not admit(VisualiserRule(match: "M",
                                language: repeat("r", MaxNameBytes + 1)))
    ck not admit(VisualiserRule(match: "M",
                                summary: repeat("s", MaxSummaryBytes + 1)))
    ck not admit(VisualiserRule(match: "M", summary: "{unterminated"))
    ck not admit(VisualiserRule(match: "M", summary: "{a{b}}"))
    ck not admit(VisualiserRule(match: "M", summary: "{}"))
    var tooMany: seq[string] = @[]
    for k in 0 .. MaxHiddenFields: tooMany.add "f" & $k
    ck not admit(VisualiserRule(match: "M", hide: tooMany))
    ck not admit(VisualiserRule(match: "M",
                                hide: @[repeat("f", MaxFieldNameBytes + 1)]))
    ck not admit(VisualiserRule(match: "M", hide: @[""]))

  test "a field name carrying a path SEPARATOR is refused":
    # `mediaFrom` and `hide` are compared to member LABELS by equality and are
    # nothing else — there is no field on a `Visualiser` that names a file. The
    # refusal below is of the overlap with a path anyway, so that the name
    # cannot BECOME one by someone else's edit: no member label in any
    # recording this workspace produces contains a separator.
    #
    # SEPARATE FROM THE CONTROL-BYTE CASE BELOW, and the split is §16a's: two
    # refusals in one predicate, asserted by one case, means an arm removing
    # either is graded against evidence the other also satisfies. One case per
    # refusal is what makes each arm's kill attributable to it.
    for bad in ["../secrets", "a/b", "a\\b", "/etc/passwd", "pix/els"]:
      ck not admit(VisualiserRule(match: "M", mediaType: "image/png",
                                  mediaFrom: bad))
      ck not admit(VisualiserRule(match: "M", hide: @[bad]))

  test "a field name carrying a CONTROL byte is refused":
    # A NUL is the one that matters most: every comparison above it runs on the
    # whole string and every C API below it sees the string truncated at the
    # NUL, so the name that was checked and the name that is used are two
    # different names. The same split `containment.ppControlChar` closes for a
    # path, applied to a string that is compared to one.
    for bad in ["pix\x00els", "pix\telse", "pix\nels", "\x7f", "\x1b[0m"]:
      ck not admit(VisualiserRule(match: "M", mediaType: "image/png",
                                  mediaFrom: bad))
      ck not admit(VisualiserRule(match: "M", hide: @[bad]))

  test "the legitimate field names a language really produces are admitted":
    # The positive control for both cases above. A refusal that refused
    # everything would satisfy every `not admit` and make the feature
    # unreachable — which is the empty-set pass §4 describes, wearing a
    # security badge.
    for good in ["self", "__dict__", "r#type", "字段", "x.y", "[0]", "a-b"]:
      ck admit(VisualiserRule(match: "M", mediaType: "image/png",
                              mediaFrom: good))
      ck admit(VisualiserRule(match: "M", hide: @[good]))

  test "media and mediaFrom are refused apart, at both boundaries":
    ck not admit(VisualiserRule(match: "M", mediaType: "image/png"))
    ck not admit(VisualiserRule(match: "M", mediaFrom: "pixels"))
    ck admit(VisualiserRule(match: "M", mediaType: "image/png",
                            mediaFrom: "pixels"))

  test "the active tier is bounded by MaxVisualiserRules":
    # `winningVisualiser` scans this list once per rendered node, so its length
    # is the one number a declaration could otherwise multiply against a
    # recording's size.
    var text = "schema = \"codetracer.visualisers.v1\"\n"
    for k in 0 ..< MaxVisualiserRules + 20:
      text.add "\n[[visualiser]]\nmatch = \"T" & $k & "\"\n"
    let loaded = loadedFrom([("", text)])
    # The loader refuses the file outright past its own entry bound, which is
    # the first of the two mechanisms; the second is the slice below, and it is
    # asserted directly over a list that did not come from a file.
    ck loaded.problems.len > 0
    var many: seq[Visualiser] = @[]
    for k in 0 ..< MaxVisualiserRules + 20:
      many.add visualiserFor(VisualiserRule(match: "T" & $k), doProject, 0)
    ckEq withVisualisers(many).visualisers.len, MaxVisualiserRules + 20
    var rules: seq[VisualiserRule] = @[]
    for k in 0 ..< MaxVisualiserRules + 20:
      rules.add VisualiserRule(match: "T" & $k, file: "f", order: k)
    var synthesised = LoadedProjectDefinitions()
    synthesised.project.visualisers = rules
    ckEq visualisersFor(synthesised).len, MaxVisualiserRules

  test "a rule that names nothing loadable cannot be built, because there is no field":
    # The structural half of the argument, asserted the way PLAT-11 asserts the
    # grammar's: over the accepted keys of the table that produces these rules.
    # Not one of them takes a program, a path, an interpreter or a URL, and a
    # key that did would redden this.
    ckEq AcceptedKeys[tiVisualiser],
         @["match", "matchKind", "language", "summary", "hide", "present",
           "media", "mediaFrom"]
    for key in AcceptedKeys[tiVisualiser]:
      for forbidden in ["exec", "command", "script", "run", "shell", "eval",
                        "interpreter", "argv", "env", "cwd", "path", "file",
                        "url", "include", "load", "lib", "dll", "so"]:
        ck not key.toLowerAscii.contains(forbidden)

suite "PLAT-12: purity, and §5.5's compatibility":

  test "the same declaration renders byte-identically across runs":
    # PLAT-12's second integration test. A visualiser is a pure function of a
    # value: the presenter set is a PARAMETER, so there is no registry whose
    # order could differ between two calls.
    let first = presentersFrom(MatrixRule)
    let second = presentersFrom(MatrixRule)
    for budget in SurfaceBudgets:
      let a = present(matrix(), budget, presenters = first)
      let b = present(matrix(), budget, presenters = second)
      ckEq a.root.text, b.root.text
      ckEq describeAttribution(a), describeAttribution(b)
      ckEq describeDegradation(a), describeDegradation(b)

  test "with no visualisers the pipeline is byte-identical to PLAT-2's":
    # §5.5: "a file using none of them behaves exactly as it does today —
    # which is also the cheapest way to know the extension did not disturb the
    # evaluator". Asserted over every budget and a corpus of shapes.
    let empty = presentersFor(LoadedProjectDefinitions())
    ckEq empty.visualisers.len, 0
    let values = @[matrix(), point(), image(), bytesOf(3), i("306"),
                   str("hello"), PValue(kind: pvkNil)]
    for v in values:
      for budget in SurfaceBudgets:
        let plain = present(v, budget)
        let withEmpty = present(v, budget, presenters = empty)
        ckEq plain.root.text, withEmpty.root.text
        ckEq describeAttribution(plain), describeAttribution(withEmpty)
        ckEq plain.mediaGaps.len, 0

  test "describeVisualisers reports what is in FORCE, not what was read":
    let loaded = loadedFrom([("", MatrixRule)])
    let presenters = presentersFor(loaded)
    let described = describeVisualisers(presenters)
    ck described.contains("1 per-type visualiser(s) active")
    ck described.contains("project:.codetracer/visualisers.toml#0")
    ck described.contains("typeName 'Matrix'")
    ck described.contains("summary '{rows}x{cols}'")
    ck described.contains("hides scratch")
    ckEq describeVisualisers(BuiltinPresenters),
         "no per-type visualisers are active"

  test "every assertion in this file ran":
    # Verification-Harness-Traps §4c. A branch that returned early, a loop that
    # skipped a member or a `continue` that dropped a case cannot reach this
    # line with the right count.
    ckEq countedAssertions, ExpectedAssertions
