## viewmodels/terminal_output_model.nim — the Terminal Output pane's MODEL,
## shared by the desktop, the terminal and the GPUI window.
##
## Spec: `codetracer-specs/spec/GUI/Core-Panes/Terminal-Output-Pane.md`.
##
## Pure: no ViewModel, no renderer, no signal, no `when defined(js)`. It
## compiles for the C and the JavaScript backends alike, and every front-end
## reads the SAME answers from it — so the desktop's spans, the terminal's
## cells and the window's text runs cannot disagree about which characters a
## program wrote in which colour, or what its screen looked like at a tick.
##
## ## What it holds
##
##  1. **An ANSI scanner** (`AnsiScanner`): the recorded byte stream split into
##     text, C0 controls, CSI and ESC sequences — streaming, so a sequence a
##     program split across two writes is still one sequence.
##  2. **SGR decoding** (`applySgr`): the attributes a run was written in, as
##     DATA (`types.TermAttrs`) — foreground, background, bold, faint, italic,
##     underline, blink, reverse, hidden, strike. The desktop used to keep
##     `ansi_up`'s HTML here, which only a browser can draw.
##  3. **The line view** (`buildTerminalLines`): the output split into lines and
##     each line into fragments — one styled run of one write — exactly the
##     grouping the desktop's line cache made, with every escape sequence that
##     is not SGR dropped and tabs expanded to the next multiple of eight.
##  4. **The screen view** (`TermScreen`, `TerminalScreenModel`): a terminal
##     emulator state machine over the same stream — cursor addressing, erase,
##     insert / delete, scroll regions, the alternate screen, autowrap — with
##     PERIODIC SNAPSHOTS, so the screen at any write is reconstructed by
##     replaying only from the nearest snapshot (§3 "Cost"), never from byte 0.
##     Its semantics follow libvterm's (`nim-libvterm`), which the tests use as
##     the reference emulator.
##  5. **The built-in scrubber's range and marks** — the writes, first to last,
##     and where the program cleared the screen or switched to / from the
##     alternate screen.

import std/[base64, hashes, json, math, strutils, tables, unicode]

import ../store/types

# ---------------------------------------------------------------------------
# 1. The scanner
# ---------------------------------------------------------------------------

type
  AnsiState = enum
    asGround, asEscape, asEscInter, asCsi, asOsc, asOscEsc, asString,
    asStringEsc, asCharset

  AnsiTokenKind* = enum
    atText      ## printable text (UTF-8)
    atControl   ## a C0 control byte (`ch`)
    atCsi       ## `ESC [ <private> <params> <inter> <final>`
    atEsc       ## `ESC <inter> <final>`

  AnsiToken* = object
    kind*: AnsiTokenKind
    text*: string
    ch*: char
      ## The control byte, or the sequence's final byte.
    params*: seq[seq[int]]
      ## CSI parameters: one group per `;`, sub-parameters per `:`; an
      ## omitted parameter is -1.
    private*: char
      ## `?`, `>`, `<` or `=` right after `CSI`, else `'\0'`.
    inter*: string
      ## Intermediate bytes (0x20..0x2f).

  AnsiScanner* = object
    ## The scanner's state BETWEEN writes, so an escape sequence split across
    ## two writes is read as one.
    state: AnsiState
    groups: seq[seq[int]]
    cur: int
    hasCur: bool
    private: char
    inter: string

proc flushParam(sc: var AnsiScanner; newGroup: bool) =
  if sc.groups.len == 0:
    sc.groups.add @[]
  sc.groups[^1].add(if sc.hasCur: sc.cur else: -1)
  sc.cur = 0
  sc.hasCur = false
  if newGroup:
    sc.groups.add @[]

proc scanAnsi*(sc: var AnsiScanner; data: string): seq[AnsiToken] =
  ## Split `data` into tokens, continuing from where the previous write left
  ## the scanner.
  var text = ""
  template flushText() =
    if text.len > 0:
      result.add AnsiToken(kind: atText, text: text)
      text = ""
  for c in data:
    let b = ord(c)
    case sc.state
    of asGround:
      if c == '\x1b':
        flushText()
        sc.state = asEscape
        sc.inter = ""
      elif b < 0x20:
        flushText()
        result.add AnsiToken(kind: atControl, ch: c)
      elif b == 0x7f:
        discard
      else:
        text.add c
    of asEscape:
      case c
      of '[':
        sc.state = asCsi
        sc.groups = @[]
        sc.cur = 0
        sc.hasCur = false
        sc.private = '\0'
        sc.inter = ""
      of ']':
        sc.state = asOsc
      of 'P', 'X', '^', '_':
        sc.state = asString
      of '(', ')', '*', '+', '-', '.', '/':
        sc.state = asCharset
      of '\x1b':
        sc.state = asEscape
      else:
        if b >= 0x20 and b <= 0x2f:
          sc.inter.add c
          sc.state = asEscInter
        elif b >= 0x30 and b <= 0x7e:
          result.add AnsiToken(kind: atEsc, ch: c, inter: sc.inter)
          sc.state = asGround
        elif b < 0x20:
          result.add AnsiToken(kind: atControl, ch: c)
        else:
          sc.state = asGround
    of asEscInter:
      if b >= 0x20 and b <= 0x2f:
        sc.inter.add c
      elif b >= 0x30 and b <= 0x7e:
        result.add AnsiToken(kind: atEsc, ch: c, inter: sc.inter)
        sc.state = asGround
      else:
        sc.state = asGround
    of asCharset:
      sc.state = asGround
    of asCsi:
      if c >= '0' and c <= '9':
        sc.cur = sc.cur * 10 + (b - ord('0'))
        if sc.cur > 1_000_000: sc.cur = 1_000_000
        sc.hasCur = true
      elif c == ';':
        sc.flushParam(newGroup = true)
      elif c == ':':
        sc.flushParam(newGroup = false)
      elif c in {'?', '>', '<', '='} and sc.groups.len == 0 and
           not sc.hasCur and sc.private == '\0':
        sc.private = c
      elif b >= 0x20 and b <= 0x2f:
        sc.inter.add c
      elif b >= 0x40 and b <= 0x7e:
        if sc.hasCur or sc.groups.len > 0:
          sc.flushParam(newGroup = false)
        result.add AnsiToken(kind: atCsi, ch: c, params: sc.groups,
                             private: sc.private, inter: sc.inter)
        sc.state = asGround
      elif c == '\x1b':
        sc.state = asEscape
        sc.inter = ""
      elif b < 0x20:
        # A C0 control inside a CSI sequence is executed (xterm, libvterm).
        result.add AnsiToken(kind: atControl, ch: c)
      else:
        sc.state = asGround
    of asOsc:
      if c == '\x07':
        sc.state = asGround
      elif c == '\x1b':
        sc.state = asOscEsc
    of asOscEsc:
      sc.state = (if c == '\\': asGround else: asOsc)
    of asString:
      if c == '\x1b':
        sc.state = asStringEsc
    of asStringEsc:
      sc.state = (if c == '\\': asGround else: asString)
  flushText()

