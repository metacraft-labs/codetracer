## viewmodels/sessions_bar_fit.nim
##
## Which session tabs the sessions bar draws where: on the bar's own line,
## on extra rows beside it, or behind its `+N` chip. One answer every
## front-end draws, so the web, GPUI and the terminal agree tab for tab.
##
## The bar's line is shared with the inbox group (the bell, its count,
## Previous and Next) and, at the bottom, with the status line's own words.
## The rules, in the order they are applied:
##
## 1. **The status line keeps its own words first.** At the bottom, the bar
##    gets only the room the note, the location and the certificate label
##    leave (`statusBarBarArea`, by the status line's own rule,
##    `footer_row_fit.fitFooterRow`): a note never gives way to a tab.
## 2. **The inbox group's width is taken before any tab is fitted.** The
##    group stays on the bar's line whatever happens to the tabs, so the
##    inbox control never moves when a session starts or ends.
## 3. **Everything fits:** every tab is drawn on the line, before the group.
## 4. **Rows:** the tabs leave the line together and wrap onto extra rows
##    (`tab_layout.packTabRows`), up to a cap; the bar never splits its tabs
##    between its line and the rows, so a reader never has to look in two
##    places for the next tab. Past the cap, the last row ends in the `+N`
##    chip and the rest go behind it. The active tab is always on a row.
## 5. **Popup** (or rows not allowed, as on a short terminal): one line,
##    the first tabs that fit, then the `+N` chip, then the group. The chip
##    is never to the right of the group: it belongs to the tabs. The active
##    tab is always drawn (`tab_layout.singleLineLayout`'s rule).
##
## Pure and signal-free, like `tab_layout`; widths are in the caller's unit
## (pixels on the web and in GPUI, cells in a terminal).

import nim_agents_isonim_viewmodels/agent_harbor/tab_layout
import ./sessions_bar_setting
import ./footer_row_fit

export sessions_bar_setting, footer_row_fit

const
  SessionsBarRowCap* = 3
    ## The most extra rows a window's bar wraps onto. Three rows of tabs
    ## still read as a strip; past that the rows push the work area away.
  SessionsBarRowCapTerminal* = 2
    ## The terminal's cap: each row costs a whole screen line.
  SessionsBarRowsMinScreenRows* = 30
    ## Below this many screen lines a terminal keeps the bar on one line
    ## (`rows` behaves as `popup`): the rows would take too much of a small
    ## screen.

type
  SessionsBarFitMode* = enum
    sfInline = "inline"
      ## The tabs that are drawn are on the bar's line.
    sfRows = "rows"
      ## The tabs are on extra rows; the bar's line holds the group only.

  SessionsBarSlotKind* = enum
    sskTab = "tab"
    sskChip = "chip"
    sskGroup = "group"

  SessionsBarSlot* = object
    ## One thing on the bar's line, in drawing order.
    kind*: SessionsBarSlotKind
    index*: int
      ## The tab's index for `sskTab`; -1 otherwise.

  SessionsBarFitInput* = object
    area*: int
      ## The bar's room on its line (after the status line's words at the
      ## bottom, `statusBarBarArea`; after the controls at the top).
    rowWidth*: int
      ## The width of an extra row.
    groupWidth*: int
      ## The inbox group's width; 0 when it is not on the bar (under
      ## `panel`, or when there is no inbox).
    chipWidth*: int
      ## The `+N` chip's width.
    gap*: int
      ## The space between two neighbours on a line or a row.
    tabMins*: seq[int]
      ## Each tab's narrowest width on the bar's line.
    tabWraps*: seq[int]
      ## Each tab's width on an extra row.
    activeIndex*: int
      ## The tab the reader works in; -1 for none.
    overflow*: SessionsBarOverflow
    rowCap*: int
      ## The most extra rows (`rowCapOf`).
    rowsAllowed*: bool
      ## Whether the extra rows may be used at all (`rowsAllowedOf`).

  SessionsBarFit* = object
    mode*: SessionsBarFitMode
    inline*: seq[int]
      ## Tab indexes drawn on the bar's line, in order.
    rows*: seq[seq[int]]
      ## Tab indexes on each extra row, in order (empty unless `sfRows`).
    popup*: seq[int]
      ## Tab indexes behind the `+N` chip, in order.
    chip*: bool
      ## The `+N` chip is drawn.
    chipRow*: int
      ## Where the chip is: the index of the row it ends, or -1 for the
      ## bar's line.
    groupInline*: bool
      ## The inbox group is on the bar's line (always, when there is one).
    inlineOrder*: seq[SessionsBarSlot]
      ## What the bar's line holds, in drawing order: tabs, then the chip,
      ## then the group.

proc rowCapOf*(terminal: bool): int =
  ## The most extra rows the bar wraps onto in a window or a terminal.
  if terminal: SessionsBarRowCapTerminal else: SessionsBarRowCap

proc rowsAllowedOf*(terminal: bool; screenRows: int): bool =
  ## Whether `rows` may wrap at all: always in a window; in a terminal, only
  ## on a screen of at least `SessionsBarRowsMinScreenRows` lines.
  not terminal or screenRows >= SessionsBarRowsMinScreenRows

proc statusBarBarArea*(rowW, leftW, noteW, locationW, locationFloorW,
                       certificateW: int): int =
  ## The room the status line leaves the sessions bar: the row's width less
  ## what comes before the note (`leftW`) and what the note, the location
  ## and the certificate label are drawn at by the status line's own rule
  ## (`fitFooterRow`). The status line keeps its words first, so a long note
  ## keeps its measured width and the bar gets less room. Never negative.
  let fit = fitFooterRow(rowW - leftW, noteW, locationW, locationFloorW,
                         certificateW)
  max(0, rowW - leftW - (fit.note + fit.location + fit.certificate))

