## wrap.nim — PLAT-27: the coordinate model under soft wrap.
##
## Owns: Editor-ViewModel.md §9. Everything above this module — `gj`/`gk`,
## screen-line `0`/`$`, a gutter that has to decide which display rows carry a
## line number, a renderer that has to paint rows — asks THIS module and never
## re-derives wrapping for itself.
##
## =========================================================================
## THE DECISION §5 AND §9 DISAGREED ABOUT, SETTLED: WRAP CONFIGURATION IS A
## PARAMETER TO A PROJECTION, NOT A FIELD OF THE STATE
## =========================================================================
##
## Editor-ViewModel.md §5 said `EditorState` carries the wrap configuration;
## §3.1 and §9 said the per-renderer settings *"enter as parameters"*. Those
## are two designs and they collide at one place: **two front-ends showing one
## document at different widths**, which is PLAT-34. A shared state holding one
## wrap column fails at the moment the second front-end attaches.
##
## **The settled answer is the parameter.** The document, the selection and the
## decorations are the shared state; display geometry is a PROJECTION taken per
## renderer at that renderer's own settings. `WrapSettings` is an argument to
## every routine here and is a field of `WrapCache`, which is a per-renderer
## value — never of `EditorState`.
##
## That keeps §9's claim intact (display questions are answered in the model,
## so `gj` is written once) while dropping the implication that one answer
## serves everyone. §9's claim is about WHERE the code lives, not about how
## many answers there are.
##
## **The cost, stated rather than discovered:**
##
## 1. **The cache cannot live in the shared state either**, because it is keyed
##    by the settings. Each front-end owns a `WrapCache` and each must be handed
##    the change set — so invalidation is N calls rather than one, and a
##    front-end that forgets one holds a stale projection. That is mitigated
##    and not merely noted: `WrapCache` records the BYTE LENGTH of the document
##    it was built from and `refuseStaleCache` RAISES when it is asked about a
##    different one. It is a guard, not a proof — two documents of the same
##    byte length pass it, and the guard checks the LENGTH ONLY even though the
##    cache also carries a line count, because a second cheap field buys
##    nothing a fingerprint would not buy properly. The residual is stated here
##    rather than in a comment nobody reaches. `LAW-C6` is the real check.
## 2. **Every display-dependent operation grows a settings parameter.** The
##    vocabulary census in Editor-Model-Conformance-Suite.md §7.2 measured that
##    set at **24 of 224** operations, so the widening is bounded and known
##    rather than open-ended. The twelve display motions below are the ones this
##    milestone adds.
## 3. **Two projections of one document can disagree about a display row and
##    both be right.** Anything that names a display row across a process
##    boundary — a scroll sync, a shared cursor — must carry the settings with
##    it or name a LOGICAL position instead. PLAT-33's convergence is over
##    logical positions for exactly this reason, which is the same answer
##    arrived at from the other end.
##
## =========================================================================
## TAB STOPS BELONG TO THE LOGICAL LINE, AND WRAPPING PARTITIONS THE CELLS
## =========================================================================
##
## A tab advances to the next multiple of `tabSize` **counted from the start of
## the logical line**, and soft wrap then cuts the resulting cell sequence into
## rows. The alternative — restarting the tab grid at each display row — makes a
## cluster's width depend on where the wrap put it, which makes the wrap depend
## on itself for any line whose first row ends inside a run of tabs.
##
## So the width of every cluster is fixed before any row boundary is chosen, and
## `DisplayRow.startColumn` carries the logical-line column the row begins at,
## which is what makes a display column convertible back into a line column by
## one addition.
##
## **`tabSize = 0` is a real setting and it means "a tab is a cluster like any
## other".** `clusterDisplayWidth` reports a tab as 0 cells — it is a control
## character, not a glyph — so `tabSize = 0` is exactly `isonim-tui`'s model,
## and it is what `DIFF-2` runs at so that the model and the terminal are
## compared on WRAPPING rather than on tab policy. The tab policy has its own
## matrix (tab sizes {2, 4, 8} x four wrap columns over the two class-8
## documents), and the suite asserts two-sidedly that at `tabSize = 4` the model
## and the terminal DISAGREE on exactly the tab-bearing documents — a `DIFF-2`
## that passed because both sides ignored tabs would be §7b's negative control
## wearing a comparison.
##
## =========================================================================
## THE WIDTH FUNCTION IS THE PURE `func`, NEVER THE THREADVAR OVERLOAD
## =========================================================================
##
## `isonim_tui/text/width` exports both `func clusterDisplayWidth(cluster,
## ambiguous)` and a `proc` overload that reads a `threadvar`. Only the `func`
## is called here. A model whose answer depended on a global would make
## `LAW-C5`'s two-sided arm a test of process state, and would make two
## projections at two policies impossible in one process — which is the same
## thing the decision above is about.
##
## =========================================================================
## THE BIJECTION IS BETWEEN TWO SETS THAT HAD TO BE NAMED, AND ONE OF THEM IS
## SMALLER THAN "EVERY POSITION"
## =========================================================================
##
## `LAW-C1` is published as *"logical→display→logical is the identity, at every
## position"*. On `(row, column)` that is **false**, and it is false by a
## measured amount rather than in principle-only: a zero-width cluster occupies
## no cell, so it shares its column with whatever follows it. Two logical
## positions at one display column cannot both come back from that column.
##
## **THE COUNT IS POLICY-DEPENDENT, AND THE TWO FIGURES ARE NOT THE SAME ONE.**
## `clusterDisplayWidth` reports **7,352** clusters of the pinned corpus as
## zero-width, and that figure INCLUDES the corpus's 659 tabs, because a tab is
## a control character to the width function (see `TabsAsClusters` above). It is
## therefore the count at `tabSize = 0`. Every position the laws sweep is swept
## at `tabSize = 4`, where `cellsOf` expands a tab to a positive number of cells
## and a tab absorbs nothing. The clusters that actually collapse a column there
## number **6,693** — 7,352 less the 659 tabs — and at five wrap columns per
## document that is `6,693 x 5 =` **33,465** absorbed boundaries, which is the
## figure `LAW-C1` reports. Quoting 7,352 as the cause of 33,465 would be a
## measurement taken at a policy the law is not run at.
##
## The repair is to the statement, with the measurement beside it
## (Verification-Harness-Traps §36 — repair the assertion, never the killer),
## and it is recorded in Editor-Model-Conformance-Suite.md §3.3a. What this
## module provides, and what the suite asserts:
##
## * `toDisplay` is **total** over every byte position of every line, including
##   positions inside a cluster: a byte inside a cluster answers with the
##   cluster's own column. That is deliverable 2's *"the answer for a position
##   that is not a cluster boundary"*.
## * `toLogical` is **total** over every `(row, column)` with `0 <= column <=
##   row.width`, and always returns a cluster boundary.
## * The two are **mutually inverse on a bijection that is stated as one**:
##   `columnCanonical` logical positions — cluster boundaries that are not
##   followed by a zero-width cluster sharing their column — against canonical
##   display positions that are cluster boundaries. The suite asserts the two
##   CARDINALITIES are equal, per document, per wrap column, which is what makes
##   it a bijection claim rather than two round-trip claims.
##
## The arithmetic that makes the cardinalities checkable without running either
## direction, and which the suite uses as an independent derivation:
##
##     canonical display positions in a line  == line display width + 1
##     of which are cluster boundaries        == positive-width clusters + 1
##     the rest are interior cells of wide clusters
##
## and the first of those is independent of the wrap column, which is `LAW-C4`'s
## partition claim in a second form.

