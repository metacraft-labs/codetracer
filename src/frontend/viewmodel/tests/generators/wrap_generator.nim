## wrap_generator.nim — PLAT-27's POPULATION, which is a declared cross product
## rather than a sample, and is a subject like any other.
##
## NOT-A-TEST-LANE-FILE: the population's constructor and its classifier. The
## assertions are in `../unit/test_editor_wrap_laws.nim`.
##
## =========================================================================
## THE DECLARED MATRIX LEFT A THIRD OF THE CORPUS UNWRAPPED, AND THAT WAS
## MEASURED RATHER THAN SUPPOSED
## =========================================================================
##
## Editor-Model-Conformance-Suite.md §6 declares the population as *"every
## corpus document x every wrap column in the matrix x every position"*, with
## the matrix `{20, 40, 80, 120}`. Building it and then COUNTING the realised
## classes — Verification-Harness-Traps §34's own remedy — produced this:
##
##     of the 72 declared cells, 35 have no wrapped line at all,
##     and SIX documents (c1/c2/c3/c4/c5/c6-short) never wrap at ANY
##     column of the declared matrix, because their widest line is
##     narrower than 20 cells.
##
## For those six, `LAW-C1` … `LAW-C4` are true because a display row is a
## logical line — which is precisely the trap: *"a generator producing only
## documents narrower than the wrap column, so no line ever wraps and every
## coordinate law is trivially true"*. Every law stays green and the milestone's
## subject is never exercised on a third of its corpus.
##
## **THE REPAIR IS A FIFTH COLUMN PER DOCUMENT, DERIVED FROM THE DOCUMENT.**
## `witnessWrapColumn` is `max(2, widestLine div 3)` and every document is
## asserted to realise **all three** of the wrapped, exactly-at-boundary and
## multi-row classes there. The declared matrix is not touched — the floor's
## `18 x 4` term still reads off it — and the population is the declared cross
## product PLUS eighteen witness cells, which is 90.
##
## The divisor is 3 and not 2 because 2 was tried and measured: **ten of the
## eighteen documents realised no multi-row line at it**, and an eleventh
## (`c5-cjk-long`) realised no exactly-at-boundary row — so eleven of eighteen
## failed to witness all three classes. At 3 all eighteen do. A constant chosen
## without that run would be a population that LOOKED repaired, which is the
## same defect one level up.
##
## =========================================================================
## THE CLASSIFIER IS NOT THE CONSTRUCTOR
## =========================================================================
##
## §34's third rule. `classifyCell` reads a built `WrapCache` back and says what
## it FOUND; nothing here labels its own output. A generator agreeing with
## itself is invisible to a histogram, in principle.

import std/strutils

import isonim_tui/widgets/textarea as tui

import ../../editor/wrap
import ../corpus/unicode_corpus

export wrap, unicode_corpus

type
  WrapClass* = enum
    ## The declared shape classes of a `(document, wrap column)` cell. They are
    ## a SET rather than an enumeration — `wcWrapped` and `wcMultiRow` co-occur
    ## by construction, and `wcExactBoundary` is orthogonal to both — and
    ## `wcNoWrap` is the one that excludes the others.
    wcNoWrap          ## every logical line is exactly one display row
    wcWrapped         ## some logical line spans two or more display rows
    wcExactBoundary   ## some display row ends EXACTLY on the wrap column
    wcMultiRow        ## some logical line spans three or more display rows

  WrapCell* = object
    ## One member of the population.
    docId*: string
    docIndex*: int
    column*: int
    isWitness*: bool   ## true for the per-document fifth column

const
  WrapMatrix* = [20, 40, 80, 120]
    ## §6's declared matrix, transcribed. It is ALSO read out of the spec at run
    ## time by `ci/test/editor-model-case-floor.sh PLAT-27`, so this is a cache
    ## of a published fact rather than a second source of it.

  WrapMatrixCount* = WrapMatrix.len
  TabSizes* = [2, 4, 8]
    ## §6's tab matrix, *"where the document's class makes tab size relevant"* —
    ## which is class 8, and the suite runs it there.
  TabSizeCount* = TabSizes.len
  WrapClassCount* = ord(high(WrapClass)) - ord(low(WrapClass)) + 1
  CorpusDocCount* = CorpusDocs.len
  WitnessDivisor* = 3
    ## See the header. Measured, not chosen.

proc widestLine*(c: WrapCache): int =
  result = 0
  for i in 0 ..< c.lineCount:
    let w = c.metricsOf(i).width
    if w > result: result = w

proc witnessWrapColumn*(c: WrapCache): int =
  ## The per-document fifth column. Derived from the document's own widest line,
  ## so it moves when the corpus does instead of being a constant that silently
  ## stops wrapping when a document is regenerated.
  max(2, c.widestLine div WitnessDivisor)

proc classifyCell*(c: WrapCache; column: int): set[WrapClass] =
  ## **THE CLASSIFIER.** It reads the built cache and reports what is there.
  ## Nothing in this file tells it what the cell was supposed to be.
  result = {}
  var anyWrapped = false
  for line in 0 ..< c.lineCount:
    let n = c.rowsInLine(line)
    if n >= 2:
      anyWrapped = true
      result.incl wcWrapped
    if n >= 3: result.incl wcMultiRow
    let base = c.firstRowOf(line)
    for k in 0 ..< n:
      if column > 0 and c.rowAt(base + k).width == column:
        result.incl wcExactBoundary
  if not anyWrapped: result.incl wcNoWrap

