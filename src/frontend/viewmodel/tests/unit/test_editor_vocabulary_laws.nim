## test_editor_vocabulary_laws.nim — PLAT-30's executable half: the 224
## operations driven against the corpus, display-dependence as a two-sided
## equality, and `FUZZ-8`.
##
## =========================================================================
## WHAT EACH OF THE THREE SWEEPS CAN CATCH THAT THE OTHERS CANNOT
## =========================================================================
##
##   1. **The operation sweep** — 224 cases, one per generated operation, each
##      run against all eighteen scenario documents. It catches an operation
##      that does nothing, an operation that does the WRONG thing (every case
##      carries a witness the scenario declared, not a "something changed"),
##      and a form that disagrees with its siblings.
##   2. **The display sweep** — 224 cases, the same operations at two wrap
##      columns, asking a DIFFERENT question: does the answer move when the
##      wrap column does? 24 must, 200 must not. One direction alone is
##      satisfied by declaring everything dependent.
##   3. **`FUZZ-8`** — 9 cases, one per corpus class, over random operation
##      sequences with adversarial arguments. It is the only check that grades
##      all 224 at once, and the only one that can see an operation that
##      raises on an input nobody wrote down.
##
## =========================================================================
## EVERY OPERATION IS DRIVEN DIRECTLY, AND THAT IS NOT A CONVENIENCE
## =========================================================================
##
## PLAT-30's own words: *"An operation a test can only reach through the keymap
## is an operation the collaboration and scripting layers cannot reach either —
## so this is not a testing convenience, it is the reachability property
## asserted by construction."* Nothing below synthesises a keystroke. There is
## one call, `operations.applyOperationAt`, reached by index and by name.
##
## =========================================================================
## THE WRAP-COLUMN PAIR IS MEASURED, NOT CHOSEN
## =========================================================================
##
## §2.3 says *"two different wrap columns"* and stops there, and which two is
## the whole of whether the positive half of the equality is a statement. Three
## pairs, re-measured over this population on 2026-09-19 by driving all 224
## operations at each pair with the `displayCaret` landmark RE-SEARCHED against
## the pair under test — which is what a suite committed to that pair would
## actually have been, since the landmark is declared in the generator:
##
##     | pair      | display-dependent operations that NEVER differ |
##     |-----------|-----------------------------------------------|
##     | 8 / 64    | 0                                              |
##     | 12 / 200  | 0                                              |
##     | 16 / 40   | 9                                              |
##
## At `16/40` the six `line-up` / `line-down` operations and the three
## `display-line-end` ones agree at both columns on all eighteen documents. A
## suite on that pair would have reported nine green cases that had asserted
## nothing about display-dependence at all: §34, in the PARAMETERS rather than
## in the documents. The committed pair is `8 / 64`, and what the measurement
## shows is that it is not vacuous — NOT that it is the only pair that is not.
##
## **THIS TABLE READ `12` AGAINST BOTH `12/200` AND `16/40` WHEN THIS FILE
## FIRST LANDED, AND THE FIGURE WAS NEVER TAKEN.** Its own attribution refuted
## it: it named *"the six `display-line-start` ones"*, and the 24
## display-dependent operations are 8 motions in 3 generated forms each, so one
## motion contributes three and 6 + 6 is not a number this population can
## produce. Nothing here asserts these figures — the COMMITTED pair's
## consequence is asserted (24 differ, 200 do not, both equalities, both green),
## which is exactly why a wrong number about the rejected pairs survived every
## gate this milestone built. Verification-Harness-Traps §36b is that finding.
## Holding the landmark fixed at the committed `8/64` search instead of
## re-searching it gives 3 at `12/200` and 9 at `16/40`; neither reading is 12.
##
## ## No mocks
##
## The corpus is bytes on disk, `staticRead` at compile time; the operations
## are the shipped ones; the wrap cache is `wrap.nim`'s. Nothing is
## substituted.
##
## ## Templates, not procs, for anything that calls `check`
## Verification-Harness-Traps §29: `unittest.check` inside a plain `proc` sets
## a GLOBAL, and the test then reports `[OK]` with the failed comparison
## printed above it. Every `check` below is in a `test` body or in a template.

import std/[algorithm, options, sequtils, strutils, tables, unicode, unittest]

import isonim_tui/text/width as widthMod

