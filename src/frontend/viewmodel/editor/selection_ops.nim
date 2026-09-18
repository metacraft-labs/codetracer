## selection_ops.nim — PLAT-26: the apply-across-ranges helper, and the twelve
## primitives that exist at this milestone.
##
## Owns: Editor-ViewModel.md §7's fifth deliverable — *"the apply-across-ranges
## helper every editing operation is written on: run a per-range function in
## start-document coordinates, get back one merged change set, selection and
## effect list"* — and the operation set `LAW-S3` sweeps.
##
## =========================================================================
## THIS IS THE THIRD IN-TREE CALL SITE OF THE ONE REBASE PRIMITIVE
## =========================================================================
##
## `changeByRange` is `codemirror-state/src/state.ts:150-175`, the SECOND of
## the five places the reference hand-writes the strict double mapping:
##
##     let newMapped = newChanges.map(changes)          // before defaults false
##     let mapBy = changes.mapDesc(newChanges, true)
##
## Those two lines are `rebase(changes, newChanges)` and nothing else. PLAT-25
## recorded this site as *"PLAT-26's"* and left the deliverable's second clause
## unticked because the call site did not exist yet; it exists now, it calls
## `rebase`, and it does not spell `before` anywhere — there is no `before` to
## spell, because `mapOver` is private to `change_set.nim`. The source scan in
## `test_editor_change_algebra.nim` is what keeps that true, and it now reads
## this file too.
##
## =========================================================================
## WHY THE PER-RANGE FUNCTION TAKES ONE RANGE AND NOT A SELECTION
## =========================================================================
##
## Because that is the whole of "multi-cursor is the absence of a special
## case". An operation is written once, against one range, in start-document
## coordinates; `changeByRange` runs it over the set and reconciles the
## coordinate systems. **Nothing below this line asks how many ranges there
## are.** `LAW-S3` is the executable form of the claim, at K ∈ {1, 2, 3, 7},
## and its published killer — *"make one operation read `s.ranges[s.primary]`"*
## — is performed as an arm on `changeByRange` itself.
##
## =========================================================================
## THE TWELVE, AND WHY THE NUMBER IS ASSERTED RATHER THAN WRITTEN
## =========================================================================
##
## `SelectionOpCount` is derived from the enum. The milestone's floor has it as
## a multiplier (12 primitives x 4 values of K = 48 cases), and
## Editor-Model-Conformance-Suite.md §10.4 rule 3 says a sweep's multiplier
## must be an asserted cardinality rather than a round number: *"If the number
## of primitives changes, the assertion moves the floor rather than the floor
## hiding the change."* PLAT-30 brings the full 224-operation vocabulary; these
## twelve are what the model can express before it, and the sweep is over the
## enum rather than over a list somebody maintains beside it.

import std/[algorithm, options]

import isonim_tui/text/width as widthMod

import ./change_set
import ./selection
import ./text_store
import ./transaction

export selection, transaction

type
  SelectionOp* = enum
    ## The operation set at THIS milestone. Ten motions and two operators —
    ## and the point of the split is that the two operators consume whatever
    ## the ten motions produce, with no fused `delete-word-forward` anywhere.
    opMoveLeft          ## one grapheme cluster left, collapsing
    opMoveRight
    opExtendLeft        ## the head moves, the anchor stays
    opExtendRight
    opMoveLineStart
    opMoveLineEnd
    opMoveLineUp        ## vertical, through the goal column
    opMoveLineDown
    opCollapseToHead
    opSelectLine        ## extend to cover the whole line(s) the range touches
    opDeleteRange       ## the operator: delete what is selected
    opInsertText        ## the operator: replace what is selected

  RangeOutcome* = object
    ## What a per-range function returns.
    ##
    ## `edits` are in **start-document** coordinates — the coordinates the
    ## range itself is in — so an operation never has to know what the other
    ## ranges did. `range` is in the coordinates of the document with THIS
    ## range's edits applied and no others, which is the reference's contract
    ## and the reason `changeByRange` has two mappings to reconcile rather
    ## than one.
    edits*: seq[Edit]
    range*: SelectionRange
    effects*: seq[Effect]

  OpCtx* = object
    ## Everything an operation needs that is not the range: the document, its
    ## line index, its cluster boundaries and the column policy.
    ##
    ## The boundaries are computed ONCE per context rather than per range,
    ## because a K-range operation would otherwise segment the document K
    ## times — and `LAW-S3`'s K = 7 rows would be paying for it on every draw.
    doc*: string
    store*: TextStore
    boundaries*: seq[int]
    policy*: ColumnPolicy
    inserted*: string     ## what `opInsertText` puts in

