## view_vocabulary/diff_regions.nim — the unified diff's model, for the diff
## view drawn on the shared editor (`ui/shared_diff_editor`).
##
## The review's and the VCS panel's unified diff is, on Monaco, Monaco's diff
## editor in its inline layout. What that view relies on beyond the line diff
## (`editor_dom_frame.lineDiff`) is decided here, with no DOM in it, so both
## Nim backends run the same derivation and a suite can hold it to two texts
## without a browser:
##
##   * the UNCHANGED REGIONS (Monaco's `UnchangedRegion`, what the option
##     `hideUnchangedRegions` collapses): which runs of equal lines are
##     hidden, how many lines each end shows, and what a press, a drag, the
##     keyboard and the boundary's menu do to them — the same arithmetic as
##     Monaco 0.54's `UnchangedRegion.fromDiffs`, `showMoreAbove`,
##     `showMoreBelow`, `showAll` and its boundary widget's drag;
##   * the WORD-LEVEL marks inside a changed run (Monaco's `innerChanges`,
##     drawn as `char-insert` / `char-delete`): a longest common subsequence
##     over the run's words, spaces and punctuation;
##   * the ALIGNMENT of the old revision beside the new one: the inline
##     layout draws the old revision's line numbers in a strip beside the new
##     revision, row for row, so every block the new revision shows (an added
##     run, a view zone of the review's overlay, a collapsed region's band)
##     has a spacer of the same height in the old revision, at the matching
##     place (Monaco's `DiffEditorViewZones` alignments).
##
## NO MOCKS. Nothing here constructs a stand-in: the suite
## (`viewmodel/tests/unit/test_diff_regions.nim`) hands it real texts.

import std/[algorithm, math]

import ./editor_dom_frame

export editor_dom_frame.DiffHunk

# ---------------------------------------------------------------------------
# Unchanged regions
# ---------------------------------------------------------------------------

type
  UnchangedRegion* = object
    ## A run of `lineCount` equal lines: old lines `originalLine ..` and new
    ## lines `modifiedLine ..` (1-based starts), of which the first
    ## `visibleTop` and the last `visibleBottom` are shown and the rest are
    ## hidden behind the region's band.
    originalLine*, modifiedLine*, lineCount*: int
    visibleTop*, visibleBottom*: int

  LineSpan* = tuple[first, last: int]
    ## 0-based lines, inclusive; empty when `last < first`.

proc unchangedRegions*(hunks: openArray[DiffHunk]; originalLineCount,
                       modifiedLineCount, minimumLineCount,
                       contextLineCount: int): seq[UnchangedRegion] =
  ## Monaco's `UnchangedRegion.fromDiffs`: every run of equal lines between
  ## the changes, less `contextLineCount` lines next to each change, when
  ## what is left is at least `minimumLineCount` lines. A run at the start or
  ## the end of the file keeps context on its inner side only. Two equal
  ## texts have no region (Monaco drops the one region that would cover the
  ## whole file).
  var prevOld = 0
  var prevNew = 0
  var runs: seq[tuple[o, m, n: int]] = @[]
  for h in hunks:
    if h.oldFrom > prevOld:
      runs.add (prevOld + 1, prevNew + 1, h.oldFrom - prevOld)
    prevOld = h.oldTo
    prevNew = h.newTo
  if originalLineCount > prevOld:
    runs.add (prevOld + 1, prevNew + 1, originalLineCount - prevOld)
  let c = max(0, contextLineCount)
  let minimum = max(0, minimumLineCount)
  for r in runs:
    var o = r.o
    var m = r.m
    var n = r.n
    let atStart = o == 1 and m == 1
    let atEnd = o + n == originalLineCount + 1 and m + n == modifiedLineCount + 1
    if (atStart or atEnd) and n >= c + minimum:
      if atStart and not atEnd: n -= c
      if atEnd and not atStart:
        o += c
        m += c
        n -= c
      result.add UnchangedRegion(originalLine: o, modifiedLine: m, lineCount: n)
    elif n >= c * 2 + minimum:
      result.add UnchangedRegion(originalLine: o + c, modifiedLine: m + c,
                                 lineCount: n - c * 2)
  if result.len == 1 and result[0].modifiedLine == 1 and
     result[0].lineCount == modifiedLineCount:
    result = @[]