proc columnsFor*(c: WrapCache): seq[int] =
  ## The five columns of one document: the four declared, then its witness.
  ##
  ## The witness is appended rather than substituted, and it is never one of the
  ## four even by accident — if the derived value collides with a declared one
  ## the NEXT smaller column is taken, because a population of five cells that
  ## is really four would be §4b's partial set wearing the right label.
  result = @[]
  for w in WrapMatrix: result.add w
  var w = witnessWrapColumn(c)
  while w > 2 and w in result: dec w
  result.add w

iterator cells*(): WrapCell =
  ## The whole population, in a declared order. Eighteen documents, five columns
  ## each: **90 cells**, of which the first four of every document are §6's
  ## declared cross product.
  for i in 0 ..< CorpusDocs.len:
    let base = initWrapCache(CorpusDocs[i].text,
                             wrapSettings(WrapMatrix[0], 4, awNarrow))
    var k = 0
    for col in columnsFor(base):
      yield WrapCell(docId: CorpusDocs[i].id, docIndex: i, column: col,
                     isWitness: k >= WrapMatrixCount)
      inc k

proc cellCache*(cell: WrapCell; tabSize = 4;
                ambiguous = awNarrow): WrapCache =
  ## The cache one cell names. Built fresh rather than carried on the cell, so
  ## a caller that wants a different tab size or width policy gets one rather
  ## than a cached answer at the wrong settings.
  initWrapCache(CorpusDocs[cell.docIndex].text,
                wrapSettings(cell.column, tabSize, ambiguous))

proc corpusClassOf*(id: string): int =
  ## The corpus class (1 … 9) of a document, read off its id — the same
  ## derivation `unicode_corpus.docsOfClass` uses, spelled once here so a caller
  ## that needs the number does not re-parse the name.
  parseInt($id[1])

proc classOf*(cell: WrapCell): int = corpusClassOf(cell.docId)

# ---------------------------------------------------------------------------
# The reference wrap — a SECOND DERIVATION, for `LAW-C6`'s cache arm
# ---------------------------------------------------------------------------

proc referenceRows*(doc: string; settings: WrapSettings): seq[wrap.DisplayRow] =
  ## Every display row of `doc`, computed from scratch with no cache at all.
  ##
  ## This is `LAW-C6`'s oracle. It calls `initWrapCache`, which IS the full
  ## computation — the law compares the INCREMENTAL path (`updateWrapCache`)
  ## against the full one, so the oracle being the full computation is the
  ## claim, not a circularity. What would be circular is comparing
  ## `updateWrapCache` against itself, which is what a cache that validated its
  ## own entries would do.
  let c = initWrapCache(doc, settings)
  result = @[]
  for i in 0 ..< c.rowCount: result.add c.rowAt(i)

# ---------------------------------------------------------------------------
# The TUI's own wrap, reached through ITS types — `DIFF-2`'s second producer
# ---------------------------------------------------------------------------

func clusterIndexOfByte*(m: LineMetrics; byteInLine: int): int =
  ## The cluster index a byte offset sits at — the conversion `DIFF-2` needs
  ## because the model counts bytes and the terminal counts clusters.
  var i = 0
  for cl in m.clusters:
    if cl.startByte >= byteInLine: return i
    inc i
  m.clusters.len

proc terminalRowSpans*(doc: string; wrapColumn: int): seq[(int, int, int)] =
  ## `(line, startCluster, endCluster)` for every display row `isonim-tui`
  ## produces for `doc` at `wrapColumn`, in CLUSTER units, which is the unit its
  ## `DisplayRow` is in.
  ##
  ## **It drives the real widget**, not a copy of its algorithm: the import is
  ## `isonim_tui/widgets/textarea` and the call is `allDisplayRows`. A
  ## transcription here would be one producer wearing two hats, which is exactly
  ## what `DIFF-2` exists to avoid.
  ##
  ## The widget reads the THREADVAR width policy, and the suite sets it to
  ## `awNarrow` before calling — the model never does, which is the asymmetry
  ## §9 records and the reason the pure `func` overload is the one the model
  ## uses.
  ##
  ## The widget is built by assigning the three fields `wrapLineToRows` reads —
  ## `lines`, `width`, `softWrap`. It is NOT given a renderer, because
  ## `allDisplayRows` does not paint anything, and constructing one would drag a
  ## terminal into a suite that also compiles to JavaScript. The document is
  ## split the way the widget's own `setText` splits it (`doc.split('\n')`, with
  ## an empty document becoming one empty line), so the comparison is over the
  ## same line set the widget would have had.
  result = @[]
  var ls = doc.split('\n')
  if ls.len == 0: ls = @[""]
  let t = tui.TextAreaWidget(lines: ls, width: wrapColumn, softWrap: true,
                             tabSize: 4)
  for r in tui.allDisplayRows(t):
    result.add (r.lineIndex, r.startCluster, r.endCluster)