import ../generators/vocabulary_generator

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a static assertion count when a suite dies before printing.
const ExpectedAssertions = 8962
  ## **+144 ON 2026-09-19**, and they are one case: PLAT-31's §36a repair —
  ## the marks and the jump list mapped through the change set instead of
  ## clamped — had NO case that could see it removed. The arm re-aimed onto
  ## those two loops came back SURVIVED over 660 green cases, which is §36's
  ## *'the repair is to the ASSERTION, never to the killer'* found by a
  ## needle that moved rather than by a reviewer.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  WrapA = DisplayWrapA
  WrapB = DisplayWrapB
    ## The measured pair, read from the generator rather than re-spelled: the
    ## `displayCaret` landmark is SEARCHED against these two columns, and a
    ## suite that swept at a different pair would be asserting at a pair its
    ## own population was not built for. See the header.
  ViewportRows = 4
    ## `page-up` / `page-down`'s parameter. Small, so a page is smaller than
    ## the scenario documents and both directions have somewhere to go.

  ExpectedOperations = 226
  ExpectedDeclarations = 142
  ExpectedDisplayDependent = 24
  ExpectedDisplayIndependent = 202
  ExpectedScenarioDocs = 18
  ExpectedCorpusClasses = 9

  DisplayDependentNames = [
    ## **THE SECOND SWEEP'S POSITIVE CASES, ASSERTED BY NAME.** 200 of the 224
    ## are negative controls there — which is admissible, and is the same
    ## argument corpus class 9 and `LAW-C5`'s negative half rest on — but it
    ## means the positive cases are only these, and a list this short is one
    ## that has to be written down rather than counted.
    "move-line-up", "extend-line-up", "select-line-up",
    "move-line-down", "extend-line-down", "select-line-down",
    "move-display-line-up", "extend-display-line-up", "select-display-line-up",
    "move-display-line-down", "extend-display-line-down", "select-display-line-down",
    "move-page-up", "extend-page-up", "select-page-up",
    "move-page-down", "extend-page-down", "select-page-down",
    "move-display-line-start", "extend-display-line-start", "select-display-line-start",
    "move-display-line-end", "extend-display-line-end", "select-display-line-end",
  ]

  FuzzStepsPerClass = 240
  FuzzSeed = 0x30A7C0DE'u32

let
  docs = scenarioDocs()
  specs = scenarioSpecs()
  ops = operations()
  vocab = vocabulary()

# ===========================================================================
# MEASUREMENT HELPERS — none of them calls the code under test
# ===========================================================================

proc clusterCount(s: string): int =
  for _ in graphemeClusters(s): inc result

proc boundariesOf(s: string): seq[int] =
  clusterBoundariesOfText(s)

proc lineCountOf(s: string): int =
  s.count('\n') + 1

proc lineIndexOf(s: string; offset: int): int =
  for i in 0 ..< min(offset, s.len):
    if s[i] == '\n': inc result

proc lineStartOffset(s: string; line: int): int =
  var seen = 0
  if line == 0: return 0
  for i in 0 ..< s.len:
    if s[i] == '\n':
      inc seen
      if seen == line: return i + 1
  s.len

proc lineEndOffset(s: string; line: int): int =
  let a = lineStartOffset(s, line)
  var i = a
  while i < s.len and s[i] != '\n': inc i
  # Back to a cluster boundary — a CRLF line's `\n`-delimited end sits INSIDE
  # a cluster (PLAT-26's finding), and the model lands on the boundary.
  let bs = boundariesOf(s)
  var lo = a
  for b in bs:
    if b <= i: lo = b else: break
  lo

proc displayPosOf(doc: string; offset: int; col: int): DisplayPos =
  let settings = wrapSettings(col)
  let cache = initWrapCache(doc, settings)
  cache.toDisplay(toTextStore(doc).posOf(offset))

proc lastColumnAtRow(doc: string; row: int; col: int): int =
  let cache = initWrapCache(doc, wrapSettings(col))
  cache.lastColumnOf(row)

proc selectionBytes(sel: EditorSelection): int =
  for r in sel: result += r.byteLen

proc touchedLineCount(doc: string; sel: EditorSelection): int =
  var seen: seq[int] = @[]
  for r in sel:
    let a = lineIndexOf(doc, r.rangeFrom)
    let b = lineIndexOf(doc, max(r.rangeTo - 1, r.rangeFrom))
    for line in a .. b:
      if line notin seen: seen.add line
  seen.len

proc commentedLines(doc: string; sel: EditorSelection; token: string): int =
  var seen: seq[int] = @[]
  for r in sel:
    let a = lineIndexOf(doc, r.rangeFrom)
    let b = lineIndexOf(doc, max(r.rangeTo - 1, r.rangeFrom))
    for line in a .. b:
      if line notin seen: seen.add line
  for line in seen:
    let s = doc[lineStartOffset(doc, line) ..< lineEndOffset(doc, line)]
    if s.strip().startsWith(token): inc result

# ===========================================================================
# THE WITNESS — the scenario's declared expectations, checked
# ===========================================================================

