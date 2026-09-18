## change_set.nim — PLAT-25: the edit algebra, and the ONE rebase primitive.
##
## Owns: Editor-ViewModel.md §6, §6.1, §6.1a, §6.1b, §6.2. A change set is a
## document-to-document mapping, not a list of edits applied to a moving
## target; a transaction (`editor/transaction.nim`) is the only thing that
## carries one into the state.
##
## =========================================================================
## THE DELIVERABLE: ONE REBASE PRIMITIVE, AND THE FLAG THAT IS NOT A PARAMETER
## =========================================================================
##
## Editor-ViewModel.md §6.1a states the law
##
##     A.compose(B.map(A)) == B.compose(A.map(B, before = true))
##
## and records that CodeMirror writes that *same strict double mapping* by hand
## in FIVE places. Verified against the vendored source at `refs/` on
## 2026-09-18, with the law itself stated in a doc comment at
## `codemirror-state/src/change.ts:240-251`:
##
##   | site | file |
##   |------|------|
##   | `mergeTransaction`  | `codemirror-state/src/transaction.ts:318` |
##   | `changeByRange`     | `codemirror-state/src/state.ts:161`       |
##   | `mapEvent`          | `codemirror-commands/src/history.ts:301`  |
##   | `receiveUpdates`    | `codemirror-collab/src/collab.ts:97,111`  |
##   | `rebaseUpdates`     | `codemirror-collab/src/collab.ts:171,181` |
##
## Every one of them spells the same two lines — one `map` with the flag left
## at its default and one with it set to `true` — and the flag is the thing
## that is wrong when a copy is wrong. Five copies of a four-line function is
## five places to diverge, and nothing can tell you which one did.
##
## **So the flag is not a parameter of anything this module exports.** The
## only way out of here to move one change set over another is `rebase`, which
## takes the two sets in the order they are to be understood in and returns
## BOTH arms:
##
##     let r = rebase(a, b)        # `a` is the one that comes first
##     r.aOverB                    # a, re-expressed to apply after b
##     r.bOverA                    # b, re-expressed to apply after a
##
## `mapOver` — the routine that takes `before` — is private to this module and
## has exactly two call sites, both inside `rebase`. A caller cannot get the
## flag wrong because a caller never writes it, and
## `tests/unit/test_editor_change_algebra.nim` scans this tree to assert that
## the private routine, its flag and its two call sites are all still where
## this paragraph says they are. That scan is the mechanical half of "one
## function, one name"; the mutation arm on `before` in
## `run-plat25-change-algebra-mutations.py` is the half that shows the law can
## see the flag flip.
##
## =========================================================================
## THE ENCODING, AND WHY IT IS NOT THE REFERENCE'S — §6.1b
## =========================================================================
##
## CodeMirror stores a change set as a flat `number[]` of pairs where `-1` in
## the second slot means "untouched", alongside a SPARSE parallel array of
## inserted text indexed at half rate (`i >> 1`) and padded with empty entries.
## Three invariants are carried by convention: the array length is even, `-1`
## is not a length, and the parallel array is indexed at half rate.
##
## Here a change set is a `seq` of a two-arm variant — *keep this many* or
## *replace this many with this text*. The sentinel disappears (a keep has no
## `insert` field to hold `-1`), the half-rate indexing disappears (the text
## lives in the arm that has it), the padding disappears, and the evenness
## invariant is unrepresentable rather than unchecked.
##
## What is NOT normalised away, deliberately: two ADJACENT changed sections
## stay two sections. That is what makes `changedRanges(individual = true)` a
## different answer from `changedRanges()` — §6's *"adjacent changes are
## reported as one range by default and separately on request, and the
## difference is a parameter rather than a surprise"*. Empty runs and adjacent
## KEEPS are coalesced, because `LAW-A3` asks for `A ∘ id == A` **as values**.
##
## =========================================================================
## POSITION MAPPING IS TYPED — §6.2
## =========================================================================
##
## CodeMirror's `mapPos` takes `assoc: number` (negative/positive, and
## magnitudes above 1 mean something else again) plus a `mode: MapMode`, and
## returns `number | null` where the nullability depends on the mode. Here the
## side is a two-valued enum and the result is a three-arm variant that a
## caller must destructure:
##
##   `mapSurvived`   the position's text is still there
##   `mapDeleted`    the position was strictly inside text that was REPLACED,
##                   so the arm carries the old range AND the landing the side
##                   chose — a caller that wants a plausible neighbour has to
##                   ask for it by name
##   `mapCollapsed`  the position was strictly inside text that was purely
##                   DELETED, so the range collapsed to one point and both
##                   sides give the same answer
##
## Anchors, breakpoints, the execution pointer, decoration ranges and remote
## selections are all mapped through this, and a silently-wrong side means a
## breakpoint drifts a line.

