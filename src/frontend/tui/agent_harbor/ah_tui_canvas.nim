## tui/agent_harbor/ah_tui_canvas.nim — CTF-P1b. What the terminal views of
## CodeTracer as an Agent Harbor front-end draw ON: a grid of styled cells, the
## facts a reader needs to find in it, the areas it is divided into, and the
## places a click or a hover lands.
##
## ## Where this sits
##
## Beside `app/`, `host/` and `testing/`, as `gpui/agent_harbor/` sits beside
## the GPUI shell: the Agent Harbor views read the Agent Harbor viewmodels
## (nim-agents-isonim-viewmodels), which `app/`'s layer rule does not admit,
## and nothing in `main.nim` reaches them yet. They draw into `app/`'s
## `StyledGrid` and leave a frame to `app/views/styled_row.styledRowsTree`,
## so the bytes a terminal receives are the ones every other pane's are.
##
## ## Colours
##
## Every colour is a design-system role resolved by
## `viewmodel/views/agent_harbor_palette.nim` — the resolution GPUI uses — and
## painted as a LITERAL 24-bit colour (`CellStyle.fg` / `.bg`). The Agent
## Harbor views paint the web's design-system roles in both modes, which
## the debugger's `SemanticRole` table does not carry. The story host (`ah_tui_story_host.nim`) writes them as they
## are, so it wants a truecolor terminal; when the views join the shell, the
## shell's negotiated tier applies to them as to any literal colour
## (`app/theme/degradation.projectStyle`). Every cell of a frame has a
## background, so no area falls back on the terminal's own.
##
## The palette's translucent `selectedTint` (`#rrggbbaa`) is blended over the
## panel here, since a terminal cell has no alpha.
##
## ## Areas, not boxes
##
## A view marks each area it separates — a frame's header, a section head, a
## list, a band, a menu — with `area`, which paints the area's background and
## records its rectangle. Nothing here draws a box: an area is told from its
## neighbour by its background, and `test_ctf_p1b_tui_no_box_borders_between_
## areas.nim` holds every story to that, over the cells actually drawn.
##
## ## Facts
##
## The views tag what they draw the way the GPUI views do (`data-ah-*`): a
## `AhNode` carries name/value facts and the rectangle it occupies, nested as
## the drawing is. The CTF-P1b coverage test reads the drawing back through
## them and compares it with the viewmodel; a text fact (`label`, `title`, …)
## is also compared with the cells under its node, so a fact cannot say one
## word while the cells show another.
##
## ## Cells and pixels
##
## The web and GPUI lay out in CSS pixels, and the viewmodels' single-line
## layouts count in the renderer's unit. The terminal counts a cell as 8×16
## pixels (`CellPx`; a row is 16): a 180×56 terminal is the brief's laptop
## 1440×900 and 45×56 its 360×900 sidebar, and a viewmodel told the strip is
## `cols * CellPx` wide picks the same tabs for the terminal as for the web at
## that size. A width the stylesheet states in pixels is drawn as
## `cellsOf(px)` cells.

import std/strutils
from std/unicode import runes, Rune, `$`, runeAtPos

import ../app/views/styled_row
import isonim/viewmodel
import nim_agents_isonim_viewmodels/agent_harbor/data_source
import ../../viewmodel/views/agent_harbor_palette

export styled_row, agent_harbor_palette, data_source, viewmodel

const
  CellPx* = 8
    ## One terminal column in CSS pixels (the brief's sizes: 1440 px = 180
    ## columns, 360 px = 45).
  Ellipsis* = "\xE2\x80\xA6"
  Middot* = " \xC2\xB7 "
  DotGlyph* = "\xE2\x97\x8F"     ## ● a filled status mark
  RingGlyph* = "\xE2\x97\x8B"    ## ○ a hollow one (idle, planned)
  FoldedGlyph* = "\xE2\x96\xB8"  ## ▸ (what expands)
  UnfoldedGlyph* = "\xE2\x96\xBE" ## ▾
  BarGlyph* = "\xE2\x96\x8E"     ## ▎ an inset bar down a row's left edge