import std/[algorithm, options]

import isonim_tui/text/width as widthMod

import ./change_set
import ./selection
import ./selection_ops
import ./text_store

export selection, selection_ops, text_store
export widthMod.AmbiguousWidth   ## the enum, and with it `awNarrow`/`awWide`

type
  WrapSettings* = object
    ## **THE PER-RENDERER SETTINGS, AND THEY ARE A PARAMETER.** See the header:
    ## this object is never a field of `EditorState`.
    wrapColumn*: int
      ## Cells per display row. `0` or negative means no soft wrap, and then a
      ## display row IS a logical line — which is the configuration the TUI runs
      ## today, and the one under which every display motion below degenerates
      ## into its PLAT-26 logical counterpart.
    policy*: ColumnPolicy
      ## `tabSize` and the ambiguous-width policy, reused from PLAT-26 rather
      ## than re-declared: a second object with the same two fields is a second
      ## place for a default to drift.

  ClusterCell* = object
    ## One grapheme cluster of one logical line, with the cells it occupies and
    ## the logical-line column it begins at. Computed once per (line, policy)
    ## and reused at every wrap column — `rewrap` below is the reason that
    ## matters.
    startByte*: int   ## byte offset WITHIN the line
    stopByte*: int
    cells*: int
    column*: int      ## logical-line display column of `startByte`

  LineMetrics* = object
    clusters*: seq[ClusterCell]
    byteLen*: int
    width*: int       ## the column the line ends at

  DisplayRow* = object
    ## One row a renderer paints. Byte offsets are WITHIN the logical line, not
    ## document offsets, so a row survives an edit on another line unchanged —
    ## which is what makes the cache splice below a splice rather than a
    ## renumbering.
    line*: int
    startByte*, endByte*: int
    startColumn*: int   ## logical-line column this row begins at
    width*: int         ## cells

  DisplayPos* = object
    row*: int       ## GLOBAL display row index, 0-based
    column*: int    ## cells from the row's left edge

  WrapCache* = object
    ## The projection of one document at one renderer's settings.
    ##
    ## **It is invalidated by change set, never recomputed** — Editor-ViewModel
    ## §9 names the cost it exists to remove: `allDisplayRows` re-wraps the
    ## whole document on every call and five entry points call it.
    settings: WrapSettings
    metrics: seq[LineMetrics]
    rows: seq[seq[DisplayRow]]
    rowBase: seq[int]     ## len == metrics.len + 1; rowBase[i] is line i's first global row
    lineStart: seq[int]   ## len == metrics.len; the DOCUMENT offset each line begins at
    docLen: int
    lineCount: int
    hasWidgets: bool
      ## Whether any line's metrics carry a cluster of ZERO bytes and positive
      ## cells — which is what PLAT-28's `inlay.nim` injects and what nothing
      ## a segmenter produces can be. It exists for exactly one reason:
      ## `updateWrapCache` recomputes a touched line's metrics FROM THE TEXT,
      ## so splicing a decorated cache would silently drop the widgets on the
      ## edited lines. It RAISES instead (§36a) and names the routine that
      ## does it properly.

  GutterFacts* = object
    ## §9's *"which display rows of a wrapped logical line carry a line number
    ## is a RENDERING POLICY, and the model supplies the facts it is decided
    ## from"*. The model states the facts; it takes no view.
    line*: int
    rowInLine*: int       ## 0 for the first row of the logical line
    rowsInLine*: int
    isContinuation*: bool ## `rowInLine > 0`

  DisplayMotion* = enum
    ## The four motions that are defined over DISPLAY lines and are therefore
    ## unimplementable at the model layer unless the model owns wrapping.
    dispRowUp            ## Vim `gk`
    dispRowDown          ## Vim `gj`
    dispRowStart         ## screen-line `0`
    dispRowEnd           ## screen-line `$`

  DisplayForm* = enum
    ## The three forms each motion takes. Vim's own three: normal mode moves,
    ## visual mode extends, operator-pending yields the span crossed.
    formMove
    formExtend
    formSpan

  DisplayOp* = object
    motion*: DisplayMotion
    form*: DisplayForm

  DisplayCtx* = object
    ## Everything a display motion needs that is not the range.
    doc*: string
    store*: TextStore
    cache*: WrapCache
    boundaries*: seq[int]   ## document-wide cluster boundaries, PLAT-26's
    settings*: WrapSettings

  WrapError* = object of ValueError