proc witnessFailures(sc: Scenario; op: Operation; res: OpResult;
                     innerRes: Option[OpResult]): seq[string] =
  ## Every failure as a sentence. **No `check` in here** (§29); the caller
  ## asserts `result.len == 0` and prints the sentences as checkpoints.
  result = @[]
  let before = sc.state
  let after = res.state
  let bDoc = before.doc
  let aDoc = after.doc
  let oldHead = before.selection.mainRange.head
  let newHead = after.selection.mainRange.head
  let checks = sc.spec.checks
  template fail(msg: string) = result.add sc.doc.id & " / " & op.name & ": " & msg

  # --- the three FORMS, generated from one declaration ------------------
  if op.category == ocMotion:
    case op.form
    of ofMove:
      if not after.selection.mainRange.isEmpty:
        fail "the `move-` form must collapse each range to the new position"
    of ofExtend:
      if after.selection.mainRange.anchor != before.selection.mainRange.anchor:
        fail "the `extend-` form must keep the anchor: " &
          $before.selection.mainRange.anchor & " -> " &
          $after.selection.mainRange.anchor
    of ofSelect:
      if after.selection.mainRange.anchor != oldHead:
        fail "the `select-` form must span from the OLD position: anchor " &
          $after.selection.mainRange.anchor & " want " & $oldHead
    else: discard

  for c in checks:
    case c
    of ckMovedBack:
      if newHead >= oldHead: fail "head did not move back: " & $oldHead & " -> " & $newHead
    of ckMovedFwd:
      if newHead <= oldHead: fail "head did not move forward: " & $oldHead & " -> " & $newHead
    of ckOneCluster:
      let bs = boundariesOf(bDoc)
      let i = bs.find(oldHead)
      let j = bs.find(newHead)
      if i < 0 or j < 0 or abs(i - j) != 1:
        fail "not exactly one cluster step: boundary " & $i & " -> " & $j
    of ckOnClusterBoundary:
      if newHead notin boundariesOf(aDoc):
        fail "landed inside a grapheme cluster at " & $newHead
    of ckLineUp:
      if lineIndexOf(aDoc, newHead) != lineIndexOf(bDoc, oldHead) - 1:
        fail "logical line did not decrease by one"
    of ckLineDown:
      if lineIndexOf(aDoc, newHead) != lineIndexOf(bDoc, oldHead) + 1:
        fail "logical line did not increase by one"
    of ckRowUp:
      if displayPosOf(aDoc, newHead, WrapA).row >=
         displayPosOf(bDoc, oldHead, WrapA).row:
        fail "display row did not decrease"
    of ckRowDown:
      if displayPosOf(aDoc, newHead, WrapA).row <=
         displayPosOf(bDoc, oldHead, WrapA).row:
        fail "display row did not increase"
    of ckAtLineStart:
      if newHead != lineStartOffset(aDoc, lineIndexOf(aDoc, newHead)):
        fail "not at the line's first offset"
    of ckAtLineEnd:
      if newHead != lineEndOffset(aDoc, lineIndexOf(aDoc, newHead)):
        fail "not at the line's last offset"
    of ckAtLandmark:
      let want = landmarkOf(sc.doc, sc.spec.landmark, before)
      if newHead != want:
        fail "landed at " & $newHead & ", the scenario's landmark is " & $want
    of ckAtMatch:
      let n = sc.doc.marks.needle
      if newHead + n.len > aDoc.len or aDoc[newHead ..< newHead + n.len] != n:
        fail "the bytes at the landing are not the search pattern"
    of ckRowCol0:
      if displayPosOf(aDoc, newHead, WrapA).column != 0:
        fail "display column is not 0"
    of ckRowColEnd:
      let d = displayPosOf(aDoc, newHead, WrapA)
      if d.column != lastColumnAtRow(aDoc, d.row, WrapA):
        fail "display column is not the row's last"
    of ckSpanContainsCaret:
      let r = after.selection.mainRange
      if not (r.rangeFrom <= oldHead and oldHead <= r.rangeTo):
        fail "the object does not contain the caret it was taken at"
    of ckAroundContainsInner:
      if op.form == ofAround and innerRes.isSome:
        let a = after.selection.mainRange
        let i = innerRes.get.state.selection.mainRange
        if not (a.rangeFrom <= i.rangeFrom and a.rangeTo >= i.rangeTo and
                a.byteLen > i.byteLen):
          fail "`around` does not strictly contain `inner`: " & $a & " vs " & $i
    of ckDelimiters:
      if op.form == ofAround and sc.spec.delimiters.len == 2:
        let r = after.selection.mainRange
        if r.rangeFrom >= aDoc.len or r.rangeTo > aDoc.len or r.byteLen < 2 or
           aDoc[r.rangeFrom] != sc.spec.delimiters[0] or
           aDoc[r.rangeTo - 1] != sc.spec.delimiters[1]:
          fail "`around` is not delimited by '" & sc.spec.delimiters & "'"
    of ckDocChanged:
      if aDoc == bDoc: fail "the document did not change"
    of ckDocGrew:
      if aDoc.len <= bDoc.len: fail "the document did not grow"
    of ckDocShrank:
      if aDoc.len >= bDoc.len: fail "the document did not shrink"
    of ckDocMinusSelection:
      let want = bDoc.len - selectionBytes(before.selection)
      if aDoc.len != want:
        fail "document is " & $aDoc.len & " bytes, want " & $want
    of ckSelectionChanged:
      if after.selection == before.selection: fail "the selection did not change"
    of ckModeInsert:
      if after.mode != emInsert: fail "mode is " & $after.mode & ", want insert"
    of ckModeChanged:
      if after.mode == before.mode: fail "the mode did not change"
    of ckRegisterContent:
      if after.registerOf(after.activeRegister).text ==
         before.registerOf(before.activeRegister).text:
        fail "the active register's content did not change"
    of ckActiveRegister:
      if after.activeRegister == before.activeRegister:
        fail "the active register did not change"
    of ckUndoGrew:
      # PLAT-32: a DEPTH over the event branch, not a stack length. The two are
      # not the same number — `undoDepth` subtracts a leading selection-only
      # event, because one of those is not an undoable step — and reading the
      # raw `done.len` would count a selection record as an edit.
      if after.history.undoDepth <= before.history.undoDepth:
        fail "the undo branch did not grow"
    of ckRedoGrew:
      if after.history.redoDepth <= before.history.redoDepth:
        fail "the redo branch did not grow"
    of ckSearchChanged:
      if after.search == before.search: fail "the search state did not change"
    of ckFoldChanged:
      if after.folded == before.folded: fail "the fold set did not change"
    of ckMarkerChanged:
      if after.breakpoints == before.breakpoints and
         after.tracepoints == before.tracepoints and
         after.flowOverlay == before.flowOverlay:
        fail "no debugger marker changed"
    of ckIntent:
      if res.intents.len == 0: fail "no host intent was emitted"
    of ckCountChanged:
      if after.count == before.count: fail "the count did not change"
    of ckMacroChanged:
      if after.recording == before.recording and after.macros == before.macros:
        fail "neither the recording nor the macro table changed"
    of ckOperatorChanged:
      if after.pendingOperator == before.pendingOperator:
        fail "the pending operator did not change"
    of ckLineCountUp:
      if lineCountOf(aDoc) <= lineCountOf(bDoc): fail "the line count did not rise"
    of ckLineCountDown:
      if lineCountOf(aDoc) >= lineCountOf(bDoc): fail "the line count did not fall"
    of ckClusterMinusOne:
      if clusterCount(aDoc) != clusterCount(bDoc) - 1:
        fail "cluster count " & $clusterCount(bDoc) & " -> " &
          $clusterCount(aDoc) & ", want exactly one fewer"
    of ckBytesPermuted:
      # **NOT "the cluster count is unchanged", WHICH IS FALSE.** Transposing
      # two grapheme clusters can RE-SEGMENT: swapping a ZWJ family with the
      # cluster before it puts a joiner next to a different base, and the
      # count moves. Measured on `c1-zwj-short`. What IS invariant is the
      # BYTE MULTISET, and that is the witness — strictly stronger than "the
      # document changed" and true of a transposition and of nothing else the
      # vocabulary does.
      var b0 = toSeq(bDoc.items)
      var a0 = toSeq(aDoc.items)
      b0.sort()
      a0.sort()
      if b0 != a0:
        fail "the bytes are not a permutation of the originals"
    of ckRangeCountUp:
      if after.selection.rangeCount <= before.selection.rangeCount:
        fail "the cursor count did not rise"
    of ckRangeCountDown:
      if after.selection.rangeCount >= before.selection.rangeCount:
        fail "the cursor count did not fall"
    of ckPrimaryMoved:
      if after.selection.primaryIndex == before.selection.primaryIndex:
        fail "the primary index did not move"
    of ckUpperCased:
      let r = after.selection.mainRange
      let body = aDoc[r.rangeFrom ..< min(r.rangeTo, aDoc.len)]
      if body.len == 0 or body != unicode.toUpper(body):
        fail "the selected text is not upper case"
    of ckLowerCased:
      let r = after.selection.mainRange
      let body = aDoc[r.rangeFrom ..< min(r.rangeTo, aDoc.len)]
      if body.len == 0 or body != unicode.toLower(body):
        fail "the selected text is not lower case"
    of ckCommented:
      let n = touchedLineCount(bDoc, before.selection)
      if commentedLines(bDoc, before.selection, before.comments.lineToken) != 0:
        fail "the scenario's lines were already commented"
      elif commentedLines(aDoc, after.selection, after.comments.lineToken) != n:
        fail "not every touched line is commented"
    of ckUncommented:
      if commentedLines(bDoc, before.selection, before.comments.lineToken) == 0:
        fail "the scenario's lines were not commented to begin with"
      elif commentedLines(aDoc, after.selection, after.comments.lineToken) != 0:
        fail "a line is still commented"
    of ckIndented:
      let n = touchedLineCount(bDoc, before.selection)
      if aDoc.len != bDoc.len + n * before.indentUnit.len:
        fail "the document grew by " & $(aDoc.len - bDoc.len) & " bytes, want " &
          $(n * before.indentUnit.len)