type
  AhNode* = ref object
    ## One drawn element and the facts it carries (the GPUI views'
    ## `data-ah-*` attributes), with the cells it covers.
    facts*: seq[(string, string)]
    row*, col*, width*, height*: int
    children*: seq[AhNode]

  AhArea* = object
    ## A region the view separates from its neighbours by background.
    name*: string
    row*, col*, width*, height*: int
    bg*: string

  AhTarget* = object
    ## Where a press (`click`) or a pointer (`hover`) acts. Later targets
    ## are drawn over earlier ones and win.
    row*, col*, width*, height*: int
    click*: proc() {.closure.}
    hover*: proc() {.closure.}

  AhCanvas* = object
    grid*: StyledGrid
    p*: AhPalette
    tone*: AhTone
      ## The area surfaces of `p`'s mode (`tone`).
    root*: AhNode
    areas*: seq[AhArea]
    targets*: seq[AhTarget]
    leave*: seq[proc() {.closure.}]
      ## What a pointer leaving every hover target does (a popup closing).

  AhTone* = object
    ## The surfaces the views separate areas by, resolved for one mode from the
    ## palette's roles. Each is a design-system role; which role plays which
    ## part is the terminal's own choice (the web draws hairlines there).
    frame*: string   ## the window and a panel frame's header row: surface/primary/default
    body*: string    ## a panel body, a list: surface/base/panel
    head*: string    ## a section head band (title, filters, columns)
    band*: string    ## a striped row (Dark: the web's `bandOf`; Light: lighter, see `tone`)
    group*: array[2, string]
      ## A group or status header between rows, by its index's parity: two
      ## folded groups are neighbours, and must not share a ground. Where
      ## the web draws a hairline under each header, the terminal changes
      ## the ground instead.
    filters*: string ## the fleet's filter strip, between two head bands
    menu*: string    ## a dropdown, a popup: surface/base/card
    chip*: string    ## a control's own ground (+, +N, a badge, Retry)
    chosen*: string  ## the active filter chip

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------

proc hexByte(s: string; at: int): int = parseHexInt(s[at .. at + 1])

proc blendOver*(top, under: string): string =
  ## `top` (`#rrggbbaa`) composited over the opaque `under` (`#rrggbb`):
  ## straight-alpha source-over (https://www.w3.org/TR/compositing-1/#simplealphacompositing).
  ## A `#rrggbb` top is returned as it is.
  if top.len != 9: return top
  let a = float(hexByte(top, 7)) / 255.0
  result = "#"
  for i in [1, 3, 5]:
    let v = int(float(hexByte(top, i)) * a + float(hexByte(under, i)) * (1.0 - a) + 0.5)
    result.add toHex(clamp(v, 0, 255), 2).toLowerAscii

proc tokenHexOf*(token: DesignToken; mode: DesignMode): string =
  DesignTokenHex[token][mode]

proc tone*(p: AhPalette): AhTone =
  ## The terminal's area surfaces. Dark steps away from the panel (#282828)
  ## both ways — the frame and the group headers darker, the head band
  ## lighter — and Light likewise around its warm panel, so two neighbouring
  ## areas never share a ground.
  let dark = p.mode == dmDark
  AhTone(frame: p.ground, body: p.panel,
         head: (if dark: p.hover else: p.menu),
         # Light's stripe is the window's ground, a step LIGHTER than the
         # panel: on the card (the web's band) the status words fell to
         # about 2.3:1 (green `running` on #dbd6cc), below their 2.5:1 on
         # the panel itself; on this ground they read at about 3:1.
         band: (if dark: p.hover else: p.ground),
         # surface/base/raised: a step off the window's ground in both modes
         # (#161616 against #1b1b1b, #f3f3f3 against #f8f6f2), so a group
         # header at a sidebar's edge is not read as the window.
         group: [tokenHexOf(dtColorsUiSurfaceBaseRaised, p.mode),
                 (if dark: p.hover else: p.menu)],
         filters: tokenHexOf(dtColorsUiSurfaceBaseRaised, p.mode),
         menu: p.menu,
         # Dark's tertiary is its stripe's ground: a chip on a stripe takes
         # the next grey up.
         chip: (if dark: p.activeTab else: p.tertiary),
         chosen: p.activeTab)

