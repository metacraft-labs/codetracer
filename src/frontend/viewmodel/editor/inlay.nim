## inlay.nim — PLAT-28: **the inline widget that reflows**, which is the claim
## Editor-ViewModel.md §8.3 calls *"the design's sharpest claim"*.
##
## Owns: §8.3. An inline value drawn beside code is CONTENT ON THAT LINE. It
## occupies columns, the wrap point moves, and the text after it is positioned
## after it.
##
## =========================================================================
## THE FINDING THIS MODULE IS, IN ONE PARAGRAPH
## =========================================================================
##
## PLAT-27 decided that the ViewModel owns wrapping and that `WrapSettings` is
## a PARAMETER TO A PROJECTION rather than state. If that decision is right,
## an inline widget is not a feature of the wrap algorithm — it is **a cluster
## of zero bytes and W cells**, and `wrap.wrapLine`, `wrap.toDisplay`,
## `wrap.toLogical`, `wrap.gutterFacts`, `wrap.lastColumnOf` and all twelve
## display motions work on it with no change at all.
##
## That is what was built and it is what was measured: `wrap.nim` gained one
## constructor (`wrapCacheOfMetrics`) and one refusal (a decorated cache may
## not be spliced by `updateWrapCache`, because the splice recomputes a line's
## metrics from its TEXT and a widget is not in the text). It gained no widget
## parameter, no decoration import and no branch. **An overlay cannot be
## expressed this way and that is the point**: an overlay is drawn over a
## layout the model already fixed, so it cannot move a column, and `LAW-C7`
## measures a column.
##
## =========================================================================
## THE TAB GRID IS WHY THE COLUMNS ARE RECOMPUTED RATHER THAN SHIFTED
## =========================================================================
##
## The cheap implementation of "insert W cells at column C" is to add W to the
## column of every cluster after C. **It is wrong on any line containing a tab
## after the widget**, because `wrap.cellsOf` advances a tab to the next
## multiple of `tabSize` counted from the start of the LOGICAL LINE — so a
## widget of 3 cells before a tab does not move that tab's end by 3, it moves
## it by however much the tab stop moved, which is between 0 and `tabSize`.
##
## So the columns are re-derived by walking the clusters with a running column
## and asking `wrap.cellsOf` again. The SEGMENTATION is not repeated:
## `wrap.lineMetrics` is called once and its cluster boundaries are reused,
## because a second segmenter in this tree is the defect PLAT-24's corpus
## exists to catch.
##
## =========================================================================
## WHAT HAS A PRODUCER AND WHAT DOES NOT
## =========================================================================
##
## The reflow is exercised by **inline values**, which have a producer:
## `frontend/view_vocabulary/editor_surface.inlineValuesOf` reads
## `StateVM.currentVariables`. **Inlays and type hints have no producer** —
## Editor-ViewModel.md §16 says so and this milestone does not invent one; the
## gap is filed as `decoration.PLAT28-DG2`. An inlay decoration constructs and
## reflows exactly as an inline value does; nothing computes one.

import ./change_set
import ./decoration
import ./wrap

export decoration, wrap

type
  InlayPlacement* = object
    ## One inline widget, resolved onto a logical line.
    ##
    ## `byteInLine` and not a document offset: `wrap.LineMetrics` is per line
    ## and a document offset in it would be a second coordinate system in a
    ## type that already has one.
    byteInLine*: int
    cells*: int
    id*: int
    text*: string

  BlockRows* = object
    ## §8.1's *"content BETWEEN lines"*, as facts rather than as a layout. The
    ## model says how many rows a line's block widgets ask for above and below
    ## it; where a renderer puts them, and whether it honours the request at
    ## all, is the renderer's.
    above*, below*: int

  InlayError* = object of ValueError