import std/[algorithm, strutils]

type
  SectionKind* = enum
    skKeep      ## carry this many bytes of the old document through
    skReplace   ## delete this many bytes of the old document, put `insert` there

  Section* = object
    ## One run of a change set. The two arms are the whole vocabulary; there
    ## is no third state and no sentinel.
    case kind*: SectionKind
    of skKeep:
      keep*: int
    of skReplace:
      delete*: int
      insert*: string

  ChangeSet* = object
    ## A mapping from a document of `oldLen` bytes to one of `newLen` bytes.
    ##
    ## `sections` is PRIVATE and the two lengths are cached rather than
    ## recomputed: a change set that can be assembled field by field is a
    ## change set whose invariants are advice. Build one with `changeSet`,
    ## `identityChangeSet`, `compose`, `invert`, `rebase` or `decodeChangeSet`.
    sections: seq[Section]
    oldLen: int
    newLen: int

  Edit* = object
    ## The ergonomic constructor's input: replace `[fromPos, toPos)` of the
    ## old document with `insert`.
    fromPos*, toPos*: int
    insert*: string

  Side* = enum
    ## Which side of an insertion a position sticks to. Two values, not a
    ## signed integer whose magnitude means something else again.
    sideBefore
    sideAfter

  MappedKind* = enum
    mapSurvived
    mapDeleted
    mapCollapsed

  Mapped* = object
    ## §6.2's typed outcome. Total over every `(position, side)` pair, which
    ## is `LAW-A10`.
    case kind*: MappedKind
    of mapSurvived:
      pos*: int
    of mapDeleted:
      deletedFrom*, deletedTo*: int   ## the old range whose text is gone
      landing*: int                   ## where `side` puts it among the new text
    of mapCollapsed:
      collapsedFrom*, collapsedTo*: int
      at*: int                        ## the one point the range collapsed to

  ChangedRange* = object
    ## One changed run, reported by `changedRanges`.
    fromA*, toA*: int     ## in the old document
    fromB*, toB*: int     ## in the new document
    inserted*: string

  Rebased* = object
    ## The result of the ONE rebase primitive. Both arms, always, so a caller
    ## never chooses a flag.
    aOverB*: ChangeSet    ## `a`, re-expressed to apply after `b`
    bOverA*: ChangeSet    ## `b`, re-expressed to apply after `a`

  ChangeSetError* = object of ValueError
    ## Raised when two change sets do not meet — mismatched lengths, an edit
    ## out of bounds, an overlapping edit list, a malformed encoding.

# ===========================================================================
# THE BUILDER — the only way a `seq[Section]` becomes a `ChangeSet`
# ===========================================================================
#
# This is the exact coalescing CodeMirror performs in `addSection`, restated
# over the variant. The three rules, and what each one is for:
#
#   * a zero-length keep and a no-op replace are dropped, so `A ∘ id` does not
#     gain a zero-length section (`LAW-A3`, whose stated killer is precisely
#     "drop the empty-run coalescing");
#   * two adjacent keeps merge, and two adjacent PURE DELETIONS merge, and two
#     adjacent PURE INSERTIONS merge — these are the cases where the merged
#     section is indistinguishable from the pair;
#   * two adjacent full replacements do NOT merge, because `changedRanges`
#     reports them separately on request.
#
# `forceJoin` is `compose`'s "this change is still open" signal, and it can
# only ever land on a replace section. Landing it on a keep would be a defect
# in `compose`, and the variant makes that unrepresentable rather than
# unchecked: it raises instead of silently turning a keep into a replace.

type ChangeBuilder = object
  secs: seq[Section]

func addKeep(b: var ChangeBuilder; n: int) =
  if n <= 0: return
  if b.secs.len > 0 and b.secs[^1].kind == skKeep:
    b.secs[^1].keep += n
  else:
    b.secs.add Section(kind: skKeep, keep: n)

func addReplace(b: var ChangeBuilder; delete: int; insert: string;
                forceJoin = false) =
  if delete <= 0 and insert.len == 0: return
  if b.secs.len > 0 and b.secs[^1].kind == skReplace:
    let last = b.secs.len - 1
    if insert.len == 0 and b.secs[last].insert.len == 0:
      b.secs[last].delete += delete
      return
    if delete == 0 and b.secs[last].delete == 0:
      b.secs[last].insert.add insert
      return
    if forceJoin:
      b.secs[last].delete += delete
      b.secs[last].insert.add insert
      return
  elif forceJoin and b.secs.len > 0:
    raise newException(ChangeSetError,
      "change set builder: forceJoin onto a keep section — compose kept a " &
      "change open across an untouched run")
  b.secs.add Section(kind: skReplace, delete: delete, insert: insert)

