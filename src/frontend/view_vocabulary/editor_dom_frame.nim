## view_vocabulary/editor_dom_frame.nim — the shared editor's DOM frame, as a
## value: what the desktop's shared-editor renderer (`ui/shared_editor`) draws
## for one viewport of an `EditingDocument`.
##
## The desktop has two editors behind one developer setting
## (`sharedEditor`, Editor-ViewModel.md §3.2): Monaco, the default, and the
## shared editing core — the one the terminal draws as cells and GPUI as
## elements — drawn here as DOM. Everything a frame says is decided in this
## module, with no DOM in it, so both Nim backends run the same derivation and
## a suite can hold a frame to a document without a browser:
##
##   * the LINE INDEX of the core's text (`LineIndex`), rebuilt once per
##     document version rather than once per question, which is what keeps a
##     file of hundreds of thousands of lines scrollable;
##   * the editor's DECORATIONS in the vocabulary the desktop speaks —
##     Monaco's `IModelDecorationOptions` subset `ui/editor`, `ui/flow` and
##     `ui/trace` set — held as the core's `decoration.DecorationSet` and
##     moved through each edit by the core's own mapping (`mapDecorationSet`
##     over the timeline's `delta`), so a breakpoint mark or a value chip
##     follows the text it was put on;
##   * FOLDING: the core keeps the folded heads (`EditorState.folded`, 0-based
##     lines); which lines a fold hides is the indentation rule the core's
##     `fold-all` uses, applied here;
##   * the VERTICAL LAYOUT: line tops with view zones (Monaco's block widgets:
##     the flow panel, a tracepoint's editor, a macro expansion) and folds
##     taken out, and its inverse for a pointer;
##   * each visible line as SPANS: the Monarch tokens (`lexical.tokenRuns`,
##     the runner the terminal and GPUI colour with, PLAT-47) cut at every
##     inline decoration's edge, with the injected `after` content in place;
##   * the COLUMN CONVERSIONS between the core's byte offsets and Monaco's
##     1-based UTF-16 columns, which is the unit every `ui/` caller of the
##     editor API speaks.
##
## NO MOCKS. Nothing here constructs a stand-in: the suites hand it a real
## `EditingDocument` and real token runs.

import std/[algorithm, strutils, tables]

import ../viewmodel/editing_core
import ../viewmodel/editor/[change_set, decoration, range_set,
                            document_version]
import ../tui/app/syntax/lexical
import ../tui/app/syntax/token_class

export lexical.TokenRun, lexical.LexerId, token_class.TokenClass

# ---------------------------------------------------------------------------
# The line index
# ---------------------------------------------------------------------------

type
  LineIndex* = object
    ## Where each line of one version of the text starts. `starts[i]` is the
    ## byte offset of 0-based line `i`; there is always at least one line.
    starts*: seq[int]
    textLen*: int
    version*: DocumentVersion
    built*: bool

proc buildLineIndex*(text: string; version: DocumentVersion): LineIndex =
  result.starts = newSeqOfCap[int](max(16, text.len div 32))
  result.starts.add 0
  for i in 0 ..< text.len:
    if text[i] == '\n':
      result.starts.add i + 1
  result.textLen = text.len
  result.version = version
  result.built = true

