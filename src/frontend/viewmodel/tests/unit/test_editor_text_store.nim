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

import std/[random, strutils, unicode, unittest]

import ../../editor/text_store
import ../../editor/seq_line_store
import ../corpus/unicode_corpus
import isonim_tui/text/width as widthMod

# ---------------------------------------------------------------------------
# Counted assertions — `CHECKS:` for the lane, plus the static constant it
# falls back to when a suite dies before printing anything.
#
# Conformance Suite §10.1: the case floor and the assertion count are two
# numbers in two units doing two different jobs, and NEITHER is sufficient
# alone — a file of empty cases scores `OK (n tests)`, and one case holding a
# thousand assertions is one case that can fail. `counted` is `check` with a
# tally, so every assertion in this file is in the number.
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

func classOfDoc(id: string): int =
  ## The class number a corpus document's id carries. Spelled once so a sweep
  ## that filters by class and the manifest that records it cannot disagree.
  parseInt($id[1])

const ExpectedAssertions = 9469
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

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
  counted raised

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
    counted s.lineCount == 1
    counted s.len == 0
    counted s.lineLen(0) == 0
    counted s.text == ""
    counted s.lineText(0) == ""
    counted s.offsetOf(textPos(0, 0)) == 0
    counted s.posOf(0) == textPos(0, 0)
    # An insert into the empty document is the first keystroke of every file
    # anyone ever creates, and it is the boundary a store is most likely to
    # get wrong.
    s.insert(textPos(0, 0), "a")
    counted s.text == "a"
    counted s.lineCount == 1

  test storeName & ": a single line has one line and no newline":
    checkpoint(storeName)
    var s = makeStore("one line, no terminator")
    counted s.lineCount == 1
    counted s.lineLen(0) == 23
    counted s.len == 23
    counted s.lineText(0) == "one line, no terminator"
    s.delete(textPos(0, 0), textPos(0, 23))
    counted s.text == ""
    counted s.lineCount == 1

  test storeName & ": a trailing newline means a final empty line":
    checkpoint(storeName)
    let s = makeStore("a\nb\n")
    counted s.lineCount == 3
    counted s.lineText(2) == ""
    counted s.lineLen(2) == 0
    counted s.offsetOf(textPos(2, 0)) == 4
    counted s.posOf(4) == textPos(2, 0)

  test storeName & ": insert and delete at the first and the last line":
    checkpoint(storeName)
    let body = CorpusSmall
    var s = makeStore(body)
    let lastLine = s.lineCount - 1
    let before = s.text
    s.insert(textPos(0, 0), "# FIRST\n")
    counted s.lineText(0) == "# FIRST"
    counted s.lineCount == before.count('\n') + 2
    s.delete(textPos(0, 0), textPos(1, 0))
    counted s.text == before
    # The last line, which is where `seq[string]` is cheap and a wrapper is
    # most likely to be off by one.
    s.insert(textPos(lastLine, s.lineLen(lastLine)), "tail")
    counted s.lineText(s.lineCount - 1).endsWith("tail")
    s.delete(textPos(s.lineCount - 1, s.lineLen(s.lineCount - 1) - 4),
             textPos(s.lineCount - 1, s.lineLen(s.lineCount - 1)))
    counted s.text == before

  test storeName & ": a position past the end of the document is clamped":
    checkpoint(storeName)
    let s = makeStore("ab\ncd")
    counted s.offsetOf(textPos(99, 99)) == 5
    counted s.offsetOf(textPos(0, 99)) == 2
    counted s.offsetOf(textPos(-5, -5)) == 0
    counted s.posOf(9999) == textPos(1, 2)
    counted s.posOf(-1) == textPos(0, 0)

  test storeName & ": CRLF is stored byte for byte and never normalised":
    checkpoint(storeName)
    # A store that quietly rewrote line endings would corrupt every Windows
    # working-tree file it opened, and would do it invisibly: `lineText`
    # returns the same thing either way if the '\r' is dropped at load.
    var s = makeStore("alpha\r\nbeta\r\n")
    counted s.len == 13
    counted s.lineCount == 3
    counted s.lineText(0) == "alpha\r"
    counted s.lineLen(0) == 6
    counted s.text == "alpha\r\nbeta\r\n"
    # Splitting a CRLF line keeps the '\r' with the text before it.
    s.insert(textPos(0, 5), "X")
    counted s.lineText(0) == "alphaX\r"
    counted s.text == "alphaX\r\nbeta\r\n"

  test storeName & ": a lone CR is not a line break":
    checkpoint(storeName)
    let s = makeStore("a\rb\nc")
    counted s.lineCount == 2
    counted s.lineText(0) == "a\rb"
    counted s.lineLen(0) == 3

  test storeName & ": tabs are one byte and not a width":
    checkpoint(storeName)
    var s = makeStore("\tif x:\n\t\tpass\n")
    counted s.lineLen(0) == 6
    counted s.lineLen(1) == 6
    counted s.offsetOf(textPos(1, 2)) == 9
    s.insert(textPos(1, 2), "\t")
    counted s.lineText(1) == "\t\t\tpass"
    counted s.lineLen(1) == 7

  test storeName & ": a ZWJ family is one backspace":
    checkpoint(storeName)
    # This is the property `textarea.nim` already has and the store must not
    # regress. The store itself is byte-addressed on purpose (see
    # text_store.nim's COORDINATES section); cluster editing is COMPOSED over
    # it, using the real UAX #29 segmenter from `isonim_tui/text/width.nim`,
    # which is exactly how a caller above this layer will do it.
    const Family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    var s = makeStore("x" & Family & "y")
    counted s.lineLen(0) == 2 + Family.len
    counted Family.len == 18            # four-byte emoji + two ZWJ, not one rune

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
    counted clusterCount == 3           # "x", the family, "y"

    # Backspace at the end of "y"
    let caretY = line0.len
    s.delete(textPos(0, prevClusterStart(line0, caretY)), textPos(0, caretY))
    counted s.text == "x" & Family

    # Backspace over the family: ONE deletion, the whole 18 bytes
    let line1 = s.lineText(0)
    let caretF = line1.len
    s.delete(textPos(0, prevClusterStart(line1, caretF)), textPos(0, caretF))
    counted s.text == "x"

  test storeName & ": multi-byte text survives a slice at a cluster boundary":
    checkpoint(storeName)
    let body = CorpusSmall
    counted body.contains("\u2014")     # the corpus really does hold UTF-8
    counted body.len > 5_000           # and it is not an empty string (§4)
    let s = makeStore(body)
    counted s.text == body
    # Every line, rebuilt from its own slice, is the line.
    var rebuilt = ""
    for i in 0 ..< s.lineCount:
      if i > 0: rebuilt.add '\n'
      rebuilt.add s.lineText(i)
    counted rebuilt == body

  test storeName & ": a replace spanning many lines removes exactly those":
    checkpoint(storeName)
    var s = makeStore("l0\nl1\nl2\nl3\nl4\nl5")
    s.replaceRange(textPos(1, 1), textPos(4, 1), "@")
    counted s.text == "l0\nl@4\nl5"
    counted s.lineCount == 3

  test storeName & ": offsetOf and posOf round-trip at every offset":
    checkpoint(storeName)
    let body = CorpusMid
    let s = makeStore(body)
    var checkedOffsets = 0
    var off = 0
    while off <= body.len:
      let p = s.posOf(off)
      counted s.offsetOf(p) == off
      inc checkedOffsets
      # Every offset of a big real file is too slow for the JS lane; a stride
      # that is not a divisor of any line length still lands mid-line, at line
      # starts and at line ends over a file this size.
      off += 7
    # §4: a loop that ran zero times satisfies every check inside it.
    counted checkedOffsets > 1000

  test storeName & ": the line index answers the last line of a big document":
    checkpoint(storeName)
    let body = CorpusBig
    let s = makeStore(body)
    counted s.lineCount > 12_000
    let last = s.lineCount - 1
    counted s.offsetOf(textPos(last, 0)) == body.rfind('\n') + 1
    counted s.posOf(body.len).line == last
    counted s.lineText(last) == body[body.rfind('\n') + 1 .. ^1]

  # -------------------------------------------------------------------------
  # `DIFF-3` OVER REAL CLUSTERS — the Unicode corpus, through the interface.
  #
  # Editor-Model-Conformance-Suite.md §5.3: the corpus is delivered in PLAT-24
  # rather than PLAT-27 partly so that *"the storage conformance suite (§8,
  # `DIFF-3`) runs over real clusters from the day the interface exists"*. The
  # cases below are in the CONTRACT, so every one of them runs against both
  # backends: a rope that mangled a ZWJ family and a `seq[string]` that did not
  # would be a difference the differential is there to see.
  #
  # The multiplier is 18 because 18 is the corpus's asserted cardinality
  # (§10.4 rule 3), and every case asserts it got 18 — a sweep over a corpus
  # that silently shrank satisfies everything written over it (§4).
  # -------------------------------------------------------------------------

  test storeName & ": every corpus document survives storage byte for byte":
    checkpoint(storeName)
    var docs = 0
    for d in CorpusDocs:
      inc docs
      checkpoint(d.id)
      let s = makeStore(d.text)
      # A store that normalised a line ending, dropped an invalid byte or
      # rewrote a lone CR would corrupt a document it merely OPENED, and would
      # do it invisibly: every later question answers the same either way.
      counted s.text == d.text
      counted s.len == d.text.len
      var lfs = 0
      for ch in d.text:
        if ch == '\n': inc lfs
      counted s.lineCount == lfs + 1
    counted docs == 18

  test storeName & ": every corpus document's line index round-trips":
    checkpoint(storeName)
    var docs = 0
    var checkedOffsets = 0
    var roundTripFailures = 0
    for d in CorpusDocs:
      inc docs
      let s = makeStore(d.text)
      var off = 0
      # A stride that is not a divisor of any line length, over documents whose
      # line lengths come from a real file's distribution, lands mid-line, at
      # line starts and at line ends.
      while off <= d.text.len:
        if s.offsetOf(s.posOf(off)) != off:
          inc roundTripFailures
          checkpoint(d.id & " at offset " & $off)
        inc checkedOffsets
        off += 13
    counted docs == 18
    counted roundTripFailures == 0
    checkpoint($checkedOffsets & " offsets over the corpus")
    counted checkedOffsets > 20_000

  test storeName & ": every corpus line is reachable through lineText":
    checkpoint(storeName)
    var docs = 0
    var linesSeen = 0
    var mismatches = 0
    for d in CorpusDocs:
      inc docs
      let s = makeStore(d.text)
      var rebuilt = ""
      for i in 0 ..< s.lineCount:
        if i > 0: rebuilt.add '\n'
        let text = s.lineText(i)
        if text.len != s.lineLen(i): inc mismatches
        rebuilt.add text
        inc linesSeen
      if rebuilt != d.text:
        inc mismatches
        checkpoint(d.id & " did not rebuild from its own lines")
    counted docs == 18
    counted mismatches == 0
    checkpoint($linesSeen & " lines rebuilt")
    counted linesSeen > 3_000

  test storeName & ": a backspace over a corpus cluster deletes exactly one":
    # The property `textarea.nim` already has and this layer must not lose: a
    # ZWJ family, a flag, a base-plus-marks cluster is ONE backspace. The store
    # is byte-addressed on purpose; the segmentation is composed ABOVE it with
    # the real UAX #29 segmenter, which is how a caller will do it.
    checkpoint(storeName)
    var docs = 0
    var deletions = 0
    var multiRuneDeletions = 0
    for d in CorpusDocs:
      if not d.id.endsWith("-short"): continue
      # CLASS 7 IS EXCLUDED HERE AND THE EXCLUSION IS A RECORDED FACT, not a
      # convenience: the last cluster of an ill-formed line can START on a bare
      # continuation byte, and `TextStore.replaceRange` refuses an offset whose
      # byte is `10xxxxxx`. The two stores DISAGREE about that edit — the rope
      # raises, the incumbent splits the byte — which is a `DIFF-3` finding the
      # corpus produced on its first run, and it has a case of its own below
      # ("the two stores disagree about an edit inside ill-formed bytes"). A
      # sweep that silently skipped it would have hidden the difference the
      # differential axis exists to find.
      if classOfDoc(d.id) == 7: continue
      inc docs
      checkpoint(d.id)
      var s = makeStore(d.text)
      for lineNo in 0 ..< s.lineCount:
        let line = s.lineText(lineNo)
        if line.len == 0: continue
        var lastStart = 0
        var lastStop = 0
        for c in graphemeClusters(line):
          lastStart = c.start
          lastStop = c.stop
        if lastStop <= lastStart: continue
        var runeCount = 0
        for _ in runes(line[lastStart ..< lastStop]): inc runeCount
        if runeCount > 1: inc multiRuneDeletions
        let before = s.len
        s.delete(textPos(lineNo, lastStart), textPos(lineNo, lastStop))
        inc deletions
        # ONE backspace removed the WHOLE cluster and nothing else.
        counted s.len == before - (lastStop - lastStart)
        counted s.lineText(lineNo) == line[0 ..< lastStart]
    counted docs == 8
    checkpoint($deletions & " backspaces, " & $multiRuneDeletions &
               " of them over a multi-rune cluster")
    counted deletions > 70
    # §4b: a sweep that only ever met the easy shape is worse than an empty
    # one. A one-rune cluster is the shape a byte-addressed store gets right by
    # accident, so the multi-rune population is asserted separately.
    counted multiRuneDeletions > 10

  test storeName & ": the ill-formed corpus documents slice without loss":
    checkpoint(storeName)
    var docs = 0
    var slices = 0
    var losses = 0
    for d in CorpusDocs:
      if classOfDoc(d.id) != 7: continue
      inc docs
      let s = makeStore(d.text)
      var a = 0
      while a < d.text.len:
        let b = min(a + 97, d.text.len)
        if s.slice(s.posOf(a), s.posOf(b)) != d.text[a ..< b]:
          inc losses
          checkpoint(d.id & " lost bytes in [" & $a & ", " & $b & ")")
        inc slices
        a += 89
    counted docs == 2
    counted losses == 0
    counted slices > 100

  test storeName & ": the line-terminator corpus keeps lines and terminators in step":
    checkpoint(storeName)
    var docs = 0
    for d in CorpusDocs:
      if classOfDoc(d.id) != 6: continue
      inc docs
      checkpoint(d.id)
      let s = makeStore(d.text)
      var lfs = 0
      var crs = 0
      for ch in d.text:
        if ch == '\n': inc lfs
        elif ch == '\r': inc crs
      counted s.lineCount == lfs + 1
      # A lone CR is NOT a terminator, so the CRs are inside lines and the two
      # counts must not agree — the two-sided half of the same claim.
      counted crs > 0
      counted s.lineCount != lfs + crs + 1
      # No final newline: the last line has content, which is the case that
      # decides whether a document's last line exists at all.
      counted not d.text.endsWith("\n")
      counted s.lineLen(s.lineCount - 1) > 0
    counted docs == 2

  test storeName & ": the corpus's tabs are one byte and never a width":
    checkpoint(storeName)
    var docs = 0
    var tabs = 0
    for d in CorpusDocs:
      if classOfDoc(d.id) != 8: continue
      inc docs
      let s = makeStore(d.text)
      for lineNo in 0 ..< s.lineCount:
        let line = s.lineText(lineNo)
        for i in 0 ..< line.len:
          if line[i] == '\t':
            inc tabs
            # The store charges a tab ONE byte, whatever a renderer later
            # decides it is worth in cells.
            counted s.offsetOf(textPos(lineNo, i + 1)) -
                    s.offsetOf(textPos(lineNo, i)) == 1
    counted docs == 2
    counted tabs > 600

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
        counted pa == incumbent.posOf(a)
        counted pb == incumbent.posOf(b)
        break
      if rope.slice(pa, pb) != model[a ..< b]:
        checkpoint("slice disagreed at step " & $step)
        counted rope.slice(pa, pb) == model[a ..< b]
        break
      rope.replaceRange(pa, pb, payload)
      incumbent.replaceRange(pa, pb, payload)
      model = model[0 ..< a] & payload & model[b .. ^1]
      inc applied
      if rope.text != model or incumbent.text != model:
        checkpoint("diverged at step " & $step)
        counted rope.text == model
        counted incumbent.text == model
        break
    # §4: assert the population, so a generator that produced nothing cannot
    # pass. Each of the three edit shapes has to have occurred, and the floors
    # are arithmetic rather than taste: over 3,000 steps, P(a == b) = 0.55 and
    # P(payload is empty) = 1/8, so the expectations are ~1,444 pure inserts,
    # ~169 pure deletes and ~1,181 replacements. The floors sit at roughly
    # half of each, which is far enough below the mean to be stable and far
    # enough above zero to catch a generator that stopped producing a shape.
    counted applied == 3000
    counted sawInsert > 700
    counted sawDelete > 80
    counted sawReplace > 500
    counted rope.text == model
    counted incumbent.text == model

  test "the rope's structural invariants hold after every kind of edit":
    const Seed = 74010203
    var rng = initRand(Seed)
    checkpoint("seed = " & $Seed)
    var rope = toTextStore(CorpusBig)
    var st: RopeStats
    counted rope.invariants(st) == ""
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
      counted bad == ""
      inc verified
      if bad != "": break
    counted verified == 600
    counted st.leaves > 0
    counted st.maxLeafBytes <= MaxLeafBytes
    counted st.maxFanout <= MaxChildren
    counted st.minFanout >= 2

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
    counted afterBurst == ""
    counted st.maxLeafBytes <= MaxLeafBytes
    counted rope.lineLen(burstAt.line) >= 3 * MaxLeafBytes

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
    counted rope.lineCount == linesBefore + 20_000
    counted rope.invariants(st) == ""
    # log2(leaves) + 1 is what `checkInvariants` enforces; restate the bound
    # here in the case itself so a reader sees the number the case is about.
    var bound = 1
    var cap = 1
    while cap < st.leaves:
      cap *= 2
      inc bound
    checkpoint("leaves = " & $st.leaves & ", height = " & $st.height &
               ", bound = " & $bound)
    counted st.height <= bound
    counted st.height < 40

  test "an offset inside a UTF-8 code point is refused, not silently moved":
    var rope = toTextStore("a\u2014b")     # 'a', a 3-byte em dash, 'b'
    counted rope.len == 5
    mustRaise(ValueError):
      rope.replaceRange(textPos(0, 2), textPos(0, 2), "!")
    mustRaise(ValueError):
      rope.replaceRange(textPos(0, 1), textPos(0, 3), "!")
    # The document is untouched by a refused edit.
    counted rope.text == "a\u2014b"
    # And the boundaries either side of it are accepted.
    rope.replaceRange(textPos(0, 1), textPos(0, 4), "!")
    counted rope.text == "a!b"

  test "the two stores disagree about an edit inside ill-formed bytes":
    # A `DIFF-3` finding, produced by the corpus on the day it landed and
    # recorded rather than smoothed away. `TextStore.replaceRange` refuses an
    # offset whose byte is `10xxxxxx` on the grounds that in WELL-FORMED text
    # that byte is the interior of a code point. In class 7's documents it can
    # be a standalone byte, so the refusal costs a legitimate edit — and the
    # incumbent, which has no such check, performs it.
    #
    # Neither answer is wrong and the point is that they differ: one suite over
    # two backends is what makes a difference visible at all, and a conformance
    # suite that required them to agree here would have been written from one
    # implementation's behaviour (§2's "conformance" row).
    let ill = docById("c7-illformed-short")
    var refusedByRope = 0
    var acceptedBySeq = 0
    var bothAccepted = 0
    for off in 0 .. ill.len:
      var rope = toTextStore(ill)
      var incumbent = toSeqLineStore(ill)
      let p = rope.posOf(off)
      var ropeRefused = false
      try:
        rope.replaceRange(p, p, "")
      except ValueError:
        ropeRefused = true
      incumbent.replaceRange(incumbent.posOf(off), incumbent.posOf(off), "")
      if ropeRefused:
        inc refusedByRope
        inc acceptedBySeq        # the incumbent has no refusal at all
      else:
        inc bothAccepted
        # Where they DO agree, they agree exactly — the divergence is confined
        # to the refusal and is not a second, quieter difference.
        counted rope.text == incumbent.text
    checkpoint($refusedByRope & " offsets the rope refuses and the incumbent " &
               "does not, of " & $(ill.len + 1))
    counted refusedByRope > 0
    counted bothAccepted > 0          # two-sided: it is not refusing everything
    counted acceptedBySeq == refusedByRope
    counted refusedByRope + bothAccepted == ill.len + 1
    # And on WELL-FORMED text the two never diverge, which is what says the
    # divergence is about ill-formed bytes rather than about the check.
    let clean = docById("c1-zwj-short")
    var divergedOnClean = 0
    for off in 0 .. clean.len:
      var rope = toTextStore(clean)
      try:
        rope.replaceRange(rope.posOf(off), rope.posOf(off), "")
      except ValueError:
        # An offset inside a MULTI-BYTE CODE POINT is refused on clean text
        # too, and correctly: that is the check doing its job.
        if (uint8(clean[off]) and 0xC0'u8) != 0x80'u8: inc divergedOnClean
    counted divergedOnClean == 0

  test "a rope and the incumbent answer the same on the same real file":
    let body = CorpusMid
    let rope = toTextStore(body)
    let incumbent = toSeqLineStore(body)
    counted rope.len == incumbent.len
    counted rope.lineCount == incumbent.lineCount
    var comparedLines = 0
    for i in 0 ..< rope.lineCount:
      if rope.lineText(i) != incumbent.lineText(i) or
         rope.lineLen(i) != incumbent.lineLen(i) or
         rope.offsetOf(textPos(i, 0)) != incumbent.offsetOf(textPos(i, 0)):
        checkpoint("line " & $i)
        counted rope.lineText(i) == incumbent.lineText(i)
        counted rope.lineLen(i) == incumbent.lineLen(i)
        counted rope.offsetOf(textPos(i, 0)) == incumbent.offsetOf(textPos(i, 0))
        break
      inc comparedLines
    counted comparedLines == rope.lineCount
    counted comparedLines > 100

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
    counted found[secPrimitives].len > 0
    counted found[secDerived].len > 0
    counted found[secStructural].len > 0
    counted found[secPrimitives].len == 7
    for name in Expected:
      checkpoint("expected primitive: " & name)
      counted name in found[secPrimitives]
    for name in found[secPrimitives]:
      checkpoint("unexpected primitive: " & name)
      counted name in Expected

  test "the DERIVED section adds no capability the seven do not have":
    # The operator names carry their backquotes: that is how they are spelled
    # at their declaration, and the scan reports what the file says.
    const ExpectedDerived = ["text", "lineText", "insert", "delete",
                             "`==`", "`$`"]
    let found = exportedRoutinesBySection(TextStoreSource)
    checkpoint("derived found: " & found[secDerived].join(", "))
    counted found[secDerived].len == ExpectedDerived.len
    for name in ExpectedDerived:
      checkpoint("expected derived: " & name)
      counted name in found[secDerived]

  test "the two stores are interchangeable behind the seven operations":
    # The reversibility claim, made mechanical: the same generic code compiles
    # and answers identically against both, so the decision recorded in
    # Editor-ViewModel.md §4 can be reversed without touching a caller.
    proc describe[S](s: S): string =
      $s.len & "/" & $s.lineCount & "/" & $s.lineLen(0) & "/" &
      $s.offsetOf(textPos(1, 1)) & "/" & $s.posOf(4).line & "/" &
      s.slice(textPos(0, 0), textPos(1, 1))
    let body = "alpha\nbeta\ngamma\n"
    counted describe(toTextStore(body)) == describe(toSeqLineStore(body))
    counted describe(toTextStore(body)) == "17/4/5/7/0/alpha\nb"

# ---------------------------------------------------------------------------
# The tally, asserted against the declared constant
# ---------------------------------------------------------------------------

suite "PLAT-24 text store — the tally":
  test "assertion count":
    ## `CHECKS:` is what `ci/lib/run-nim-test-lane.sh` reads; the constant is
    ## what it falls back to when a suite dies before printing anything. This
    ## case is the one that makes either of them mean something: without it a
    ## case that returned early before asserting anything is invisible.
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
