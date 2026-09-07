## value_presentation_bridge_test.nim — the DESKTOP adapter, and the wire
## contract the terminal adapter transcribes.
##
## ## WHAT ONLY THIS FILE CAN ASSERT
##
## `common/value_presentation/json_adapter.nim` cannot import `TypeKind`. That
## is not an oversight, it is the reason the module exists: `TypeKind` lives
## inside `common_types`, which is `include`d twice under incompatible
## `langstring` bindings, and `viewmodel/headless_session.nim` — the adapter's
## only consumer — cannot see either copy. So the wire ordinals are
## TRANSCRIBED there, and a transcription with nothing checking it is exactly
## how the PREVIOUS one came to be wrong on six kinds, silently, for as long as
## nobody compared a `String` against a `Seq`.
##
## This file CAN see `TypeKind`, because it is a C-backend suite that imports
## `common/types`. So it holds the other half of the check:
## `$kind == WireKindNames[ord(kind)]`, for every member. A kind inserted into
## the middle of the enum reddens this file rather than shifting every wire
## decode by one.
##
## ## AND THE CROSS-FRONT-END IDENTITY
##
## PLAT-2: "the same value renders byte-identically across runs, across
## front-ends". Across FRONT-ENDS reduces to this file, because the two
## front-ends differ in exactly one thing — which adapter their values arrive
## through — and here both adapters are reachable at once. Each case below
## builds the same value twice, once as a `Value` and once as the JSON the
## engine would have sent, and asserts the two presentations are equal byte for
## byte at every one of the six surface budgets.
##
## ## NO MOCKS
##
## The `Value`s are constructed and the JSON is written out; both are DATA in
## the shape the engine produces, not stand-ins for a collaborator. The
## real-recording half — where the JSON comes from a real `replay-server`
## instead of from this file — is
## `src/frontend/tui/tests/test_value_presentation_corpus.nim`, which is in the
## `tui` lane because it needs a trace and a server this lane does not build.

import std/[json, unittest]

import types
import lang
import value_presentation/json_adapter

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 438

# ---------------------------------------------------------------------------
# One value, two ways
# ---------------------------------------------------------------------------

type ValuePair = object
  name: string
  native: Value
  wire: JsonNode

