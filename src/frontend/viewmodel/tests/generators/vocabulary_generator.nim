## vocabulary_generator.nim — PLAT-30's POPULATION: one scenario per
## declaration, over corpus text, built so that the operation ACTS.
##
## NOT-A-TEST-LANE-FILE: the population's constructor, its landmarks and its
## declared expectations. The assertions are in
## `../unit/test_editor_vocabulary_laws.nim`.
##
## =========================================================================
## §34 IS THIS MILESTONE'S MOST LIKELY TRAP AND IT IS IN THE INPUTS
## =========================================================================
##
## Verification-Harness-Traps §34, in the form it takes here: *"a sweep whose
## INPUTS make most operations no-ops — an empty document, a caret at 0, no
## selection"*. It is not hypothetical. Driving all 224 against one ad-hoc
## document and one caret, while this module was being written, produced
##
##     total=224  acted=177  no-op=12  refused=35
##
## — every one of those 47 a green case that had executed nothing. A sweep
## reporting `OK (224 tests)` over that population is a sweep about its
## document.
##
## So the population is **one declared scenario per declaration**: a document,
## a caret or selection placed at a NAMED LANDMARK of it, whatever state the
## operation needs (a mark, a register, a recorded macro, a non-empty undo
## stack), and the argument its declaration takes. The suite asserts
## `acted == 224` as an EQUALITY, per operation and in total, and the
## refusals get their own two-sided sweep rather than being what the main one
## silently measures.
##
## =========================================================================
## THE DOCUMENTS ARE CORPUS TEXT WITH STRUCTURE BUILT AROUND IT
## =========================================================================
##
## PLAT-30's own spec: *"Every operation is exercised against corpus documents
## rather than ASCII. `char-left` over a ZWJ family and `delete-char-backward`
## over a combining sequence are the two operations most likely to regress
## silently as the storage changes under them."*
##
## That is in tension with category B: `select-inner-parens` needs a paren, and
## §5's eighteen corpus documents contain almost no ASCII punctuation at all —
## they are ZWJ families, Devanagari clusters, regional indicators, CJK and
## ill-formed bytes. A scenario document of pure corpus text would leave
## twenty-six object operations with nothing to find, which is §34 again one
## level down.
##
## **The resolution is to FRAME corpus text in structure rather than to replace
## it with ASCII.** Each of the eighteen documents contributes a run of
## consecutive grapheme clusters, and those clusters are what sits inside the
## parens, inside the quotes, inside the tag, on the indented line and on the
## line `delete-char-backward` deletes from. So `select-inner-parens` finds a
## paren AND the text it selects is a real ZWJ family; `delete-char-backward`
## removes a whole combining sequence.
##
## **THE RUN IS MEASURED, NOT ASSUMED.** A cluster is admitted to the run only
## if it carries none of the structural bytes the frame uses — the run would
## otherwise close a paren the frame opened, and the object operations would be
## reading a document the scenario did not describe. Measured over the pinned
## corpus on 2026-09-18, the longest admissible run is **at least 7 clusters**
## in every one of the eighteen documents (`c2-combining-short` and
## `c4-ambiguous-short` are the two shortest, at 7), which is why no segment
## below asks for more than four. `RunFloor` is asserted of every document by
## the suite, so a corpus edit that shortened one is red here rather than
## silently producing a scenario with an empty paren.

import std/[options, strutils, tables]

import isonim_tui/text/width as widthMod

import ../../editor/operations
import ../corpus/unicode_corpus

export operations, unicode_corpus

const
  StructuralBytes* = {'"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}',
                      '#', '\n', '\r', '\\', ',', ':', '\t'}
    ## The bytes the frame below uses. A cluster carrying one of them cannot go
    ## inside the frame, because it would close what the frame opened.

  RunFloor* = 7
    ## The shortest admissible run over the pinned corpus, measured. Asserted
    ## per document by the suite: a corpus edit that drops one below this makes
    ## a scenario's paren empty, and an empty object is an operation that
    ## refuses in a sweep whose whole claim is that nothing refuses.

  SegMax* = 4
    ## No segment asks for more than this, so `RunFloor` clusters suffice.

  DisplayWrapA* = 8
  DisplayWrapB* = 64
    ## The wrap-column pair the suite sweeps at, declared HERE because the
    ## `displayCaret` landmark is searched against it: a landmark chosen at one
    ## pair and asserted at another is a landmark chosen for nothing.

