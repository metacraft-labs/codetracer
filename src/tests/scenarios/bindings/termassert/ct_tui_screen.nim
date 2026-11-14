## ct_tui_screen.nim — the terminal front-end's page objects, read off its
## screen: the CodeTracer pack's TermAssert binding's reader.
##
## What a person reading the terminal sees, and nothing else: the top bar
## (menu, transport, omnibox, session tabs, the `[ct]` trace summary), the
## boxes of the layout — each with its strip of pane tabs and its content —,
## the context menu and palette overlays, and the status line. Every property
## comes from the cells (their text, and the colours that tell an active tab
## from an inactive one); the terminal's cursor is the editor's caret when the
## editor holds the focus, as on a real terminal.
##
## What is not drawn cannot be read. A property the screen does not show at
## the moment (an editor's caret while it has no focus, a list's rows past the
## box) is reported unreadable, so a scenario that needs it is `unsupported`
## on this backend rather than answered from somewhere else.
##
## The reader is a pure function of the screen (`ScreenGrid`), so it is
## exercised by `test_ct_tui_screen.nim` on captured screens as well as live.

import std/[algorithm, json, strutils, options, tables, sequtils]
from std/sequtils import anyIt
from std/unicode import Rune, toRunes, runeLen, `$`, strip
import demo_video_script/surface

type
  GridCell* = object
    text*: string          ## the cell's character ("" for a continuation)
    bg*: string            ## its background, as a comparable token
    fg*: string
    bold*, inverse*: bool

  ScreenGrid* = object
    width*, height*: int
    rows*: seq[seq[GridCell]]
    cursorRow*, cursorCol*: int
    cursorVisible*: bool

  Box* = object
    ## One box of the layout: its strip row and its content rectangle.
    left*, right*: int     ## columns [left, right)
    strip*: int            ## the row of its pane-tab strip
    bottom*: int           ## rows (strip, bottom) are its content
    labels*: seq[tuple[label: string, col: int, active: bool]]

const
  BoxEdge = "▏"

proc rowText*(g: ScreenGrid; r: int; a = 0; b = -1): string =
  let e = if b < 0: g.width else: min(b, g.width)
  for c in a ..< e:
    let t = g.rows[r][c].text
    result.add(if t.len == 0: "" else: t)

proc cellsOf(g: ScreenGrid; r: int; a, b: int): seq[GridCell] =
  for c in a ..< min(b, g.width): result.add g.rows[r][c]

proc fl(i: int): float = float(i)

proc findCol(g: ScreenGrid; r: int; needle: string; start = 0): int =
  ## The cell column where `needle` starts on row `r` (cells, not bytes).
  var c = start
  let n = needle.toRunes
  while c + n.len <= g.width:
    var ok = true
    for k in 0 ..< n.len:
      if g.rows[r][c + k].text != $n[k]:
        ok = false
        break
    if ok: return c
    inc c
  -1

template allIt(s, pred: untyped): bool =
  var res = true
  for it {.inject.} in s:
    if not pred:
      res = false
      break
  res

proc labelsIn(g: ScreenGrid; r, a, b: int): seq[tuple[label: string, col: int, active: bool]] =
  ## The tab labels of a strip: runs of text separated by two or more blanks.
  var c = a
  var found: seq[tuple[label: string, col: int, bg: string, bold: bool]]
  while c < b:
    while c < b and g.rows[r][c].text in ["", " ", BoxEdge]: inc c
    if c >= b: break
    let start = c
    var label = ""
    var blanks = 0
    while c < b and g.rows[r][c].text != BoxEdge:
      let t = g.rows[r][c].text
      if t == " " or t == "":
        inc blanks
        if blanks >= 2: break
      else:
        if blanks == 1: label.add " "
        blanks = 0
        label.add t
      inc c
    if label.len > 0:
      found.add (label, start, g.rows[r][start].bg, g.rows[r][start].bold)
  # the active tab is drawn apart: the one label whose ground (or weight)
  # differs from the others'
  var counts = initCountTable[string]()
  for f in found: counts.inc f.bg
  # the strip's own ground: its most common background
  var grounds = initCountTable[string]()
  for c in a ..< b: grounds.inc g.rows[r][c].bg
  let ground = if grounds.len > 0: grounds.largest.key else: ""
  # In a narrow strip the active tab's own ground (its label and padding)
  # can cover most of it. A blank cell two or more away from every label is
  # the strip's ground for certain: when there is one, it decides.
  var clear = initCountTable[string]()
  for c in a ..< b:
    if g.rows[r][c].text notin ["", " "]: continue
    var near = false
    for f in found:
      if c >= f.col - 1 and c <= f.col + f.label.len: near = true
    if not near: clear.inc g.rows[r][c].bg
  let stripGround = if clear.len > 0: clear.largest.key else: ground
  for f in found:
    let active =
      if found.len == 1: true
      elif found.len == 2 and counts.len == 2: f.bg != stripGround
      elif counts[f.bg] == 1 and counts.len > 1: true
      else: f.bold and not found.allIt(it.bold)
    result.add (f.label, f.col, active)