const
  SelectionOpCount* = ord(high(SelectionOp)) - ord(low(SelectionOp)) + 1
    ## Derived from the enum. See the header.

proc clusterBoundariesOf*(s: string): seq[int] =
  ## Every grapheme-cluster boundary of `s`, ascending, including 0 and
  ## `s.len`. **Positions are byte offsets and cluster awareness composes
  ## above them** — this is that composition, and it is the only place in this
  ## module that segments anything.
  result = @[0]
  for c in graphemeClusters(s):
    if c.stop > result[^1]: result.add c.stop
  if result[^1] != s.len: result.add s.len

proc initOpCtx*(doc: string; policy = DefaultColumnPolicy;
                inserted = "X"): OpCtx =
  OpCtx(doc: doc, store: toTextStore(doc), boundaries: clusterBoundariesOf(doc),
        policy: policy, inserted: inserted)

func prevBoundary*(ctx: OpCtx; pos: int): int =
  ## The largest cluster boundary strictly below `pos`, or 0.
  ##
  ## `lowerBound` rather than a scan: `LAW-S3` at K = 7 over eighteen corpus
  ## documents calls this often enough for a linear walk to show up in the JS
  ## lane, which is the lane PLAT-25 measured at 5 m 55 s before its own
  ## hoisting.
  let i = ctx.boundaries.lowerBound(pos)
  if i <= 0: 0 else: ctx.boundaries[i - 1]

func nextBoundary*(ctx: OpCtx; pos: int): int =
  ## The smallest cluster boundary strictly above `pos`, or the document end.
  let i = ctx.boundaries.upperBound(pos)
  if i >= ctx.boundaries.len: ctx.doc.len else: ctx.boundaries[i]

func boundaryAtOrBefore*(ctx: OpCtx; pos: int): int =
  ## The largest cluster boundary not above `pos`. `pos` itself when it is one.
  let i = ctx.boundaries.upperBound(pos)
  if i <= 0: 0 else: ctx.boundaries[i - 1]

proc lineOf(ctx: OpCtx; offset: int): int =
  ctx.store.posOf(offset).line

proc lineStart(ctx: OpCtx; line: int): int =
  ## Always a cluster boundary: a line starts immediately after a `\n`, and
  ## UAX #29 always breaks after LF (GB4). No clamp is needed and none is
  ## applied, because a clamp here would hide a line index that had drifted.
  ctx.store.offsetOf(textPos(line, 0))

proc lineEnd(ctx: OpCtx; line: int): int =
  ## **THE LINE INDEX AND THE SEGMENTER DISAGREE ON A CRLF LINE, AND THIS IS
  ## WHERE THAT IS RESOLVED.**
  ##
  ## `TextStore` is `\n`-delimited (PLAT-24: `lineCount` is `newlineCount + 1`
  ## and `lineLen` excludes only the terminating `\n`), so the "end" of a line
  ## ending `\r\n` is the offset BETWEEN the CR and the LF. UAX #29 GB3 keeps
  ## CR LF together as ONE grapheme cluster, so that offset is inside a
  ## cluster — and a caret inside a CRLF pair is exactly the half-deleted-emoji
  ## defect §9 names, in its least glamorous form.
  ##
  ## Found by PLAT-26's own corpus sweep rather than reasoned about in advance:
  ## the case *"every motion lands on a cluster boundary, over all eighteen
  ## corpus documents"* reported `c6-terminators-short`, `opMoveLineEnd`,
  ## landing at offset 7 of a window whose bytes are `...two\r\n...`. Clamping
  ## back to the last boundary puts the caret before the CR, which is where
  ## every editor puts it.
  ctx.boundaryAtOrBefore(ctx.store.offsetOf(textPos(line, ctx.store.lineLen(line))))

