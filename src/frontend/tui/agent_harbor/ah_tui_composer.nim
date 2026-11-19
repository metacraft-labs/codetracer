## tui/agent_harbor/ah_tui_composer.nim — CTF-P2c (P2c-G). The terminal's
## omnibox composer: the caption bar's omnibox field in agent mode
## (`/ai …`) and the composer's sheet dropped under it, over
## `OmniboxComposerVM` (nim-agents-isonim-viewmodels), as the web
## (`isonim_agent_harbor_composer_view`) and GPUI
## (`gpui/agent_harbor/ah_composer.nim`) draw it. Every word both front-ends
## say comes from `agent_harbor_composer_words`, which renders nothing.
##
## The sheet is a surface dropped from the caption bar, `sheetWidthFor`
## cells wide (the viewmodel's `min(640px, window − 16px)` at 8 px a cell)
## and centred under the field, on grounds of its own (`inksFor`). Inside it
## nothing is boxed (TUI §3.4, cardless). Where the web draws a hairline the
## ground changes: the header and the context in view are a band, the
## destinations and the form are on the sheet, and the send line is a band
## again. A destination row is marked by the inset bar `▎` in the action
## border role down its first cell (never a fill); the only other grounds
## are the controls' own: a chip, a choice, a field's value, a button. A
## cited chip and a chosen option are underlined in the action colour. Top
## to bottom:
##
## - the header line (where the instruction is in its flow);
## - the instruction when it has several lines, what was sent, `In view`
##   (the chips, `+`, the add-context menu, `Cites …`), or `Recent` with
##   nothing typed;
## - the three destinations in their fixed order, the launch or initiative
##   form, the stop message;
## - the send line (hint, `· N more`, the button), never with nothing typed.
##
## The body scrolls as the web's does: when it holds more than the screen
## leaves it, a quiet `More below ↓` ends it; an open schedule is scrolled
## into view (the web's `scrollOpenScheduleIntoView`), whole sections at a
## time.
##
## A destination row, at laptop width: the title (in capitals, the web's
## `text-transform`), what the destination is, the state word and the row's
## buttons two cells clear of it; the reason, and the delivery after a quiet
## `↳`, wrap under the label. A text the web keeps on one line (the label
## at laptop width, the cited list) wraps once here, a terminal line holding
## fewer characters than the web's, and is then cut by the views' one rule;
## a list breaks only after its commas. Below 30rem (the web's media query,
## `isNarrow`) the title and the state word share a line and the label (wrapped
## whole, as the web wraps it), the reason, the delivery and the buttons each
## take their own.
##
## A form's field is an input: its value is one line at every width, and a
## value wider than the field is cut in its middle (`elideMiddle`, study
## D35), keeping its start and as much of its end as fits, so a plan file's
## name stays whole. The omnibox field is cut at its end instead: the sheet
## shows the whole instruction where the field cannot (study D32).
##
## Presses and keys are not handled here: the composer's operations are the
## router's (Input-Routing-And-Keymaps.md §5.1). Each element a press would
## act on carries `action` and `target` facts, as the web's carries
## `data-ah-action` / `data-ah-target`.
##
## Facts (`AhNode`): `surface`, `phase`, `route`, `field`, `more-lines` and
## `header` on the view; `instruction`, `sent-text`, `sent-line`, `recent`,
## `chip` (with `chip-state`), `add-context`, `menu-item`, `cites`, `dest`
## (with `marked`, `unavailable`, `dest-title`, `label`, `state`, `detail`,
## `delivery`), `action`, `form`, `form-title`, `field-label`, `value`,
## `problem`, `toggle` (with `chosen`), `schedule`, `stopped`, `send`,
## `send-hint`, `send-more`, `more-below`.

import std/strutils
from std/unicode import runes, `$`
import nim_agents_isonim_viewmodels/agent_harbor/omnibox_composer_vm
import ../../viewmodel/views/agent_harbor_composer_words

import ./ah_tui_canvas

export omnibox_composer_vm, agent_harbor_composer_words, ah_tui_canvas

const
  TitleCells* = 13
    ## A destination's title column at laptop width: the longest title,
    ## `MANAGER AGENT` (the web's 7.25rem column holds it in a smaller type).
  FieldCells* = 48
    ## The omnibox field in the caption bar (the web's caption omnibox,
    ## about 380 px).
  SheetTop* = 2
    ## The sheet's first row: one row under the caption bar (the web's
    ## trigger gap).
  GapCells = 2
    ## Between a text and whatever follows it on its line (a state word, a
    ## button): `StatusWordGap`, so the two never read as one phrase.
  ControlGroundMinContrast = 1.3
    ## A control's ground against the sheet's (WCAG 2 contrast ratio,
    ## https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio): below it a chip or
    ## a button reads as loose text (the web outlines them).
  SheetCaptionContrast = 4.0
    ## The caption's contrast on the web's dropdown surface (Light 4.23:1):
    ## where the window's ground reaches it, the sheet takes that ground.
  CaptionMinContrast = 3.0
    ## The least a caption keeps against the ground under it; below it the
    ## label role takes its place (Light's tan sheet).

type
  Block = object
    ## A run of the body's rows, laid out before it is drawn so the body
    ## knows its height (the sheet is sized to its content, as the web's).
    rows: int
    schedule: bool   ## holds the open schedule's end
    band: bool       ## on the band (the context in view, the form)
    lead: bool       ## before the destinations (the context in view)
    spacer: bool     ## a blank row, nothing to scroll to
    draw: proc(c: var AhCanvas; row: int) {.closure.}

  Inks = object
    ## The grounds and inks the sheet draws with, chosen once against the
    ## sheet's ground (`inksFor`).
    window: string    ## the window under the caption bar, which the sheet covers
    sheet: string     ## the sheet: the dropped surface's ground
    band: string      ## the header and context, and the send line
    quiet: string     ## a chip in view, not cited
    removed: string   ## a chip the operator switched off
    cited: string     ## a cited chip, a chosen option: the action surface
    citedText: string ## the words on it
    control: string   ## a button's and a choice's own ground
    chosen: string    ## a chosen option
    field: string     ## a form field's value (the app's input field)
    menu: string      ## the add-context menu, on the band
    caption: string   ## a caption on the sheet
    bandCaption: string ## a caption on the band
    bandError: string ## the error role on the band
    controlText: string ## a quiet text on a control's ground

  Layout = object
    ## The sheet's inner columns, its inks, and where a press goes.
    left, width: int
    narrow: bool
    ink: Inks
    press: ComposerPress
    buttonsBelow: bool
      ## Every row's buttons on a line of their own under its label (right-
      ## aligned), when one row's label and buttons do not fit on its title
      ## line: the rows stay alike.

proc pressOf(press: ComposerPress; operation, target: string): proc() =
  ## A target's press: the operation and its target, handed to `press`. A
  ## proc of its own so each closure owns its pair.
  result = proc() =
    if press != nil: press(operation, target)