proc updatedLineIndex*(old: LineIndex; cs: ChangeSet; text: string;
                       version: DocumentVersion): LineIndex =
  ## `old` moved through `cs` onto `text`: the line starts before the first
  ## change are kept, those after the last one shift by the length change, and
  ## only the changed span of the new text is scanned for newlines — so a
  ## keystroke in a large document costs its line count in integer copies,
  ## not a scan of every byte. `buildLineIndex(text)` is the oracle
  ## (`test_editor_dom_frame.nim`).
  let rs = cs.changedRangeSeq()
  if rs.len == 0:
    result = old
    result.version = version
    result.textLen = text.len
    return
  var loA = rs[0].fromA
  var hiA = rs[0].toA
  var loB = rs[0].fromB
  var hiB = rs[0].toB
  for r in rs:
    loA = min(loA, r.fromA)
    hiA = max(hiA, r.toA)
    loB = min(loB, r.fromB)
    hiB = max(hiB, r.toB)
  let delta = text.len - old.textLen
  result.starts = newSeqOfCap[int](old.starts.len + 8)
  var i = 0
  while i < old.starts.len and old.starts[i] <= loA:
    result.starts.add old.starts[i]
    inc i
  for p in loB ..< min(hiB, text.len):
    if text[p] == '\n':
      result.starts.add p + 1
  while i < old.starts.len and old.starts[i] <= hiA:
    inc i
  while i < old.starts.len:
    result.starts.add old.starts[i] + delta
    inc i
  result.textLen = text.len
  result.version = version
  result.built = true

func lineCount*(ix: LineIndex): int = ix.starts.len

func lineStart*(ix: LineIndex; line0: int): int =
  ## The offset of 0-based `line0`, clamped to the document.
  if line0 <= 0: 0
  elif line0 >= ix.starts.len: ix.textLen
  else: ix.starts[line0]

func lineEnd*(ix: LineIndex; line0: int): int =
  ## The offset just past 0-based `line0`'s last character (its newline
  ## excluded).
  if line0 < 0: return 0
  if line0 + 1 < ix.starts.len: ix.starts[line0 + 1] - 1
  else: ix.textLen

func lineOfOffset*(ix: LineIndex; offset: int): int =
  ## The 0-based line holding `offset` (binary search).
  if ix.starts.len == 0: return 0
  let off = clamp(offset, 0, ix.textLen)
  var lo = 0
  var hi = ix.starts.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if ix.starts[mid] <= off: lo = mid
    else: hi = mid - 1
  lo

proc lineText*(ix: LineIndex; text: string; line0: int): string =
  if line0 < 0 or line0 >= ix.starts.len: return ""
  let a = ix.lineStart(line0)
  let b = ix.lineEnd(line0)
  if b <= a: "" else: text[a ..< b]

# ---------------------------------------------------------------------------
# Columns: the core's bytes and Monaco's UTF-16 units
# ---------------------------------------------------------------------------

func utf16Units(s: string; a, b: int): int =
  ## UTF-16 code units of the UTF-8 bytes `s[a ..< b]`.
  var i = a
  while i < b and i < s.len:
    let c = ord(s[i])
    let n = if c < 0x80: 1
            elif c < 0xE0: 2
            elif c < 0xF0: 3
            else: 4
    result += (if n == 4: 2 else: 1)
    i += n

func monacoColumnOf*(lineText: string; byteCol: int): int =
  ## The 1-based UTF-16 column of byte `byteCol` of `lineText`.
  utf16Units(lineText, 0, clamp(byteCol, 0, lineText.len)) + 1

func byteColumnOf*(lineText: string; monacoColumn: int): int =
  ## The byte offset within `lineText` of 1-based UTF-16 `monacoColumn`,
  ## clamped to the line (a column inside a surrogate pair lands after it).
  var units = 0
  let want = max(0, monacoColumn - 1)
  var i = 0
  while i < lineText.len and units < want:
    let c = ord(lineText[i])
    let n = if c < 0x80: 1
            elif c < 0xE0: 2
            elif c < 0xF0: 3
            else: 4
    units += (if n == 4: 2 else: 1)
    i += n
  min(i, lineText.len)

proc offsetOfPosition*(ix: LineIndex; text: string;
                       lineNumber, column: int): int =
  ## Monaco's `(lineNumber, column)` as a document byte offset.
  let line0 = clamp(lineNumber - 1, 0, ix.lineCount - 1)
  ix.lineStart(line0) + byteColumnOf(ix.lineText(text, line0), column)