const
  DisplayMotionCount* = ord(high(DisplayMotion)) - ord(low(DisplayMotion)) + 1
  DisplayFormCount* = ord(high(DisplayForm)) - ord(low(DisplayForm)) + 1
  DisplayOpCount* = DisplayMotionCount * DisplayFormCount
    ## **TWELVE, DERIVED FROM TWO ENUMS.** The milestone's floor multiplies it
    ## by three wrap columns; §10.4's third rule says a sweep's multiplier must
    ## be an asserted cardinality rather than a round number, and this is the
    ## cardinality it is asserted against.

  TabsAsClusters* = 0
    ## The `tabSize` at which a tab is an ordinary zero-width cluster — the
    ## terminal's model. Named rather than spelled `0` at the call sites, so a
    ## reader of `DIFF-2` sees a decision instead of a magic number.

func displayOps*(): seq[DisplayOp] =
  ## The twelve, enumerated. **An enumeration, not a draw** — §36's third rule:
  ## an arm whose kill depends on which operation the seed happened to pick is
  ## an arm that is sometimes a survivor.
  result = @[]
  for m in DisplayMotion:
    for f in DisplayForm:
      result.add DisplayOp(motion: m, form: f)

func `$`*(op: DisplayOp): string =
  $op.motion & "/" & $op.form

func `==`*(a, b: DisplayRow): bool =
  a.line == b.line and a.startByte == b.startByte and a.endByte == b.endByte and
    a.startColumn == b.startColumn and a.width == b.width

func `$`*(r: DisplayRow): string =
  "row(line " & $r.line & " bytes [" & $r.startByte & "," & $r.endByte &
    ") col " & $r.startColumn & " w " & $r.width & ")"

func `==`*(a, b: DisplayPos): bool = a.row == b.row and a.column == b.column

func `$`*(d: DisplayPos): string = "(" & $d.row & "," & $d.column & ")"

func wrapSettings*(wrapColumn: int; tabSize = 4;
                   ambiguous = awNarrow): WrapSettings =
  WrapSettings(wrapColumn: wrapColumn,
               policy: ColumnPolicy(tabSize: tabSize, ambiguous: ambiguous))

# ===========================================================================
# CELLS — the one place a cluster's width is decided
# ===========================================================================

func cellsOf*(cluster: string; atColumn: int; policy: ColumnPolicy): int =
  ## The cells `cluster` occupies when it begins at logical-line column
  ## `atColumn`.
  ##
  ## **A TAB IS THE ONLY CLUSTER WHOSE WIDTH DEPENDS ON WHERE IT SITS**, which
  ## is why this takes a column and `clusterDisplayWidth` does not. At
  ## `tabSize <= 0` a tab is not expanded at all and falls through to the width
  ## function like any other control character — see `TabsAsClusters`.
  if cluster == "\t" and policy.tabSize > 0:
    ((atColumn div policy.tabSize) + 1) * policy.tabSize - atColumn
  else:
    clusterDisplayWidth(cluster, policy.ambiguous)

proc lineMetrics*(line: string; policy: ColumnPolicy): LineMetrics =
  ## Segment one logical line once and record every cluster's cells and column.
  ##
  ## This is the only segmentation in the module. `LAW-C1` at every byte of a
  ## 67 KB corpus document would otherwise re-segment a line per position, and
  ## the JS lane is where that shows up first.
  result.byteLen = line.len
  result.clusters = @[]
  var col = 0
  for c in graphemeClusters(line):
    let w = cellsOf(c.text, col, policy)
    result.clusters.add ClusterCell(startByte: c.start, stopByte: c.stop,
                                    cells: w, column: col)
    col += w
  result.width = col

func wrapLine*(m: LineMetrics; line, wrapColumn: int): seq[DisplayRow] =
  ## One logical line's display rows, greedily.
  ##
  ## **A CLUSTER IS NEVER SPLIT**, which is the whole reason this is written
  ## over `LineMetrics` and not over bytes or cells. A cluster WIDER than the
  ## wrap column occupies a row of its own and overflows it — the alternative is
  ## to split it, and half a CJK ideograph is the defect the corpus exists to
  ## catch. `isonim-tui`'s `wrapLineToRows` reaches the same answer through an
  ## explicit branch; the two are compared row by row in `DIFF-2`.
  result = @[]
  var startByte = 0
  var startColumn = 0
  var cells = 0
  if wrapColumn > 0:
    for c in m.clusters:
      if cells > 0 and cells + c.cells > wrapColumn:
        result.add DisplayRow(line: line, startByte: startByte,
                              endByte: c.startByte, startColumn: startColumn,
                              width: cells)
        startByte = c.startByte
        startColumn = c.column
        cells = 0
      cells += c.cells
  else:
    cells = m.width
  # The tail row, and the ONLY row of a line that does not wrap. An empty line
  # produces exactly one row of width 0 — a document of N lines has at least N
  # rows, which is `LAW-C4`'s partition holding at its degenerate end.
  result.add DisplayRow(line: line, startByte: startByte, endByte: m.byteLen,
                        startColumn: startColumn, width: cells)

# ===========================================================================
# THE CACHE
# ===========================================================================

proc documentLines*(doc: string): seq[string] =
  ## `'\n'`-delimited, the same convention `TextStore` uses: `lineCount` is
  ## `newlineCount + 1` and a trailing newline means a final empty line. Spelled
  ## here rather than imported from `strutils.splitLines`, which also splits on
  ## a lone CR and would give this module a different line count from the store
  ## it must agree with (PLAT-24's `unrepresentable.tsv`, row 1).
  result = @[]
  var start = 0
  for i, ch in doc:
    if ch == '\n':
      result.add doc[start ..< i]
      start = i + 1
  result.add doc[start .. ^1]