type
  Landmarks* = object
    ## Named offsets into the scenario document. **The scenario names them and
    ## the expectations refer to them by name**, so a case that asserts "this
    ## motion lands on the matching bracket" is comparing against an offset the
    ## scenario recorded while BUILDING the document, never against one
    ## recomputed by the same algorithm the operation uses (§30).
    line0Mid*, line1Mid*, line1End*, line1FirstNonBlank*: int
    line1Early*: int
      ## One cluster past line 1's first non-blank. **A display-row motion
      ## needs a caret that is not ALREADY at its row's edge**, and `line1Mid`
      ## is not: at `wrapColumn 8` it fell exactly on a row boundary for
      ## `c1-zwj-long`, so `display-line-start` had nowhere to go and the
      ## sweep recorded a no-op. Four cells in is inside row 0 at every wrap
      ## column the suite uses, because no cluster is wider than two cells.
    transposeCaret*: int
      ## A cluster boundary with two DIFFERENT clusters around it. Searched
      ## rather than computed: `transpose-chars` is a no-op between two equal
      ## clusters, and `c8-tabs-short`'s admissible run is a repeated
      ## character, so the third boundary of the document transposed a cluster
      ## with its twin and changed nothing.
    displayCaret*: int
      ## A cluster boundary that, at `DisplayWrapA`, sits on a row that is NOT
      ## its logical line's first and at a column that is neither 0 nor the
      ## row's last — and that at `DisplayWrapB` sits on its line's first row.
      ## Searched, for the same reason: `display-line-start` has nowhere to go
      ## from a caret already at column 0, and answers the SAME thing at both
      ## wrap columns from a caret whose row is the line's first at both. The
      ## first spelling of this landmark was a constant offset and it produced
      ## a no-op on one document and, after that was repaired, twelve display
      ## cases that no longer differed at all.
    docCluster2*: int
      ## The document's THIRD cluster boundary. `transpose-chars` needs a
      ## cluster on each side of the caret, and a caret at boundary 0 or 1 has
      ## nothing to transpose — which is what two documents produced from
      ## `line0Mid`.
    line2Mid*, line3Mid*, line6Mid*, nearEnd*: int
    camelStart*, camelMid*, camelEnd*: int
    parensInner*, bracketsInner*, bracesInner*, angleInner*: int
    singleInner*, doubleInner*, backInner*, tagInner*: int
    defOpenParen*, defCloseParen*: int
    blankLineStart*: int
    line2Start*: int
    commentedFrom*, commentedTo*: int
    blockFrom*, blockTo*: int
    trailingFrom*, trailingTo*: int
    spanFrom*, spanTo*: int          ## a span over line 0's corpus clusters
    indentSpanFrom*, indentSpanTo*: int
    multiFrom*, multiTo*: int        ## a span crossing three logical lines
    markOffset*: int
    jumpPrev*, jumpMid*, jumpNext*: int
    needle*: string
    needleAt*: int                   ## the FIRST occurrence at or after `line6Mid`
    beforeMatch*, afterMatch*: int

  ScenarioDoc* = object
    id*: string       ## the corpus document the clusters came from
    cls*: int         ## §5's class, 1 … 9
    text*: string
    runLen*: int      ## the admissible run this document contributed
    marks*: Landmarks

  CaretAt* = enum
    ## Where the scenario puts the selection. The `sp*` and `two*` members are
    ## selections rather than carets, which is the whole point of having them:
    ## an operator with no selection to consume is an operator that no-ops.
    caLine0Mid, caLine1Mid, caLine1End, caLine2Mid, caLine3Mid, caLine6Mid
    caDocStart, caDocEnd, caNearEnd
    caCamelStart, caCamelMid, caCamelEnd
    caParensInner, caBracketsInner, caBracesInner, caAngleInner
    caSingleInner, caDoubleInner, caBackInner, caTagInner
    caDefOpenParen, caBeforeMatch, caAfterMatch
    caCommentedLine, caTrailingLine
    caLine1Early, caDocCluster2, caTransposeCaret, caDisplayCaret
    spLine0Clusters, spCamelWord, spLine2Indented, spLines0to2
    spCommentedLine, spBlockComment
    twoCarets

  Prep* = enum
    ## Extra state a scenario needs for its operation to have something to do.
    prFresh          ## `EditorState.parse = pfFresh`
    prMark
    prSearch
    prJumps
    prRegister
    prMacro
    prLastChange
    prUndo
    prRedo
    prSelUndo
    prSelRedo
    prFolded
    prPending
    prInsertMode
    prSearchBackward
      ## The search direction starts BACKWARD. `search-forward` sets it
      ## forward, and from a state that is already forward it has nothing to
      ## do — which is §34 in one field of one scenario.

  Check* = enum
    ## **THE WITNESS.** One or more per declaration, declared HERE and asserted
    ## by the suite — never by the module under test. Each is a statement about
    ## the operation's NAME rather than about "something changed", which is
    ## what makes a mutation that swaps two implementations observable rather
    ## than merely a different valid structure (§36).
    ckMovedBack, ckMovedFwd
    ckOneCluster          ## exactly one grapheme-cluster step
    ckOnClusterBoundary   ## the landing is a cluster boundary of the document
    ckLineUp, ckLineDown
    ckRowUp, ckRowDown
    ckAtLineStart, ckAtLineEnd
    ckAtLandmark
    ckAtMatch             ## the bytes at the landing are the search pattern
    ckRowCol0, ckRowColEnd
    ckSpanContainsCaret
    ckAroundContainsInner ## `around` strictly contains `inner`
    ckDelimiters          ## `around` begins and ends with the declared bytes
    ckDocChanged, ckDocGrew, ckDocShrank
    ckDocMinusSelection   ## the document shrank by exactly the selection's bytes
    ckSelectionChanged
    ckModeInsert, ckModeChanged
    ckRegisterContent     ## the active register's text changed
    ckActiveRegister      ## which register is active changed
    ckUndoGrew, ckRedoGrew
    ckSearchChanged
    ckFoldChanged
    ckMarkerChanged
    ckIntent
    ckCountChanged
    ckMacroChanged
    ckOperatorChanged
    ckLineCountUp, ckLineCountDown
    ckClusterMinusOne, ckBytesPermuted
    ckRangeCountUp, ckRangeCountDown
    ckPrimaryMoved
    ckUpperCased, ckLowerCased
    ckCommented, ckUncommented
    ckIndented

  LandmarkKind* = enum
    lkNone, lkDocStart, lkDocEnd, lkLine2Start, lkMark, lkJumpPrev,
    lkJumpNext, lkDefCloseParen, lkLine1FirstNonBlank, lkBlankLineStart

  ScenarioSpec* = object
    ## One row per DECLARATION. 140 of them, in `operations.vocabulary()`'s own
    ## order, which the suite asserts by comparing the two name lists.
    decl*: string
    caret*: CaretAt
    preps*: set[Prep]
    args*: OpArgs
    checks*: set[Check]
    delimiters*: string
    landmark*: LandmarkKind

  Scenario* = object
    doc*: ScenarioDoc
    state*: EditorState
    spec*: ScenarioSpec
    args*: OpArgs
      ## `spec.args`, with any document-dependent field filled in. The suite
      ## drives THIS rather than `spec.args`.

# ===========================================================================
# THE ADMISSIBLE RUN
# ===========================================================================