proc positionOfOffset*(ix: LineIndex; text: string;
                       offset: int): tuple[lineNumber, column: int] =
  let line0 = ix.lineOfOffset(offset)
  let col = clamp(offset, 0, ix.textLen) - ix.lineStart(line0)
  (line0 + 1, monacoColumnOf(ix.lineText(text, line0), col))

# ---------------------------------------------------------------------------
# Decorations in the desktop's vocabulary, held by the core
# ---------------------------------------------------------------------------

type
  DecoOptions* = object
    ## The part of Monaco's `IModelDecorationOptions` the desktop sets.
    className*: string
      ## Whole-line (or range) background class, drawn in the overlay layer.
    isWholeLine*: bool
    inlineClassName*: string
      ## A class on the text of the range itself.
    glyphMarginClassName*: string
    linesDecorationsClassName*: string
    marginClassName*: string
    afterContent*: string
      ## Injected text at the range's end (`options.after.content`).
    afterClass*: string
    beforeContent*: string
    beforeClass*: string
    hoverMessage*: string
    showIfCollapsed*: bool
    stickiness*: int

  FacadeDecoration* = object
    id*: string
    coreId*: int
    options*: DecoOptions

  DecorationTable* = object
    ## The editor's decorations: options by id, ranges in the core's set.
    entries*: seq[FacadeDecoration]
    core*: DecorationSet
    nextId*: int
    version*: DocumentVersion
      ## The document version the ranges in `core` are positions of.
    mapped*: int
      ## How many edits the ranges have been moved through (a suite reads it
      ## to know the mapping ran rather than the ranges standing still).

  DecoRequest* = object
    ## One new decoration: a document byte range and its options.
    fromOffset*, toOffset*: int
    options*: DecoOptions

proc initDecorationTable*(version: DocumentVersion): DecorationTable =
  DecorationTable(core: decorationSet(@[]), nextId: 1, version: version)

proc payloadFor(o: DecoOptions; fromOff, toOff: int): DecorationPayload =
  if fromOff == toOff: linePayload(o.className)
  else: markPayload(o.inlineClassName)

proc deltaDecorations*(t: var DecorationTable; old: openArray[string];
                       added: openArray[DecoRequest]): seq[string] =
  ## Monaco's `deltaDecorations`: remove `old`, add `added`, answer the new
  ## ids in order.
  var keepEntries: seq[FacadeDecoration] = @[]
  var dropped: seq[int] = @[]
  for e in t.entries:
    if e.id in old: dropped.add e.coreId
    else: keepEntries.add e
  var ds: seq[Decoration] = @[]
  for d in t.core.payloads:
    if d.value.id notin dropped: ds.add d
  for req in added:
    let a = max(0, min(req.fromOffset, req.toOffset))
    let b = max(req.fromOffset, req.toOffset)
    let coreId = t.nextId
    inc t.nextId
    let id = "ct-shared-" & $coreId
    ds.add decoration(coreId, a, b, payloadFor(req.options, a, b))
    keepEntries.add FacadeDecoration(id: id, coreId: coreId,
                                     options: req.options)
    result.add id
  t.entries = keepEntries
  t.core = decorationSet(ds)

proc rangeOf*(t: DecorationTable; id: string): tuple[found: bool;
                                                  fromOffset, toOffset: int] =
  for e in t.entries:
    if e.id == id:
      for d in t.core.payloads:
        if d.value.id == e.coreId:
          return (true, d.value.fromAnchor.pos, d.value.toAnchor.pos)
  (false, 0, 0)

proc mapThrough*(t: var DecorationTable; cs: ChangeSet;
                 version: DocumentVersion) =
  ## Move every range through `cs`, the change from `t.version` to `version`.
  if not cs.isIdentity:
    var st: MapStats
    t.core = mapDecorationSet(t.core, cs, st)
    inc t.mapped
    # A range the mapping dropped takes its options with it.
    var alive: seq[FacadeDecoration] = @[]
    for e in t.entries:
      for d in t.core.payloads:
        if d.value.id == e.coreId:
          alive.add e
          break
    t.entries = alive
  t.version = version

