## row_projection.nim — PLAT-28: `EditorRow` as a **projection** of the
## decoration model rather than a parallel structure.
##
## Owns: PLAT-28's fifth deliverable. *"`EditorRow` (the existing 435-line
## cross-front-end read model) re-expressed as a projection of this, not a
## parallel structure. Its `EditorMark`, `EditorPointer`, `EditorProvenance`,
## `EditorFlowState` and `EditorValue` are KEPT; what changes is where they
## come from."*
##
## So none of those five types is redefined here. `editor_rows.nim` stays the
## vocabulary — it is imported, not restated — and this module is the one place
## that says which decoration produces which field.
##
## =========================================================================
## WHY THIS MODULE IMPORTS NEITHER `wrap` NOR `inlay`, AND WHY THAT MATTERS
## =========================================================================
##
## `frontend/view_vocabulary/editor_surface.nim` is compiled by the
## `gpui-shell` lane, whose own note says it carries **no `isonim_tui` flags**
## and that *"a lane that carried the grammar archive and the tree-sitter link
## flags would be hiding a dependency the split exists to forbid"*.
## `viewmodel/editor/wrap.nim` and `selection.nim` both
## `import isonim_tui/text/width` — for the segmenter and the width table —
## so a projection that reached them could not be called from `editor_surface`
## without putting the terminal's text module into the GPUI front-end's
## compile.
##
## An `EditorRow` needs no display widths: its fields are a line number, text,
## a held flag and four vocabulary values. So the import chain here is
## `decoration -> range_set -> anchor -> change_set`, and every one of those
## imports `std` only. **The reflow half of this milestone (`inlay.nim`) is
## deliberately on the other side of that line**, and the split is what makes
## the projection callable from production.
##
## =========================================================================
## THE CLASS NAMES ARE A CODEC, IN BOTH DIRECTIONS, AND IT REFUSES
## =========================================================================
##
## A `dkLine` decoration carries a `lineClass` string, because `decoration.nim`
## is the GENERIC model and must not know what a breakpoint is. The mapping
## between those strings and `EditorMark` / `EditorPointer` / `EditorFlowState`
## therefore lives here, as total `case` expressions in both directions with no
## `else` on the enum side — so a new `EditorMark` member does not compile
## until it has been given a class name.
##
## The string side cannot be made total by the compiler, so it REFUSES: an
## unknown class raises rather than answering `emNone`. §36a — *"a guard that
## repairs a value silently must be a guard that RAISES"* — and the repair here
## would be the worst kind, because `emNone` is what a line with no breakpoint
## looks like, so a typo in a class name would present as a gutter that simply
## never shows anything.

import std/strutils

import ./decoration

import ../../../common/view_vocabulary/editor_rows

export decoration, editor_rows

type
  RowProjection* = object
    ## Everything a row needs that is not a decoration.
    doc*: string
    decorations*: DecorationSet
    viewportTop*: int
      ## 1-based, the same base `EditorRow.line` is in and the same base
      ## `EditorSurface.viewportTop` is in.
    viewportHeight*: int
      ## `0` means "every line", which is `editorSurfaceForProject`'s own
      ## convention rather than a second one.
    trailing*: TrailingLinePolicy
    heldFrom*, heldTo*: int
      ## The 1-based, inclusive range of lines whose text this projection
      ## actually holds. `0, 0` means all of them. A line outside it is
      ## `held = false` with `text = ""`, which is `source_vm.srkRequest` — and
      ## `editor_rows.EditorRow.held`'s own doc comment is why it is a separate
      ## field rather than an empty string: *"an empty-string default is
      ## exactly how a source pane silently renders blank"*.
    firstLine*: int
      ## The line number of `doc`'s FIRST line; `0` means `1`. A debug surface
      ## projects a WINDOW of a file — `SourceVM.visibleReads` is a contiguous
      ## run starting at `visibleFirstLine` — and its rows must carry the
      ## file's line numbers, not the window's. `viewportTop` is in the same
      ## numbering.
    requested*: seq[int]
      ## Lines, in `firstLine`'s numbering, whose text is NOT held — a window
      ## line the provider has not answered yet (`srkRequest`). Unlike
      ## `heldFrom`/`heldTo` it need not be a range: a window can hold lines
      ## 10–20 and 25–30 with the gap still in flight.

  TrailingLinePolicy* = enum
    ## What a projection does with the empty final line a file that ends in a
    ## newline produces.
    ##
    ## **AN ENUM AND NOT A `bool`**, because it is a decision two editors can
    ## disagree about and `editorSurfaceForProject`'s own comment says why it
    ## must not be taken per medium: *"done HERE rather than at each medium so
    ## three editors cannot disagree about how long a file is"*. A flag called
    ## `dropTrailing` reads as an implementation detail; this reads as the
    ## decision it is.
    tlpKeep
      ## Every `'\n'`-delimited line, including a final empty one. This is
      ## `text_store`'s and `wrap`'s convention and it is what the coordinate
      ## model counts.
    tlpDropFinalEmpty
      ## Drop the empty final line of a file that ends in a newline, which is
      ## the number a user counts and what `editorSurfaceForProject` reports.

  RowProjectionError* = object of ValueError