proc stripeOn*(t: AhTone; p: AhPalette; ground: string; besides = ""): string =
  ## The ground of every other item of a list drawn on `ground`: the band,
  ## or the next role that differs from `ground` (and from `besides`, the
  ## ground the list lies against: a menu's window) where the band is one of
  ## them (Light's band is the window's ground).
  for candidate in [t.band, p.hover, t.filters]:
    if candidate != ground and candidate != besides: return candidate
  t.band

proc selectedGround*(p: AhPalette): string =
  ## The selected initiative's ground: the palette's tint over the panel.
  blendOver(p.selectedTint, p.panel)

# ---------------------------------------------------------------------------
# The canvas
# ---------------------------------------------------------------------------

proc cellsOf*(px: int): int =
  ## A stylesheet width in cells, rounded to the nearest (at least one for a
  ## positive width).
  if px <= 0: 0 else: max(1, (px + CellPx div 2) div CellPx)

proc newAhCanvas*(cols, rows: int; p: AhPalette): AhCanvas =
  result = AhCanvas(grid: newStyledGrid(cols, rows), p: p, tone: tone(p),
                    root: AhNode(width: cols, height: rows))

proc cols*(c: AhCanvas): int = c.grid.width
proc rows*(c: AhCanvas): int = c.grid.height

proc fill*(c: var AhCanvas; row, col, width, height: int; bg: string) =
  ## Paint `bg` under every cell of the rectangle, clearing what was there.
  for r in max(0, row) ..< min(c.rows, row + height):
    if width > 0:
      c.grid.paint(r, max(0, col), repeat(' ', max(0, min(width, c.cols - max(0, col)))),
                   CellStyle(fg: c.p.textBody, bg: bg))

proc area*(c: var AhCanvas; name: string; row, col, width, height: int; bg: string) =
  ## An area: filled with `bg` and recorded (see the module header).
  c.fill(row, col, width, height, bg)
  c.areas.add AhArea(name: name, row: row, col: col, width: width, height: height, bg: bg)

proc bgAt*(c: AhCanvas; row, col: int): string = c.grid.styleAt(row, col).bg

proc node*(c: var AhCanvas; parent: AhNode; row, col, width, height: int;
           facts: openArray[(string, string)] = []): AhNode =
  ## A drawn element under `parent` (the canvas root when nil).
  result = AhNode(row: row, col: col, width: width, height: height, facts: @facts)
  (if parent.isNil: c.root else: parent).children.add result

proc tag*(n: AhNode; name, value: string) =
  ## A fact on an element: `data-ah-<name>`, as the GPUI views spell it.
  for i in 0 ..< n.facts.len:
    if n.facts[i][0] == name:
      n.facts[i][1] = value
      return
  n.facts.add (name, value)

proc widthOf*(s: string): int = cellWidthOf(s)

proc elide*(s: string; cells: int): string =
  ## `s` in at most `cells` columns: whole when it fits, else cut and ended
  ## with "…" (the stylesheet's `text-overflow: ellipsis`).
  if cells <= 0: return ""
  if widthOf(s) <= cells: return s
  if cells == 1: return Ellipsis
  cellSlice(s, 0, cells - 1) & Ellipsis

type
  WrappedLine* = object
    ## One line of a wrapped text: what it shows, and where in the text
    ## (rune index; a cell, in the narrow texts the views wrap) it starts, so
    ## a caller can colour a part of the text that falls on any line.
    text*: string
    start*: int

proc runeCells(r: string): int = max(1, cellsOfRune(r.runeAtPos(0), awNarrow))

proc isSeparatorAt(runesOf: seq[string]; k: int): bool =
  ## Whether runes `k - 1 .. k + 1` are " · ".
  k >= 1 and k + 1 < runesOf.len and runesOf[k - 1] == " " and
    runesOf[k] == "\xC2\xB7" and runesOf[k + 1] == " "

