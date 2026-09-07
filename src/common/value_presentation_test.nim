## value_presentation_test.nim — PLAT-2's contract suite for the ONE presenter.
##
## ## NO MOCKS
##
## There is no mock in this file and none is justified, because there is nothing
## to mock: `common/value_presentation/` imports `std/strutils` and
## `std/unicode` and nothing else, so every dependency it has is the standard
## library. The values below are DATA — the same `PValue` shape
## `json_adapter.toPValue` produces from a `ct/load-locals` response and the
## same shape `common_types/utils/value_presentation_bridge.toPValue` produces
## from a `Value` — not stand-ins for a collaborator.
##
## The REAL-RECORDING half of PLAT-2's tests is
## `src/frontend/tui/tests/test_value_presentation_corpus.nim`, which opens the
## warm fixture corpus through a real `replay-server` and asserts the same
## properties over values this file cannot construct. Both are required: this
## one can reach kinds the corpus does not produce (a map, a variant, media),
## and that one can prove the wire decode is right, which no constructed value
## can.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## Every assertion goes through `ck`, and the last case asserts the tally
## against a number written from a run. A branch that returned early, a loop
## that skipped a member, or a `continue` that dropped a case cannot reach the
## end of this file with the right count.

import std/[strutils, unittest]

import value_presentation
import value_presentation/json_adapter
import std/json

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 179
  ## Written from a run. See the final case.

# ---------------------------------------------------------------------------
# Values. Built the way an adapter builds them, so a test value and a recorded
# value differ in provenance and in nothing else.
# ---------------------------------------------------------------------------

proc i(text: string; typeName = "int"): PValue =
  PValue(kind: pvkInt, text: text, typeName: typeName, sourceKind: "Int")

proc str(text: string; typeName = "str"): PValue =
  PValue(kind: pvkString, text: text, typeName: typeName, sourceKind: "String")

proc seqOf(sourceKind: string; members: varargs[PValue]): PValue =
  var acc: seq[PMember] = @[]
  for m in members:
    acc.add member("", m)
  PValue(kind: pvkSequence, typeName: "list", sourceKind: sourceKind,
         members: acc)

proc pointOf(): PValue =
  PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
         members: @[member("x", i("10")), member("y", i("20"))])

proc bigSeq(n: int): PValue =
  var acc: seq[PMember] = @[]
  for k in 0 ..< n:
    acc.add member("", i($k))
  PValue(kind: pvkSequence, typeName: "list", sourceKind: "Seq", members: acc)

proc mapOf(): PValue =
  PValue(kind: pvkMap, typeName: "dict", sourceKind: "TableKind",
         entries: @[PEntry(key: str("a"), val: i("1")),
                    PEntry(key: str("b"), val: i("2"))])

proc mediaOf(): PValue =
  PValue(kind: pvkMedia, typeName: "Image", sourceKind: "Raw",
         mediaType: "image/png", mediaBytes: 2048)

# ---------------------------------------------------------------------------

suite "PLAT-2: the vocabulary slice is PLAT-3's, and it is closed":

  test "every PresentationKind is one of PLAT-3's sixteen":
    # The vocabulary slice is only an EXTENSION POINT for PLAT-3 if every name
    # in it is a name PLAT-3 already declares. A entry spelled differently would
    # have to be renamed later, which is a replacement.
    const Plat3Vocabulary = ["Text", "Button", "Checkbox", "Toggle", "Input",
      "Select", "List", "Tree", "Table", "Tabs", "Collapsible", "Modal",
      "Menu", "ProgressIndicator", "Image", "Markdown"]
    var checked = 0
    for k in PresentationKind:
      # `pkText` -> `Text`
      let name = ($k)[2 .. ^1]
      ck name in Plat3Vocabulary
      inc checked
    # The COUNT, not "at least one" — Verification-Harness-Traps §4b.
    ck checked == 5

  test "each value kind lands on a vocabulary entry, and the mapping is total":
    var seen: set[PresentationKind] = {}
    for k in PValueKind:
      let v = PValue(kind: k)
      let p = present(v, TracepointBudget)
      seen.incl p.root.kind
      # Total: every kind renders to SOMETHING. "" is indistinguishable from
      # "the debugger has no value for this", which is the failure both prior
      # decoders' `else` arms were written to avoid — and which this assertion
      # found still reachable, on a scalar whose payload the engine omitted.
      ck p.root.text.len > 0
    ck pkText in seen
    ck pkList in seen
    ck pkTree in seen
    ck pkTable in seen

  test "an Image carries a MIME type and degrades to a line where there are no pixels":
    let p = present(mediaOf(), TracepointBudget)
    ck p.root.kind == pkImage
    ck p.root.class == pcMedia
    # Project-Definitions §5.2: "an image, at whatever fidelity the surface
    # allows". A one-line surface allows none, and what it shows instead is the
    # presenter's answer rather than a blank.
    ck p.root.text == "<image/png, 2048 bytes>"
    ck p.attribution.presenter == "builtin.media"