const
  MarkClassNone* = "ct-mark-none"
  MarkClassBreakpoint* = "ct-mark-breakpoint"
  MarkClassBreakpointDisabled* = "ct-mark-breakpoint-disabled"
  MarkClassTracepoint* = "ct-mark-tracepoint"

  PointerClassNone* = "ct-pointer-none"
  PointerClassInspection* = "ct-pointer-inspection"
  PointerClassExecution* = "ct-pointer-execution"

  FlowClassUnknown* = "ct-flow-unknown"
  FlowClassTaken* = "ct-flow-taken"
  FlowClassNotTaken* = "ct-flow-not-taken"

  InlineValueSeparator* = " = "
    ## The one separator, spelled once. `inlineTextOf` REFUSES a name
    ## containing it, which is what makes the first-occurrence split in
    ## `editorValueOf` exact rather than usually right.

func classOfMark*(m: EditorMark): string =
  case m
  of emNone: MarkClassNone
  of emBreakpoint: MarkClassBreakpoint
  of emBreakpointDisabled: MarkClassBreakpointDisabled
  of emTracepoint: MarkClassTracepoint

func markOfClass*(cls: string): EditorMark =
  if cls == MarkClassNone: emNone
  elif cls == MarkClassBreakpoint: emBreakpoint
  elif cls == MarkClassBreakpointDisabled: emBreakpointDisabled
  elif cls == MarkClassTracepoint: emTracepoint
  else:
    raise newException(RowProjectionError,
      "markOfClass: '" & cls & "' is not a declared mark class. Refused " &
      "rather than answered `emNone`: a line with no breakpoint is what " &
      "`emNone` means, so a typo would present as a gutter that never shows " &
      "anything.")

func classOfPointer*(p: EditorPointer): string =
  case p
  of eptNone: PointerClassNone
  of eptInspection: PointerClassInspection
  of eptExecution: PointerClassExecution

func pointerOfClass*(cls: string): EditorPointer =
  if cls == PointerClassNone: eptNone
  elif cls == PointerClassInspection: eptInspection
  elif cls == PointerClassExecution: eptExecution
  else:
    raise newException(RowProjectionError,
      "pointerOfClass: '" & cls & "' is not a declared pointer class.")

func classOfFlow*(f: EditorFlowState): string =
  case f
  of efsUnknown: FlowClassUnknown
  of efsTaken: FlowClassTaken
  of efsNotTaken: FlowClassNotTaken

func flowOfClass*(cls: string): EditorFlowState =
  if cls == FlowClassUnknown: efsUnknown
  elif cls == FlowClassTaken: efsTaken
  elif cls == FlowClassNotTaken: efsNotTaken
  else:
    raise newException(RowProjectionError,
      "flowOfClass: '" & cls & "' is not a declared flow class.")