proc clusterBoundariesOfText*(text: string): seq[int] =
  result = @[0]
  for c in graphemeClusters(text):
    if c.stop > result[^1]: result.add c.stop
  if result[^1] != text.len: result.add text.len

proc admissibleRun*(text: string; bs: seq[int]; want: int): (int, int) =
  ## The first run of `want` consecutive clusters carrying no structural byte
  ## and no C0 control, or the longest run there is.
  ##
  ## A space is admitted deliberately: excluding it cut `c2-combining-long`'s
  ## longest run to **two** clusters, because the UCD-derived documents are
  ## space-separated sequences. A space inside a paren is not a problem the
  ## frame has.
  var best = (0, 0)
  var runStart = 0
  var runLen = 0
  for i in 0 ..< bs.len - 1:
    let cl = text[bs[i] ..< bs[i + 1]]
    var ok = cl.len > 0
    for ch in cl:
      if ch in StructuralBytes or ch.int < 0x20: ok = false
    if ok:
      if runLen == 0: runStart = i
      inc runLen
      if runLen > best[1]: best = (runStart, runLen)
      if runLen >= want: return (runStart, runLen)
    else:
      runLen = 0
  best

# ===========================================================================
# THE SCENARIO DOCUMENT
# ===========================================================================

proc transposeWitness*(text: string; bs: seq[int]): int =
  ## The first cluster boundary whose two neighbouring clusters DIFFER. -1 when
  ## the document has none, which the suite asserts never happens.
  for i in 1 ..< bs.len - 1:
    if text[bs[i - 1] ..< bs[i]] != text[bs[i] ..< bs[i + 1]]:
      return bs[i]
  -1

proc displayWitness*(text: string; bs: seq[int]): int =
  ## The first cluster boundary that witnesses what a display-row motion needs.
  ## See `Landmarks.displayCaret`.
  let ca = initWrapCache(text, wrapSettings(DisplayWrapA))
  let cb = initWrapCache(text, wrapSettings(DisplayWrapB))
  let store = toTextStore(text)
  for b in bs:
    if b <= 0 or b >= text.len: continue
    let pos = store.posOf(b)
    let da = ca.toDisplay(pos)
    let db = cb.toDisplay(pos)
    if da.row <= ca.firstRowOf(pos.line): continue
    if da.column <= 0 or da.column >= ca.lastColumnOf(da.row): continue
    if db.row != cb.firstRowOf(pos.line): continue
    return b
  -1

