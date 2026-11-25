## Where the sessions bar draws each tab (`sessions_bar_fit`): on its line,
## on extra rows up to a cap, or behind its `+N` chip; the inbox group's
## place on the line; and the room the status line leaves the bar.
##
## The fit model is pure, so each case gives it the widths a host measures
## and reads its answer; no test doubles are used. The widths are round
## numbers in the web's pixels (tabs 160 px at their narrowest and 200 px on
## a row, a 4 px gap, a 40 px chip, a 120 px inbox group) and in terminal
## cells (tabs 20 cells, a 1-cell gap, a 4-cell chip), and every expected
## index is worked out by hand from them in the comments.

import std/[algorithm, sequtils, unittest]
import ../../viewmodels/sessions_bar_fit

const
  Gap = 4
  Chip = 40
  Group = 120
  TabMin = 160
  TabWrap = 200

proc windowInput(tabs, area: int; overflow = sboRows; active = 0;
                 group = Group; rowWidth = 1440): SessionsBarFitInput =
  SessionsBarFitInput(area: area, rowWidth: rowWidth, groupWidth: group,
                      chipWidth: Chip, gap: Gap,
                      tabMins: repeat(TabMin, tabs), tabWraps: repeat(TabWrap, tabs),
                      activeIndex: active, overflow: overflow,
                      rowCap: rowCapOf(terminal = false),
                      rowsAllowed: rowsAllowedOf(terminal = false, 0))

proc terminalInput(tabs, area, screenRows: int; overflow = sboRows;
                   active = 0): SessionsBarFitInput =
  SessionsBarFitInput(area: area, rowWidth: 180, groupWidth: 12,
                      chipWidth: 4, gap: 1,
                      tabMins: repeat(16, tabs), tabWraps: repeat(20, tabs),
                      activeIndex: active, overflow: overflow,
                      rowCap: rowCapOf(terminal = true),
                      rowsAllowed: rowsAllowedOf(terminal = true, screenRows))

proc everyTab(fit: SessionsBarFit): seq[int] =
  ## Every tab the fit places anywhere, sorted, each as often as placed.
  result = fit.inline & fit.popup
  for row in fit.rows: result.add row
  result.sort

proc tabSlot(i: int): SessionsBarSlot = SessionsBarSlot(kind: sskTab, index: i)
const ChipSlot = SessionsBarSlot(kind: sskChip, index: -1)
const GroupSlot = SessionsBarSlot(kind: sskGroup, index: -1)