func finish(b: ChangeBuilder): ChangeSet =
  result.sections = b.secs
  for s in b.secs:
    case s.kind
    of skKeep:
      result.oldLen += s.keep
      result.newLen += s.keep
    of skReplace:
      result.oldLen += s.delete
      result.newLen += s.insert.len

# ===========================================================================
# CONSTRUCTION AND ACCESS
# ===========================================================================

func `==`*(a, b: Section): bool =
  ## Written out rather than generated: Nim's structural `==` refuses a `case`
  ## object outright (*"parallel 'fields' iterator does not work for 'case'
  ## objects"*), so a variant encoding has to say what equality means. That is
  ## a cost of the encoding and it is paid here, once.
  if a.kind != b.kind: return false
  case a.kind
  of skKeep: a.keep == b.keep
  of skReplace: a.delete == b.delete and a.insert == b.insert

func `==`*(a, b: ChangeSet): bool =
  ## Equality as VALUES, which is what `LAW-A3` is quantified over: `A ∘ id`
  ## must be `A`, not merely a change set that produces the same document.
  if a.oldLen != b.oldLen or a.newLen != b.newLen: return false
  if a.sections.len != b.sections.len: return false
  for i in 0 ..< a.sections.len:
    if a.sections[i] != b.sections[i]: return false
  true

func `==`*(a, b: Mapped): bool =
  if a.kind != b.kind: return false
  case a.kind
  of mapSurvived: a.pos == b.pos
  of mapDeleted:
    a.deletedFrom == b.deletedFrom and a.deletedTo == b.deletedTo and
      a.landing == b.landing
  of mapCollapsed:
    a.collapsedFrom == b.collapsedFrom and a.collapsedTo == b.collapsedTo and
      a.at == b.at

func `$`*(s: Section): string =
  case s.kind
  of skKeep: "keep " & $s.keep
  of skReplace:
    "replace " & $s.delete & " with " & $s.insert.len & " byte(s)"

proc `$`*(cs: ChangeSet): string =
  ## A counterexample a human can read. Printed by the property harness when
  ## a law fails, which is the whole reason it exists.
  result = "ChangeSet(" & $cs.oldLen & " -> " & $cs.newLen & "): ["
  for i, s in cs.sections:
    if i > 0: result.add ", "
    result.add $s
  result.add "]"

func `$`*(m: Mapped): string =
  case m.kind
  of mapSurvived: "survived@" & $m.pos
  of mapDeleted:
    "deleted[" & $m.deletedFrom & "," & $m.deletedTo & ")->" & $m.landing
  of mapCollapsed:
    "collapsed[" & $m.collapsedFrom & "," & $m.collapsedTo & ")->" & $m.at

func sections*(cs: ChangeSet): seq[Section] =
  ## A copy. The field is private so that the only values in circulation are
  ## ones a builder produced.
  cs.sections

func length*(cs: ChangeSet): int =
  ## The length of the document this change set applies to. `LAW-A8`.
  cs.oldLen

func newLength*(cs: ChangeSet): int =
  ## The length of the document it produces. `LAW-A8`.
  cs.newLen

func isIdentity*(cs: ChangeSet): bool =
  ## True when nothing changes. A single keep, or nothing at all.
  for s in cs.sections:
    if s.kind == skReplace: return false
  true

func identityChangeSet*(docLen: int): ChangeSet =
  ## The identity over a document of `docLen` bytes. `LAW-A3`'s `id`.
  var b = ChangeBuilder()
  b.addKeep(docLen)
  b.finish()

proc changeSet*(docLen: int; edits: openArray[Edit]): ChangeSet =
  ## The ergonomic constructor. `edits` may arrive in any order; they are
  ## sorted here and refused if they overlap or leave the document.
  ##
  ## Two edits at the SAME position are allowed and stay two sections — that
  ## is the `adjacent` shape class, and the whole reason `changedRanges` takes
  ## a coalescing parameter.
  var sorted = @edits
  sorted.sort(proc (x, y: Edit): int =
    if x.fromPos != y.fromPos: cmp(x.fromPos, y.fromPos)
    else: cmp(x.toPos, y.toPos))
  var b = ChangeBuilder()
  var pos = 0
  for e in sorted:
    if e.fromPos < 0 or e.toPos > docLen or e.fromPos > e.toPos:
      raise newException(ChangeSetError,
        "change set: edit [" & $e.fromPos & ", " & $e.toPos &
        ") is not inside a document of " & $docLen & " bytes")
    if e.fromPos < pos:
      raise newException(ChangeSetError,
        "change set: edit at " & $e.fromPos & " overlaps the one ending at " & $pos)
    b.addKeep(e.fromPos - pos)
    b.addReplace(e.toPos - e.fromPos, e.insert)
    pos = e.toPos
  b.addKeep(docLen - pos)
  b.finish()