proc pressable(c: var AhCanvas; n: AhNode; press: ComposerPress; operation, target: string) =
  ## `n` carries `operation` on `target` (the terminal's `data-ct-operation`
  ## and `data-ah-target`), and a press over its cells reports both to
  ## `press`, which routes it (Input-Routing-And-Keymaps.md §5.1).
  n.tag("operation", operation)
  n.tag("target", target)
  c.target(n.row, n.col, max(1, n.width), max(1, n.height), pressOf(press, operation, target))

proc warningInk(p: AhPalette): string =
  ## Light's warning text role is a pale step meant for larger type; its
  ## hover step is the readable one (the web's `ah-role-warning`).
  if p.mode == dmDark: p.textWarning
  else: tokenHexOf(dtColorsUiTextWarningPrimaryHover, p.mode)

proc readable(p: AhPalette; ground: string): string =
  ## The caption role on `ground`, or the label role where the caption is
  ## too faint there.
  if contrastOf(p.textCaption, ground) >= CaptionMinContrast: p.textCaption
  else: p.textLabel

proc firstOff(ground: string; candidates: openArray[string];
              avoid: openArray[string] = []): string =
  ## The first candidate at least `ControlGroundMinContrast` off `ground`
  ## and not one of `avoid`; the last candidate when none is.
  for cand in candidates:
    if cand.len > 0 and cand notin avoid and
        contrastOf(cand, ground) >= ControlGroundMinContrast:
      return cand
  candidates[^1]

proc inksFor(c: AhCanvas): Inks =
  ## The sheet's grounds, from the design system's surface roles.
  ##
  ## The sheet is three areas, where the web draws two hairlines: a band
  ## with the header and the context in view (and the launch or initiative
  ## form, which the web also sets off with a line), the destinations
  ## between, on the sheet's own ground, and the send line on the band again
  ## (TUI §3.4: where the web draws a hairline, the terminal changes the
  ## ground). The window under the sheet is drawn a step back from it, a
  ## backdrop every one of its grounds is at least 1.3:1 off (the rule for
  ## any surface dropped from the caption bar): Light `secondary-hover`
  ## under the window's own ground and the panel; Dark `base/raised` under
  ## `tertiary-hover` and `secondary-hover`.
  ##
  ## On the band, a chip or an option is on a quiet ground at least 1.3:1
  ## off the band; a cited chip or a chosen option is on a darker step, bold
  ## and underlined in the action colour (never the action fill: the send
  ## button is the sheet's one); a field's value is the app's input ground.
  ## On the sheet, a button is on the controls' ground, 1.3:1 off it.
  let p = c.p
  if p.mode == dmLight:
    result.window = p.hover
    result.sheet = p.ground
    result.band = p.panel
    result.quiet = p.hover
    result.removed = ""
    # Cited and chosen: a step darker than a chip in view, bold and
    # underlined in the action colour; never the action fill (the send
    # button's).
    result.cited = p.tertiary
    result.citedText = p.textBody
    result.control = p.menu
    # The app's input ground, near the window's own; not the sheet's, which
    # a field on a band's last row would meet under it.
    result.field = tokenHexOf(dtColorsUiSurfaceBaseRaised, p.mode)
    # The add-context menu: 1.37:1 off the band it opens on (TUI §3.4's
    # rule for a dropped surface).
    result.menu = p.hover
  else:
    result.window = tokenHexOf(dtColorsUiSurfaceBaseRaised, p.mode)
    result.sheet = tokenHexOf(dtColorsUiSurfacePrimaryTertiaryHover, p.mode)
    result.band = p.hover
    result.quiet = p.ground
    result.removed = ""
    # Cited and chosen: the selection's tint over the band (the selected
    # initiative's ground), 1.31:1 off the band and 1.78:1 off a chip in
    # view; not the sheet's own, which an option on a band's last row would
    # meet.
    result.cited = blendOver(p.selectedTint, p.hover)
    result.citedText = p.textBody
    result.control = p.secondary
    result.field = p.ground
    result.menu = tokenHexOf(dtColorsUiSurfaceBaseRaised, p.mode)
  result.chosen = result.cited
  result.caption = readable(p, result.sheet)
  result.bandCaption = readable(p, result.band)
  # The error role where it reads on the band (4.5:1), else its stronger step.
  result.bandError = if contrastOf(p.textError, result.band) >= 4.5: p.textError
                     else: tokenHexOf(dtColorsUiTextErrorPrimaryHover, p.mode)
  result.controlText = readable(p, result.control)

proc roleInk(p: AhPalette; ink: Inks; role: string): string =
  case role
  of "error": p.textError
  of "warning": warningInk(p)
  of "body", "label": p.textBody
  else: ink.caption

proc prune(n: AhNode; start, clip: int; keep: openArray[AhNode]) =
  ## Drops every node under `n` that starts at or below `start` and does not
  ## end above `clip` (a section cut off at the body's foot), except `keep`.
  var children: seq[AhNode]
  for ch in n.children:
    if ch notin keep and ch.row >= start and ch.row + max(1, ch.height) > clip:
      continue
    ch.prune(start, clip, keep)
    children.add ch
  n.children = children

proc blank(): Block =
  Block(rows: 1, spacer: true, draw: proc(c: var AhCanvas; row: int) = discard)

proc contentAfter(blocks: seq[Block]; last: int): bool =
  ## Whether anything but blank rows follows block `last`: what "More
  ## below" announces.
  for i in last + 1 .. blocks.high:
    if not blocks[i].spacer: return true
  false

proc paraRows(s: string; cells: int): int =
  ## The rows `s` wraps to at `cells`, each of its own lines apart.
  for part in s.splitLines:
    result += max(1, wrapCells(part, max(1, cells)).len)

proc drawPara(c: var AhCanvas; parent: AhNode; row, col, cells: int; s, fg, fact: string;
              bold = false): int =
  ## `s` wrapped (its own lines kept), one node over it with the full text.
  var r = row
  var widest = 0
  for part in s.splitLines:
    if part.len == 0:
      inc r
      continue
    for line in wrapCells(part, max(1, cells)): widest = max(widest, widthOf(line))
    r += c.para(nil, r, col, cells, part, fg, bold = bold)
  if fact.len > 0:
    # Over the lines' own cells: a one-line text's node ends where it does.
    discard c.node(parent, row, col, min(cells, widest), r - row, [(fact, s)])
  r - row

const DeliveryLead = "\xE2\x86\xB3 "
  ## `↳`: what a delivery added, under the label it answers.

const MaxLines = 2
  ## The most lines a text the web keeps on one line takes here (a
  ## destination's label at laptop width, the cited list): the terminal's
  ## line holds fewer words than the web's, so it wraps once, then cuts.

