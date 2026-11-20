## tui/agent_harbor/ah_tui_results.nim — CTF-P2c step 2. The terminal's
## omnibox result commands and search: the caption bar's omnibox field
## holding `/s …`, `/ah…` or an instruction ending in a sigil, and under it
## the rows the command answered, grouped by provider, over
## `ResultCommandsVM` (nim-agents-isonim-viewmodels), as the web
## (`isonim_agent_harbor_results_view`) and GPUI
## (`gpui/agent_harbor/ah_results.nim`) draw it. Every word comes from
## `agent_harbor_results_words`, which renders nothing.
##
## The sheet is the composer's (`ah_tui_composer`): `sheetWidthFor` cells
## wide, centred under the field, which has the sheet's edges (P2c study
## D36), on the composer's grounds (`inksFor`). Inside it nothing is boxed
## (TUI §3.4): the header is a band, each group's head is a band of its own
## (where the web draws a hairline between groups the ground changes), and
## the rows sit on the sheet's ground. The selected row takes a ground a
## visible step off the sheet (the web's chosen ground). Top to bottom:
##
## - the header line (where the query is);
## - `← All providers` when one group is shown alone;
## - the line in place of the rows, and its quiet hint;
## - each group: its title in capitals with its state at the right, its
##   rows (the title with the query's match in bold, what it is, where it
##   is at the right, a quiet tag), and `+N more`.
##
## A rich row draws its text form (OMNI-AREQ4, D45): a terminal cannot
## render HTML, so its title and what it is, with no box.
##
## The body scrolls as the web's does: when it holds more than the screen
## leaves it, a quiet `More below ↓` ends it, whole rows at a time.
##
## Presses and keys are not handled here: the results' operations are the
## router's (Input-Routing-And-Keymaps.md §5.1, D48). Each element a press
## acts on carries `operation` and `target` facts.
##
## Facts (`AhNode`): `surface`, `kind`, `field` and `header` on the view;
## `back`, `notice-line` (with `notice-role`), `notice-hint`, `group` (with
## `group-state`, `state`), `row` (with `selected`, `title`, `detail`,
## `location`, `tag`, `second`), `more`, `more-below`; the sheet carries
## `hidden-below`.

import std/strutils
from std/unicode import runes, `$`
import nim_agents_isonim_viewmodels/agent_harbor/result_commands_vm
import ../../viewmodel/views/agent_harbor_results_words
import ./ah_tui_canvas
import ./ah_tui_composer

export result_commands_vm, agent_harbor_results_words, ah_tui_canvas

type
  Line = object
    ## A run of the body's rows (a head line, a result row, a blank row),
    ## laid out before it is drawn so the body knows its height.
    rows: int
    band: bool
    spacer: bool
    draw: proc(c: var AhCanvas; row: int) {.closure.}

  Layout = object
    left, width: int
    narrow: bool
    ink: Inks
    selected: string   ## the selected row's ground
    press: ResultsPress

const
  GapCells = 2
  ResultsSheetCells* = 100
    ## The terminal results sheet's width where the window has room: about
    ## the characters the web's 640 px sheet holds in its proportional face
    ## (P2c study D51).

proc pressOf(press: ResultsPress; operation, target: string): proc() =
  result = proc() =
    if press != nil: press(operation, target)

proc pressable(c: var AhCanvas; n: AhNode; press: ResultsPress; operation, target: string) =
  n.tag("operation", operation)
  n.tag("target", target)
  c.target(n.row, n.col, max(1, n.width), max(1, n.height), pressOf(press, operation, target))

proc spacer(): Line =
  Line(rows: 1, spacer: true, draw: proc(c: var AhCanvas; row: int) = discard)

