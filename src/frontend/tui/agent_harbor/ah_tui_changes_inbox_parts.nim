## tui/agent_harbor/ah_tui_changes_inbox_parts.nim — CTF-P3. The parts the
## terminal's Changes panel (`ah_tui_changes_panel.nim`) and Inbox
## (`ah_tui_inbox_panel.nim`) both draw: a state word with its dot, a chip, a
## form's button, a select and its dropped menu, a text field, a group's
## head, a diff's hunks, a row of buttons that wraps, the submitting
## spinner, and the grounds the two views separate their areas by.
##
## The web draws these parts in `agent_harbor_changes.styl` and
## `agent_harbor_inbox.styl`, GPUI in `gpui/agent_harbor/ah_changes_inbox_parts.nim`;
## the roles are the same (`agent_harbor_changes_inbox_palette`, which the
## GPUI parts read too), adapted to cells: where the web outlines a control,
## the terminal puts it on a ground of its own, and where it draws a hairline
## between two areas, the terminal changes the ground (CodeTracer-TUI §3.4,
## "How the terminal draws it").
##
## Every part tags what it draws with the facts the GPUI parts carry
## (`state-word`, `chip`, `chip-text`, `button`, `primary`, `disabled`,
## `select-value`, `input`, `typed`, `hunks`, `hunk-head`, `hunk-line`), so a
## reader of either host's drawing reads the same names.
##
## ## Selects
##
## A terminal has no native drop-down. A select is drawn closed (its value
## and `▾` on the controls' ground); a press drops its menu under it, on the
## ground every dropped surface takes (`ah_tui_canvas.dropGround`), and a
## press on a choice calls the viewmodel and closes it. Which select is
## dropped is the host's own state (`AhP3State.open`), as a pointer's hover
## is: nothing a viewmodel or a story records.
##
## ## Scrolling
##
## A list longer than its region scrolls (`drawScrolled`), the way the
## terminal VCS pane scrolls its rows (`app/views/vcs_pane`): the host keeps
## the region's first row (`AhP3State`, as the VCS pane's host carries its
## `scrollTop`), the content is drawn whole and the region shows the window
## from that row, and while the content overflows the region's rightmost
## column is its scrollbar, the shared scrubber model's thumb
## (`scrollbar_scrubber`, projected by `scrubber_track.thumbCells`). The
## wheel and the page keys move the window (`scrollBy`); the row the
## keyboard is on, or the item on screen, is brought into view when it
## changes. A press on the scrollbar's track jumps there.
##
## ## The spinner
##
## A submitting action is marked by a spinner glyph before its words
## (CodeTracer-TUI §3.4 "Animation where it informs"). The frame drawn is `AhP3State.spinnerFrame`: 0 unless the story
## host advances it, which it does only with animation on (a capture and
## every test draws frame 0, so a capture never moves).

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
import ../../viewmodel/views/agent_harbor_changes_inbox_palette
import ../../viewmodel/views/agent_harbor_changes_code
import ../../viewmodel/views/agent_harbor_changes_inbox_words

import ./ah_tui_canvas
import ../app/views/scrubber_track
from codetracer_embed import scrubberModel, thumbSpan, clickAt, trackFractionAt

export ah_tui_canvas, agent_harbor_changes_inbox_palette, agent_harbor_changes_code

const
  DropGlyph* = "\xE2\x96\xBE"        ## ▾ a closed select's arrow
  SpinnerFrames* = ["\xE2\xA0\x8B", "\xE2\xA0\x99", "\xE2\xA0\xB9", "\xE2\xA0\xB8",
                    "\xE2\xA0\xBC", "\xE2\xA0\xB4", "\xE2\xA0\xA6", "\xE2\xA0\xA7",
                    "\xE2\xA0\x87", "\xE2\xA0\x8F"]
    ## ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏: the braille spinner, one cell wide in every
    ## monospace font the terminal profiles name.
  FieldRows* = 3
    ## A text field's rows: the web's `textarea rows="3"`.