proc boxes*(g: ScreenGrid): seq[Box] =
  ## The layout's boxes. A box starts at a strip row — the row of pane-tab
  ## labels at its top — and spans the columns between two edges (`▏`) or the
  ## screen's sides; it ends at the next strip row in the same columns, or at
  ## the status line. A box docked under two or more of row 1's column spans
  ## (an Event Log under both Variables and Call Trace) is as wide as all of
  ## them: its strip and its content cross the edge between them.
  let last = g.height - 1
  # column segments of the first body row: edges split it
  var edges: seq[int] = @[]
  for c in 0 ..< g.width:
    if g.rows[1][c].text == BoxEdge: edges.add c
  var spans: seq[(int, int)] = @[]
  var prev = 0
  for e in edges:
    if e > prev: spans.add (prev, e)
    prev = e + 1
  if prev < g.width: spans.add (prev, g.width)
  # the grounds row 1's tabs are drawn on: a later strip's tabs are drawn on
  # the same ones (an unfocused strip can have the content's ground)
  var tabGrounds: seq[string]
  for (a, b) in spans:
    for l in g.labelsIn(1, a, b):
      if g.rows[1][l.col].bg notin tabGrounds: tabGrounds.add g.rows[1][l.col].bg
  var perSpan: seq[seq[int]]
  for (a, b) in spans:
    # strips within this column span: row 1, and any later row whose text in
    # the span starts with a label and whose row above is not text of the
    # same box (a strip is drawn as its own band)
    var strips = @[1]
    for r in 2 ..< last:
      let t = g.rowText(r, a, b)
      if t.strip.len == 0: continue
      # a strip row: its first cell is blank, then a capitalised label, and its
      # cells carry the strip's ground, which differs from the content's
      let first = g.rows[r][min(a + 1, b - 1)]
      let content = g.rows[r - 1][min(a + 1, b - 1)]
      # (a focused pane's strip is drawn on the focus ground, which row 1
      # need not show: then the strip is a band of one ground, end to end)
      # (a box has a row of content under its strip: the row right under a
      # strip — a docked pane's query field, say — never starts another)
      if strips[^1] == r - 1 or not (t.startsWith(" ") and t.len > 1 and t[1] in {'A'..'Z'}):
        continue
      var isStrip = first.bg != content.bg and
         (g.rows[r][a].bg == g.rows[1][a].bg or
          (g.rows[r][a].bg == g.rows[r][b - 1].bg and g.rows[r][b - 1].bg != content.bg))
      if not isStrip and a > 0:
        # a focused pane's strip: one band of the focus ground from the edge
        # before it (which a content row's highlight never covers) to the
        # span's end, where the row above shows another ground; its first
        # tab, when active, sits on its own ground inside the band
        let band = g.rows[r][b - 1].bg
        isStrip = first.bg != content.bg and g.rows[r][a - 1].bg == band and
                  g.rows[r][a - 1].text == BoxEdge and band != g.rows[r - 1][b - 1].bg
      if not isStrip:
        # an unfocused strip on the content's own ground: its first tab is
        # drawn on one of the grounds row 1's tabs are drawn on
        isStrip = first.bg != content.bg and first.bg in tabGrounds
      if isStrip: strips.add r
    perSpan.add strips
  # a strip that crosses the edge at its span's right (no edge glyph on the
  # strip row or the row under it) is one box with the spans it reaches; it
  # also ends the box above it in each of them
  var reach = newSeq[seq[(int, int)]](spans.len)   # (strip row, last span index)
  var covered = newSeq[seq[int]](spans.len)        # strip rows owned by a span to the left
  for i in 0 ..< spans.len:
    for r in perSpan[i]:
      if r == 1: continue
      var j = i
      while j + 1 < spans.len and r + 1 < last and
            g.rows[r][spans[j][1]].text != BoxEdge and
            g.rows[r + 1][spans[j][1]].text != BoxEdge:
        inc j
      if j > i:
        reach[i].add (r, j)
        for k in i + 1 .. j:
          covered[k].add r
          if r notin perSpan[k]: perSpan[k].add r
  for i, (a, b) in spans:
    var strips = perSpan[i]
    strips.sort()
    for k, s in strips:
      if s in covered[i]: continue
      var right = b
      var bottom = if k + 1 < strips.len: strips[k + 1] else: last
      for (r, j) in reach[i]:
        if r == s:
          right = spans[j][1]
          # it ends where the first of the spans it covers has its next strip
          for jj in i + 1 .. j:
            for s2 in perSpan[jj]:
              if s2 > s and s2 < bottom: bottom = s2
      result.add Box(left: a, right: right, strip: s, bottom: bottom,
                     labels: g.labelsIn(s, a, right))