proc drawTitle(c: var AhCanvas; row, col, cells: int; row0: ResultRow; query, fg, bg: string): int =
  ## The title, cut by the one rule, its query's matches in bold. Returns
  ## the cells drawn.
  let shown = elide(row0.title, cells)
  let cut = shown != row0.title
  var at = col
  # The parts as drawn: the cut text keeps its start, so the spans before
  # the cut keep their place; the "…" is plain.
  let spans = matchSpans(row0.title, query)
  var byte = 0
  for r in shown.runes:
    let s = $r
    # A cut title is one string (the cut rule draws it so): its match is
    # no longer bold (P2c study D41), as on the web.
    var bold = false
    if not cut:
      for (start, length) in spans:
        if byte >= start and byte < start + length: bold = true
    c.grid.paint(row, at, s, CellStyle(fg: fg, bg: (if bg.len > 0: bg else: c.bgAt(row, at)),
                                        bold: bold))
    at += max(1, cellsOfRune(r, awNarrow))
    byte += s.len
  at - col

proc rightWant(row: ResultRow; tag: string): int =
  ## The cells where a row is and its tag take whole.
  (if row.location.len > 0: widthOf(row.location) else: 0) +
    (if tag.len > 0: widthOf(tag) else: 0) +
    (if row.location.len > 0 and tag.len > 0: GapCells else: 0)

proc narrowDetailLines(vm: ResultCommandsVM; row: ResultRow; width: int): seq[string] =
  ## At sidebar width, what a row is on the lines under its title, wrapped
  ## whole (a session's state is never cut: P2c study D41), beside where it
  ## is at the right of the first of them.
  let detail = vm.rowDetail(row)
  if detail.len == 0: return
  let right = rightWant(row, vm.rowTagText(row))
  let room = if right > 0: max(8, width - min(right, width div 2) - GapCells) else: width
  # Broken only between its parts (` · `), the separator dropped at the
  # break (a line never ends on a dangling `·`; P2c D51), and in as few lines as the greedy fill
  # takes, made as even as they can be (TUI §3.4): a state word is never
  # left alone on a line when a more even break keeps it with the agent's
  # name. A part wider than the line wraps by itself.
  let parts = detail.split(" \xC2\xB7 ")
  proc joined(a, b: int): string =
    result = parts[a]
    for k in a + 1 ..< b: result.add " \xC2\xB7 " & parts[k]
  # The greedy count of lines.
  var greedy = 0
  var at = 0
  while at < parts.len:
    var b = at + 1
    while b < parts.len and widthOf(joined(at, b + 1)) <= room: inc b
    inc greedy
    at = b
  # The most even split into that many lines (parts are few: try them all).
  var best: seq[int]
  var bestWidest = high(int)
  proc search(start: int; cuts: seq[int]) =
    if cuts.len == greedy - 1:
      var widest = 0
      var a = start
      var ok = true
      var bounds = cuts & @[parts.len]
      var prev = 0
      for b in bounds:
        let w = widthOf(joined(prev, b))
        if w > room: ok = false
        widest = max(widest, w)
        prev = b
      if ok and widest < bestWidest:
        bestWidest = widest
        best = bounds
      return
    for b in start + 1 ..< parts.len:
      search(b, cuts & @[b])
  if greedy > 1: search(0, @[])
  if best.len == 0:
    # No even split fits (a part wider than the line): the greedy fill, a
    # wide part wrapped by itself.
    var line = ""
    for part in parts:
      let j = if line.len == 0: part else: line & " \xC2\xB7 " & part
      if line.len > 0 and widthOf(j) > room:
        result.add line
        line = part
      else:
        line = j
      while widthOf(line) > room:
        let w = wrapCells(line, room)
        result.add w[0]
        line = line[w[0].len .. ^1].strip(trailing = false)
    if line.len > 0: result.add line
  else:
    var prev = 0
    for b in best:
      result.add joined(prev, b)
      prev = b

proc partLines(text: string; width: int): seq[string] =
  ## A line of parts joined by ` · ` (a header) in lines of `width` cells,
  ## broken only between its parts and the separator dropped at the break
  ## (P2c D51); a part wider than the line wraps at its words by itself.
  var line = ""
  for part in text.split(" \xC2\xB7 "):
    let j = if line.len == 0: part else: line & " \xC2\xB7 " & part
    if line.len > 0 and widthOf(j) > width:
      result.add line
      line = part
    else:
      line = j
    while widthOf(line) > width:
      let w = wrapCells(line, width)
      result.add w[0]
      line = line[w[0].len .. ^1].strip(trailing = false)
  if line.len > 0: result.add line