proc capLines(lines: seq[string]; full: string; cells: int): seq[string] =
  ## `lines`, at most `MaxLines` of them, the last ending in "…" when any
  ## were dropped: what is left of `full` after the kept lines, cut.
  if lines.len <= MaxLines: return lines
  result = lines[0 ..< MaxLines - 1]
  var used = 0
  for l in result: used += l.len
  # The kept lines' words are a prefix of `full`, less the spaces the wrap
  # dropped between them: find where the last kept line ends.
  var at = 0
  for l in result:
    let k = full.find(l, at)
    at = if k >= 0: k + l.len else: at + l.len
  let rest = full[min(full.len, at) .. ^1].strip(trailing = false)
  result.add elide(rest, cells)

proc wrappedLines(s: string; cells: int): seq[string] =
  ## `s` wrapped to `cells`, at most `MaxLines` lines.
  capLines(wrapCells(s, max(1, cells)), s, cells)

proc listLines(s: string; cells: int): seq[string] =
  ## A list (`a, b, c`) in lines of `cells`, broken only after a ", "; a
  ## part wider than a line is wrapped by itself. At most `MaxLines`.
  var line = ""
  var all: seq[string]
  for part in s.split(", "):
    let piece = if line.len == 0: part else: ", " & part
    if line.len > 0 and widthOf(line & piece) > cells:
      all.add line & ","
      line = part
    else:
      line.add piece
    while widthOf(line) > cells:
      let w = wrapCells(line, cells)
      all.add w[0]
      line = line[w[0].len .. ^1].strip(trailing = false)
  if line.len > 0: all.add line
  capLines(all, s, cells)

proc drawLines(c: var AhCanvas; parent: AhNode; row, col, cells: int;
               lines: seq[string]; full, fg, fact: string; bold = false) =
  ## Lines already broken, one node over them with the full text.
  var widest = 0
  for i, l in lines:
    discard c.put(row + i, col, l, fg, bold)
    widest = max(widest, widthOf(l))
  if fact.len > 0:
    discard c.node(parent, row, col, min(cells, widest), lines.len, [(fact, full)])

proc putMarked(c: var AhCanvas; row, col: int; s, fg, bg, mark: string; bold = false) =
  ## `s` underlined in `mark`'s own colour (SGR 58), the terminal's mark of
  ## a chosen control: the focused initiative's underline (TUI §3.4).
  var at = col
  for r in s.runes:
    if at >= c.cols: break
    c.grid.paint(row, at, $r, CellStyle(fg: fg, bg: bg, bold: bold, underline: true,
                                         underlineColor: mark))
    at += max(1, cellsOfRune(r, awNarrow))

proc chipLines(label: string; cells: int): seq[string] =
  ## A chip's label in lines of at most `cells - 2` cells: whole on one line
  ## when it fits; else wrapped, after its last ` · ` where that is enough
  ## (the gaze chip's time on a line of its own), its lines on one ground,
  ## never cut (the web shows a chip whole).
  let room = max(1, cells - 2)
  if widthOf(label) <= room: return @[label]
  let k = label.rfind(" \xC2\xB7 ")
  if k > 0 and widthOf(label[0 .. k + 2]) <= room and widthOf(label[k + 4 .. ^1]) <= room:
    return @[label[0 .. k + 2], label[k + 4 .. ^1]]
  wrapCells(label, room)

type ChipStyle = object
  fg, bg, mark: string
  lead: string   ## a mark's colour for the inset bar in the cell before the chip
  bold, italic: bool

proc drawChipLines(c: var AhCanvas; row, col, cells: int; lines: seq[string];
                   st: ChipStyle): int =
  ## A chip's lines, each ` line ` on the chip's ground (padded to the
  ## widest); returns its width.
  var w = 0
  for l in lines: w = max(w, widthOf(l) + 2)
  w = min(w, cells)
  for i, l in lines:
    if st.bg.len > 0:
      discard c.put(row + i, col, repeat(' ', w), st.fg, bg = st.bg)
    if st.lead.len > 0 and col > 0:
      # The inset bar the selected row carries, in the cell before the chip,
      # on the ground around it, where it shows in both themes.
      discard c.put(row + i, col - 1, BarGlyph, st.lead)
    if st.mark.len > 0:
      c.putMarked(row + i, col + 1, l, st.fg, (if st.bg.len > 0: st.bg
                                               else: c.bgAt(row, col)), st.mark, st.bold)
    else:
      var at = col + 1
      for r in l.runes:
        let ground = if st.bg.len > 0: st.bg else: c.bgAt(row + i, at)
        c.grid.paint(row + i, at, $r, CellStyle(fg: st.fg, bg: ground, bold: st.bold,
                                                 italic: st.italic))
        at += max(1, cellsOfRune(r, awNarrow))
  w

type Flow = object
  ## Chips laid out in lines, a blank row between lines (so two chips one
  ## above the other never share a ground edge to edge): where each goes.
  rows: int
  places: seq[(int, int)]   ## (row offset, column) of each item

proc flow(widths: openArray[int]; heights: openArray[int]; first, cells: int;
          gap = 1): Flow =
  ## `widths[i]` cells × `heights[i]` rows each, one cell apart and `gap`
  ## blank rows between lines; an item of several rows (a wrapped chip)
  ## takes a line of its own, its rows together on one ground.
  var top = 0
  var at = first
  var lineH = 1
  for i, w in widths:
    let h = heights[i]
    if at > 0 and (h > 1 or at + 1 + w > cells):
      top += lineH + gap
      at = 0
      lineH = 1
    elif at > 0: inc at
    result.places.add (top, at)
    at += w
    lineH = max(lineH, h)
    if h > 1:
      top += lineH + gap
      at = 0
      lineH = 1
  result.rows = max(1, if at > 0: top + lineH else: top - gap)

# ---------------------------------------------------------------------------
# The body's sections
# ---------------------------------------------------------------------------

proc recentRowBlock(host: AhNode; lay: Layout; index: int; r: RecentRow): Block =
  ## One recent instruction: its first line, and where it went under it. A
  ## proc of its own so each closure owns its row (a closure made in a loop
  ## shares the loop's variables).
  Block(rows: 2, draw: proc(c: var AhCanvas; row: int) =
    let n = c.node(host, row, lay.left, lay.width, 2,
                   [("recent", $index), ("action", "recall")])
    c.pressable(n, lay.press, ComposerRecallOperation, $index)
    discard c.text(n, row, lay.left, lay.width, r.text, c.p.textBody, fact = "recent-text")
    discard c.text(n, row + 1, lay.left, lay.width, r.line,
                   if r.failed: c.p.textError else: lay.ink.caption, fact = "recent-line"))

proc recentBlocks(vm: OmniboxComposerVM; host: AhNode; lay: Layout): seq[Block] =
  let recent = vm.recent
  if recent.len == 0: return
  result.add Block(rows: 1, draw: proc(c: var AhCanvas; row: int) =
    discard c.text(host, row, lay.left, lay.width, RecentLabel.toUpperAscii, c.p.textLabel,
                   fact = "section"))
  result.add blank()
  for i, rec in recent:
    result.add recentRowBlock(host, lay, i, rec)
    if i < recent.high: result.add blank()

