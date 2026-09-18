## PLAT-24 deliverable 6 — the Unicode and grapheme corpus, asserted.
##
## Subject: `viewmodel/tests/corpus/unicode/` — nine classes, two documents
## each, eighteen documents, with `manifest.tsv` recording every document's
## class, provenance, byte length, line count, rune count, cluster count,
## fingerprint and display width at BOTH `AmbiguousWidth` settings, and
## `short-lines.tsv` recording the author's per-line hand audit of the nine
## short ones.
##
## Editor-Model-Conformance-Suite.md §5.2 says why this file exists: *"The
## manifest figures are asserted, so a corpus file silently rewritten by an
## editor that normalises line endings — which is how corpora die — reddens the
## suite instead of quietly changing what every law is quantified over."*
##
## THE ORACLE IS NEVER THE THING UNDER TEST
## ========================================
## §7's first rule. Three independent sources answer here and none of them is
## the segmenter:
##
##   * `manifest.tsv` — bytes on disk, parsed at run time, compared against a
##     fresh measurement. It catches a corpus that MOVED.
##   * `short-lines.tsv` — the author's own arithmetic over each short line's
##     composition, worked out from the characters rather than read back out of
##     `graphemeClusters`. It catches a segmenter that moved. Its first run
##     found two of its own rows wrong, both plain ASCII miscounts by the
##     author, and both are corrected in the generator with the correction
##     visible in its history rather than in a silent edit.
##   * `GraphemeBreakTest.txt` — **Unicode's own break data**. Three long
##     documents are packed out of its 1,093 sequences, so their expected
##     cluster count is arithmetic over upstream data. That is the `oracle`
##     column, and it is an equality rather than a pinned divergence count
##     because `width.nim` agrees with all 1,093 sequences (measured
##     2026-09-18, 0 divergences).
##
## TWO-SIDED, PER §7.1
## ===================
## The manifest's row set and the compiled-in document set are compared in BOTH
## directions and their common cardinality is asserted, because two
## set-differences are both satisfied by two empty sets.
##
## `LAW-C5` IS WHY CLASS 9 IS IN THE CORPUS
## ========================================
## "Width policy is two-sided": switching `AmbiguousWidth` must change the
## answer for the ambiguous class and must NOT change it for the ASCII control
## class. A model that ignored the parameter passes the second half, and a model
## that applied it to everything passes the first. Only both halves together say
## anything, and the second half is the one that gets dropped
## (Verification-Harness-Traps.md §7b).
##
## ARMING: `run-plat24-text-store-mutations.py`, which runs this suite as well
## as the store suite and requires the NAMED case here to go red for each arm
## that reaches the corpus.

import std/[strutils, unicode, unittest]

import ../corpus/unicode_corpus
import ../../editor/text_store

# ---------------------------------------------------------------------------
# Counted assertions — `CHECKS:` for the lane, and the constant it falls back
# to when a suite dies before printing anything (Conformance Suite §10.1).
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 928
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Parsed once. A parse that threw would take the whole file down by name, which
# is what a missing prerequisite should do (Silent-Self-Pass audit).
# ---------------------------------------------------------------------------

let manifest = manifestRows()
let audits = shortLineAudits()
let unrepresentable = unrepresentableRows()

func classOf(id: string): int =
  parseInt($id[1])

# ---------------------------------------------------------------------------
# The manifest, two-sided
# ---------------------------------------------------------------------------