proc codeLines(code: string; width: int): seq[string] =
  ## A line of code in lines of `width` cells, each filled before it breaks
  ## (a keyword is never left alone on a line): it breaks after a space, a
  ## `(` or a `,` in the line's last third where there is one, else at the
  ## width, inside a name (the web's `overflow-wrap: anywhere`).
  var rest = code
  while widthOf(rest) > width:
    let take = cellSlice(rest, 0, width)
    var cut = take.len
    var k = take.len - 1
    while k >= take.len * 2 div 3:
      if take[k] in {' ', '(', ','}:
        cut = k + 1
        break
      dec k
    if cut == take.len and take.len > 0 and take[^1] notin {' ', '(', ','}:
      # No break in the last third: the last allowed one anywhere on the
      # line, so a name is split only when the line has none (a line never
      # starts inside `name:`).
      var j = take.len - 2
      while j > 0:
        if take[j] in {' ', '(', ','}:
          cut = j + 1
          break
        dec j
    result.add rest[0 ..< cut].strip(leading = false)
    rest = rest[cut .. ^1].strip(trailing = false)
  if rest.len > 0: result.add rest

proc wideTitleRoom(row: ResultRow; tag: string; width: int): int =
  ## At laptop width, the cells a line of the program's text wraps in:
  ## the line less where it is and its tag at the right (at most half).
  if row.location.len > 0 or tag.len > 0:
    max(8, width - min(rightWant(row, tag), max(8, width div 2)) - GapCells)
  else: width

proc titleLines(row: ResultRow; width: int; narrow: bool): seq[string] =
  ## The title's lines: one, cut, except a line of the program's text,
  ## which wraps whole at every width so the match that put it in the list
  ## is in view (the web wraps it too).
  if row.kind == rkLine and widthOf(row.title) > width:
    codeLines(row.title, width)
  else: @[row.title]

proc drawTitleLines(c: var AhCanvas; row, col: int; lines: seq[string]; r: ResultRow;
                    query, fg, bg: string) =
  ## Wrapped title lines, the query's matches in bold across them.
  let spans = matchSpans(r.title, query)
  var at = 0
  for i, l in lines:
    let start = max(0, r.title.find(l, at))
    var byte = start
    var x = col
    for ru in l.runes:
      let s = $ru
      var bold = false
      for (b, n) in spans:
        if byte >= b and byte < b + n: bold = true
      c.grid.paint(row + i, x, s, CellStyle(fg: fg, bg: (if bg.len > 0: bg else: c.bgAt(row + i, x)),
                                             bold: bold))
      x += max(1, cellsOfRune(ru, awNarrow))
      byte += s.len
    at = start + l.len

proc rowShape(vm: ResultCommandsVM; row: ResultRow; width: int; narrow: bool):
    tuple[rows, secondRows, underRows, titleRows: int; underTitle: bool] =
  ## How many terminal rows a result row takes: its line, at sidebar width
  ## the lines for what it is and where (the web's wrapped line), and the
  ## line under it (a command's description, wrapped whole).
  let second = vm.rowSecondLine(row)
  result.underTitle = narrow and (vm.rowDetail(row).len > 0 or row.location.len > 0 or
                                  vm.rowTagText(row).len > 0)
  result.underRows = if result.underTitle: max(1, narrowDetailLines(vm, row, width).len) else: 0
  result.secondRows = if second.len > 0: max(1, wrapCells(second, width).len) else: 0
  result.titleRows = if narrow: titleLines(row, width, narrow).len
                     else: titleLines(row, wideTitleRoom(row, vm.rowTagText(row), width), false).len
  result.rows = result.titleRows + result.underRows + result.secondRows

proc drawRight(c: var AhCanvas; n: AhNode; row, rightEnd, room: int; location, tag, ink,
               ground: string): int =
  ## Where the row is (a path, cut in its middle) and its tag, ending at
  ## `rightEnd`, in at most `room` cells. Returns the column they start at.
  let tagW = if tag.len > 0: min(widthOf(tag), room) else: 0
  let locRoom = max(0, room - tagW - (if tagW > 0 and location.len > 0: GapCells else: 0))
  let locShown = if location.len > 0: elidePath(location, locRoom) else: ""
  let locW = widthOf(locShown)
  var at = rightEnd - tagW - (if tagW > 0 and locW > 0: GapCells else: 0) - locW
  result = at
  if locW > 0:
    discard c.put(row, at, locShown, ink, bg = ground)
    discard c.node(n, row, at, locW, 1, [("location", location)])
    at += locW + (if tagW > 0: GapCells else: 0)
  if tagW > 0:
    discard c.text(n, row, at, tagW, tag, ink, fact = "tag", bg = ground)

