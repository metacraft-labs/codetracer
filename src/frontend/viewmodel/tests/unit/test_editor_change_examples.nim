## PLAT-25 — the boundary EXAMPLES, the typed mapping outcome, and the
## transaction.
##
## Subjects: `viewmodel/editor/change_set.nim` and
## `viewmodel/editor/transaction.nim`.
##
## =========================================================================
## WHY EXAMPLES, BESIDE THE LAWS RATHER THAN INSTEAD OF THEM
## =========================================================================
##
## Editor-Model-Conformance-Suite.md §2: an example is *"the only kind of test
## that carries the exact boundary a human once noticed"*. PLAT-25's
## integration bullet asks for the cases
## `codemirror-state/test/test-change.ts` exercises by hand, re-expressed
## against this encoding — and re-expressed is the operative word. The
## reference asserts against a STRING rendering of its flat `number[]`
## (`"2 0:2 2"`), so the port needs a rendering of the variant that says the
## same thing, and `descOf` is it: `keep n` prints `n`, `replace d with m
## bytes` prints `d:m`. Where the reference's expected string is quoted below,
## it is quoted verbatim from `test-change.ts` with its line number, so a
## reader can diff the two by eye.
##
## **EIGHTEEN of them, which is a term of PLAT-25's floor.** The count is
## asserted in a case of its own against the enumerated list, so the floor's
## third term moves when the list does.
##
## =========================================================================
## `over` AND `under`, AND WHY THEY ARE BOTH `rebase`
## =========================================================================
##
## The reference's mapping tests call `a.mapDesc(b)` and `a.mapDesc(b, true)`.
## Neither spelling exists here: the flag is private (`change_set.nim`'s
## header). The translation is exact and is spelled once, in `over` and
## `under` below —
##
##     over(a, b)   ==  a.map(b, before = false)  ==  rebase(b, a).bOverA
##     under(a, b)  ==  a.map(b, before = true)   ==  rebase(a, b).aOverB
##
## — so the eighteen examples are eighteen more calls of the ONE primitive
## rather than a second path into it. That is deliberate: if the examples
## reached `mapOver` directly they would be a second copy of the thing under
## test (Verification-Harness-Traps §30), and the mutation arm on `before`
## would kill them for the wrong reason.
##
## ARMING: `run-plat25-change-algebra-mutations.py`.

import std/[options, strutils, unittest]

import ../../editor/change_set
import ../../editor/transaction

# ---------------------------------------------------------------------------
# Counted assertions — `CHECKS:` for the lane, and the constant it falls back
# to when a suite dies before printing anything (Conformance Suite §10.1).
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 226
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# `mk` and `descOf` — the reference's notation, both directions
# ---------------------------------------------------------------------------

proc mk(spec: string): ChangeSet =
  ## `test-change.ts:4-12`, re-expressed. `"2 0:2 2"` is keep 2, replace 0
  ## bytes with 2, keep 2. The inserted text is filler, because the reference's
  ## `ChangeDesc` carries no text and the examples ported here are about
  ## SHAPE. Where an example is about text, it builds its change set with
  ## `changeSet` instead and says so.
  var edits: seq[Edit] = @[]
  var pos = 0
  for tok in spec.splitWhitespace():
    let colon = tok.find(':')
    if colon < 0:
      pos += parseInt(tok)
    else:
      let del = parseInt(tok[0 ..< colon])
      let ins = parseInt(tok[colon + 1 .. ^1])
      edits.add Edit(fromPos: pos, toPos: pos + del, insert: repeat('x', ins))
      pos += del
  changeSet(pos, edits)

proc descOf(cs: ChangeSet): string =
  ## The variant, rendered in the reference's notation so the expected strings
  ## below can be quoted from `test-change.ts` unchanged.
  var parts: seq[string] = @[]
  for s in cs.sections:
    case s.kind
    of skKeep: parts.add $s.keep
    of skReplace: parts.add $s.delete & ":" & $s.insert.len
  parts.join(" ")

proc comp(specs: varargs[string]): string =
  ## Fold `composeDesc` over every spec but the last, which is the expectation.
  var sets: seq[ChangeSet] = @[]
  for i in 0 ..< specs.len - 1: sets.add mk(specs[i])
  var acc = sets[0]
  for i in 1 ..< sets.len: acc = compose(acc, sets[i])
  descOf(acc)