suite "PLAT-2: resolution precedence is stated and reportable":

  test "the winner, its tier and what it beat are on the presentation":
    let p = present(pointOf(), StatePanelBudget)
    ck p.attribution.presenter == "builtin.record"
    ck p.attribution.tier == ptBuiltin
    ck p.attribution.matched == "kind=pvkRecord"
    ck p.attribution.candidates == @["builtin.record"]
    ck describeAttribution(p).contains("builtin.record")
    ck describeAttribution(p).contains("tier=builtin")
    ck describeAttribution(p).contains("budget=state-panel")
    ck describeAttribution(p).contains("unopposed")

  test "a contested value names the loser, in precedence order":
    # A sequence of bytes matches BOTH `builtin.byte-buffer` (rank 70) and
    # `builtin.sequence` (rank 35). This is the case that makes the report a
    # precedence report rather than a lookup: the answer says who else could
    # have rendered it.
    let bytes = seqOf("Seq", i("1"), i("2"), i("255"))
    let p = present(bytes, StatePanelBudget)
    ck p.attribution.presenter == "builtin.byte-buffer"
    ck p.attribution.candidates.len == 2
    ck p.attribution.candidates[0] == "builtin.byte-buffer"
    ck p.attribution.candidates[1] == "builtin.sequence"
    ck describeAttribution(p).contains("over=builtin.sequence")
    ck p.root.text == "01 02 ff (3 bytes)"

  test "a member out of byte range takes the same value to the other presenter":
    # The rule that decides between them is the VALUE's contents — the shape a
    # NatVis rule has (Project-Definitions §5.3). `[1, 300]` is not a buffer.
    let notBytes = seqOf("Seq", i("1"), i("300"))
    let p = present(notBytes, StatePanelBudget)
    ck p.attribution.presenter == "builtin.sequence"
    ck p.attribution.candidates == @["builtin.sequence"]
    ck p.root.text == "@[1, 300]"

  test "precedence is a parameter, so a later tier wins without editing resolve":
    # PLAT-12 adds project-definition and plugin presenters. This asserts the
    # MECHANISM by which it will: a `PresenterSet` passed in, not a global
    # registry mutated. A mutable registry would make every presentation impure.
    let projectRule = PresenterRule(id: "project.point", tier: ptProjectDefinition,
                                    kinds: {pvkRecord}, rank: 10)
    var rules = @[projectRule]
    for r in BuiltinRules:
      rules.add r
    let a = resolve(pointOf(), PresenterSet(rules: rules))
    ck a.tier == ptProjectDefinition
    ck a.presenter == "project.point"
    ck a.candidates[0] == "project.point"
    ck "builtin.record" in a.candidates
    # And the built-in still wins when the project rule does not claim the kind.
    let b = resolve(i("1"), PresenterSet(rules: rules))
    ck b.presenter == "builtin.scalar"