proc lineWidth(widths: openArray[int]; tabs: openArray[int]; gap: int): int =
  ## The width `tabs` take side by side, gaps included.
  for k, i in tabs:
    if k > 0: result += gap
    result += widths[i]

proc widthAt(widths: seq[int]; i: int): int =
  if i in 0 ..< widths.len: max(0, widths[i]) else: 0

proc slotsOf(fit: SessionsBarFit): seq[SessionsBarSlot] =
  ## The bar's line in drawing order: the tabs drawn there, then the chip
  ## when it is on the line, then the group.
  for i in fit.inline:
    result.add SessionsBarSlot(kind: sskTab, index: i)
  if fit.chip and fit.chipRow < 0:
    result.add SessionsBarSlot(kind: sskChip, index: -1)
  if fit.groupInline:
    result.add SessionsBarSlot(kind: sskGroup, index: -1)

proc fitRows(input: SessionsBarFitInput; n, active: int;
             fit: var SessionsBarFit) =
  ## Rule 4: every tab on extra rows, at most `rowCap` of them, the last
  ## ending in the chip when the rest go behind it.
  var wraps = newSeq[int](n)
  for i in 0 ..< n: wraps[i] = widthAt(input.tabWraps, i)
  let packed = packTabRows(wraps, input.rowWidth, input.gap)
  let cap = max(1, input.rowCap)
  fit.mode = sfRows
  if packed.len <= cap:
    fit.rows = packed
    return
  # Past the cap: the rows before the last are kept as packed; the last row
  # is packed again with the chip's room kept at its end, and the tabs that
  # do not fit go behind the chip.
  for r in 0 ..< cap - 1:
    fit.rows.add packed[r]
  var next = 0
  for row in fit.rows: next += row.len
  let budget = input.rowWidth - input.chipWidth - input.gap
  var last: seq[int]
  var used = 0
  while next < n:
    let need = (if last.len > 0: input.gap else: 0) + wraps[next]
    if last.len > 0 and used + need > budget: break
    used += need
    last.add next
    inc next
  for i in next ..< n: fit.popup.add i
  # The active tab is always on a row: when it went behind the chip, it
  # takes the last row's last place, and the tabs it displaces (as many as
  # its width needs) go behind the chip instead.
  if active in fit.popup:
    fit.popup.delete(fit.popup.find(active))
    last.add active
    while last.len > 1 and lineWidth(wraps, last, input.gap) > budget:
      fit.popup.add last[^2]
      last.delete(last.len - 2)
    var sorted: seq[int]
    for i in 0 ..< n:
      if i in fit.popup: sorted.add i
    fit.popup = sorted
  fit.rows.add last
  fit.chip = fit.popup.len > 0
  fit.chipRow = if fit.chip: fit.rows.len - 1 else: -1

proc fitPopup(input: SessionsBarFitInput; n, active, room: int;
              fit: var SessionsBarFit) =
  ## Rule 5: one line; the first tabs that fit beside the chip, the active
  ## tab always among them, the rest behind the chip.
  var mins = newSeq[int](n)
  for i in 0 ..< n: mins[i] = widthAt(input.tabMins, i)
  let budget = room - input.chipWidth - input.gap
  var capacity = 0
  var used = 0
  while capacity < n:
    let need = (if capacity > 0: input.gap else: 0) + mins[capacity]
    if used + need > budget: break
    used += need
    inc capacity
  let layout = singleLineLayout(n, active, max(1, capacity))
  var visible = layout.visible
  var hidden = layout.overflow
  # The active tab took the last place; when it is wider than the tab it
  # displaced, the tabs before it give way until the line fits again.
  while visible.len > 1 and lineWidth(mins, visible, input.gap) > budget:
    let drop = if visible[^1] == active: visible.len - 2 else: visible.len - 1
    hidden.add visible[drop]
    visible.delete(drop)
  var sorted: seq[int]
  for i in 0 ..< n:
    if i in hidden: sorted.add i
  fit.mode = sfInline
  fit.inline = visible
  fit.popup = sorted
  fit.chip = sorted.len > 0
  fit.chipRow = -1

proc fitSessionsBar*(input: SessionsBarFitInput): SessionsBarFit =
  ## Where each tab is drawn (the module's rules 2 to 5; rule 1 is the
  ## caller's `area`, from `statusBarBarArea` at the bottom).
  let n = max(input.tabMins.len, input.tabWraps.len)
  let active = if input.activeIndex in 0 ..< n: input.activeIndex else: -1
  result.chipRow = -1
  result.groupInline = input.groupWidth > 0
  let room = input.area -
             (if input.groupWidth > 0: input.groupWidth + input.gap else: 0)
  var all: seq[int]
  for i in 0 ..< n: all.add i
  var mins = newSeq[int](n)
  for i in 0 ..< n: mins[i] = widthAt(input.tabMins, i)
  if n == 0 or lineWidth(mins, all, input.gap) <= room:
    result.mode = sfInline
    result.inline = all
  elif input.overflow == sboRows and input.rowsAllowed:
    fitRows(input, n, active, result)
  else:
    fitPopup(input, n, max(0, active), room, result)
  result.inlineOrder = slotsOf(result)