type
  AhMenuChoice* = object
    id*, label*: string

  AhMenu = object
    ## A select dropped this draw, drawn last so it lies over what is under it.
    key: string
    row, col, width: int
    choices: seq[AhMenuChoice]
    current: string
    pick: proc(id: string) {.closure.}

  AhScrollRegion* = object
    ## A region drawn this draw that scrolls: where it is on the screen, how
    ## tall its content is, its first row shown.
    key*: string
    row*, col*, width*, height*: int
    content*, top*: int

  AhP3State* = ref object
    ## What the terminal host keeps between draws of a Changes or Inbox story
    ## that no viewmodel holds: the dropped select, the spinner's frame.
    open*: string
      ## The select whose menu is dropped ("" for none).
    spinnerFrame*: int
      ## The spinner's frame (`SpinnerFrames`); 0 unless the host animates.
    spinning*: bool
      ## The last draw drew a spinner: the host may advance its frame.
    menus: seq[AhMenu]
    scrolls: seq[(string, int)]
      ## Each scrolling region's first row shown, by its key.
    seen: seq[(string, string)]
      ## Each region's item kept in view at the last draw (the keyboard's
      ## item, the item on screen): a change brings the new one into view.
    regions*: seq[AhScrollRegion]
      ## The scrolling regions of the last draw.

  P3Grounds* = object
    ## The grounds the two views' areas take, resolved for one mode from the
    ## palette's roles (see each field). Any two areas that touch are on two
    ## of these that differ, in both modes.
    panel*: string       ## a list, a page: surface/base/panel
    stripe*: string      ## every other row: the fleet rows' stripe (`AhTone.band`)
    groupHead*: string
      ## A group's head (a spec tier, a milestone, a server): Dark
      ## surface/base/raised (#161616), Light surface/base/card (#dbd6cc),
      ## each off the panel and the stripe.
    tabBand*: string
      ## The tab bar and the Previous / Next bar: Dark surface/base/canvas
      ## (#1b1b1b), Light surface/base/raised (#f3f3f3): off the head band
      ## above and off a group's head below (Dark's raised is the group
      ## head's own).
    activeTab*: string
      ## The explanation strip and a shown side's toggle: the session strip's
      ## active-tab grey.
    tabActive*: string
      ## The active tab: the selection's ground, off the band and off the
      ## controls' grey of a select under it.
    selection*: string   ## the item on screen: the palette's selection tint over the panel
    control*: string     ## a button, a closed select: `AhTone.chip`
    strip*: string
      ## The explanation strip over a page reached by Previous / Next: Dark
      ## the active tab's grey (#3c3c3c), Light surface/base/card (#dbd6cc),
      ## off the rows above it and the page under it.
    field*: string
      ## A text field: Dark surface/base/raised (#161616, a well 1.29:1 off
      ## the panel), Light surface/base/canvas (#d2ccc1, 1.25:1); the
      ## input roles are the panel's own grey in Dark and 1.12:1 off it in
      ## Light, where the web draws the field's border.
    banner*: string      ## a question's banner: `AhTone.head`
    gap*: string
      ## The column between the inbox's rows and the page beside them: Dark
      ## surface/primary/tertiary-hover (#414141), Light surface/base/canvas
      ## (#d2ccc1), off every ground the column touches.

proc p3Grounds*(c: AhCanvas): P3Grounds =
  let dark = c.p.mode == dmDark
  P3Grounds(panel: c.tone.body, stripe: c.tone.band,
            groupHead: (if dark: c.tone.group[0] else: c.tone.group[1]),
            tabBand: (if dark: tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode)
                      else: c.tone.filters),
            activeTab: c.p.activeTab, tabActive: selectedGround(c.p),
            selection: selectedGround(c.p), control: c.tone.chip,
            strip: (if dark: c.p.activeTab else: c.p.menu),
            field: (if dark: tokenHexOf(dtColorsUiSurfaceBaseRaised, c.p.mode)
                    else: tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode)),
            banner: c.tone.head,
            gap: (if dark: tokenHexOf(dtColorsUiSurfacePrimaryTertiaryHover, c.p.mode)
                  else: tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode)))