proc buildScenarioDoc*(id: string; cls: int; source: string): ScenarioDoc =
  ## Seventeen lines of corpus clusters inside a frame that carries one of
  ## every structure the vocabulary names. **One document per corpus document**
  ## rather than one per operation: the caret placement is what varies, so the
  ## eighteen documents are the population's only degree of freedom and the
  ## suite can assert every one of them is used.
  let bs = clusterBoundariesOfText(source)
  let (runStart, runLen) = admissibleRun(source, bs, 32)
  proc seg(k, n: int): string =
    ## `n` consecutive clusters of the admissible run, starting `k` into it and
    ## clamped so the slice never wraps — a wrap would join the run's last
    ## cluster to its first, and a base plus a following combining mark are one
    ## cluster, not two.
    ##
    ## **A LEADING BLANK CLUSTER IS SKIPPED, AND THAT IS NOT COSMETIC.** The run
    ## admits a space (see `admissibleRun` on why), and a segment that BEGINS
    ## with one lengthens the frame's indent — so `line1FirstNonBlank`, which
    ## the scenario records as "four spaces in", stops being where the first
    ## non-blank actually is, and `line-start-smart`'s landmark case fails on a
    ## landmark that is wrong rather than on a motion that is. It did, on four
    ## of the eighteen documents, on the first run — and on a fifth after the
    ## first repair, because the test was `strip().len == 0` and a cluster of
    ## *space + combining mark* is not blank to `strip` and IS leading
    ## whitespace to a byte scan. The predicate is the byte one now, which is
    ## the question actually being asked.
    let take = min(n, runLen)
    var off = if runLen - take <= 0: 0 else: k mod (runLen - take + 1)
    var tries = 0
    while tries < runLen and
          source[bs[runStart + off]] in {' ', '\t'}:
      off = if runLen - take <= 0: 0 else: (off + 1) mod (runLen - take + 1)
      inc tries
    let a = bs[runStart + off]
    let b = bs[runStart + off + take]
    source[a ..< b]

  var lines: seq[string] = @[]
  var m: Landmarks
  proc emit(s: string) = lines.add s
  proc offsetOfLine(i: int): int =
    var n = 0
    for k in 0 ..< i: n += lines[k].len + 1
    n

  emit seg(0, 4)                                       # 0
  emit "    " & seg(1, 4) & " fooBarBaz_qux"            # 1
  emit "        " & seg(2, 4)                           # 2
  emit seg(3, 3) & "   "                                # 3  trailing blanks
  emit ""                                               # 4  paragraph break
  emit "def f(" & seg(0, 2) & ", " & seg(1, 2) & "):"   # 5
  emit "    arr = [" & seg(2, 2) & "]"                  # 6
  emit "    obj = {" & seg(3, 2) & "}"                  # 7
  emit "    gen = <" & seg(0, 2) & ">"                  # 8
  emit "    s1 = '" & seg(1, 2) & "'"                   # 9
  emit "    s2 = \"" & seg(2, 2) & "\""                 # 10
  emit "    s3 = `" & seg(3, 2) & "`"                   # 11
  emit "    <em>" & seg(0, 2) & "</em>"                 # 12
  emit "    #[" & seg(1, 2) & "]#"                      # 13
  emit "# " & seg(2, 2)                                 # 14
  emit ""                                               # 15
  emit "tail " & seg(3, 2)                              # 16
  emit ""                                               # 17 — the final newline

  let text = lines.join("\n")
  let tbs = clusterBoundariesOfText(text)
  proc snap(p: int): int =
    ## Every landmark is snapped to a cluster boundary. A landmark inside a
    ## cluster would make "the caret is at the landmark" a statement the model
    ## refuses to satisfy, and the case would then be about the snap.
    var lo = 0
    for b in tbs:
      if b <= p: lo = b else: break
    lo
  proc afterInLine(i: int; needle: string): int =
    let at = lines[i].find(needle)
    if at < 0: offsetOfLine(i) else: offsetOfLine(i) + at + needle.len
  proc atInLine(i: int; needle: string): int =
    let at = lines[i].find(needle)
    if at < 0: offsetOfLine(i) else: offsetOfLine(i) + at

  m.line0Mid = snap(offsetOfLine(0) + lines[0].len div 2)
  m.line1Mid = snap(offsetOfLine(1) + 4 + (lines[1].len - 4) div 2)
  m.line1End = offsetOfLine(1) + lines[1].len
  m.line1FirstNonBlank = offsetOfLine(1) + 4
  m.line1Early = snap(m.line1FirstNonBlank + 1)
  m.docCluster2 = (if tbs.len > 3: tbs[2] else: tbs[min(1, tbs.len - 1)])
  m.transposeCaret = transposeWitness(text, tbs)
  m.displayCaret = displayWitness(text, tbs)
  m.line2Start = offsetOfLine(2)
  m.line2Mid = snap(offsetOfLine(2) + 8 + (lines[2].len - 8) div 2)
  m.line3Mid = snap(offsetOfLine(3) + lines[3].len div 2)
  m.line6Mid = snap(offsetOfLine(6) + lines[6].len div 2)
  m.nearEnd = snap(offsetOfLine(16))
  m.camelStart = atInLine(1, "fooBarBaz_qux")
  m.camelMid = m.camelStart + 3
  m.camelEnd = m.camelStart + len("fooBarBaz_qux")
  m.defOpenParen = atInLine(5, "(")
  m.defCloseParen = atInLine(5, ")")
  m.parensInner = m.defOpenParen + 1
  m.bracketsInner = atInLine(6, "[") + 1
  m.bracesInner = atInLine(7, "{") + 1
  m.angleInner = atInLine(8, "<") + 1
  m.singleInner = atInLine(9, "'") + 1
  m.doubleInner = atInLine(10, "\"") + 1
  m.backInner = atInLine(11, "`") + 1
  m.tagInner = afterInLine(12, "<em>")
  m.blankLineStart = offsetOfLine(4)
  m.commentedFrom = offsetOfLine(14)
  m.commentedTo = offsetOfLine(14) + lines[14].len
  m.blockFrom = atInLine(13, "#[")
  m.blockTo = atInLine(13, "]#") + 2
  m.trailingFrom = offsetOfLine(3)
  m.trailingTo = offsetOfLine(3) + lines[3].len
  m.spanFrom = tbs[1]
  m.spanTo = snap(offsetOfLine(0) + lines[0].len)
  m.indentSpanFrom = offsetOfLine(2) + 8
  m.indentSpanTo = offsetOfLine(2) + lines[2].len
  m.multiFrom = tbs[1]
  m.multiTo = snap(offsetOfLine(2) + lines[2].len)
  m.markOffset = snap(offsetOfLine(16))
  m.jumpPrev = snap(offsetOfLine(0))
  m.jumpMid = snap(offsetOfLine(2))
  m.jumpNext = snap(offsetOfLine(16))
  m.needle = seg(2, 2)
  m.needleAt = text.find(m.needle, offsetOfLine(6))
  if m.needleAt < 0: m.needleAt = text.find(m.needle)
  m.beforeMatch = snap(max(m.needleAt - 1, 0))
  m.afterMatch = snap(min(m.needleAt + m.needle.len + 1, text.len))

  ScenarioDoc(id: id, cls: cls, text: text, runLen: runLen, marks: m)

proc scenarioDocs*(): seq[ScenarioDoc] =
  ## One per §5 corpus document. **Eighteen, and the suite asserts eighteen**,
  ## because a loop over a list that lost a row is a sweep that lost a class.
  result = @[]
  for d in CorpusDocs:
    var cls = 0
    for i in 1 .. 9:
      if d.id.startsWith("c" & $i & "-"): cls = i
    result.add buildScenarioDoc(d.id, cls, d.text)

# ===========================================================================
# THE SPECS — one row per declaration, in §2.2's order
# ===========================================================================

func sp(decl: string; caret: CaretAt; checks: set[Check];
        preps: set[Prep] = {}; args = OpArgs();
        delimiters = ""; landmark = lkNone): ScenarioSpec =
  ScenarioSpec(decl: decl, caret: caret, preps: preps, args: args,
               checks: checks, delimiters: delimiters, landmark: landmark)