proc pairsToCheck(): seq[ValuePair] =
  ## Every pair is the SAME recorded value expressed twice: as the `Value` the
  ## desktop receives and as the `ct/load-locals` JSON the terminal receives.
  result = @[]

  result.add ValuePair(name: "int",
    native: Value(kind: Int, i: "306", typ: Type(kind: Int, langType: "i32")),
    wire: %*{"kind": 7, "i": "306", "typ": {"langType": "i32"}})

  result.add ValuePair(name: "float",
    native: Value(kind: Float, f: "0.5", typ: Type(kind: Float, langType: "f64")),
    wire: %*{"kind": 8, "f": "0.5", "typ": {"langType": "f64"}})

  result.add ValuePair(name: "string",
    native: Value(kind: String, text: "shield online",
                  typ: Type(kind: String, langType: "str")),
    wire: %*{"kind": 9, "text": "shield online", "typ": {"langType": "str"}})

  result.add ValuePair(name: "bool",
    native: Value(kind: Bool, b: true, typ: Type(kind: Bool, langType: "bool")),
    wire: %*{"kind": 12, "b": true, "typ": {"langType": "bool"}})

  result.add ValuePair(name: "char",
    native: Value(kind: Char, c: "x", typ: Type(kind: Char, langType: "char")),
    wire: %*{"kind": 11, "c": "x", "typ": {"langType": "char"}})

  result.add ValuePair(name: "none",
    native: Value(kind: TypeKind.None, typ: Type(kind: TypeKind.None, langType: "NoneType")),
    wire: %*{"kind": 30, "typ": {"langType": "NoneType"}})

  result.add ValuePair(name: "error",
    native: Value(kind: TypeKind.Error, msg: "cannot evaluate `a + 1`",
                  typ: Type(kind: TypeKind.Error, langType: "Error")),
    wire: %*{"kind": 24, "msg": "cannot evaluate `a + 1`",
             "typ": {"langType": "Error"}})

  result.add ValuePair(name: "raw",
    native: Value(kind: Raw, r: "<function add at 0x1>",
                  typ: Type(kind: TypeKind.Raw, langType: "Object")),
    wire: %*{"kind": 16, "r": "<function add at 0x1>",
             "typ": {"langType": "Object"}})

  let seqType = Type(kind: Seq, langType: "list")
  result.add ValuePair(name: "sequence",
    native: Value(kind: Seq, typ: seqType, elements: @[
      Value(kind: Int, i: "1000", typ: Type(kind: Int, langType: "int")),
      Value(kind: Int, i: "2000", typ: Type(kind: Int, langType: "int"))]),
    wire: %*{"kind": 0, "typ": {"langType": "list"}, "elements": [
      {"kind": 7, "i": "1000", "typ": {"langType": "int"}},
      {"kind": 7, "i": "2000", "typ": {"langType": "int"}}]})

  result.add ValuePair(name: "record",
    native: Value(kind: Instance,
      typ: Type(kind: Instance, langType: "Point", labels: @["x", "y"]),
      elements: @[
        Value(kind: Int, i: "10", typ: Type(kind: Int, langType: "int")),
        Value(kind: Int, i: "20", typ: Type(kind: Int, langType: "int"))]),
    wire: %*{"kind": 6, "typ": {"langType": "Point", "labels": ["x", "y"]},
      "elements": [
        {"kind": 7, "i": "10", "typ": {"langType": "int"}},
        {"kind": 7, "i": "20", "typ": {"langType": "int"}}]})

  result.add ValuePair(name: "tuple",
    native: Value(kind: Tuple,
      typ: Type(kind: Tuple, langType: "tuple", labels: @["0", "1"]),
      elements: @[
        Value(kind: String, text: "key_000", typ: Type(kind: String, langType: "str")),
        Value(kind: Int, i: "1000", typ: Type(kind: Int, langType: "int"))]),
    wire: %*{"kind": 27, "typ": {"langType": "tuple", "labels": ["0", "1"]},
      "elements": [
        {"kind": 9, "text": "key_000", "typ": {"langType": "str"}},
        {"kind": 7, "i": "1000", "typ": {"langType": "int"}}]})

  result.add ValuePair(name: "byte-buffer",
    native: Value(kind: Seq, typ: Type(kind: Seq, langType: "bytes"), elements: @[
      Value(kind: Int, i: "0", typ: Type(kind: Int, langType: "u8")),
      Value(kind: Int, i: "17", typ: Type(kind: Int, langType: "u8")),
      Value(kind: Int, i: "255", typ: Type(kind: Int, langType: "u8"))]),
    wire: %*{"kind": 0, "typ": {"langType": "bytes"}, "elements": [
      {"kind": 7, "i": "0", "typ": {"langType": "u8"}},
      {"kind": 7, "i": "17", "typ": {"langType": "u8"}},
      {"kind": 7, "i": "255", "typ": {"langType": "u8"}}]})

  result.add ValuePair(name: "pointer-with-target",
    native: Value(kind: Pointer, address: "0x7ffd0000",
      typ: Type(kind: Pointer, langType: "ptr"),
      refValue: Value(kind: Int, i: "42", typ: Type(kind: Int, langType: "int"))),
    wire: %*{"kind": 23, "address": "0x7ffd0000", "typ": {"langType": "ptr"},
      "refValue": {"kind": 7, "i": "42", "typ": {"langType": "int"}}})

  result.add ValuePair(name: "enum-named",
    native: Value(kind: Enum, enumInt: 1,
      typ: Type(kind: Enum, langType: "Colour", enumNames: @["Red", "Green"])),
    wire: %*{"kind": 17, "i": "1",
      "typ": {"langType": "Colour", "labels": ["Red", "Green"]}})

  result.add ValuePair(name: "enum-out-of-range",
    native: Value(kind: Enum, enumInt: 7,
      typ: Type(kind: Enum, langType: "Colour", enumNames: @["Red", "Green"])),
    wire: %*{"kind": 17, "i": "7",
      "typ": {"langType": "Colour", "labels": ["Red", "Green"]}})