func hiddenCount*(r: UnchangedRegion): int =
  ## How many lines the region still hides: both ends of it reveal from the
  ## same pool.
  max(0, r.lineCount - r.visibleTop - r.visibleBottom)

func controlsHidden*(r: UnchangedRegion): bool =
  ## Monaco's `shouldHideControls`: everything is shown, so the region has no
  ## band and no boundaries.
  r.visibleTop + r.visibleBottom >= r.lineCount

func maxVisibleTop*(r: UnchangedRegion): int = r.lineCount - r.visibleBottom
func maxVisibleBottom*(r: UnchangedRegion): int = r.lineCount - r.visibleTop

proc showMoreAbove*(r: var UnchangedRegion; count: int) =
  ## Reveal `count` more of the region's topmost hidden lines (Monaco clamps
  ## to what is left, so "to the file's edge" is a large enough count).
  r.visibleTop = min(r.visibleTop + max(0, count), r.maxVisibleTop)

proc showMoreBelow*(r: var UnchangedRegion; count: int) =
  r.visibleBottom = min(r.visibleBottom + max(0, count), r.maxVisibleBottom)

proc showAll*(r: var UnchangedRegion) =
  r.visibleBottom = r.lineCount - r.visibleTop

func hiddenModifiedSpan*(r: UnchangedRegion): LineSpan =
  ## The new revision's hidden lines, 0-based inclusive.
  let first = r.modifiedLine - 1 + r.visibleTop
  (first, first + r.hiddenCount - 1)

func hiddenOriginalSpan*(r: UnchangedRegion): LineSpan =
  let first = r.originalLine - 1 + r.visibleTop
  (first, first + r.hiddenCount - 1)

func bandAfterLine*(r: UnchangedRegion; modified: bool): int =
  ## The 1-based line a region's band (its view zone) is drawn after: the
  ## last shown line above the hidden ones, 0 above the first line.
  (if modified: r.modifiedLine else: r.originalLine) + r.visibleTop - 1

const
  DragThresholdPx* = 2
    ## A press that moves no more than this is a click (Monaco's widget).
  BandHeightPx* = 24
    ## A collapsed region's band (Monaco's `ViewZone` of 24 px).

func dragMoved*(startY, y: float): bool = abs(y - startY) > float(DragThresholdPx)

func draggedVisibleTop*(start: int; startY, y: float; lineHeight: int;
                        r: UnchangedRegion): int =
  ## The upper boundary dragged from `startY` to `y`: one more line shown per
  ## line height moved down (Monaco's widget: `round(delta / lineHeight)`).
  let lines = int(round((y - startY) / float(max(1, lineHeight))))
  clamp(start + lines, 0, r.maxVisibleTop)

func draggedVisibleBottom*(start: int; startY, y: float; lineHeight: int;
                           r: UnchangedRegion): int =
  ## The lower boundary: one more line shown per line height moved UP.
  let lines = int(round((y - startY) / float(max(1, lineHeight))))
  clamp(start - lines, 0, r.maxVisibleBottom)

proc revealModifiedLine*(r: var UnchangedRegion; line1: int): bool =
  ## Monaco's `ensureModifiedLineIsVisible`: a caret moved onto a hidden line
  ## (a find match, a jump) shows it, from the nearer end. Whether it was
  ## hidden.
  let span = r.hiddenModifiedSpan
  let line0 = line1 - 1
  if span.last < span.first or line0 < span.first or line0 > span.last:
    return false
  let fromTop = line1 - r.modifiedLine
  let fromBottom = r.modifiedLine + r.lineCount - line1
  if fromTop < fromBottom: r.visibleTop = max(r.visibleTop, fromTop + 1)
  else: r.visibleBottom = max(r.visibleBottom, fromBottom)
  true

func liveRegions*(rs: openArray[UnchangedRegion]): seq[int] =
  ## The indices of the regions that still have a band, in line order — the
  ## order the bands are drawn in.
  for i, r in rs:
    if not r.controlsHidden: result.add i