proc over(a, b: string): string =
  ## `mk(a).mapDesc(mk(b))` — the reference's default, `before = false`.
  descOf(rebase(mk(b), mk(a)).bOverA)

proc under(a, b: string): string =
  ## `mk(a).mapDesc(mk(b), true)` — `before = true`.
  descOf(rebase(mk(a), mk(b)).aOverB)

const PortedExamples = [
  "compose: unrelated changes",
  "compose: an insertion cancelled by a deletion",
  "compose: adjacent insertions join",
  "compose: adjacent deletions join",
  "compose: a delete shadows multiple operations",
  "compose: the empty set, on both sides",
  "compose: multiple replaces join",
  "compose: inconsistent lengths are refused",
  "rebase: over an insertion",
  "rebase: over a deletion",
  "rebase: insertions at one point are ordered by the primitive, not by a flag",
  "rebase: a deletion over an overlapping replace",
  "rebase: changes after the mapped one",
  "rebase: deletions join",
  "rebase: an insertion inside a deletion is kept",
  "rebase: replacements are kept",
  "rebase: replacements do not join, and a duplicate deletion drops",
  "rebase: overlapping replaces",
]
  ## §10.4 rule 3: the floor's third term is **18**, and it is this list's
  ## length rather than a number somebody typed into the milestone.

suite "PLAT-25 examples — composition, ported from test-change.ts":

  test PortedExamples[0]:
    # test-change.ts:39-40
    counted comp("5 0:2", "1 2:0 4", "1 2:0 2 0:2") == "1 2:0 2 0:2"

  test PortedExamples[1]:
    # test-change.ts:42-43
    counted comp("2 0:2 2", "2 2:0 2", "4") == "4"

  test PortedExamples[2]:
    # test-change.ts:45-46
    counted comp("2 0:2 2", "4 0:3 2", "2 0:5 2") == "2 0:5 2"

  test PortedExamples[3]:
    # test-change.ts:48-49
    counted comp("2 5:0", "1 1:0", "1 6:0") == "1 6:0"

  test PortedExamples[4]:
    # test-change.ts:51-52
    counted comp("2 2:0 0:3", "5:0", "4:0") == "4:0"

  test PortedExamples[5]:
    # test-change.ts:54-55. FIVE specs folded, three of them empty — the arm
    # that exists because the reference's `this.empty ? other` shortcut is
    # deliberately NOT ported here (`change_set.nim`, `compose`). Without that
    # decision this example would be testing an `if`.
    counted comp("", "0:8", "8:0", "", "") == ""

  test PortedExamples[6]:
    # test-change.ts:57-61
    counted comp("2 2:2 2:2 2", "1 2:2 2:2 2:2 1", "1 6:6 1") == "1 6:6 1"
    counted comp("1 2:2 2:2 2:2 1", "2 2:2 2:2 2", "1 6:6 1") == "1 6:6 1"
    counted comp("1 2:3 3:2 1", "2 3:1 2", "1 5:3 1") == "1 5:3 1"

  test PortedExamples[7]:
    # test-change.ts:63-67. A refusal is a typed value here — `ChangeSetError`
    # — rather than a bare `Error`, and the three cases are the reference's.
    expect ChangeSetError: discard compose(mk("2 0:2"), mk("1 0:1"))
    expect ChangeSetError: discard compose(mk("2 0:2"), mk("30 0:1"))
    expect ChangeSetError: discard compose(mk("2 2:0 0:3"), mk("7:0"))
    counted true    # reached only if all three raised