proc followDocument*(t: var DecorationTable; d: EditingDocument) =
  ## Bring the ranges to the document's current version through the
  ## timeline's change set since the version they were put on. When the
  ## timeline no longer knows that version (more than `TimelineDepth` edits
  ## in one go) the ranges are clamped to the document instead.
  let now = d.timeline.version
  if now == t.version: return
  if d.timeline.knows(t.version):
    t.mapThrough(d.timeline.delta(t.version), now)
  else:
    var ds: seq[Decoration] = @[]
    let n = d.state.doc.len
    for x in t.core.payloads:
      var y = x
      let a = min(x.value.fromAnchor.pos, n)
      let b = min(max(a, x.value.toAnchor.pos), n)
      y = decoration(x.value.id, a, b, x.payload)
      ds.add y
    t.core = decorationSet(ds)
    t.version = now

type
  LineDecorations* = object
    ## What the decorations put on one line.
    lineClasses*: seq[string]       ## overlay classes (whole line)
    glyphClasses*: seq[string]
    lineDecoClasses*: seq[string]
    marginClasses*: seq[string]
    inline*: seq[tuple[fromCol, toCol: int; cls: string]]
      ## byte columns within the line, `toCol` exclusive
    after*: seq[tuple[col: int; text, cls: string]]
    before*: seq[tuple[col: int; text, cls: string]]
    hovers*: seq[tuple[fromCol, toCol: int; message: string]]

proc decorationsByLine*(t: DecorationTable; ix: LineIndex;
                        firstLine0, lastLine0: int): Table[int, LineDecorations] =
  ## The decorations touching 0-based lines `firstLine0 .. lastLine0`, by line.
  result = initTable[int, LineDecorations]()
  var byCore = initTable[int, int]()
  for i, e in t.entries: byCore[e.coreId] = i
  for d in t.core.payloads:
    if not byCore.hasKey(d.value.id): continue
    let o = t.entries[byCore[d.value.id]].options
    let a = d.value.fromAnchor.pos
    let b = d.value.toAnchor.pos
    let la = ix.lineOfOffset(a)
    var lb = ix.lineOfOffset(b)
    # Monaco: a range ending at column 1 of a line does not touch that line
    # for whole-line purposes.
    if lb > la and b == ix.lineStart(lb): dec lb
    if lb < firstLine0 or la > lastLine0: continue
    for line0 in max(la, firstLine0) .. min(lb, lastLine0):
      var ld = result.getOrDefault(line0)
      let ls = ix.lineStart(line0)
      let le = ix.lineEnd(line0)
      if o.className.len > 0 and (o.isWholeLine or a != b or o.showIfCollapsed):
        ld.lineClasses.add o.className
      # The margin classes go on the range's FIRST line only, as Monaco's
      # glyph margin draws them.
      if line0 == la:
        if o.glyphMarginClassName.len > 0: ld.glyphClasses.add o.glyphMarginClassName
        if o.linesDecorationsClassName.len > 0:
          ld.lineDecoClasses.add o.linesDecorationsClassName
        if o.marginClassName.len > 0: ld.marginClasses.add o.marginClassName
      if o.inlineClassName.len > 0:
        let fc = if o.isWholeLine: 0 else: max(a, ls) - ls
        let tc = if o.isWholeLine: le - ls else: min(b, le) - ls
        if tc > fc: ld.inline.add (fc, tc, o.inlineClassName)
      if o.hoverMessage.len > 0:
        let fc = if o.isWholeLine: 0 else: max(a, ls) - ls
        let tc = if o.isWholeLine: le - ls else: min(b, le) - ls
        ld.hovers.add (fc, max(fc + 1, tc), o.hoverMessage)
      if o.afterContent.len > 0 and line0 == lb:
        ld.after.add (clamp(b, ls, le) - ls, o.afterContent, o.afterClass)
      if o.beforeContent.len > 0 and line0 == la:
        ld.before.add (clamp(a, ls, le) - ls, o.beforeContent, o.beforeClass)
      result[line0] = ld