proc mergeSpans*(a, b: openArray[LineSpan]): seq[LineSpan] =
  ## Two lists of hidden 0-based line spans as one, merged and sorted (the
  ## folds' and the collapsed regions').
  var all: seq[LineSpan] = @[]
  for s in a:
    if s.last >= s.first: all.add s
  for s in b:
    if s.last >= s.first: all.add s
  all.sort(proc (x, y: LineSpan): int = cmp(x.first, y.first))
  for s in all:
    if result.len > 0 and s.first <= result[^1].last + 1:
      result[^1].last = max(result[^1].last, s.last)
    else:
      result.add s

# ---------------------------------------------------------------------------
# Word-level marks
# ---------------------------------------------------------------------------

type
  CharSpan* = object
    ## Byte columns `[fromCol, toCol)` of 0-based `line` in one revision.
    line*, fromCol*, toCol*: int

  InnerChanges* = object
    deleted*: seq[CharSpan]   ## in the old revision
    inserted*: seq[CharSpan]  ## in the new revision

func isWordByte(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or ord(c) >= 0x80

proc wordTokens(s: string): seq[tuple[a, b: int]] =
  ## `s` cut into words, runs of blanks, line breaks and single punctuation.
  var i = 0
  while i < s.len:
    let c = s[i]
    var j = i + 1
    if c.isWordByte:
      while j < s.len and s[j].isWordByte: inc j
    elif c in {' ', '\t'}:
      while j < s.len and s[j] in {' ', '\t'}: inc j
    result.add (i, j)
    i = j

proc spansOf(lines: openArray[string]; firstLine: int;
             changed: seq[tuple[a, b: int]]): seq[CharSpan] =
  ## Offsets into `lines` joined by "\n" as per-line spans, line breaks left
  ## out, adjacent spans on one line merged.
  var starts: seq[int] = @[]
  var at = 0
  for l in lines:
    starts.add at
    at += l.len + 1
  for (a, b) in changed:
    var k = 0
    while k + 1 < starts.len and starts[k + 1] <= a: inc k
    var pos = a
    while pos < b and k < lines.len:
      let ls = starts[k]
      let le = ls + lines[k].len
      let f = max(pos, ls)
      let t = min(b, le)
      if t > f:
        let sp = CharSpan(line: firstLine + k, fromCol: f - ls, toCol: t - ls)
        if result.len > 0 and result[^1].line == sp.line and
           result[^1].toCol == sp.fromCol:
          result[^1].toCol = sp.toCol
        else:
          result.add sp
      pos = le + 1
      inc k

const InnerDiffCellLimit = 1_000_000
  ## A changed run too large for the word table is marked whole.

proc innerChanges*(oldLines, newLines: openArray[string];
                   h: DiffHunk): InnerChanges =
  ## The words that differ inside a changed run that has both removed and
  ## added lines. A run of only one kind has no word marks: the whole lines
  ## are the change (`wholeLineMarks`).
  if h.oldTo <= h.oldFrom or h.newTo <= h.newFrom: return
  var a = ""
  var b = ""
  for k in h.oldFrom ..< h.oldTo:
    if k > h.oldFrom: a.add '\n'
    a.add oldLines[k]
  for k in h.newFrom ..< h.newTo:
    if k > h.newFrom: b.add '\n'
    b.add newLines[k]
  let ta = wordTokens(a)
  let tb = wordTokens(b)
  let n = ta.len
  let m = tb.len
  var delA: seq[tuple[a, b: int]] = @[]
  var insB: seq[tuple[a, b: int]] = @[]
  if n * m > InnerDiffCellLimit:
    if a.len > 0: delA.add (0, a.len)
    if b.len > 0: insB.add (0, b.len)
  else:
    proc tok(s: string; t: tuple[a, b: int]): string = s[t.a ..< t.b]
    var dp = newSeq[seq[int32]](n + 1)
    for i in 0 .. n: dp[i] = newSeq[int32](m + 1)
    for i in countdown(n - 1, 0):
      for j in countdown(m - 1, 0):
        dp[i][j] = if tok(a, ta[i]) == tok(b, tb[j]): dp[i + 1][j + 1] + 1
                   else: max(dp[i + 1][j], dp[i][j + 1])
    var i = 0
    var j = 0
    proc addTok(into: var seq[tuple[a, b: int]]; t: tuple[a, b: int]) =
      if into.len > 0 and into[^1].b == t.a: into[^1].b = t.b
      else: into.add t
    while i < n or j < m:
      if i < n and j < m and tok(a, ta[i]) == tok(b, tb[j]):
        inc i
        inc j
      elif j < m and (i >= n or dp[i][j + 1] >= dp[i + 1][j]):
        insB.addTok tb[j]
        inc j
      else:
        delA.addTok ta[i]
        inc i
  result.deleted = spansOf(oldLines[h.oldFrom ..< h.oldTo], h.oldFrom, delA)
  result.inserted = spansOf(newLines[h.newFrom ..< h.newTo], h.newFrom, insB)

func wholeLineMarks*(h: DiffHunk): tuple[deletedLines, insertedLines: seq[int]] =
  ## Monaco marks a run that only removes, or only adds, whole-line
  ## (`char-delete` / `char-insert` over each line): 0-based lines.
  if h.newTo <= h.newFrom:
    for k in h.oldFrom ..< h.oldTo: result.deletedLines.add k
  if h.oldTo <= h.oldFrom:
    for k in h.newFrom ..< h.newTo: result.insertedLines.add k

# ---------------------------------------------------------------------------
# The old revision aligned beside the new one
# ---------------------------------------------------------------------------

type
  AlignZone* = object
    ## A block of `heightPx` drawn after 1-based `afterLine` (0: above the
    ## first line); `order` breaks ties between blocks after one line (the
    ## lower first), as the editor's layout does.
    afterLine*, heightPx*, order*: int

proc originalZones*(hunks: openArray[DiffHunk]; modifiedZones: openArray[AlignZone];
                    lineHeight: int; deletedOrder = -1): seq[AlignZone] =
  ## The old revision's spacers, so it lines up with the new revision row for
  ## row. The new revision draws, besides its lines: each removed run as a
  ## block of the old lines (order `deletedOrder`, which the old revision
  ## draws as its own lines) and `modifiedZones` — the bands, the overlay's
  ## blocks. The old revision draws a spacer for each added run and for each
  ## of those zones, at the place the zone holds in the new revision.
  ##
  ## The result is in layout order, with `order` numbering it, so the old
  ## revision's layout keeps the order given.
  type Item = tuple[after, sub, slot, tie, seqNo, height: int; spacer: bool]
  var items: seq[Item] = @[]
  let lh = max(1, lineHeight)
  # the added runs' spacers, one slot per added line
  for h in hunks:
    for k in 1 .. (h.newTo - h.newFrom):
      items.add (h.oldTo, 1, k, 0, items.len, lh, true)
  var zs = @modifiedZones
  zs.sort(proc (x, y: AlignZone): int =
    if x.afterLine != y.afterLine: cmp(x.afterLine, y.afterLine)
    else: cmp(x.order, y.order))
  for z in zs:
    let L = z.afterLine
    var placed = false
    for h in hunks:
      if h.newFrom < L and L <= h.newTo:
        # after an added line: between the spacer's slots
        items.add (h.oldTo, 1, L - h.newFrom, 1, items.len, z.heightPx, false)
        placed = true
        break
    if placed: continue
    # after an unchanged line (or above the first): the matching old line
    var origL = L
    var nextH = -1
    for i, h in hunks:
      if h.newFrom == L:
        # the change right below this line
        nextH = i
        break
      if h.newTo <= L: origL = L - (h.newTo - h.oldTo)
    if nextH >= 0 and z.order > deletedOrder:
      # drawn below the removed lines' block, above the added lines
      items.add (hunks[nextH].oldTo, 0, 0, 0, items.len, z.heightPx, false)
    else:
      items.add (origL, 0, 0, 0, items.len, z.heightPx, false)
  items.sort(proc (x, y: Item): int =
    if x.after != y.after: return cmp(x.after, y.after)
    if x.sub != y.sub: return cmp(x.sub, y.sub)
    if x.slot != y.slot: return cmp(x.slot, y.slot)
    if x.tie != y.tie: return cmp(x.tie, y.tie)
    cmp(x.seqNo, y.seqNo))
  var lastSpacer = false
  for it in items:
    if it.spacer and lastSpacer and result.len > 0 and
       result[^1].afterLine == it.after:
      result[^1].heightPx += it.height
    else:
      result.add AlignZone(afterLine: it.after, heightPx: it.height,
                           order: result.len)
    lastSpacer = it.spacer