proc wrapGreedy(runesOf: seq[string]; w: int): seq[WrappedLine] =
  ## The longest-first word wrap `wrapRuns` falls back on (see there).
  var i = 0
  while i < runesOf.len:
    while i < runesOf.len and runesOf[i] == " ": inc i
    if i >= runesOf.len: break
    # The longest run from i that fits, ending before a space when it can.
    var cells = 0
    var j = i
    var lastBreak = -1
    while j < runesOf.len:
      let rw = max(1, cellsOfRune(runesOf[j].runeAtPos(0), awNarrow))
      if cells + rw > w: break
      if runesOf[j] == " ": lastBreak = j
      cells += rw
      inc j
    # A rune wider than the whole line (a wide glyph on a one-cell line) is
    # drawn on a line of its own rather than never placed.
    if j == i: j = i + 1
    var stop = j
    if j < runesOf.len and runesOf[j] != " " and lastBreak > i:
      stop = lastBreak
    if stop < runesOf.len:
      # Break after the line's last separator when it is past the middle.
      var k = stop - 1
      while k > i + 1:
        if runesOf[k] == " " and runesOf[k - 1] == "\xC2\xB7" and runesOf[k - 2] == " ":
          break
        dec k
      if k > i + 1 and (k - i) * 2 >= w: stop = k
      else:
        # Never start the next line with the separator: break a word
        # earlier, so the separator follows that word on the next line.
        var n = stop
        while n < runesOf.len and runesOf[n] == " ": inc n
        if n < runesOf.len and runesOf[n] == "\xC2\xB7":
          var back = stop - 1
          while back > i and runesOf[back] != " ": dec back
          if back > i: stop = back
    var line = ""
    for k in i ..< stop: line.add runesOf[k]
    result.add WrappedLine(text: line.strip(leading = false), start: i)
    i = stop

proc lineOf(runesOf: seq[string]; first, stop: int): WrappedLine =
  ## Runes `first ..< stop` as one line, its trailing spaces dropped.
  var line = ""
  for k in first ..< stop: line.add runesOf[k]
  WrappedLine(text: line.strip(leading = false), start: first)

proc wrapParts(runesOf: seq[string]; w: int): seq[WrappedLine] =
  ## A text that lists its parts with " · ", broken only after a separator
  ## (each part whole on a line, the separator ending the line it breaks),
  ## into as few lines as a longest-first fill needs, those lines as even
  ## as they can be: the break that minimises the longest line, then the
  ## spread. Empty when a part (with its separator) is wider than a line:
  ## the caller then wraps the words.
  var starts = @[0]        # the rune each part starts at
  for k in 1 ..< runesOf.len - 1:
    if isSeparatorAt(runesOf, k): starts.add k + 2
  let n = starts.len
  if n < 2: return
  # Each part's cells as it ends a line (" ·" kept, the trailing space not)
  # and as it is followed on the same line (" · " in full).
  var alone, joined = newSeq[int](n)
  for p in 0 ..< n:
    let stop = if p + 1 < n: starts[p + 1] - 3 else: runesOf.len
    var cells = 0
    for k in starts[p] ..< stop: cells += runeCells(runesOf[k])
    alone[p] = cells + (if p + 1 < n: 2 else: 0)
    joined[p] = cells + (if p + 1 < n: 3 else: 0)
    if alone[p] > w: return
  proc span(a, b: int): int =
    ## Cells of parts `a ..< b` on one line.
    for p in a ..< b - 1: result += joined[p]
    result += alone[b - 1]
  # The fewest lines: a longest-first fill.
  var lines = 0
  var a = 0
  while a < n:
    var b = a + 1
    while b < n and span(a, b + 1) <= w: inc b
    inc lines
    a = b
  # The evenest break into that many lines (a handful of parts: exhaustive
  # search over the break positions by dynamic programming).
  const Inf = high(int) div 4
  type Cost = tuple[longest, spread: int]
  var best = newSeq[seq[Cost]](n + 1)
  var cut = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    best[i] = newSeq[Cost](lines + 1)
    cut[i] = newSeq[int](lines + 1)
    for l in 0 .. lines: best[i][l] = (Inf, Inf)
  best[0][0] = (0, 0)
  for l in 1 .. lines:
    for b in 1 .. n:
      for a in 0 ..< b:
        if best[a][l - 1].longest >= Inf: continue
        let s = span(a, b)
        if s > w: continue
        let slack = w - s
        let c: Cost = (max(best[a][l - 1].longest, s), best[a][l - 1].spread + slack * slack)
        if c < best[b][l]:
          best[b][l] = c
          cut[b][l] = a
  if best[n][lines].longest >= Inf: return
  var bounds: seq[int]
  var b = n
  for l in countdown(lines, 1):
    bounds.add b
    b = cut[b][l]
  var first = 0
  for i in countdown(bounds.high, 0):
    let stop = bounds[i]
    let last = if stop < n: starts[stop] - 1 else: runesOf.len   # keep " ·"
    result.add lineOf(runesOf, starts[first], last)
    first = stop