proc runScenario(d: ScenarioDoc; op: Operation; col: int): (Scenario, OpResult) =
  let spec = specFor(vocab[op.decl].name)
  let sc = scenarioFor(d, spec)
  (sc, applyOperationAt(sc.state, operationNamed(op.name), sc.args,
                        wrapSettings(col), ViewportRows))

# ===========================================================================

suite "PLAT-30: the population is declared, and every part of it is asserted":

  test "eighteen scenario documents, one per corpus document, each with an admissible run":
    ck docs.len == ExpectedScenarioDocs
    ck docs.len == CorpusDocs.len
    var classes: seq[int] = @[]
    for d in docs:
      checkpoint(d.id & ": run " & $d.runLen & " clusters, " & $d.text.len & " bytes")
      ck d.runLen >= RunFloor
      ck d.text.len > 0
      # The frame's seventeen lines, so a scenario that lost one is red here
      # rather than silently placing a landmark on the wrong line.
      ck lineCountOf(d.text) == 18
      ck d.cls >= 1 and d.cls <= ExpectedCorpusClasses
      # The two SEARCHED landmarks. A document with none would make its
      # `transpose-chars` or `display-line-start` cell green on an input that
      # cannot exercise it.
      ck d.marks.transposeCaret > 0
      ck d.marks.displayCaret > 0
      if d.cls notin classes: classes.add d.cls
    ck classes.len == ExpectedCorpusClasses

  test "the scenario table is one row per declaration, in the vocabulary's order":
    ck specs.len == ExpectedDeclarations
    ck vocab.len == ExpectedDeclarations
    var mismatched: seq[string] = @[]
    for i in 0 ..< min(specs.len, vocab.len):
      if specs[i].decl != vocab[i].name:
        mismatched.add $i & ": spec '" & specs[i].decl & "' vs vocabulary '" &
          vocab[i].name & "'"
    for m in mismatched: checkpoint(m)
    ck mismatched.len == 0
    # …and every row carries at least one witness. A row with an empty check
    # set would be an operation swept and graded on nothing.
    var witnessless: seq[string] = @[]
    for s in specs:
      if s.checks.card == 0: witnessless.add s.decl
    for w in witnessless: checkpoint("no witness: " & w)
    ck witnessless.len == 0

  test "the vocabulary's own cardinalities, asserted before anything is swept":
    ck ops.len == ExpectedOperations
    ck displayDependentCount() == ExpectedDisplayDependent
    ck ops.len - displayDependentCount() == ExpectedDisplayIndependent
    ck duplicateDeclarationNames().len == 0
    ck duplicateOperationNames().len == 0
    ck unimplementedDeclarations().len == 0
    ck DisplayDependentNames.len == ExpectedDisplayDependent
    # The names list and the declared property agree, both ways.
    var declared: seq[string] = @[]
    for op in ops:
      if op.displayDependent: declared.add op.name
    for n in DisplayDependentNames:
      ck n in declared
    for n in declared:
      ck n in DisplayDependentNames