suite "PLAT-25 examples — rebase, ported from test-change.ts":

  test PortedExamples[8]:
    # test-change.ts:78-79
    counted over("4 0:1", "0:3 4") == "7 0:1"

  test PortedExamples[9]:
    # test-change.ts:81-82
    counted over("4 0:1", "2:0 2") == "2 0:1"

  test PortedExamples[10]:
    # test-change.ts:84-87. **THE EXAMPLE THIS MILESTONE IS ABOUT.** The same
    # two change sets, the same single point, and the answer differs only by
    # which side is understood to come first — which in the reference is a
    # boolean a caller passes and here is which arm of `rebase` is read.
    counted over("2 0:1 2", "2 0:1 2") == "3 0:1 2"
    counted under("2 0:1 2", "2 0:1 2") == "2 0:1 3"
    # And stated once more as the primitive rather than as two helpers, so the
    # example cannot be satisfied by two unrelated calls that happen to agree.
    let r = rebase(mk("2 0:1 2"), mk("2 0:1 2"))
    counted descOf(r.aOverB) == "2 0:1 3"
    counted descOf(r.bOverA) == "3 0:1 2"

  test PortedExamples[11]:
    # test-change.ts:89-92 — the one place the reference asserts that BOTH
    # arms give the same answer, which is what makes it a boundary.
    counted over("2 2:0", "2 1:2 1") == "4 1:0"
    counted under("2 2:0", "2 1:2 1") == "4 1:0"

  test PortedExamples[12]:
    # test-change.ts:94-95
    counted over("0:1 2:0 8", "6 1:0 0:5 3") == "0:1 2:0 12"

  test PortedExamples[13]:
    # test-change.ts:97-98
    counted over("5:0 2 3:0 2", "4 4:0 4") == "6:0 2"

  test PortedExamples[14]:
    # test-change.ts:100-103
    counted under("2 0:1 2", "4:0") == "0:1"
    counted over("4 0:1 4", "2 4:0 2") == "2 0:1 2"

  test PortedExamples[15]:
    # test-change.ts:105-111
    counted over("2 2:2 2", "0:2 6") == "4 2:2 2"
    counted over("2 2:2 2", "3:0 3") == "1:2 2"
    counted over("1 4:4 1", "3 0:2 3") == "1 2:4 2 2:0 1"
    counted over("1 4:4 1", "2 2:0 2") == "1 2:4 1"
    counted over("2 2:2 2", "3 2:0 1") == "2 1:2 1"

  test PortedExamples[16]:
    # test-change.ts:113-120. Two reference cases in one block, because they
    # are the two halves of one claim about section identity: adjacent
    # replacements stay two sections, and two identical deletions become none.
    counted over("2:2 2 2:2", "2 2:0 2") == "2:2 2:2"
    counted under("2 2:0 2", "2 2:0 2") == "4"
    counted over("2 2:0 2", "2 2:0 2") == "4"

  test PortedExamples[17]:
    # test-change.ts:122-129
    counted over("1 1:2 1", "1 1:1 1") == "2 0:2 1"
    counted under("1 1:2 1", "1 1:1 1") == "1 0:2 2"
    counted over("1 1:2 2", "1 2:1 1") == "1 0:2 2"
    counted over("2 1:2 1", "1 2:1 1") == "2 0:2 1"
    counted over("2:1 1", "1 2:2") == "1:1 2"
    counted over("1 2:1", "2:2 1") == "2 1:1"

suite "PLAT-25 examples — the list itself":

  test "eighteen ported examples, counted rather than claimed":
    # The floor's third term. A list a check can count (§10.4 rule 3).
    counted PortedExamples.len == 18
    var seen: seq[string] = @[]
    for name in PortedExamples:
      counted name notin seen
      counted name.len > 0
      seen.add name

# ===========================================================================
# THE TYPED MAPPING OUTCOME AT THE BOUNDARIES — 2 sides x 3 arms x 4 shapes
# ===========================================================================
#
# PLAT-25's floor derives 24 cases from this cross product, and the cell is
# the unit: for one side, one arm and one edit shape, either the shape
# PRODUCES that arm somewhere in the document — and then the witness's fields
# are asserted — or it CANNOT, and the absence is asserted over every position
# rather than left out.
#
# An absent cell and an impossible cell look identical in a pass
# (Conformance Suite §5.1's rule about unrepresentable rows, applied to
# outcomes), so both are written and both can fail: a mapping that started
# reporting `deleted` for a pure insertion breaks a "cannot" cell, and one
# that stopped reporting `collapsed` for a pure deletion breaks a "must".

type EditShape = enum
  esInsert
  esDelete
  esReplace
  esMixed

const ShapeDocLen = 8

proc shapeSet(s: EditShape): ChangeSet =
  case s
  of esInsert: changeSet(ShapeDocLen, 4, 4, "XY")
  of esDelete: changeSet(ShapeDocLen, 2, 6, "")
  of esReplace: changeSet(ShapeDocLen, 2, 6, "XY")
  of esMixed: changeSet(ShapeDocLen, [Edit(fromPos: 1, toPos: 1, insert: "A"),
                                      Edit(fromPos: 2, toPos: 4, insert: ""),
                                      Edit(fromPos: 5, toPos: 7, insert: "BC")])

