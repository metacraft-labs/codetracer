## decoration.nim — PLAT-28: the decoration model that makes CodeTracer's four
## debugger surfaces ordinary line content instead of an overlay.
##
## Owns: Editor-ViewModel.md §8.1 and the ordering paragraph under it. Built on
## `range_set.nim` (§8.0) rather than beside it: a decoration IS a range value
## with a payload, so the mapping and the comparison are inherited rather than
## re-derived.
##
## =========================================================================
## FOUR ARMS, AND BLOCK-NESS IS INTRINSIC TO THE ARM
## =========================================================================
##
## CodeMirror's `Decoration` has four kinds — `mark`, `widget`, `replace`,
## `line` — and a widget is inline or block depending on a `block: boolean`
## field on the widget's spec. Ours are `dkMark`, `dkInlineWidget`,
## `dkBlockWidget`, `dkLine`: **the milestone's four**, with block-ness in the
## arm rather than in a field, so *"an inline widget with block-ness set"* is
## unrepresentable rather than merely unusual.
##
## **CodeMirror's `replace` IS NOT ONE OF OURS, and that is a divergence rather
## than an oversight.** `replace` is *"hide a range, optionally showing a
## widget"* — two behaviours in one kind, and the optional widget is the same
## `block: boolean` problem one level up. What the four arms here cannot
## express is therefore exactly one thing: hiding a span. It is recorded in
## `Editor-Model-Conformance-Suite.md` and named `PLAT28-DG1` below rather than
## implied by its absence, because a taxonomy with a silent hole is the shape
## `EditorConcern` was given a `EditorProducerGap` register to avoid.
##
## =========================================================================
## ORDERING AT ONE POSITION IS AN ENUM PLUS A BOUNDED OFFSET
## =========================================================================
##
## §8.1: *"The reference orders everything drawn at the same position with a
## single signed `side` number whose value is a band constant … plus a user
## offset CLAMPED to ±10,000 — so block widgets sort outside inline ones
## because the bands are 10⁸ apart. That is an ordered enumeration implemented
## in arithmetic."*
##
## Ours is `(DecoOrderClass, offset)` compared lexicographically. Three things
## follow, and each is a property a test can see:
##
##   1. **Transitivity cannot be lost to a clamp**, because there is no
##      addition. The reference's `side` is `band + clamp(offset)`, and a
##      lexicographic pair has no arithmetic for a clamp to distort.
##   2. **THE OFFSET BOUND RAISES; IT DOES NOT CLAMP.** The reference clamps to
##      ±10,000, which is `Verification-Harness-Traps` §36a exactly — a repair
##      that cannot be told from a guard that never fires, and one that makes
##      two decorations with different offsets compare EQUAL without anything
##      saying so. `decoOrder` refuses an out-of-range offset by name.
##   3. **The one exception the reference supports — a block widget
##      deliberately ordered AMONG the inline ones — is a VARIANT**
##      (`BlockPlacement`), not a flag that skips an addition. The mapping from
##      placement to order class is one total `case`, so a fourth placement
##      does not compile until it has been given an order.
##
## =========================================================================
## THE INLINE WIDGET'S WIDTH IS A NUMBER THIS MODEL CARRIES
## =========================================================================
##
## §8.3's complaint about the web front-end is that the width is *"a hard-coded
## constant in a stylesheet that no ViewModel can see or budget"*. So an
## inline widget declares `cells`, and `inlay.nim` is what turns that number
## into columns the wrap point moves for. Nothing about a renderer appears in
## this file.

import ./anchor
import ./change_set
import ./range_set

export anchor, change_set, range_set

