## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/styled_row.nim — CTUI-5. A screen row that carries STYLE, and the
## one place that knows how to hand such a row to the compositor.
##
## ## Why CTUI-5 needed this and CTUI-3 did not
##
## CTUI-3's shell paints `height` strings of exactly `width` cells and emits one
## `div` per row. A string cannot say that column 4 is a red breakpoint dot and
## column 9 is a green string literal, and CTUI-5's whole subject — the gutter's
## `●`/`○`/`◆`, the execution pointer's accent, tree-sitter token classes, the
## heatmap's flame spectrum — is per-CELL style. So the grid the shell paints
## into gains a style per cell, and a row becomes a run-length encoded sequence
## of `StyledSpan`s rather than one string.
##
## `rowText` is kept and is byte-identical to what CTUI-3's grid produced, so
## every CTUI-3 assertion written against `shellRows` still reads the same
## screen.
##
## ## HOW TWO STYLES LAND ON ONE ROW, measured rather than assumed
##
## `app/views/shell.nim`'s header records that isonim-tui's compositor "does
## NOT put two entries on the same ROW" — `walkLayoutImpl` increments one row
## counter per emitted entry. That is true of a tree of nested BOXES, and it is
## not the whole rule. Read again at `isonim-tui/src/isonim_tui/compositor.nim`
## (the `allText` branch, lines 385-418): a box whose children are ALL TEXT
## NODES and at least one of which carries its own style is emitted as
## **one `LayoutEntry` per child, at adjacent columns, on the same row**, each
## with its own resolved foreground, background and attribute set. That branch
## is what this module targets, and it is why a styled row is built as
##
##     div
##       text "  42 "   (style: line number)
##       text "-->"     (style: pointer accent)
##       text " def "   (style: keyword)
##
## rather than as nested boxes. `paintEntryOnto` clamps an entry's
## `fillBackground` to `[col, col+width)`, so a span with a background — the
## execution line's highlight — masks its own columns and no sibling's.
##
## A row whose spans are ALL unstyled takes the other branch of the same `if`
## and fuses into a single entry, which is exactly CTUI-3's shape. So a screen
## with no source pane on it emits precisely the bytes it emitted before this
## milestone.
##
## ## Colours are ANSI NAMES, and that is a cross-tier decision
##
## `compositor.parseColorOrDefault` accepts `default`, the sixteen ANSI names
## and `#RRGGBB`. Only the sixteen names are used here, because
## `testing/dual_snap.nim`'s `ansi16-is-indexed` canonicalisation maps Tier 1's
## `ckAnsi n` and Tier 2's `ckIndexed n` onto one value — so a name is a colour
## the cross-tier comparison still FAILS on when it differs, while `#RRGGBB`
## would land as `cckRgb` on one side and as whatever the terminal's palette
## approximated on the other.
##
## `dim` is deliberately NOT in `CellStyle`. libvterm's cell model has no dim
## bit (`dual_snap.CrossTierExclusions`, `dim-has-no-tier-2-representation`), so
## a muted line number expressed as `dim` would be a style Tier 2 cannot see and
## the cross-tier equality could not check. §3.3.2's "muted styling" is
## `bright_black` here, which both tiers report as indexed colour 8.

import std/[sequtils, strutils, unicode]

import isonim_tui

type
  CellStyle* = object
    ## Everything one cell can carry that both tiers can observe.
    ##
    ## A value with `==` derived, because the row encoder below groups adjacent
    ## cells by style equality and a hand-written comparison would be one more
    ## thing to keep true.
    fg*: string
      ## An ANSI colour name, or "" for the terminal default.
    bg*: string
    bold*: bool
    italic*: bool
    underline*: bool
    reverse*: bool

  StyledSpan* = object
    ## A run of cells sharing one style.
    text*: string
    style*: CellStyle

  StyledRow* = seq[StyledSpan]
    ## One screen row. The concatenation of the spans' text is the row's text.

  StyledCell = object
    rune: string
      ## One cell's text. "" is the ZERO-WIDTH trailing half of a wide glyph —
      ## the same convention `app/views/shell.nim`'s grid uses, kept identical
      ## so a row's cell count is still its column count.
    style: CellStyle

  StyledGrid* = object
    ## A mutable screen of styled cells.
    width*: int
    height*: int
    cells: seq[StyledCell]

const DefaultCellStyle* = CellStyle()
  ## The terminal's own colours and no attributes. Named so a caller can say
  ## "unstyled" rather than spelling an empty object.

# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

func isDefault*(s: CellStyle): bool =
  ## Whether this style asks the renderer for nothing at all. A span with a
  ## default style contributes no `setStyle` call, which is what lets a whole
  ## row of them fuse into one `LayoutEntry`.
  s == DefaultCellStyle