func inlayPlacement*(byteInLine, cells, id: int; text = ""): InlayPlacement =
  if byteInLine < 0:
    raise newException(InlayError,
      "inlayPlacement: byte " & $byteInLine & " is before the start of its " &
      "line. Refused rather than clamped to 0 (§36a): a widget silently " &
      "moved to the start of the line is a widget beside the wrong code.")
  if cells < 0:
    raise newException(InlayError,
      "inlayPlacement: " & $cells & " cells, refused rather than clamped.")
  InlayPlacement(byteInLine: byteInLine, cells: cells, id: id, text: text)

proc inlayLineMetrics*(line: string; policy: ColumnPolicy;
                       widgets: openArray[InlayPlacement]): LineMetrics =
  ## **THE WHOLE OF THE REFLOW.** One logical line's metrics with its inline
  ## widgets in them, as clusters of zero bytes and positive cells.
  ##
  ## `widgets` must be ascending in `byteInLine`; the caller orders them,
  ## because two widgets at one position are ordered by `LAW-D5`'s total order
  ## and this routine has no business re-deciding that. An out-of-order list
  ## RAISES rather than being sorted here — a silent sort would make the paint
  ## order depend on which of two routines the caller happened to go through.
  ##
  ## A widget at exactly `line.len` (the end of the line) is legal and lands
  ## after the last cluster, which is where an inline value beside a line of
  ## code actually sits.
  var last = -1
  for w in widgets:
    if w.byteInLine < last:
      raise newException(InlayError,
        "inlayLineMetrics: widget at byte " & $w.byteInLine & " follows one " &
        "at " & $last & ". The list is not sorted for you: two widgets at " &
        "one position have a declared order and sorting here would discard it.")
    if w.byteInLine > line.len:
      raise newException(InlayError,
        "inlayLineMetrics: widget at byte " & $w.byteInLine & " is past the " &
        "end of a line of " & $line.len & " byte(s).")
    last = w.byteInLine

  let base = lineMetrics(line, policy)
  result.byteLen = base.byteLen
  result.clusters = @[]
  var col = 0
  var wi = 0
  for cl in base.clusters:
    # EVERY WIDGET AT OR BEFORE THIS CLUSTER'S START COMES FIRST, which is what
    # makes the text at column C sit at C+W rather than the widget sitting on
    # top of it.
    while wi < widgets.len and widgets[wi].byteInLine <= cl.startByte:
      result.clusters.add ClusterCell(startByte: widgets[wi].byteInLine,
                                      stopByte: widgets[wi].byteInLine,
                                      cells: widgets[wi].cells, column: col)
      col += widgets[wi].cells
      inc wi
    let text = line[cl.startByte ..< cl.stopByte]
    # `cellsOf` AND NOT `cl.cells`: a tab's width depends on the column it
    # begins at, and the widget moved that column. See the header.
    let w = cellsOf(text, col, policy)
    result.clusters.add ClusterCell(startByte: cl.startByte,
                                    stopByte: cl.stopByte, cells: w,
                                    column: col)
    col += w
  while wi < widgets.len:
    result.clusters.add ClusterCell(startByte: widgets[wi].byteInLine,
                                    stopByte: widgets[wi].byteInLine,
                                    cells: widgets[wi].cells, column: col)
    col += widgets[wi].cells
    inc wi
  result.width = col