proc arms(s: EditShape; side: Side): seq[Mapped] =
  ## Every position of the document, mapped. Totality is a property of this
  ## sweep rather than an assertion beside it: `mapPos` returns a variant, so
  ## a position that produced no arm could not have got here.
  result = @[]
  let cs = shapeSet(s)
  for p in 0 .. ShapeDocLen:
    result.add cs.mapPos(p, side)

proc countArm(ms: seq[Mapped]; k: MappedKind): int =
  for m in ms:
    if m.kind == k: inc result

const ArmIsPossible: array[EditShape, array[MappedKind, bool]] = [
  #            survived  deleted  collapsed
  esInsert:  [true,     false,   false],
  esDelete:  [true,     false,   true ],
  esReplace: [true,     true,    false],
  esMixed:   [true,     true,    true ],
]
  ## The oracle for the 24 cells, written from §6.2's definition of the arms
  ## rather than from a run: a pure insertion deletes nothing, a pure deletion
  ## replaces nothing with new text, a replacement collapses nothing to a
  ## point, and the mixed shape does all three.

suite "PLAT-25 — the typed mapping outcome, 2 sides x 3 arms x 4 shapes":

  for shape in EditShape:
    for side in Side:
      for arm in MappedKind:
        test "typed mapping: " & $shape & " / " & $side & " / " & $arm:
          let ms = arms(shape, side)
          counted ms.len == ShapeDocLen + 1
          let n = ms.countArm(arm)
          if ArmIsPossible[shape][arm]:
            checkpoint($shape & " must produce " & $arm & " somewhere")
            counted n > 0
            # The witness's own fields, so the arm is not merely tagged.
            for m in ms:
              if m.kind == arm:
                case m.kind
                of mapSurvived:
                  counted m.pos >= 0
                  counted m.pos <= shapeSet(shape).newLength
                of mapDeleted:
                  counted m.deletedFrom < m.deletedTo
                  counted m.landing >= 0
                of mapCollapsed:
                  counted m.collapsedFrom < m.collapsedTo
                  counted m.at >= 0
                break
          else:
            checkpoint($shape & " must never produce " & $arm)
            counted n == 0

suite "PLAT-25 — the typed outcome's two-sidedness":

  test "the side decides exactly where a zero-width insertion is, and nowhere else":
    # The claim §6.2 makes about `Side`, two-sided. A model that ignored the
    # parameter passes the second half; one that applied it everywhere passes
    # the first.
    let ins = shapeSet(esInsert)
    counted ins.mapPos(4, sideBefore) == Mapped(kind: mapSurvived, pos: 4)
    counted ins.mapPos(4, sideAfter) == Mapped(kind: mapSurvived, pos: 6)
    var differing = 0
    var same = 0
    for p in 0 .. ShapeDocLen:
      if ins.mapPos(p, sideBefore) == ins.mapPos(p, sideAfter): inc same
      else: inc differing
    counted differing == 1            # only the insertion point
    counted same == ShapeDocLen       # every other position

  test "a collapsed range answers the same on both sides, and a replaced one does not":
    let del = shapeSet(esDelete)
    counted del.mapPos(4, sideBefore) == del.mapPos(4, sideAfter)
    counted del.mapPos(4, sideBefore).kind == mapCollapsed
    let rep = shapeSet(esReplace)
    counted rep.mapPos(4, sideBefore).kind == mapDeleted
    counted rep.mapPos(4, sideAfter).kind == mapDeleted
    counted rep.mapPos(4, sideBefore).landing != rep.mapPos(4, sideAfter).landing

  test "a position outside the document is refused, not clamped":
    let cs = shapeSet(esReplace)
    expect ChangeSetError: discard cs.mapPos(-1, sideBefore)
    expect ChangeSetError: discard cs.mapPos(ShapeDocLen + 1, sideBefore)
    counted true

# ===========================================================================
# ITERATION OVER CHANGED RANGES — the coalescing parameter
# ===========================================================================