suite "PLAT-24 corpus — the manifest is the corpus":

  test "the manifest and the documents name the same set, in both directions":
    # §7.1, applied. The last line is the one usually omitted, and without it
    # the two set-differences are both satisfied by two empty sets.
    var manifestIds: seq[string] = @[]
    for r in manifest: manifestIds.add r.id
    var docIds: seq[string] = @[]
    for d in CorpusDocs: docIds.add d.id
    counted manifestIds.len > 0
    counted docIds.len > 0
    counted manifestIds.len == docIds.len
    counted manifestIds.len == 18          # §5: nine classes, two each
    for id in manifestIds:
      checkpoint("manifest row with no document: " & id)
      counted id in docIds
    for id in docIds:
      checkpoint("document with no manifest row: " & id)
      counted id in manifestIds
    # A duplicate id would satisfy both differences with one fewer distinct
    # name than the count claims (§7.3).
    var duplicates = 0
    for i in 0 ..< docIds.len:
      for j in i + 1 ..< docIds.len:
        if docIds[i] == docIds[j]:
          inc duplicates
          checkpoint("duplicate id: " & docIds[i])
    counted duplicates == 0
    # NINE classes, TWO documents each — the shape §5.1 states, checked rather
    # than assumed from the count.
    for cls in 1 .. 9:
      var short = 0
      var long = 0
      for d in docsOfClass(cls):
        if d.id.endsWith("-short"): inc short
        elif d.id.endsWith("-long"): inc long
      checkpoint("class " & $cls)
      counted short == 1
      counted long == 1
    # Every class the manifest names is in 1..9 and every one of the nine is
    # named, so a tenth class or a missing one fails here rather than later.
    var seen: set[1'u8 .. 9'u8] = {}
    for r in manifest:
      counted r.cls in 1 .. 9
      seen.incl uint8(r.cls)
    counted seen == {1'u8 .. 9'u8}
    # A short document is at most 20 lines (§5.1); its final empty line is the
    # trailing newline, which is why the bound is on the authored lines.
    for r in manifest:
      if r.kind == "short":
        checkpoint(r.id & " has " & $r.lines & " lines")
        counted r.lines <= 21

template manifestCase(docId: string) =
  test docId & " — the manifest row matches the bytes":
    ## One case per document. They can fail independently — a rewritten class 6
    ## says nothing about class 5 — which is what makes eighteen cases eighteen
    ## rather than one (§10.4 rule 2).
    checkpoint(docId)
    var row: ManifestRow
    var found = false
    for r in manifest:
      if r.id == docId: (row = r; found = true)
    counted found
    let text = docById(docId)
    let f = measure(text)
    counted row.bytes == f.bytes
    counted row.lines == f.lines
    counted row.runes == f.runes
    counted row.clusters == f.clusters
    counted row.widthNarrow == f.widthNarrow
    counted row.widthWide == f.widthWide
    # The fingerprint is the one column that moves for ANY byte change,
    # including one the other six agree about — a swap of two identical-width
    # clusters, say.
    counted row.fingerprint == toHex16(fnv1a(text))
    counted row.cls == classOf(docId)
    # Non-vacuity: an empty document satisfies every equality above.
    counted f.bytes > 0
    counted f.clusters > 0
    # The provenance is a statement somebody can follow back.
    counted row.provenance.len > 20

suite "PLAT-24 corpus — the manifest, per document":
  manifestCase("c1-zwj-short")
  manifestCase("c2-combining-short")
  manifestCase("c3-regional-short")
  manifestCase("c4-ambiguous-short")
  manifestCase("c5-cjk-short")
  manifestCase("c6-terminators-short")
  manifestCase("c7-illformed-short")
  manifestCase("c8-tabs-short")
  manifestCase("c9-ascii-control-short")
  manifestCase("c1-zwj-long")
  manifestCase("c2-combining-long")
  manifestCase("c3-regional-long")
  manifestCase("c4-ambiguous-long")
  manifestCase("c5-cjk-long")
  manifestCase("c6-terminators-long")
  manifestCase("c7-illformed-long")
  manifestCase("c8-tabs-long")
  manifestCase("c9-ascii-control-long")

# ---------------------------------------------------------------------------
# The two independent oracles
# ---------------------------------------------------------------------------