func isMarkClass*(cls: string): bool =
  cls in [MarkClassNone, MarkClassBreakpoint, MarkClassBreakpointDisabled,
          MarkClassTracepoint]

func isPointerClass*(cls: string): bool =
  cls in [PointerClassNone, PointerClassInspection, PointerClassExecution]

func isFlowClass*(cls: string): bool =
  cls in [FlowClassUnknown, FlowClassTaken, FlowClassNotTaken]

func inlineTextOf*(v: EditorValue): string =
  ## An `EditorValue` as the text an inline widget shows.
  if v.name.contains(InlineValueSeparator):
    raise newException(RowProjectionError,
      "inlineTextOf: the name '" & v.name & "' contains the separator '" &
      InlineValueSeparator & "'. Refused rather than escaped: the decode is a " &
      "split at the FIRST separator, and a name containing one would make the " &
      "round trip silently wrong for exactly the values whose names are odd.")
  v.name & InlineValueSeparator & v.value

func editorValueOf*(text: string): EditorValue =
  let i = text.find(InlineValueSeparator)
  if i < 0:
    raise newException(RowProjectionError,
      "editorValueOf: '" & text & "' carries no '" & InlineValueSeparator &
      "'. An inline widget that is not an inline VALUE has no name to report, " &
      "and inventing one would put a row's `values` beside a widget that is " &
      "an inlay or a type hint.")
  EditorValue(name: text[0 ..< i],
              value: text[i + InlineValueSeparator.len .. ^1])

func valueWidth*(v: EditorValue): int =
  ## The cells an inline value occupies, as a BYTE count of its rendered text.
  ##
  ## **A byte count and not a display width, deliberately, and this is a
  ## limitation rather than a shortcut.** A display width would need
  ## `isonim_tui/text/width`, which is the import this module exists not to
  ## have (see the header). Every caller that needs cells for a *projection*
  ## computes them with `wrap.cellsOf` on the other side of that line;
  ## `PLAT28-DG2`'s neighbours in `decoration.FiledDecorationGaps` are where
  ## this is recorded.
  inlineTextOf(v).len

func decorationsForRow*(mark: EditorMark; pointer: EditorPointer;
                        flow: EditorFlowState;
                        values: openArray[EditorValue];
                        lineStart, lineLen, baseId: int): seq[Decoration] =
  ## **THE OTHER DIRECTION**: the decorations a row's four vocabulary values
  ## are. Exported because a producer builds them and because the round trip
  ## `decorationsForRow -> editorRowsOf` is what `LAW-D*`'s projection cases
  ## assert — a codec tested in one direction is a codec half tested.
  result = @[]
  var id = baseId
  if mark != emNone:
    result.add decoration(id, lineStart, lineStart,
                          linePayload(classOfMark(mark)))
    inc id
  if pointer != eptNone:
    result.add decoration(id, lineStart, lineStart,
                          linePayload(classOfPointer(pointer)))
    inc id
  if flow != efsUnknown:
    result.add decoration(id, lineStart, lineStart,
                          linePayload(classOfFlow(flow)))
    inc id
  for v in values:
    let text = inlineTextOf(v)
    result.add decoration(id, lineStart + lineLen, lineStart + lineLen,
                          inlineWidget(text.len, text))
    inc id

func projectionLines*(doc: string): seq[string] =
  ## `'\n'`-delimited, the same convention `text_store` and `wrap` use.
  ##
  ## **Spelled here and not imported**, and that is a cost paid deliberately:
  ## the only other declaration is `wrap.documentLines`, and importing `wrap`
  ## would put `isonim_tui/text/width` into the GPUI front-end's compile (see
  ## the header). The two are asserted EQUAL over every corpus document by
  ## `test_editor_decoration_laws.nim`, which imports both — §30's remedy when
  ## a second copy genuinely cannot be avoided is to grade the two copies
  ## against each other rather than to trust the comment.
  result = @[]
  var start = 0
  for i, ch in doc:
    if ch == '\n':
      result.add doc[start ..< i]
      start = i + 1
  result.add doc[start .. ^1]