func attrNames*(s: CellStyle): seq[string] =
  ## The boolean attributes set on `s`, as the style names
  ## `compositor.styleFor` reads. Sorted by declaration order rather than
  ## alphabetically, so a failure message lists them the same way twice.
  result = @[]
  if s.bold: result.add "bold"
  if s.italic: result.add "italic"
  if s.underline: result.add "underline"
  if s.reverse: result.add "reverse"

func describe*(s: CellStyle): string =
  ## One line for a failure message. Never used to make a decision.
  var parts: seq[string] = @[]
  parts.add "fg=" & (if s.fg.len > 0: s.fg else: "default")
  parts.add "bg=" & (if s.bg.len > 0: s.bg else: "default")
  let attrs = s.attrNames()
  parts.add "attrs={" & attrs.join(",") & "}"
  parts.join(" ")

func withBackground*(s: CellStyle; bg: string): CellStyle =
  ## `s` with its background replaced. The execution line's highlight is
  ## applied this way — over the gutter's and the syntax highlighter's own
  ## foregrounds — so that "the current line is highlighted" does not throw
  ## away "this token is a string literal".
  result = s
  result.bg = bg

# ---------------------------------------------------------------------------
# The grid
# ---------------------------------------------------------------------------

proc newStyledGrid*(width, height: int): StyledGrid =
  result = StyledGrid(width: max(0, width), height: max(0, height), cells: @[])
  result.cells = newSeq[StyledCell](result.width * result.height)
  for i in 0 ..< result.cells.len:
    result.cells[i] = StyledCell(rune: " ", style: DefaultCellStyle)

proc paint*(g: var StyledGrid; row, col: int; text: string;
            style = DefaultCellStyle) =
  ## Write `text` starting at `(row, col)` in `style`, clipped at the grid's
  ## edges.
  ##
  ## Wide glyphs occupy their first cell and put a ZERO-WIDTH marker in the
  ## second, exactly as CTUI-3's grid does, so a pane that prints a CJK
  ## identifier does not shift every cell after it.
  if row < 0 or row >= g.height:
    return
  var c = col
  for r in runes(text):
    if c >= g.width:
      break
    let w = displayWidth($r)
    if c >= 0:
      g.cells[row * g.width + c] = StyledCell(rune: $r, style: style)
      if w == 2 and c + 1 < g.width:
        g.cells[row * g.width + c + 1] = StyledCell(rune: "", style: style)
    c += max(1, w)

proc restyle*(g: var StyledGrid; row, col, width: int;
              transform: proc(s: CellStyle): CellStyle) =
  ## Apply `transform` to every cell of `[col, col+width)` on `row`, leaving
  ## the runes alone.
  ##
  ## This is how the execution line's background highlight is painted: over
  ## cells whose foregrounds have already been decided by the gutter and the
  ## highlighter. Painting the background FIRST and the text over it would lose
  ## the background on every cell the text writes.
  if row < 0 or row >= g.height:
    return
  for c in max(0, col) ..< min(g.width, col + width):
    let i = row * g.width + c
    g.cells[i].style = transform(g.cells[i].style)

proc styleAt*(g: StyledGrid; row, col: int): CellStyle =
  ## The style of one cell. `DefaultCellStyle` outside the grid, so a test that
  ## reads past the edge gets an answer rather than a crash — every caller here
  ## asserts a coordinate it computed from the grid's own geometry.
  if row < 0 or row >= g.height or col < 0 or col >= g.width:
    return DefaultCellStyle
  g.cells[row * g.width + col].style

proc runeAt*(g: StyledGrid; row, col: int): string =
  if row < 0 or row >= g.height or col < 0 or col >= g.width:
    return " "
  g.cells[row * g.width + col].rune

proc rowText*(g: StyledGrid; row: int): string =
  ## The row as text — byte-identical to what CTUI-3's `Grid.rowText`
  ## produced for the same runes.
  result = ""
  if row < 0 or row >= g.height:
    return
  for c in 0 ..< g.width:
    result.add g.cells[row * g.width + c].rune

proc rowSpans*(g: StyledGrid; row: int): StyledRow =
  ## The row, run-length encoded by style.
  ##
  ## Adjacent cells sharing a style become one span, which matters for more
  ## than tidiness: each span is one `LayoutEntry` and one strip-cache key, so
  ## a row split into 80 single-cell spans would be 80 cache misses per frame
  ## and would put the single-step emission budget out of reach.
  result = @[]
  if row < 0 or row >= g.height or g.width <= 0:
    return
  var current = g.cells[row * g.width]
  var text = current.rune
  for c in 1 ..< g.width:
    let cell = g.cells[row * g.width + c]
    if cell.style == current.style:
      text.add cell.rune
    else:
      result.add StyledSpan(text: text, style: current.style)
      current = cell
      text = cell.rune
  result.add StyledSpan(text: text, style: current.style)