proc stripeOf*(g: P3Grounds; index: int): string =
  ## Row `index`'s ground in a striped list: the panel, then the stripe.
  if index mod 2 == 0: g.panel else: g.stripe

proc inks*(c: AhCanvas): ChangesInboxInks = changesInboxInks(c.p.mode)

proc beginDraw*(s: AhP3State) =
  ## A draw starts: no menu dropped yet, no spinner drawn, no region.
  if s.isNil: return
  s.menus.setLen(0)
  s.spinning = false
  s.regions.setLen(0)

proc scrollTopOf*(s: AhP3State; key: string): int =
  ## The region's first row shown (0 for a region never scrolled).
  if s.isNil: return 0
  for (k, v) in s.scrolls:
    if k == key: return v

proc setScrollTop*(s: AhP3State; key: string; top: int) =
  if s.isNil: return
  for i in 0 ..< s.scrolls.len:
    if s.scrolls[i][0] == key:
      s.scrolls[i][1] = top
      return
  s.scrolls.add (key, top)

proc regionOf*(s: AhP3State; key: string): AhScrollRegion =
  if s.isNil: return
  for r in s.regions:
    if r.key == key: return r

proc regionAt*(s: AhP3State; row, col: int): AhScrollRegion =
  ## The scrolling region under (`row`, `col`); one with an empty key for
  ## none.
  if s.isNil: return
  for r in s.regions:
    if row >= r.row and row < r.row + r.height and col >= r.col and col < r.col + r.width:
      return r

proc scrollBy*(s: AhP3State; key: string; delta: int): bool =
  ## Moves region `key`'s window `delta` rows (negative: up), within its
  ## content as the last draw measured it; true when it moved.
  let r = s.regionOf(key)
  if r.key.len == 0: return false
  let top = clamp(r.top + delta, 0, max(0, r.content - r.height))
  if top == r.top: return false
  s.setScrollTop(key, top)
  true

proc pageOf*(s: AhP3State; key: string): int =
  ## A page of region `key`: its height less a row kept for context.
  max(1, s.regionOf(key).height - 1)

# ---------------------------------------------------------------------------
# Words with a role
# ---------------------------------------------------------------------------

proc stateWordCells*(text: string): int = 2 + widthOf(text)
  ## `● word`: the dot, a cell, the word.

proc drawStateWord*(c: var AhCanvas; parent: AhNode; row, col: int; text, role: string;
                    maxCells = 0): AhNode =
  ## A state word at (`row`, `col`): the dot in its role's mark (`roleDot`:
  ## a ring for `idle`), a cell, the word in its role's ink, cut to
  ## `maxCells` when given. Tagged `state-word` and `role`, as GPUI's.
  let ink = c.inks
  let shown = if maxCells > 2: elide(text, maxCells - 2) else: text
  result = c.node(parent, row, col, 2 + widthOf(shown), 1,
                  [("state-word", text), ("role", role)])
  discard c.mark(result, row, col, c.p.roleDot(role))
  discard c.put(row, col + 2, shown, c.p.roleInk(ink, role))
  discard c.node(result, row, col + 2, widthOf(shown), 1, [("state-text", text)])

proc drawChip*(c: var AhCanvas; parent: AhNode; row, col: int; text, role, kind: string): int =
  ## A chip (`.ah-chip`): the word, a cell clear on each side, in its role's
  ## ink on the row's own ground. The web's chip ground is
  ## surface/primary/secondary, the panel's own grey in both modes, so it
  ## reads as a coloured word there too; a ground of its own here would join
  ## the row above wherever that row is the panel. Returns the cells.
  let label = " " & text & " "
  discard c.put(row, col, label, c.p.roleInk(c.inks, role))
  let n = c.node(parent, row, col, widthOf(label), 1, [("chip", kind)])
  discard c.node(n, row, col + 1, widthOf(text), 1, [("chip-text", text)])
  widthOf(label)

proc spinnerOf*(s: AhP3State): string =
  ## The spinner's glyph at the host's frame (the first frame without a host).
  let f = if s.isNil: 0 else: s.spinnerFrame
  SpinnerFrames[f mod SpinnerFrames.len]

# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------

type
  AhButton* = object
    label*: string
    primary*, disabled*: bool
    press*: proc() {.closure.}

proc buttonCells*(label: string): int = widthOf(label) + 2

proc drawButton*(c: var AhCanvas; parent: AhNode; row, col: int; b: AhButton): int =
  ## A form's button: its label a cell in on a ground of its own. The
  ## primary is filled in the action role with the on-action ink (a
  ## disabled one at half strength, as GPUI draws it); the others on the
  ## controls' ground in the label ink (a disabled one in the disabled ink).
  ## A press calls `press` unless disabled. Returns the cells it takes.
  let g = c.p3Grounds
  let label = " " & b.label & " "
  let (fg, bg) =
    if b.primary:
      ((if b.disabled: blendOver(c.p.onAction & "80", c.p.action) else: c.p.onAction),
       c.p.action)
    else:
      ((if b.disabled: c.p.textDisabled else: c.p.textLabel), g.control)
  discard c.put(row, col, label, fg, bold = b.primary and not b.disabled, bg = bg)
  discard c.node(parent, row, col, widthOf(label), 1,
                 [("button", b.label), ("primary", $b.primary), ("disabled", $b.disabled)])
  if not b.disabled and b.press != nil:
    c.target(row, col, widthOf(label), 1, b.press)
  widthOf(label)

proc drawButtons*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                  buttons: seq[AhButton]; fact = "actions"): int =
  ## A row of buttons a cell apart, wrapping onto the next row where the row
  ## cannot hold the next one (`.ah-item-actions`: `flex-wrap: wrap`).
  ## Returns the rows taken (none for no button).
  if buttons.len == 0: return 0
  let n = c.node(parent, row, col, width, 1, [(fact, $buttons.len)])
  var r = row
  var x = col
  for b in buttons:
    let w = buttonCells(b.label)
    if x > col and x + w > col + width:
      inc r
      x = col
    x += c.drawButton(n, r, x, b) + 1
  n.height = r - row + 1
  r - row + 1

proc drawSelect*(c: var AhCanvas; s: AhP3State; parent: AhNode; row, col, maxCells: int;
                 key, fact, shown: string; choices: seq[AhMenuChoice]; current: string;
                 pick: proc(id: string)): int =
  ## A closed select: ` <value> ▾ ` on the controls' ground, as wide as its
  ## widest choice (the browser's sizing), at most `maxCells`. A press drops
  ## its menu (or closes it), and a press on a choice calls `pick` and closes
  ## it. Tagged `fact` (the shown value) and `select-value`. Returns the
  ## cells it takes.
  let g = c.p3Grounds
  var widest = widthOf(shown)
  for ch in choices: widest = max(widest, widthOf(ch.label))
  let w = max(4, min(maxCells, widest + 4))
  let value = elide(shown, w - 4)
  discard c.put(row, col, " " & value & repeat(' ', max(0, w - 4 - widthOf(value))) & " " &
                DropGlyph & " ", c.p.textLabel, bg = g.control)
  let n = c.node(parent, row, col, w, 1, [(fact, shown)])
  discard c.node(n, row, col + 1, widthOf(value), 1, [("select-value", shown)])
  if not s.isNil:
    let state = s
    c.target(row, col, w, 1, proc() =
      state.open = if state.open == key: "" else: key)
    if s.open == key:
      let close = proc(id: string) =
        state.open = ""
        pick(id)
      s.menus.add AhMenu(key: key, row: row + 1, col: col, width: w, choices: choices,
                         current: current, pick: close)
  w

proc pickPress(pick: proc(id: string); id: string): proc() =
  ## A menu choice's press: a proc of its own, so each closure owns its id (a
  ## closure in a Nim loop body shares the body's variables with every other
  ## iteration's).
  result = proc() = pick(id)