proc keepLastWordCompany(lines: var seq[WrappedLine]; runesOf: seq[string]; w: int) =
  ## Prose does not end on a lone word: when the last line is one word and
  ## the line above has more than one, that line's last word moves down,
  ## where the two fit on a line.
  if lines.len < 2: return
  let last = lines[^1]
  if ' ' in last.text: return
  let prev = lines[^2]
  let cut = prev.text.rfind(' ')
  if cut <= 0: return
  # The previous line must have broken at a space (not inside a long word).
  if last.start == 0 or runesOf[last.start - 1] != " ": return
  let moved = prev.text[cut + 1 .. ^1]
  let joinedText = moved & " " & last.text
  if widthOf(joinedText) > w: return
  let kept = prev.text[0 ..< cut].strip(leading = false)
  var movedRunes = 0
  for _ in runes(moved): inc movedRunes
  lines[^2] = WrappedLine(text: kept, start: prev.start)
  lines[^1] = WrappedLine(text: joinedText, start: last.start - 1 - movedRunes)

proc wrapRuns*(text: string; width: int): seq[WrappedLine] =
  ## `text` broken into lines of at most `width` cells, at spaces, as the
  ## web's `white-space: normal` breaks it; a word longer than a line is
  ## cut across lines at the width (`overflow-wrap: anywhere`), so nothing
  ## of it is lost. The spaces a break falls on are not drawn.
  ##
  ## A text that lists its parts with " · " (a summary, a milestone's meta)
  ## breaks only after a separator, so a part (`Tests: 1 failing, 2
  ## pending`) is never split, and its lines are made even
  ## (`wrapParts`); only a part wider than a line falls back on breaking
  ## at words. Prose never ends on a lone word (`keepLastWordCompany`).
  let w = max(1, width)
  var runesOf: seq[string]
  for r in runes(text): runesOf.add $r
  var lead = 0
  while lead < runesOf.len and runesOf[lead] == " ": inc lead
  if lead == runesOf.len: return
  var cells = 0
  for k in lead ..< runesOf.len: cells += runeCells(runesOf[k])
  if cells <= w: return @[lineOf(runesOf, lead, runesOf.len)]
  var hasSeparator = false
  for k in 1 ..< max(1, runesOf.len - 1):
    if isSeparatorAt(runesOf, k): hasSeparator = true
  if hasSeparator:
    result = wrapParts(runesOf, w)
    if result.len > 0: return
    return wrapGreedy(runesOf, w)
  result = wrapGreedy(runesOf, w)
  keepLastWordCompany(result, runesOf, w)

proc wrapCells*(text: string; width: int): seq[string] =
  ## `wrapRuns`' lines as text.
  for l in wrapRuns(text, width): result.add l.text