suite "PLAT-24 corpus — the oracles that are not the segmenter":

  test "every short document's per-line hand audit holds":
    # §5.1: "each line's expected cluster count and display width recorded
    # beside it". The numbers come from the author's reading of the line's
    # composition. Where they disagree with the segmenter one of the two is
    # wrong and the case says which line.
    var checkedLines = 0
    var measuredRows = 0
    for a in audits:
      let text = docById(a.id)
      let ls = text.split('\n')
      checkpoint(a.id & " line " & $a.line)
      counted a.line < ls.len
      if a.clusters == "MEASURED":
        inc measuredRows
        continue
      let f = measure(ls[a.line])
      counted $f.clusters == a.clusters
      counted $f.widthNarrow == a.widthNarrow
      counted $f.widthWide == a.widthWide
      inc checkedLines
    # §4: a loop that ran zero times satisfies every check inside it, and a
    # PARTIAL sweep is worse than an empty one (§4b) — so the floor is on the
    # audited lines and the MEASURED rows are counted separately rather than
    # allowed to absorb the audit.
    checkpoint("audited " & $checkedLines & " lines, " & $measuredRows &
               " recorded as MEASURED")
    counted checkedLines > 70
    counted measuredRows > 0
    counted checkedLines + measuredRows == audits.len

  test "the MEASURED rows are named and confined to the ill-formed class":
    # An audit row that says MEASURED is an admission, and an admission that
    # could spread silently is worse than none. Every one of them is class 7,
    # where what Nim's `fastRuneAt` yields for a byte that is not text is an
    # implementation's answer rather than a fact about Unicode.
    var measured = 0
    for a in audits:
      if a.clusters != "MEASURED": continue
      inc measured
      checkpoint(a.id & " line " & $a.line)
      counted classOf(a.id) == 7
      counted a.widthNarrow == "MEASURED"
      counted a.widthWide == "MEASURED"
    counted measured > 0
    counted measured == 12

  test "Unicode's own break data agrees with the segmenter, document by document":
    # The `oracle` column of a `ucd-oracle` row is arithmetic over
    # GraphemeBreakTest.txt's `÷` marks, which no code in this tree produced.
    var withOracle = 0
    for r in manifest:
      if r.oracle == "-": continue
      inc withOracle
      checkpoint(r.id & ": Unicode says " & r.oracle)
      counted parseInt(r.oracle) == measure(docById(r.id)).clusters
    # A filter that matched nothing would satisfy the loop above, so the
    # population is asserted — and it is asserted by KIND, because "eleven
    # oracles" is satisfied by eleven of the cheap kind.
    var handOracles = 0
    var ucdOracles = 0
    var noOracle: seq[string] = @[]
    for r in manifest:
      if r.audit == "hand-audited": inc handOracles
      elif r.audit == "ucd-oracle": inc ucdOracles
      if r.oracle == "-": noOracle.add r.id
    checkpoint($withOracle & " documents carry an independent oracle: " &
               $handOracles & " hand-audited, " & $ucdOracles & " from the UCD")
    counted handOracles == 8
    counted ucdOracles == 3
    counted withOracle == handOracles + ucdOracles
    counted withOracle == 11
    # EXACTLY ONE short document has no cluster oracle, and it is class 7's:
    # what Nim's `fastRuneAt` yields for a byte that is not text is an
    # implementation's answer, not a fact about Unicode, so the audit is on its
    # BYTES instead and the manifest says `bytes-audited` rather than leaving
    # the column looking like the others.
    counted "c7-illformed-short" in noOracle
    var shortWithoutOracle = 0
    for id in noOracle:
      for r in manifest:
        if r.id == id and r.kind == "short": inc shortWithoutOracle
    counted shortWithoutOracle == 1
    counted noOracle.len == 7

  test "the recorded unrepresentable cases are real, and each one is demonstrated":
    # §5.1: an omitted row and an impossible row look identical in a pass. So
    # every row here is ATTEMPTED, and the attempt has to fail in the stated
    # way.
    counted unrepresentable.len == 3
    var byId: seq[string] = @[]
    for (id, doc, why) in unrepresentable:
      byId.add id
      checkpoint(id)
      counted why.len > 60           # a reason, not a label
      counted docById(doc).len > 0   # it names a document that exists

    # 1. A lone CR is not a terminator: the document holds CRs the line count
    #    does not see.
    counted "lone-cr-is-not-a-terminator" in byId
    let term = docById("c6-terminators-long")
    var crs = 0
    var lfs = 0
    for ch in term:
      if ch == '\r': inc crs
      elif ch == '\n': inc lfs
    let s = toTextStore(term)
    counted crs > 0
    counted s.lineCount == lfs + 1
    counted s.lineCount < crs + lfs + 1    # the CRs really are not counted

    # 2. CRLF is one cluster and no line can hold it.
    counted "crlf-cluster-spans-a-line" in byId
    var crlfPairs = 0
    for i in 0 ..< term.len - 1:
      if term[i] == '\r' and term[i + 1] == '\n': inc crlfPairs
    counted crlfPairs > 0
    var lineEndingCrs = 0
    for line in term.split('\n'):
      if line.len > 0 and line[^1] == '\r': inc lineEndingCrs
    counted lineEndingCrs == crlfPairs
    # The CR at the end of such a line is its OWN cluster, which is exactly the
    # "CRLF counted as two clusters" shape — here a property of the storage
    # model rather than of the segmenter.
    var lonelyCrClusters = 0
    for line in term.split('\n'):
      if line.len > 0 and line[^1] == '\r':
        for c in graphemeClusters(line):
          if c.text == "\r": inc lonelyCrClusters
    counted lonelyCrClusters >= crlfPairs
    # And the segmenter really does join them when they ARE adjacent, so this
    # is the model's limitation and not the segmenter's (two-sided).
    var joined = 0
    for c in graphemeClusters("a\r\nb"):
      if c.text == "\r\n": inc joined
    counted joined == 1

    # 3. An edit at a bare continuation byte is refused.
    counted "edit-at-a-bare-continuation-byte" in byId
    let ill = docById("c7-illformed-short")
    var refused = 0
    var accepted = 0
    for off in 0 .. ill.len:
      var probe = toTextStore(ill)
      let p = probe.posOf(off)
      try:
        probe.replaceRange(p, p, "")
        inc accepted
      except ValueError:
        inc refused
    checkpoint($refused & " of " & $(ill.len + 1) & " offsets refuse an edit")
    counted refused > 0
    counted accepted > 0          # two-sided: it is not refusing everything
    counted refused + accepted == ill.len + 1