proc drawMenus*(c: var AhCanvas; s: AhP3State) =
  ## The dropped selects of this draw, over what was drawn under them: each
  ## choice on its own row, the current one marked `›` and bold; a press
  ## picks it.
  if s.isNil: return
  for m in s.menus:
    var w = m.width
    for ch in m.choices: w = max(w, widthOf(ch.label) + 4)
    w = min(w, c.cols - m.col)
    let col = max(0, min(m.col, c.cols - w))
    let ground = c.dropArea("menu", m.row, col, w, m.choices.len)
    let n = c.node(nil, m.row, col, w, m.choices.len, [("menu", m.key)])
    for i, ch in m.choices:
      let on = ch.id == m.current
      discard c.put(m.row + i, col + 1, (if on: "\xE2\x80\xBA " else: "  ") &
                    elide(ch.label, w - 4), c.p.textBody, bold = on, bg = ground)
      discard c.node(n, m.row + i, col, w, 1, [("menu-choice", ch.id)])
      c.target(m.row + i, col, w, 1, pickPress(m.pick, ch.id))

proc drawTextField*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                    typed, placeholder: string; disabled: bool; rows = FieldRows): int =
  ## A form's text field (`.ah-text-field`): `rows` rows across `width` on the
  ## field's ground, the typed text wrapped a cell in (in the body ink), or
  ## the placeholder in the subtle label ink; disabled, on the disabled
  ## surface in the disabled ink. The story hosts take no typing: the field
  ## shows what the viewmodel holds. Tagged `input` and `typed`. Returns the
  ## rows it takes.
  let g = c.p3Grounds
  let ink = c.inks
  # Disabled, the field keeps its ground and its words take the disabled
  # ink: the disabled surface is the panel's own grey in Dark and #7a756a in
  # Light, on which the disabled ink would not read.
  let ground = g.field
  c.area("field", row, col, width, rows, ground)
  let shown = if typed.len > 0: typed else: placeholder
  let fg = if disabled: c.p.textDisabled
           elif typed.len > 0: c.p.textBody else: ink.placeholder
  let lines = wrapCells(shown, max(1, width - 2))
  for i in 0 ..< min(rows, lines.len):
    var l = lines[i]
    if i == rows - 1 and lines.len > rows: l = elide(l & " " & lines[rows].strip, width - 2)
    discard c.put(row + i, col + 1, l, fg)
  discard c.node(parent, row, col, width, rows,
                 [("input", shown), ("typed", $(typed.len > 0))])
  rows

# ---------------------------------------------------------------------------
# Heads, prose, hunks
# ---------------------------------------------------------------------------

proc drawGroupHead*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                    name: string; count: int; fact = "changes-group";
                    ground = ""): AhNode =
  ## A group's head (`.ah-changes-group-head`): a band on the group head's
  ## ground (where the web draws a hairline), the name in capitals, bold, in
  ## the label ink, and its count in parentheses in the caption ink.
  let g = c.p3Grounds
  c.area("group-head", row, col, width, 1, if ground.len > 0: ground else: g.groupHead)
  let upper = name.toUpperAscii
  let countText = "(" & $count & ")"
  let room = max(1, width - 3 - widthOf(countText))
  result = c.node(parent, row, col, width, 1, [(fact, name), ("group-head", "true")])
  let w = c.text(result, row, col + 1, room, upper, c.p.textLabel, bold = true,
                 fact = "group-name")
  discard c.put(row, col + 1 + w + 1, countText, c.p.textCaption)

proc drawSmallCaps*(c: var AhCanvas; parent: AhNode; row, col, cells: int; name: string): int =
  ## A small-caps label (`.ah-card-meta-label`, `.ah-item-section-name`):
  ## capitals, bold, in the label ink. Returns the cells drawn.
  c.text(parent, row, col, cells, name.toUpperAscii, c.p.textLabel, bold = true)