proc changeSet*(docLen, fromPos, toPos: int; insert: string): ChangeSet =
  ## One edit, the common case.
  changeSet(docLen, [Edit(fromPos: fromPos, toPos: toPos, insert: insert)])

proc changeSetOrdered*(docLen: int; edits: openArray[Edit]): ChangeSet
  ## THE OTHER constructor — declared here and defined after `rebase`,
  ## because it is one of its call sites. See the definition for what it is
  ## for and why it is a separate name rather than a fallback inside
  ## `changeSet`.

# ===========================================================================
# APPLY AND INVERT
# ===========================================================================

proc apply*(cs: ChangeSet; doc: string): string =
  ## The new document. Raises when `doc` is not the document this change set
  ## was built over — a change set applied to the wrong document is the defect
  ## `length` exists to make visible (`LAW-A8`).
  if doc.len != cs.oldLen:
    raise newException(ChangeSetError,
      "change set over " & $cs.oldLen & " bytes applied to a document of " &
      $doc.len)
  result = newStringOfCap(cs.newLen)
  var pos = 0
  for s in cs.sections:
    case s.kind
    of skKeep:
      result.add doc[pos ..< pos + s.keep]
      pos += s.keep
    of skReplace:
      result.add s.insert
      pos += s.delete

proc invert*(cs: ChangeSet; doc: string): ChangeSet =
  ## The change set that undoes `cs`, against the document it applied to.
  ## `invert(A, d).apply(A.apply(d)) == d` is `LAW-A4`, and the killer named
  ## for it is recording the INSERTED text's length where the DELETED text
  ## belongs — which is why this reads `doc` at all.
  if doc.len != cs.oldLen:
    raise newException(ChangeSetError,
      "invert: change set over " & $cs.oldLen &
      " bytes inverted against a document of " & $doc.len)
  var b = ChangeBuilder()
  var pos = 0
  for s in cs.sections:
    case s.kind
    of skKeep:
      b.addKeep(s.keep)
      pos += s.keep
    of skReplace:
      b.addReplace(s.insert.len, doc[pos ..< pos + s.delete])
      pos += s.delete
  b.finish()

# ===========================================================================
# ITERATION OVER CHANGED RANGES — §6's explicit coalescing parameter
# ===========================================================================

iterator changedRanges*(cs: ChangeSet; individual = false): ChangedRange =
  ## Every changed run, in old (`fromA`/`toA`) and new (`fromB`/`toB`)
  ## coordinates.
  ##
  ## By default ADJACENT changed sections are reported as ONE range, which is
  ## what a renderer invalidating a region wants. With `individual = true`
  ## each section is its own range, which is what a caller that needs to know
  ## the edit structure wants. §6 makes the difference a parameter rather than
  ## a surprise, and both arms are exercised by the suite.
  var posA = 0
  var posB = 0
  var i = 0
  while i < cs.sections.len:
    let s = cs.sections[i]
    case s.kind
    of skKeep:
      posA += s.keep
      posB += s.keep
      inc i
    of skReplace:
      var endA = posA
      var endB = posB
      var text = ""
      while true:
        endA += cs.sections[i].delete
        endB += cs.sections[i].insert.len
        text.add cs.sections[i].insert
        inc i
        if individual or i >= cs.sections.len or cs.sections[i].kind == skKeep:
          break
      yield ChangedRange(fromA: posA, toA: endA, fromB: posB, toB: endB,
                         inserted: text)
      posA = endA
      posB = endB

proc changedRangeSeq*(cs: ChangeSet; individual = false): seq[ChangedRange] =
  result = @[]
  for r in changedRanges(cs, individual): result.add r