# ---------------------------------------------------------------------------
# Folding
# ---------------------------------------------------------------------------

func indentWidth(s: string): int =
  ## Leading whitespace in columns (a tab is four), -1 for a blank line.
  for c in s:
    if c == ' ': inc result
    elif c == '\t': result += 4
    else: return
  -1

proc foldEnd*(ix: LineIndex; text: string; head0: int): int =
  ## The last 0-based line the fold at `head0` hides — the block below it
  ## indented deeper (blank lines inside it included, trailing blank lines
  ## left visible, as Monaco's indentation folding does) — or `head0` when
  ## nothing is below it.
  let own = indentWidth(ix.lineText(text, head0))
  if own < 0: return head0
  result = head0
  var i = head0 + 1
  while i < ix.lineCount:
    let w = indentWidth(ix.lineText(text, i))
    if w >= 0:
      if w <= own: break
      result = i
    inc i

proc isFoldable*(ix: LineIndex; text: string; line0: int): bool =
  ## Monaco's indentation folding: a non-blank line whose next non-blank
  ## line is indented deeper.
  let own = indentWidth(ix.lineText(text, line0))
  if own < 0: return false
  var i = line0 + 1
  while i < ix.lineCount:
    let w = indentWidth(ix.lineText(text, i))
    if w >= 0: return w > own
    inc i
  false

proc hiddenRanges*(ix: LineIndex; text: string;
                   folded: openArray[int]): seq[tuple[first, last: int]] =
  ## The 0-based line ranges hidden by `folded` heads, merged and sorted. A
  ## head inside another fold's hidden range stays hidden with it.
  var rs: seq[tuple[first, last: int]] = @[]
  for h in folded:
    if h < 0 or h >= ix.lineCount: continue
    let e = foldEnd(ix, text, h)
    if e > h: rs.add (h + 1, e)
  rs.sort(proc (a, b: tuple[first, last: int]): int = cmp(a.first, b.first))
  for r in rs:
    if result.len > 0 and r.first <= result[^1].last + 1:
      result[^1].last = max(result[^1].last, r.last)
    else:
      result.add r

func isHidden*(hidden: openArray[tuple[first, last: int]]; line0: int): bool =
  for r in hidden:
    if line0 < r.first: return false
    if line0 <= r.last: return true
  false

# ---------------------------------------------------------------------------
# Vertical layout
# ---------------------------------------------------------------------------

type
  ZoneSpec* = object
    ## A view zone (Monaco's block widget): `heightPx` of content after
    ## 1-based `afterLine` (0 = above the first line).
    id*: int
    afterLine*: int
    heightPx*: int

  VerticalLayout* = object
    ## Line tops, with folds and zones accounted for. Built per frame from the
    ## index, the hidden ranges and the zones; every query is O(log n) or
    ## O(zones).
    lineHeight*: int
    lineCount*: int
    hidden*: seq[tuple[first, last: int]]
    zones*: seq[ZoneSpec]   ## sorted by `afterLine`
    hiddenBefore*: seq[int]
      ## hiddenBefore[k] = lines hidden by ranges `0 ..< k`

proc verticalLayout*(lineCount, lineHeight: int;
                     hidden: seq[tuple[first, last: int]];
                     zones: openArray[ZoneSpec]): VerticalLayout =
  result.lineHeight = max(1, lineHeight)
  result.lineCount = max(1, lineCount)
  result.hidden = hidden
  result.zones = @zones
  result.zones.sort(proc (a, b: ZoneSpec): int =
    if a.afterLine != b.afterLine: cmp(a.afterLine, b.afterLine)
    else: cmp(a.id, b.id))
  result.hiddenBefore = @[0]
  for r in hidden:
    result.hiddenBefore.add result.hiddenBefore[^1] + (r.last - r.first + 1)