proc put*(c: var AhCanvas; row, col: int; s, fg: string; bold = false;
          bg = ""): int =
  ## `s` at (`row`, `col`) in `fg`, on the background already there (or
  ## `bg`). Returns the cells drawn.
  if row < 0 or row >= c.rows or col >= c.cols or s.len == 0: return 0
  let w = min(widthOf(s), c.cols - col)
  let text = if widthOf(s) > c.cols - col: cellSlice(s, 0, c.cols - col) else: s
  # One run per ground: the cells keep the area's background under the text.
  var at = col
  for r in runes(text):
    let rw = max(1, cellsOfRune(r, awNarrow))
    let ground = if bg.len > 0: bg else: c.bgAt(row, at)
    c.grid.paint(row, at, $r, CellStyle(fg: fg, bg: ground, bold: bold))
    at += rw
  w

proc text*(c: var AhCanvas; parent: AhNode; row, col, cells: int; s, fg: string;
           bold = false; fact = ""; bg = ""; alignRight = false): int =
  ## One line of text, elided to `cells` (the width the layout gives it).
  ## `fact`, when given, tags a node with the full text over the cells it
  ## draws. Returns the cells drawn.
  let shown = elide(s, cells)
  let w = widthOf(shown)
  let at = if alignRight: col + max(0, cells - w) else: col
  discard c.put(row, at, shown, fg, bold, bg)
  if fact.len > 0:
    discard c.node(parent, row, at, w, 1, [(fact, s)])
  w

proc para*(c: var AhCanvas; parent: AhNode; row, col, cells: int; s, fg: string;
           fact = ""; alignRight = false; bold = false): int =
  ## `s` wrapped to `cells` columns (`wrapCells`) from (`row`, `col`), each
  ## line right-aligned in the cells when `alignRight` — the web's
  ## `white-space: normal`, where a terminal line cannot hold what the web's
  ## does. Never ellipsised: the whole text is drawn. `fact` tags ONE node
  ## over the lines' rectangle with the full text. Returns the rows drawn
  ## (none for an empty text).
  if s.len == 0: return 0
  let lines = wrapCells(s, cells)
  let shown = lines.len
  var left = col + cells
  var right = col
  for i in 0 ..< shown:
    let w = widthOf(lines[i])
    let at = if alignRight: col + max(0, cells - w) else: col
    discard c.put(row + i, at, lines[i], fg, bold)
    left = min(left, at)
    right = max(right, at + w)
  if fact.len > 0:
    discard c.node(parent, row, left, max(0, right - left), shown, [(fact, s)])
  shown

proc mark*(c: var AhCanvas; parent: AhNode; row, col: int; m: MarkStyle): AhNode =
  ## The status mark: ● filled, ○ for a ring (idle, planned).
  discard c.put(row, col, if m.ring: RingGlyph else: DotGlyph, m.colour)
  c.node(parent, row, col, 1, 1,
         [("mark", if m.ring: "ring:" & m.colour else: m.colour)])

proc target*(c: var AhCanvas; row, col, width, height: int; click: proc() = nil;
             hover: proc() = nil) =
  c.targets.add AhTarget(row: row, col: col, width: width, height: height,
                         click: click, hover: hover)

proc targetAt*(c: AhCanvas; row, col: int): int =
  ## The topmost target under (`row`, `col`), -1 for none.
  result = -1
  for i in countdown(c.targets.high, 0):
    let t = c.targets[i]
    if row >= t.row and row < t.row + t.height and col >= t.col and col < t.col + t.width:
      return i

proc press*(c: AhCanvas; row, col: int): bool =
  ## A click at (`row`, `col`): runs what is there; false for nothing.
  let i = c.targetAt(row, col)
  if i < 0 or c.targets[i].click.isNil: return false
  c.targets[i].click()
  true

proc pointAt*(c: AhCanvas; row, col: int): bool =
  ## The pointer now rests at (`row`, `col`): the hover under it, or every
  ## `leave` when there is none. True when something ran.
  let i = c.targetAt(row, col)
  if i >= 0 and not c.targets[i].hover.isNil:
    c.targets[i].hover()
    return true
  for f in c.leave: f()
  c.leave.len > 0

