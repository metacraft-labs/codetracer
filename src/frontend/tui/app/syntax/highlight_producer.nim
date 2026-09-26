## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. This module reaches `isonim_tui` (through
## `highlighter`), the ViewModel facade and `std/*`: it starts no thread and
## opens no file. The thread that runs `computeHighlight` off the render path
## is the HOST's (`host/highlight_worker.nim`).
##
## app/syntax/highlight_producer.nim — PLAT-29: THE HIGHLIGHTER AS AN
## ASYNCHRONOUS PRODUCER, RECONCILED.
##
## Editor-ViewModel.md §11: *"Everything genuinely asynchronous — tree-sitter
## re-parse and re-highlight, … — sits outside, computes against a version,
## and is reconciled or discarded when stale."* Until 2026-09-23 the Edit pane
## parsed its visible window synchronously, in the render path, on every frame
## whose text differed — which is every frame after a keystroke. Now:
##
##   1. A REQUEST names the document's version and carries its WHOLE text.
##      Whole, because the parse no longer runs on the render path: a
##      construct that opens above the viewport (a block comment, a string)
##      is classified with its context, and scrolling costs no parse at all.
##   2. `computeHighlight` runs the parse — inline in a session with no host
##      thread (the suites), or on the host's worker. ONE function, so the two
##      cannot classify differently.
##   3. `installHighlight` takes the answer. When it is about the CURRENT
##      version it is the answer, whole. When the document moved while it was
##      in flight, the lines around the viewport are handed to
##      `reconcile.reconcile` one by one — `pkTreeSitter`, evidence = the
##      line's bytes, `srTextDerived` — so a line the user did not touch keeps
##      its spans at its new position, and a line they edited draws PLAIN
##      until the parse of the current version arrives. Never the old spans on
##      new text: that is the "applied as though the document had not moved"
##      §11's first rule forbids.
##   4. Every arrival's per-line outcomes are counted in a `StalenessReport` —
##      §11's second rule — and exported, so a stream of drops is a number.
##
## The model never waits (§11's third rule): nothing here blocks on the
## worker, and a frame drawn while a parse is in flight draws what is known.

import std/tables

import codetracer_embed
import ./highlighter

export highlighter

type
  HighlightRequest* = object
    ## What the render path asks for: the document AT a version.
    path*: string
    bufferSerial*: int
      ## Which OPENING of the file this is about. A buffer closed and opened
      ## again starts a new timeline at `v0`, so a late answer for the old one
      ## would name a version the new one has — or has not yet — reached, and
      ## be reconciled against the wrong history. Refused instead.
    version*: DocumentVersion
    text*: string

  HighlightResult* = object
    ## The parse of one request's text, line by line.
    request*: HighlightRequest
    highlight*: FileHighlight

  BufferHighlights* = object
    ## One buffer's spans and what they are true of.
    parsed*: FileHighlight
      ## The last parse that arrived, whole — true of `parsedVersion`.
    parsedVersion*: DocumentVersion
    parsedText*: string
    hasParse*: bool
    held*: Table[int, seq[SyntaxSpan]]
      ## 1-based line (at `heldVersion`) → spans, for a document that has
      ## moved past `parsedVersion`: only the lines reconciliation let
      ## through. Empty while the parse is current.
    heldEvidence*: Table[int, (int, int)]
      ## Each held line's byte range at `heldVersion`, so the next edit can
      ## reconcile it again rather than re-deriving it.
    heldVersion*: DocumentVersion
    hasHeld*: bool
    heldTop*, heldRows*: int
      ## The viewport `held` was reconciled for. One that has scrolled
      ## outside it is re-derived from the last parse.
      ## Whether `held` was built for `heldVersion` (it may legitimately be
      ## empty: every line around the viewport was edited).
    requested*: DocumentVersion
    hasRequest*: bool
    report*: StalenessReport
      ## Arrivals only: one count per line reconciled when a STALE parse
      ## lands, and one `roApplied` per arrival that is current. Re-mapping
      ## held lines after a later edit is counted in `remapReport`, so the
      ## arrival figures are not inflated by every keystroke that follows.
    remapReport*: StalenessReport
    arrivals*: int