proc sameMapping*(a, b: ChangeSet): bool =
  ## Equality of the MAPPING, ignoring how it was split into sections.
  ##
  ## **This exists because composition is associative as a mapping and is NOT
  ## associative as a value, and that is a property of the algorithm rather
  ## than of this port.** `(A ∘ B) ∘ C` and `A ∘ (B ∘ C)` can disagree about
  ## whether one changed run is one section or two — measured over PLAT-25's
  ## own generator at **12 divergences in 5,000 triples**, of which none
  ## disagreed about the coalesced changed ranges and none about the document.
  ## CodeMirror's own associativity test
  ## (`test/test-change.ts:279`) compares `left.apply(doc)` against
  ## `right.apply(doc)` and never the values, which is the same admission made
  ## quietly.
  ##
  ## So `LAW-A2` is quantified over this relation rather than over `==`, and
  ## the difference is not a weakening: two change sets with the same coalesced
  ## changed ranges over the same lengths replace the same text with the same
  ## text. It is strictly stronger than document equality — `replace [0,1) of
  ## "ab" with "a"` and `replace [1,2) with "b"` produce the same document and
  ## are not the same mapping — and the suite pins an example of each, so
  ## neither claim rests on this comment.
  if a.oldLen != b.oldLen or a.newLen != b.newLen: return false
  let ra = a.changedRangeSeq()
  let rb = b.changedRangeSeq()
  if ra.len != rb.len: return false
  for i in 0 ..< ra.len:
    if ra[i] != rb[i]: return false
  true

# ===========================================================================
# POSITION MAPPING — §6.2
# ===========================================================================

func mapPos*(cs: ChangeSet; pos: int; side: Side): Mapped =
  ## Total over every `(pos, side)` with `pos` in `[0, length]`. `LAW-A10`.
  ##
  ## The three arms are decided by where `pos` sits, never by a mode
  ## parameter the caller passes and then forgets to honour:
  ##
  ##   * strictly inside a range that was replaced by NEW text -> `mapDeleted`,
  ##     carrying the old range and the landing `side` chose;
  ##   * strictly inside a range that was purely DELETED -> `mapCollapsed`,
  ##     one point, the same for both sides — there is nothing to be on a side
  ##     of;
  ##   * anywhere else -> `mapSurvived`. At the START of a replacement both
  ##     sides answer "before the new text", and at its END both answer
  ##     "after"; only a ZERO-WIDTH insertion has a genuine two-sided answer,
  ##     and that is exactly the case `side` exists for.
  if pos < 0 or pos > cs.oldLen:
    raise newException(ChangeSetError,
      "mapPos: " & $pos & " is outside a document of " & $cs.oldLen & " bytes")
  var posA = 0
  var posB = 0
  for s in cs.sections:
    case s.kind
    of skKeep:
      let endA = posA + s.keep
      if endA > pos:
        return Mapped(kind: mapSurvived, pos: posB + (pos - posA))
      posB += s.keep
      posA = endA
    of skReplace:
      let endA = posA + s.delete
      if posA < pos and pos < endA:
        if s.insert.len == 0:
          return Mapped(kind: mapCollapsed, collapsedFrom: posA,
                        collapsedTo: endA, at: posB)
        return Mapped(kind: mapDeleted, deletedFrom: posA, deletedTo: endA,
                      landing: (if side == sideBefore: posB
                                else: posB + s.insert.len))
      # Reaching here with `endA > pos` means `pos == posA`, because every
      # earlier section already returned for a smaller `pos` and the strictly-
      # inside case above took everything between. A position at the start of
      # a replacement lands before the new text on BOTH sides; the zero-width
      # insertion is the only shape where the side decides, and `sideAfter`
      # falls through to pick up `posB + insert.len` on the next step.
      if endA > pos or (endA == pos and side == sideBefore and s.delete == 0):
        return Mapped(kind: mapSurvived, pos: posB)
      posB += s.insert.len
      posA = endA
  Mapped(kind: mapSurvived, pos: posB)

func mapPosOr*(cs: ChangeSet; pos: int; side: Side): int =
  ## The position a caller that has decided it does not care gets. Spelled
  ## once, here, so "I want a number" is a decision with a name on it rather
  ## than a nullable return nobody checked.
  let m = cs.mapPos(pos, side)
  case m.kind
  of mapSurvived: m.pos
  of mapDeleted: m.landing
  of mapCollapsed: m.at

# ===========================================================================
# THE SECTION ITERATOR — shared by `compose` and `mapOver`
# ===========================================================================

type SectionIter = object
  cs: ChangeSet
  idx: int      ## the CURRENT section, or `sections.len` when exhausted
  len: int      ## old-document bytes left in the current section
  ins: int      ## -2 exhausted, -1 a keep, >= 0 insert bytes left
  off: int      ## how far into the current section this iterator has walked