# ---------------------------------------------------------------------------
# Reading a drawing back (the coverage test's side, and the story host's)
# ---------------------------------------------------------------------------

proc attr*(n: AhNode; name: string): string =
  for (k, v) in n.facts:
    if k == name: return v

proc has*(n: AhNode; name: string): bool =
  for (k, _) in n.facts:
    if k == name: return true

proc collect(n: AhNode; name: string; into: var seq[AhNode]) =
  if n.isNil: return
  if n.has(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all*(n: AhNode; name: string): seq[AhNode] =
  ## Every node under `n` (itself included) carrying fact `name`, in
  ## drawing order.
  collect(n, name, result)

proc values*(n: AhNode; name: string): seq[string] =
  for e in n.all(name): result.add e.attr(name)

proc first*(n: AhNode; name: string): AhNode =
  let found = n.all(name)
  if found.len > 0: found[0] else: nil

proc cellsText*(g: StyledGrid; row, col, width: int): string =
  ## The text the cells of one row span hold.
  for c in col ..< min(g.width, col + width):
    result.add g.runeAt(row, c)


# ---------------------------------------------------------------------------
# Shared pieces
# ---------------------------------------------------------------------------

proc notice*(c: var AhCanvas; parent: AhNode; row, col, width, height: int;
             message, kind: string) =
  ## The shared empty / loading overlay (`.empty-overlay`): the message
  ## centred both ways in the body, 5 cells (the web's 40px) clear of the
  ## sides, wrapping, in the body colour.
  let n = c.node(parent, row, col, width, height, [("notice", kind)])
  let avail = max(1, width - 2 * cellsOf(40))
  let lines = wrapCells(message, avail)
  let top = row + max(0, (height - lines.len) div 2)
  for i, l in lines:
    let shown = elide(l, avail)
    discard c.put(top + i, col + max(0, (width - widthOf(shown)) div 2), shown,
                  c.p.textCaption)
  # The whole message is the fact; its words are the cells above.
  n.tag("message", message)

proc errorBlock*(c: var AhCanvas; parent: AhNode; row, col, width, height: int;
                 title, message: string; retry: proc()) =
  ## A load failure (`.ah-fleet-error`): what failed, why, and Retry,
  ## centred in the body.
  ## The title and the reason wrap, centred line by line, as the web's do:
  ## the reason is the one useful part of the block and is never cut.
  let n = c.node(parent, row, col, width, height, [("notice", "error")])
  let avail = max(1, width - 2 * cellsOf(40))
  let titleLines = wrapCells(title, avail)
  let whyLines = wrapCells(message, avail)
  let top = row + max(0, (height - titleLines.len - whyLines.len - 1) div 2)
  var r = top
  proc centred(c: var AhCanvas; lines: seq[string]; r: var int; fg, fact, value: string) =
    var left = col + width
    var right = col
    let first = r
    for l in lines:
      let at = col + max(0, (width - widthOf(l)) div 2)
      discard c.put(r, at, l, fg)
      left = min(left, at)
      right = max(right, at + widthOf(l))
      inc r
    discard c.node(n, first, left, max(0, right - left), lines.len, [(fact, value)])
  c.centred(titleLines, r, c.p.textError, "error-title", title)
  c.centred(whyLines, r, c.p.textCaption, "error", message)
  let label = " Retry "
  let rc = col + max(0, (width - widthOf(label)) div 2)
  discard c.put(r, rc, label, c.p.textLabel, bg = c.p.secondary)
  if c.p.secondary == c.bgAt(r, max(0, rc - 1)):
    # Retry's ground is the body's in some mode: then the chip's own.
    discard c.put(r, rc, label, c.p.textLabel, bg = c.p.tertiary)
  discard c.node(n, r, rc + 1, widthOf(label) - 2, 1, [("button", "Retry")])
  c.target(r, rc, widthOf(label), 1, retry)

proc stateName*(state: AsyncState): string =
  ## The load state a view's root reports (`data-ah-state`).
  case state
  of asIdle, asLoading: "loading"
  of asError: "error"
  of asReady: "ready"