suite "PLAT-2: the budget is an input, and the presenter returns what fits":

  test "a one-line budget yields one line and no children":
    for budget in [TracepointBudget, FlowBudget, ScratchpadBudget,
                   EventLogBudget]:
      let p = present(pointOf(), budget)
      ck p.budget.lines == 1
      ck p.root.children.len == 0
      ck not p.root.text.contains("\n")
      # The members are still REPORTED, so the surface can say there are more
      # without counting them itself.
      ck p.root.totalMembers == 2

  test "a tree budget yields children, and the same value's line is unchanged":
    let tree = present(pointOf(), StatePanelBudget)
    ck tree.root.children.len == 2
    ck tree.root.children[0].label == "x"
    ck tree.root.children[1].label == "y"
    ck tree.root.expandable
    let line = present(pointOf(), TracepointBudget)
    # THE MILESTONE'S CENTRAL CLAIM, on one value: two surfaces, one rendering,
    # differing only by what the budget let through.
    ck tree.root.text == line.root.text
    ck tree.root.class == line.root.class

  test "a member cap elides rather than the surface truncating":
    let p = present(bigSeq(600), FlowBudget)
    ck p.truncated
    ck p.root.totalMembers == 600
    # The cells budget is 30 and the ellipsis is inside it, so the rendering
    # is the SURFACE's width and was never longer.
    ck defaultMeasure(p.root.text) <= FlowBudget.cells
    ck p.root.text.endsWith("…")

  test "the cells budget is honoured for every surface that declares one":
    var withCells = 0
    for budget in SurfaceBudgets:
      if budget.cells <= 0:
        continue
      inc withCells
      let p = present(bigSeq(600), budget)
      ck defaultMeasure(p.root.text) <= budget.cells
    # Exactly one of the seven declares a cell bound today (flow, at 30).
    # Asserted as a COUNT so a budget that silently loses its bound is caught.
    ck withCells == 1

  test "SurfaceBudgets is the seven named surfaces and nothing else":
    # SEVEN, NOT SIX. PLAT-2's brief named six; `calltrace-arg` is the seventh
    # and was ADDED to the milestone's scope rather than found inside it —
    # `ui/calltrace.nim` carried a `safeCallArgText` the first migration
    # missed, and its output crosses into the scratchpad, which was already on
    # the pipeline. See `surfaces.SurfaceBudgets`.
    ck SurfaceBudgets.len == 7
    var names: seq[string] = @[]
    for b in SurfaceBudgets:
      names.add b.name
    ck names == @["state-panel", "tracepoint", "flow", "scratchpad",
                  "event-log", "tui-tree", "calltrace-arg"]

  test "depth is a budget and not a constant":
    let nested = PValue(kind: pvkRecord, typeName: "A", sourceKind: "Instance",
      members: @[member("b", PValue(kind: pvkRecord, typeName: "B",
        sourceKind: "Instance", members: @[member("c", i("1"))]))])
    let deep = present(nested, StatePanelBudget)
    ck deep.root.text == "A(b:B(c:1))"
    var shallow = TracepointBudget
    shallow.depth = 1
    let p = present(nested, shallow)
    # `depth: 1` admits ONE level of nesting below the root and cuts the next.
    ck p.root.text == "A(b:B(c:#))"
    ck p.truncated
    var flat = TracepointBudget
    flat.depth = 0
    ck present(nested, flat).root.text == "A(b:#)"

  test "an elision by the BUDGET reads differently from a short RECORDING":
    # `…` is the pane; `..` is the trace. A reader who cannot tell them apart
    # is told the debugger has no more data when the pane has no more room.
    let partial = PValue(kind: pvkSequence, typeName: "list", sourceKind: "Seq",
                         members: @[member("", i("1000"))], partial: true)
    ck present(partial, StatePanelBudget).root.text == "@[1000..]"
    let elided = present(bigSeq(300), StatePanelBudget)
    ck elided.root.text.contains("…")
    ck not elided.root.text.contains("..]")

  test "the annotated budget is what produces the second numeric base":
    ck present(i("306"), tuiRowBudget(40, focused = false)).root.text == "306"
    ck present(i("306"), tuiRowBudget(40, focused = true)).root.text ==
       "306 (0x132)"
    let field = str("0x00000000000000000000000000000000000000000000000000000000000007d0",
                    "Field")
    ck present(field, tuiRowBudget(80, focused = false)).root.text ==
       "\"0x00000000000000000000000000000000000000000000000000000000000007d0\""
    ck present(field, tuiRowBudget(80, focused = true)).root.text ==
       "0x7d0 (2000)"
    # And the SAME value at a narrower row is the same rendering, clipped —
    # not a different one.
    ck present(field, tuiRowBudget(20, focused = false)).root.text ==
       "\"0x0000000000000000…"