func csiParam*(t: AnsiToken; i: int; default: int): int =
  ## The `i`-th parameter's first value, or `default` when omitted / zero
  ## where the sequence treats 0 as 1 (the caller decides by `default`).
  if i < t.params.len and t.params[i].len > 0 and t.params[i][0] >= 0:
    t.params[i][0]
  else:
    default

# ---------------------------------------------------------------------------
# 2. SGR
# ---------------------------------------------------------------------------

func termIndexed*(i: int): TermColor = TermColor(kind: tckIndexed, index: i)
func termRgbColor*(r, g, b: int): TermColor =
  TermColor(kind: tckRgb, r: r, g: g, b: b)

proc hash*(c: TermColor): Hash =
  !$(hash(ord(c.kind)) !& hash(c.index) !& hash(c.r) !& hash(c.g) !&
     hash(c.b))

proc hash*(a: TermAttrs): Hash =
  !$(hash(a.fg) !& hash(a.bg) !& hash(a.bold) !& hash(a.faint) !&
     hash(a.italic) !& hash(a.underline) !& hash(a.blink) !&
     hash(a.reverse) !& hash(a.hidden) !& hash(a.strike))

proc applySgr*(attrs: var TermAttrs; t: AnsiToken) =
  ## Apply one `CSI ... m` to `attrs`.
  if t.params.len == 0:
    attrs = TermAttrs()
    return
  # Flatten `;`-separated groups, keeping each `:`-group whole for 38/48/58.
  var i = 0
  var flat: seq[seq[int]] = t.params
  proc v(g: seq[int]): int = (if g.len > 0 and g[0] >= 0: g[0] else: 0)
  while i < flat.len:
    let g = flat[i]
    let n = v(g)
    case n
    of 0: attrs = TermAttrs()
    of 1: attrs.bold = true
    of 2: attrs.faint = true
    of 3: attrs.italic = true
    of 4:
      attrs.underline = not (g.len > 1 and g[1] == 0)
    of 5, 6: attrs.blink = true
    of 7: attrs.reverse = true
    of 8: attrs.hidden = true
    of 9: attrs.strike = true
    of 21: attrs.underline = true
    of 22:
      attrs.bold = false
      attrs.faint = false
    of 23: attrs.italic = false
    of 24: attrs.underline = false
    of 25: attrs.blink = false
    of 27: attrs.reverse = false
    of 28: attrs.hidden = false
    of 29: attrs.strike = false
    of 30 .. 37: attrs.fg = termIndexed(n - 30)
    of 39: attrs.fg = TermColor()
    of 40 .. 47: attrs.bg = termIndexed(n - 40)
    of 49: attrs.bg = TermColor()
    of 90 .. 97: attrs.fg = termIndexed(n - 90 + 8)
    of 100 .. 107: attrs.bg = termIndexed(n - 100 + 8)
    of 38, 48, 58:
      var colour = TermColor()
      var ok = false
      if g.len > 1:
        # The `:` form: 38:5:n, 38:2:r:g:b or 38:2::r:g:b.
        if g[1] == 5 and g.len >= 3:
          colour = termIndexed(max(0, g[2]) and 255); ok = true
        elif g[1] == 2 and g.len >= 5:
          let o = if g.len >= 6: 3 else: 2
          colour = termRgbColor(max(0, g[o]) and 255, max(0, g[o+1]) and 255,
                            max(0, g[o+2]) and 255)
          ok = true
      else:
        # The `;` form consumes the following groups.
        if i + 1 < flat.len:
          let mode = v(flat[i+1])
          if mode == 5 and i + 2 < flat.len:
            colour = termIndexed(v(flat[i+2]) and 255); ok = true
            i += 2
          elif mode == 2 and i + 4 < flat.len:
            colour = termRgbColor(v(flat[i+2]) and 255, v(flat[i+3]) and 255,
                              v(flat[i+4]) and 255)
            ok = true
            i += 4
          else:
            i += 1
      if ok:
        if n == 38: attrs.fg = colour
        elif n == 48: attrs.bg = colour
    else:
      discard
    inc i