# ---------------------------------------------------------------------------
# Grapheme segmentation's allocation profile, on ALL EIGHTEEN documents
# ---------------------------------------------------------------------------

template profileCase(docId: string) =
  test docId & " — the grapheme allocation profile":
    ## PLAT-24 deliverable: *"The grapheme allocation profile is taken on all
    ## eighteen corpus documents, so the figure is a distribution rather than
    ## one number from whichever file was open."* The TIMING half is the
    ## benchmark's (§4.5); what a suite can assert is the profile's shape, and
    ## the falsifiable part of that is that segmentation loses nothing: the
    ## cluster texts of a line concatenate back to the line, byte for byte,
    ## including on bytes that are not text at all.
    checkpoint(docId)
    let text = docById(docId)
    var clusters = 0
    var runeTotal = 0
    var emptyClusters = 0
    var rebuiltAll = true
    var maxCluster = 0
    for line in text.split('\n'):
      var rebuilt = ""
      for c in graphemeClusters(line):
        inc clusters
        if c.text.len == 0: inc emptyClusters
        if c.text.len > maxCluster: maxCluster = c.text.len
        rebuilt.add c.text
        # The yielded byte span and the yielded text must agree, or a caller
        # that indexes by the span and a caller that uses the text disagree
        # about the same cluster.
        if line[c.start ..< c.stop] != c.text: rebuiltAll = false
      if rebuilt != line: rebuiltAll = false
      for _ in runes(line): inc runeTotal
    counted rebuiltAll
    counted emptyClusters == 0
    counted clusters > 0
    counted runeTotal >= clusters          # a cluster is one or more runes
    # The allocation figure itself: `graphemeClusters` builds three `seq`s
    # before its first yield — a `seq[int32]` of runes and two `seq[int]` of
    # byte offsets — so it reserves 4 + 8 + 8 bytes per rune of the line, plus
    # one fresh substring per cluster.
    let lineCount = text.split('\n').len
    let bufferBytesPerLine = runeTotal * 20 div lineCount
    let clustersPerRune = clusters * 100 div runeTotal
    checkpoint("runes=" & $runeTotal & " clusters=" & $clusters &
               " buffers=" & $bufferBytesPerLine & " B/line" &
               " clusters/rune=" & $clustersPerRune & "%")
    counted bufferBytesPerLine > 0
    # And the manifest agrees about both, so the profile and the manifest
    # cannot drift apart without one of them going red.
    for r in manifest:
      if r.id == docId:
        counted r.clusters == clusters
        counted r.runes == runeTotal