type
  DecorationKind* = enum
    ## §8.1's four, as a Nim variant.
    dkMark          ## style a range
    dkInlineWidget  ## content INSIDE a line, occupying columns
    dkBlockWidget   ## content BETWEEN lines, occupying rows
    dkLine          ## attributes for a whole line

  BlockPlacement* = enum
    ## Where a block widget sits relative to its line, and the third member is
    ## §8.1's *"one exception the reference supports"* made a variant.
    bpAbove
    bpBelow
    bpAmongInline

  DecoOrderClass* = enum
    ## **THE ORDERED ENUM. DECLARATION ORDER IS THE ORDER**, which is the whole
    ## content of the type: there is no constant, no band and no arithmetic.
    ocBlockBefore
    ocLine
    ocInlineBefore
    ocInlineAfter
    ocBlockAfter

  DecoOrder* = object
    ## Compared lexicographically, class first. `LAW-D5`'s published killer is
    ## *"compare the offset before the enum"*, which is one swapped line here
    ## and is the reason the comparison is a named routine rather than a tuple
    ## literal at each call site.
    cls*: DecoOrderClass
    offset*: int

  DecorationPayload* = object
    ## The four arms. Every arm carries only what that arm means, which is what
    ## makes `dkMark` with a widget width unrepresentable.
    case kind*: DecorationKind
    of dkMark:
      markClass*: string    ## the style name; a renderer decides what it looks like
    of dkInlineWidget:
      cells*: int           ## §8.3: the width the MODEL owns
      inlineText*: string   ## what the widget shows, for a medium that draws text
    of dkBlockWidget:
      rows*: int            ## vertical space, in display rows
      placement*: BlockPlacement
      blockText*: string
    of dkLine:
      lineClass*: string

  Decoration* = object
    ## A range value plus what to draw. The range is `range_set`'s, so
    ## `mapRangeSet` and `compareOver` apply unchanged — which is §8.0's
    ## *"build it before building decorations"* paying off rather than being
    ## quoted.
    value*: RangeValue
    payload*: DecorationPayload
    order*: DecoOrder

  DecorationSet* = object
    ## The decorations, and the range set they live in. Two fields rather than
    ## one because the range set is the SHARED structure and the payloads are
    ## this module's; keeping them apart is what lets a gutter, an atomic-range
    ## table and a remote-caret list be three `RangeSet`s over one type.
    ranges*: RangeSet
    payloads*: seq[Decoration]

  DecorationGapId* = enum
    ## A filed gap's own name, the shape `editor_rows.EditorProducerGapId`
    ## already uses so a status block, a comment and a case all spell it the
    ## same way.
    dgHideARangeIsNotExpressible = "PLAT28-DG1"
    dgInlaysHaveNoProducer = "PLAT28-DG2"
    dgLineTerminatorsDiverge = "PLAT28-DG3"
    dgValueWidthIsBytes = "PLAT28-DG4"

  DecorationGap* = object
    id*: DecorationGapId
    subject*: string
    measurement*: string
    remedy*: string

  DecorationError* = object of ValueError