suite "PLAT-2: presentation is pure":

  test "the same value renders byte-identically across repeated calls":
    let v = bigSeq(120)
    var renderings: seq[string] = @[]
    for run in 0 ..< 8:
      renderings.add present(v, StatePanelBudget).root.text
    for r in renderings:
      ck r == renderings[0]

  test "two independently built copies of one value render identically":
    # Byte-identity across FRONT-ENDS reduces to this: the two adapters build
    # `PValue`s separately, and the presenter must not distinguish them by
    # identity, allocation order or anything else about how they were made.
    ck present(pointOf(), StatePanelBudget).root.text ==
       present(pointOf(), StatePanelBudget).root.text
    ck present(mapOf(), StatePanelBudget).root.text ==
       present(mapOf(), StatePanelBudget).root.text
    ck present(bigSeq(50), FlowBudget).root.text ==
       present(bigSeq(50), FlowBudget).root.text

  test "the wire adapter and the value adapter agree on one value":
    # The two paths that reach the presenter, on the same value, at the same
    # budget. `json_adapter` is the terminal's; the `Value` bridge is the
    # desktop's and is exercised by `value_presentation_bridge_test.nim`, which
    # can see `common_types`. Here the wire half is pinned.
    let node = %*{
      "kind": 6,
      "typ": {"langType": "Point", "labels": ["x", "y"]},
      "elements": [
        {"kind": 7, "i": "10", "typ": {"langType": "int"}},
        {"kind": 7, "i": "20", "typ": {"langType": "int"}}]}
    let fromWire = present(toPValue(node), StatePanelBudget)
    let fromConstructed = present(pointOf(), StatePanelBudget)
    ck fromWire.root.text == fromConstructed.root.text
    ck fromWire.root.class == fromConstructed.root.class
    ck fromWire.attribution.presenter == fromConstructed.attribution.presenter

  test "the language is an argument, never an ambient default":
    # `text_representation.textRepr` read `common_lang.CURRENT_LANG` — a
    # module-level `var` — whenever it was called without a language, which was
    # nearly every call site. So the same value rendered before and after a
    # session switch produced different bytes with no argument having changed.
    # There is no such default here: the ONLY way to get the Rust rendering is
    # to ask for it.
    let v = seqOf("Seq", i("1000"), i("2000"))
    ck present(v, TracepointBudget, plUnknown).root.text == "@[1000, 2000]"
    ck present(v, TracepointBudget, plOther).root.text == "@[1000, 2000]"
    ck present(v, TracepointBudget, plRust).root.text == "vec![1000, 2000]"
    let arr = seqOf("Array", i("1000"))
    ck present(arr, TracepointBudget, plRust).root.text == "[1000]"
    ck present(pointOf(), TracepointBudget, plRust).root.text == "Point{x:10, y:20}"

  test "a measure is part of the type's contract, so an impure one cannot be passed":
    # `PresentationMeasure` is `{.noSideEffect, gcsafe, raises: [].}`. This
    # asserts the pipeline USES the measure it is given — the negative half (a
    # measure that reads the clock does not compile) is the planted violation
    # in `ci/test/value-presentation-boundary-test.sh`, because a compile
    # failure cannot be asserted from inside the program it fails.
    func doubleWidth(s: string): int {.gcsafe, raises: [].} =
      s.len * 2
    var budget = FlowBudget
    budget.cells = 10
    let plain = present(bigSeq(20), budget)
    let doubled = present(bigSeq(20), budget, plUnknown, doubleWidth)
    ck defaultMeasure(plain.root.text) <= 10
    ck doubleWidth(doubled.root.text) <= 10
    ck doubled.root.text.len < plain.root.text.len