proc scenarioSpecs*(): seq[ScenarioSpec] =
  result = @[
    # --- A. Motions ------------------------------------------------------
    sp("char-left", caLine0Mid, {ckMovedBack, ckOneCluster, ckOnClusterBoundary}),
    sp("char-right", caLine0Mid, {ckMovedFwd, ckOneCluster, ckOnClusterBoundary}),
    sp("char-forward", caLine0Mid, {ckMovedFwd, ckOneCluster, ckOnClusterBoundary}),
    sp("char-backward", caLine0Mid, {ckMovedBack, ckOneCluster, ckOnClusterBoundary}),
    sp("group-left", caCamelEnd, {ckMovedBack, ckOnClusterBoundary}),
    sp("group-right", caCamelStart, {ckMovedFwd, ckOnClusterBoundary}),
    sp("group-forward", caCamelStart, {ckMovedFwd, ckOnClusterBoundary}),
    sp("group-backward", caCamelEnd, {ckMovedBack, ckOnClusterBoundary}),
    sp("subword-forward", caCamelStart, {ckMovedFwd, ckOnClusterBoundary}),
    sp("subword-backward", caCamelEnd, {ckMovedBack, ckOnClusterBoundary}),
    sp("line-up", caLine2Mid, {ckLineUp, ckOnClusterBoundary}),
    sp("line-down", caLine1Mid, {ckLineDown, ckOnClusterBoundary}),
    sp("display-line-up", caLine2Mid, {ckRowUp, ckOnClusterBoundary}),
    sp("display-line-down", caLine1Mid, {ckRowDown, ckOnClusterBoundary}),
    sp("page-up", caNearEnd, {ckRowUp, ckOnClusterBoundary}),
    sp("page-down", caDocStart, {ckRowDown, ckOnClusterBoundary}),
    sp("line-start", caLine1Mid, {ckMovedBack, ckAtLineStart}),
    sp("line-end", caLine1Mid, {ckMovedFwd, ckAtLineEnd}),
    sp("line-start-smart", caLine1End,
       {ckMovedBack, ckAtLandmark}, landmark = lkLine1FirstNonBlank),
    sp("display-line-start", caDisplayCaret, {ckMovedBack, ckRowCol0}),
    sp("display-line-end", caDisplayCaret, {ckMovedFwd, ckRowColEnd}),
    sp("doc-start", caLine1Mid, {ckMovedBack, ckAtLandmark}, landmark = lkDocStart),
    sp("doc-end", caLine1Mid, {ckMovedFwd, ckAtLandmark}, landmark = lkDocEnd),
    sp("line-number", caLine6Mid, {ckMovedBack, ckAtLandmark},
       args = OpArgs(number: 3), landmark = lkLine2Start),
    sp("matching-bracket", caDefOpenParen,
       {ckMovedFwd, ckAtLandmark}, landmark = lkDefCloseParen),
    sp("syntax-left", caCamelEnd, {ckMovedBack, ckOnClusterBoundary}, {prFresh}),
    sp("syntax-right", caCamelStart, {ckMovedFwd, ckOnClusterBoundary}, {prFresh}),
    sp("paragraph-forward", caLine1Mid,
       {ckMovedFwd, ckAtLandmark}, landmark = lkBlankLineStart),
    sp("paragraph-backward", caLine6Mid,
       {ckMovedBack, ckAtLandmark}, landmark = lkBlankLineStart),
    sp("search-next", caBeforeMatch, {ckMovedFwd, ckAtMatch}, {prSearch}),
    sp("search-prev", caAfterMatch, {ckMovedBack, ckAtMatch}, {prSearch}),
    sp("mark", caLine0Mid, {ckMovedFwd, ckAtLandmark}, {prMark},
       args = OpArgs(id: "a"), landmark = lkMark),
    sp("jump-back", caLine6Mid, {ckAtLandmark}, {prJumps}, landmark = lkJumpPrev),
    sp("jump-forward", caLine6Mid, {ckAtLandmark}, {prJumps}, landmark = lkJumpNext),

    # --- B. Text objects -------------------------------------------------
    sp("word", caLine0Mid, {ckSpanContainsCaret, ckAroundContainsInner}),
    sp("subword", caCamelMid, {ckSpanContainsCaret, ckAroundContainsInner}),
    sp("line", caLine1Mid, {ckSpanContainsCaret, ckAroundContainsInner}),
    sp("paragraph", caLine1Mid, {ckSpanContainsCaret, ckAroundContainsInner}),
    sp("parens", caParensInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "()"),
    sp("brackets", caBracketsInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "[]"),
    sp("braces", caBracesInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "{}"),
    sp("angle", caAngleInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "<>"),
    sp("quote-single", caSingleInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "''"),
    sp("quote-double", caDoubleInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "\"\""),
    sp("quote-back", caBackInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "``"),
    sp("tag", caTagInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, delimiters = "<>"),
    sp("indent-block", caLine2Mid, {ckSpanContainsCaret, ckAroundContainsInner}),
    sp("syntax-node", caParensInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, {prFresh},
       delimiters = "()"),
    sp("function", caBracesInner,
       {ckSpanContainsCaret, ckAroundContainsInner, ckDelimiters}, {prFresh},
       delimiters = "{}"),
    sp("argument", caParensInner, {ckSpanContainsCaret}, {prFresh}),

    # --- C. Operators ----------------------------------------------------
    sp("delete-selection", spLine0Clusters, {ckDocMinusSelection}),
    sp("change-selection", spLine0Clusters, {ckDocMinusSelection, ckModeInsert}),
    sp("yank-selection", spLine0Clusters, {ckRegisterContent}),
    sp("paste-before", spLine0Clusters, {ckDocGrew}, {prRegister}),
    sp("paste-after", spLine0Clusters, {ckDocGrew}, {prRegister}),
    sp("paste-replace", spLine0Clusters, {ckDocChanged}, {prRegister}),
    sp("indent-selection", spLine0Clusters, {ckDocGrew, ckIndented}),
    sp("dedent-selection", spLine2Indented, {ckDocShrank}),
    sp("reindent-selection", spLine2Indented, {ckDocChanged}, {prFresh}),
    sp("toggle-comment", spLine0Clusters, {ckDocGrew, ckCommented}),
    sp("line-comment", spLine0Clusters, {ckDocGrew, ckCommented}),
    sp("line-uncomment", spCommentedLine, {ckDocShrank, ckUncommented}),
    sp("block-comment", spLine0Clusters, {ckDocGrew}),
    sp("block-uncomment", spBlockComment, {ckDocShrank}),
    sp("upper-case", spCamelWord, {ckDocChanged, ckUpperCased}),
    sp("lower-case", spCamelWord, {ckDocChanged, ckLowerCased}),
    sp("swap-case", spCamelWord, {ckDocChanged}),
    sp("join-lines", spLines0to2, {ckDocShrank, ckLineCountDown}),
    sp("replace-char", spLine0Clusters, {ckDocChanged},
       args = OpArgs(ch: "Z")),
    sp("pipe-selection", spLine0Clusters, {ckIntent},
       args = OpArgs(command: "sort")),

    # --- D. Commands -----------------------------------------------------
    sp("insert-text", caLine0Mid, {ckDocGrew}, args = OpArgs(text: "Z")),
    sp("insert-newline", caLine0Mid, {ckDocGrew, ckLineCountUp}),
    sp("insert-newline-and-indent", caLine2Mid, {ckDocGrew, ckLineCountUp}),
    sp("insert-blank-line-above", caLine1Mid, {ckDocGrew, ckLineCountUp}),
    sp("insert-blank-line-below", caLine1Mid, {ckDocGrew, ckLineCountUp}),
    sp("insert-tab", caLine0Mid, {ckDocGrew}),

    sp("delete-char-backward", caLine0Mid, {ckDocShrank, ckClusterMinusOne}),
    sp("delete-char-forward", caLine0Mid, {ckDocShrank, ckClusterMinusOne}),
    sp("delete-group-backward", caCamelEnd, {ckDocShrank}),
    sp("delete-group-forward", caCamelStart, {ckDocShrank}),
    sp("delete-to-line-start", caLine1Mid, {ckDocShrank}),
    sp("delete-to-line-end", caLine1Mid, {ckDocShrank}),
    sp("delete-line", caLine1Mid, {ckDocShrank, ckLineCountDown}),
    sp("delete-trailing-whitespace", caLine0Mid, {ckDocShrank}),

    sp("swap-line-up", caLine1Mid, {ckDocChanged}),
    sp("swap-line-down", caLine1Mid, {ckDocChanged}),
    sp("copy-line-up", caLine1Mid, {ckDocGrew, ckLineCountUp}),
    sp("copy-line-down", caLine1Mid, {ckDocGrew, ckLineCountUp}),
    sp("split-line", caLine1Mid, {ckDocGrew, ckLineCountUp}),
    sp("transpose-chars", caTransposeCaret, {ckDocChanged, ckBytesPermuted}),

    sp("select-all", caLine0Mid, {ckSelectionChanged}),
    sp("select-line", caLine1Mid, {ckSelectionChanged}),
    sp("select-parent-syntax", caParensInner, {ckSelectionChanged}, {prFresh}),
    sp("simplify-selection", spLine0Clusters, {ckSelectionChanged}),
    sp("collapse-to-cursors", spLine0Clusters, {ckSelectionChanged}),
    sp("flip-selections", spLine0Clusters, {ckSelectionChanged}),
    sp("keep-primary-selection", twoCarets, {ckSelectionChanged, ckRangeCountDown}),

    sp("add-cursor-above", caLine2Mid, {ckRangeCountUp}),
    sp("add-cursor-below", caLine1Mid, {ckRangeCountUp}),
    # caLine6Mid and NOT caLine0Mid: the needle is `seg(2, 2)` and line 0 is
    # `seg(0, 4)`, so the needle is a SUBSTRING of line 0 — the found range
    # then abuts the caret and normalisation merges the two, leaving the
    # cursor count where it was. Measured on thirteen of the eighteen
    # documents before the caret moved.
    sp("add-cursor-at-next-match", caLine6Mid, {ckRangeCountUp}, {prSearch}),
    sp("add-cursor-at-each-line-of-selection", spLines0to2,
       {ckSelectionChanged, ckRangeCountUp}),
    sp("remove-primary-cursor", twoCarets, {ckSelectionChanged, ckRangeCountDown}),
    sp("rotate-primary-cursor", twoCarets, {ckPrimaryMoved}),

    sp("undo", caLine0Mid, {ckDocChanged, ckRedoGrew}, {prUndo}),
    sp("redo", caLine0Mid, {ckDocChanged, ckUndoGrew}, {prRedo}),
    sp("undo-selection", caLine0Mid, {ckSelectionChanged}, {prSelUndo}),
    sp("redo-selection", caLine0Mid, {ckSelectionChanged}, {prSelRedo}),

    sp("set-register", caLine0Mid, {ckActiveRegister}, args = OpArgs(id: "b")),
    sp("record-macro", caLine0Mid, {ckMacroChanged}, args = OpArgs(id: "q")),
    sp("replay-macro", caLine0Mid, {ckDocChanged}, {prMacro},
       args = OpArgs(id: "m")),
    sp("repeat-last-change", caLine0Mid, {ckDocChanged}, {prLastChange}),

    sp("enter-insert", caLine0Mid, {ckModeChanged, ckModeInsert}),
    sp("enter-insert-line-start", caLine1Mid,
       {ckModeChanged, ckModeInsert, ckSelectionChanged}),
    sp("enter-append", caLine0Mid,
       {ckModeChanged, ckModeInsert, ckSelectionChanged}),
    sp("enter-append-line-end", caLine1Mid,
       {ckModeChanged, ckModeInsert, ckSelectionChanged}),
    sp("enter-normal", caLine0Mid, {ckModeChanged}, {prInsertMode}),
    sp("enter-visual", caLine0Mid, {ckModeChanged}),
    sp("enter-visual-line", caLine0Mid, {ckModeChanged}),
    sp("enter-visual-block", caLine0Mid, {ckModeChanged}),
    sp("enter-replace", caLine0Mid, {ckModeChanged}),

    sp("begin-operator", caLine0Mid, {ckOperatorChanged, ckModeChanged},
       args = OpArgs(operator: "delete-selection")),
    sp("cancel-operator", caLine0Mid, {ckOperatorChanged, ckModeChanged},
       {prPending}),

    sp("push-count-digit", caLine0Mid, {ckCountChanged}, args = OpArgs(digit: 3)),

    sp("search-forward", caLine0Mid, {ckSearchChanged}, {prSearchBackward}),
    sp("search-backward", caLine0Mid, {ckSearchChanged}),
    sp("search-selection", spLine0Clusters, {ckSearchChanged}),
    sp("search-clear", caLine0Mid, {ckSearchChanged}, {prSearch}),

    sp("save", caLine0Mid, {ckIntent}),
    sp("save-as", caLine0Mid, {ckIntent}, args = OpArgs(text: "/tmp/x")),
    sp("save-all", caLine0Mid, {ckIntent}),
    sp("reload-from-disk", caLine0Mid, {ckIntent}),

    sp("fold", caLine1Mid, {ckFoldChanged}),
    sp("unfold", caLine1Mid, {ckFoldChanged}, {prFolded}),
    sp("fold-all", caLine1Mid, {ckFoldChanged}),
    sp("unfold-all", caLine1Mid, {ckFoldChanged}, {prFolded}),
    sp("toggle-fold", caLine1Mid, {ckFoldChanged}),

    sp("toggle-breakpoint", caLine1Mid, {ckMarkerChanged}),
    sp("toggle-tracepoint", caLine1Mid, {ckMarkerChanged}),
    sp("toggle-flow-overlay", caLine1Mid, {ckMarkerChanged}),
    sp("jump-to-value-origin", caLine1Mid, {ckIntent}),
  ]