const AnsiPalette16*: array[16, (int, int, int)] = [
  (0, 0, 0), (187, 0, 0), (0, 187, 0), (187, 187, 0),
  (0, 0, 187), (187, 0, 187), (0, 187, 187), (255, 255, 255),
  (85, 85, 85), (255, 85, 85), (0, 255, 0), (255, 255, 85),
  (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255)]
  ## The sixteen ANSI colours — the desktop's palette (`ansi_up` 6.0.6's
  ## `setup_palettes`), so the terminal and GPUI draw a recorded program's
  ## red in the red the desktop has always drawn it in.

func termColorRgb*(c: TermColor): (int, int, int) =
  ## The colour as RGB, through the desktop's palette (16 named colours, the
  ## 6x6x6 cube and the grey ramp of the 256-colour table). `tckDefault` has
  ## no RGB: the caller draws its surface's own colour.
  case c.kind
  of tckDefault: (0, 0, 0)
  of tckRgb: (c.r, c.g, c.b)
  of tckIndexed:
    let i = c.index
    if i < 16: AnsiPalette16[max(0, i)]
    elif i < 232:
      const levels = [0, 95, 135, 175, 215, 255]
      let j = i - 16
      (levels[j div 36], levels[(j div 6) mod 6], levels[j mod 6])
    else:
      let g = 8 + (i - 232) * 10
      (g, g, g)

func termHex*(c: TermColor): string =
  ## `#rrggbb`, or "" for the default colour.
  if c.kind == tckDefault:
    return ""
  let (r, g, b) = termColorRgb(c)
  "#" & toHex(r, 2).toLowerAscii & toHex(g, 2).toLowerAscii &
    toHex(b, 2).toLowerAscii

func drawnColours*(a: TermAttrs): tuple[fg, bg: TermColor] =
  ## The colours a run is DRAWN in: reverse video swaps them, a default one
  ## swapped becomes the palette's black / white (as `ansi_up` drew it). Every
  ## front-end that draws colours itself (the desktop's CSS, GPUI's runs)
  ## reads this; the terminal hands `reverse` to the terminal instead.
  var fg = a.fg
  var bg = a.bg
  if a.reverse:
    swap(fg, bg)
    if fg.kind == tckDefault: fg = termIndexed(0)
    if bg.kind == tckDefault: bg = termIndexed(7)
  (fg, bg)

func cssOf*(a: TermAttrs): string =
  ## The desktop's inline style for a run — the declarations `ansi_up` wrote
  ## (`color:rgb(r,g,b)`, `background-color:...`, `font-weight:bold`,
  ## `opacity:0.7`, `font-style:italic`, `text-decoration:underline`), plus
  ## the attributes `ansi_up` dropped (reverse, strike, hidden).
  let (fg, bg) = drawnColours(a)
  var parts: seq[string] = @[]
  if fg.kind != tckDefault:
    let (r, g, b) = termColorRgb(fg)
    parts.add "color:rgb(" & $r & "," & $g & "," & $b & ")"
  if bg.kind != tckDefault:
    let (r, g, b) = termColorRgb(bg)
    parts.add "background-color:rgb(" & $r & "," & $g & "," & $b & ")"
  if a.bold: parts.add "font-weight:bold"
  if a.faint: parts.add "opacity:0.7"
  if a.italic: parts.add "font-style:italic"
  var deco: seq[string] = @[]
  if a.underline: deco.add "underline"
  if a.strike: deco.add "line-through"
  if deco.len > 0: parts.add "text-decoration:" & deco.join(" ")
  if a.hidden: parts.add "visibility:hidden"
  parts.join(";")

func describe*(a: TermAttrs): string =
  ## One line, for a test's failure message and a capture's JSON.
  var parts: seq[string] = @[]
  if a.fg.kind != tckDefault: parts.add "fg=" & termHex(a.fg)
  if a.bg.kind != tckDefault: parts.add "bg=" & termHex(a.bg)
  for (on, name) in [(a.bold, "bold"), (a.faint, "faint"),
                     (a.italic, "italic"), (a.underline, "underline"),
                     (a.blink, "blink"), (a.reverse, "reverse"),
                     (a.hidden, "hidden"), (a.strike, "strike")]:
    if on: parts.add name
  if parts.len == 0: "plain" else: parts.join(" ")

# ---------------------------------------------------------------------------
# Decoding `ct/loaded-terminal`
# ---------------------------------------------------------------------------