# ===========================================================================
# SWEEP 1 — 224 cases, one per operation, over the corpus
# ===========================================================================

var actedTotal = 0
var noOpTotal = 0
var refusedTotal = 0
var docsUsed = initTable[string, int]()

suite "PLAT-30: every operation, driven directly against corpus documents":
  for op in ops:
    test "operation: " & op.name:
      for d in docs:
        let (sc, res) = runScenario(d, op, WrapA)
        docsUsed[d.id] = docsUsed.getOrDefault(d.id) + 1
        case res.outcome
        of ooActed: inc actedTotal
        of ooNoOp: inc noOpTotal
        of ooRefused: inc refusedTotal
        if res.outcome != ooActed:
          checkpoint(d.id & " / " & op.name & ": " & $res.outcome & " " & $res.refusal)
        # §34: the INPUT made it act. An operation that no-ops on the
        # scenario built for it is a case that executed nothing.
        ck res.outcome == ooActed
        var inner = none(OpResult)
        if op.form == ofAround:
          let innerName = "select-inner-" & vocab[op.decl].name
          let (_, ir) = runScenario(d, ops[operationNamed(innerName)], WrapA)
          inner = some(ir)
        let fails = witnessFailures(sc, op, res, inner)
        for f in fails: checkpoint(f)
        ck fails.len == 0

# ===========================================================================
# SWEEP 2 — 224 cases, the SAME operations, a DIFFERENT question
# ===========================================================================

var positiveDiffering = 0
var negativeIdentical = 0