proc activeLabel*(b: Box): string =
  for l in b.labels:
    if l.active: return l.label
  if b.labels.len > 0: b.labels[0].label else: ""

proc baseName(path: string): string =
  let i = path.rfind('/')
  if i >= 0: path[i + 1 .. ^1] else: path

proc isSourceLabel(label: string): bool =
  ## An editor's strip names its file (`nim-project/tracing.nim`); a modified
  ## buffer's tab carries ` ●` after the name.
  let base = label.replace(" ●", "").baseName
  base.contains('.') and not base.contains(' ') and label.len > 2

proc readEditor(g: ScreenGrid; b: Box; t: var Tree; root: SurfaceNode) =
  var file = ""
  for l in b.labels:
    if l.label.isSourceLabel and (l.active or file.len == 0):
      file = l.label.replace(" ●", "").baseName
  if file.len == 0: return
  let ed = node("editor", fl(b.left), fl(b.strip), fl(b.right - b.left), fl(b.bottom - b.strip),
                newJObject(), @[("file", file)])
  t.add(root, ed)
  var current, caret, first, last = 0
  var texts: seq[string]
  # The caret: in a writable editor the terminal's cursor; in the read-only
  # editor (Debug mode) a reversed cell in the code (Editor-Pane.md, "The
  # caret in a read-only editor"). Either one means the editor holds it.
  let cursorIn = g.cursorVisible and g.cursorRow > b.strip and g.cursorRow < b.bottom and
                 g.cursorCol >= b.left and g.cursorCol < b.right
  var reversedRow = -1
  for r in b.strip + 1 ..< b.bottom:
    let line = g.rowText(r, b.left, b.right)
    var i = 1
    while i < line.len and line[i] == ' ': inc i
    var j = i
    while j < line.len and line[j] in Digits: inc j
    if j == i: continue
    var reversed = 0
    for c in b.left + j + 5 ..< b.right:
      if g.rows[r][c].inverse: inc reversed
    # one reversed cell is a caret; a run of them is a selection's
    if reversed >= 1 and reversed <= 2:
      reversedRow = r
  if not cursorIn and reversedRow < 0:
    # --- terminal --- a caret painted as one cell on its own ground (Edit
    # mode hides the terminal's cursor): the one row of the text whose cells
    # hold a single cell on a ground of its own
    var candidates: seq[int]
    for r in b.strip + 1 ..< b.bottom:
      let line = g.rowText(r, b.left, b.right)
      var i = 1
      while i < line.len and line[i] == ' ': inc i
      var j = i
      while j < line.len and line[j] in Digits: inc j
      if j == i: continue
      let a = b.left + j + 5
      if a >= b.right: continue
      var grounds = initCountTable[string]()
      for c in a ..< b.right: grounds.inc g.rows[r][c].bg
      let ground = grounds.largest.key
      var odd = 0
      for c in a ..< b.right - 1:
        if g.rows[r][c].bg != ground: inc odd
      if odd == 1: candidates.add r
    if candidates.len == 1: reversedRow = candidates[0]
  let focused = cursorIn or reversedRow >= 0
  let caretRow = if cursorIn: g.cursorRow else: reversedRow
  for r in b.strip + 1 ..< b.bottom:
    let line = g.rowText(r, b.left, b.right)
    # breakpoint lane, the number right-aligned, two blanks, the pointer lane,
    # two blanks, the text
    let rs = line.toRunes
    if rs.len < 4: continue
    var i = 1
    while i < rs.len and $rs[i] == " ": inc i
    var digits = ""
    while i < rs.len and ($rs[i])[0] in Digits:
      digits.add $rs[i]
      inc i
    if digits.len == 0: continue
    if i + 4 >= rs.len and i + 3 > rs.len: continue
    let n = parseInt(digits)
    let marker = if i + 2 < rs.len: $rs[i + 2] else: " "
    let textCol = i + 5
    var text = if textCol <= rs.len: $rs[min(textCol, rs.len) ..< rs.len] else: ""
    text = text.strip(leading = false)
    let bpGlyph = $rs[0]
    let isCurrent = marker == "▸"
    let isCaret = focused and caretRow == r
    if isCurrent: current = n
    if isCaret: caret = n
    if first == 0: first = n
    last = n
    texts.add text
    let ln = node("line", fl(b.left), fl(r), fl(b.right - b.left), 1,
                  %*{"number": n, "text": text, "current": isCurrent, "caret": isCaret,
                     "breakpoint": bpGlyph in ["●", "◉", "○", "◆"],
                     "tracepoint": bpGlyph in ["◆", "◇"]},
                  @[("number", $n)])
    if not focused:
      ln.unreadable["caret"] = "the editor does not hold the focus, so no caret is drawn"
    t.add(ed, ln)
  ed.props = %*{"file": file, "active": true, "focused": focused, "read-only": true,
                "current-line": current, "caret-line": caret, "first-visible": first,
                "last-visible": last, "text": texts}
  ed.focused = focused
  if not focused:
    ed.unreadable["caret-line"] = "the editor does not hold the focus, so no caret is drawn"
  ed.unreadable["read-only"] = "the terminal draws no read-only marker; the mode is on the status line"