suite "the sessions bar's fit":
  test "everything fits: every tab on the line, then the group":
    # 4 tabs at 160 with 3 gaps take 652; the line has 1000 less the group
    # and its gap (124): 876.
    let fit = fitSessionsBar(windowInput(4, 1000))
    check fit.mode == sfInline
    check fit.inline == @[0, 1, 2, 3]
    check fit.rows.len == 0
    check fit.popup.len == 0
    check not fit.chip
    check fit.groupInline
    check fit.inlineOrder == @[tabSlot(0), tabSlot(1), tabSlot(2), tabSlot(3), GroupSlot]

  test "the group's width is taken before the tabs are fitted":
    # 5 tabs take 816: they fit 900 alone, but not 900 less the group's 124.
    let alone = fitSessionsBar(windowInput(5, 900, group = 0))
    check alone.mode == sfInline
    check alone.inline.len == 5
    let withGroup = fitSessionsBar(windowInput(5, 900))
    check withGroup.mode == sfRows
    check withGroup.groupInline
    # Exactly at the edge: 816 + 124 = 940 fits.
    check fitSessionsBar(windowInput(5, 940)).mode == sfInline
    check fitSessionsBar(windowInput(5, 939)).mode == sfRows

  test "rows: every tab leaves the line together; the group stays on it":
    # 10 tabs (1636) do not fit 876; on 1440-wide rows 7 tabs at 200 take
    # 1424, so the rows are 0..6 and 7..9.
    let fit = fitSessionsBar(windowInput(10, 1000))
    check fit.mode == sfRows
    check fit.rows == @[@[0, 1, 2, 3, 4, 5, 6], @[7, 8, 9]]
    check fit.inline.len == 0
    check fit.popup.len == 0
    check not fit.chip
    check fit.chipRow == -1
    check fit.groupInline
    check fit.inlineOrder == @[GroupSlot]
    check fit.everyTab == toSeq(0 ..< 10)

  test "the bar never splits its tabs between its line and the rows":
    for tabs in [6, 9, 12, 25, 40]:
      for area in [300, 700, 1000]:
        let fit = fitSessionsBar(windowInput(tabs, area))
        if fit.mode == sfRows:
          check fit.inline.len == 0
          check fit.inlineOrder == @[GroupSlot]
        else:
          for row in fit.rows: check row.len == 0
        check fit.everyTab == toSeq(0 ..< tabs)

  test "the cap: three rows in a window, the rest behind the chip on the last":
    # 40 tabs pack into 6 rows of 7 (the last 5). Rows 0 and 1 are kept as
    # packed (0..13); the last row keeps the chip's 40 and its gap at its end
    # (1396), which holds 6 tabs (1220): 14..19. The other 20 are behind it.
    let fit = fitSessionsBar(windowInput(40, 1000))
    check fit.mode == sfRows
    check fit.rows.len == 3
    check fit.rows[0] == toSeq(0 .. 6)
    check fit.rows[1] == toSeq(7 .. 13)
    check fit.rows[2] == toSeq(14 .. 19)
    check fit.popup == toSeq(20 .. 39)
    check fit.chip
    check fit.chipRow == 2
    check fit.groupInline
    check fit.inlineOrder == @[GroupSlot]
    check fit.everyTab == toSeq(0 ..< 40)
    # Exactly the cap's worth of tabs: three rows and no chip.
    let full = fitSessionsBar(windowInput(21, 1000))
    check full.rows.len == 3
    check not full.chip
    check full.popup.len == 0
    # One tab more than three rows hold: still three rows, and a chip.
    let over = fitSessionsBar(windowInput(22, 1000))
    check over.rows.len == 3
    check over.chip
    check over.everyTab == toSeq(0 ..< 22)

  test "the cap: two rows in a terminal":
    # Rows of 180 cells hold 8 tabs of 20 (167); the last row keeps 5 for
    # the chip (175), which still holds 8. 40 tabs: 0..7, 8..15, the rest
    # behind the chip.
    let fit = fitSessionsBar(terminalInput(40, 120, screenRows = 40))
    check fit.mode == sfRows
    check fit.rows.len == 2
    check fit.rows[0] == toSeq(0 .. 7)
    check fit.rows[1] == toSeq(8 .. 15)
    check fit.popup == toSeq(16 .. 39)
    check fit.chip
    check fit.chipRow == 1
    check fit.everyTab == toSeq(0 ..< 40)
    check rowCapOf(terminal = true) == 2
    check rowCapOf(terminal = false) == 3

  test "the active tab is always on a row, even past the cap":
    # Active 30 takes the last row's last place; 7 tabs would not fit 1396,
    # so the tab before it (19) goes behind the chip instead.
    let fit = fitSessionsBar(windowInput(40, 1000, active = 30))
    check fit.rows.len == 3
    check fit.rows[2] == @[14, 15, 16, 17, 18, 30]
    check 30 notin fit.popup
    check 19 in fit.popup
    check fit.popup == toSeq(19 .. 29) & toSeq(31 .. 39)
    check fit.everyTab == toSeq(0 ..< 40)

  test "popup: one line, the first tabs that fit, the chip, then the group":
    # The line has 876 for tabs; the chip and its gap leave 832, which holds
    # 5 tabs (816).
    let fit = fitSessionsBar(windowInput(10, 1000, overflow = sboPopup))
    check fit.mode == sfInline
    check fit.inline == @[0, 1, 2, 3, 4]
    check fit.popup == @[5, 6, 7, 8, 9]
    check fit.rows.len == 0
    check fit.chip
    check fit.chipRow == -1
    check fit.inlineOrder == @[tabSlot(0), tabSlot(1), tabSlot(2), tabSlot(3),
                               tabSlot(4), ChipSlot, GroupSlot]

  test "popup: the active tab beyond the line is still drawn, in the last place":
    let fit = fitSessionsBar(windowInput(10, 1000, overflow = sboPopup, active = 8))
    check fit.inline == @[0, 1, 2, 3, 8]
    check fit.popup == @[4, 5, 6, 7, 9]
    check 8 in fit.inline
    check fit.everyTab == toSeq(0 ..< 10)
    # A wider active tab makes the tabs before it give way: at 400 it needs
    # the room of 2 and a half narrow tabs, so 2 and 3 go behind the chip
    # (0, 1 and 8 take 728 of 832).
    var input = windowInput(10, 1000, overflow = sboPopup, active = 8)
    input.tabMins[8] = 400
    let wide = fitSessionsBar(input)
    check 8 in wide.inline
    check wide.inline[^1] == 8
    check wide.inline == @[0, 1, 8]
    check wide.popup == @[2, 3, 4, 5, 6, 7, 9]
    check wide.everyTab == toSeq(0 ..< 10)

  test "the chip is never to the right of the group":
    for overflow in [sboRows, sboPopup]:
      for tabs in [8, 20, 40]:
        let fit = fitSessionsBar(windowInput(tabs, 700, overflow = overflow))
        let chipAt = fit.inlineOrder.find(ChipSlot)
        let groupAt = fit.inlineOrder.find(GroupSlot)
        check groupAt == fit.inlineOrder.len - 1
        if chipAt >= 0: check chipAt < groupAt

  test "a short terminal keeps the bar on one line":
    check not rowsAllowedOf(terminal = true, 29)
    check rowsAllowedOf(terminal = true, 30)
    check rowsAllowedOf(terminal = false, 10)
    let short = fitSessionsBar(terminalInput(40, 120, screenRows = 29))
    check short.mode == sfInline
    check short.rows.len == 0
    check short.chip
    check short.chipRow == -1
    check short.inline.len > 0
    check short.everyTab == toSeq(0 ..< 40)
    let tall = fitSessionsBar(terminalInput(40, 120, screenRows = 30))
    check tall.mode == sfRows

  test "a long status note shrinks the bar's room, and the tabs leave the line sooner":
    # A 1920 row with 200 before the note leaves 1720 for the note, the
    # location (400) and the certificate label (100). A short note (200)
    # leaves the bar 1020; a long one (900) keeps its measured width and
    # leaves 320.
    let roomy = statusBarBarArea(1920, 200, 200, 400, 100, 100)
    let squeezed = statusBarBarArea(1920, 200, 900, 400, 100, 100)
    check roomy == 1020
    check squeezed == 320
    check squeezed == 1920 - 200 - 900 - 400 - 100
    # 4 tabs (652) beside the group fit 1020, not 320.
    check fitSessionsBar(windowInput(4, roomy)).mode == sfInline
    check fitSessionsBar(windowInput(4, squeezed)).mode == sfRows
    check fitSessionsBar(windowInput(4, squeezed, overflow = sboPopup)).chip
    # Once the location has to be cut, the status line's words fill the
    # row and the bar gets nothing; a note longer than the row, or a row
    # narrower than what comes before the note, never makes it negative.
    check statusBarBarArea(1920, 200, 1500, 400, 100, 100) == 0
    check statusBarBarArea(1920, 200, 3000, 400, 100, 100) == 0
    check statusBarBarArea(100, 200, 300, 400, 100, 100) == 0

  test "under panel the bar has no group; the pane's header carries it":
    let fit = fitSessionsBar(windowInput(4, 1000, group = 0))
    check not fit.groupInline
    check fit.inlineOrder == @[tabSlot(0), tabSlot(1), tabSlot(2), tabSlot(3)]
    let rows = fitSessionsBar(windowInput(40, 1000, group = 0))
    check not rows.groupInline
    check rows.inlineOrder.len == 0

  test "no tabs: the line holds the group alone":
    let fit = fitSessionsBar(windowInput(0, 400))
    check fit.mode == sfInline
    check fit.inline.len == 0
    check not fit.chip
    check fit.inlineOrder == @[GroupSlot]