proc chipStyle(c: AhCanvas; ink: Inks; state: string): ChipStyle =
  ## Cited: the cited ground, the body text bold and underlined in the
  ## action colour (SGR 58, the focused initiative's mark: TUI §3.4), as the
  ## web outlines a cited chip in that colour. Offered: the chip ground, the
  ## label role. Uncited (switched off by the operator): no ground, the
  ## disabled role in italics, as removed (the cell style has no
  ## strike-through). A note: no ground, a quiet italic after a dotted ring.
  case state
  of "cited": ChipStyle(fg: ink.citedText, bg: ink.cited, mark: c.p.borderAction, bold: true)
  of "uncited":
    let fg = if contrastOf(c.p.textDisabled, ink.band) >= CaptionMinContrast: c.p.textDisabled
             else: ink.bandCaption
    ChipStyle(fg: fg, italic: true)
  of "note": ChipStyle(fg: ink.bandCaption, italic: true)
  else: ChipStyle(fg: c.p.textLabel, bg: ink.quiet)

proc contextBlocks(vm: OmniboxComposerVM; host: AhNode; lay: Layout): seq[Block] =
  let chips = vm.chips
  let composing = vm.phase == cpComposing
  let addOpen = vm.addContextOpen.val
  let label = InViewLabel.toUpperAscii
  let lead = widthOf(label) + 1
  let width = lay.width
  var lines: seq[seq[string]]
  var widths, heights: seq[int]
  for ch in chips:
    # A note (`Gaze paused`) is never cited: a dotted ring before it says so,
    # as the web's dashed outline does.
    let l = chipLines((if ch.item.note: "\xE2\x97\x8C " else: "") & ch.item.label, width)
    lines.add l
    var w = 0
    for s in l: w = max(w, widthOf(s) + 2)
    widths.add min(w, width)
    heights.add l.len
  if chips.len == 0:
    widths.add widthOf(NothingInView)
    heights.add 1
  if composing:
    widths.add 3
    heights.add 1
  let placed = flow(widths, heights, lead, width)
  result.add Block(rows: placed.rows, draw: proc(c: var AhCanvas; row: int) =
    let ink = lay.ink
    discard c.text(host, row, lay.left, width, label, c.p.textLabel, fact = "section")
    var k = 0
    if chips.len == 0:
      let (ln, at) = placed.places[k]
      discard c.text(host, row + ln, lay.left + at, width - at, NothingInView,
                     ink.bandCaption, fact = "chip-none")
      inc k
    for i, ch in chips:
      let (ln, at) = placed.places[k]
      inc k
      let state = chipState(ch)
      let r = row + ln
      let w = c.drawChipLines(r, lay.left + at, width - at, lines[i], c.chipStyle(ink, state))
      let chip = c.node(host, r, lay.left + at, w, lines[i].len,
                        [("chip", ch.item.id), ("chip-state", state),
                         ("chip-label", ch.item.label), ("action", "cite")])
      c.pressable(chip, lay.press, ComposerCiteOperation, ch.item.id)
    if composing:
      let (ln, at) = placed.places[k]
      let r = row + ln
      discard c.drawChipLines(r, lay.left + at, 3, @["+"],
        ChipStyle(fg: (if addOpen: ink.citedText else: c.p.textBody),
                  bg: (if addOpen: ink.cited else: ink.quiet)))
      let add = c.node(host, r, lay.left + at, 3, 1,
                       [("add-context", $addOpen), ("action", "add-context")])
      c.pressable(add, lay.press, ComposerAddContextOperation, ""))
  if addOpen:
    var menuW = 0
    for item in AddContextItems: menuW = max(menuW, widthOf(item) + 2)
    menuW = min(width, max(24, menuW))
    let items = AddContextItems.len
    result.add blank()
    result.add Block(rows: items, draw: proc(c: var AhCanvas; row: int) =
      # The menu opens in place under the chips, a row below them, on the
      # band's ground: a step off the sheet's and the chips'.
      let ink = lay.ink
      let menu = c.node(host, row, lay.left, menuW, items, [("context-menu", "add-context")])
      for i, item in AddContextItems:
        discard c.put(row + i, lay.left, repeat(' ', menuW), c.p.textBody, bg = ink.menu)
        discard c.text(menu, row + i, lay.left + 1, menuW - 2, item, c.p.textBody,
                       bg = ink.menu, fact = "context-item"))
  let cites = vm.citesShown
  if cites.len > 0:
    result.add blank()
    # A list: broken only after its ", " separators, so no cited name is
    # split; at most `MaxLines` lines, the last cut by the one rule.
    let lines = listLines(cites, width)
    result.add Block(rows: lines.len, draw: proc(c: var AhCanvas; row: int) =
      c.drawLines(host, row, lay.left, width, lines, cites, lay.ink.bandCaption, "cites"))

proc actionLabels(vm: OmniboxComposerVM; row: DestinationRow): seq[(string, string)] =
  ## The row's actions: what each says and the action it names.
  if row.canStop:
    result.add ((if vm.stopState.val == ssStopping: "Stopping\xE2\x80\xA6" else: "Stop agent"),
                "stop")
  if row.canSendAgain: result.add (sendAgainLabel(row), "send-again")
  if row.delivered and row.delivery == dsFailed: result.add ("Retry", "retry")

proc actionsCells(actions: seq[(string, string)]): int =
  for i, (label, _) in actions:
    result += widthOf(label) + 2 + (if i > 0: 1 else: 0)

proc drawActions(c: var AhCanvas; ink: Inks; press: ComposerPress; parent: AhNode; row, col: int;
                 actions: seq[(string, string)]; target: TargetKind) =
  ## The row's buttons on the controls' ground, a cell apart; Stop in the
  ## error role.
  var at = col
  for (label, action) in actions:
    # Stop in the error role: its words on the controls' ground where they
    # read there (4.5:1), else the button filled in the error colour.
    let strongError = tokenHexOf(dtColorsUiTextErrorPrimaryHover, c.p.mode)
    let stopInk = if contrastOf(c.p.textError, ink.control) >= 4.5 or
                     contrastOf(strongError, ink.control) <= contrastOf(c.p.textError, ink.control):
                    c.p.textError
                  else: strongError
    let st = if action != "stop": ChipStyle(fg: c.p.textBody, bg: ink.control)
             else: ChipStyle(fg: stopInk, bg: ink.control)
    let w = c.drawChipLines(row, at, widthOf(label) + 2, @[label], st)
    let b = c.node(parent, row, at, w, 1, [("action", action), ("button", label)])
    c.pressable(b, press, operationOfAction(action), $target)
    at += w + 1