proc rebuildBase(c: var WrapCache) =
  ## The two prefix sums, derived from the per-line data rather than carried
  ## alongside it. Derived, because a counter maintained beside a splice is the
  ## bookkeeping §36a's second rule is about.
  c.rowBase = newSeq[int](c.rows.len + 1)
  c.lineStart = newSeq[int](c.rows.len)
  var acc = 0
  var off = 0
  for i in 0 ..< c.rows.len:
    c.rowBase[i] = acc
    acc += c.rows[i].len
    c.lineStart[i] = off
    off += c.metrics[i].byteLen + 1   # the terminating '\n'
  c.rowBase[^1] = acc

func lineStartOffsetsOf*(doc: string): seq[int] =
  ## The DOCUMENT offset each logical line begins at, derived from
  ## `documentLines` so the line set is this module's rather than a second
  ## `split` with a different idea of what a line terminator is.
  ##
  ## The same accumulation `rebuildBase` performs over the metrics
  ## (`byteLen + 1` per line, the terminating newline included); exported
  ## because PLAT-28's `inlay.nim` has to place a decoration's DOCUMENT offset
  ## onto a line before it has a cache to ask.
  let ls = documentLines(doc)
  result = newSeq[int](ls.len)
  var off = 0
  for i in 0 ..< ls.len:
    result[i] = off
    off += ls[i].len + 1

proc wrapCacheOfMetrics*(doc: string; settings: WrapSettings;
                         metrics: seq[LineMetrics]): WrapCache =
  ## **THE PROJECTION, FROM METRICS SOMEBODY ELSE COMPUTED.** PLAT-28's seam,
  ## and it is one seam rather than a decoration parameter threaded through
  ## this module.
  ##
  ## Editor-ViewModel.md §8.3 claims an inline value is *"ordinary line
  ## content"* — it occupies columns, the wrap point moves, and the text after
  ## it reflows. If that claim is right then wrapping needs no knowledge of
  ## widgets at all: a widget is a cluster of zero bytes and W cells, and
  ## everything below this line — `wrapLine`, `toDisplay`, `toLogical`,
  ## `gutterFacts`, the twelve display motions — works on it unchanged.
  ##
  ## So this module gains a CONSTRUCTOR and not a feature, `viewmodel/editor/
  ## inlay.nim` supplies the metrics with the widgets already in them, and
  ## nothing here imports a decoration. **That is the architecture's claim
  ## arriving as a diff of about fifteen lines**, which is the measurement
  ## PLAT-28 exists to take.
  ##
  ## The metrics' byte lengths are CHECKED against the document rather than
  ## assumed, and a mismatch RAISES (§36a): `lineStart` is derived from
  ## `byteLen + 1` per line, so a metrics list that disagrees with the document
  ## would move every slice in the module by a plausible amount.
  let ls = documentLines(doc)
  if metrics.len != ls.len:
    raise newException(WrapError,
      "wrapCacheOfMetrics: " & $metrics.len & " line metrics for a document " &
      "of " & $ls.len & " line(s). Not repaired: the row index and the line " &
      "start offsets are both derived from this list.")
  for i in 0 ..< ls.len:
    if metrics[i].byteLen != ls[i].len:
      raise newException(WrapError,
        "wrapCacheOfMetrics: line " & $i & "'s metrics claim " &
        $metrics[i].byteLen & " bytes and the document has " & $ls[i].len &
        ". A widget adds CELLS and never BYTES; a metrics list whose byte " &
        "length moved is measuring a different document.")
  result.settings = settings
  result.docLen = doc.len
  # The metrics are stored first and then read back from `result`, and the
  # parameter is not named again below. A NEUTRAL REFACTOR, and recorded as one:
  # `metrics[i]` and `result.metrics[i]` are the same value here, on every
  # backend this tree builds — C, `nim js` and wasm32 through `emcc` were each
  # measured saying so. Deriving the rows from the field they are stored beside
  # is simply the shorter thing to read: the loop below and `result.metrics`
  # then name one object rather than two that happen to be equal.
  result.metrics = metrics
  result.rows = @[]
  for i in 0 ..< result.metrics.len:
    result.rows.add wrapLine(result.metrics[i], i, settings.wrapColumn)
    for cl in result.metrics[i].clusters:
      if cl.startByte == cl.stopByte and cl.cells > 0:
        result.hasWidgets = true
  result.lineCount = result.metrics.len
  result.rebuildBase()

proc initWrapCache*(doc: string; settings: WrapSettings): WrapCache =
  ## The full computation, with no decorations. `LAW-C6`'s oracle is this
  ## function; the incremental path below is the thing under test.
  ##
  ## It is the undecorated ARM of `wrapCacheOfMetrics` rather than a second
  ## copy of the loop — §30, and it is also `LAW-C7`'s negative control: *"with
  ## the widget removed and nothing else changed"* has to be the same code path
  ## or the two arms differ in more than the widget.
  var ms: seq[LineMetrics] = @[]
  for line in documentLines(doc):
    ms.add lineMetrics(line, settings.policy)
  wrapCacheOfMetrics(doc, settings, ms)

proc rewrap*(c: WrapCache; wrapColumn: int): WrapCache =
  ## The same document at a DIFFERENT wrap column, reusing the cluster metrics.
  ##
  ## **This is PLAT-34's shape in one function**: two front-ends, one document,
  ## two widths. It is here rather than in the suite because it is the operation
  ## the decision at the top of this file makes cheap, and a decision whose
  ## benefit has no call site is a decision nobody can price.
  result = c
  result.settings.wrapColumn = wrapColumn
  result.rows = @[]
  for i in 0 ..< c.metrics.len:
    result.rows.add wrapLine(c.metrics[i], i, wrapColumn)
  result.rebuildBase()