const
  ReconcileMarginLines* = 16
    ## How far beyond the viewport a stale parse's lines are reconciled. A
    ## 40,000-line file is reconciled a screen and a margin at a time, not
    ## whole: every line costs a `delta`, and nothing draws the others. The
    ## first spelling was 200, and on a 24,000-line file it made reconciling
    ## the held lines cost 65 ms per keystroke — measured, and more than the
    ## edit itself. A viewport that moves beyond what is held re-derives from
    ## the last parse (`refreshHeld`).

func lineStartsOf(text: string): seq[int] =
  result = @[0]
  for i, ch in text:
    if ch == '\n': result.add i + 1

func lineOfOffset(starts: openArray[int]; offset: int): int =
  ## 1-based line holding `offset`: the last start at or before it.
  var lo = 0
  var hi = starts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if starts[mid] <= offset: lo = mid else: hi = mid - 1
  lo + 1

proc highlightRequestFor*(d: EditingDocument;
                          bufferSerial = 0): HighlightRequest =
  HighlightRequest(path: d.path, bufferSerial: bufferSerial,
                   version: d.version, text: d.text)

proc computeHighlight*(req: HighlightRequest): HighlightResult =
  ## THE PARSE. Pure over the request; this is what the host's worker runs.
  var lines: seq[string] = @[]
  var start = 0
  for i, ch in req.text:
    if ch == '\n':
      lines.add req.text[start ..< i]
      start = i + 1
  lines.add req.text[start .. ^1]
  HighlightResult(request: req, highlight: highlightWindow(req.path, 1, lines))

proc needsRequest*(bh: BufferHighlights; d: EditingDocument): bool =
  ## Whether the render path should ask for a parse of the current version:
  ## nothing current has arrived and nothing current is in flight.
  not (bh.hasParse and bh.parsedVersion == d.version) and
    not (bh.hasRequest and bh.requested == d.version)

proc noteRequested*(bh: var BufferHighlights; req: HighlightRequest) =
  bh.requested = req.version
  bh.hasRequest = true

proc reconcileLines(bh: var BufferHighlights; d: EditingDocument;
                    viewportTop, rows: int;
                    source: Table[int, (seq[SyntaxSpan], (int, int))];
                    against: DocumentVersion; docLen: int;
                    rep: var StalenessReport) =
  ## Hand each line to `reconcile` and keep the ones it lets through, at the
  ## line their evidence now starts on.
  bh.held = initTable[int, seq[SyntaxSpan]]()
  bh.heldEvidence = initTable[int, (int, int)]()
  bh.heldVersion = d.version
  bh.hasHeld = true
  bh.heldTop = viewportTop
  bh.heldRows = rows
  let starts = lineStartsOf(d.text)
  for entry in source.values:
    let spans = entry[0]
    let ev = entry[1]
    let pr = producerResult(pkTreeSitter, against, docLen, ev[0], ev[1])
    let r = reconcile(d.timeline, pr, rep)
    case r.outcome
    of roApplied, roMapped:
      # Keyed by the line the evidence now STARTS on; the spans stay relative
      # to the evidence, and `spansAt` places them — see there.
      let line = lineOfOffset(starts, r.value.evidenceFrom)
      bh.held[line] = spans
      bh.heldEvidence[line] = (r.value.evidenceFrom, r.value.evidenceTo)
    of roDropped:
      discard

proc parsedLinesAround(bh: BufferHighlights; viewportTop, rows: int):
    Table[int, (seq[SyntaxSpan], (int, int))] =
  ## The last parse's lines within `ReconcileMarginLines` of the viewport,
  ## with each line's byte range in the text that was parsed.
  result = initTable[int, (seq[SyntaxSpan], (int, int))]()
  let starts = lineStartsOf(bh.parsedText)
  let first = max(1, viewportTop - ReconcileMarginLines)
  let last = min(starts.len, viewportTop + rows + ReconcileMarginLines)
  for line in first .. last:
    let a = starts[line - 1]
    let b = if line < starts.len: starts[line] - 1 else: bh.parsedText.len
    result[line] = (bh.parsed.spansForLine(line), (a, b))

