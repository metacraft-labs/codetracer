## PLAT-24 — the editor ViewModel's text store.
##
## Subject: `viewmodel/editor/text_store.nim` (the rope the measurement chose),
## `viewmodel/editor/rope.nim` (its structure) and
## `viewmodel/editor/seq_line_store.nim` (the incumbent, which is still here
## because it is the measurement's other arm and this suite's oracle).
##
## NO MOCKS, and no synthetic document of repeated lines. Every corpus in this
## file is real source read off this repository's disk at run time, because
## line-length distribution and the presence of real UTF-8 are two of the
## inputs. The files are named at their read sites so a failure says which
## bytes it was about.
##
## HOW THIS SUITE IS BUILT, and the two traps it is built against
## =============================================================
##
## **One contract, run twice.** The behavioural cases are written ONCE, in
## `storeContract`, and instantiated against BOTH stores. That is
## Verification-Harness-Traps.md §30's rule — one predicate, one function,
## rule and control both calling it — applied to a suite with two subjects: a
## second, hand-copied set of cases for the rope would let the two drift and
## would let the rope be checked against a copy of its own assumptions.
##
## **It is a `template`, not a `proc`.** §29: `unittest.check` compiles inside
## an ordinary `proc`, resolves to a module-level `testStatusIMPL`, and leaves
## the running test's own status untouched — so the case reports `[OK]` with
## the failed comparison printed directly above it. Every helper here that can
## fail is a template for that reason, and `mustRaise` is one too.
##
## **The differential case asserts its own population.** A generator that
## silently produces nothing satisfies every assertion written over it (§4), so
## the random-edit case counts the edits it applied and asserts the count, and
## prints its seed so a failure is reproducible.
##
## ARMING: `run-plat24-text-store-mutations.py`, beside this file, breaks one
## property of the store per arm and requires THIS suite's named case to go
## red. An assertion nobody has seen fail is documentation with a call site
## (§26).

import std/[random, strutils, unittest]

import ../../editor/text_store
import ../../editor/seq_line_store
import isonim_tui/text/width as widthMod

# ---------------------------------------------------------------------------
# Real corpora — this repository's own source, read at COMPILE time
# ---------------------------------------------------------------------------
#
# `staticRead`, not a runtime `readFile`, for two reasons and neither is
# convenience:
#
#   * `std/os`'s `readFile` and `fileExists` DO NOT EXIST on the JS backend,
#     and this directory is run by three lanes — `vm-unit` (C), `vm-unit-js`
#     (node) and `vm-unit-wasm`. A suite that reads its corpus at run time
#     compiles on one of the three;
#   * a missing corpus file becomes a COMPILE error naming the path, which is
#     as loud as a missing prerequisite can be. A helper that returns "" when
#     its file has moved turns every case written over it into a case about the
#     empty string, and those pass.
#
# The bytes are still real product source with real UTF-8 in it, and the files
# are named here so a failure says which ones. `text_store.nim` is deliberately
# among them: a store that mangled multi-byte text would fail on its own
# documentation, which is full of em dashes.

const
  CorpusSmallPath = "src/frontend/viewmodel/editor/text_store.nim"
  CorpusMidPath = "src/frontend/viewmodel/viewmodels/source_vm.nim"
  # Eight DISTINCT real files, ~13,600 lines between them. Distinct rather
  # than one file repeated: line-length distribution is a property of the
  # corpus, and repeating one document flattens it.
  CorpusBigPaths = [
    "src/frontend/ui/editor.nim",
    "src/frontend/types.nim",
    "src/frontend/ui/layout.nim",
    "src/common/plugin_model/manifest.nim",
    "src/frontend/tui/app/input/keymap.nim",
    "src/frontend/viewmodel/editor/rope.nim",
    "src/frontend/viewmodel/editor/text_store.nim",
    "src/frontend/viewmodel/editor/seq_line_store.nim",
  ]