proc rowLine(vm: ResultCommandsVM; host: AhNode; lay: Layout; g: ShownGroup;
             index: int; query: string): Line =
  ## One row. Laptop: the title, what it is, and where it is with its tag at
  ## the right; the title gives way first, so what a row is (a session's
  ## state) stays whole where it can. Sidebar: the title on its line, what
  ## it is and where under it (the web's wrapped line). Under both, a
  ## command's description wrapped whole. A proc of its own so each closure
  ## owns its row.
  let row = g.rows[index]
  let at = g.first + index
  let selected = vm.isSelected(g, index)
  let detail = vm.rowDetail(row)
  let second = vm.rowSecondLine(row)
  let tag = vm.rowTagText(row)
  let narrow = lay.narrow
  let shape = rowShape(vm, row, lay.width, narrow)
  Line(rows: shape.rows, draw: proc(c: var AhCanvas; row0: int) =
    let ink = lay.ink
    let ground = if selected: lay.selected else: ""
    if selected:
      c.fill(row0, lay.left - 1, lay.width + 2, shape.rows, lay.selected)
      for r in row0 ..< row0 + shape.rows:
        discard c.put(r, lay.left - 1, BarGlyph, c.p.borderAction, bg = lay.selected)
    let n = c.node(host, row0, lay.left - 1, lay.width + 2, shape.rows,
                   [("row", row.title), ("selected", $selected), ("kind", $row.kind)])
    c.pressable(n, lay.press, ResultsOpenOperation, $at)
    let caption = if selected: readable(c.p, lay.selected) else: ink.caption
    let lineEnd = lay.left + lay.width
    if not narrow:
      # Where it is and its tag at the right, at most half the line.
      var textEnd = lineEnd
      if row.location.len > 0 or tag.len > 0:
        let room = min(rightWant(row, tag), max(8, lay.width div 2))
        textEnd = c.drawRight(n, row0, lineEnd, room, row.location, tag, caption, ground) - GapCells
      # What it is keeps its words; the title gives way first, down to a
      # fifth of the line.
      let detailW = if detail.len > 0:
                      min(widthOf(detail), max(0, textEnd - lay.left - max(12, lay.width div 5) -
                                                    GapCells))
                    else: 0
      let titleRoom = max(4, textEnd - lay.left - (if detailW > 0: detailW + GapCells else: 0))
      if shape.titleRows > 1:
        # A line of the program's text wraps whole beside where it is.
        let tl = titleLines(row, wideTitleRoom(row, tag, lay.width), false)
        c.drawTitleLines(row0, lay.left, tl, row, query, c.p.textBody, ground)
        var widest = 0
        for l in tl: widest = max(widest, widthOf(l))
        discard c.node(n, row0, lay.left, widest, tl.len, [("title", row.title)])
      else:
        let tw = c.drawTitle(row0, lay.left, titleRoom, row, query, c.p.textBody, ground)
        discard c.node(n, row0, lay.left, tw, 1, [("title", row.title)])
        # (A line of the program's text says nothing of what it is: its
        # wrapped form above has no detail to place.)
        if detailW > 0:
          discard c.text(n, row0, lay.left + tw + GapCells, detailW, detail, caption,
                         fact = "detail", bg = ground)
    else:
      let tl = titleLines(row, lay.width, true)
      if tl.len > 1:
        c.drawTitleLines(row0, lay.left, tl, row, query, c.p.textBody, ground)
        discard c.node(n, row0, lay.left, lay.width, tl.len, [("title", row.title)])
      else:
        let tw = c.drawTitle(row0, lay.left, lay.width, row, query, c.p.textBody, ground)
        discard c.node(n, row0, lay.left, tw, 1, [("title", row.title)])
      let under = row0 + tl.len
      if shape.underTitle:
        # Where it is at the right of the line under the title (the whole
        # line when the row says nothing of what it is), what it is wrapped
        # whole at its left.
        let lines = narrowDetailLines(vm, row, lay.width)
        if row.location.len > 0 or tag.len > 0:
          let room = if lines.len == 0: lay.width
                     else: min(rightWant(row, tag), max(8, lay.width div 2))
          discard c.drawRight(n, under, lineEnd, room, row.location, tag, caption, ground)
        for i, l in lines:
          discard c.put(under + i, lay.left, l, caption, bg = ground)
        if lines.len > 0:
          var widest = 0
          for l in lines: widest = max(widest, widthOf(l))
          discard c.node(n, under, lay.left, widest, lines.len, [("detail", detail)])
    if second.len > 0:
      let r = row0 + shape.titleRows + shape.underRows
      for i, l in wrapCells(second, lay.width):
        discard c.put(r + i, lay.left, l, caption, bg = ground)
      discard c.node(n, r, lay.left, lay.width, shape.secondRows, [("second", second)]))

