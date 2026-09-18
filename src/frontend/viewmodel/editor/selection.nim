## selection.nim — PLAT-26: selections are the primitive.
##
## Owns: Editor-ViewModel.md §7. Everything above this module — motions,
## operators, multi-cursor editing — is written against `EditorSelection` and
## never against a "cursor", because there is no cursor type to write against.
##
## =========================================================================
## THE DESIGN, IN ONE PARAGRAPH: A MOTION PRODUCES A SELECTION, AN OPERATOR
## CONSUMES ONE
## =========================================================================
##
## This is Kakoune's model and it is the reason `dw` and `wd` are the same two
## named operations in a different order rather than two different features.
## A *fused* vocabulary — `delete-word-forward` — is the cross product of the
## motion set and the operator set, it grows quadratically, and it cannot
## express Kakoune at all. So the vocabulary here is two sets and one
## composition rule, and the composition rule needs exactly one thing from the
## type system: **a motion's result and an operator's argument must be the same
## type.** That type is `EditorSelection`.
##
## **Multi-cursor falls out of that rather than being bolted onto it.** Every
## operation in `selection_ops.nim` is a function of ONE `SelectionRange`, and
## `changeByRange` runs it over the whole set; one caret is a set of one. There
## is no branch anywhere in this module or the next that asks how many ranges
## there are, and `LAW-S3` is the executable form of that claim — for every
## operation, at K ∈ {1, 2, 3, 7}. If multi-cursor needed a special case, the
## primitive would be wrong, and the K > 1 rows are what say it is not.
##
## =========================================================================
## A RANGE IS A VARIANT OVER EMPTINESS, NOT A BITFIELD
## =========================================================================
##
## CodeMirror packs association, bidi level, invertedness and a goal column
## into one integer (`codemirror-state/src/selection.ts`), with `7` meaning
## "no bidi level" and `0xffffff` meaning "no goal column". Two of those four
## fields are meaningful only for an EMPTY range (there is nothing to be
## inside of, so association and bidi level decide where a caret sits between
## two runs); a third is meaningful only for a NON-EMPTY one (a caret has no
## direction to be inverted about).
##
## Here the emptiness is the discriminator, so each field is reachable exactly
## where it means something and unrepresentable where it does not. The two
## sentinels disappear with it: `goalColumn` and `bidiLevel` are `Option`s,
## because "no goal column" is an absence and not a very large number.
##
## =========================================================================
## NORMALISATION MERGES RANGES THAT TOUCH, AND THAT DIVERGES FROM THE
## REFERENCE DELIBERATELY
## =========================================================================
##
## CodeMirror's `normalized` merges an EMPTY range into its predecessor when
## `range.from <= prev.to` and a NON-EMPTY one only when `range.from <
## prev.to`. So `[0,3)` and `[3,6)` survive as two ranges there.
##
## Here both merge, and the invariant is strict separation — `ranges[i].from >
## ranges[i-1].to`. The reason is not taste, it is that
## Editor-Model-Conformance-Suite.md §3.2 names the killing mutation for
## `LAW-S1` as *"drop the merge step for touching ranges"*, and under the
## reference's rule that mutation is not observable: with half-open intervals
## `[0,3)` and `[3,6)` do not overlap, so an invariant that only forbids
## OVERLAP is satisfied by the mutated output and the law cannot go red. **A
## law whose published killer cannot kill it is a law nobody has watched
## fail.** Strict separation is the weakest invariant under which §3.2's own
## arm lands, so it is the one taken, and `LAW-S1`'s arm in
## `run-plat26-selection-mutations.py` is the evidence that it lands.
##
## **THE USER-VISIBLE COST IS REAL, AND THE FIRST VERSION OF THIS PARAGRAPH
## UNDERSTATED IT.** Two adjacent non-empty selections with no gap become one.
## They render as one contiguous highlight either way, and the ten motions and
## `delete` produce the same document either way — but an INSERT does not.
## Over `"abcdefghij"`, inserting `"X"` across `[0,3)` and `[3,6)` as two
## ranges gives `"XXghij"`; across the merged `[0,6)` it gives `"Xghij"`. One
## insertion instead of two, which is the behaviour multi-cursor exists for.
##
## It is reachable from the twelve primitives, not only from a constructor:
## from `[0,2)` and `[4,6)`, two `extend-right` steps give `[0,4)` and
## `[4,8)`, which abut and merge here. A user who extends two selections into
## contact loses a cursor. That is taken at THIS milestone because the
## alternative available here was a published killer that cannot kill; PLAT-30
## is to revisit it against the other option — keep the reference's merge rule
## and strengthen `LAW-S1`'s invariant in §3.2's WORDING instead.
##
## =========================================================================
## POSITIONS ARE BYTE OFFSETS; CLUSTER AWARENESS COMPOSES ABOVE
## =========================================================================
##
## `TextPos.column` is a byte offset (PLAT-24, `text_store.nim`) and so is
## every offset here. A motion that lands mid-cluster is a defect, and the
## corpus exists to catch it: `selection_ops.nim` moves by whole grapheme
## clusters, segmenting the line once, and the suite asserts every landing is
## a cluster boundary over all eighteen corpus documents.
##
## =========================================================================
## THE GOAL COLUMN IS A TAB-EXPANDED DISPLAY COLUMN — §7
## =========================================================================
##
## CodeMirror's `goalColumn` is a PIXEL offset, because a proportional font
## makes columns meaningless; vertical motion there round-trips through layout
## (`posAtCoords({x: left + goal, y})`). In a monospace editor that round trip
## is arithmetic, and §7 calls it *"the single largest simplification monospace
## buys us"*. The two pure conversions are `columnAt` and `offsetAtColumn`
## below: a tab advances to the next multiple of the tab size, every other
## cluster advances by its display width, and `offsetAtColumn` always returns a
## cluster boundary.
##
## **The width policy is a parameter, not a global.** `isonim_tui`'s
## `ambiguousWidth` is a threadvar and PLAT-27 owns the policy's home; taking
## it as an argument here means a suite can sweep both settings without
## touching global state, which is what `LAW-C5` will need.