suite "PLAT-24 corpus — grapheme segmentation's allocation profile":
  profileCase("c1-zwj-short")
  profileCase("c2-combining-short")
  profileCase("c3-regional-short")
  profileCase("c4-ambiguous-short")
  profileCase("c5-cjk-short")
  profileCase("c6-terminators-short")
  profileCase("c7-illformed-short")
  profileCase("c8-tabs-short")
  profileCase("c9-ascii-control-short")
  profileCase("c1-zwj-long")
  profileCase("c2-combining-long")
  profileCase("c3-regional-long")
  profileCase("c4-ambiguous-long")
  profileCase("c5-cjk-long")
  profileCase("c6-terminators-long")
  profileCase("c7-illformed-long")
  profileCase("c8-tabs-long")
  profileCase("c9-ascii-control-long")

# ---------------------------------------------------------------------------
# What each class exists to catch
# ---------------------------------------------------------------------------

suite "PLAT-24 corpus — what each class exists to catch":

  test "LAW-C5 first half: the ambiguous class MOVES with the width policy":
    var moved = 0
    for d in docsOfClass(4):
      inc moved
      let f = measure(d.text)
      checkpoint(d.id & ": " & $f.widthNarrow & " -> " & $f.widthWide)
      counted f.widthWide > f.widthNarrow
      # The difference is exactly the number of ambiguous clusters, each of
      # which goes from one cell to two — a stronger statement than "it
      # changed", and the one an off-by-one in the table would break.
      var ambiguousClusters = 0
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          if clusterDisplayWidth(c.text, awWide) !=
             clusterDisplayWidth(c.text, awNarrow):
            inc ambiguousClusters
      counted ambiguousClusters > 0
      counted f.widthWide - f.widthNarrow == ambiguousClusters
    counted moved == 2

  test "LAW-C5 second half: the ASCII-control class does NOT move":
    # The negative half, and the reason class 9 is in the corpus at all.
    # Without it a model that ignored `AmbiguousWidth` entirely would fail the
    # first half and a model that widened EVERYTHING would pass it
    # (Verification-Harness-Traps.md §7b).
    var held = 0
    for d in docsOfClass(9):
      inc held
      let f = measure(d.text)
      checkpoint(d.id & ": " & $f.widthNarrow & " / " & $f.widthWide)
      counted f.widthNarrow == f.widthWide
      counted f.widthNarrow > 0
      # Every byte is ASCII — the property that makes the invariance a fact
      # about the document rather than a coincidence about its contents.
      var nonAscii = 0
      for ch in d.text:
        if uint8(ch) > 0x7F'u8: inc nonAscii
      counted nonAscii == 0
      # And it really does carry ASCII CONTROL characters, or the class is a
      # plain-text class wearing a control-character name.
      var controls = 0
      for ch in d.text:
        if ch != '\n' and (uint8(ch) < 0x20'u8 or uint8(ch) == 0x7F'u8):
          inc controls
      counted controls > 0
    counted held == 2

  test "class 1: a ZWJ sequence is one cluster and one backspace":
    var families = 0
    var docs = 0
    var spanDisagreements = 0
    for d in docsOfClass(1):
      inc docs
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          if c.text.contains("‍") and c.text.len > 3:
            inc families
            # The yielded byte span and the yielded text describe the same
            # cluster, or a caller that indexes and a caller that copies
            # disagree about where a family emoji ends.
            if c.stop - c.start != c.text.len: inc spanDisagreements
    counted docs == 2
    checkpoint($families & " ZWJ clusters in the class")
    counted families > 100
    counted spanDisagreements == 0
    # The named case §5's headline is about: a family emoji is ONE backspace.
    let short = docById("c1-zwj-short")
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    counted short.contains(family)
    var s = toTextStore(short)
    let line0 = s.lineText(0)
    var lastStart = 0
    var lastStop = 0
    for c in graphemeClusters(line0):
      lastStart = c.start
      lastStop = c.stop
    counted line0[lastStart ..< lastStop] == family
    s.delete(textPos(0, lastStart), textPos(0, lastStop))
    counted s.lineText(0) == "family: "
    counted s.lineText(0).len == line0.len - family.len

  test "class 2: a combining mark never separates from its base":
    var multiRuneClusters = 0
    var docs = 0
    for d in docsOfClass(2):
      inc docs
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          var n = 0
          for _ in runes(c.text): inc n
          if n > 1: inc multiRuneClusters
    counted docs == 2
    checkpoint($multiRuneClusters & " multi-rune clusters")
    counted multiRuneClusters > 500
    # A mark with no base at all is its OWN cluster of width 0 — the case a
    # segmenter that assumes a base gets wrong.
    let short = docById("c2-combining-short")
    var orphan = 0
    for line in short.split('\n'):
      var first = true
      for c in graphemeClusters(line):
        if first and clusterDisplayWidth(c.text, awNarrow) == 0: inc orphan
        first = false
    counted orphan > 0

  test "class 3: an ODD TRAILING regional indicator is its own cluster":
    # §5.1's named case, "which is the case a naive pair-chunker gets wrong".
    let short = docById("c3-regional-short")
    let lines = short.split('\n')
    counted lines[2].startsWith("pair+odd: ")
    var clusters: seq[string] = @[]
    for c in graphemeClusters(lines[2]):
      clusters.add c.text
    # "pair+odd: " is ten ASCII clusters, then TWO flags, then ONE lone
    # indicator — thirteen, not twelve and not fourteen.
    counted clusters.len == 13
    var ri = 0
    for r in runes(clusters[^1]): inc ri
    counted ri == 1
    counted clusters[^2].runeLen == 2
    counted clusters[^3].runeLen == 2
    # A lone indicator is still two cells wide, under both policies.
    counted clusterDisplayWidth(clusters[^1], awNarrow) == 2
    counted clusterDisplayWidth(clusters[^1], awWide) == 2
    # And the long document ends EVERY line with one, so the case is a
    # distribution rather than one line somebody wrote.
    let long = docById("c3-regional-long")
    var oddTails = 0
    var textLines = 0
    for line in long.split('\n'):
      if line.len == 0: continue
      inc textLines
      var last = ""
      for c in graphemeClusters(line): last = c.text
      if last.runeLen == 1 and last.len == 4: inc oddTails
    counted textLines > 200
    counted oddTails == textLines

  test "class 5: a CJK wide glyph is two cells under BOTH policies":
    var wide = 0
    var docs = 0
    for d in docsOfClass(5):
      inc docs
      let f = measure(d.text)
      checkpoint(d.id & ": " & $f.widthNarrow & " / " & $f.widthWide)
      counted f.widthNarrow == f.widthWide      # W is not A: policy-invariant
      var policyMoved = 0
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          if clusterDisplayWidth(c.text, awNarrow) == 2:
            inc wide
            if clusterDisplayWidth(c.text, awWide) != 2: inc policyMoved
      counted policyMoved == 0
    counted docs == 2
    counted wide > 1000
    # The width really is carried by the glyph and not by the byte count: a
    # three-byte CJK character and a three-byte ambiguous one differ.
    counted clusterDisplayWidth("漢", awNarrow) == 2
    counted clusterDisplayWidth("─", awNarrow) == 1
    counted clusterDisplayWidth("─", awWide) == 2

  test "class 6: lines and terminators agree, and a lone CR is not one":
    var docs = 0
    for d in docsOfClass(6):
      inc docs
      var lfs = 0
      for ch in d.text:
        if ch == '\n': inc lfs
      let s = toTextStore(d.text)
      checkpoint(d.id & ": " & $lfs & " terminators, " & $s.lineCount & " lines")
      counted s.lineCount == lfs + 1
      counted s.text == d.text
    counted docs == 2
    # No final newline — §5.1 names it, and it is the case that decides whether
    # a document's last line exists.
    let short = docById("c6-terminators-short")
    counted not short.endsWith("\n")
    let long = docById("c6-terminators-long")
    counted not long.endsWith("\n")
    let s = toTextStore(short)
    counted s.lineText(s.lineCount - 1) == "no final newline"
    counted s.lineLen(s.lineCount - 1) == 16
    # Mixed terminators in one file, all three kinds present.
    counted short.contains("\r\n")
    counted short.contains("\rB")            # a lone CR, mid-line
    counted short.contains("one\nc")         # a bare LF

  test "class 7: ill-formed bytes are stored and reported, never truncated":
    var docs = 0
    for d in docsOfClass(7):
      inc docs
      # The store holds them byte for byte. A store that normalised or dropped
      # an invalid byte would corrupt a file it merely opened.
      let s = toTextStore(d.text)
      checkpoint(d.id)
      counted s.text == d.text
      counted s.len == d.text.len
      # And the segmenter loses nothing either.
      var rebuilt = ""
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          rebuilt.add c.text
        rebuilt.add '\n'
      if rebuilt.len > 0: rebuilt.setLen(rebuilt.len - 1)
      counted rebuilt == d.text
    counted docs == 2
    # Every byte-level case §5.1 names is PRESENT — an omitted case and an
    # impossible one look identical in a pass, so the presence is asserted.
    let short = docById("c7-illformed-short")
    counted short.contains("\x80\xBF")                 # bare continuations
    counted short.contains("\xE2\x82")                 # truncated 3-byte
    counted short.contains("\xF0\x9F\x98")             # truncated 4-byte
    counted short.contains("\xC0\x80")                 # overlong
    counted short.contains("\xF5\xFF\xFE")             # invalid leads
    counted short.contains("\xED\xA0\x80")             # WTF-8 high surrogate
    counted short.contains("\xED\xB0\x80")             # WTF-8 low surrogate
    counted short.contains("\xED\xA0\xBD\xED\xB8\x80") # CESU-8 pair
    counted short.contains("\x00")                     # an embedded NUL
    # A WTF-8 surrogate decodes to ONE rune rather than being dropped.
    var surrogateRunes = 0
    for r in runes("\xED\xA0\x80"): inc surrogateRunes
    counted surrogateRunes == 1

  test "class 8: tabs expand to tab stops, at more than one tab size":
    # §5.1: "tab size is a parameter, so each document is exercised at more
    # than one". PLAT-24 does not own the wrap model — that is PLAT-27 — so
    # what is asserted here is the expansion and the PRESENCE of the cases a
    # wrap model will need, not a wrap.
    # The declared matrix, §6: wrap columns {20, 40, 80, 120}, tab sizes
    # {2, 4, 8}. Declared, not sampled.
    const WrapColumns = [20, 40, 80, 120]
    const TabSizes = [2, 4, 8]
    var docs = 0
    var tabsSeen = 0
    var straddles = 0
    var landings = 0
    var stopViolations = 0
    var expansionDisagreements = 0
    for d in docsOfClass(8):
      inc docs
      var tabBytes = 0
      for ch in d.text:
        if ch == '\t': inc tabBytes
      var tabClusters = 0
      for line in d.text.split('\n'):
        for c in graphemeClusters(line):
          if c.text == "\t": inc tabClusters
      checkpoint(d.id & ": " & $tabBytes & " tab bytes")
      counted tabBytes > 0
      # Two-sided: the cluster walk finds exactly the tabs the bytes hold.
      counted tabClusters == tabBytes
      for tabSize in TabSizes:
        var widest = 0
        for line in d.text.split('\n'):
          let expanded = expandTabs(line, tabSize, awNarrow)
          if expanded > widest: widest = expanded
          var col = 0
          for c in graphemeClusters(line):
            if c.text == "\t":
              let before = col
              col = ((col div tabSize) + 1) * tabSize
              inc tabsSeen
              # Every tab lands on a stop and advances by 1..tabSize. The
              # violations are COUNTED and asserted once, rather than asserted
              # per tab: 636 tabs x 3 sizes x 3 claims is 5,724 assertions
              # whose count says nothing a single zero does not.
              if col mod tabSize != 0 or col - before < 1 or
                 col - before > tabSize:
                inc stopViolations
              for w in WrapColumns:
                if before < w and col > w: inc straddles
                elif col == w: inc landings
            else:
              col += clusterDisplayWidth(c.text, awNarrow)
          if col != expanded: inc expansionDisagreements
        checkpoint("tab size " & $tabSize & ": widest line " & $widest)
        counted widest > 0
    counted docs == 2
    counted tabsSeen > 0
    counted stopViolations == 0
    counted expansionDisagreements == 0
    # The corpus really contains a tab whose expansion STRADDLES a wrap column
    # — before < W < after, which is a different case from landing exactly on
    # it and is the one §5.1 names. It only exists when the wrap column is not
    # a multiple of the tab size: at tab size 8 a tab at column 19 advances to
    # 24 and straddles 20, where at column 39 it merely lands on 40. Both are
    # in the corpus and both are counted, because a class whose named case is
    # absent is a class every later law is quantified over without it.
    checkpoint("over " & $tabsSeen & " (tab, size) pairs: " & $straddles &
               " straddle a wrap column, " & $landings & " land on one")
    counted straddles > 0
    counted landings > 0
    # Consecutive tabs, and a tab as a line's FIRST cluster.
    let short = docById("c8-tabs-short")
    counted short.contains("\t\t\t\t")
    var leading = 0
    for line in short.split('\n'):
      if line.len > 0 and line[0] == '\t': inc leading
    counted leading >= 4
    # Tab size really is a parameter: the same line is wider at 8 than at 2.
    counted expandTabs("\ta", 8, awNarrow) == 9
    counted expandTabs("\ta", 2, awNarrow) == 3

  test "the corpus is cluster-dense, which is the whole point of having one":
    # §4.5's figures were taken on a path-sorted `.nim` corpus that is 99.8%
    # ASCII. The corpus exists so that segmentation is measured on the
    # distribution the model will actually meet, and "cluster-dense" is a claim
    # with a number behind it or it is a word.
    var asciiRunes = 0
    var totalRunes = 0
    var totalClusters = 0
    for d in CorpusDocs:
      let f = measure(d.text)
      totalRunes += f.runes
      totalClusters += f.clusters
      for r in runes(d.text):
        if int32(r) < 0x80: inc asciiRunes
    let asciiPercent = asciiRunes * 1000 div totalRunes
    let runesPerCluster = totalRunes * 100 div totalClusters
    checkpoint("corpus: " & $totalRunes & " runes, " & $totalClusters &
               " clusters, " & $asciiPercent & " per mille ASCII, " &
               $runesPerCluster & " runes per 100 clusters")
    # The `.nim` corpus §4.5 used is 99.8% ASCII (998 per mille) and has one
    # rune per cluster. This one must be neither.
    counted asciiPercent < 800
    counted runesPerCluster > 110
    counted totalRunes > 100_000

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