proc headLine(host: AhNode; lay: Layout; line: int; title, state, role, id, gstate: string;
              besideTitle: bool; stateLines: seq[string]): Line =
  ## Line `line` of a group's head: the title (and the state beside it), or
  ## a line of a failure's reason under it. A proc of its own so each
  ## closure owns its line (a closure made in a loop shares the loop's
  ## variables).
  Line(rows: 1, band: true, draw: proc(c: var AhCanvas; row: int) =
    let ink = lay.ink
    let stateInk = if role == "error": ink.bandError else: ink.bandCaption
    if line == 0:
      let n = c.node(host, row, lay.left, lay.width, (if besideTitle: 1 else: 1 + stateLines.len),
                     [("group", id), ("group-state", gstate), ("state", state)])
      if besideTitle:
        let sw = widthOf(state)
        discard c.put(row, lay.left + lay.width - sw, state, stateInk)
        discard c.text(n, row, lay.left, max(1, lay.width - sw - GapCells), title,
                       c.p.textLabel, fact = "group-title")
      else:
        discard c.text(n, row, lay.left, lay.width, title, c.p.textLabel, fact = "group-title")
    else:
      discard c.put(row, lay.left, stateLines[line - 1], stateInk))

proc groupLines(vm: ResultCommandsVM; host: AhNode; lay: Layout; g: ShownGroup;
                query: string): seq[Line] =
  ## The group's head (its title, and its state at the right; a failure's
  ## reason that does not fit beside the title wraps on lines of its own
  ## under it, CodeTracer-TUI §3.4), its rows and `+N more`.
  let title = g.group.title.toUpperAscii
  let state = stateWord(g.group)
  let role = stateRole(g.group)
  let id = g.group.id
  let gstate = $g.group.state
  let besideTitle = widthOf(title) + GapCells + widthOf(state) <= lay.width
  let stateLines = if besideTitle: @[state] else: wrapCells(state, lay.width)
  for k in 0 .. (if besideTitle: 0 else: stateLines.len):
    result.add headLine(host, lay, k, title, state, role, id, gstate, besideTitle, stateLines)
  for i in 0 ..< g.rows.len:
    # Rows of more than one line are set apart by a row of the sheet's own
    # ground (TUI §3.4's rule for stacked items), so where one ends shows.
    if i > 0 and (rowShape(vm, g.rows[i], lay.width, lay.narrow).rows > 1 or
                  rowShape(vm, g.rows[i - 1], lay.width, lay.narrow).rows > 1):
      result.add spacer()
    result.add rowLine(vm, host, lay, g, i, query)
  let more = moreLabel(g)
  if more.len > 0:
    if g.rows.len > 0 and rowShape(vm, g.rows[^1], lay.width, lay.narrow).rows > 1:
      result.add spacer()
    result.add Line(rows: 1, draw: proc(c: var AhCanvas; row: int) =
      let n = c.node(host, row, lay.left, widthOf(more), 1, [("more", more)])
      c.pressable(n, lay.press, ResultsMoreOperation, id)
      discard c.put(row, lay.left, more, c.p.textLabel))