import std/[algorithm, options]

import isonim_tui/text/width as widthMod

import ./change_set

export change_set
export widthMod.AmbiguousWidth   ## the enum, and with it `awNarrow`/`awWide`

type
  Assoc* = enum
    ## Which side of an insertion a CARET sticks to. Meaningful only for an
    ## empty range, which is why it lives in that arm of the variant.
    assocBefore
    assocAfter

  BidiLevel* = range[0 .. 126]
    ## A Unicode bidi embedding level. The reference reserves `7` inside a
    ## packed integer to mean "none"; here the absence is `none(BidiLevel)`
    ## and `7` is a level like any other.

  SelectionRangeKind* = enum
    srEmpty      ## a caret
    srNonEmpty   ## a selection with extent

  SelectionRange* = object
    ## §7's range. The goal column is common to both arms — vertical motion
    ## applies to a caret and to a selection alike — and everything else is
    ## available exactly where it means something.
    goalColumn*: Option[int]
    case kind*: SelectionRangeKind
    of srEmpty:
      pos*: int
      assoc*: Assoc
      bidiLevel*: Option[BidiLevel]
    of srNonEmpty:
      lo*, hi*: int           ## `lo < hi`, always
      inverted*: bool         ## true when the head is at `lo`

  EditorSelection* = object
    ## An ordered, strictly separated, non-empty SEQUENCE of ranges with a
    ## primary index.
    ##
    ## Both fields are private and there is no field-by-field constructor:
    ## normalisation is part of building one (`editorSelection`), never
    ## something a caller remembers to do. A selection that can be assembled
    ## field by field is a selection whose invariants are advice.
    ##
    ## **That is "normalisation cannot be SKIPPED", which is weaker than
    ## "un-normalised is unrepresentable" — the difference was measured.** The
    ## type's ZERO VALUE is reachable from anywhere: `var s: EditorSelection`,
    ## `default(EditorSelection)` and `reset(s)` all produce one whose `ranges`
    ## is empty, and `isNormalised` says false for it. It is the ONE
    ## un-normalised inhabitant — no *sequence* of ranges can be assembled by
    ## hand — and it is inert rather than silent: `mapSelection` over it raises
    ## `SelectionError` by name (because `editorSelection` re-validates) and
    ## `mainRange` raises `IndexDefect`. `{.requiresInit.}` would close
    ## `var s:` but not `default`/`reset`, so it buys a third of the claim and
    ## is not applied; the residual is documented here instead of overstated.
    ranges: seq[SelectionRange]
    primary: int

  ColumnPolicy* = object
    ## What a display column means. PLAT-27 owns where this is configured;
    ## PLAT-26 only needs it to be an argument rather than a global.
    tabSize*: int
    ambiguous*: AmbiguousWidth

  SelectionError* = object of ValueError