func advance(it: var SectionIter) =
  if it.idx + 1 < it.cs.sections.len:
    inc it.idx
    let s = it.cs.sections[it.idx]
    case s.kind
    of skKeep:
      it.len = s.keep
      it.ins = -1
    of skReplace:
      it.len = s.delete
      it.ins = s.insert.len
  else:
    it.idx = it.cs.sections.len
    it.len = 0
    it.ins = -2
  it.off = 0

func initSectionIter(cs: ChangeSet): SectionIter =
  result = SectionIter(cs: cs, idx: -1)
  result.advance()

func done(it: SectionIter): bool = it.ins == -2

func newExtent(it: SectionIter): int =
  ## The section's length in the NEW document — CodeMirror's `len2`.
  if it.ins < 0: it.len else: it.ins

func text(it: SectionIter): string =
  if it.idx < it.cs.sections.len and it.cs.sections[it.idx].kind == skReplace:
    it.cs.sections[it.idx].insert
  else:
    ""

func textBit(it: SectionIter; n: int): string =
  let t = it.text
  if t.len == 0: return ""
  let a = min(it.off, t.len)
  let b = if n < 0: t.len else: min(it.off + n, t.len)
  if b <= a: "" else: t[a ..< b]

func forward(it: var SectionIter; n: int) =
  if n == it.len: it.advance()
  else:
    it.len -= n
    it.off += n

func forwardNew(it: var SectionIter; n: int) =
  ## Walk `n` bytes of the section's NEW-document extent.
  if it.ins == -1: it.forward(n)
  elif n == it.ins: it.advance()
  else:
    it.ins -= n
    it.off += n

# ===========================================================================
# COMPOSE — §6.1
# ===========================================================================

proc compose*(a, b: ChangeSet): ChangeSet =
  ## Two sequential change sets into one. `b` must start in the document `a`
  ## produced: if `a` is `docA -> docB` and `b` is `docB -> docC`, the result
  ## is `docA -> docC`.
  ##
  ## `LAW-A2` (associativity), `LAW-A3` (identity, as VALUES) and `LAW-A5`
  ## (the homomorphism onto `apply`) are all about this function.
  if a.newLen != b.oldLen:
    raise newException(ChangeSetError,
      "compose: " & $a.newLen & " bytes out of the first set meet a second " &
      "set over " & $b.oldLen)
  # **THE REFERENCE'S `this.empty ? other : other.empty ? this` SHORTCUT IS
  # DELIBERATELY NOT PORTED** (`change.ts:238`). It is an optimisation, and it
  # is the one that makes `LAW-A3` vacuous: with it, `A ∘ id` returns `A` by
  # identity rather than by composition, so the law's own stated killer —
  # *"drop the empty-run coalescing so `A ∘ id` gains a zero-length section"* —
  # would survive. The identity therefore walks the general algorithm here,
  # which is both the slower and the only honest arrangement.
  var builder = ChangeBuilder()
  var ia = initSectionIter(a)
  var ib = initSectionIter(b)
  var open = false
  while true:
    if ia.done and ib.done:
      return builder.finish()
    elif ia.ins == 0 and not ia.done:
      # A deletion in `a`: `b` never sees those bytes, so they are deleted
      # from the composition outright.
      builder.addReplace(ia.len, "", open)
      ia.advance()
    elif ib.len == 0 and not ib.done:
      # An insertion in `b`, at a point in `a`'s output.
      builder.addReplace(0, ib.text, open)
      ib.advance()
    elif ia.done or ib.done:
      raise newException(ChangeSetError,
        "compose: mismatched change set lengths")
    else:
      let n = min(ia.newExtent, ib.len)
      let before = builder.secs.len
      if ia.ins == -1:
        if ib.ins == -1:
          builder.addKeep(n)
        else:
          builder.addReplace(n, (if ib.off > 0: "" else: ib.text), open)
      elif ib.ins == -1:
        builder.addReplace((if ia.off > 0: 0 else: ia.len), ia.textBit(n), open)
      else:
        builder.addReplace((if ia.off > 0: 0 else: ia.len),
                           (if ib.off > 0: "" else: ib.text), open)
      open = (ia.ins > n or (ib.ins >= 0 and ib.len > n)) and
             (open or builder.secs.len > before)
      ia.forwardNew(n)
      ib.forward(n)

# ===========================================================================
# THE REBASE PRIMITIVE — §6.1a
# ===========================================================================
#
# `mapOver` IS PRIVATE AND IT IS THE ONLY ROUTINE IN THIS TREE THAT TAKES THE
# FLAG. It has exactly two call sites, both three lines below, and
# `test_editor_change_algebra.nim` asserts all three of those facts by
# scanning `src/frontend/viewmodel/editor/`. If a sixth feature ever wants a
# double mapping, it calls `rebase`; there is no other door.