let SpecTable = scenarioSpecs()

proc specFor*(decl: string): ScenarioSpec =
  for s in SpecTable:
    if s.decl == decl: return s
  raise newException(ValueError,
    "vocabulary_generator: no scenario for declaration '" & decl & "'. " &
    "Every one of the 140 published declarations must have one, and a " &
    "missing row would silently exclude three operations from the sweep.")

proc specNames*(): seq[string] =
  result = @[]
  for s in SpecTable: result.add s.decl

# ===========================================================================
# BUILDING A SCENARIO
# ===========================================================================

proc selectionFor*(d: ScenarioDoc; at: CaretAt): EditorSelection =
  ## `at` and not `caret`: `selection.caret` is the range constructor this body
  ## calls, and a parameter of that name shadows it.
  let m = d.marks
  case at
  of caLine0Mid: caretSelection(m.line0Mid)
  of caLine1Mid: caretSelection(m.line1Mid)
  of caLine1End: caretSelection(m.line1End)
  of caLine2Mid: caretSelection(m.line2Mid)
  of caLine3Mid: caretSelection(m.line3Mid)
  of caLine6Mid: caretSelection(m.line6Mid)
  of caDocStart: caretSelection(0)
  of caDocEnd: caretSelection(d.text.len)
  of caNearEnd: caretSelection(m.nearEnd)
  of caCamelStart: caretSelection(m.camelStart)
  of caCamelMid: caretSelection(m.camelMid)
  of caCamelEnd: caretSelection(m.camelEnd)
  of caParensInner: caretSelection(m.parensInner)
  of caBracketsInner: caretSelection(m.bracketsInner)
  of caBracesInner: caretSelection(m.bracesInner)
  of caAngleInner: caretSelection(m.angleInner)
  of caSingleInner: caretSelection(m.singleInner)
  of caDoubleInner: caretSelection(m.doubleInner)
  of caBackInner: caretSelection(m.backInner)
  of caTagInner: caretSelection(m.tagInner)
  of caDefOpenParen: caretSelection(m.defOpenParen)
  of caBeforeMatch: caretSelection(m.beforeMatch)
  of caAfterMatch: caretSelection(m.afterMatch)
  of caCommentedLine: caretSelection(m.commentedFrom)
  of caTrailingLine: caretSelection(m.trailingFrom)
  of caLine1Early: caretSelection(m.line1Early)
  of caDocCluster2: caretSelection(m.docCluster2)
  of caTransposeCaret: caretSelection(m.transposeCaret)
  of caDisplayCaret: caretSelection(m.displayCaret)
  of spLine0Clusters: singleSelection(m.spanFrom, m.spanTo)
  of spCamelWord: singleSelection(m.camelStart, m.camelEnd)
  of spLine2Indented: singleSelection(m.indentSpanFrom, m.indentSpanTo)
  of spLines0to2: singleSelection(m.multiFrom, m.multiTo)
  of spCommentedLine: singleSelection(m.commentedFrom, m.commentedTo)
  of spBlockComment: singleSelection(m.blockFrom, m.blockTo)
  of twoCarets: editorSelection(@[caret(m.line0Mid), caret(m.line2Mid)], 0)