func settings*(c: WrapCache): WrapSettings = c.settings
func lineCount*(c: WrapCache): int = c.lineCount
func rowCount*(c: WrapCache): int = c.rowBase[^1]
func firstRowOf*(c: WrapCache; line: int): int = c.rowBase[line]
func rowsInLine*(c: WrapCache; line: int): int = c.rows[line].len
func metricsOf*(c: WrapCache; line: int): LineMetrics = c.metrics[line]
func lineStartOffset*(c: WrapCache; line: int): int = c.lineStart[line]

proc refuseStaleCache*(c: WrapCache; doc: string) =
  ## **A GUARD THAT RAISES, BECAUSE THE ALTERNATIVE IS A SILENT REPAIR**
  ## (Verification-Harness-Traps §36a). A cache handed a document it was not
  ## built from would otherwise answer plausibly and wrongly for as long as the
  ## two happened to have compatible shapes.
  ##
  ## Its residual is stated where it is, not where its result is quoted: a byte
  ## length is not a fingerprint, so two documents of the same length pass — and
  ## the line count the cache also holds is deliberately NOT added to the test,
  ## because a second cheap field narrows the gap without closing it and reads
  ## as though it had. Hashing every call would cost O(n) on a routine whose
  ## whole purpose is to avoid O(n). `LAW-C6` is the check that the cache
  ## CONTENT is right; this one is the check that the caller did not hand it the
  ## wrong book.
  if doc.len != c.docLen:
    raise newException(WrapError,
      "wrap cache: built from a document of " & $c.docLen &
      " bytes, asked about one of " & $doc.len &
      ". A projection is per renderer AND per document version; invalidate it " &
      "with the change set (`updateWrapCache`) rather than reusing it.")

func rowAt*(c: WrapCache; row: int): DisplayRow =
  ## The global row. Raises by name rather than clamping: every caller here
  ## derives the index from the cache itself, so an out-of-range value is a
  ## bookkeeping defect and a clamp would hide it (§36a).
  if row < 0 or row >= c.rowBase[^1]:
    raise newException(WrapError,
      "wrap cache: display row " & $row & " outside a document of " &
      $c.rowBase[^1] & " row(s)")
  let line = c.rowBase.upperBound(row) - 1
  c.rows[line][row - c.rowBase[line]]

func lineOfRow*(c: WrapCache; row: int): int =
  if row < 0 or row >= c.rowBase[^1]:
    raise newException(WrapError,
      "wrap cache: display row " & $row & " outside a document of " &
      $c.rowBase[^1] & " row(s)")
  c.rowBase.upperBound(row) - 1

func gutterFacts*(c: WrapCache; row: int): GutterFacts =
  ## §9's gutter deliverable. The model says which logical line a row belongs
  ## to, which row of that line it is, and how many there are; **it does not say
  ## which row carries the number**, because that is a rendering policy and a
  ## model that took a view would make the TUI's `softWrap = false` a constraint
  ## again instead of a choice.
  let line = c.lineOfRow(row)
  let idx = row - c.rowBase[line]
  GutterFacts(line: line, rowInLine: idx, rowsInLine: c.rows[line].len,
              isContinuation: idx > 0)

proc rowText*(c: WrapCache; doc: string; row: int): string =
  ## The bytes a renderer paints for `row`. `LAW-C4` concatenates these.
  ##
  ## Sliced out of the document through the cache's own line index rather than
  ## by splitting the document again: `LAW-C4` asks for every row of a 67 KB
  ## corpus document and an O(n) split per row would make the law a benchmark.
  c.refuseStaleCache(doc)
  let r = c.rowAt(row)
  let base = c.lineStart[r.line]
  doc[base + r.startByte ..< base + r.endByte]

# ===========================================================================
# INVALIDATION BY CHANGE SET — §9's second deliverable, and `LAW-C6`
# ===========================================================================

proc lineOfOffset(doc: string; offset: int): int =
  var n = 0
  let lim = min(offset, doc.len)
  for i in 0 ..< lim:
    if doc[i] == '\n': inc n
  n