suite "PLAT-25 — changed ranges, coalesced and individual":

  test "adjacent changes are one range by default and two on request":
    # test-change.ts:227-237, extended: the reference iterates once. §6 makes
    # the difference a PARAMETER, so both answers are asserted here and the
    # two are asserted to DIFFER on the input that distinguishes them.
    let set0 = changeSet(10, [Edit(fromPos: 4, toPos: 4, insert: "ok"),
                              Edit(fromPos: 6, toPos: 8, insert: "")])
    let coalesced = set0.changedRangeSeq()
    let individual = set0.changedRangeSeq(individual = true)
    counted individual.len == 2
    counted individual[0] == ChangedRange(fromA: 4, toA: 4, fromB: 4, toB: 6,
                                          inserted: "ok")
    counted individual[1] == ChangedRange(fromA: 6, toA: 8, fromB: 8, toB: 8,
                                          inserted: "")
    counted coalesced.len == 2        # separated by a keep, so not adjacent

    # Now the adjacent input, where the two modes must disagree.
    let adj = changeSet(10, [Edit(fromPos: 4, toPos: 6, insert: ""),
                             Edit(fromPos: 6, toPos: 6, insert: "ok")])
    counted adj.changedRangeSeq(individual = true).len == 2
    counted adj.changedRangeSeq().len == 1
    let one = adj.changedRangeSeq()[0]
    counted one.fromA == 4
    counted one.toA == 6
    counted one.inserted == "ok"

  test "the ranges reproduce the document, which is what makes them a partition":
    let doc = "0123456789"
    let cs = changeSet(10, [Edit(fromPos: 2, toPos: 4, insert: "AB"),
                            Edit(fromPos: 7, toPos: 7, insert: "C")])
    var rebuilt = ""
    var at = 0
    for r in cs.changedRanges():
      rebuilt.add doc[at ..< r.fromA]
      rebuilt.add r.inserted
      at = r.toA
    rebuilt.add doc[at ..< doc.len]
    counted rebuilt == cs.apply(doc)
    counted rebuilt == "01AB456C789"

# ===========================================================================
# CONSTRUCTION, APPLICATION AND INVERSION — the `ChangeSet` examples
# ===========================================================================

suite "PLAT-25 — construction and application, ported":

  test "change sets are built from unordered, colliding edit lists":
    # test-change.ts:183-194
    counted descOf(changeSet(10, 5, 5, "hi")) == "5 0:2 5"
    counted descOf(changeSet(10, 5, 7, "")) == "5 2:0 3"
    # The colliding list goes through `changeSetOrdered`, which is the
    # reference's order-sensitive constructor and the SECOND in-tree call site
    # of `rebase`: the insertion at 5 lands inside the deletion [4, 6) and
    # splits it, which is only expressible when a later edit can be rebased
    # over an earlier one.
    counted descOf(changeSetOrdered(10, [
      Edit(fromPos: 5, toPos: 5, insert: "hi"),
      Edit(fromPos: 5, toPos: 5, insert: "ok"),
      Edit(fromPos: 0, toPos: 3, insert: ""),
      Edit(fromPos: 4, toPos: 6, insert: ""),
      Edit(fromPos: 8, toPos: 8, insert: "boo")])) ==
      "3:0 1 1:0 0:4 1:0 2 0:3 2"

  test "an overlapping edit list is refused":
    # NOT in the reference, which silently tolerates some shapes. An overlap
    # is a caller error and a typed refusal is cheaper than the change set it
    # would otherwise build.
    expect ChangeSetError:
      discard changeSet(10, [Edit(fromPos: 2, toPos: 6, insert: ""),
                             Edit(fromPos: 4, toPos: 8, insert: "")])
    expect ChangeSetError:
      discard changeSet(10, [Edit(fromPos: 2, toPos: 12, insert: "")])
    counted true

  test "apply, compose-and-apply, and the clipped insert":
    # test-change.ts:195-215
    let doc10 = "0123456789"
    counted changeSet(10, 2, 2, "ok").apply(doc10) == "01ok23456789"
    counted changeSet(10, 1, 9, "").apply(doc10) == "09"
    counted changeSet(10, [Edit(fromPos: 1, toPos: 1, insert: "hi"),
                           Edit(fromPos: 2, toPos: 8, insert: "")]).apply(doc10) ==
      "0hi189"
    counted compose(changeSet(10, 8, 8, "ABCD"),
                    changeSet(14, 8, 11, "")).apply(doc10) == "01234567D89"
    counted compose(
      changeSet(10, [Edit(fromPos: 2, toPos: 2, insert: "hi"),
                     Edit(fromPos: 8, toPos: 8, insert: "ok")]),
      changeSet(14, [Edit(fromPos: 4, toPos: 4, insert: "!"),
                     Edit(fromPos: 6, toPos: 8, insert: ""),
                     Edit(fromPos: 12, toPos: 12, insert: "?")])).apply(doc10) ==
      "01hi!2367ok?89"
    # "can clip inserted strings on compose" — the case that proves `textBit`
    # slices rather than copies whole.
    counted compose(
      changeSet(10, [Edit(fromPos: 2, toPos: 2, insert: "abc"),
                     Edit(fromPos: 4, toPos: 4, insert: "def")]),
      changeSet(16, 4, 8, "")).apply(doc10) == "01abef456789"

  test "a rebased set applies, and an inverted one round-trips":
    # test-change.ts:216-225
    let doc10 = "0123456789"
    let set0 = changeSet(10, [Edit(fromPos: 5, toPos: 5, insert: "hi"),
                              Edit(fromPos: 8, toPos: 10, insert: "")])
    let set1 = changeSet(10, [Edit(fromPos: 6, toPos: 7, insert: ""),
                              Edit(fromPos: 10, toPos: 10, insert: "ok")])
    counted compose(set0, rebase(set0, set1).bOverA).apply(doc10) == "01234hi57ok"
    counted invert(set0, doc10).apply(set0.apply(doc10)) == doc10

  test "apply refuses a document of the wrong length":
    expect ChangeSetError: discard changeSet(10, 1, 2, "").apply("short")
    expect ChangeSetError: discard invert(changeSet(10, 1, 2, ""), "short")
    counted true