proc terminalEventsFromJson*(body: JsonNode): seq[TerminalOutputEvent] =
  ## The writes of a `ct/load-terminal` answer (or `ct/loaded-terminal`
  ## event body): a JSON array of `ProgramEvent`s.
  if body.isNil or body.kind != JArray:
    return
  for i, e in body.getElems:
    var content = e{"content"}.getStr("")
    if e{"base64Encoded"}.getBool(false):
      try:
        content = decode(content)
      except CatchableError:
        discard
    result.add TerminalOutputEvent(
      content: content,
      rrTicks: uint64(max(0'i64, e{"directLocationRRTicks"}.getBiggestInt(0))),
      eventIndex: i,
      logIndex: e{"eventIndex"}.getInt(i),
      path: e{"highLevelPath"}.getStr(""),
      line: e{"highLevelLine"}.getInt(0),
      stdout: e{"stdout"}.getBool(true))

# ---------------------------------------------------------------------------
# 3. The line view
# ---------------------------------------------------------------------------

const TermTabStop* = 8

type
  TerminalTense* = enum
    ttPast = "past"
    ttActive = "active"
    ttFuture = "future"

func fragmentTense*(currentTicks, fragmentTicks: uint64): TerminalTense =
  ## Past / active / future against the debugger's position: the desktop's
  ## `.past` / `.active` / `.future` classes, which every front-end draws.
  if fragmentTicks < currentTicks: ttPast
  elif fragmentTicks == currentTicks: ttActive
  else: ttFuture

type
  TerminalLineBuilder* = object
    ## The line view built write by write.
    scanner: AnsiScanner
    attrs: TermAttrs
    col: int
    lines*: seq[TerminalLine]
    cur: seq[TerminalEventFragment]

proc addText(b: var TerminalLineBuilder; ev: TerminalOutputEvent;
             text: string) =
  if text.len == 0:
    return
  if b.cur.len > 0 and b.cur[^1].eventIndex == ev.eventIndex and
     b.cur[^1].style == b.attrs:
    b.cur[^1].text.add text
  else:
    b.cur.add TerminalEventFragment(text: text, style: b.attrs,
                                    eventIndex: ev.eventIndex,
                                    rrTicks: ev.rrTicks)
  b.col += text.runeLen

proc endLine(b: var TerminalLineBuilder; ev: TerminalOutputEvent) =
  if b.cur.len == 0:
    # An empty line still belongs to the write that ended it, so it can be
    # clicked (the desktop's line cache kept an empty fragment for it).
    b.cur.add TerminalEventFragment(text: "", style: b.attrs,
                                    eventIndex: ev.eventIndex,
                                    rrTicks: ev.rrTicks)
  b.lines.add TerminalLine(lineIndex: b.lines.len, fragments: b.cur)
  b.cur = @[]
  b.col = 0

proc addEvent*(b: var TerminalLineBuilder; ev: TerminalOutputEvent) =
  for t in b.scanner.scanAnsi(ev.content):
    case t.kind
    of atText:
      b.addText(ev, t.text)
    of atControl:
      case t.ch
      of '\n': b.endLine(ev)
      of '\t':
        b.addText(ev, spaces(TermTabStop - (b.col mod TermTabStop)))
      else: discard
    of atCsi:
      if t.ch == 'm' and t.private == '\0' and t.inter.len == 0:
        b.attrs.applySgr(t)
    of atEsc:
      if t.ch == 'c' and t.inter.len == 0:
        b.attrs = TermAttrs()

proc finishLines*(b: var TerminalLineBuilder): seq[TerminalLine] =
  result = b.lines
  if b.cur.len > 0:
    result.add TerminalLine(lineIndex: result.len, fragments: b.cur)

proc buildTerminalLines*(events: openArray[TerminalOutputEvent]):
    seq[TerminalLine] =
  ## The line view of `events`: lines, each a sequence of styled fragments.
  var b = TerminalLineBuilder()
  for ev in events:
    b.addEvent(ev)
  b.finishLines()

func lineText*(line: TerminalLine): string =
  for f in line.fragments:
    result.add f.text

func lineOfTick*(lines: openArray[TerminalLine]; ticks: uint64): int =
  ## The line holding the LAST fragment written at or before `ticks` — the
  ## line view's current-position mark — or -1 before the first write.
  result = -1
  for i, l in lines:
    for f in l.fragments:
      if f.rrTicks <= ticks:
        result = i

# ---------------------------------------------------------------------------
# 4. The screen
# ---------------------------------------------------------------------------

const
  DefaultScreenCols* = 80
  DefaultScreenRows* = 24
    ## A recording that carries no terminal size is reconstructed at 80x24
    ## (Terminal-Output-Pane.md §3 "Geometry").

type
  AttrTable* = ref object
    ## Every distinct attribute set the screen has used, so a cell holds a
    ## small index and a snapshot is cheap to keep. Append-only and SHARED by
    ## every snapshot of one model.
    items*: seq[TermAttrs]
    index: Table[TermAttrs, int32]

  TermCell* = object
    ch*: int32
      ## The character (a rune), 0 for an erased cell.
    attr*: int32
      ## Into the screen's `AttrTable`.
    wide*: int8
      ## 2 for the first cell of a double-width character, -1 for its second.

  SavedCursor = object
    row, col: int
    attrs: TermAttrs
    valid: bool

  TermScreen* = object
    ## A terminal's state: both buffers, the cursor, the pen, the scroll
    ## region and the scanner — a value, so a snapshot is a copy.
    cols*, rows*: int
    primary, alternate: seq[TermCell]
    altActive*: bool
    row*, col*: int
    wrapPending: bool
    pen*: TermAttrs
    saved: SavedCursor
    top, bottom: int
    autowrap: bool
    cursorVisible*: bool
    scanner: AnsiScanner
    table*: AttrTable
    # What the last `feed` saw.
    sawClear*, sawAltEnter*, sawAltLeave*, sawScreenControl*: bool

proc newAttrTable*(): AttrTable =
  result = AttrTable(items: @[TermAttrs()])
  result.index[TermAttrs()] = 0'i32

proc idOf(t: AttrTable; a: TermAttrs): int32 =
  if a in t.index:
    return t.index[a]
  result = int32(t.items.len)
  t.items.add a
  t.index[a] = result

proc newTermScreen*(cols = DefaultScreenCols; rows = DefaultScreenRows;
                    table: AttrTable = nil): TermScreen =
  result = TermScreen(cols: max(1, cols), rows: max(1, rows),
                      autowrap: true, cursorVisible: true,
                      table: (if table.isNil: newAttrTable() else: table))
  result.primary = newSeq[TermCell](result.cols * result.rows)
  result.alternate = newSeq[TermCell](result.cols * result.rows)
  result.top = 0
  result.bottom = result.rows - 1

template buf(s: TermScreen): untyped =
  (if s.altActive: s.alternate else: s.primary)

proc cellAt*(s: TermScreen; row, col: int): TermCell =
  if row < 0 or row >= s.rows or col < 0 or col >= s.cols:
    return TermCell()
  if s.altActive: s.alternate[row * s.cols + col]
  else: s.primary[row * s.cols + col]

proc attrsOf*(s: TermScreen; c: TermCell): TermAttrs =
  if c.attr >= 0 and c.attr < s.table.items.len.int32:
    s.table.items[c.attr]
  else: TermAttrs()

proc setCell(s: var TermScreen; row, col: int; c: TermCell) =
  if row < 0 or row >= s.rows or col < 0 or col >= s.cols:
    return
  if s.altActive: s.alternate[row * s.cols + col] = c
  else: s.primary[row * s.cols + col] = c

proc blankCell(s: var TermScreen): TermCell =
  ## An erased cell carries the pen's colours and nothing else (libvterm's
  ## `erase_internal`).
  TermCell(ch: 0, attr: s.table.idOf(TermAttrs(fg: s.pen.fg, bg: s.pen.bg)))

proc eraseRect(s: var TermScreen; r0, c0, r1, c1: int) =
  ## Erase rows `r0..r1`, columns `c0 ..< c1` on each.
  let blank = s.blankCell()
  for r in max(0, r0) .. min(s.rows - 1, r1):
    for c in max(0, c0) ..< min(s.cols, c1):
      s.setCell(r, c, blank)

proc scrollUp(s: var TermScreen; top, bottom, n: int) =
  ## Scroll rows `top..bottom` up by `n`, erasing what comes in at the
  ## bottom.
  if n <= 0 or top > bottom: return
  let n = min(n, bottom - top + 1)
  for r in top .. bottom - n:
    for c in 0 ..< s.cols:
      s.setCell(r, c, s.cellAt(r + n, c))
  s.eraseRect(bottom - n + 1, 0, bottom, s.cols)

proc scrollDown(s: var TermScreen; top, bottom, n: int) =
  if n <= 0 or top > bottom: return
  let n = min(n, bottom - top + 1)
  for r in countdown(bottom, top + n):
    for c in 0 ..< s.cols:
      s.setCell(r, c, s.cellAt(r - n, c))
  s.eraseRect(top, 0, top + n - 1, s.cols)

proc lineFeed(s: var TermScreen) =
  s.wrapPending = false
  if s.row == s.bottom:
    s.scrollUp(s.top, s.bottom, 1)
  elif s.row < s.rows - 1:
    inc s.row

proc reverseIndex(s: var TermScreen) =
  s.wrapPending = false
  if s.row == s.top:
    s.scrollDown(s.top, s.bottom, 1)
  elif s.row > 0:
    dec s.row

func runeCells*(r: Rune): int =
  ## How many cells a character takes: 0 for a combining mark, 2 for an East
  ## Asian wide or fullwidth character or an emoji, else 1.
  let c = int(r)
  if c == 0: return 0
  if (c >= 0x0300 and c <= 0x036f) or (c >= 0x200b and c <= 0x200f) or
     (c >= 0xfe00 and c <= 0xfe0f):
    return 0
  if (c >= 0x1100 and c <= 0x115f) or (c >= 0x2e80 and c <= 0xa4cf and
     c != 0x303f) or (c >= 0xac00 and c <= 0xd7a3) or
     (c >= 0xf900 and c <= 0xfaff) or (c >= 0xfe30 and c <= 0xfe4f) or
     (c >= 0xff00 and c <= 0xff60) or (c >= 0xffe0 and c <= 0xffe6) or
     (c >= 0x1f300 and c <= 0x1f64f) or (c >= 0x1f900 and c <= 0x1f9ff) or
     (c >= 0x20000 and c <= 0x3fffd):
    return 2
  1

proc putRune(s: var TermScreen; r: Rune) =
  let w = runeCells(r)
  if w == 0:
    return
  if s.wrapPending:
    if s.autowrap:
      s.col = 0
      s.lineFeed()
    s.wrapPending = false
  if w == 2 and s.col == s.cols - 1:
    if s.autowrap:
      s.setCell(s.row, s.col, s.blankCell())
      s.col = 0
      s.lineFeed()
    else:
      return
  let a = s.table.idOf(s.pen)
  s.setCell(s.row, s.col, TermCell(ch: int32(r), attr: a,
                                   wide: (if w == 2: 2'i8 else: 0'i8)))
  if w == 2:
    s.setCell(s.row, s.col + 1, TermCell(ch: 0, attr: a, wide: -1))
  if s.col + w >= s.cols:
    s.col = s.cols - 1
    s.wrapPending = true
  else:
    s.col += w

proc clampCursor(s: var TermScreen) =
  s.row = max(0, min(s.rows - 1, s.row))
  s.col = max(0, min(s.cols - 1, s.col))
  s.wrapPending = false

proc saveCursor(s: var TermScreen) =
  s.saved = SavedCursor(row: s.row, col: s.col, attrs: s.pen, valid: true)

proc restoreCursor(s: var TermScreen) =
  if s.saved.valid:
    s.row = s.saved.row
    s.col = s.saved.col
    s.pen = s.saved.attrs
  else:
    s.row = 0
    s.col = 0
    s.pen = TermAttrs()
  s.clampCursor()

proc setAlt(s: var TermScreen; on: bool) =
  if on == s.altActive:
    if on:
      # libvterm erases the alternate screen on every enable.
      s.eraseRect(0, 0, s.rows - 1, s.cols)
    return
  s.altActive = on
  if on:
    s.eraseRect(0, 0, s.rows - 1, s.cols)
    s.sawAltEnter = true
    s.sawClear = true
  else:
    s.sawAltLeave = true

proc fullReset(s: var TermScreen) =
  let table = s.table
  let scanner = s.scanner
  s = newTermScreen(s.cols, s.rows, table)
  s.scanner = scanner
  s.sawClear = true

proc insertChars(s: var TermScreen; n: int) =
  let n = min(n, s.cols - s.col)
  for c in countdown(s.cols - 1, s.col + n):
    s.setCell(s.row, c, s.cellAt(s.row, c - n))
  s.eraseRect(s.row, s.col, s.row, s.col + n)

proc deleteChars(s: var TermScreen; n: int) =
  let n = min(n, s.cols - s.col)
  for c in s.col ..< s.cols - n:
    s.setCell(s.row, c, s.cellAt(s.row, c + n))
  s.eraseRect(s.row, s.cols - n, s.row, s.cols)

proc setMode(s: var TermScreen; t: AnsiToken; on: bool) =
  if t.private != '?':
    return
  for g in t.params:
    if g.len == 0: continue
    case g[0]
    of 7: s.autowrap = on
    of 25: s.cursorVisible = on
    of 47, 1047:
      s.sawScreenControl = true
      s.setAlt(on)
    of 1048:
      if on: s.saveCursor() else: s.restoreCursor()
    of 1049:
      s.sawScreenControl = true
      if on:
        s.saveCursor()
        s.setAlt(true)
      else:
        s.setAlt(false)
        s.restoreCursor()
    else: discard

proc csi(s: var TermScreen; t: AnsiToken) =
  if t.inter.len > 0:
    return
  let n1 = max(1, t.csiParam(0, 1))
  case t.ch
  of 'm':
    if t.private == '\0': s.pen.applySgr(t)
  of 'h': s.setMode(t, true)
  of 'l': s.setMode(t, false)
  of 'A':
    s.row = (if s.row >= s.top: max(s.top, s.row - n1) else: s.row - n1)
    s.clampCursor()
  of 'B', 'e':
    s.row = (if s.row <= s.bottom: min(s.bottom, s.row + n1) else: s.row + n1)
    s.clampCursor()
  of 'C', 'a':
    s.col += n1
    s.clampCursor()
  of 'D':
    s.col -= n1
    s.clampCursor()
  of 'E':
    s.row = min(s.bottom, s.row + n1); s.col = 0; s.clampCursor()
  of 'F':
    s.row = max(s.top, s.row - n1); s.col = 0; s.clampCursor()
  of 'G', '`':
    s.col = n1 - 1
    s.clampCursor()
    s.sawScreenControl = true
  of 'd':
    s.row = n1 - 1
    s.clampCursor()
    s.sawScreenControl = true
  of 'H', 'f':
    if t.private == '\0':
      s.row = max(1, t.csiParam(0, 1)) - 1
      s.col = max(1, t.csiParam(1, 1)) - 1
      s.clampCursor()
      s.sawScreenControl = true
  of 'J':
    if t.private != '\0' and t.private != '?': return
    s.sawScreenControl = true
    case t.csiParam(0, 0)
    of 0:
      s.eraseRect(s.row, s.col, s.row, s.cols)
      s.eraseRect(s.row + 1, 0, s.rows - 1, s.cols)
    of 1:
      s.eraseRect(0, 0, s.row - 1, s.cols)
      s.eraseRect(s.row, 0, s.row, s.col + 1)
    of 2:
      s.eraseRect(0, 0, s.rows - 1, s.cols)
      s.sawClear = true
    else: discard
    s.wrapPending = false
  of 'K':
    if t.private != '\0' and t.private != '?': return
    case t.csiParam(0, 0)
    of 0: s.eraseRect(s.row, s.col, s.row, s.cols)
    of 1: s.eraseRect(s.row, 0, s.row, s.col + 1)
    of 2: s.eraseRect(s.row, 0, s.row, s.cols)
    else: discard
    s.wrapPending = false
  of 'X':
    s.eraseRect(s.row, s.col, s.row, s.col + n1)
    s.wrapPending = false
  of '@':
    s.insertChars(n1)
    s.wrapPending = false
  of 'P':
    s.deleteChars(n1)
    s.wrapPending = false
  of 'L':
    if s.row >= s.top and s.row <= s.bottom:
      s.scrollDown(s.row, s.bottom, n1)
      s.col = 0
    s.wrapPending = false
  of 'M':
    if s.row >= s.top and s.row <= s.bottom:
      s.scrollUp(s.row, s.bottom, n1)
      s.col = 0
    s.wrapPending = false
  of 'S':
    if t.private == '\0': s.scrollUp(s.top, s.bottom, n1)
  of 'T':
    if t.private == '\0' and t.params.len <= 1:
      s.scrollDown(s.top, s.bottom, n1)
  of 'r':
    if t.private == '\0':
      let top = max(1, t.csiParam(0, 1)) - 1
      let bottom = (if t.csiParam(1, 0) <= 0: s.rows else: t.csiParam(1, 0)) - 1
      if top < bottom and bottom < s.rows:
        s.top = top
        s.bottom = bottom
      else:
        s.top = 0
        s.bottom = s.rows - 1
      s.row = 0
      s.col = 0
      s.wrapPending = false
  of 's':
    if t.private == '\0' and t.params.len == 0: s.saveCursor()
  of 'u':
    if t.private == '\0': s.restoreCursor()
  else:
    discard

proc control(s: var TermScreen; c: char) =
  case c
  of '\n':
    # The terminal device's output processing (ONLCR, on in every terminal a
    # program writes to): a line feed the program wrote reaches the terminal
    # as CR LF. A program's `print` therefore starts its next line at the
    # left edge, as the user saw it.
    s.col = 0
    s.lineFeed()
  of '\v', '\f': s.lineFeed()
  of '\r':
    s.col = 0
    s.wrapPending = false
  of '\b':
    if s.col > 0: dec s.col
    s.wrapPending = false
  of '\t':
    s.col = min(s.cols - 1, (s.col div TermTabStop + 1) * TermTabStop)
    s.wrapPending = false
  else: discard

proc feed*(s: var TermScreen; data: string) =
  ## Run `data` through the state machine, as the terminal received it (a
  ## line feed as CR LF — `control`).
  s.sawClear = false
  s.sawAltEnter = false
  s.sawAltLeave = false
  s.sawScreenControl = false
  for t in s.scanner.scanAnsi(data):
    case t.kind
    of atText:
      for r in t.text.runes:
        s.putRune(r)
    of atControl:
      s.control(t.ch)
    of atCsi:
      s.csi(t)
    of atEsc:
      if t.inter.len > 0: continue
      case t.ch
      of '7': s.saveCursor()
      of '8': s.restoreCursor()
      of 'D': s.lineFeed()
      of 'E':
        s.col = 0
        s.lineFeed()
      of 'M': s.reverseIndex()
      of 'c':
        s.fullReset()
        s.sawScreenControl = true
      else: discard

type
  ScreenRun* = object
    ## Adjacent cells of one row in one style, for a front-end to draw.
    col*: int
    cells*: int
    text*: string
    attrs*: TermAttrs

proc screenRowText*(s: TermScreen; row: int): string =
  ## A row's characters, an erased cell as a space, a wide character once.
  for c in 0 ..< s.cols:
    let cell = s.cellAt(row, c)
    if cell.wide == -1: continue
    result.add(if cell.ch == 0: " " else: $Rune(cell.ch))

proc screenRowRuns*(s: TermScreen; row: int): seq[ScreenRun] =
  ## A row as styled runs, left to right, covering every column.
  var c = 0
  while c < s.cols:
    let cell = s.cellAt(row, c)
    if cell.wide == -1:
      inc c
      continue
    let a = s.attrsOf(cell)
    let w = if cell.wide == 2: 2 else: 1
    let txt = if cell.ch == 0: " " else: $Rune(cell.ch)
    if result.len > 0 and result[^1].attrs == a:
      result[^1].text.add txt
      result[^1].cells += w
    else:
      result.add ScreenRun(col: c, cells: w, text: txt, attrs: a)
    c += w

# ---------------------------------------------------------------------------
# 5. The screen over time, its snapshots, its scrubber
# ---------------------------------------------------------------------------

type
  ScreenMarkKind* = enum
    smClear = "clear"
      ## The program cleared the whole screen (`ED 2`, `RIS`).
    smAltEnter = "alt-enter"
      ## It switched to the alternate screen.
    smAltLeave = "alt-leave"
      ## It switched back to the main screen.

  ScreenMark* = object
    write*: int
    kind*: ScreenMarkKind

  TerminalScreenModel* = ref object
    ## The recorded output as a screen, at every write.
    cols*, rows*: int
    writes*: seq[TerminalOutputEvent]
    snapshotEvery*: int
      ## `snapshots[j]` is the screen after the first `j * snapshotEvery`
      ## writes.
    snapshots: seq[TermScreen]
    marks*: seq[ScreenMark]
    offered*: bool
      ## The output contains screen control (the alternate screen, absolute
      ## cursor addressing, erase-in-display): the pane offers the screen view.
    replayed*: int
      ## How many writes the last `screenAfter` fed — the cost probe the
      ## tests read (§3 "Cost": never the whole stream per move).
    cacheWrite: int
    cache: TermScreen
    table: AttrTable

const
  MaxSnapshots* = 256
  MinSnapshotEvery* = 16

proc snapshotIntervalFor*(writes: int): int =
  ## Every N writes, N chosen so a model keeps at most `MaxSnapshots`.
  max(MinSnapshotEvery, (writes + MaxSnapshots - 1) div MaxSnapshots)

proc newTerminalScreenModel*(events: openArray[TerminalOutputEvent];
                             cols = DefaultScreenCols;
                             rows = DefaultScreenRows): TerminalScreenModel =
  ## Build the model: one pass over every write, keeping a snapshot every
  ## `snapshotEvery` writes and noting the marks.
  result = TerminalScreenModel(cols: cols, rows: rows,
                               snapshotEvery: snapshotIntervalFor(events.len),
                               cacheWrite: -2, table: newAttrTable())
  result.writes = @events
  var s = newTermScreen(cols, rows, result.table)
  result.snapshots.add s
  for i, ev in events:
    s.feed(ev.content)
    if s.sawScreenControl: result.offered = true
    if s.sawAltEnter: result.marks.add ScreenMark(write: i, kind: smAltEnter)
    if s.sawAltLeave: result.marks.add ScreenMark(write: i, kind: smAltLeave)
    if s.sawClear and not s.sawAltEnter:
      result.marks.add ScreenMark(write: i, kind: smClear)
    if (i + 1) mod result.snapshotEvery == 0:
      result.snapshots.add s

proc writeCount*(m: TerminalScreenModel): int =
  if m.isNil: 0 else: m.writes.len

proc screenAfter*(m: TerminalScreenModel; write: int): TermScreen =
  ## The screen after write `write` (0-based) was applied; the blank screen
  ## for -1. Replays from the nearest snapshot — or from the last screen
  ## asked for, when that is nearer — and never more than `snapshotEvery`
  ## writes.
  if m.isNil:
    return newTermScreen()
  let w = min(write, m.writes.len - 1)
  if w < 0:
    m.replayed = 0
    return newTermScreen(m.cols, m.rows, m.table)
  let j = (w + 1) div m.snapshotEvery
  var start = j * m.snapshotEvery
  var s: TermScreen
  if m.cacheWrite >= start - 1 and m.cacheWrite <= w:
    s = m.cache
    start = m.cacheWrite + 1
  else:
    s = m.snapshots[min(j, m.snapshots.len - 1)]
  m.replayed = 0
  for i in start .. w:
    s.feed(m.writes[i].content)
    inc m.replayed
  m.cache = s
  m.cacheWrite = w
  s

proc writeAtTick*(m: TerminalScreenModel; ticks: uint64): int =
  ## The last write at or before `ticks`, -1 before the first: the screen
  ## "as the program left it at the current recording position".
  result = -1
  if m.isNil: return
  var lo = 0
  var hi = m.writes.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    if m.writes[mid].rrTicks <= ticks:
      result = mid
      lo = mid + 1
    else:
      hi = mid - 1

func writeAtFraction*(writes: int; fraction: float): int =
  ## The built-in scrubber's track, first write to last: the write a pointer
  ## at `fraction` (0..1) of the track names.
  if writes <= 0: return -1
  let f = max(0.0, min(1.0, fraction))
  int(round(f * float(writes - 1)))

func fractionOfWrite*(writes, write: int): float =
  ## Where write `write` sits on the track.
  if writes <= 1: 0.0
  else: max(0.0, min(1.0, float(write) / float(writes - 1)))

func markGlyph*(k: ScreenMarkKind): string =
  ## How a mark is drawn under a text-cell scrubber.
  case k
  of smClear: "c"
  of smAltEnter: "▲"
  of smAltLeave: "▼"

func markTitle*(k: ScreenMarkKind): string =
  case k
  of smClear: "screen cleared"
  of smAltEnter: "alternate screen"
  of smAltLeave: "main screen"

# ---------------------------------------------------------------------------
# The view choice, per recording
# ---------------------------------------------------------------------------

type
  TerminalView* = enum
    tvLines = "lines"
    tvScreen = "screen"

func defaultViewFor*(offered: bool): TerminalView =
  ## A program that drives the terminal as a screen opens in the screen view;
  ## a plain line-oriented one in the line view (§3 "When it is offered").
  if offered: tvScreen else: tvLines

proc recordingKeyOf*(outputFolder: cstring): string =
  ## The key a recording's remembered view choice is filed under: its output
  ## folder, or "" when it has none.
  ##
  ## A recording made in a browser tab has NO output folder — it lives in the
  ## page, not on a disk — so its `Trace.outputFolder` arrives as `null`.
  ## Converting that with `$` raises under the JS backend, and the raise
  ## happened inside the terminal pane's load handler, so every in-browser
  ## Run reported an uncaught "Cannot read properties of null (reading
  ## 'length')". "" is the VM's own spelling of "no recording to remember
  ## for": `setView` still applies the choice, it only does not file it.
  if outputFolder.isNil: "" else: $outputFolder

proc viewMemoryFromJson*(text: string): Table[string, TerminalView] =
  ## The remembered choices, `{ "<recording>": "lines" | "screen" }`; none for
  ## an empty or unreadable store. Checked BEFORE parsing: on the JavaScript
  ## backend `parseJson("")` throws the engine's own `SyntaxError`, which no
  ## `except CatchableError` catches (measured: the desktop's pane stopped
  ## loading on a fresh profile).
  if text.strip.len == 0 or text.strip[0] != '{':
    return
  try:
    let j = parseJson(text)
    if j.kind == JObject:
      for k, v in j.pairs:
        let s = v.getStr("")
        if s == $tvScreen: result[k] = tvScreen
        elif s == $tvLines: result[k] = tvLines
  except:  # a bare `except` is the one that catches a JavaScript SyntaxError
    discard

proc viewMemoryToJson*(m: Table[string, TerminalView]): string =
  var j = newJObject()
  for k, v in m.pairs:
    j[k] = %($v)
  $j