proc readList(g: ScreenGrid; b: Box; t: var Tree; root: SurfaceNode;
              role, childRole, key: string) =
  let pane = node(role, fl(b.left), fl(b.strip), fl(b.right - b.left), fl(b.bottom - b.strip))
  t.add(root, pane)
  var n = 0
  for r in b.strip + 1 ..< b.bottom:
    var text = g.rowText(r, b.left, b.right).strip
    # the pane's scrollbar track and the box's edges at the row's end are not
    # the row's text (the track shows once the pane has scrolled or focused)
    while text.len > 0 and (text.endsWith("▕") or text.endsWith(BoxEdge)):
      text = text[0 ..< text.len - "▕".len].strip
    if text.len == 0: continue
    var props = newJObject()
    var keyVal = text
    case childRole
    of "call":
      # `name(args) → ret` rows, indented by depth, with fold glyphs
      var s = text
      for g in ["▼ ", "▶ ", "▸ ", "▾ ", "• ", "· "]:
        s = s.replace(g, "")
      let paren = s.find('(')
      var name = (if paren > 0: s[0 ..< paren] else: s).strip
      # the call's ordinal (`add #5`) is the terminal's, not the call's name
      let hash = name.rfind(" #")
      if hash > 0 and name[hash + 2 .. ^1].allCharsInSet(Digits): name = name[0 ..< hash]
      keyVal = name
      props = %*{"name": name, "arguments": (if paren > 0: s[paren .. ^1] else: ""),
                 "current": text.contains("◀") or g.rows[r][b.left + 1].inverse,
                 "selected": g.rows[r][b.left + 1].inverse}
    of "event":
      if text.startsWith("tick") and text.contains("kind"): continue  # the header
      let parts = text.splitWhitespace()
      # tick, index, kind, output…
      let output = if parts.len >= 4: parts[3 .. ^1].join(" ") else: text
      keyVal = output
      props = %*{"text": output, "kind": (if parts.len >= 3: parts[2] else: ""),
                 "current": g.rows[r][b.left + 1].inverse, "future": false}
    of "variable":
      let parts = text.splitWhitespace()
      if parts.len == 0 or text.contains("empty at this position") or
         text.startsWith("+ Add watch"): continue
      # a category letter column, then `name: value` / `name type value`
      var s = text
      if parts[0].len == 1 and parts.len > 1: s = text[text.find(parts[1]) .. ^1]
      let colon = s.find(':')
      let name = (if colon > 0: s[0 ..< colon] else: s.splitWhitespace()[0]).strip
      let value = if colon > 0: s[colon + 1 .. ^1].strip else: ""
      if name.len == 0 or name.contains(' '): continue
      keyVal = name
      props = %*{"name": name, "value": value, "type": ""}
    else:
      props = %*{"text": text}
    inc n
    t.add(pane, node(childRole, fl(b.left), fl(r), fl(b.right - b.left), 1, props, @[(key, keyVal)]))
  pane.props = %*{"count": n, "focused": false}