proc rowBlock(vm: OmniboxComposerVM; host: AhNode; lay: Layout;
              row: DestinationRow; sheetCol: int): Block =
  ## One destination. Laptop: the title column, the label wrapped beside
  ## it (never cut: the web shows it whole where it has room), the state
  ## word and the buttons at the line's end two cells clear of it, the
  ## reason and the delivery under the label. Narrow: the title and the
  ## state word, then the label, the reason, the delivery, the buttons.
  let marked = vm.rowMarked(row)
  let unavailable = vm.rowUnavailable(row)
  let label = vm.rowLabel(row)
  let reason = vm.rowReason(row)
  let word = stateWord(row)
  let wordRole = stateRole(row)
  let delivery = deliveryText(row)
  let dRole = deliveryRole(row)
  let actions = actionLabels(vm, row)
  let title = row.title.toUpperAscii
  let left = lay.left
  let width = lay.width
  let narrow = lay.narrow
  # Two cells between the title column and the label (StatusWordGap).
  let textCol = if narrow: left else: left + TitleCells + GapCells
  let textCells = if narrow: width else: width - TitleCells - GapCells
  let wordW = widthOf(word)
  # The buttons stay right-aligned on the title line at laptop width while
  # every row's label keeps its two cells before them (`buttonsBelow`);
  # else every row's take a line of their own under the label, still
  # right-aligned. At sidebar width they go under the label, as the web
  # re-flows them.
  let actFull = actionsCells(actions)
  let actionsBelow = actions.len > 0 and (narrow or lay.buttonsBelow)
  let actW = if actionsBelow: 0 else: actFull
  # The first line's end: the state word, then the buttons.
  var rightStart = left + width
  if actW > 0: rightStart -= actW
  if wordW > 0: rightStart -= wordW + (if actW > 0: GapCells else: 0)
  let labelGap = GapCells
  let labelCells = if narrow: width
                   elif wordW > 0 or actW > 0: max(8, rightStart - labelGap - textCol)
                   else: textCells
  # The label: wrapped whole when narrow (as the web wraps it there), and at
  # laptop width wrapped once and then cut (the web keeps it on one line).
  let labelLines = if narrow: wrapCells(label, max(1, labelCells))
                   else: wrappedLines(label, labelCells)
  let labelRows = max(1, labelLines.len)
  # A delivery's result reads apart from the label above it: a quiet `↳`
  # leads it, its words wrapped beside it.
  let deliveryCells = max(1, textCells - widthOf(DeliveryLead))
  var rows = labelRows
  if narrow: inc rows                 # the title line
  if reason.len > 0: rows += paraRows(reason, textCells)
  if delivery.len > 0: rows += paraRows(delivery, deliveryCells)
  if actionsBelow: rows += (if narrow: 2 else: 1)
  result = Block(rows: rows, draw: proc(c: var AhCanvas; row0: int) =
    let ink = lay.ink
    let n = c.node(host, row0, sheetCol, width + 2 * (left - sheetCol), rows,
                   [("dest", $row.target), ("marked", $marked),
                    ("unavailable", $unavailable)])
    if marked:
      # The inset bar down the row's first cell, in the action border role.
      for r in row0 ..< row0 + rows:
        discard c.put(r, sheetCol, BarGlyph, c.p.borderAction)
    let titleInk = if unavailable: c.p.textDisabled else: c.p.textLabel
    # Why a destination cannot be reached is said in the caption role, a
    # quiet italic: the disabled role is too faint on the sheet to read.
    let labelInk = if unavailable: ink.caption else: c.p.textBody
    let wordInk = case wordRole
                  of "quiet": ink.caption
                  of "error": c.p.textError
                  else: c.p.textBody
    discard c.text(n, row0, left, (if narrow: rightStart - GapCells - left else: TitleCells),
                   title, titleInk, fact = "dest-title")
    if wordW > 0:
      discard c.text(n, row0, rightStart, wordW, word, wordInk,
                     fact = "state")
    if actW > 0:
      c.drawActions(ink, lay.press, n, row0, left + width - actW, actions, row.target)
    var r = row0 + (if narrow: 1 else: 0)
    for i, l in labelLines:
      if unavailable:
        var at = textCol
        for ru in l.runes:
          c.grid.paint(r + i, at, $ru, CellStyle(fg: labelInk, bg: c.bgAt(r + i, at),
                                                  italic: true))
          at += max(1, cellsOfRune(ru, awNarrow))
      else:
        discard c.put(r + i, textCol, l, labelInk)
    var widest = 0
    for l in labelLines: widest = max(widest, widthOf(l))
    discard c.node(n, r, textCol, widest, labelRows, [("label", label)])
    r += labelRows
    if reason.len > 0:
      r += c.drawPara(n, r, textCol, textCells, reason, ink.caption, "detail")
    if delivery.len > 0:
      discard c.put(r, textCol, DeliveryLead, ink.caption)
      r += c.drawPara(n, r, textCol + widthOf(DeliveryLead), deliveryCells, delivery,
                      roleInk(c.p, ink, dRole), "delivery")
    if actionsBelow:
      c.drawActions(ink, lay.press, n, r + (if narrow: 1 else: 0),
                    (if narrow: left else: left + width - actFull), actions, row.target))

proc fieldBlock(host: AhNode; lay: Layout; col, cells: int; label, value, problem: string;
                placeholder = ""): Block =
  ## One field: its label over its value on the window's ground (the app's
  ## input field), and its problem under it. The value is one line at every
  ## width, as an input's: what does not fit is cut in its middle
  ## (`elideMiddle`, study D35), so a path keeps its file name.
  let rows = 2 + (if problem.len > 0: paraRows(problem, cells) else: 0)
  Block(rows: rows, draw: proc(c: var AhCanvas; row: int) =
    let n = c.node(host, row, col, cells, rows, [("field-label", label)])
    discard c.text(n, row, col, cells, label, c.p.textLabel, fact = "field-name")
    let ground = lay.ink.field
    discard c.put(row + 1, col, repeat(' ', cells), c.p.textBody, bg = ground)
    let room = max(1, cells - 2)
    if value.len > 0:
      discard c.put(row + 1, col + 1, elideMiddle(value, room), c.p.textBody, bg = ground)
      discard c.node(n, row + 1, col + 1, room, 1, [("value", value)])
    else:
      # The placeholder is a hint, not a value: cut at its end like any text.
      discard c.text(n, row + 1, col + 1, room, placeholder, readable(c.p, ground),
                     bg = ground, fact = "value")
    if problem.len > 0:
      # The field the problem is about carries the error role's inset bar,
      # as the web outlines it in that role.
      discard c.put(row + 1, col, BarGlyph, lay.ink.bandError, bg = ground)
      discard c.drawPara(n, row + 2, col, cells, problem, lay.ink.bandError,
                         "problem"))