const
  DecoOffsetBound* = 10_000
    ## The reference's own bound, kept so the two models are comparable, and
    ## enforced by a `raise` where the reference clamps. See the header's
    ## second point.

  DecorationKindCount* = ord(high(DecorationKind)) - ord(low(DecorationKind)) + 1
    ## **FOUR, DERIVED FROM THE ENUM.** PLAT-28's floor multiplies it by
    ## `LAW-D5`'s four order axioms; §10.4's third rule.

  DecoOrderClassCount* = ord(high(DecoOrderClass)) - ord(low(DecoOrderClass)) + 1

  BlockPlacementCount* = ord(high(BlockPlacement)) - ord(low(BlockPlacement)) + 1

  FiledDecorationGaps*: array[DecorationGapId, DecorationGap] = [
    dgHideARangeIsNotExpressible: DecorationGap(
      id: dgHideARangeIsNotExpressible,
      subject: "viewmodel",
      measurement: "CodeMirror's `Decoration` has a `replace` kind — hide a " &
        "range, optionally showing a widget. PLAT-28's deliverable names FOUR " &
        "arms and `replace` is not among them, so hiding a span is not " &
        "expressible by this taxonomy. Nothing in CodeTracer asks for it " &
        "today: the four surfaces §8.1 tabulates are a line attribute, a " &
        "gutter mark, an inline widget and a block widget, and none of them " &
        "hides text.",
      remedy: "a fifth arm, if and when a surface needs it — folding, or a " &
        "collapsed macro expansion. It is NOT a field on `dkMark`, which is " &
        "the shape this taxonomy exists to avoid."),
    dgInlaysHaveNoProducer: DecorationGap(
      id: dgInlaysHaveNoProducer,
      subject: "viewmodel",
      measurement: "§8.1's taxonomy lists `Inlays / type hints` as an inline " &
        "widget and Editor-ViewModel.md §16 records that nothing in the " &
        "product computes them. PLAT-28 carries the MECHANISM: the reflow " &
        "gate below is exercised by INLINE VALUES, which do have a producer " &
        "(`editor_surface.inlineValuesOf` reads `StateVM.currentVariables`). " &
        "An inlay decoration can be constructed and it reflows exactly as an " &
        "inline value does; no code path constructs one.",
      remedy: "LSP inlay hints through `nim-langserver`, which is in the " &
        "workspace. §16 does not decide whether they arrive with LSP or " &
        "before it, and this milestone does not decide it either."),
    dgLineTerminatorsDiverge: DecorationGap(
      id: dgLineTerminatorsDiverge,
      subject: "front-end",
      measurement: "`editor_surface.editorSurfaceForProject` splits its text " &
        "with `strutils.splitLines`, which breaks on a LONE CR and on CRLF. " &
        "The model splits on '\\n' only — `text_store`, `wrap` and " &
        "`row_projection` must agree about how many lines a document has or " &
        "LAW-C4's partition is false, and PLAT-24's `unrepresentable.tsv` " &
        "row 1 is the same fact from the store's side. On a document " &
        "carrying a CRLF and then a lone CR the two answer THREE rows and " &
        "TWO. Measured by a " &
        "named case in `test_editor_decoration_examples.nim` rather than " &
        "avoided by choosing documents that cannot show it.",
      remedy: "decide, in a GUI spec, what a line terminator is for EDIT " &
        "mode, and move whichever side is wrong. It is the reason " &
        "`editor_surface.nim` is not rewired onto `row_projection` by " &
        "PLAT-28: rewiring would change edit-mode line counting in " &
        "production for every file containing a CR."),
    dgValueWidthIsBytes: DecorationGap(
      id: dgValueWidthIsBytes,
      subject: "viewmodel",
      measurement: "`row_projection.valueWidth` counts BYTES, because that " &
        "module imports neither `wrap` nor `inlay` — which is what keeps it " &
        "callable from `view_vocabulary/editor_surface.nim` without putting " &
        "`isonim_tui/text/width` into the `gpui-shell` lane's compile. On " &
        "ASCII the byte count and the cell count agree; on a CJK value they " &
        "do not, and a widget sized with it would reserve the wrong number " &
        "of cells.",
      remedy: "a producer that builds an inline-value widget measures it " &
        "with `wrap.cellsOf`, which is what every LAW-C7 cell and the reflow " &
        "gate's own widget do. `valueWidth` is for a caller that wants a " &
        "byte length and knows it.")]
    ## **THE FILED GAPS, AS DATA.** PLAT-22's `FiledEditorGaps` shape, reused
    ## rather than re-derived. `PLAT22-PG1` (marks have no production producer)
    ## and `PLAT22-PG2` (no per-line flow fact) are INHERITED and stay filed
    ## against their existing ids in `editor_rows.nim`: this milestone carries
    ## the mechanism, not the producers, and these two are its own additions to
    ## that register rather than a second register.