proc goalOf(ctx: OpCtx; r: SelectionRange): int =
  ## The goal column a vertical motion should use: the one the range is
  ## carrying, or — if it carries none — the column its head is at NOW.
  ##
  ## **`LAW-S5`'s published killer is "recompute the goal from the landed
  ## column", and this is the function it lands on.** The goal is read here
  ## and carried through unchanged by `verticalMove` below; a version that
  ## re-derived it after landing would collapse the column on the first short
  ## line, which is the entire reason the field exists.
  if r.goalColumn.isSome: return r.goalColumn.get
  let line = ctx.lineOf(r.head)
  columnAt(ctx.store.lineText(line), r.head - ctx.lineStart(line), ctx.policy)

proc verticalMove(ctx: OpCtx; r: SelectionRange; delta: int): RangeOutcome =
  let goal = ctx.goalOf(r)
  let line = ctx.lineOf(r.head)
  let target = clamp(line + delta, 0, ctx.store.lineCount - 1)
  let text = ctx.store.lineText(target)
  # `offsetAtColumn` returns a cluster boundary OF THE LINE, and for a line
  # ending `\r\n` the line's own last boundary is the offset between the CR and
  # the LF in the DOCUMENT — see `lineEnd`. Clamping against the document's
  # boundaries is what makes "a cluster boundary of the line" and "a cluster
  # boundary of the document" the same claim.
  let landed = ctx.boundaryAtOrBefore(
    ctx.lineStart(target) + offsetAtColumn(text, goal, ctx.policy))
  RangeOutcome(edits: @[], effects: @[],
               range: caret(landed, assocBefore, none(BidiLevel), some(goal)))

proc applyRangeOp*(ctx: OpCtx; op: SelectionOp; r: SelectionRange): RangeOutcome =
  ## **THE PER-RANGE FUNCTION.** One range in, one outcome out, in
  ## start-document coordinates. There is no `EditorSelection` in this
  ## signature and that is the design, not an omission.
  ##
  ## The goal column is CLEARED by every horizontal motion and PRESERVED by
  ## the two vertical ones and by the collapse — which is the reference's rule
  ## and the only one under which `LAW-S5` is a statement about vertical
  ## motion rather than about motion in general.
  case op
  of opMoveLeft:
    RangeOutcome(edits: @[], effects: @[],
                 range: caret(ctx.prevBoundary(r.head)))
  of opMoveRight:
    RangeOutcome(edits: @[], effects: @[],
                 range: caret(ctx.nextBoundary(r.head)))
  of opExtendLeft:
    RangeOutcome(edits: @[], effects: @[],
                 range: spanRange(r.anchor, ctx.prevBoundary(r.head)))
  of opExtendRight:
    RangeOutcome(edits: @[], effects: @[],
                 range: spanRange(r.anchor, ctx.nextBoundary(r.head)))
  of opMoveLineStart:
    RangeOutcome(edits: @[], effects: @[],
                 range: caret(ctx.lineStart(ctx.lineOf(r.head))))
  of opMoveLineEnd:
    RangeOutcome(edits: @[], effects: @[],
                 range: caret(ctx.lineEnd(ctx.lineOf(r.head))))
  of opMoveLineUp:
    verticalMove(ctx, r, -1)
  of opMoveLineDown:
    verticalMove(ctx, r, 1)
  of opCollapseToHead:
    RangeOutcome(edits: @[], effects: @[],
                 range: caret(r.head, assocBefore, none(BidiLevel),
                              r.goalColumn))
  of opSelectLine:
    let a = ctx.lineStart(ctx.lineOf(r.rangeFrom))
    let b = ctx.lineEnd(ctx.lineOf(r.rangeTo))
    RangeOutcome(edits: @[], effects: @[], range: spanRange(a, b))
  of opDeleteRange:
    # THE OPERATOR, over whatever a motion produced. An empty range has
    # nothing selected, so it takes the cluster behind it — which is what
    # makes `d` and backspace one operation rather than two.
    let a = if r.isEmpty: ctx.prevBoundary(r.pos) else: r.rangeFrom
    let b = r.rangeTo
    if a == b:
      RangeOutcome(edits: @[], effects: @[], range: caret(a))
    else:
      RangeOutcome(edits: @[Edit(fromPos: a, toPos: b, insert: "")],
                   effects: @[], range: caret(a))
  of opInsertText:
    let a = r.rangeFrom
    let b = r.rangeTo
    RangeOutcome(
      edits: @[Edit(fromPos: a, toPos: b, insert: ctx.inserted)],
      effects: @[], range: caret(a + ctx.inserted.len))