proc scenarioFor*(d: ScenarioDoc; spec: ScenarioSpec): Scenario =
  ## The state the operation is run against. **Every field a prep writes is a
  ## field the operation reads**; a prep nothing reads would be a scenario
  ## claiming to have set something up.
  var st = initEditorState(d.text)
  st.selection = selectionFor(d, spec.caret)
  let m = d.marks
  if prFresh in spec.preps: st.parse = pfFresh
  if prMark in spec.preps: st.marks["a"] = m.markOffset
  if prSearch in spec.preps: st.search.pattern = m.needle
  if prJumps in spec.preps:
    st.jumps = @[m.jumpPrev, m.jumpMid, m.jumpNext]
    st.jumpIndex = 1
  if prRegister in spec.preps:
    st.setRegister("", Register(text: "PASTED", kind: rkCharwise))
  if prMacro in spec.preps: st.macros["m"] = @["insert-newline"]
  if prLastChange in spec.preps: st.lastChange = @["insert-newline"]
  # ==========================================================================
  # THE FOUR HISTORY PREPS ARE BUILT BY RUNNING THE HISTORY, NOT BY ASSIGNING
  # TO IT — PLAT-32
  # ==========================================================================
  # Until PLAT-32 these four lines pushed literal `Snapshot(doc: ...)` values
  # onto four flat stacks. There is nothing to assign now: an event holds an
  # INVERTED change set, so a hand-built event is a change set somebody wrote
  # by hand, and an event whose inversion does not meet the document is exactly
  # the state `history.pop` raises on. Each prep therefore drives a real
  # transaction through `record` — which is also the only way the prep can be
  # wrong in a way the suite notices.
  if prUndo in spec.preps:
    # The user deleted a trailing `UNDONE`; the document is what remained.
    let prev = d.text & "UNDONE"
    st.history = record(st.history,
      transaction(changeSet(prev.len, d.text.len, prev.len, ""),
                  some(caretSelection(0)), @[],
                  @[Annotation(kind: anUserEvent, userEvent: ueDelete)]),
      prev, caretSelection(0))
  if prRedo in spec.preps:
    # The user inserted `REDONE` and undid it, so `redo` puts it back. The
    # undone branch is reached the ONLY way it can be reached — by popping —
    # which is "redo is generated rather than stored" holding for the fixture
    # as well as for the product.
    let withText = d.text & "REDONE"
    var h = record(initHistory(),
      transaction(changeSet(d.text.len, d.text.len, d.text.len, "REDONE"),
                  some(caretSelection(0)), @[],
                  @[Annotation(kind: anUserEvent, userEvent: ueInput)]),
      d.text, caretSelection(0))
    let step = popUndo(h, withText, caretSelection(0))
    doAssert step.isSome, "the redo prep could not pop the event it just made"
    st.history = recordStep(step.get, withText)
  if prSelUndo in spec.preps:
    st.history = recordSelectionChange(st.history, caretSelection(0), 0)
  if prSelRedo in spec.preps:
    let h = recordSelectionChange(initHistory(), caretSelection(0), 0)
    let step = popUndoSelection(h, d.text, caretSelection(0))
    doAssert step.isSome, "the redo-selection prep could not pop its entry"
    st.history = recordStep(step.get, d.text)
  if prFolded in spec.preps: st.folded = @[1]
  if prPending in spec.preps:
    st.pendingOperator = "delete-selection"
    st.mode = emOperatorPending
  if prInsertMode in spec.preps: st.mode = emInsert
  if prSearchBackward in spec.preps: st.search.direction = sdBackward
  Scenario(doc: d, state: st, spec: spec, args: spec.args)