func visibleIndexOf*(v: VerticalLayout; line0: int): int =
  ## How many VISIBLE lines precede 0-based `line0`.
  var hiddenAbove = 0
  for k, r in v.hidden:
    if r.first > line0 - 1: break
    if r.last < line0: hiddenAbove = v.hiddenBefore[k + 1]
    else:
      hiddenAbove = v.hiddenBefore[k] + (line0 - r.first)
      break
  line0 - hiddenAbove

func zonePxBefore*(v: VerticalLayout; line1: int): int =
  ## Height of the zones placed above 1-based `line1` (after lines < line1),
  ## counting only zones whose anchor line is not hidden.
  for z in v.zones:
    if z.afterLine >= line1: break
    if z.afterLine >= 1 and v.hidden.isHidden(z.afterLine - 1): continue
    result += z.heightPx

func topOfLine*(v: VerticalLayout; line1: int): int =
  ## Monaco's `getTopForLineNumber`.
  let line0 = clamp(line1 - 1, 0, v.lineCount - 1)
  v.visibleIndexOf(line0) * v.lineHeight + v.zonePxBefore(line0 + 1)

func zoneTop*(v: VerticalLayout; z: ZoneSpec): int =
  ## Where zone `z` starts: below its anchor line.
  if z.afterLine <= 0:
    var px = 0
    for o in v.zones:
      if o.afterLine > 0 or o.id == z.id: break
      px += o.heightPx
    return px
  result = v.topOfLine(z.afterLine) + v.lineHeight
  for o in v.zones:
    if o.afterLine != z.afterLine: continue
    if o.id == z.id: break
    result += o.heightPx

func contentHeight*(v: VerticalLayout): int =
  let hiddenTotal = if v.hiddenBefore.len > 0: v.hiddenBefore[^1] else: 0
  result = (v.lineCount - hiddenTotal) * v.lineHeight
  for z in v.zones:
    if z.afterLine >= 1 and v.hidden.isHidden(z.afterLine - 1): continue
    result += z.heightPx

func nextVisible*(v: VerticalLayout; line0: int): int =
  ## `line0`, or the first visible line after it.
  result = line0
  for r in v.hidden:
    if result < r.first: break
    if result <= r.last: result = r.last + 1
  result = min(result, v.lineCount - 1)

func lineAtY*(v: VerticalLayout; y: int): int =
  ## The 1-based line under content y (Monaco's `getPositionAt` row half):
  ## a y inside a zone answers the zone's anchor line.
  var lo = 0
  var hi = v.lineCount - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if v.topOfLine(mid + 1) <= y: lo = mid
    else: hi = mid - 1
  if v.hidden.isHidden(lo):
    # a hidden line shares its top with the next visible one; answer the head
    var head = lo
    while head > 0 and v.hidden.isHidden(head): dec head
    lo = head
  lo + 1

func visibleLines*(v: VerticalLayout; scrollTop, height: int): seq[int] =
  ## The 1-based visible lines whose box intersects `[scrollTop,
  ## scrollTop + height)`, in order.
  if v.lineCount <= 0: return
  var line0 = v.lineAtY(max(0, scrollTop)) - 1
  line0 = v.nextVisible(line0)
  let bottom = scrollTop + max(0, height)
  while line0 < v.lineCount:
    if v.hidden.isHidden(line0):
      line0 = v.nextVisible(line0)
      if v.hidden.isHidden(line0): break
      continue
    let top = v.topOfLine(line0 + 1)
    if top >= bottom: break
    result.add line0 + 1
    inc line0

# ---------------------------------------------------------------------------
# Spans
# ---------------------------------------------------------------------------