proc drawHunks*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                hunks: seq[DiffHunk]): int =
  ## A diff's hunks (`.ah-hunks`): each hunk's header (`@@ -a,b +c,d @@` and
  ## git's section) in the information ink, then each line with its marker,
  ## added lines in the success ink, removed in the error ink, unchanged in
  ## the label ink, each cut at the row's end (a diff line is code: it is
  ## not wrapped). The lines go through the VCS panel's hunk value
  ## (`agent_harbor_changes_code.vcsHunkRow`), as the web's and GPUI's do.
  ## Returns the rows taken.
  let ink = c.inks
  var r = row
  var count = 0
  let n = c.node(parent, row, col, width, 1, [])
  if hunks.len == 0:
    discard c.text(n, r, col, width, NoHunksText, c.p.textCaption)
    inc r
  for hunk in hunks:
    let h = vcsHunkRow(hunk)
    let header = hunkHeader(h) & (if hunk.section.len > 0: " " & hunk.section else: "")
    discard c.text(n, r, col, width, header, ink.textInfo, fact = "hunk-head")
    inc r
    for line in h.lines:
      let fg = case line.lineType
        of "added": c.p.textSuccess
        of "removed": c.p.textError
        else: c.p.textLabel
      discard c.put(r, col, lineMarker(line), fg)
      discard c.put(r, col + 2, elide(diffLineText(line), max(1, width - 2)), fg)
      discard c.node(n, r, col, width, 1, [("hunk-line", line.lineType)])
      inc r
      inc count
  n.height = r - row
  n.tag("hunks", $count)
  r - row

# ---------------------------------------------------------------------------
# Scrolling regions
# ---------------------------------------------------------------------------

const
  SubCanvasRows = 4000
    ## The rows a region's content is drawn into before its window is shown:
    ## more than any story's content (300 files, their open diff).

type
  ScrolledBody* = proc(sub: var AhCanvas; parent: AhNode; row, width: int): int {.closure.}
    ## Draws a region's content into `sub` from `row`, `width` cells wide at
    ## the region's column; returns the rows it took.

proc shiftNode(n: AhNode; delta, top, bottom, foot: int) =
  ## Moves a node drawn on the content canvas onto the screen: down `delta`
  ## rows; a node the window does not show whole is put below the screen's
  ## foot (`foot`), where a reader of the drawing treats it as clipped, as
  ## the web's list clips what is scrolled out of it.
  for ch in n.children: shiftNode(ch, delta, top, bottom, foot)
  let r = n.row + delta
  if r >= top and r + max(1, n.height) <= bottom: n.row = r
  else: n.row = foot + n.row

proc keptRow(sub: AhNode; fact, value: string): tuple[row, height: int] =
  ## The row and height of the node carrying `fact` = `value` ("true" for a
  ## flag), -1 for none.
  result = (-1, 0)
  if value.len == 0: return
  for n in sub.all(fact):
    if n.attr(fact) == value: return (n.row, max(1, n.height))

proc trackPress(s: AhP3State; key: string; at, rows, content, first: int): proc() =
  ## A press on row `at` of a region's scrollbar: the window jumps to centre
  ## the row it stands for (the shared model's click, `clickAt`). A proc of
  ## its own so each closure owns its row.
  result = proc() =
    let m = scrubberModel(content, first, rows)
    s.setScrollTop(key, clamp(m.clickAt(trackFractionAt(at, rows)), 0, max(0, content - rows)))