proc installHighlight*(bh: var BufferHighlights; d: EditingDocument;
                       res: HighlightResult; viewportTop, rows: int) =
  ## Take a parse that arrived. See the header's point 3.
  inc bh.arrivals
  bh.parsed = res.highlight
  bh.parsedVersion = res.request.version
  bh.parsedText = res.request.text
  bh.hasParse = true
  if res.request.version == d.version:
    # CURRENT: one `roApplied` for the arrival, and the parse is the answer.
    bh.report.record(pkTreeSitter, roApplied, drNotDropped)
    bh.held.clear()
    bh.heldEvidence.clear()
    bh.hasHeld = false
    return
  if not d.timeline.knows(res.request.version):
    bh.report.record(pkTreeSitter, roDropped, drVersionForgotten)
    bh.held.clear()
    bh.heldEvidence.clear()
    bh.hasHeld = false
    return
  # STALE: reconcile the lines around the viewport, counted as arrivals.
  bh.reconcileLines(d, viewportTop, rows,
                    bh.parsedLinesAround(viewportTop, rows),
                    res.request.version, res.request.text.len, bh.report)

proc refreshHeld*(bh: var BufferHighlights; d: EditingDocument;
                  viewportTop, rows: int) =
  ## After an edit, before a frame: bring what is held up to the current
  ## version, by the same reconciliation — from the held lines when there are
  ## some, else from the last parse, which is what keeps a keystroke from
  ## blanking every line on screen until the next parse lands. Counted in
  ## `remapReport`, not in the arrival report.
  if not bh.hasParse or bh.parsedVersion == d.version: return
  let viewportMoved = bh.hasHeld and
    (viewportTop < bh.heldTop or
     viewportTop + rows > bh.heldTop + bh.heldRows)
  if bh.hasHeld and bh.heldVersion == d.version and not viewportMoved: return
  if bh.hasHeld and not viewportMoved and d.timeline.knows(bh.heldVersion):
    var source = initTable[int, (seq[SyntaxSpan], (int, int))]()
    for line, spans in bh.held:
      source[line] = (spans, bh.heldEvidence[line])
    let docLen = d.timeline.lengthAt(bh.heldVersion)
    bh.reconcileLines(d, bh.heldTop, bh.heldRows, source, bh.heldVersion,
                      docLen, bh.remapReport)
  elif d.timeline.knows(bh.parsedVersion):
    bh.reconcileLines(d, viewportTop, rows,
                      bh.parsedLinesAround(viewportTop, rows),
                      bh.parsedVersion, bh.parsedText.len, bh.remapReport)
  else:
    bh.held.clear()
    bh.heldEvidence.clear()
    bh.heldVersion = d.version
    bh.hasHeld = true

proc spansForWindow*(bh: BufferHighlights; d: EditingDocument;
                     firstLine, count: int): seq[seq[SyntaxSpan]] =
  ## The spans to DRAW on lines `firstLine ..< firstLine + count` (1-based) of
  ## the current document: the parse when it is current, the reconciled lines
  ## otherwise, and nothing — plain text — for a line neither can vouch for.
  ## One call per frame, so the line table is computed once rather than per
  ## line.
  result = newSeq[seq[SyntaxSpan]](max(0, count))
  if bh.hasParse and bh.parsedVersion == d.version:
    for i in 0 ..< result.len:
      result[i] = bh.parsed.spansForLine(firstLine + i)
    return
  if not (bh.hasHeld and bh.heldVersion == d.version) or bh.held.len == 0:
    return
  let starts = lineStartsOf(d.text)
  for i in 0 ..< result.len:
    let line = firstLine + i
    if line < 1 or line > starts.len or not bh.held.hasKey(line): continue
    # Text typed AT the start of a line abuts its evidence, so reconciliation
    # keeps the line — and its spans, measured in cells from where the
    # evidence begins, move right by exactly the cells typed before it.
    let lineStart = starts[line - 1]
    let lineEnd = if line < starts.len: starts[line] - 1 else: d.text.len
    let (evFrom, _) = bh.heldEvidence[line]
    let shift = cellOffsetAtByte(d.text[lineStart ..< lineEnd],
                                 evFrom - lineStart)
    result[i] = bh.held[line]
    if shift != 0:
      for sp in result[i].mitems:
        sp.startCell += shift
        sp.endCell += shift