suite "PLAT-2: the renderings the surfaces used to disagree about":

  test "one error value, one rendering":
    # Five spellings existed: `textRepr` -> bare `msg`; `state.valueDisplayText`
    # -> bare `msg`; scratchpad's `cellText` -> `<error: msg>`;
    # `extractValueText` -> `<error: msg>`; `trace.nim` and `trace_log.nim` ->
    # `<span class="error-trace">msg</span>`, which is HTML in a value.
    let err = PValue(kind: pvkError, typeName: "Error", sourceKind: "Error",
                     text: "cannot evaluate `a + 1`")
    var unbounded = 0
    for budget in SurfaceBudgets:
      let t = present(err, budget).root.text
      if budget.cells > 0:
        # Flow declares 30 cells, so it gets 30 cells of the SAME rendering —
        # a budget difference, which is the only difference PLAT-2 permits.
        ck t == "<error: cannot evaluate `a + …"
      else:
        inc unbounded
        ck t == "<error: cannot evaluate `a + 1`>"
    # SIX of the seven declare no cell bound; `flow` is the only one that does.
    # A COUNT rather than "at least one", so a budget that silently loses or
    # gains a cell bound is a failure here.
    ck unbounded == SurfaceBudgets.len - 1
    ck present(err, TracepointBudget).root.class == pcError
    # The distinction the HTML spelling carried is now the CLASS, which every
    # medium can map — the terminal to a colour, the DOM to a class name.
    ck not present(err, TracepointBudget).root.text.contains("<span")

  test "one map, one rendering, on a surface that never had one":
    let p = present(mapOf(), StatePanelBudget)
    ck p.root.kind == pkTable
    ck p.root.text == "{\"a\": 1, \"b\": 2}"
    ck p.root.keys.len == 2
    ck p.root.children.len == 2
    ck p.root.keys[0].text == "\"a\""
    ck p.root.children[0].text == "1"

  test "a variant keeps its type and its active arm":
    let v = PValue(kind: pvkVariant, typeName: "Shape", sourceKind: "Variant",
                   variantName: "Circle",
                   members: @[member("", i("5"))])
    ck present(v, TracepointBudget).root.text == "Shape::Circle(5)"
    ck present(v, TracepointBudget).root.kind == pkTree

  test "a pointer with and without a target":
    let null = PValue(kind: pvkPointer, typeName: "ptr", sourceKind: "Pointer")
    ck present(null, TracepointBudget).root.text == "NULL"
    let p = PValue(kind: pvkPointer, typeName: "ptr", sourceKind: "Pointer",
                   text: "0x7ffd0000", target: i("42"))
    ck present(p, TracepointBudget).root.text == "0x7ffd0000 -> (42)"
    ck present(p, StatePanelBudget).root.children.len == 1
    ck present(p, StatePanelBudget).root.children[0].label == "*"

  test "the sequence delimiters follow the recorded kind":
    # `i("1000")` and not `i("1")`: a sequence whose every member is an integer
    # in `0 … 255` is a BYTE BUFFER to `builtin.byte-buffer`, which outranks
    # `builtin.sequence` — see the case below, which pins that inherited rule.
    ck present(seqOf("Seq", i("1000")), TracepointBudget).root.text == "@[1000]"
    ck present(seqOf("Set", i("1000")), TracepointBudget).root.text == "{1000}"
    ck present(seqOf("HashSet", i("1000")), TracepointBudget).root.text ==
       "HashSet{1000}"
    ck present(seqOf("OrderedSet", i("1000")), TracepointBudget).root.text ==
       "OrderedSet{1000}"
    ck present(seqOf("Array", i("1000")), TracepointBudget).root.text == "[1000]"
    ck present(seqOf("Varargs", i("1000")), TracepointBudget).root.text ==
       "varargs[1000]"

  test "the byte-buffer rule is the terminal's, inherited unchanged and now universal":
    # PINNED, INCLUDING ITS SHARP EDGE. `type_formatters.byteBufferOf` accepted
    # any sequence of at least one integer in `0 … 255`, so the terminal's
    # variables pane has rendered `@[1, 2]` as `01 02 (2 bytes)` since CTUI-7.
    # The migration keeps that rule byte for byte rather than improving it in
    # passing, because a line that moved during a mechanism change is
    # indistinguishable from a defect. What changed is its REACH: every surface
    # has it now.
    ck present(seqOf("Seq", i("1"), i("2")), TracepointBudget).root.text ==
       "01 02 (2 bytes)"
    ck present(seqOf("Seq", i("1"), i("300")), TracepointBudget).root.text ==
       "@[1, 300]"
    # An empty sequence is not a buffer, so `@[]` survives.
    ck present(seqOf("Seq"), TracepointBudget).root.text == "@[]"
    ck present(seqOf("Seq", str("1")), TracepointBudget).root.text ==
       "@[\"1\"]"

  test "a nil value is a value":
    ck present(nil, TracepointBudget).root.text == "nil"
    ck present(nil, StatePanelBudget).root.children.len == 0
    ck present(nil, TracepointBudget).attribution.presenter == "builtin.scalar"