type
  SpanKind* = enum
    skText      ## a run of the line's own text
    skInjected  ## decoration content that is not part of the text

  FrameSpan* = object
    kind*: SpanKind
    text*: string
    fromCol*: int
      ## byte column of the span's first byte in the line (skText), or the
      ## column it is injected at (skInjected)
    tokenClass*: TokenClass
    classes*: seq[string]
      ## inline decoration classes on a text span; the injected class on an
      ## injected one

proc lineSpans*(lineText: string; runs: openArray[TokenRun];
                deco: LineDecorations): seq[FrameSpan] =
  ## The line as spans: each token run cut at every inline decoration edge
  ## and at every injection column, with the injected content in place.
  ## The text spans concatenate to exactly `lineText`.
  var cuts: seq[int] = @[0, lineText.len]
  var at = 0
  for r in runs:
    cuts.add at
    at += r.text.len
  for i in deco.inline:
    cuts.add clamp(i.fromCol, 0, lineText.len)
    cuts.add clamp(i.toCol, 0, lineText.len)
  for a in deco.after: cuts.add clamp(a.col, 0, lineText.len)
  for b in deco.before: cuts.add clamp(b.col, 0, lineText.len)
  cuts.sort()
  var uniq: seq[int] = @[]
  for c in cuts:
    if uniq.len == 0 or uniq[^1] != c: uniq.add c
  # token class at a byte column
  var runStarts: seq[(int, TokenClass)] = @[]
  at = 0
  for r in runs:
    runStarts.add (at, r.class)
    at += r.text.len
  proc classAt(col: int): TokenClass =
    result = tcPlain
    for (s, c) in runStarts:
      if s <= col: result = c
      else: break
  proc injectAt(col: int; into: var seq[FrameSpan]) =
    for b in deco.before:
      if clamp(b.col, 0, lineText.len) == col:
        into.add FrameSpan(kind: skInjected, text: b.text, fromCol: col,
                           tokenClass: tcPlain, classes: @[b.cls])
  proc injectAfter(col: int; into: var seq[FrameSpan]) =
    for a in deco.after:
      if clamp(a.col, 0, lineText.len) == col:
        into.add FrameSpan(kind: skInjected, text: a.text, fromCol: col,
                           tokenClass: tcPlain, classes: @[a.cls])
  for k in 0 ..< uniq.len:
    let a = uniq[k]
    injectAfter(a, result)
    injectAt(a, result)
    if k + 1 >= uniq.len: break
    let b = uniq[k + 1]
    if b <= a: continue
    var cls: seq[string] = @[]
    for i in deco.inline:
      if i.fromCol <= a and b <= i.toCol and i.cls notin cls: cls.add i.cls
    result.add FrameSpan(kind: skText, text: lineText[a ..< b], fromCol: a,
                         tokenClass: classAt(a), classes: cls)

func textOfSpans*(spans: openArray[FrameSpan]): string =
  ## The line's own text back out of its spans (injected content excluded).
  for s in spans:
    if s.kind == skText: result.add s.text

# ---------------------------------------------------------------------------
# Brackets
# ---------------------------------------------------------------------------

const
  OpenBrackets = {'(', '[', '{'}
  CloseBrackets = {')', ']', '}'}

func partnerOf(c: char): char =
  case c
  of '(': ')'
  of '[': ']'
  of '{': '}'
  of ')': '('
  of ']': '['
  of '}': '{'
  else: '\0'