proc rowSpansIn*(g: StyledGrid; row, col, width: int): StyledRow =
  ## The `[col, col+width)` cells of `row`, run-length encoded by style.
  ##
  ## A pane owns a RECTANGLE of a shared screen, so a pane's own rows are a
  ## horizontal slice of the grid's. Written as its own walk rather than as a
  ## slice of `rowSpans`, because slicing an already-encoded row would have to
  ## cut a span in the middle and re-measure it in cells — the same arithmetic,
  ## done twice, with one more place to be wrong.
  result = @[]
  let lo = max(0, col)
  let hi = min(g.width, col + width)
  if row < 0 or row >= g.height or hi <= lo:
    return
  var current = g.styleAt(row, lo)
  var text = g.runeAt(row, lo)
  for c in lo + 1 ..< hi:
    let style = g.styleAt(row, c)
    if style == current:
      text.add g.runeAt(row, c)
    else:
      result.add StyledSpan(text: text, style: current)
      current = style
      text = g.runeAt(row, c)
  result.add StyledSpan(text: text, style: current)

func rowText*(row: StyledRow): string =
  ## The text of a already-encoded row.
  row.mapIt(it.text).join("")

proc cellCount*(row: StyledRow): int =
  ## How many terminal cells the row occupies.
  for span in row:
    for r in runes(span.text):
      result += max(1, displayWidth($r))

# ---------------------------------------------------------------------------
# Handing a row to the compositor
# ---------------------------------------------------------------------------

proc styledRowNode*(r: TerminalRenderer; row: StyledRow): TerminalNode =
  ## One screen row as a `div` of styled text children.
  ##
  ## See this module's header: the compositor emits one entry per child, at
  ## adjacent columns, IF AND ONLY IF at least one child carries a style. A row
  ## with none fuses into a single entry — the same thing CTUI-3's shell
  ## produced — which is why a screen with no styled pane on it emits
  ## byte-identical output to the pre-CTUI-5 shell.
  result = r.createElement("div")
  for span in row:
    if span.text.len == 0:
      continue
    let node = r.createTextNode(span.text)
    if span.style.fg.len > 0:
      r.setStyle(node, "color", span.style.fg)
    if span.style.bg.len > 0:
      r.setStyle(node, "background-color", span.style.bg)
    for a in span.style.attrNames():
      r.setStyle(node, a, "true")
    r.appendChild(result, node)

proc styledRowsTree*(r: TerminalRenderer; rows: seq[StyledRow]): TerminalNode =
  ## A whole frame: one `div` per screen row.
  result = r.createElement("div")
  for row in rows:
    r.appendChild(result, styledRowNode(r, row))

# ---------------------------------------------------------------------------
# Small text helpers the pane modules share
# ---------------------------------------------------------------------------

proc padLeft*(s: string; width: int): string =
  ## `s` right-aligned in `width` CELLS (not bytes, not runes).
  var cells = 0
  for r in runes(s):
    cells += max(1, displayWidth($r))
  if cells >= width:
    return s
  repeat(' ', width - cells) & s

proc pathBaseName*(path: string): string =
  ## The last component of a recorded path, splitting on BOTH separators.
  ##
  ## `std/os.extractFilename` is not used, for the reason
  ## `ct/trace/ctfs_sources.safePayloadPath` was fixed for in CTUI-4: a recorded
  ## path is whatever a recorder interned, a Windows recording carries
  ## backslashes, and a splitter that knows only its own host's separator shows
  ## the whole path as the "file name" on the other host. It also keeps
  ## `std/os` out of a view.
  ##
  ## LIVES HERE RATHER THAN IN `source_pane.nim`, where CTUI-5 put it: CTUI-6's
  ## `frame_item.nim` needs the same rule, and a second copy made every call
  ## site that imported both modules ambiguous.
  result = path
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      return path[i + 1 .. ^1]

proc cellWidthOf*(s: string): int =
  ## How many terminal cells `s` occupies.
  for r in runes(s):
    result += max(1, displayWidth($r))

proc cellSlice*(s: string; startCell, endCell: int): string =
  ## The `[startCell, endCell)` CELLS of `s`.
  ##
  ## By cell rather than by byte or by rune, because a syntax span is expressed
  ## in cells (see `app/syntax/highlighter.SyntaxSpan`) and a line may hold a
  ## wide glyph. A wide glyph straddling the boundary is included when its
  ## FIRST cell is inside, which keeps the slice's cell count right — dropping
  ## it would shift everything after it left by two columns.
  ##
  ## LIVES HERE RATHER THAN IN `source_pane.nim`, WHERE CTUI-5 PUT IT: CTUI-6's
  ## `frame_item.nim` needs the same cell arithmetic and must not import a pane
  ## to get it. `source_pane` re-exports this module, so every CTUI-5 call site
  ## resolves unchanged.
  result = ""
  var at = 0
  for r in runes(s):
    let w = max(1, displayWidth($r))
    if at >= endCell:
      break
    if at >= startCell:
      result.add $r
    at += w

proc truncateToCells*(s: string; cells: int): string =
  ## `s` clipped to `cells` columns.
  if cells <= 0: "" else: cellSlice(s, 0, cells)