proc drawScrolled*(c: var AhCanvas; s: AhP3State; key: string; parent: AhNode;
                   row, col, width, height: int; ground: string;
                   keepFact, keepValue: string; body: ScrolledBody;
                   keepAtTop = false): int =
  ## Region `key` at (`row`, `col`), `width` x `height` cells on `ground`:
  ## `body`'s content, shown from the region's first row (kept within the
  ## content, and moved to show the node carrying `keepFact` = `keepValue`
  ## when that value changed since the last draw: the least move, or, with
  ## `keepAtTop`, to the region's first row whenever it must move, so what
  ## is drawn under it shows too), with a scrollbar in its
  ## last column while the content overflows. Returns the content's rows.
  if height <= 0 or width <= 1: return 0
  var w = width
  var sub = newAhCanvas(c.cols, SubCanvasRows, c.p)
  let menusBefore = if s.isNil: 0 else: s.menus.len
  sub.area("region", 0, col, w, SubCanvasRows, ground)
  var content = body(sub, sub.root, 0, w)
  if content > height:
    # The scrollbar takes the last column: the content again, a cell narrower.
    if not s.isNil: s.menus.setLen(menusBefore)
    w = width - ScrubberTrackCells
    sub = newAhCanvas(c.cols, SubCanvasRows, c.p)
    sub.area("region", 0, col, w, SubCanvasRows, ground)
    content = body(sub, sub.root, 0, w)
  content = min(content, SubCanvasRows)
  var top = clamp(s.scrollTopOf(key), 0, max(0, content - height))
  if not s.isNil:
    var last = ""
    for (k, v) in s.seen:
      if k == key: last = v
    if keepValue != last:
      let (kr, kh) = keptRow(sub.root, keepFact, keepValue)
      if kr >= 0:
        if keepAtTop and (kr < top or kr + min(kh, height) > top + height): top = kr
        elif kr < top: top = kr
        elif kr + min(kh, height) > top + height: top = kr + min(kh, height) - height
        top = clamp(top, 0, max(0, content - height))
      var found = false
      for i in 0 ..< s.seen.len:
        if s.seen[i][0] == key:
          s.seen[i][1] = keepValue
          found = true
      if not found: s.seen.add (key, keepValue)
    s.setScrollTop(key, top)
    s.regions.add AhScrollRegion(key: key, row: row, col: col, width: width,
                                 height: height, content: content, top: top)
  # The window: the cells, the areas, the nodes and the presses.
  c.fill(row, col, width, height, ground)
  for r in 0 ..< height:
    let src = top + r
    if src >= SubCanvasRows: break
    for x in col ..< col + w:
      let rune = sub.grid.runeAt(src, x)
      if rune.len == 0: continue
      c.grid.paint(row + r, x, rune, sub.grid.styleAt(src, x))
    if w < width:
      # The scrollbar's column is on its row's ground (a stripe, a band or
      # the panel run on under it), so it parts nothing.
      c.fill(row + r, col + w, width - w, 1, sub.grid.styleAt(src, col + w - 1).bg)
  let delta = row - top
  for a in sub.areas:
    let r0 = max(a.row + delta, row)
    let r1 = min(a.row + a.height + delta, row + height)
    if r1 > r0 and a.name != "region":
      # An area that reaches the content's right edge runs on under the
      # scrollbar's column.
      let aw = if w < width and a.col + a.width == col + w: a.width + width - w else: a.width
      c.areas.add AhArea(name: a.name, row: r0, col: a.col, width: aw,
                         height: r1 - r0, bg: a.bg)
  for n in sub.root.children:
    shiftNode(n, delta, row, row + height, c.rows + SubCanvasRows)
    parent.children.add n
  for t in sub.targets:
    let r0 = max(t.row + delta, row)
    let r1 = min(t.row + t.height + delta, row + height)
    if r1 > r0:
      var moved = t
      moved.row = r0
      moved.height = r1 - r0
      c.targets.add moved
  if not s.isNil:
    for i in menusBefore ..< s.menus.len: s.menus[i].row += delta
  if content > height:
    # The scrollbar: the shared scrubber model's thumb, in eighths.
    let bar = col + width - 1
    let sm = scrubberModel(content, top, height)
    let cells = thumbCells(sm.thumbSpan(height * 8, MinThumbEighths), height, vertical = true)
    # The track is the row's own ground (no line: CodeTracer-TUI §3.4, few
    # borders); only the thumb is drawn.
    for i, cell in cells:
      let under = c.grid.styleAt(row + i, bar).bg
      case cell.kind
      of tcThumb, tcThumbSpace:
        discard c.put(row + i, bar, cell.glyph, c.p.textCaption)
      of tcThumbReversed:
        discard c.put(row + i, bar, cell.glyph, under, bg = c.p.textCaption)
      of tcTrack: discard
    discard c.node(parent, row, bar, 1, height,
                   [("scrollbar", key), ("scroll-top", $top), ("scroll-content", $content)])
    if not s.isNil:
      for i in 0 ..< height:
        c.target(row + i, bar, 1, 1, trackPress(s, key, i, height, content, top))
  content