proc readTopBar(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  let top = g.rowText(0)
  let ct = g.findCol(0, "[ct]")
  # the trace summary: `[ct] | trace: <name> | tick: …`
  var activeTitle = ""
  let tr = top.find("trace: ")
  if tr >= 0:
    let rest = top[tr + 7 .. ^1]
    let bar = rest.find(" |")
    activeTitle = (if bar >= 0: rest[0 ..< bar] else: rest).strip
  # the session tabs: between the omnibox's right edge and `[ct]`, `<title> ×`
  let om = g.findCol(0, BoxEdge, max(0, g.findCol(0, "⌕")))
  var titles: seq[tuple[title: string, col: int]] = @[]
  if om >= 0 and ct > om:
    var c = om + 1
    var cur = ""
    var start = -1
    while c < ct:
      let ch = g.rows[0][c].text
      if ch == "×":
        if cur.strip.len > 0: titles.add (cur.strip, start)
        cur = ""
        start = -1
      elif ch in ["+", "‹", "›"]:
        discard
      else:
        if start < 0 and ch notin ["", " "]: start = c
        if start >= 0: cur.add(if ch.len == 0: "" else: ch)
      inc c
  # The strip is drawn with its `+` (open a new session tab); a top bar too
  # narrow for it draws neither, and then how many sessions there are is not
  # on the screen.
  var plus = false
  if om >= 0 and ct > om:
    for c in om + 1 ..< ct:
      if g.rows[0][c].text == "+": plus = true
  if titles.len == 0 and activeTitle.len > 0 and plus:
    # one session: the strip is the summary's
    titles.add (activeTitle, max(0, ct))
  let strip = node("session-strip", fl(max(0, om)), 0, fl(max(1, ct - om)), 1,
                   %*{"count": titles.len, "active": activeTitle})
  if not plus:
    strip.unreadable["count"] = "the top bar is too narrow to draw the session tabs"
    strip.unreadable["active"] = "the top bar is too narrow to draw the session tabs"
  t.add(root, strip)
  for (title, col) in titles:
    t.add(strip, node("session-tab", fl(col), 0, fl(title.runeLen), 1,
                      %*{"title": title, "active": activeTitle.startsWith(title) or
                                                    title.startsWith(activeTitle)},
                      @[("title", title)]))
  # the omnibox
  let lens = g.findCol(0, "⌕")
  if lens >= 0:
    let edge = g.findCol(0, BoxEdge, lens)
    let q = g.rowText(0, lens + 1, (if edge > 0: edge else: lens + 40)).strip
    let placeholder = q.startsWith("Navigate to file")
    let focused = g.cursorVisible and g.cursorRow == 0
    t.add(root, node("omnibox", fl(lens), 0, fl(max(1, edge - lens)), 1,
                     %*{"query": (if placeholder: "" else: q), "focused": focused, "count": 0}))

proc readStatus(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  let r = g.height - 1
  let text = g.rowText(r).strip
  var location = ""
  for w in text.splitWhitespace():
    let c = w.rfind(':')
    if c > 0 and c < w.len - 1 and w[c + 1 .. ^1].allCharsInSet(Digits) and w.contains('/'):
      location = w.baseName
  var mode = ""
  for m in ["[DEBUG]", "[EDIT]", "[NORMAL]", "[INSERT]"]:
    if text.contains(m): mode = m[1 .. ^2]
  t.add(root, node("status-line", 0, fl(r), fl(g.width), 1,
                   %*{"message": text, "location": location, "mode": mode}))

proc addPaneTab(t: var Tree; b: Box; l: tuple[label: string, col: int, active: bool]) =
  t.add(t.root, node("pane-tab", fl(l.col), fl(b.strip), fl(l.label.runeLen), 1,
                     %*{"label": l.label, "active": l.active}, @[("label", l.label)]))


# --- terminal -------------------------------------------------------------------
# The terminal batch's page objects: any pane by its tab (`pane`/`row`), the
# Files tree, the framed overlays (context menus, the program menu's
# dropdowns, content popups and tooltips), the program menu's root button, the
# debugger's transport controls and the footer's auto-hide labels.

const
  TransportGlyphs = [("↶", "Reverse next"), ("↷", "Next"), ("⇣", "Reverse step in"),
                     ("↓", "Step in"), ("⇡", "Reverse step out"), ("↑", "Step out"),
                     ("⏴", "Reverse continue"), ("⏵", "Continue"), ("⏮", "Run to entry"),
                     ("■", "Stop")]
    ## The transport row's glyphs (`top_bar`, unicode tier), in the
    ## desktop toolbar's order, by the desktop's labels
    ## (`debug_controls_vm.TransportActions`).
  ContextMenuHint = "Terminal menu: Shift + right-click"
    ## The inert last row every context menu the terminal draws carries.
  FooterLabels = ["BUILD", "PROBLEMS", "FIND IN FILES", "REQUESTS", "TERMINAL",
                  "SEARCH RESULTS", "BUILD OUTPUT", "SHELL", "TEST RESULTS"]

type Overlay* = object
  ## A framed box drawn over the body: `┌─┐`, `│ │`, `└─┘`.
  top*, left*, bottom*, right*: int     ## the frame's cells, inclusive

proc overlays*(g: ScreenGrid): seq[Overlay] =
  ## The framed overlays on the screen, outermost first.
  for r in 0 ..< g.height - 1:
    for c in 0 ..< g.width - 1:
      if g.rows[r][c].text != "┌": continue
      var e = c + 1
      while e < g.width and g.rows[r][e].text == "─": inc e
      if e >= g.width or g.rows[r][e].text != "┐" or e == c + 1: continue
      var b = r + 1
      while b < g.height and g.rows[b][c].text == "│": inc b
      # a box cut by the status row has no bottom edge on the screen
      if b < g.height - 1 and g.rows[b][c].text != "└": continue
      if b >= g.height: continue
      result.add Overlay(top: r, left: c, bottom: b, right: e)

proc innerRows(g: ScreenGrid; o: Overlay): seq[tuple[row: int, text: string]] =
  for r in o.top + 1 ..< o.bottom:
    result.add (r, g.rowText(r, o.left + 1, o.right).strip)

proc splitColumns(text: string): seq[string] =
  ## A row's columns: runs separated by two or more blanks.
  var cur = ""
  var blanks = 0
  for ch in text:
    if ch == ' ':
      inc blanks
    else:
      if blanks >= 2 and cur.len > 0:
        result.add cur
        cur = ""
      elif blanks == 1 and cur.len > 0: cur.add ' '
      blanks = 0
      cur.add ch
  if cur.len > 0: result.add cur

proc rowSelected(g: ScreenGrid; r, a, b: int; usual: string): bool =
  ## A row drawn on another ground than the box's usual one (the selection's).
  let probe = min(a + 1, b - 1)
  g.rows[r][probe].bg != usual or g.rows[r][probe].inverse

proc readOverlays(g: ScreenGrid; t: var Tree; root: SurfaceNode; menus: bool) =
  ## `menus`: the context menu and the program menu's dropdowns (read early,
  ## so their places among the window's children do not move when a tooltip
  ## or a pane changes); else the omnibox's results and the popups.
  var level = 0
  var lastRight = -10
  for o in g.overlays:
    let rows = g.innerRows(o)
    let nonEmpty = block:
      var n: seq[tuple[row: int, text: string]]
      for x in rows:
        if x.text.len > 0: n.add x
      n
    let w = fl(o.right - o.left + 1)
    let h = fl(o.bottom - o.top + 1)
    let lens = g.findCol(0, "⌕")
    if o.top == 1 and lens >= 0 and o.left >= lens - 2:
      if menus: continue
      # the omnibox's results, under its field
      var box: SurfaceNode = nil
      for k in t.kids(root):
        if k.role == "omnibox": box = k
      if box == nil: continue
      var n = 0
      let usual = g.rows[o.top][o.left].bg
      for x in nonEmpty:
        let cols = splitColumns(x.text)
        inc n
        t.add(box, node("option", fl(o.left + 1), fl(x.row), w - 2, 1,
                        %*{"label": cols[0], "detail": (if cols.len > 1: cols[^1] else: ""),
                           "selected": g.rowSelected(x.row, o.left + 1, o.right, usual)},
                        @[("label", cols[0])]))
      box.props["count"] = %n
    elif nonEmpty.len > 0 and nonEmpty[^1].text == ContextMenuHint:
      if not menus: continue
      # a context menu: its entries, then the inert hint row
      let menu = node("context-menu", fl(o.left), fl(o.top), w, h)
      t.add(root, menu)
      let hintFg = g.rows[nonEmpty[^1].row][o.left + 2].fg
      var n = 0
      for x in nonEmpty[0 ..< ^1]:
        let cols = splitColumns(x.text)
        let label = cols[0]
        let shortcut = if cols.len > 1: cols[^1] else: ""
        # a disabled entry is drawn muted, as the hint row is
        let enabled = g.rows[x.row][o.left + 2].fg != hintFg
        inc n
        t.add(menu, node("menu-item", fl(o.left + 1), fl(x.row), w - 2, 1,
                         %*{"label": label, "enabled": enabled, "shortcut": shortcut},
                         @[("label", label)]))
      menu.props = %*{"count": n}
    elif nonEmpty.len > 0 and (o.top == 1 or (level > 0 and o.left == lastRight + 1)):
      # the program menu's dropdowns: the first below the root button, every
      # entered folder cascading to its right
      inc level
      lastRight = o.right
      if not menus: continue
      let dd = node("dropdown", fl(o.left), fl(o.top), w, h, newJObject(),
                    @[("level", $level)])
      t.add(root, dd)
      let usual = g.rows[o.top + 1][o.right - 1].bg
      var n = 0
      for x in nonEmpty:
        let cols = splitColumns(x.text)
        var label = cols[0]
        var folder = false
        var shortcut = if cols.len > 1: cols[^1] else: ""
        if shortcut == "›": folder = true; shortcut = ""
        if label.endsWith(" ›"):
          folder = true
          label = label[0 ..< ^4].strip
        inc n
        t.add(dd, node("dropdown-item", fl(o.left + 1), fl(x.row), w - 2, 1,
                       %*{"label": label, "shortcut": shortcut, "folder": folder,
                          "selected": g.rowSelected(x.row, o.left + 1, o.right, usual)},
                       @[("label", label)]))
      dd.props = %*{"level": level, "count": n}
    else:
      if menus: continue
      var lines: seq[string]
      for x in rows: lines.add x.text
      while lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
      let title = if nonEmpty.len > 0: nonEmpty[0].text else: ""
      t.add(root, node("popup", fl(o.left), fl(o.top), w, h,
                       %*{"title": title, "text": lines}))

proc readPanes(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## Every box of the layout as a `pane` named by its active tab, with its
  ## rows of text — the panes no other reader knows (Problems, Find in
  ## Files, Build, VCS, Constraints, …) as well as the ones it does.
  for b0 in g.boxes():
    var b = b0
    let title = b.activeLabel
    if title.len == 0: continue
    # a pane docked across the whole width (Find in Files, Build, Problems):
    # its strip has no divider, so its rows are the screen's whole width
    if g.findCol(b.strip, BoxEdge) < 0:
      b.left = 0
      b.right = g.width
    let pane = node("pane", fl(b.left), fl(b.strip), fl(b.right - b.left),
                    fl(b.bottom - b.strip), newJObject(), @[("title", title)])
    t.add(root, pane)
    var lines: seq[string]
    var n = 0
    var hbar = false
    let usual = if b.strip + 1 < b.bottom: g.rows[b.strip + 1][b.right - 1].bg else: ""
    for r in b.strip + 1 ..< b.bottom:
      # a horizontal scrollbar: a row of bar glyphs and blanks only
      let raw = g.rowText(r, b.left, b.right).replace(BoxEdge, "").replace("▕", "").strip
      if raw.len > 0:
        var only = true
        for ch in raw.toRunes:
          if $ch notin ["█", "▉", "▊", "▋", "▌", "▍", "▎", "▄", "▁", "━", "─", " "]:
            only = false
            break
        if only: hbar = true
      var text = g.rowText(r, b.left, b.right).strip
      # the box's own edge glyphs (scrollbars, dividers) are not its text
      for edge in [BoxEdge, "▕", "▁"]:
        text = text.replace(edge, "")
      text = text.strip
      if text.len == 0: continue
      lines.add text
      inc n
      # its cells: the runs of text two or more blanks apart, where drawn
      var cells: seq[tuple[text: string, col, width: int]]
      var c = b.left
      while c < b.right:
        while c < b.right and g.rows[r][c].text in ["", " ", BoxEdge, "▕", "▁"]: inc c
        if c >= b.right: break
        let start = c
        var cell = ""
        var blanks = 0
        var last = c
        while c < b.right and g.rows[r][c].text notin [BoxEdge, "▕"]:
          let ch = g.rows[r][c].text
          if ch == " " or ch == "":
            inc blanks
            if blanks >= 2: break
          else:
            if blanks == 1: cell.add " "
            blanks = 0
            cell.add ch
            last = c
          inc c
        if cell.len > 0: cells.add (cell, start, last - start + 1)
      let first = if cells.len > 0: cells[0].text else: text
      let row = node("row", fl(b.left), fl(r), fl(b.right - b.left), 1,
                     %*{"text": text, "first": first,
                        "selected": g.rowSelected(r, b.left, b.right, usual)},
                     @[("text", text), ("first", first)])
      t.add(pane, row)
      for cell in cells:
        t.add(row, node("cell", fl(cell.col), fl(r), fl(cell.width), 1,
                        %*{"text": cell.text}, @[("text", cell.text)]))
    var labels: seq[string]
    for l in b.labels: labels.add l.label
    pane.props = %*{"title": title, "text": lines, "count": n, "tabs": labels, "hbar": hbar}

proc readFiles(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## The Files pane's tree: one node per row, by its name (the open file's
  ## `•` marker read as `selected`).
  for b in g.boxes():
    if b.activeLabel != "Files": continue
    let fs = node("filesystem", fl(b.left), fl(b.strip), fl(b.right - b.left),
                  fl(b.bottom - b.strip))
    t.add(root, fs)
    var n = 0
    for r in b.strip + 1 ..< b.bottom:
      var text = g.rowText(r, b.left, b.right).replace(BoxEdge, "").strip
      if text.len == 0: continue
      var kind = "file"
      var expanded = false
      var open = false
      if text.startsWith("▼ "):
        kind = "folder"; expanded = true; text = text[4 .. ^1]
      elif text.startsWith("▶ "):
        kind = "folder"; text = text[4 .. ^1]
      if text.startsWith("•"):
        open = true; text = text[3 .. ^1]
      text = text.strip
      inc n
      t.add(fs, node("file-node", fl(b.left), fl(r), fl(b.right - b.left), 1,
                     %*{"name": text, "kind": kind, "expanded": expanded, "selected": open},
                     @[("name", text)]))
    fs.props = %*{"count": n, "focused": false}

proc readDockLabels(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## The footer's auto-hide labels (the status row).
  let r = g.height - 1
  for label in FooterLabels:
    let c = g.findCol(r, " " & label & " ")
    if c >= 0:
      t.add(root, node("dock-label", fl(c + 1), fl(r), fl(label.len), 1,
                       %*{"label": label}, @[("label", label)]))

proc readChrome*(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## The program menu's root button and the transport controls (row 0).
  let menuCol = g.findCol(0, "≡")
  if menuCol >= 0:
    let bar = node("menu-bar", fl(menuCol), 0, 1, 1)
    t.add(root, bar)
    let open = g.overlays.anyIt(it.top == 1)
    t.add(bar, node("menu", fl(menuCol), 0, 1, 1, %*{"label": "Menu", "open": open},
                    @[("label", "Menu")]))
  let lens = g.findCol(0, "⌕")
  let limit = if lens > 0: lens else: g.width
  var buttons: seq[(string, int)]
  for (glyph, label) in TransportGlyphs:
    let c = g.findCol(0, glyph)
    if c >= 0 and c < limit: buttons.add (label, c)
  if buttons.len > 0:
    let tb = node("toolbar", fl(buttons[0][1]), 0, fl(buttons[^1][1] - buttons[0][1] + 1), 1)
    t.add(root, tb)
    for (label, c) in buttons:
      t.add(tb, node("toolbar-button", fl(c), 0, 1, 1, %*{"label": label, "enabled": true},
                     @[("label", label)]))

const WelcomeActions = ["New file", "Open folder", "Record new trace", "Open local trace",
                        "Open online trace", "CodeTracer shell"]
  ## `welcome_screen_vm.StartOptionNames`, the welcome tab's start options.

proc readWelcome(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## The welcome tab: its heading and start options, wherever it draws them.
  var at = (-1, -1)
  for r in 1 ..< g.height - 1:
    let c = g.findCol(r, "Welcome to CodeTracer")
    if c >= 0:
      at = (r, c)
      break
  if at[0] < 0: return
  var lines: seq[string]
  for r in at[0] ..< g.height - 1:
    let t = g.rowText(r).strip
    if t.len > 0: lines.add t
  let w = node("welcome", 0, fl(at[0]), fl(g.width), fl(g.height - 1 - at[0]),
               %*{"heading": "Welcome to CodeTracer", "text": lines})
  t.add(root, w)
  for label in WelcomeActions:
    for r in at[0] ..< g.height - 1:
      let c = g.findCol(r, label)
      if c >= 0:
        t.add(w, node("welcome-action", fl(c), fl(r), fl(label.len), 1,
                      %*{"label": label}, @[("label", label)]))
        break

proc readReplayPosition(g: ScreenGrid; t: var Tree; root: SurfaceNode) =
  ## The top bar's trace summary: `tick: <n> / <total>`.
  let top = g.rowText(0)
  let at = top.find("tick: ")
  if at < 0: return
  var i = at + 6
  var n = ""
  while i < top.len and top[i] in Digits:
    n.add top[i]
    inc i
  var total = ""
  if top.continuesWith(" / ", i):
    i += 3
    while i < top.len and top[i] in Digits:
      total.add top[i]
      inc i
  if n.len == 0: return
  t.add(root, node("replay-position", fl(g.findCol(0, "tick: ")), 0, 12, 1,
                   %*{"tick": parseInt(n), "total": (if total.len > 0: parseInt(total) else: 0),
                      "paused": top.contains("[PAUSED]")}))

proc readTerminalBatch*(g: ScreenGrid; t: var Tree) =
  readDockLabels(g, t, t.root)
  readWelcome(g, t, t.root)
  readFiles(g, t, t.root)
  readPanes(g, t, t.root)
  readOverlays(g, t, t.root, menus = false)

proc readSurface*(g: ScreenGrid): Tree =
  ## The page objects on the screen.
  result.root = node("window", 0, 0, fl(g.width), fl(g.height), newJObject())
  result.root.visible = true
  readStatus(g, result, result.root)
  # --- terminal --- the replay's position next: the nodes before it keep
  # their places while the panes change, so an id taken for it stays valid
  readReplayPosition(g, result, result.root)
  readChrome(g, result, result.root)
  readOverlays(g, result, result.root, menus = true)
  readTopBar(g, result, result.root)
  var mode = "debug"
  if g.rowText(g.height - 1).contains("[EDIT]"): mode = "edit"
  result.root.props = %*{"title": "", "mode": mode}
  result.root.unreadable["title"] = "a terminal has no window title the screen shows"
  for b in g.boxes():
    for l in b.labels:
      addPaneTab(result, b, l)
    let active = b.activeLabel
    if active.isSourceLabel or active.contains("the recording's source"):
      readEditor(g, b, result, result.root)
    else:
      case active
      of "Call Trace": readList(g, b, result, result.root, "call-trace", "call", "name")
      of "Event Log": readList(g, b, result, result.root, "event-log", "event", "text")
      of "Variables": readList(g, b, result, result.root, "variables", "variable", "name")
      of "Terminal Output":
        var lines: seq[string]
        for r in b.strip + 1 ..< b.bottom:
          let s = g.rowText(r, b.left, b.right).strip(leading = false)
          if s.strip.len > 0: lines.add s.strip
        result.add(result.root, node("terminal-output", fl(b.left), fl(b.strip),
                                     fl(b.right - b.left), fl(b.bottom - b.strip),
                                     %*{"text": lines, "count": lines.len}))
      else: discard
  readTerminalBatch(g, result)