func projectionLineStarts*(doc: string): seq[int] =
  let ls = projectionLines(doc)
  result = newSeq[int](ls.len)
  var off = 0
  for i in 0 ..< ls.len:
    result[i] = off
    off += ls[i].len + 1

proc projectionLinesFor*(doc: string; trailing: TrailingLinePolicy):
                        seq[string] =
  ## **THE ONE PLACE `TrailingLinePolicy` IS APPLIED** (PLAT-34 extracted it;
  ## §30b). `editorRowsOf` below calls it, and so does
  ## `view_vocabulary/editor_surface.editorSurfaceForDocument`, which used to
  ## carry its own `splitLines`-and-drop — a THIRD spelling of a decision this
  ## enum exists to make once. One function, two callers, and the mutation
  ## goes on the function, so an edit to the policy reddens both consumers at
  ## once rather than letting one of them go on agreeing with itself.
  result = projectionLines(doc)
  if trailing == tlpDropFinalEmpty and result.len > 1 and
     result[^1].len == 0 and doc.len > 0 and doc[^1] in {'\n', '\r'}:
    result.setLen(result.len - 1)

proc editorRowsOf*(p: RowProjection): seq[EditorRow] =
  ## **THE PROJECTION.** One pass over the viewport's lines, reading the
  ## decoration set for the four vocabulary fields.
  ##
  ## The order of `values` is the decoration set's own order at that position,
  ## which is `LAW-D5`'s total order applied (`sortedAtPosition`). Two inline
  ## values on one line therefore appear in a declared order rather than in
  ## whichever order a producer happened to add them.
  let ls = projectionLinesFor(p.doc, p.trailing)
  let starts = projectionLineStarts(p.doc)
  let base = max(1, p.firstLine)
  let lastLine = if p.viewportHeight <= 0: high(int)
                 else: p.viewportTop + p.viewportHeight - 1
  result = @[]
  for idx in 0 ..< ls.len:
    let line = base + idx
    if line < p.viewportTop: continue
    if line > lastLine: break
    let held = ((p.heldFrom == 0 and p.heldTo == 0) or
                (line >= p.heldFrom and line <= p.heldTo)) and
               line notin p.requested
    var row = EditorRow(line: line, held: held,
                        text: if held: ls[idx] else: "",
                        pointer: eptNone, mark: emNone, flow: efsUnknown,
                        values: @[])
    let lo = starts[idx]
    let hi = starts[idx] + ls[idx].len
    for d in p.decorations.payloads:
      let pos = d.value.fromAnchor.pos
      if pos < lo or pos > hi: continue
      case d.payload.kind
      of dkLine:
        let cls = d.payload.lineClass
        if isMarkClass(cls): row.mark = markOfClass(cls)
        elif isPointerClass(cls): row.pointer = pointerOfClass(cls)
        elif isFlowClass(cls): row.flow = flowOfClass(cls)
        else:
          raise newException(RowProjectionError,
            "editorRowsOf: line decoration class '" & cls & "' belongs to no " &
            "declared vocabulary. A row has four fields and this is none of " &
            "them; ignoring it would be a decoration nothing draws and " &
            "nothing reports.")
      of dkMark, dkBlockWidget: discard
      of dkInlineWidget: discard
    # THE INLINE VALUES COME SECOND AND THROUGH `sortedAtPosition`, so the
    # order is the declared one rather than the payload sequence's.
    var seenPositions: seq[int] = @[]
    for d in p.decorations.payloads:
      if d.payload.kind != dkInlineWidget: continue
      let pos = d.value.fromAnchor.pos
      if pos < lo or pos > hi: continue
      var seen = false
      for q in seenPositions:
        if q == pos: seen = true
      if seen: continue
      seenPositions.add pos
      for e in p.decorations.sortedAtPosition(pos):
        if e.payload.kind != dkInlineWidget: continue
        row.values.add editorValueOf(e.payload.inlineText)
    result.add row