proc choiceBlock(host: AhNode; lay: Layout; col, cells: int; label: string;
                 options: seq[string]; chosen: seq[string]; problem = "";
                 several = false): Block =
  ## A choice among a few options: its label over a row of choices on the
  ## controls' ground, each chosen one on the chosen ground, underlined in
  ## the action colour (`✓` before it when several may be).
  var shown: seq[string]
  var widths, heights: seq[int]
  for o in options:
    let s = if several and o in chosen: "\xE2\x9C\x93 " & o else: o
    shown.add s
    widths.add widthOf(s) + 2
    heights.add 1
  # The rows of one choice stay together, no blank row between them: a
  # wrapped option belongs to its field, not to the next (each option is on
  # a ground of its own, so two rows of them do not run together).
  let placed = flow(widths, heights, 0, cells, gap = 0)
  let rows = 1 + placed.rows + (if problem.len > 0: paraRows(problem, cells) else: 0)
  Block(rows: rows, draw: proc(c: var AhCanvas; row: int) =
    let ink = lay.ink
    let n = c.node(host, row, col, cells, rows, [("field-label", label)])
    discard c.text(n, row, col, cells, label, c.p.textLabel, fact = "field-name")
    for i, o in options:
      let (ln, at) = placed.places[i]
      let r = row + 1 + ln
      let on = o in chosen
      let st = if on: ChipStyle(fg: ink.citedText, bg: ink.cited, mark: c.p.borderAction,
                                bold: true)
               else: ChipStyle(fg: c.p.textLabel, bg: ink.quiet)
      let drawn = c.drawChipLines(r, col + at, cells - at, @[shown[i]], st)
      discard c.node(n, r, col + at, drawn, 1,
                     [("toggle", o), ("chosen", $on), ("action", "choose-option")])
    if problem.len > 0:
      discard c.drawPara(n, row + 1 + placed.rows, col, cells, problem, lay.ink.bandError,
                         "problem"))

proc pairBlock(a, b: Block): Block =
  ## Two fields side by side (a proc of its own: see `recentRowBlock`).
  Block(rows: max(a.rows, b.rows), draw: proc(c: var AhCanvas; row: int) =
    a.draw(c, row)
    b.draw(c, row))

proc gridBlocks(fields: seq[(Block, bool)]; narrow: bool): seq[Block] =
  ## Fields two to a line at laptop width (a wide one alone), one per line
  ## when narrow; a blank row between lines. The blocks were laid out for
  ## the column they are drawn in.
  var i = 0
  while i < fields.len:
    let (a, wide) = fields[i]
    if narrow or wide or i + 1 >= fields.len or fields[i + 1][1]:
      result.add a
      inc i
    else:
      result.add pairBlock(a, fields[i + 1][0])
      i += 2
    if i < fields.len: result.add blank()

proc formBlocks(vm: OmniboxComposerVM; host: AhNode; lay: Layout): seq[Block] =
  let left = lay.left
  let width = lay.width
  let narrow = lay.narrow
  let title = vm.formTitle
  let intent = vm.intent
  let form = AhNode(row: 0, col: left, width: width, height: 0,
                    facts: @[("form", $intent)])
  host.children.add form
  result.add Block(rows: paraRows(title, width), draw: proc(c: var AhCanvas; row: int) =
    form.row = row
    discard c.drawPara(form, row, left, width, title, lay.ink.bandCaption, "form-title"))
  if not vm.optionsOpen.val: return
  result.add blank()
  let colW = if narrow: width else: (width - 2) div 2
  let col2 = if narrow: left else: left + colW + 2
  let problems = vm.problems
  var fields: seq[(Block, bool)]
  if intent == riLaunchTask:
    let o = vm.launch
    fields.add (fieldBlock(form, lay, left, colW, "Repository", o.repository,
      problemOf(problems, "repository"), "Choose a repository"), false)
    fields.add (fieldBlock(form, lay, col2, colW, "Branch", o.branch, "", "default branch"),
                false)
    fields.add (choiceBlock(form, lay, left, width, "Agents", vm.agentChoices, o.agents,
      problemOf(problems, "agents"), several = true), true)
    var runOn: seq[string]
    for v in RunOn: runOn.add $v
    fields.add (choiceBlock(form, lay, left, width, "Runs on", runOn, @[$o.runOn]), true)
    if o.runOn == roExecutor:
      fields.add (fieldBlock(form, lay, left, colW, "Executor", o.executor,
        problemOf(problems, "executor"), "Choose an executor"), false)
      fields.add (fieldBlock(form, lay, col2, colW, "Session name", o.sessionName, "",
        "named by the server"), false)
    else:
      fields.add (fieldBlock(form, lay, left, colW, "Session name", o.sessionName, "",
        "named by the server"), true)
    var openIn: seq[string]
    for v in OpenIn: openIn.add $v
    fields.add (choiceBlock(form, lay, left, width, "Opens in", openIn, @[$o.openIn]), true)
    result.add gridBlocks(fields, narrow)
    result.add blank()
    # The schedule: its head line, and its fields when open.
    let open = vm.scheduleOpen.val
    let (summary, problem) = vm.scheduleSummary
    result.add Block(rows: 1, schedule: not open, draw: proc(c: var AhCanvas; row: int) =
      let n = c.node(form, row, left, width, 1,
                     [("schedule", $open), ("action", "schedule")])
      discard c.put(row, left, if open: UnfoldedGlyph else: FoldedGlyph,
                    tokenHexOf(dtColorsUiIconPrimaryDefault, c.p.mode))
      discard c.text(n, row, left + 2, width - 2, ScheduleLabel, c.p.textLabel,
                     fact = "field-name")
      let at = left + 2 + widthOf(ScheduleLabel) + GapCells
      discard c.text(n, row, at, max(1, left + width - at), summary,
                     if problem: lay.ink.bandError else: lay.ink.bandCaption,
                     fact = "schedule-summary"))
    if open:
      let s = o.schedule
      var sched: seq[(Block, bool)]
      sched.add (fieldBlock(form, lay, left, colW, "Cron", s.cron,
        problemOf(problems, "cron"), "minute hour day month weekday"), false)
      sched.add (fieldBlock(form, lay, col2, colW, "Time zone", s.timezone,
        problemOf(problems, "timezone"), "UTC"), false)
      sched.add (fieldBlock(form, lay, left, colW, "Jitter", $s.jitterSeconds & " s",
        problemOf(problems, "jitter")), true)
      var conc, mis: seq[string]
      for v in Concurrency: conc.add $v
      for v in Misfire: mis.add $v
      sched.add (choiceBlock(form, lay, left, width, "Concurrency", conc, @[$s.concurrency]),
                 true)
      sched.add (choiceBlock(form, lay, left, width, "Misfire", mis, @[$s.misfire]), true)
      result.add blank()
      var g = gridBlocks(sched, narrow)
      g[^1].schedule = true
      result.add g
  else:
    let f = vm.initiative
    fields.add (fieldBlock(form, lay, left, width, "Goal", f.goal, problemOf(problems, "goal"),
      "What the initiative is for"), true)
    var modes: seq[string]
    for v in IterationMode: modes.add $v
    fields.add (choiceBlock(form, lay, left, width, "Iterations", modes, @[$f.iteration]), true)
    if f.iteration == imCount:
      fields.add (fieldBlock(form, lay, left, width, "Number of iterations", $f.iterations,
        problemOf(problems, "iterations")), true)
    fields.add (fieldBlock(form, lay, left, width, "Plan file", vm.planPreview,
      problemOf(problems, "plan")), true)
    fields.add (fieldBlock(form, lay, left, width, "Related specs", f.relatedSpecs.join(", "),
      "", "none"), true)
    result.add gridBlocks(fields, narrow)