proc updateWrapCache*(c: WrapCache; oldDoc: string; cs: ChangeSet;
                      newDoc: string): WrapCache =
  ## The cache, moved onto `newDoc`, recomputing **only the logical lines the
  ## change touched**.
  ##
  ## Lines above the first touched line keep their rows unchanged; lines below
  ## the last touched line keep their rows unchanged and move by whatever the
  ## line count changed by. Rows carry LINE-RELATIVE byte offsets precisely so
  ## that "unchanged" is literal rather than "unchanged after renumbering".
  ##
  ## `LAW-C6`'s published killer is *"skip invalidation for a region above the
  ## edit"*, and the region above an edit that is nonetheless invalidated by
  ## this function is **the part of the edit's own first line that precedes
  ## it**: an insert in the middle of a line re-wraps that line from its start,
  ## because a cluster added at column 40 moves every row boundary after it and
  ## a tab added anywhere moves the columns of everything after it on the line.
  ## The arm starts the recomputed span one line lower and that line keeps its
  ## stale rows.
  c.refuseStaleCache(oldDoc)
  if c.hasWidgets:
    # §36a AGAIN, AND THIS ONE IS A DROP RATHER THAN A CLAMP. A touched line's
    # metrics are recomputed FROM ITS TEXT below, and a widget is not in the
    # text — so splicing a decorated cache would quietly un-decorate exactly
    # the lines the user is editing, which is the one place a missing inline
    # value looks most like "there is nothing in scope here".
    raise newException(WrapError,
      "updateWrapCache: this cache carries inline widgets and the splice " &
      "recomputes a touched line's metrics from its text, which has no " &
      "widgets in it. Use `inlay.updateInlayCache`, which maps the decoration " &
      "set through the change set first and then re-projects.")
  if cs.length != oldDoc.len:
    raise newException(WrapError,
      "wrap cache: the change set is over a document of " & $cs.length &
      " bytes and the cache over one of " & $oldDoc.len)
  if cs.newLength != newDoc.len:
    raise newException(WrapError,
      "wrap cache: the change set produces " & $cs.newLength &
      " bytes and the new document has " & $newDoc.len)

  var loA = -1
  var hiA = -1
  var loB = -1
  var hiB = -1
  for ch in cs.changedRanges():
    if loA < 0 or ch.fromA < loA: loA = ch.fromA
    if hiA < 0 or ch.toA > hiA: hiA = ch.toA
    if loB < 0 or ch.fromB < loB: loB = ch.fromB
    if hiB < 0 or ch.toB > hiB: hiB = ch.toB
  if loA < 0:
    # The identity. Nothing moved, and re-wrapping would be the cost this
    # function exists to avoid.
    result = c
    result.docLen = newDoc.len
    return

  let newLines = documentLines(newDoc)
  let firstLine = lineOfOffset(oldDoc, loA)
  let lastOldLine = lineOfOffset(oldDoc, hiA)
  let lastNewLine = lineOfOffset(newDoc, hiB)

  result.settings = c.settings
  result.docLen = newDoc.len
  result.metrics = @[]
  result.rows = @[]
  # Above the edit: carried over byte for byte.
  for i in 0 ..< firstLine:
    result.metrics.add c.metrics[i]
    result.rows.add c.rows[i]
  # The touched span: recomputed.
  for i in firstLine .. lastNewLine:
    let m = lineMetrics(newLines[i], c.settings.policy)
    result.metrics.add m
    result.rows.add wrapLine(m, i, c.settings.wrapColumn)
  # Below the edit: carried over, with only the line index re-stamped.
  for i in (lastOldLine + 1) ..< c.metrics.len:
    let target = i + (lastNewLine - lastOldLine)
    result.metrics.add c.metrics[i]
    var rs = c.rows[i]
    for k in 0 ..< rs.len: rs[k].line = target
    result.rows.add rs
  result.lineCount = result.metrics.len
  if result.lineCount != newLines.len:
    # Unreachable by construction, and it RAISES rather than truncating: a
    # cache that quietly held a different number of lines from its document
    # would answer every question plausibly and every one of them wrongly.
    raise newException(WrapError,
      "wrap cache: the splice produced " & $result.lineCount &
      " lines and the document has " & $newLines.len)
  result.rebuildBase()

# ===========================================================================
# THE TWO MAPPINGS
# ===========================================================================

func clusterIndexAtOrBefore(m: LineMetrics; byteInLine: int): int =
  ## The index of the cluster containing `byteInLine`, or `-1` when the offset
  ## is the line's end (or the line is empty).
  if m.clusters.len == 0: return -1
  if byteInLine >= m.byteLen: return -1
  var lo = 0
  var hi = m.clusters.len - 1
  var best = 0
  while lo <= hi:
    let mid = (lo + hi) div 2
    if m.clusters[mid].startByte <= byteInLine:
      best = mid
      lo = mid + 1
    else:
      hi = mid - 1
  best

func columnOfByte*(m: LineMetrics; byteInLine: int): int =
  ## The logical-line display column at `byteInLine`. A byte that is NOT a
  ## cluster boundary answers with the column of the cluster it is inside —
  ## deliverable 2's *"the answer for a position that is not a cluster
  ## boundary"*, decided here and once.
  let i = clusterIndexAtOrBefore(m, byteInLine)
  if i < 0: m.width else: m.clusters[i].column

proc toDisplay*(c: WrapCache; pos: TextPos): DisplayPos =
  ## Logical → display. Total over every byte of every line.
  ##
  ## **A POSITION EXACTLY AT A WRAP BOUNDARY RESOLVES TO THE START OF THE
  ## FOLLOWING ROW**, never to the end of the preceding one. It has to resolve
  ## to one of the two or the map is not a function, and the start of the next
  ## row is the choice every editor makes because it is where the caret is
  ## painted. The end-of-row position of a non-final row is therefore NOT a
  ## canonical display position, and `isCanonicalDisplayPos` says so — which is
  ## what keeps `LAW-C2` a statement about a bijection rather than about a
  ## set with a duplicated member.
  if pos.line < 0 or pos.line >= c.metrics.len:
    raise newException(WrapError,
      "wrap: line " & $pos.line & " outside a document of " &
      $c.metrics.len & " line(s)")
  let m = c.metrics[pos.line]
  if pos.column < 0 or pos.column > m.byteLen:
    raise newException(WrapError,
      "wrap: byte column " & $pos.column & " outside line " & $pos.line &
      " of " & $m.byteLen & " byte(s)")
  let col = columnOfByte(m, pos.column)
  let rs = c.rows[pos.line]
  var idx = rs.len - 1
  for k in 0 ..< rs.len:
    if col < rs[k].startColumn + rs[k].width:
      idx = k
      break
  DisplayPos(row: c.rowBase[pos.line] + idx, column: col - rs[idx].startColumn)

proc toLogical*(c: WrapCache; d: DisplayPos): TextPos =
  ## Display → logical, and **it always returns a cluster boundary**.
  ##
  ## The answer for a column that falls INSIDE a wide cluster is that cluster's
  ## OWN start — the caret does not jump forward over a glyph because the
  ## pointer landed on its right-hand cell. The alternative is the cluster's
  ## END, which is `LAW-C2`'s published killer and which breaks the round trip
  ## at every cluster boundary rather than only at interior cells.
  ##
  ## The map stays monotone under this rule: over the columns of `"a漢b"` it
  ## answers bytes `0, 1, 1, 4`, which is non-decreasing — that is `LAW-C3`'s
  ## clause, and it is why "snap back" rather than "snap forward" is the choice
  ## that costs nothing.
  ##
  ## A run of zero-width clusters shares a column with what follows it, so this
  ## walks past them: the boundary returned for a column is the one a caret
  ## painted at that column would be at.
  let r = c.rowAt(d.row)
  if d.column < 0 or d.column > r.width:
    raise newException(WrapError,
      "wrap: display column " & $d.column & " outside row " & $d.row &
      " of width " & $r.width)
  let m = c.metrics[r.line]
  let target = r.startColumn + d.column
  for cl in m.clusters:
    if cl.startByte < r.startByte: continue
    if cl.startByte >= r.endByte: break
    if cl.column + cl.cells > target:
      return textPos(r.line, cl.startByte)
  textPos(r.line, r.endByte)