const
  DefaultColumnPolicy* = ColumnPolicy(tabSize: 4, ambiguous: awNarrow)

# ===========================================================================
# RANGE CONSTRUCTION AND ACCESS
# ===========================================================================

func caret*(pos: int; assoc = assocBefore;
            bidiLevel = none(BidiLevel);
            goalColumn = none(int)): SelectionRange =
  ## The empty range. A single caret is a selection of one of these, and that
  ## sentence is the whole of §7's "multi-cursor is the absence of a special
  ## case".
  SelectionRange(kind: srEmpty, pos: pos, assoc: assoc,
                 bidiLevel: bidiLevel, goalColumn: goalColumn)

func spanRange*(anchor, head: int; goalColumn = none(int)): SelectionRange =
  ## The range from `anchor` to `head`, in either direction. **This is the one
  ## constructor a motion calls**, and it decides emptiness rather than asking
  ## the caller to: `anchor == head` yields a caret, so a motion that happens
  ## to collapse a selection does not have to notice.
  if anchor == head:
    SelectionRange(kind: srEmpty, pos: anchor, assoc: assocBefore,
                   bidiLevel: none(BidiLevel), goalColumn: goalColumn)
  elif anchor < head:
    SelectionRange(kind: srNonEmpty, lo: anchor, hi: head, inverted: false,
                   goalColumn: goalColumn)
  else:
    SelectionRange(kind: srNonEmpty, lo: head, hi: anchor, inverted: true,
                   goalColumn: goalColumn)

func isEmpty*(r: SelectionRange): bool =
  r.kind == srEmpty

func rangeFrom*(r: SelectionRange): int =
  ## The lower end, whichever end the head is at.
  case r.kind
  of srEmpty: r.pos
  of srNonEmpty: r.lo

func rangeTo*(r: SelectionRange): int =
  case r.kind
  of srEmpty: r.pos
  of srNonEmpty: r.hi

func anchor*(r: SelectionRange): int =
  ## The end that stays put under an extend-style motion.
  case r.kind
  of srEmpty: r.pos
  of srNonEmpty: (if r.inverted: r.hi else: r.lo)

func head*(r: SelectionRange): int =
  ## The end that moves. **Direction matters**, which is why it is a field and
  ## not a convention: `extend-left` from a rightward selection shrinks it and
  ## from a leftward one grows it, and a range that only knew `lo` and `hi`
  ## could not tell the two apart.
  case r.kind
  of srEmpty: r.pos
  of srNonEmpty: (if r.inverted: r.lo else: r.hi)

func byteLen*(r: SelectionRange): int =
  r.rangeTo - r.rangeFrom

func `==`*(a, b: SelectionRange): bool =
  ## Written out: Nim's structural `==` refuses a `case` object.
  if a.kind != b.kind: return false
  if a.goalColumn != b.goalColumn: return false
  case a.kind
  of srEmpty:
    a.pos == b.pos and a.assoc == b.assoc and a.bidiLevel == b.bidiLevel
  of srNonEmpty:
    a.lo == b.lo and a.hi == b.hi and a.inverted == b.inverted

func `$`*(r: SelectionRange): string =
  case r.kind
  of srEmpty:
    "caret@" & $r.pos & (if r.assoc == assocBefore: "<" else: ">") &
      (if r.goalColumn.isSome: "g" & $r.goalColumn.get else: "")
  of srNonEmpty:
    (if r.inverted: "<" else: "") & "[" & $r.lo & "," & $r.hi & ")" &
      (if r.inverted: "" else: ">") &
      (if r.goalColumn.isSome: "g" & $r.goalColumn.get else: "")