# ===========================================================================
# THE APPLY-ACROSS-RANGES HELPER — §7's fifth deliverable
# ===========================================================================

proc changeByRange*(doc: string; sel: EditorSelection;
                    f: proc (r: SelectionRange): RangeOutcome): Transaction =
  ## Run `f` over every range of `sel` and reconcile the results into ONE
  ## transaction: one change set, one normalised selection, one effect list.
  ##
  ## Each call to `f` is independent and expressed against the start document.
  ## What has to be reconciled is that range *i*'s answer knows nothing about
  ## ranges 0..i-1's edits and vice versa — so at each step the accumulated
  ## change set and the new one are **rebased over each other**, the already
  ## collected ranges and effects move forward over the new change, and the new
  ## range and effects move forward over the accumulated one.
  ##
  ## THE PRIMITIVE IS CALLED ONCE PER STEP AND BOTH ARMS ARE USED. Writing
  ## either arm by hand is impossible from here: `mapOver` does not leave
  ## `change_set.nim`.
  if sel.rangeCount == 0:
    raise newException(SelectionError, "changeByRange: an empty selection")
  let first = f(sel[0])
  var changes = changeSet(doc.len, first.edits)
  var ranges = @[first.range]
  var effects = first.effects
  for i in 1 ..< sel.rangeCount:
    let res = f(sel[i])
    let newChanges = changeSet(doc.len, res.edits)
    let rb = rebase(changes, newChanges)
    # `bOverA` is the new change re-expressed to apply after everything
    # accumulated so far; `aOverB` is everything accumulated re-expressed to
    # apply after the new change. The reference spells those two as
    # `newChanges.map(changes)` and `changes.mapDesc(newChanges, true)`.
    let newMapped = rb.bOverA
    let mapBy = rb.aOverB
    for j in 0 ..< ranges.len:
      ranges[j] = mapRange(ranges[j], newMapped)
    ranges.add mapRange(res.range, mapBy)
    effects = mapEffects(effects, newMapped) & mapEffects(res.effects, mapBy)
    changes = compose(changes, newMapped)
  transaction(changes, some(editorSelection(ranges, sel.primaryIndex)), effects)

proc runOp*(ctx: OpCtx; op: SelectionOp; sel: EditorSelection): Transaction =
  ## One named operation over a whole selection set. The closure is the only
  ## thing that knows which operation it is; `changeByRange` does not.
  changeByRange(ctx.doc, sel, proc (r: SelectionRange): RangeOutcome =
    applyRangeOp(ctx, op, r))

proc applyOp*(ctx: OpCtx; op: SelectionOp;
              sel: EditorSelection): (string, EditorSelection) =
  ## The observable outcome: the document after, and the selection after.
  let t = runOp(ctx, op, sel)
  (t.changes.apply(ctx.doc), t.selection.get)