proc inlaysOf*(s: DecorationSet; doc: string): seq[seq[InlayPlacement]] =
  ## Every inline widget in the set, resolved onto the line it sits on and
  ## ordered — by position, then by `LAW-D5`'s total order for the ones that
  ## share a position.
  ##
  ## A widget whose anchor is outside the document RAISES. It is the shape a
  ## decoration set that was not mapped through the change set has, and
  ## answering "line 0" for it would put an inline value at the top of the file
  ## for as long as nobody looked.
  let starts = lineStartOffsetsOf(doc)
  let ls = documentLines(doc)
  result = newSeq[seq[InlayPlacement]](ls.len)
  for i in 0 ..< ls.len: result[i] = @[]
  var positions: seq[int] = @[]
  for d in s.payloads:
    if d.payload.kind != dkInlineWidget: continue
    var seen = false
    for p in positions:
      if p == d.value.fromAnchor.pos: seen = true
    if not seen: positions.add d.value.fromAnchor.pos
  for pos in positions:
    if pos < 0 or pos > doc.len:
      raise newException(InlayError,
        "inlaysOf: an inline widget at document offset " & $pos &
        " in a document of " & $doc.len & " bytes. A decoration set is " &
        "mapped through the change set before it is projected; this one was " &
        "not.")
    var line = 0
    for i in 0 ..< ls.len:
      if pos >= starts[i] and pos <= starts[i] + ls[i].len: line = i
    for d in s.sortedAtPosition(pos):
      if d.payload.kind != dkInlineWidget: continue
      result[line].add inlayPlacement(pos - starts[line], d.payload.cells,
                                      d.value.id, d.payload.inlineText)

proc inlayWrapCache*(doc: string; settings: WrapSettings;
                     s: DecorationSet): WrapCache =
  ## **THE PROJECTION, WITH THE WIDGETS IN IT.** Six lines, because the widgets
  ## are ordinary line content and `wrap.wrapCacheOfMetrics` is the seam.
  let placements = inlaysOf(s, doc)
  var ms: seq[LineMetrics] = @[]
  for i, line in documentLines(doc):
    ms.add inlayLineMetrics(line, settings.policy, placements[i])
  wrapCacheOfMetrics(doc, settings, ms)

proc updateInlayCache*(oldDoc: string; cs: ChangeSet; newDoc: string;
                       settings: WrapSettings; s: DecorationSet;
                       st: var MapStats): (WrapCache, DecorationSet) =
  ## **THE DECORATED CACHE MOVED ONTO A NEW DOCUMENT.** The decoration set goes
  ## through §8.0's chunk-skipping mapping first and the projection is taken
  ## again; `wrap.updateWrapCache` REFUSES a decorated cache for the reason
  ## stated at its own `raise`.
  ##
  ## **This is a full re-projection and it is not the splice `LAW-C6` grades.**
  ## Stated here rather than implied: PLAT-27 bought an incremental wrap and
  ## the decorated path does not use it, because the decoration set's own
  ## mapping is what decides which lines moved and the two invalidations have
  ## not been composed. The cost is O(document) per edit on a decorated
  ## projection; the correctness is not in question, the performance is, and it
  ## is recorded as PLAT-28's own residual rather than left for a later
  ## milestone to discover.
  if cs.length != oldDoc.len:
    raise newException(InlayError,
      "updateInlayCache: the change set is over a document of " & $cs.length &
      " bytes and the old document has " & $oldDoc.len)
  if cs.newLength != newDoc.len:
    raise newException(InlayError,
      "updateInlayCache: the change set produces " & $cs.newLength &
      " bytes and the new document has " & $newDoc.len)
  let moved = mapDecorationSet(s, cs, st)
  (inlayWrapCache(newDoc, settings, moved), moved)

func blockRowsOf*(s: DecorationSet; doc: string; line: int): BlockRows =
  ## §8.1's block widgets, as a per-line row count. `bpAmongInline` contributes
  ## to NEITHER, and that is the variant meaning what it says: a block widget
  ## deliberately ordered among the inline ones is asking to be laid out with
  ## them, not to be given rows of its own.
  let starts = lineStartOffsetsOf(doc)
  let ls = documentLines(doc)
  if line < 0 or line >= ls.len:
    raise newException(InlayError,
      "blockRowsOf: line " & $line & " of a document with " & $ls.len &
      " line(s)")
  for d in s.payloads:
    if d.payload.kind != dkBlockWidget: continue
    let pos = d.value.fromAnchor.pos
    if pos < starts[line] or pos > starts[line] + ls[line].len: continue
    case d.payload.placement
    of bpAbove: result.above += d.payload.rows
    of bpBelow: result.below += d.payload.rows
    of bpAmongInline: discard