func withGoal*(r: SelectionRange; goal: Option[int]): SelectionRange =
  result = r
  result.goalColumn = goal

# ===========================================================================
# NORMALISATION — part of constructing a selection, never a caller's job
# ===========================================================================

func mergeTwo(prev, next: SelectionRange): SelectionRange =
  ## The merged range of two that touch or overlap. The DIRECTION comes from
  ## the incoming range, which is the reference's rule
  ## (`range.anchor > range.head ? range(to, from) : range(from, to)`): the
  ## range a user just extended is the one whose direction the merge should
  ## keep.
  let lo = min(prev.rangeFrom, next.rangeFrom)
  let hi = max(prev.rangeTo, next.rangeTo)
  let goal = if next.goalColumn.isSome: next.goalColumn else: prev.goalColumn
  if lo == hi:
    # Two coincident carets. Nothing survives but the point itself, and the
    # incoming association wins for the same reason the direction does.
    var r = next
    if r.kind != srEmpty:
      r = caret(lo, assocBefore)
    r.goalColumn = goal
    r
  elif next.anchor > next.head:
    spanRange(hi, lo, goal)
  else:
    spanRange(lo, hi, goal)

proc editorSelection*(ranges: openArray[SelectionRange];
                      primary = 0): EditorSelection =
  ## **THE ONLY CONSTRUCTOR, AND IT NORMALISES.** Sort by start, merge every
  ## pair that touches or overlaps, and carry the primary index onto the range
  ## that absorbed it.
  ##
  ## `LAW-S1` (idempotent and total) and `LAW-S2` (the primary survives) are
  ## both about this function. Note how the primary is tracked: by the INDEX
  ## of the range it started as, decremented once per merge that happens at or
  ## before it — the structural bookkeeping the reference does. `LAW-S2` checks
  ## the OTHER thing, that the surviving range contains the old primary's
  ## head, and the two derivations are deliberately different, or the law would
  ## be the implementation agreeing with itself
  ## (Verification-Harness-Traps §30).
  if ranges.len == 0:
    raise newException(SelectionError,
      "editorSelection: a selection is a NON-EMPTY sequence of ranges — §7. " &
      "A caret is `caretSelection(pos)`, which is a set of one.")
  if primary < 0 or primary >= ranges.len:
    raise newException(SelectionError,
      "editorSelection: primary index " & $primary & " is outside a set of " &
      $ranges.len & " range(s)")

  # The primary is followed as a VALUE across the sort, exactly as the
  # reference does (`ranges.indexOf(main)`), because a stable sort by start
  # alone does not tell you where index `primary` went.
  var xs: seq[(SelectionRange, int)] = @[]
  for i, r in ranges:
    if r.rangeFrom > r.rangeTo:
      raise newException(SelectionError,
        "editorSelection: range " & $i & " is inverted as a pair of offsets: " & $r)
    if r.kind == srNonEmpty and r.lo == r.hi:
      raise newException(SelectionError,
        "editorSelection: range " & $i & " claims srNonEmpty at a single point")
    xs.add (r, i)
  # A stable sort on the start offset, with the ORIGINAL index as the tie
  # break, so two ranges starting at the same place keep the order the caller
  # gave them and the result does not depend on the sort's stability.
  xs.sort(proc (a, b: (SelectionRange, int)): int =
    if a[0].rangeFrom != b[0].rangeFrom:
      cmp(a[0].rangeFrom, b[0].rangeFrom)
    elif a[0].rangeTo != b[0].rangeTo:
      cmp(a[0].rangeTo, b[0].rangeTo)
    else:
      cmp(a[1], b[1]))

  var sorted: seq[SelectionRange] = @[]
  var mainIndex = 0
  for i, x in xs:
    sorted.add x[0]
    if x[1] == primary: mainIndex = i

  var merged: seq[SelectionRange] = @[]
  for i, r in sorted:
    if merged.len > 0 and r.rangeFrom <= merged[^1].rangeTo:
      # TOUCHING OR OVERLAPPING. `<=` rather than `<` is the divergence the
      # header explains: it is what makes §3.2's published killer for LAW-S1
      # observable.
      merged[^1] = mergeTwo(merged[^1], r)
      if i <= mainIndex: dec mainIndex
    else:
      merged.add r
  if mainIndex < 0: mainIndex = 0
  if mainIndex >= merged.len: mainIndex = merged.len - 1
  EditorSelection(ranges: merged, primary: mainIndex)