proc bodyBlocks(vm: OmniboxComposerVM; host: AhNode; lay: Layout;
                sheetCol: int): seq[Block] =
  let left = lay.left
  let width = lay.width
  let whole = vm.instructionBlock
  if whole.len > 0 and vm.phase == cpComposing:
    result.add Block(rows: paraRows(whole, width), draw: proc(c: var AhCanvas; row: int) =
      discard c.drawPara(host, row, left, width, whole, c.p.textBody, "instruction"))
    result.add blank()
  if vm.phase in {cpSent, cpSendFailed} or
      vm.phase == cpSending and vm.draft.deliveries.len > 1:
    let sent = vm.sentLine
    if sent.len > 0:
      let sentText = vm.draft.sentText
      result.add Block(rows: paraRows(sentText, width) + paraRows(sent, width),
        draw: proc(c: var AhCanvas; row: int) =
          let r = c.drawPara(host, row, left, width, sentText, c.p.textBody, "sent-text")
          discard c.drawPara(host, row + r, left, width, sent, lay.ink.bandCaption, "sent-line"))
      result.add blank()
  if vm.isEmptyField:
    for b in result.mitems:
      b.band = true
      b.lead = true
    result.add blank()
    result.add recentBlocks(vm, host, lay)
    return
  result.add contextBlocks(vm, host, lay)
  # The header, the instruction and the context in view are one band; the
  # destinations start on the sheet under it, a row below its end.
  for b in result.mitems:
    b.band = true
    b.lead = true
  var pad = blank()
  pad.band = true
  pad.lead = true
  result.add pad
  result.add blank()
  let rows = vm.rows
  for i, row in rows:
    result.add rowBlock(vm, host, lay, row, sheetCol)
    if i < rows.high: result.add blank()
  if vm.showsForm:
    # The form: a band of its own under the destinations, as the web sets
    # it off with a line; a row of the band above and below its fields.
    result.add blank()
    var form = @[blank()] & formBlocks(vm, host, lay) & @[blank()]
    for b in form.mitems: b.band = true
    result.add form
  let stopMessage = vm.stopMessage.val
  if stopMessage.len > 0:
    let failed = vm.stopState.val == ssFailed
    result.add blank()
    result.add Block(rows: paraRows(stopMessage, width), draw: proc(c: var AhCanvas; row: int) =
      discard c.drawPara(host, row, left, width, stopMessage,
                         if failed: c.p.textError else: lay.ink.caption, "stopped"))

# ---------------------------------------------------------------------------
# The composer
# ---------------------------------------------------------------------------

proc showsSendFooter(vm: OmniboxComposerVM): bool =
  ## The send line, as the web draws it: while composing or waiting to send,
  ## and never with nothing typed (`Recent` instead).
  vm.showsSendLine and not vm.isEmptyField

proc drawSendLine(c: var AhCanvas; ink: Inks; press: ComposerPress; vm: OmniboxComposerVM;
                  host: AhNode;
                  row, left, width: int) =
  ## The hint (the reason it cannot send, in the error role), the count of
  ## further problems (never cut), and the button at the end, on the band.
  let sending = vm.phase == cpSending
  let canSend = vm.canSend and not sending
  let (hint, more, blocked) = vm.sendHint
  let label = vm.sendLabel
  let button = " " & label & " "
  let bw = widthOf(button)
  let bcol = left + width - bw
  let send = c.node(host, row, left, width, 1,
                    [("send", label), ("send-enabled", $canSend), ("send-blocked", $blocked)])
  let moreW = widthOf(more)
  let hintRoom = max(1, bcol - GapCells - moreW - left)
  let hintW = min(widthOf(hint), hintRoom)
  let hintCol = bcol - GapCells - moreW - hintW
  let quiet = ink.bandCaption
  discard c.text(send, row, hintCol, hintW, hint,
                 if blocked: ink.bandError else: quiet, fact = "send-hint")
  if moreW > 0:
    discard c.text(send, row, bcol - GapCells - moreW, moreW, more, quiet,
                   fact = "send-more")
  # The primary button: the action ground; Light takes the body text on it
  # (the web's `by-mode(on-action, body)`); disabled, the disabled role on
  # the controls' ground.
  let (fg, bg) = if canSend:
                   ((if c.p.mode == dmDark: c.p.onAction else: c.p.textBody), c.p.action)
                 else: (c.p.textDisabled, ink.quiet)
  discard c.put(row, bcol, button, fg, bg = bg)
  let b = c.node(send, row, bcol, bw, 1, [("action", "send"), ("button", label)])
  c.pressable(b, press, ComposerSendOperation, "")