proc lineRows(vm: ResultCommandsVM; g: ShownGroup; index: int; width: int; narrow: bool): int =
  rowShape(vm, g.rows[index], width, narrow).rows

proc drawResults*(c: var AhCanvas; vm: ResultCommandsVM; row, col, width, height: int;
                  press: ResultsPress = nil) =
  ## The caption bar with the omnibox field at (`row`, `col`), and the
  ## sheet dropped under it, in `width` × `height` cells.
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-results"), ("kind", $vm.kind)])
  let ink = inksFor(c)
  c.area("caption", row, col, width, 1, c.tone.frame)
  c.area("window", row + 1, col, width, height - 1, ink.window)
  # The field, with the sheet's edges (D36), its value cut in its middle by
  # the one-line input rule (D35) where it does not fit.
  # The sheet holds as many characters as the web's (P2c study D51): a
  # terminal cell is wider than the web face's average character, so where
  # the window has room the sheet is `ResultsSheetCells` wide, not the
  # web's 640 px at 8 px a cell; never closer than a cell to the window's
  # edges, and never narrower than the web's rule gives.
  let webCells = max(10, vm.sheetWidthFor(width * CellPx) div CellPx)
  let sheetW = min(width, min(width - 2, max(webCells, ResultsSheetCells)))
  let sheetCol = col + (width - sheetW) div 2
  var fieldGround = c.tone.head
  for cand in [c.tone.head, c.p.hover, c.p.tertiary, c.p.panel, c.p.menu]:
    if cand != c.tone.frame and cand != ink.window:
      fieldGround = cand
      break
  c.area("field", row, sheetCol, sheetW, 1, fieldGround)
  let input = vm.input
  discard c.put(row, sheetCol + 1, elideMiddle(input, max(1, sheetW - 2)), c.p.textBody)
  discard c.node(host, row, sheetCol, sheetW, 1, [("field", input)])
  let narrow = vm.isNarrow(width * CellPx)
  let pad = 1
  # The selected row lifts off the sheet, as the web's chosen row does.
  # Light: the web's chosen `tertiary`, a grey step off the sheet. Dark,
  # whose sheet is already the lightest grey surface step: the selection's
  # own tint (the action role at the palette's selected alpha, the fleet's
  # selected row) over the sheet, lighter than it, never a darker grey that
  # reads as a hole. Either way the inset bar in the action role down its
  # first cell (CodeTracer-TUI §3.4's mark of a selected row), so it never
  # reads as a head.
  let selected = if c.p.mode == dmDark: blendOver(c.p.selectedTint, ink.sheet)
                 else: firstOff(ink.sheet, [c.p.tertiary,
                                            tokenHexOf(dtColorsUiSurfaceBaseCard, c.p.mode),
                                            c.p.activeTab, c.p.menu],
                                avoid = [ink.band])
  let lay = Layout(left: sheetCol + pad + 1, width: sheetW - 2 * pad - 2, narrow: narrow,
                   ink: ink, selected: selected, press: press)
  let header = vm.headerText
  # A header that ends in a URL (`Opened outside CodeTracer: https://…`)
  # keeps its words on one line and the URL on lines of its own, broken
  # only after a `/`, `-` or `.`, never inside a segment.
  var headerLines: seq[string]
  let urlAt = header.find("://")
  let colon = if urlAt > 0: header.rfind(": ", last = urlAt) else: -1
  if colon > 0 and widthOf(header) <= lay.width:
    headerLines = @[header]
  elif colon > 0:
    headerLines = partLines(header[0 .. colon], lay.width)
    var line = ""
    var seg = ""
    let url = header[colon + 2 .. ^1]
    let room = lay.width
    for ch in url:
      seg.add ch
      if ch in {'/', '-', '.'}:
        if line.len > 0 and widthOf(line & seg) > room:
          headerLines.add line
          line = ""
        line.add seg
        seg = ""
    if seg.len > 0:
      if line.len > 0 and widthOf(line & seg) > room:
        headerLines.add line
        line = ""
      line.add seg
    if line.len > 0: headerLines.add line
  else:
    headerLines = partLines(header, lay.width)
  let headerInk = case vm.headerRole
                  of "body": c.p.textBody
                  of "error": ink.bandError
                  else: ink.bandCaption
  let headerRows = max(1, headerLines.len)
  # The body's lines.
  var lines: seq[Line]
  var heights: seq[int]
  template add(l: Line; h: int) =
    lines.add l
    heights.add h
  if vm.alone.val.len > 0:
    add(Line(draw: proc(c: var AhCanvas; r: int) =
      let n = c.node(host, r, lay.left, widthOf(AllProviders), 1, [("back", AllProviders)])
      c.pressable(n, lay.press, ResultsAllOperation, "")
      discard c.put(r, lay.left, AllProviders, lay.ink.caption)), 1)
    add(spacer(), 1)
  let notice = vm.notice
  if notice.text.len > 0:
    add(spacer(), 1)
    let noticeRows = wrapCells(notice.text, lay.width).len
    add(Line(draw: proc(c: var AhCanvas; r: int) =
      let fg = if notice.role == "error": c.p.textError else: c.p.textBody
      let n = c.node(host, r, lay.left, lay.width, noticeRows,
                     [("notice-line", notice.text), ("notice-role", notice.role)])
      discard c.para(n, r, lay.left, lay.width, notice.text, fg)
      if notice.hint.len > 0:
        discard c.text(n, r + noticeRows, lay.left, lay.width, notice.hint, lay.ink.caption,
                       fact = "notice-hint")), noticeRows + (if notice.hint.len > 0: 1 else: 0))
  let query = vm.queryText
  let groups = vm.groups
  for gi in 0 ..< groups.len:
    let g = groups[gi]
    # A row of the sheet's own ground before every group head, the first
    # one included: two bands never touch (the header's and a group's, or
    # two groups'), TUI §3.4's change of ground where the web draws a line.
    if gi > 0 or lines.len == 0: add(spacer(), 1)
    for l in groupLines(vm, host, lay, g, query):
      add(l, l.rows)
  # Which lines are drawn: from the start, whole lines, ending in "More
  # below" when the window has no room for the rest.
  let top = row + SheetTop
  let maxH = row + height - 1 - top
  let topRows = 1 + headerRows + 1
  let bodyRoom = max(1, maxH - topRows - 1)
  var total = 0
  for h in heights: total += h
  var last = lines.high
  var moreBelow = false
  if total > bodyRoom:
    var used = 0
    last = -1
    while last + 1 < lines.len and used + heights[last + 1] <= bodyRoom - 1:
      inc last
      used += heights[last]
    # Never end on a blank row, nor on a group's head without its rows
    # (the footer's band would touch the head's).
    while last >= 0 and (lines[last].spacer or lines[last].band): dec last
    moreBelow = true
  var bodyRows = 0
  for i in 0 .. last: bodyRows += heights[i]
  let sheetH = topRows + bodyRows + 1 + (if moreBelow: 1 else: 0)
  let sheet = c.node(host, top, sheetCol, sheetW, sheetH,
                     [("sheet", $vm.kind), ("hidden-below", $(lines.high - last))])
  c.area("sheet", top, sheetCol, sheetW, sheetH, ink.sheet)
  c.area("head", top, sheetCol, sheetW, topRows, ink.band)
  for i, l in headerLines:
    discard c.put(top + 1 + i, lay.left, l, headerInk)
  discard c.node(sheet, top + 1, lay.left, lay.width, headerRows, [("header", header)])
  var r = top + topRows
  var bandIndex = 0
  for i in 0 .. last:
    if lines[i].band and (i == 0 or not lines[i - 1].band):
      # One area for a head and the lines of a failure's reason under it.
      var h = 0
      var j = i
      while j <= last and lines[j].band:
        h += heights[j]
        inc j
      c.area("group-head-" & $bandIndex, r, sheetCol, sheetW, h, ink.band)
      inc bandIndex
    lines[i].draw(c, r)
    r += heights[i]
  if moreBelow:
    # The body's footer: a band of its own (where the web draws a hairline
    # above the line), so it never reads as the last row's second line.
    c.area("more-below", r, sheetCol, sheetW, 1, ink.band)
    discard c.text(sheet, r, lay.left, lay.width, MoreBelow, ink.bandCaption,
                   fact = "more-below", alignRight = true)