proc caretSelection*(pos: int; assoc = assocBefore): EditorSelection =
  ## A single caret — a selection of ONE empty range. Spelled here so the
  ## phrase "one cursor is a set of one" has a call site rather than only a
  ## paragraph.
  editorSelection([caret(pos, assoc)])

proc singleSelection*(anchor, head: int): EditorSelection =
  editorSelection([spanRange(anchor, head)])

func ranges*(s: EditorSelection): seq[SelectionRange] =
  ## A copy. The field is private so the only values in circulation are ones
  ## `editorSelection` normalised.
  s.ranges

func rangeCount*(s: EditorSelection): int = s.ranges.len

func primaryIndex*(s: EditorSelection): int = s.primary

func mainRange*(s: EditorSelection): SelectionRange = s.ranges[s.primary]

func `[]`*(s: EditorSelection; i: int): SelectionRange = s.ranges[i]

iterator items*(s: EditorSelection): SelectionRange =
  for r in s.ranges: yield r

func `==`*(a, b: EditorSelection): bool =
  if a.primary != b.primary: return false
  if a.ranges.len != b.ranges.len: return false
  for i in 0 ..< a.ranges.len:
    if a.ranges[i] != b.ranges[i]: return false
  true

func `$`*(s: EditorSelection): string =
  result = "Selection{"
  for i, r in s.ranges:
    if i > 0: result.add " "
    if i == s.primary: result.add "*"
    result.add $r
  result.add "}"

func rangesInvariantViolation*(rs: openArray[SelectionRange];
                               primary: int): string =
  ## "" when `(rs, primary)` is what §7 says a selection is, otherwise the
  ## FIRST violation by name.
  ##
  ## **Written over a RAW sequence rather than over an `EditorSelection`, so
  ## that it is FALSIFIABLE.** A predicate that can only be handed values the
  ## normalising constructor produced is a predicate no test can watch say
  ## "no" — Verification-Harness-Traps §7b's exact shape. The suite feeds it
  ## unsorted, touching, overlapping and duplicated sequences and asserts each
  ## is refused BY NAME; `invariantViolation` below is the same predicate at
  ## the type (§30: one predicate, one function, rule and control both calling
  ## it).
  if rs.len == 0: return "the range set is empty"
  if primary < 0 or primary >= rs.len:
    return "primary index " & $primary & " outside " & $rs.len & " range(s)"
  for i, r in rs:
    if r.rangeFrom > r.rangeTo:
      return "range " & $i & " is inverted as a pair of offsets: " & $r
    if r.kind == srNonEmpty and r.lo >= r.hi:
      return "range " & $i & " is srNonEmpty at a single point: " & $r
    if i > 0 and r.rangeFrom <= rs[i - 1].rangeTo:
      return "range " & $i & " touches or overlaps range " & $(i - 1) & ": " &
        $rs[i - 1] & " then " & $r
  ""

func invariantViolation*(s: EditorSelection): string =
  ## The same predicate, at the type. Read back off the value rather than
  ## tracked alongside it — the analogue of `isNormalised` in PLAT-25.
  ## `FUZZ-3` calls this after every step, and so does every law that claims a
  ## result is normalised.
  rangesInvariantViolation(s.ranges, s.primary)

func isNormalised*(s: EditorSelection): bool =
  s.invariantViolation.len == 0

# ===========================================================================
# MAPPING A SELECTION THROUGH A CHANGE SET — §7, `LAW-S4` and `LAW-S6`
# ===========================================================================