proc drawComposer*(c: var AhCanvas; vm: OmniboxComposerVM; row, col, width, height: int;
                   press: ComposerPress = nil) =
  ## The caption bar with the omnibox field at (`row`, `col`), and the
  ## sheet dropped under it, in `width` × `height` cells.
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-composer"), ("phase", $vm.phase),
                     ("route", $vm.route)])
  let ink = inksFor(c)
  # The caption bar, and the window under it the sheet drops over.
  c.area("caption", row, col, width, 1, c.tone.frame)
  c.area("window", row + 1, col, width, height - 1, ink.window)
  let field = ComposerPrefix & vm.fieldText
  let more = vm.moreLines
  let moreW = if more.len > 0: widthOf(more) + GapCells else: 0
  # The caption omnibox's width, centred: what does not fit is cut. With
  # `+N lines` beside it, the field takes the room its first line and the
  # count need, so the first line still shows whole where the window has it.
  let fieldW = if more.len == 0: min(width - 2, FieldCells)
               else: min(width - 2, max(FieldCells, widthOf(field) + 2 + moreW))
  let fieldCol = col + (width - fieldW) div 2
  # The field is an area of its own: a ground off both the caption bar's
  # and the window's under it.
  var fieldGround = c.tone.head
  for cand in [c.tone.head, c.p.hover, c.p.tertiary, c.p.panel, c.p.menu]:
    if cand != c.tone.frame and cand != ink.window:
      fieldGround = cand
      break
  c.area("field", row, fieldCol, fieldW, 1, fieldGround)
  # What does not fit is cut by the views' one rule: the web's input
  # scrolls instead (P2c D32), a drawn line cannot, and a cut with no "…"
  # would read as the whole instruction.
  let fieldRoom = max(1, fieldW - 2 - moreW)
  let fieldShown = elide(field, fieldRoom)
  discard c.put(row, fieldCol + 1, fieldShown, c.p.textBody)
  discard c.node(host, row, fieldCol, fieldW, 1, [("field", field)])
  if more.len > 0:
    discard c.text(host, row, fieldCol + fieldW - 1 - widthOf(more), widthOf(more), more,
                   readable(c.p, fieldGround), fact = "more-lines")
  # The sheet's columns: `sheetWidthFor` at 8 px a cell, centred.
  let sheetW = min(width, max(10, vm.sheetWidthFor(width * CellPx) div CellPx))
  let sheetCol = col + (width - sheetW) div 2
  let narrow = vm.isNarrow(width * CellPx)
  # One cell of the sheet each side of its content (the web's 0.75rem is a
  # cell and a half): a row's title, label and buttons need the room.
  let pad = 1
  var lay = Layout(left: sheetCol + pad, width: sheetW - 2 * pad, narrow: narrow,
                   ink: ink, press: press)
  let header = vm.headerText
  let headerInk = case vm.headerRole
                  of "error": ink.bandError
                  of "body", "label": c.p.textBody
                  else: ink.bandCaption
  let headerRows = paraRows(header, lay.width)
  if not narrow:
    let textCells = lay.width - TitleCells - GapCells
    for row in vm.rows:
      let actions = actionLabels(vm, row)
      if actions.len == 0: continue
      let word = stateWord(row)
      if widthOf(vm.rowLabel(row)) + GapCells + actionsCells(actions) +
         (if word.len > 0: widthOf(word) + GapCells else: 0) > textCells:
        lay.buttonsBelow = true
  let blocks = bodyBlocks(vm, host, lay, sheetCol)
  var total = 0
  for b in blocks: total += b.rows
  # The send line: a band of its own where the palette has a ground a
  # visible step off both the sheet's and the window's (TUI §3.4: a change
  # of ground where the web draws a line); on the sheet, a row below the
  # body, where it has none.
  let footer = if vm.showsSendFooter: 3 else: 0
  let top = row + SheetTop
  let maxH = row + height - 1 - top
  let topRows = 1 + headerRows + 1          # a blank row, the header, a blank row
  let bodyRoom = max(1, maxH - topRows - footer - 1)
  # Which blocks are drawn: all when they fit; otherwise from the start,
  # ending in "More below", or, with the schedule open, from where its end
  # comes into view.
  var first = 0
  var last = blocks.high
  var moreBelow = false
  if total > bodyRoom:
    var scheduleEnd = -1
    for i, b in blocks:
      if b.schedule: scheduleEnd = i
    if scheduleEnd >= 0 and vm.scheduleOpen.val:
      last = scheduleEnd
      moreBelow = blocks.contentAfter(scheduleEnd)
      # One row under the header says the body was scrolled ("More above").
      let room = bodyRoom - (if moreBelow: 1 else: 0) - 1
      var used = 0
      first = scheduleEnd + 1
      while first > 0 and used + blocks[first - 1].rows <= room:
        dec first
        used += blocks[first].rows
      # Scrolled, the context in view goes whole or not at all: a line of
      # it left alone at the top would read as a stray caption.
      if first > 0:
        while first < last and blocks[first].lead:
          used -= blocks[first].rows
          inc first
      # Rows the scroll left free take what follows the schedule.
      while last + 1 < blocks.len and used + blocks[last + 1].rows <= room:
        inc last
        used += blocks[last].rows
      moreBelow = blocks.contentAfter(last)
    else:
      var used = 0
      last = -1
      while last + 1 < blocks.len and used + blocks[last + 1].rows <= bodyRoom - 1:
        inc last
        used += blocks[last].rows
      moreBelow = blocks.contentAfter(last)
  var bodyRows = 0
  for i in first .. last: bodyRows += blocks[i].rows
  let moreAbove = first > 0
  # A body that holds more than it shows takes every row the window leaves
  # it: the next section is drawn as far as the rows go, its cut-off part
  # cleared (whole sections only would leave rows of window unused).
  var partialRows = 0
  if moreBelow and last + 1 <= blocks.high:
    let avail = maxH - topRows - (if moreAbove: 1 else: 0) - 1 - footer
    partialRows = max(0, min(blocks[last + 1].rows - 1, avail - bodyRows))
    bodyRows += partialRows
  # A blank row after the body (where "More below" goes), and the send line.
  let sheetH = topRows + (if moreAbove: 1 else: 0) + bodyRows + 1 + footer
  let sheet = c.node(host, top, sheetCol, sheetW, sheetH,
                     [("sheet", $vm.phase), ("hidden-above", $first),
                      ("hidden-below", $(blocks.high - last))])
  c.area("sheet", top, sheetCol, sheetW, sheetH, ink.sheet)
  # The bands: the header's rows, and every run of band blocks drawn (the
  # context in view, the form); runs that touch are one area.
  var runs: seq[(int, int)] = @[(top, topRows)]
  var at = top + topRows + (if moreAbove: 1 else: 0)
  for i in first .. last + (if partialRows > 0: 1 else: 0):
    let rows = if i > last: partialRows else: blocks[i].rows
    if blocks[i].band:
      if runs[^1][0] + runs[^1][1] == at: runs[^1][1] += rows
      else: runs.add (at, rows)
    at += rows
  for k, (start, rows) in runs:
    c.area(if k == 0: "head" else: "band", start, sheetCol, sheetW, rows, ink.band)
  discard c.drawPara(sheet, top + 1, lay.left, lay.width, header, headerInk, "header")
  var r = top + topRows
  if moreAbove:
    # A quiet line on the sheet's own ground between the header's band and
    # the scrolled body, as the web's hairline and scrollbar say it.
    discard c.text(sheet, r, lay.left, lay.width, MoreAbove, lay.ink.caption,
                   fact = "more-above", alignRight = true)
    inc r
  for i in first .. last:
    blocks[i].draw(c, r)
    r += blocks[i].rows
  if partialRows > 0:
    let clip = r + partialRows
    blocks[last + 1].draw(c, r)
    # What fell past the clip is not shown: its facts and its presses go,
    # and its cells are the sheet's (or the window's, past the sheet) again.
    host.prune(r, clip, [host, sheet])
    var kept: seq[AhTarget]
    for t in c.targets:
      if not (t.row >= r and t.row + max(1, t.height) > clip): kept.add t
    c.targets = kept
    let sheetEnd = top + sheetH
    for rr in clip ..< c.rows:
      let ground = if rr < sheetEnd: ink.sheet else: ink.window
      c.fill(rr, sheetCol, sheetW, 1, ground)
    r = clip
  if moreBelow:
    # A quiet line on the sheet's own ground, at the body's end.
    discard c.text(sheet, r, lay.left, lay.width, MoreBelow, lay.ink.caption,
                   fact = "more-below", alignRight = true)
  inc r
  if footer > 0:
    c.area("send-line", r, sheetCol, sheetW, footer, ink.band)
    c.drawSendLine(ink, press, vm, sheet, r + 1, lay.left, lay.width)