suite "PLAT-30: display-dependence is a two-sided equality at two wrap columns":
  for op in ops:
    test "display: " & op.name:
      var differingDocs: seq[string] = @[]
      for d in docs:
        let (_, ra) = runScenario(d, op, WrapA)
        let (_, rb) = runScenario(d, op, WrapB)
        if not (ra.state == rb.state):
          differingDocs.add d.id
      if op.displayDependent:
        checkpoint(op.name & " differs on " & $differingDocs.len & "/" &
                   $docs.len & " documents")
        # THE POSITIVE HALF: at least one input on which the wrap column
        # decides the answer.
        ck differingDocs.len > 0
        if differingDocs.len > 0: inc positiveDiffering
      else:
        if differingDocs.len > 0:
          checkpoint(op.name & " is declared display-INDEPENDENT and differs on: " &
                     differingDocs.join(", "))
        # THE NEGATIVE HALF. 200 of the 224 land here, and they are
        # falsifiable: `env.settings` is in scope for every handler
        # (`operations.nim`'s header says why the alternative was rejected),
        # so a logical motion that consulted the wrap column reddens this.
        ck differingDocs.len == 0
        if differingDocs.len == 0: inc negativeIdentical

# ===========================================================================
# FUZZ-8 — every operation is total
# ===========================================================================

suite "PLAT-30: FUZZ-8 — every operation is total, over the corpus classes":
  for cls in 1 .. ExpectedCorpusClasses:
    test "FUZZ-8 x corpus class " & $cls:
      var r = initFuzzRng(FuzzSeed xor uint32(cls * 7919))
      var classDocs: seq[ScenarioDoc] = @[]
      for d in docs:
        if d.cls == cls: classDocs.add d
      ck classDocs.len == 2      # §5: two documents per class, short and long
      var st = initEditorState(classDocs[0].text)
      var escapes: seq[string] = @[]
      var acted, noop, refusedN, steps = 0
      var badRefusal = 0
      var badSelection = 0
      for step in 0 ..< FuzzStepsPerClass:
        let d = classDocs[step mod classDocs.len]
        if step mod 40 == 0:
          st = initEditorState(d.text)
          if step mod 80 == 0: st.parse = pfFresh
          st.search.pattern = d.marks.needle
          st.marks["a"] = d.marks.markOffset
          st.macros["m"] = @["insert-newline"]
        st.selection = fuzzSelection(r, st.doc, boundariesOf(st.doc))
        let idx = r.rand(ops.len - 1)
        let op = ops[idx]
        let args = fuzzArgs(r, op.arg, d)
        inc steps
        try:
          let res = applyOperationAt(st, idx, args, wrapSettings(WrapA), ViewportRows)
          case res.outcome
          of ooActed: inc acted
          of ooNoOp: inc noop
          of ooRefused: inc refusedN
          # A refusal is a TYPED VALUE and the two arms are disjoint: an
          # `ooRefused` with no reason and an `ooActed` with one are both
          # states in which "a refusal is typed" has stopped meaning anything.
          if res.outcome == ooRefused and res.refusal == rrNone: inc badRefusal
          if res.outcome != ooRefused and res.refusal != rrNone: inc badRefusal
          if not res.state.selection.isNormalised: inc badSelection
          for rr in res.state.selection:
            if rr.rangeFrom < 0 or rr.rangeTo > res.state.doc.len:
              inc badSelection
          st = res.state
        except CatchableError as e:
          escapes.add op.name & ": " & $e.name & " " & e.msg
        except Defect as e:
          escapes.add op.name & ": DEFECT " & $e.name & " " & e.msg
      for e in escapes[0 ..< min(escapes.len, 8)]: checkpoint(e)
      checkpoint("class " & $cls & ": steps " & $steps & " acted " & $acted &
                 " no-op " & $noop & " refused " & $refusedN)
      ck escapes.len == 0
      ck steps == FuzzStepsPerClass
      ck badRefusal == 0
      ck badSelection == 0
      # **EACH ARM'S REALISED COUNT, SEPARATELY** (§34): a stream in which
      # nothing was ever refused satisfies "a refusal is a typed value" and
      # measures nothing, and so does one in which nothing ever acted.
      ck acted > 0
      ck refusedN > 0

# ===========================================================================
# THE GATES
# ===========================================================================