func isLastRowOfLine*(c: WrapCache; row: int): bool =
  let line = c.lineOfRow(row)
  row == c.rowBase[line] + c.rows[line].len - 1

func lastColumnOf*(c: WrapCache; row: int): int =
  ## **THE LAST COLUMN A CARET CAN OCCUPY ON `row`**, which is NOT always the
  ## row's width — and the difference is the whole of what a screen-line `$`
  ## means on a wrapped line.
  ##
  ## On the FINAL row of a logical line the end-of-text position belongs to that
  ## row, so the answer is the row's width. On a CONTINUING row the position one
  ## past the last cell is the same point as column 0 of the NEXT row (see
  ## `toDisplay`), so it is not a position of this row at all; the last position
  ## that IS one is the start of the row's last cluster.
  ##
  ## Found by running the motions rather than by reasoning about them: with `$`
  ## returning the row's width, `gj`-then-`g$` on a wrapped line reported the
  ## FOLLOWING row, and the sweep asserting *"a screen-line motion stays on its
  ## display row"* went red on nine of its twelve cells. Vim does the same
  ## thing for the same reason — `g$` lands ON the last character.
  let r = c.rowAt(row)
  if c.isLastRowOfLine(row): return r.width
  let m = c.metrics[r.line]
  var best = 0
  for cl in m.clusters:
    if cl.startByte < r.startByte: continue
    if cl.startByte >= r.endByte: break
    best = cl.column - r.startColumn
  best

func isCanonicalDisplayPos*(c: WrapCache; d: DisplayPos): bool =
  ## Whether `d` is the display space's own representative of its point. The
  ## end-of-row column of a NON-FINAL row is the same point as column 0 of the
  ## next row and is not canonical; every other `0 <= column <= width` is.
  if d.row < 0 or d.row >= c.rowBase[^1]: return false
  let r = c.rowAt(d.row)
  if d.column < 0 or d.column > r.width: return false
  if d.column < r.width: return true
  let line = c.lineOfRow(d.row)
  d.row == c.rowBase[line] + c.rows[line].len - 1

proc isDisplayClusterBoundary*(c: WrapCache; d: DisplayPos): bool =
  ## Whether a cluster begins exactly at `d`. `LAW-C2` is the identity only
  ## here, and the COUNT of these is asserted separately — a model that called
  ## every display column a boundary would pass the round trip and be wrong
  ## about the thing the round trip exists to check.
  let r = c.rowAt(d.row)
  if d.column < 0 or d.column > r.width: return false
  let p = c.toLogical(d)
  let m = c.metrics[r.line]
  columnOfByte(m, p.column) == r.startColumn + d.column

func columnCanonical*(m: LineMetrics; byteInLine: int): int =
  ## The logical space's own representative of the point `byteInLine` sits at:
  ## the first byte offset at or after it that is a cluster boundary with a
  ## COLUMN OF ITS OWN.
  ##
  ## Derived here from the cluster table, deliberately WITHOUT calling either
  ## mapping, so that the law comparing `toLogical(toDisplay(p))` against it is
  ## two derivations rather than one function agreeing with itself
  ## (Verification-Harness-Traps §30).
  for cl in m.clusters:
    if cl.stopByte <= byteInLine: continue
    if cl.cells > 0: return cl.startByte
  m.byteLen

# ===========================================================================
# DISPLAY-LINE MOTIONS — §9's reason the model owns wrapping
# ===========================================================================

func displayGoalOf(ctx: DisplayCtx; r: SelectionRange; at: DisplayPos): int =
  ## The goal column a vertical DISPLAY motion should use: the one the range
  ## carries, or the display column its head is at now.
  ##
  ## **`goalColumn` IS A TAB-EXPANDED COLUMN, NOT A PIXEL OFFSET** — §7 calls
  ## that *"the single largest simplification monospace buys us"*, and PLAT-26
  ## already put the field on `SelectionRange`. What this milestone settles is
  ## its UNIT: **the tab-expanded column within the row the motion steps
  ## between**. For a logical motion the row is the whole logical line, which is
  ## PLAT-26's meaning; for a display motion it is the display row. At
  ## `wrapColumn <= 0` a display row IS a logical line and the two coincide
  ## exactly, which the suite asserts rather than asserting the wording.
  ##
  ## **THE RESIDUAL THIS HEADER CARRIED IS CLOSED, AND THE CLOSURE IS PLAT-30's
  ## DESIGN DECISION RATHER THAN A CHANGE TO THIS FUNCTION.** Until 2026-09-19
  ## the paragraph here read: *"a caret whose goal was set by `opMoveLineUp` and
  ## then stepped with `gj` across a WRAPPED line reads a line-relative column
  ## as a row-relative one … it is not taken here"*, and beneath it *"PLAT-28
  ## inherits a worry, not a measurement"*. Both sentences were true when they
  ## were written and both were **stale from the day PLAT-30 landed**.
  ##
  ## What closed it: the residual exists only if the two motion families carry
  ## goal columns in two units. They do not. `operations.verticalLogical` —
  ## which is what `move-line-up` / `move-line-down` are — takes its goal from
  ## `cache.toDisplay(...).column`, and `operations.displayMotion` delegates to
  ## `landingOf`, which takes its goal from THIS function. Both are a
  ## `DisplayPos.column`: cells from the left edge of the caret's DISPLAY ROW.
  ## A goal set by one family and read by the other is therefore in the unit the
  ## reader expects, at every wrap column and not only at `0`.
  ##
  ## §2.2 A's rows for `line-up` / `line-down` are marked display-dependent AND
  ## say *"logical lines"*, and that pair is only satisfiable under this
  ## reading — which is why the decision was PLAT-30's to take and is recorded
  ## in its status with the alternative it refused.
  ##
  ## **WHAT IS STILL TRUE AND IS NOT A RESIDUAL.** `SelectionRange.goalColumn`
  ## does not carry its unit in its TYPE, so the units coincide by construction
  ## rather than by construction being impossible to break. Making it
  ## unbreakable changes PLAT-26's published shape and is still not taken here.
  ## The difference between that sentence and the one it replaces is the
  ## difference between "a type could say this" and "the two families disagree",
  ## and only the second is a defect.
  ##
  ## **NO NUMBER IS CLAIMED FOR ANY OF IT** (§36b). The old paragraph was
  ## careful to say the residual was unmeasured; this one does not replace an
  ## unmeasured worry with an unmeasured reassurance. The claim above is a
  ## SOURCE fact — two call sites, one unit — and `test_editor_keymap_laws.nim`
  ## asserts it as one, by requiring both goal-producing sites to read a
  ## `DisplayPos.column`.
  if r.goalColumn.isSome: r.goalColumn.get else: at.column