suite "PLAT-2: the wire ordinals are the engine's":

  test "every WireKindName is at the ordinal TypeKind gives it":
    # The ordinals in `json_adapter` are a transcription of `TypeKind`, which is
    # a WIRE CONTRACT. The previous transcription in `headless_session` was
    # wrong on six kinds and nothing said so — a `String` decoded as a `Seq`, so
    # `__doc__` came back as `[]`. This is the assertion that was missing.
    #
    # It cannot import `TypeKind` (that is the whole reason `json_adapter`
    # exists), so it pins the NAMES at the ORDINALS, and
    # `value_presentation_bridge_test.nim` — which CAN see `TypeKind` — asserts
    # the other half: that `$kind` for every member equals `WireKindNames[ord]`.
    ck WireKindNames.len == 34
    ck WireKindNames[0] == "Seq"
    ck WireKindNames[tkStruct] == "Instance"
    ck WireKindNames[tkInt] == "Int"
    ck WireKindNames[tkString] == "String"
    ck WireKindNames[tkBool] == "Bool"
    ck WireKindNames[tkRaw] == "Raw"
    ck WireKindNames[tkError] == "Error"
    ck WireKindNames[tkFunction] == "FunctionKind"
    ck WireKindNames[tkTuple] == "Tuple"
    ck WireKindNames[tkNone] == "None"
    ck WireKindNames[33] == "Slice"

  test "the six kinds the previous decoder got wrong decode correctly":
    proc textOf(kind: int; extra: JsonNode): string =
      var node = %*{"kind": kind, "typ": {"langType": "t"}}
      for k, v in extra:
        node[k] = v
      present(toPValue(node), TracepointBudget).root.text
    ck textOf(tkString, %*{"text": "hi"}) == "\"hi\""
    ck textOf(tkBool, %*{"b": true}) == "true"
    ck textOf(tkBool, %*{"b": false}) == "false"
    ck textOf(tkTuple, %*{"elements": []}) == "()"
    ck textOf(tkSeq, %*{"elements": []}) == "@[]"
    ck textOf(tkRaw, %*{"r": "<function add at 0x1>"}) == "<function add at 0x1>"
    ck textOf(tkError, %*{"msg": "boom"}) == "<error: boom>"
    ck textOf(tkNone, newJObject()) == "nil"

  test "an unknown kind keeps its payload rather than rendering empty":
    let node = %*{"kind": 999, "i": "7", "typ": {"langType": "Mystery"}}
    let p = present(toPValue(node), TracepointBudget)
    ck p.root.text == "7"
    ck p.attribution.presenter == "builtin.opaque"

suite "PLAT-2: the suite measured itself":

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