suite "PLAT-30: the sweeps' own counts, asserted as equalities":

  test "the operation sweep ACTED on every operation of every document":
    let cells = ExpectedOperations * ExpectedScenarioDocs
    checkpoint("acted " & $actedTotal & " / no-op " & $noOpTotal &
               " / refused " & $refusedTotal & " of " & $cells)
    # §34's second rule: EQUALITIES, not floors. A population in which most
    # operations no-op passes every "at least one acted" check ever written.
    ck actedTotal == cells
    ck noOpTotal == 0
    ck refusedTotal == 0
    ck actedTotal + noOpTotal + refusedTotal == cells

  test "every scenario document was used, the same number of times":
    ck docsUsed.len == ExpectedScenarioDocs
    for d in docs:
      ck docsUsed.getOrDefault(d.id) == ExpectedOperations

  test "the display sweep's two halves are 24 and 200, and the 24 are by name":
    checkpoint("display-dependent and differing: " & $positiveDiffering)
    checkpoint("display-independent and identical: " & $negativeIdentical)
    ck positiveDiffering == ExpectedDisplayDependent
    ck negativeIdentical == ExpectedDisplayIndependent
    ck positiveDiffering + negativeIdentical == ExpectedOperations

  test "the refusal arm exists and is reached, two-sidedly":
    # The main sweep asserts nothing refuses. That is only meaningful if a
    # refusal is REACHABLE — otherwise `acted == 4032` is a statement about a
    # model with no refusals in it at all. Fourteen operations need a parse;
    # with `pfStale` they refuse by name, and with `pfFresh` they do not.
    let parseHungry = ["move-syntax-left", "extend-syntax-left", "select-syntax-left",
                       "move-syntax-right", "extend-syntax-right", "select-syntax-right",
                       "select-inner-syntax-node", "select-around-syntax-node",
                       "select-inner-function", "select-around-function",
                       "select-inner-argument", "select-around-argument",
                       "select-parent-syntax", "reindent-selection"]
    ck parseHungry.len == 14
    let d = docs[0]
    for name in parseHungry:
      let op = ops[operationNamed(name)]
      let spec = specFor(vocab[op.decl].name)
      var sc = scenarioFor(d, spec)
      var stale = sc.state
      stale.parse = pfStale
      let refusedRes = applyOperationAt(stale, operationNamed(name), sc.args,
                                        wrapSettings(WrapA), ViewportRows)
      checkpoint(name & " on a stale parse: " & $refusedRes.outcome & " " &
                 $refusedRes.refusal)
      ck refusedRes.outcome == ooRefused
      ck refusedRes.refusal == rrStaleParse
      ck refusedRes.state == stale          # a refusal moves nothing
      let freshRes = applyOperationAt(sc.state, operationNamed(name), sc.args,
                                      wrapSettings(WrapA), ViewportRows)
      ck freshRes.outcome == ooActed

  test "an unknown name RAISES and an unknown index RAISES, by name":
    var raised = 0
    let st = initEditorState("abc")
    try:
      discard applyOperation(st, "delete-word-forward", OpArgs(), wrapSettings(WrapA))
    except OperationError as e:
      inc raised
      checkpoint(e.msg)
      ck "delete-word-forward" in e.msg
      ck $ExpectedOperations in e.msg
    try:
      discard applyOperationAt(st, ExpectedOperations, OpArgs(), wrapSettings(WrapA))
    except OperationError:
      inc raised
    ck raised == 2
    # …and `delete-word-forward` is the FUSED name §2.1 says the vocabulary
    # must not contain. Its absence is the shape of the vocabulary, asserted.
    ck operationNamed("delete-word-forward") < 0
    ck operationNamed("change-inner-paren") < 0
    ck operationNamed("move-char-left") >= 0
    ck operationNamed("delete-selection") >= 0

  test "a motion PRODUCES a selection an operator CONSUMES, and that is the order-free pair":
    # §2.1, executable: `dw` and `wd` are the same two operations in a
    # different order. The Kakoune order is select-then-delete; the Vim order
    # is begin-operator, then the same motion, then the operator. The
    # DOCUMENTS must agree, and neither path names an operation the other
    # cannot reach.
    let d = docs[0]
    var st = initEditorState(d.text)
    st.selection = caretSelection(d.marks.camelStart)
    let settings = wrapSettings(WrapA)
    let kakSel = applyOperation(st, "select-group-right", OpArgs(), settings)
    ck kakSel.outcome == ooActed
    let kakDel = applyOperation(kakSel.state, "delete-selection", OpArgs(), settings)
    ck kakDel.outcome == ooActed
    let vimBegin = applyOperation(st, "begin-operator",
                                  OpArgs(operator: "delete-selection"), settings)
    ck vimBegin.outcome == ooActed
    ck vimBegin.state.pendingOperator == "delete-selection"
    let vimSel = applyOperation(vimBegin.state, "select-group-right", OpArgs(), settings)
    let vimDel = applyOperation(vimSel.state, "delete-selection", OpArgs(), settings)
    checkpoint("kakoune -> " & $kakDel.state.doc.len & " bytes; vim -> " &
               $vimDel.state.doc.len)
    ck vimDel.state.doc == kakDel.state.doc
    ck vimDel.state.doc.len < st.doc.len
    # The pending operator names an entry of CATEGORY C, checked rather than
    # assumed: a keymap that spelled it wrong would otherwise leave a pending
    # state nothing can discharge.
    var inCategoryC = false
    for decl in vocab:
      if decl.category == ocOperator and decl.name == vimBegin.state.pendingOperator:
        inCategoryC = true
    ck inCategoryC

  test "group motions cross MORE than one cluster, which is what makes them not char motions":
    # The sweep's witness for a group motion is "moved, and landed on a
    # cluster boundary", which a char motion also satisfies. §36: a witness
    # too weak to see a swapped implementation is a witness that reads as
    # coverage. This case is the sharp form, on a document whose group
    # structure is known because the scenario built it.
    let settings = wrapSettings(WrapA)
    for d in docs:
      var st = initEditorState(d.text)
      st.selection = caretSelection(d.marks.camelStart)
      let charRes = applyOperation(st, "move-char-right", OpArgs(), settings)
      let groupRes = applyOperation(st, "move-group-right", OpArgs(), settings)
      let subRes = applyOperation(st, "move-subword-forward", OpArgs(), settings)
      let c = charRes.state.selection.mainRange.head
      let g = groupRes.state.selection.mainRange.head
      let s = subRes.state.selection.mainRange.head
      checkpoint(d.id & ": char " & $c & " subword " & $s & " group " & $g)
      # `fooBarBaz_qux` is one group and three subwords, so the three answers
      # are strictly ordered — which no pair of them being swapped survives.
      ck c < s
      ck s < g
      ck g == d.marks.camelEnd

  test "the vertical pair carries its goal column and a short line does not eat it":
    # `line-up` / `line-down` are display-dependent BECAUSE the column they
    # preserve is a display column (`operations.verticalLogical`). The goal
    # surviving a short line is what makes that a goal rather than a landing.
    let settings = wrapSettings(WrapB)
    for d in docs:
      var st = initEditorState(d.text)
      st.selection = caretSelection(d.marks.line3Mid)
      let up1 = applyOperation(st, "move-line-up", OpArgs(), settings)
      ck up1.state.selection.mainRange.goalColumn.isSome
      let goal = up1.state.selection.mainRange.goalColumn.get
      let up2 = applyOperation(up1.state, "move-line-up", OpArgs(), settings)
      ck up2.state.selection.mainRange.goalColumn == some(goal)
      let down1 = applyOperation(up2.state, "move-line-down", OpArgs(), settings)
      let down2 = applyOperation(down1.state, "move-line-down", OpArgs(), settings)
      ck down2.state.selection.mainRange.goalColumn == some(goal)
      ck down2.state.selection.mainRange.head == d.marks.line3Mid

  test "A MARK AND THE JUMP LIST MOVE WITH THE DOCUMENT, through the same change set":
    # **PLAT-31's §36a REPAIR, ASSERTED — AND IT WAS NOT, UNTIL 2026-09-19.**
    # That milestone replaced a `clamp(..., 0, doc.len)` on `marks` and `jumps`
    # with a real mapping through `change_set.mapPosOr`, and recorded the
    # repair in `commitChange`'s header. Nothing executed it: the arm that was
    # re-aimed onto those two loops came back SURVIVED, over 660 green cases.
    #
    # Neither 224-case sweep can see it — both run ONE operation against a
    # fresh state — so what this needs is an edit BETWEEN a mark being set and
    # it being jumped to. That is the same shape `FUZZ-8` found the selection
    # history's version of, one field over.
    let settings = wrapSettings(WrapA)
    for d in docs:
      checkpoint(d.id)
      var st = initEditorState(d.text)
      # A mark on the third line, and a jump list pointing at it.
      st.selection = caretSelection(d.marks.line3Mid)
      # The mark is SET ON THE STATE and not through an operation, because the
      # published vocabulary has `mark(id)` as a MOTION and no operation that
      # records one — whoever opened the document supplies it, exactly as
      # `vocabulary_generator`'s `prMark` prep does.
      var after = st
      after.marks["a"] = d.marks.line3Mid
      after.jumps = @[d.marks.line3Mid]
      after.jumpIndex = 0
      ck after.hasMark("a")
      let markedAt = after.marks["a"]
      # The text the mark names, so the assertion is about TEXT and not about
      # an offset that happens to be plausible.
      let named = after.doc[markedAt ..< min(markedAt + 4, after.doc.len)]
      ck named.len > 0
      # Somebody edits BEFORE it.
      after.selection = caretSelection(0)
      let edited = applyOperation(after, "insert-text", OpArgs(text: "XYZ"),
                                  settings, ViewportRows).state
      ck edited.doc.len == after.doc.len + 3
      # The mark still names the same text — which a clamp cannot do and an
      # unmapped offset cannot do either.
      let moved = edited.marks["a"]
      ck moved == markedAt + 3
      ck edited.doc[moved ..< min(moved + named.len, edited.doc.len)] == named
      ck edited.jumps[0] == markedAt + 3
      # …and the MOTION lands there, through the published operation rather
      # than by reading the field.
      let jumped = applyOperation(edited, "move-mark", OpArgs(id: "a"), settings,
                                  ViewportRows)
      ck jumped.outcome == ooActed
      ck jumped.state.selection.mainRange.head == moved

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