# ===========================================================================
# SERIALISATION
# ===========================================================================

suite "PLAT-25 — the wire form":

  test "the encoding is byte-transparent and length-prefixed":
    # The corpus contains an embedded NUL, bare continuation bytes and every
    # line terminator Unicode has. A delimiter encoding would be an encoding
    # with a document that breaks it, so the reader is told how many bytes to
    # take.
    let nasty = "a\x00b\r\n\xC3\x28;K5:R"
    let cs = changeSet(6, 2, 4, nasty)
    let wire = encodeChangeSet(cs)
    counted wire.startsWith(ChangeSetWireVersion)
    counted decodeChangeSet(wire) == cs
    counted decodeChangeSet(wire).apply("abcdef") == "ab" & nasty & "ef"
    # Deterministic: the same value, twice, is the same bytes.
    counted encodeChangeSet(cs) == wire

  test "a malformed wire is refused by name":
    expect ChangeSetError: discard decodeChangeSet("")
    expect ChangeSetError: discard decodeChangeSet("XX1|K5;")
    expect ChangeSetError: discard decodeChangeSet(ChangeSetWireVersion & "Q5;")
    expect ChangeSetError: discard decodeChangeSet(ChangeSetWireVersion & "K5")
    expect ChangeSetError: discard decodeChangeSet(ChangeSetWireVersion & "R2,9:ab")
    counted true

# ===========================================================================
# THE TRANSACTION
# ===========================================================================