suite "PLAT-2: the wire ordinals in json_adapter ARE TypeKind's":

  test "every TypeKind member is at the ordinal WireKindNames gives it":
    # THE HALF `json_adapter` CANNOT ASSERT ABOUT ITSELF. The previous
    # transcription (in `headless_session`) disagreed with the wire on six
    # kinds: a `String` decoded as a `Seq` — so `__doc__` came back as `[]`, an
    # empty LIST where the program has text — a `Bool`, a `Tuple`, a `Seq`, a
    # `Raw` and an `Error` all decoded to "". Nothing said so, because nothing
    # compared the two enumerations.
    var compared = 0
    for kind in TypeKind:
      let ordinal = ord(kind)
      checkpoint($kind & " is ordinal " & $ordinal)
      ck ordinal < WireKindNames.len
      ck WireKindNames[ordinal] == $kind
      inc compared
    # THE COUNT, because the membership is knowable
    # (Verification-Harness-Traps §4b): `TypeKind` has 34 members and
    # `WireKindNames` must be exactly as long. An "at least one" control here
    # would be satisfied by `Seq` alone.
    ck compared == 34
    ck WireKindNames.len == 34

  test "the named ordinal constants agree with TypeKind":
    ck tkSeq == ord(Seq)
    ck tkStruct == ord(Instance)
    ck tkInt == ord(Int)
    ck tkString == ord(String)
    ck tkBool == ord(Bool)
    ck tkRaw == ord(TypeKind.Raw)
    ck tkError == ord(TypeKind.Error)
    ck tkTuple == ord(Tuple)
    ck tkNone == ord(TypeKind.None)
    ck tkSlice == ord(Slice)

suite "PLAT-2: one value, two front-ends, the same bytes":

  test "every pair renders identically at every surface budget":
    let pairs = pairsToCheck()
    var compared = 0
    for pair in pairs:
      let native = toPValue(pair.native)
      let wire = json_adapter.toPValue(pair.wire)
      for budget in SurfaceBudgets:
        let a = present(native, budget)
        let b = present(wire, budget)
        checkpoint(pair.name & " @ " & budget.name & ": native='" &
                   a.root.text & "' wire='" & b.root.text & "'")
        ck a.root.text == b.root.text
        ck a.root.class == b.root.class
        ck a.attribution.presenter == b.attribution.presenter
        inc compared
    # 15 pairs x 7 budgets. Written out so a pair that stopped being built, or
    # a budget that vanished from `SurfaceBudgets`, is a failure rather than a
    # smaller run. SEVEN because `calltrace-arg` joined `SurfaceBudgets` — see
    # `surfaces.nim`.
    ck pairs.len == 15
    ck compared == 15 * SurfaceBudgets.len
    ck SurfaceBudgets.len == 7

  test "the desktop bridge maps every TypeKind onto a PValue kind":
    # Total, and asserted over the whole enum rather than over the kinds a
    # corpus happens to produce: an unmapped kind used to render as "".
    var mapped = 0
    for kind in TypeKind:
      let v = Value(kind: kind, typ: Type(kind: kind, langType: "T"))
      let p = present(toPValue(v), TracepointBudget)
      checkpoint($kind & " -> '" & p.root.text & "'")
      ck p.root.text.len > 0
      inc mapped
    ck mapped == 34

suite "PLAT-2: the language is an argument here too":

  test "presentValue takes the language and has no ambient default":
    let v = Value(kind: Seq, typ: Type(kind: Seq, langType: "Vec<i32>"),
      elements: @[Value(kind: Int, i: "1000", typ: Type(kind: Int, langType: "i32"))])
    ck presentValueText(v, TracepointBudget, LangUnknown) == "@[1000]"
    ck presentValueText(v, TracepointBudget, LangRust) == "vec![1000]"
    ck presentValueText(v, TracepointBudget, LangPythonDb) == "@[1000]"
    # `CURRENT_LANG` is `common_lang`'s module-level `var`, and the point is
    # that setting it changes NOTHING here. `textRepr` read it whenever it was
    # called without a language, which was nearly every call site — so the same
    # value rendered before and after a session switch produced different bytes
    # with no argument having changed.
    let before = presentValueText(v, TracepointBudget)
    lang.CURRENT_LANG = LangRust
    let after = presentValueText(v, TracepointBudget)
    lang.CURRENT_LANG = LangUnknown
    checkpoint("with CURRENT_LANG=LangRust: '" & after & "'")
    ck before == after
    ck after == "@[1000]"

suite "PLAT-2: the suite measured itself":

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