func mapRange*(r: SelectionRange; cs: ChangeSet): SelectionRange =
  ## One range, moved into the document `cs` produced.
  ##
  ## **A NON-EMPTY RANGE SHRINKS AWAY FROM TEXT INSERTED AT ITS EDGES.** The
  ## start is mapped forward-biased (`sideAfter`) and the end backward-biased
  ## (`sideBefore`), so an insert exactly at a boundary lands OUTSIDE the
  ## selection rather than being swallowed into it. That is `LAW-S4`, its
  ## published killer is *"map both ends with the same bias"*, and the same
  ## rule is already applied to `efRevealRange` in `transaction.nim` — one
  ## rule, two call sites, stated once here.
  ##
  ## An EMPTY range has one position and no edges, so its association decides
  ## instead: that is what association is for, and it is why the field lives
  ## in that arm of the variant.
  ##
  ## Both ends go through `change_set.mapPosOr`, which is PLAT-25's typed
  ## mapping with the "I have decided I do not care which arm" decision made
  ## once and by name. Nothing here re-derives a position mapping.
  case r.kind
  of srEmpty:
    let side = if r.assoc == assocBefore: sideBefore else: sideAfter
    var m = r
    m.pos = cs.mapPosOr(r.pos, side)
    m
  of srNonEmpty:
    let lo = cs.mapPosOr(r.lo, sideAfter)
    let hi = cs.mapPosOr(r.hi, sideBefore)
    if lo >= hi:
      # The whole range was deleted, or an insert at both edges pushed the two
      # ends past each other. A range that lost its extent becomes a caret —
      # which is `LAW-S6`'s "never to MORE ranges" holding at the level of one.
      caret(min(lo, hi), assocBefore, none(BidiLevel), r.goalColumn)
    elif r.inverted:
      spanRange(hi, lo, r.goalColumn)
    else:
      spanRange(lo, hi, r.goalColumn)

proc mapSelection*(s: EditorSelection; cs: ChangeSet): EditorSelection =
  ## The whole set, mapped and re-normalised. **One mapped range per input
  ## range** — never one per touched change section, which is `LAW-S6`'s
  ## published killer — and then `editorSelection` merges whatever collided.
  ## So the count can fall and can never rise.
  var xs = newSeqOfCap[SelectionRange](s.ranges.len)
  for r in s.ranges: xs.add mapRange(r, cs)
  editorSelection(xs, s.primary)

# ===========================================================================
# THE TWO PURE COLUMN CONVERSIONS — §7
# ===========================================================================

func columnAt*(line: string; byteOffset: int;
               policy = DefaultColumnPolicy): int =
  ## The tab-expanded DISPLAY column at `byteOffset` bytes into `line`.
  ##
  ## A tab advances to the next multiple of `tabSize`; every other cluster
  ## advances by its display width, so a CJK ideograph is two columns and a
  ## combining mark is zero. **This is the function that makes a goal column a
  ## column**, and `LAW-S5` runs it over the corpus's nine classes precisely
  ## because a version that counted clusters would be right on ASCII and wrong
  ## on every wide glyph.
  ##
  ## `line` is one line: a newline inside it is a cluster like any other and
  ## would be counted, which is a caller error rather than something to guard,
  ## because the only callers take their lines from `TextStore.lineText`.
  var col = 0
  for c in graphemeClusters(line):
    if c.start >= byteOffset: break
    if c.text == "\t":
      col = ((col div policy.tabSize) + 1) * policy.tabSize
    else:
      col += clusterDisplayWidth(c.text, policy.ambiguous)
  col

func offsetAtColumn*(line: string; column: int;
                     policy = DefaultColumnPolicy): int =
  ## The inverse, and **it always returns a cluster boundary**.
  ##
  ## The last boundary whose column does not exceed `column`, or the end of
  ## the line when `column` is past its width. That choice is what makes
  ## vertical motion land on a glyph rather than inside one: a goal column of
  ## 5 against a line whose columns run 0, 2, 4, 6 lands at column 4, not
  ## between the two bytes of the CJK ideograph that occupies 4 and 5.
  if column <= 0: return 0
  var col = 0
  var last = 0
  for c in graphemeClusters(line):
    let w =
      if c.text == "\t": ((col div policy.tabSize) + 1) * policy.tabSize - col
      else: clusterDisplayWidth(c.text, policy.ambiguous)
    if col + w > column: return last
    col += w
    last = c.stop
  last

func lineWidth*(line: string; policy = DefaultColumnPolicy): int =
  ## The column the line ends at. `columnAt` at the end — spelled here so
  ## callers do not each write `columnAt(line, line.len, policy)` and one of
  ## them get it wrong.
  columnAt(line, line.len, policy)