proc initDisplayCtx*(doc: string; settings: WrapSettings): DisplayCtx =
  DisplayCtx(doc: doc, store: toTextStore(doc),
             cache: initWrapCache(doc, settings),
             boundaries: clusterBoundariesOf(doc), settings: settings)

proc offsetOfDisplay(ctx: DisplayCtx; d: DisplayPos): int =
  ## A display position as a document byte offset, snapped to a document
  ## cluster boundary.
  ##
  ## The snap is not a repair: `toLogical` returns a boundary of its LINE, and
  ## for a line ending `\r\n` the line's last boundary is the offset between the
  ## CR and the LF in the DOCUMENT — PLAT-26's `lineEnd` found the same thing
  ## and resolved it the same way. Clamping against the document's boundaries is
  ## what makes "a cluster boundary of the line" and "a cluster boundary of the
  ## document" one claim.
  let p = ctx.cache.toLogical(d)
  let raw = ctx.store.offsetOf(p)
  let i = ctx.boundaries.upperBound(raw)
  if i <= 0: 0 else: ctx.boundaries[i - 1]

proc displayPosOfOffset(ctx: DisplayCtx; offset: int): DisplayPos =
  ctx.cache.toDisplay(ctx.store.posOf(offset))

proc landingOf*(ctx: DisplayCtx; motion: DisplayMotion;
                r: SelectionRange): tuple[offset: int; goal: Option[int]] =
  ## Where `motion` puts the head, and what goal column the result carries.
  ##
  ## The vertical pair PRESERVE the goal and the two horizontal ones CLEAR it —
  ## the reference's rule, and the only one under which a goal column is a
  ## statement about vertical motion rather than about motion in general.
  let here = ctx.displayPosOfOffset(r.head)
  case motion
  of dispRowUp, dispRowDown:
    let goal = displayGoalOf(ctx, r, here)
    let delta = if motion == dispRowUp: -1 else: 1
    # **CLAMPING TO THE DOCUMENT'S FIRST AND LAST ROW IS SPECIFIED BEHAVIOUR**,
    # which is the one case §36a admits a clamp for: `gj` on the last row is a
    # no-op in every editor, and it has a name.
    let target = clamp(here.row + delta, 0, ctx.cache.rowCount - 1)
    # **A GOAL PAST THE TARGET ROW'S END LANDS AT ITS END — SPECIFIED, NAMED,
    # AND THE GOAL ITSELF IS NOT TOUCHED.** That last clause is `LAW-S5`'s
    # published killer (*"recompute the goal from the landed column"*) not being
    # committed here: the goal returned below is the one that came in.
    let col = min(goal, ctx.cache.lastColumnOf(target))
    (ctx.offsetOfDisplay(DisplayPos(row: target, column: col)), some(goal))
  of dispRowStart:
    (ctx.offsetOfDisplay(DisplayPos(row: here.row, column: 0)), none(int))
  of dispRowEnd:
    (ctx.offsetOfDisplay(
       DisplayPos(row: here.row, column: ctx.cache.lastColumnOf(here.row))),
     none(int))

proc applyDisplayOp*(ctx: DisplayCtx; op: DisplayOp;
                     r: SelectionRange): SelectionRange =
  ## **THE PER-RANGE FUNCTION**, the same shape PLAT-26's `applyRangeOp` has and
  ## for the same reason: one range in, one range out, no `EditorSelection` in
  ## the signature, so multi-cursor is the absence of a special case here too.
  let landed = ctx.landingOf(op.motion, r)
  case op.form
  of formMove:
    caret(landed.offset, assocBefore, none(BidiLevel), landed.goal)
  of formExtend:
    spanRange(r.anchor, landed.offset, landed.goal)
  of formSpan:
    spanRange(r.head, landed.offset, landed.goal)

proc runDisplayOp*(ctx: DisplayCtx; op: DisplayOp;
                   sel: EditorSelection): EditorSelection =
  ## The whole set. No branch anywhere below asks how many ranges there are.
  if sel.rangeCount == 0:
    raise newException(WrapError,
      "runDisplayOp: the zero-value selection holds no ranges")
  var xs: seq[SelectionRange] = @[]
  for r in sel: xs.add ctx.applyDisplayOp(op, r)
  editorSelection(xs, sel.primaryIndex)