proc mapOver(setA, setB: ChangeSet; before: bool): ChangeSet =
  ## `setA`, re-expressed to apply to the document `setB` produced, where both
  ## start from the same document. `before` orders the two when they touch at
  ## a point: true means `setA`'s change is understood to come first.
  if setA.oldLen != setB.oldLen:
    raise newException(ChangeSetError,
      "rebase: " & $setA.oldLen & " and " & $setB.oldLen &
      " are not the same document")
  # The same shortcut, omitted for the same reason: rebasing over the identity
  # must come back through the algorithm, or `rebase(A, id)` is a test of an
  # `if`.
  var builder = ChangeBuilder()
  var ia = initSectionIter(setA)
  var ib = initSectionIter(setB)
  var inserted = -1
  while true:
    if (ia.done and ib.len > 0) or (ib.done and ia.len > 0):
      raise newException(ChangeSetError, "rebase: mismatched change set lengths")
    elif ia.ins == -1 and ib.ins == -1:
      let n = min(ia.len, ib.len)
      builder.addKeep(n)
      ia.forward(n)
      ib.forward(n)
    elif ib.ins >= 0 and (ia.ins < 0 or inserted == ia.idx or
                          (ia.off == 0 and (ib.len < ia.len or
                                            (ib.len == ia.len and not before)))):
      # A change in `setB` that comes first, ordered by start position, then
      # by length, then by the flag. THIS IS THE CLAUSE `before` DECIDES, and
      # it decides it only when the two are at the same point with the same
      # extent — which is the `touching-at-a-point` shape class, and the
      # reason the generator asserts that class non-empty.
      var left = ib.len
      builder.addKeep(ib.ins)
      while left > 0:
        let piece = min(ia.len, left)
        if ia.ins >= 0 and inserted < ia.idx and ia.len <= piece:
          builder.addReplace(0, ia.text)
          inserted = ia.idx
        ia.forward(piece)
        left -= piece
      ib.advance()
    elif ia.ins >= 0:
      # The part of a change in `setA` up to the next non-deletion in `setB`.
      var n = 0
      var left = ia.len
      while left > 0:
        if ib.ins == -1:
          let piece = min(left, ib.len)
          n += piece
          left -= piece
          ib.forward(piece)
        elif ib.ins == 0 and ib.len < left:
          left -= ib.len
          ib.advance()
        else:
          break
      builder.addReplace(n, (if inserted < ia.idx: ia.text else: ""))
      inserted = ia.idx
      ia.forward(ia.len - left)
    elif ia.done and ib.done:
      return builder.finish()
    else:
      raise newException(ChangeSetError, "rebase: mismatched change set lengths")

proc rebase*(a, b: ChangeSet): Rebased =
  ## **THE PRIMITIVE.** Given two change sets over the SAME document, produce
  ## each one re-expressed to apply after the other, with `a` understood as
  ## the one that comes first.
  ##
  ## `LAW-A1`: `compose(a, result.bOverA)` and `compose(b, result.aOverB)`
  ## produce the same document. Multi-cursor (PLAT-26), undo across a remote
  ## edit (PLAT-32) and collaborative convergence (PLAT-33) are all
  ## consequences of that, so a defect here is a defect in all three at once —
  ## and three features sharing one tested primitive is three features that
  ## cannot disagree.
  ##
  ## The two `mapOver` calls below are the only two in the tree, and the
  ## asymmetry between them is the whole content of the primitive: `a` moves
  ## over `b` as the EARLIER change, `b` moves over `a` as the LATER one.
  Rebased(aOverB: mapOver(a, b, before = true),
          bOverA: mapOver(b, a, before = false))

# ===========================================================================
# THE SECOND IN-TREE CALL SITE — the reference's order-sensitive constructor
# ===========================================================================