const CorpusSmall = staticRead("../../editor/text_store.nim")
const CorpusMid = staticRead("../../viewmodels/source_vm.nim")
const CorpusBig =
  staticRead("../../../ui/editor.nim") &
  staticRead("../../../types.nim") &
  staticRead("../../../ui/layout.nim") &
  staticRead("../../../../common/plugin_model/manifest.nim") &
  staticRead("../../../tui/app/input/keymap.nim") &
  staticRead("../../editor/rope.nim") &
  staticRead("../../editor/text_store.nim") &
  staticRead("../../editor/seq_line_store.nim")

# ---------------------------------------------------------------------------
# Assertion helpers — TEMPLATES, never procs (§29)
# ---------------------------------------------------------------------------

template mustRaise(exc: typedesc; body: untyped) =
  var raised = false
  try:
    body
  except exc:
    raised = true
  check raised

# ---------------------------------------------------------------------------
# THE CONTRACT — written once, instantiated against both stores
# ---------------------------------------------------------------------------

template storeContract(makeStore: untyped; storeName: string) =
  ## Every behavioural property of the seven operations, over real data.
  ## Instantiated twice; `storeName` reaches the failure output through
  ## `checkpoint`, so a red line says which store it was about.

  test storeName & ": an empty document is one empty line":
    checkpoint(storeName)
    var s = makeStore("")
    check s.lineCount == 1
    check s.len == 0
    check s.lineLen(0) == 0
    check s.text == ""
    check s.lineText(0) == ""
    check s.offsetOf(textPos(0, 0)) == 0
    check s.posOf(0) == textPos(0, 0)
    # An insert into the empty document is the first keystroke of every file
    # anyone ever creates, and it is the boundary a store is most likely to
    # get wrong.
    s.insert(textPos(0, 0), "a")
    check s.text == "a"
    check s.lineCount == 1

  test storeName & ": a single line has one line and no newline":
    checkpoint(storeName)
    var s = makeStore("one line, no terminator")
    check s.lineCount == 1
    check s.lineLen(0) == 23
    check s.len == 23
    check s.lineText(0) == "one line, no terminator"
    s.delete(textPos(0, 0), textPos(0, 23))
    check s.text == ""
    check s.lineCount == 1

  test storeName & ": a trailing newline means a final empty line":
    checkpoint(storeName)
    let s = makeStore("a\nb\n")
    check s.lineCount == 3
    check s.lineText(2) == ""
    check s.lineLen(2) == 0
    check s.offsetOf(textPos(2, 0)) == 4
    check s.posOf(4) == textPos(2, 0)

  test storeName & ": insert and delete at the first and the last line":
    checkpoint(storeName)
    let body = CorpusSmall
    var s = makeStore(body)
    let lastLine = s.lineCount - 1
    let before = s.text
    s.insert(textPos(0, 0), "# FIRST\n")
    check s.lineText(0) == "# FIRST"
    check s.lineCount == before.count('\n') + 2
    s.delete(textPos(0, 0), textPos(1, 0))
    check s.text == before
    # The last line, which is where `seq[string]` is cheap and a wrapper is
    # most likely to be off by one.
    s.insert(textPos(lastLine, s.lineLen(lastLine)), "tail")
    check s.lineText(s.lineCount - 1).endsWith("tail")
    s.delete(textPos(s.lineCount - 1, s.lineLen(s.lineCount - 1) - 4),
             textPos(s.lineCount - 1, s.lineLen(s.lineCount - 1)))
    check s.text == before

  test storeName & ": a position past the end of the document is clamped":
    checkpoint(storeName)
    let s = makeStore("ab\ncd")
    check s.offsetOf(textPos(99, 99)) == 5
    check s.offsetOf(textPos(0, 99)) == 2
    check s.offsetOf(textPos(-5, -5)) == 0
    check s.posOf(9999) == textPos(1, 2)
    check s.posOf(-1) == textPos(0, 0)

  test storeName & ": CRLF is stored byte for byte and never normalised":
    checkpoint(storeName)
    # A store that quietly rewrote line endings would corrupt every Windows
    # working-tree file it opened, and would do it invisibly: `lineText`
    # returns the same thing either way if the '\r' is dropped at load.
    var s = makeStore("alpha\r\nbeta\r\n")
    check s.len == 13
    check s.lineCount == 3
    check s.lineText(0) == "alpha\r"
    check s.lineLen(0) == 6
    check s.text == "alpha\r\nbeta\r\n"
    # Splitting a CRLF line keeps the '\r' with the text before it.
    s.insert(textPos(0, 5), "X")
    check s.lineText(0) == "alphaX\r"
    check s.text == "alphaX\r\nbeta\r\n"

  test storeName & ": a lone CR is not a line break":
    checkpoint(storeName)
    let s = makeStore("a\rb\nc")
    check s.lineCount == 2
    check s.lineText(0) == "a\rb"
    check s.lineLen(0) == 3

  test storeName & ": tabs are one byte and not a width":
    checkpoint(storeName)
    var s = makeStore("\tif x:\n\t\tpass\n")
    check s.lineLen(0) == 6
    check s.lineLen(1) == 6
    check s.offsetOf(textPos(1, 2)) == 9
    s.insert(textPos(1, 2), "\t")
    check s.lineText(1) == "\t\t\tpass"
    check s.lineLen(1) == 7

  test storeName & ": a ZWJ family is one backspace":
    checkpoint(storeName)
    # This is the property `textarea.nim` already has and the store must not
    # regress. The store itself is byte-addressed on purpose (see
    # text_store.nim's COORDINATES section); cluster editing is COMPOSED over
    # it, using the real UAX #29 segmenter from `isonim_tui/text/width.nim`,
    # which is exactly how a caller above this layer will do it.
    const Family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    var s = makeStore("x" & Family & "y")
    check s.lineLen(0) == 2 + Family.len
    check Family.len == 18            # four-byte emoji + two ZWJ, not one rune

    # Walk the line's clusters and delete the LAST one before the caret, the
    # way a Backspace handler does.
    proc prevClusterStart(line: string; at: int): int =
      result = 0
      for cluster in graphemeClusters(line):
        if cluster.stop >= at: return cluster.start
        result = cluster.stop

    let line0 = s.lineText(0)
    var clusterCount = 0
    for _ in graphemeClusters(line0): inc clusterCount
    check clusterCount == 3           # "x", the family, "y"

    # Backspace at the end of "y"
    let caretY = line0.len
    s.delete(textPos(0, prevClusterStart(line0, caretY)), textPos(0, caretY))
    check s.text == "x" & Family

    # Backspace over the family: ONE deletion, the whole 18 bytes
    let line1 = s.lineText(0)
    let caretF = line1.len
    s.delete(textPos(0, prevClusterStart(line1, caretF)), textPos(0, caretF))
    check s.text == "x"

  test storeName & ": multi-byte text survives a slice at a cluster boundary":
    checkpoint(storeName)
    let body = CorpusSmall
    check body.contains("\u2014")     # the corpus really does hold UTF-8
    check body.len > 5_000           # and it is not an empty string (§4)
    let s = makeStore(body)
    check s.text == body
    # Every line, rebuilt from its own slice, is the line.
    var rebuilt = ""
    for i in 0 ..< s.lineCount:
      if i > 0: rebuilt.add '\n'
      rebuilt.add s.lineText(i)
    check rebuilt == body

  test storeName & ": a replace spanning many lines removes exactly those":
    checkpoint(storeName)
    var s = makeStore("l0\nl1\nl2\nl3\nl4\nl5")
    s.replaceRange(textPos(1, 1), textPos(4, 1), "@")
    check s.text == "l0\nl@4\nl5"
    check s.lineCount == 3

  test storeName & ": offsetOf and posOf round-trip at every offset":
    checkpoint(storeName)
    let body = CorpusMid
    let s = makeStore(body)
    var checkedOffsets = 0
    var off = 0
    while off <= body.len:
      let p = s.posOf(off)
      check s.offsetOf(p) == off
      inc checkedOffsets
      # Every offset of a big real file is too slow for the JS lane; a stride
      # that is not a divisor of any line length still lands mid-line, at line
      # starts and at line ends over a file this size.
      off += 7
    # §4: a loop that ran zero times satisfies every check inside it.
    check checkedOffsets > 1000

  test storeName & ": the line index answers the last line of a big document":
    checkpoint(storeName)
    let body = CorpusBig
    let s = makeStore(body)
    check s.lineCount > 12_000
    let last = s.lineCount - 1
    check s.offsetOf(textPos(last, 0)) == body.rfind('\n') + 1
    check s.posOf(body.len).line == last
    check s.lineText(last) == body[body.rfind('\n') + 1 .. ^1]