func decoOrder*(cls: DecoOrderClass; offset = 0): DecoOrder =
  ## **THE ONLY CONSTRUCTOR, AND IT RAISES WHERE THE REFERENCE CLAMPS.**
  ##
  ## §36a: *"a guard that repairs a value silently must be a guard that RAISES,
  ## unless the repair is itself a specified behaviour with a name"*. Clamping
  ## an offset is not a behaviour — it silently makes two decorations that were
  ## ordered compare EQUAL, and the first wrong paint order is then the
  ## thousandth.
  if offset < -DecoOffsetBound or offset > DecoOffsetBound:
    raise newException(DecorationError,
      "decoOrder: offset " & $offset & " is outside ±" & $DecoOffsetBound &
      ". It is REFUSED, not clamped: the reference clamps here, and a clamp " &
      "makes two distinguishable orders compare equal with nothing saying so.")
  DecoOrder(cls: cls, offset: offset)

func `<`*(a, b: DecoOrder): bool =
  ## **LEXICOGRAPHIC, CLASS FIRST.** One line, and swapping the two comparisons
  ## is `LAW-D5`'s published killer.
  if a.cls != b.cls: return ord(a.cls) < ord(b.cls)
  a.offset < b.offset

func `==`*(a, b: DecoOrder): bool = a.cls == b.cls and a.offset == b.offset

func `<=`*(a, b: DecoOrder): bool = a < b or a == b

func `$`*(o: DecoOrder): string = $o.cls & "+" & $o.offset

func orderClassOf*(p: BlockPlacement): DecoOrderClass =
  ## **ONE TOTAL `case`, NO `else`.** A fourth placement does not compile until
  ## it has been given an order, which is the property a flag cannot have.
  case p
  of bpAbove: ocBlockBefore
  of bpBelow: ocBlockAfter
  of bpAmongInline: ocInlineBefore

func defaultOrderOf*(payload: DecorationPayload): DecoOrder =
  ## The order class a decoration takes when its caller does not name one.
  ## Total over the four arms, again with no `else`.
  case payload.kind
  of dkMark: decoOrder(ocInlineBefore)
  of dkInlineWidget: decoOrder(ocInlineBefore)
  of dkBlockWidget: decoOrder(orderClassOf(payload.placement))
  of dkLine: decoOrder(ocLine)

func isBlock*(payload: DecorationPayload): bool = payload.kind == dkBlockWidget
  ## Block-ness read off the ARM. There is no field to disagree with it.

func widthCells*(payload: DecorationPayload): int =
  ## The columns a decoration occupies on its line. Only an inline widget
  ## occupies any — a block widget occupies ROWS, and reporting its `rows` here
  ## would be the conflation the four arms exist to prevent.
  case payload.kind
  of dkInlineWidget: payload.cells
  of dkMark, dkBlockWidget, dkLine: 0

func markPayload*(markClass: string): DecorationPayload =
  DecorationPayload(kind: dkMark, markClass: markClass)

func inlineWidget*(cells: int; text = ""): DecorationPayload =
  ## An inline widget's width is REFUSED when negative, for §36a's reason: a
  ## negative width would pull the text after it backwards over text that is
  ## already painted, and clamping it to zero would make a defect look like a
  ## widget nobody asked for.
  if cells < 0:
    raise newException(DecorationError,
      "inlineWidget: " & $cells & " cells. A width is not clamped to zero; a " &
      "negative one is a defect in whatever measured the widget.")
  DecorationPayload(kind: dkInlineWidget, cells: cells, inlineText: text)

func blockWidget*(rows: int; placement = bpBelow;
                  text = ""): DecorationPayload =
  if rows < 0:
    raise newException(DecorationError,
      "blockWidget: " & $rows & " rows, refused rather than clamped.")
  DecorationPayload(kind: dkBlockWidget, rows: rows, placement: placement,
                    blockText: text)

func linePayload*(lineClass: string): DecorationPayload =
  DecorationPayload(kind: dkLine, lineClass: lineClass)

func `==`*(a, b: DecorationPayload): bool =
  ## Written out rather than generated: Nim's structural `==` refuses a `case`
  ## object, the same cost `change_set.Section` pays and for the same reason.
  if a.kind != b.kind: return false
  case a.kind
  of dkMark: a.markClass == b.markClass
  of dkInlineWidget: a.cells == b.cells and a.inlineText == b.inlineText
  of dkBlockWidget:
    a.rows == b.rows and a.placement == b.placement and
      a.blockText == b.blockText
  of dkLine: a.lineClass == b.lineClass