proc matchingBracket*(text: string; offset: int;
                      limit = 200_000): tuple[found: bool; a, b: int] =
  ## Monaco's bracket matching at the caret: the bracket just before or at
  ## `offset` and its partner, as document offsets. Strings and comments are
  ## not skipped (Monaco's `bracketPairColorization` off, its default matcher
  ## counts brackets in tokens of the same kind; the desktop's grammars put
  ## brackets in code, so the plain count is what a reader sees). `limit`
  ## bounds the scan.
  var at = -1
  if offset < text.len and text[offset] in OpenBrackets + CloseBrackets:
    at = offset
  elif offset > 0 and offset - 1 < text.len and
       text[offset - 1] in OpenBrackets + CloseBrackets:
    at = offset - 1
  if at < 0: return (false, 0, 0)
  let c = text[at]
  let p = partnerOf(c)
  var depth = 0
  if c in OpenBrackets:
    var i = at
    while i < text.len and i - at <= limit:
      if text[i] == c: inc depth
      elif text[i] == p:
        dec depth
        if depth == 0: return (true, at, i)
      inc i
  else:
    var i = at
    while i >= 0 and at - i <= limit:
      if text[i] == c: inc depth
      elif text[i] == p:
        dec depth
        if depth == 0: return (true, i, at)
      dec i
  (false, 0, 0)

# ---------------------------------------------------------------------------
# Word at a position (Monaco's `getWordAtPosition`)
# ---------------------------------------------------------------------------

const DefaultWordSeparators* = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"
  ## Monaco's `editor.wordSeparators` default (the desktop passes
  ## `UsualWordSeparators`, the same set).

proc wordAt*(lineText: string; byteCol: int;
             separators = DefaultWordSeparators): tuple[found: bool; a, b: int] =
  ## The word touching byte column `byteCol` of `lineText`, as byte columns.
  proc isWord(c: char): bool = c notin Whitespace and c notin separators
  var a = clamp(byteCol, 0, lineText.len)
  var b = a
  if (a >= lineText.len or not isWord(lineText[a])) and
     (a == 0 or not isWord(lineText[a - 1])):
    return (false, 0, 0)
  while a > 0 and isWord(lineText[a - 1]): dec a
  while b < lineText.len and isWord(lineText[b]): inc b
  (b > a, a, b)

# ---------------------------------------------------------------------------
# The unified diff's line diff (`ui/shared_diff_editor`)
# ---------------------------------------------------------------------------

type
  DiffHunk* = object
    ## One change: old lines `[oldFrom, oldTo)` became new lines
    ## `[newFrom, newTo)`, 0-based.
    oldFrom*, oldTo*, newFrom*, newTo*: int

proc splitLinesKeep*(s: string): seq[string] =
  result = @[]
  var cur = ""
  for c in s:
    if c == '\n':
      result.add cur
      cur = ""
    else:
      cur.add c
  result.add cur

proc lineDiff*(a, b: seq[string]): seq[DiffHunk] =
  ## The changes between two line lists, by a longest common subsequence of
  ## whole lines. A pair too large for the table (over 4M cells) is one hunk.
  let n = a.len
  let m = b.len
  if n * m > 4_000_000:
    if a != b: result.add DiffHunk(oldFrom: 0, oldTo: n, newFrom: 0, newTo: m)
    return
  var dp = newSeq[seq[int32]](n + 1)
  for i in 0 .. n: dp[i] = newSeq[int32](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      dp[i][j] = if a[i] == b[j]: dp[i + 1][j + 1] + 1
                 else: max(dp[i + 1][j], dp[i][j + 1])
  var i = 0
  var j = 0
  var cur = DiffHunk(oldFrom: -1)
  proc flush(h: var DiffHunk; res: var seq[DiffHunk]; i, j: int) =
    if h.oldFrom >= 0:
      h.oldTo = i
      h.newTo = j
      res.add h
      h = DiffHunk(oldFrom: -1)
  while i < n or j < m:
    if i < n and j < m and a[i] == b[j]:
      flush(cur, result, i, j)
      inc i
      inc j
    elif j < m and (i >= n or dp[i][j + 1] >= dp[i + 1][j]):
      if cur.oldFrom < 0: cur = DiffHunk(oldFrom: i, newFrom: j)
      inc j
    else:
      if cur.oldFrom < 0: cur = DiffHunk(oldFrom: i, newFrom: j)
      inc i
  flush(cur, result, i, j)