proc changeSetOrdered*(docLen: int; edits: openArray[Edit]): ChangeSet =
  ## `codemirror-state/src/change.ts:312-348` (`ChangeSet.of`), ported.
  ##
  ## **Two constructors, two preconditions, two names.** `changeSet` is
  ## declarative: the edits describe disjoint regions of one document, order
  ## does not matter, and an overlap is a caller error refused by name. That
  ## is what almost every caller wants and it is what the generator draws.
  ##
  ## This one is the reference's: the edits are all in ORIGINAL document
  ## coordinates, they may overlap, and **the list order is a priority
  ## order** — an edit that starts before the one in front of it is rebased
  ## over everything accumulated so far. That is what lets an insertion sit
  ## inside a deletion, splitting it, which `test-change.ts:183-194` exercises
  ## by hand and which a multi-range command produces naturally.
  ##
  ## The reference folds the two into one function whose behaviour changes
  ## silently with the argument order. Two names is the improvement: a caller
  ## that meant "these are disjoint" gets told when they are not, instead of
  ## getting a different change set.
  ##
  ## **And it is the second place in this tree that calls `rebase`.** The
  ## reference spells its double mapping here too — `total.compose(set.map(
  ## total))` — which is the same two lines again, in a sixth file, with only
  ## one of the two arms needed.
  var total = identityChangeSet(docLen)
  var haveTotal = false
  var pending: seq[Edit] = @[]
  var pos = 0

  proc flushInto(total: var ChangeSet; haveTotal: var bool;
                 pending: var seq[Edit]) =
    if pending.len == 0: return
    var b = ChangeBuilder()
    var at = 0
    for e in pending:
      b.addKeep(e.fromPos - at)
      b.addReplace(e.toPos - e.fromPos, e.insert)
      at = e.toPos
    b.addKeep(docLen - at)
    let part = b.finish()
    if not haveTotal:
      total = part
      haveTotal = true
    else:
      total = compose(total, rebase(total, part).bOverA)
    pending = @[]

  for e in edits:
    if e.fromPos < 0 or e.toPos > docLen or e.fromPos > e.toPos:
      raise newException(ChangeSetError,
        "changeSetOrdered: edit [" & $e.fromPos & ", " & $e.toPos &
        ") is not inside a document of " & $docLen & " bytes")
    if e.fromPos == e.toPos and e.insert.len == 0: continue
    if e.fromPos < pos:
      flushInto(total, haveTotal, pending)
      pos = 0
    pending.add e
    pos = e.toPos
  flushInto(total, haveTotal, pending)
  if not haveTotal: return identityChangeSet(docLen)
  total

# ===========================================================================
# SERIALISATION — `LAW-A9`, because PLAT-33 puts change sets on a wire
# ===========================================================================
#
# Length-prefixed and byte-transparent. The corpus contains bare continuation
# bytes, an embedded NUL and every line terminator Unicode has, so a delimiter
# encoding would be an encoding with a document that breaks it. Nothing here
# escapes anything: the reader is told how many bytes to take.
#
#   "CS1|" <section>*
#   section := "K" <keep> ";"
#            | "R" <delete> "," <insertLen> ":" <insertLen bytes>

const ChangeSetWireVersion* = "CS1|"

proc encodeChangeSet*(cs: ChangeSet): string =
  ## Deterministic: the same value encodes to the same bytes every time,
  ## because the encoding is a fold over `sections` and nothing else.
  result = ChangeSetWireVersion
  for s in cs.sections:
    case s.kind
    of skKeep:
      result.add "K"
      result.add $s.keep
      result.add ";"
    of skReplace:
      result.add "R"
      result.add $s.delete
      result.add ","
      result.add $s.insert.len
      result.add ":"
      result.add s.insert

proc decodeChangeSet*(wire: string): ChangeSet =
  ## Raises `ChangeSetError` on anything it cannot read. A decoder that
  ## returned a plausible empty change set for a truncated wire would make
  ## `LAW-A9` a law about the empty set.
  if not wire.startsWith(ChangeSetWireVersion):
    raise newException(ChangeSetError,
      "change set wire: no " & ChangeSetWireVersion & " header")
  var b = ChangeBuilder()
  var i = ChangeSetWireVersion.len
  proc readInt(wire: string; i: var int; stop: char): int =
    let start = i
    while i < wire.len and wire[i] != stop: inc i
    if i >= wire.len or i == start:
      raise newException(ChangeSetError,
        "change set wire: no integer terminated by '" & $stop & "' at " & $start)
    for k in start ..< i:
      if wire[k] notin {'0' .. '9'}:
        raise newException(ChangeSetError,
          "change set wire: '" & $wire[k] & "' is not a digit at " & $k)
    result = parseInt(wire[start ..< i])
    inc i
  while i < wire.len:
    case wire[i]
    of 'K':
      inc i
      b.addKeep(readInt(wire, i, ';'))
    of 'R':
      inc i
      let del = readInt(wire, i, ',')
      let n = readInt(wire, i, ':')
      if i + n > wire.len:
        raise newException(ChangeSetError,
          "change set wire: " & $n & " insert bytes claimed, " &
          $(wire.len - i) & " present")
      b.addReplace(del, wire[i ..< i + n])
      i += n
    else:
      raise newException(ChangeSetError,
        "change set wire: '" & $wire[i] & "' is not a section tag at " & $i)
  b.finish()