func `$`*(p: DecorationPayload): string =
  case p.kind
  of dkMark: "mark(" & p.markClass & ")"
  of dkInlineWidget: "inline(" & $p.cells & " cells, '" & p.inlineText & "')"
  of dkBlockWidget: "block(" & $p.rows & " rows, " & $p.placement & ")"
  of dkLine: "line(" & p.lineClass & ")"

func decoration*(id, fromPos, toPos: int; payload: DecorationPayload;
                 fromSide = sideBefore; toSide = sideAfter;
                 mode = rmTrack;
                 order = DecoOrder(cls: ocInlineBefore, offset: 0);
                 useDefaultOrder = true): Decoration =
  ## A decoration is a range value with a payload. `pointness` is DERIVED from
  ## the arm rather than taken as an argument: a widget is meaningful on its
  ## own (`rpPoint`), a mark styles a span (`rpMark`), and a line attribute is
  ## a point on its line. A caller that could pass the wrong one is a caller
  ## who will.
  let pointness = case payload.kind
                  of dkMark: rpMark
                  of dkInlineWidget, dkBlockWidget, dkLine: rpPoint
  Decoration(
    value: rangeValue(id, fromPos, toPos, fromSide, toSide, mode, pointness,
                      asDecorationRange),
    payload: payload,
    order: if useDefaultOrder: defaultOrderOf(payload) else: order)

func `==`*(a, b: Decoration): bool =
  a.value == b.value and a.payload == b.payload and a.order == b.order

func `$`*(d: Decoration): string =
  $d.value & " " & $d.payload & " @" & $d.order

func decorationSet*(ds: openArray[Decoration];
                    chunkSize = DefaultChunkSize): DecorationSet =
  var vs: seq[RangeValue] = @[]
  for d in ds: vs.add d.value
  result.ranges = rangeSet(vs, chunkSize)
  result.payloads = @ds

func len*(s: DecorationSet): int = s.payloads.len

func decorationById*(s: DecorationSet; id: int): Decoration =
  for d in s.payloads:
    if d.value.id == id: return d
  raise newException(DecorationError,
    "decorationById: no decoration with id " & $id & ". Refused rather than " &
    "answered with a zero value: a default-constructed decoration is a " &
    "`dkMark` with an empty class, which draws as nothing and looks exactly " &
    "like a decoration that is simply not visible here.")

proc mapDecorationSet*(s: DecorationSet; cs: ChangeSet;
                       st: var MapStats): DecorationSet =
  ## **THE SET MOVES THROUGH §8.0's MAPPING, NOT THROUGH ONE WRITTEN HERE.**
  ## The payloads ride along by id; a decoration whose range was dropped
  ## (`rmDropWhenTouched`) loses its payload with it, which is the only place a
  ## payload can leave.
  let moved = mapRangeSet(s.ranges, cs, st)
  result.ranges = moved
  result.payloads = @[]
  for v in moved.allValues():
    for d in s.payloads:
      if d.value.id == v.id:
        var nd = d
        nd.value = v
        result.payloads.add nd
        break

func sortedAtPosition*(s: DecorationSet; pos: int): seq[Decoration] =
  ## **EVERY DECORATION AT ONE POSITION, IN ORDER** — the total order `LAW-D5`
  ## is about, applied.
  ##
  ## The sort is an insertion sort and it is STABLE, which is the law's third
  ## axiom: two decorations with equal `DecoOrder` come back in the order they
  ## were declared in. A `sort` that was not stable would make the paint order
  ## of two equally-ordered widgets depend on the algorithm's pivot choice.
  result = @[]
  for d in s.payloads:
    if d.value.fromAnchor.pos != pos: continue
    var i = result.len
    while i > 0 and d.order < result[i - 1].order:
      dec i
    result.insert(d, i)