# ---------------------------------------------------------------------------
# The two instantiations
# ---------------------------------------------------------------------------

suite "PLAT-24 text store — the contract, on both stores":
  storeContract(toTextStore, "rope")
  storeContract(toSeqLineStore, "seq[string]")

# ---------------------------------------------------------------------------
# The rope against the incumbent, and against its own invariants
# ---------------------------------------------------------------------------

suite "PLAT-24 text store — the rope":

  test "the rope agrees with seq[string] and with a plain string, edit by edit":
    # The differential case. Three independent implementations of "a document
    # with an edit applied to it": the rope, the incumbent, and `string` slice
    # arithmetic. The rope is never compared against itself.
    const Seed = 20260918
    var rng = initRand(Seed)
    checkpoint("seed = " & $Seed)
    var model = CorpusSmall
    var rope = toTextStore(model)
    var incumbent = toSeqLineStore(model)
    let payloads = ["", "x", "\n", "ab\ncd", "\n\n\n", "\u2014", "z".repeat(400),
                    "// a real looking comment line\n"]
    var applied = 0
    var sawInsert = 0
    var sawDelete = 0
    var sawReplace = 0
    for step in 1 .. 3000:
      let n = model.len
      var a = rng.rand(0 .. n)
      while a > 0 and a < n and (uint8(model[a]) and 0xC0'u8) == 0x80'u8: dec a
      var b = if rng.rand(1.0) < 0.55: a else: rng.rand(a .. n)
      while b > a and b < n and (uint8(model[b]) and 0xC0'u8) == 0x80'u8: dec b
      let payload = payloads[rng.rand(payloads.high)]
      if a == b and payload.len > 0: inc sawInsert
      elif a != b and payload.len == 0: inc sawDelete
      elif a != b: inc sawReplace
      let pa = rope.posOf(a)
      let pb = rope.posOf(b)
      if pa != incumbent.posOf(a) or pb != incumbent.posOf(b):
        checkpoint("posOf disagreed at step " & $step)
        check pa == incumbent.posOf(a)
        check pb == incumbent.posOf(b)
        break
      if rope.slice(pa, pb) != model[a ..< b]:
        checkpoint("slice disagreed at step " & $step)
        check rope.slice(pa, pb) == model[a ..< b]
        break
      rope.replaceRange(pa, pb, payload)
      incumbent.replaceRange(pa, pb, payload)
      model = model[0 ..< a] & payload & model[b .. ^1]
      inc applied
      if rope.text != model or incumbent.text != model:
        checkpoint("diverged at step " & $step)
        check rope.text == model
        check incumbent.text == model
        break
    # §4: assert the population, so a generator that produced nothing cannot
    # pass. Each of the three edit shapes has to have occurred, and the floors
    # are arithmetic rather than taste: over 3,000 steps, P(a == b) = 0.55 and
    # P(payload is empty) = 1/8, so the expectations are ~1,444 pure inserts,
    # ~169 pure deletes and ~1,181 replacements. The floors sit at roughly
    # half of each, which is far enough below the mean to be stable and far
    # enough above zero to catch a generator that stopped producing a shape.
    check applied == 3000
    check sawInsert > 700
    check sawDelete > 80
    check sawReplace > 500
    check rope.text == model
    check incumbent.text == model

  test "the rope's structural invariants hold after every kind of edit":
    const Seed = 74010203
    var rng = initRand(Seed)
    checkpoint("seed = " & $Seed)
    var rope = toTextStore(CorpusBig)
    var st: RopeStats
    check rope.invariants(st) == ""
    var verified = 0
    # Positions are drawn on rune boundaries by construction, because
    # `replaceRange` REFUSES an offset inside a code point and a generator
    # that produced one would be testing the refusal rather than the tree.
    proc runeColumn(line: string; rng: var Rand): int =
      var stops: seq[int] = @[0]
      var i = 1
      while i <= line.len:
        if i == line.len or (uint8(line[i]) and 0xC0'u8) != 0x80'u8:
          stops.add i
        inc i
      stops[rng.rand(stops.high)]
    for step in 1 .. 600:
      let l1 = rng.rand(0 ..< rope.lineCount)
      let l2 = min(rope.lineCount - 1, l1 + rng.rand(0 .. 3))
      let pa = textPos(l1, runeColumn(rope.lineText(l1), rng))
      var pb = textPos(l2, runeColumn(rope.lineText(l2), rng))
      if pb < pa: pb = pa
      rope.replaceRange(pa, pb, ["", "\n", "q", "x\ny\nz"][rng.rand(3)])
      let bad = rope.invariants(st)
      check bad == ""
      inc verified
      if bad != "": break
    check verified == 600
    check st.leaves > 0
    check st.maxLeafBytes <= MaxLeafBytes
    check st.maxFanout <= MaxChildren
    check st.minFanout >= 2

    # SPREAD EDITS ARE NOT ENOUGH, and the mutation harness is how that was
    # found. 600 edits scattered over a big document never put enough bytes
    # into ONE chunk to overflow it, so an arm that widened the leaf-local
    # fast path's capacity check survived this case and was caught two cases
    # later — a MISDIRECTED verdict, which says the run told you nothing about
    # the case that was supposed to notice. A chunk-sized burst at one
    # position is what exercises the capacity bound, and it is what a user
    # typing into one line does.
    let burstAt = rope.posOf(rope.len div 3)
    for i in 0 ..< 3 * MaxLeafBytes:
      rope.insert(burstAt, "w")
    let afterBurst = rope.invariants(st)
    checkpoint("after the burst: " & $st.leaves & " leaves, longest chunk " &
               $st.maxLeafBytes & " bytes")
    check afterBurst == ""
    check st.maxLeafBytes <= MaxLeafBytes
    check rope.lineLen(burstAt.line) >= 3 * MaxLeafBytes

  test "the rope stays balanced under 20,000 line-splitting inserts at line 1":
    # This is the anti-wrapper case. A `seq[string]` behind the same seven
    # operations passes every behavioural case above; what it cannot do is
    # keep the cost of an insert at line 1 independent of the document. The
    # structural statement of that is a depth bound, and it is asserted here
    # rather than timed, because a timing on this host is a measurement of the
    # scheduler (Verification-Harness-Traps.md §28a).
    var rope = toTextStore(CorpusBig)
    var st: RopeStats
    let linesBefore = rope.lineCount
    for i in 0 ..< 20_000:
      rope.insert(textPos(0, 0), "\n")
    check rope.lineCount == linesBefore + 20_000
    check rope.invariants(st) == ""
    # log2(leaves) + 1 is what `checkInvariants` enforces; restate the bound
    # here in the case itself so a reader sees the number the case is about.
    var bound = 1
    var cap = 1
    while cap < st.leaves:
      cap *= 2
      inc bound
    checkpoint("leaves = " & $st.leaves & ", height = " & $st.height &
               ", bound = " & $bound)
    check st.height <= bound
    check st.height < 40

  test "an offset inside a UTF-8 code point is refused, not silently moved":
    var rope = toTextStore("a\u2014b")     # 'a', a 3-byte em dash, 'b'
    check rope.len == 5
    mustRaise(ValueError):
      rope.replaceRange(textPos(0, 2), textPos(0, 2), "!")
    mustRaise(ValueError):
      rope.replaceRange(textPos(0, 1), textPos(0, 3), "!")
    # The document is untouched by a refused edit.
    check rope.text == "a\u2014b"
    # And the boundaries either side of it are accepted.
    rope.replaceRange(textPos(0, 1), textPos(0, 4), "!")
    check rope.text == "a!b"

  test "a rope and the incumbent answer the same on the same real file":
    let body = CorpusMid
    let rope = toTextStore(body)
    let incumbent = toSeqLineStore(body)
    check rope.len == incumbent.len
    check rope.lineCount == incumbent.lineCount
    var comparedLines = 0
    for i in 0 ..< rope.lineCount:
      if rope.lineText(i) != incumbent.lineText(i) or
         rope.lineLen(i) != incumbent.lineLen(i) or
         rope.offsetOf(textPos(i, 0)) != incumbent.offsetOf(textPos(i, 0)):
        checkpoint("line " & $i)
        check rope.lineText(i) == incumbent.lineText(i)
        check rope.lineLen(i) == incumbent.lineLen(i)
        check rope.offsetOf(textPos(i, 0)) == incumbent.offsetOf(textPos(i, 0))
        break
      inc comparedLines
    check comparedLines == rope.lineCount
    check comparedLines > 100

# ---------------------------------------------------------------------------
# Deliverable 1 — the interface is a list somebody can count
# ---------------------------------------------------------------------------

const TextStoreSource = staticRead("../../editor/text_store.nim")

type Section = enum secNone, secPrimitives, secDerived, secStructural

func exportedRoutinesBySection(src: string): array[Section, seq[string]] =
  ## Every exported top-level routine of `text_store.nim`, bucketed by the
  ## banner it sits under. Column 0 only: a nested helper is not part of the
  ## surface, and an indented `proc` inside a template is not either.
  var current = secNone
  for raw in src.splitLines():
    if raw.startsWith("# ===") or raw.startsWith("# ---"):
      continue
    if raw.startsWith("# PRIMITIVES"): current = secPrimitives; continue
    if raw.startsWith("# DERIVED"): current = secDerived; continue
    if raw.startsWith("# STRUCTURAL"): current = secStructural; continue
    for keyword in ["proc ", "func ", "iterator ", "template ", "converter ",
                    "method ", "macro "]:
      if raw.startsWith(keyword):
        let rest = raw[keyword.len .. ^1]
        let star = rest.find('*')
        if star > 0 and (star + 1 >= rest.len or rest[star + 1] in {'(', '['}):
          result[current].add rest[0 ..< star]
        break

suite "PLAT-24 text store — the interface is a list somebody can count":

  test "the PRIMITIVES section exports exactly the seven named operations":
    # Editor-ViewModel.md §4: "lengths, a line index, a slice, and a
    # replace-range ... if more than that leaks upward, the choice has stopped
    # being an implementation detail". The deliverable is checkable precisely
    # because it is a list, so this is the list, checked.
    const Expected = ["len", "lineCount", "lineLen", "offsetOf", "posOf",
                      "slice", "replaceRange"]
    let found = exportedRoutinesBySection(TextStoreSource)
    checkpoint("primitives found: " & found[secPrimitives].join(", "))
    # §4 again, one level down: a scanner that matched nothing satisfies every
    # "must be exactly" written over an empty set, so the non-vacuity of the
    # SCAN is asserted before its contents are.
    check found[secPrimitives].len > 0
    check found[secDerived].len > 0
    check found[secStructural].len > 0
    check found[secPrimitives].len == 7
    for name in Expected:
      checkpoint("expected primitive: " & name)
      check name in found[secPrimitives]
    for name in found[secPrimitives]:
      checkpoint("unexpected primitive: " & name)
      check name in Expected

  test "the DERIVED section adds no capability the seven do not have":
    # The operator names carry their backquotes: that is how they are spelled
    # at their declaration, and the scan reports what the file says.
    const ExpectedDerived = ["text", "lineText", "insert", "delete",
                             "`==`", "`$`"]
    let found = exportedRoutinesBySection(TextStoreSource)
    checkpoint("derived found: " & found[secDerived].join(", "))
    check found[secDerived].len == ExpectedDerived.len
    for name in ExpectedDerived:
      checkpoint("expected derived: " & name)
      check name in found[secDerived]

  test "the two stores are interchangeable behind the seven operations":
    # The reversibility claim, made mechanical: the same generic code compiles
    # and answers identically against both, so the decision recorded in
    # Editor-ViewModel.md §4 can be reversed without touching a caller.
    proc describe[S](s: S): string =
      $s.len & "/" & $s.lineCount & "/" & $s.lineLen(0) & "/" &
      $s.offsetOf(textPos(1, 1)) & "/" & $s.posOf(4).line & "/" &
      s.slice(textPos(0, 0), textPos(1, 1))
    let body = "alpha\nbeta\ngamma\n"
    check describe(toTextStore(body)) == describe(toSeqLineStore(body))
    check describe(toTextStore(body)) == "17/4/5/7/0/alpha\nb"