suite "PLAT-25 — transactions, and the first of the five call sites":

  test "the annotation and effect sets are closed, and their cardinality is asserted":
    # §6.3: closed sets, *"because a closed set is enumerable by a test"*.
    # Enumerated here, in both directions: every member is reached by the
    # sweep and the sweep's size is the enum's own cardinality.
    counted AnnotationKindCount == 6
    counted EffectKindCount == 6
    var annotationsSeen = 0
    for k in AnnotationKind: inc annotationsSeen
    counted annotationsSeen == AnnotationKindCount
    var effectsSeen = 0
    var positioned = 0
    for k in EffectKind:
      inc effectsSeen
      let e = case k
              of efScrollIntoView: Effect(kind: efScrollIntoView)
              of efRevealRange: Effect(kind: efRevealRange, rangeFrom: 2, rangeTo: 6)
              of efFocusEditor: Effect(kind: efFocusEditor)
              of efSetLanguage: Effect(kind: efSetLanguage, language: "nim")
              of efAnnounce: Effect(kind: efAnnounce, message: "hi")
              of efMoveCaretTo: Effect(kind: efMoveCaretTo, caret: 4)
      if e.carriesPositions: inc positioned
      # TOTALITY: every arm maps without an exception and keeps its kind.
      let moved = mapEffect(e, changeSet(10, 0, 0, "ABC"))
      counted moved.kind == k
      # TWO-SIDED: an arm that carries no position is unchanged by a mapping,
      # and one that does is moved by it. A check on one direction is
      # satisfied by an implementation that ignores the change set entirely.
      if e.carriesPositions: counted moved != e
      else: counted moved == e
    counted effectsSeen == EffectKindCount
    counted positioned == 2

  test "a revealed range shrinks away from an insert at either edge":
    # `LAW-S4`'s rule, one milestone early, on the only positioned values that
    # exist yet: the start is forward-biased and the end backward-biased.
    let e = Effect(kind: efRevealRange, rangeFrom: 4, rangeTo: 6)
    let atStart = mapEffect(e, changeSet(10, 4, 4, "XX"))
    counted atStart.rangeFrom == 6
    counted atStart.rangeTo == 8
    let atEnd = mapEffect(e, changeSet(10, 6, 6, "XX"))
    counted atEnd.rangeFrom == 4
    counted atEnd.rangeTo == 6

  test "mergeTransactions(sequential) composes, and the second selection wins":
    let a = transaction(changeSet(10, 2, 2, "ab"),
                        some(caretSelection(3)))
    let b = transaction(changeSet(12, 6, 6, "cd"),
                        some(caretSelection(9)))
    let m = mergeTransactions(a, b, sequential = true)
    counted m.changes.apply("0123456789") == "01ab23cd456789"
    counted m.selection.get.mainRange.head == 9

  test "mergeTransactions(concurrent) goes through the ONE primitive":
    # Both change sets are expressed against the SAME document, so they have
    # to be rebased over each other. This is the port of
    # `codemirror-state/src/transaction.ts:310-328`, and the assertion is that
    # it AGREES with the primitive called directly — if it had hand-written
    # its own double mapping, this is where the two would part.
    let doc = "0123456789"
    let a = transaction(changeSet(10, 2, 2, "ab"),
                        some(caretSelection(2)))
    let b = transaction(changeSet(10, 6, 8, "Z"),
                        some(caretSelection(7)))
    let m = mergeTransactions(a, b, sequential = false)
    let r = rebase(a.changes, b.changes)
    counted m.changes == compose(a.changes, r.bOverA)
    counted m.changes.apply(doc) == compose(b.changes, r.aOverB).apply(doc)
    counted m.changes.apply(doc) == "01ab2345Z89"
    # `b`'s selection is mapped through `aOverB`, `a`'s through `bOverA`.
    counted m.selection.get.mainRange.head == 9

  test "a concurrent merge carries both annotations and both effect lists":
    let a = transaction(changeSet(10, 2, 2, "ab"), effects = @[
      Effect(kind: efMoveCaretTo, caret: 11)],
      annotations = @[Annotation(kind: anUserEvent, userEvent: ueInput)])
    let b = transaction(changeSet(10, 8, 8, "Z"), effects = @[
      Effect(kind: efScrollIntoView)],
      annotations = @[Annotation(kind: anRemote, peer: "peer-2")])
    let m = mergeTransactions(a, b, sequential = false)
    counted m.effects.len == 2
    counted m.annotations.len == 2
    counted m.annotations[0] == Annotation(kind: anUserEvent, userEvent: ueInput)
    counted m.annotations[1] == Annotation(kind: anRemote, peer: "peer-2")
    # `a`'s effects are in `a`'s OUTPUT coordinates and are mapped through
    # `bOverA`, which is `b`'s insertion moved over `a` — from byte 8 of the
    # original document to byte 10 of `a`'s. A caret at 11 is past it and
    # moves by the one byte `b` inserted; a caret at 8 would not move at all,
    # which is the answer this case originally asserted and got wrong.
    counted m.effects[0] == Effect(kind: efMoveCaretTo, caret: 12)
    counted m.effects[1] == Effect(kind: efScrollIntoView)

  test "a sequential merge whose halves do not meet is refused":
    let a = transaction(changeSet(10, 2, 2, "ab"))
    let b = transaction(changeSet(10, 2, 2, "cd"))
    expect ChangeSetError: discard mergeTransactions(a, b, sequential = true)
    counted true

# ---------------------------------------------------------------------------
# The tally, asserted against the declared constant
# ---------------------------------------------------------------------------

suite "PLAT-25 examples — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