proc landmarkOf*(d: ScenarioDoc; k: LandmarkKind; st: EditorState): int =
  ## The offset an `ckAtLandmark` case compares against — read out of the
  ## SCENARIO's record of how the document was built, never recomputed by the
  ## algorithm the operation uses.
  case k
  of lkNone: -1
  of lkDocStart: 0
  of lkDocEnd: d.text.len
  of lkLine2Start: d.marks.line2Start
  of lkMark: d.marks.markOffset
  of lkJumpPrev: d.marks.jumpPrev
  of lkJumpNext: d.marks.jumpNext
  of lkDefCloseParen: d.marks.defCloseParen
  of lkLine1FirstNonBlank: d.marks.line1FirstNonBlank
  of lkBlankLineStart: d.marks.blankLineStart

# ===========================================================================
# `FUZZ-8` — the adversarial stream
# ===========================================================================

type FuzzRng* = object
  state: uint32

func initFuzzRng*(seed: uint32): FuzzRng =
  FuzzRng(state: if seed == 0: 0x9e3779b9'u32 else: seed)

func nextU32*(r: var FuzzRng): uint32 =
  ## The xorshift `change_generator` uses, re-spelled here rather than imported
  ## so this generator does not pull the change algebra's whole module in for
  ## six lines. Identical on C, JS and wasm: no `int` width is relied on.
  var x = r.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  r.state = x
  x

func rand*(r: var FuzzRng; hi: int): int =
  if hi <= 0: 0 else: int(r.nextU32() mod uint32(hi + 1))

func pick*[T](r: var FuzzRng; xs: openArray[T]): T =
  xs[r.rand(xs.len - 1)]

proc fuzzArgs*(r: var FuzzRng; arg: ArgKind; d: ScenarioDoc): OpArgs =
  ## **ADVERSARIAL, NOT UNIFORM** (§9). Every argument kind is drawn from a set
  ## that deliberately includes the values most likely to escape a bound: a
  ## line number of 0 and one past the end, an empty text, a mark that does not
  ## exist, a digit outside 0..9, an operator that is not in category C.
  case arg
  of akNone: OpArgs()
  of akNumber: OpArgs(number: r.pick([0, 1, 3, 17, 18, 9999, -4]))
  of akMarkId: OpArgs(id: r.pick(["a", "z", "", "«"]))
  of akText: OpArgs(text: r.pick(["", "Z", "\n", d.marks.needle, "\t  "]))
  of akChar: OpArgs(ch: r.pick(["", "Z", d.marks.needle]))
  of akCommand: OpArgs(command: r.pick(["", "sort", "rm -rf /"]))
  of akOperator: OpArgs(operator: r.pick(["", "delete-selection", "teleport"]))
  of akDigit: OpArgs(digit: r.pick([0, 3, 9, -1, 10, 99]))

proc fuzzSelection*(r: var FuzzRng; doc: string; boundaries: seq[int]):
    EditorSelection =
  ## A selection of 1 … 3 ranges on cluster boundaries. Cluster-aligned because
  ## the STORE refuses an offset inside a UTF-8 sequence (PLAT-24) and a fuzz
  ## stream that only ever measured that refusal would be a fuzz stream about
  ## the store.
  if boundaries.len < 2: return caretSelection(0)
  let k = 1 + r.rand(2)
  var ranges: seq[SelectionRange] = @[]
  for _ in 0 ..< k:
    let a = boundaries[r.rand(boundaries.len - 1)]
    let b = boundaries[r.rand(boundaries.len - 1)]
    ranges.add (if a == b: caret(a) else: spanRange(min(a, b), max(a, b)))
  editorSelection(ranges, 0)
