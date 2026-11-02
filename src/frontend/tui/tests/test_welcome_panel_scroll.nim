## test_welcome_panel_scroll.nim — the terminal's Welcome Screen keeps the
## keyboard focus on screen when a recent panel has more rows than room.
##
## The keys walk every row of the shared model (`native_welcome.rowsOf`); a
## panel that drew only its first rows left the focus on an entry nobody
## could see (the GPUI window had the same defect, codetracer-pm issue
## 2026-10-26 on `test_plat49_panes_gpui_plan`). Both front-ends now scroll
## the panel to the focused row through `native_welcome.shownFrom`.
##
## Pure: the model's rows and the shipped layout function. No mocks.

import std/unittest

import ../app/layout/cells
import ../app/views/welcome_view

const Traces = 20

proc view(focus: int): WelcomeView =
  result.shown = true
  result.focus = focus
  for i in 0 ..< Traces:
    result.rows.add NativeWelcomeRow(kind: nwrRecentTrace, index: i,
                                     key: "/r/t" & $i, label: "t" & $i,
                                     enabled: true)
  for i, k in ["open-folder", "open-local-trace"]:
    result.rows.add NativeWelcomeRow(kind: nwrOption, index: i, key: k,
                                     label: k, enabled: true)

const Body = CellArea(col: 0, row: 0, width: 120, height: 16)

proc drawn(lay: WelcomeLayout): seq[int] =
  for i in 0 ..< Traces:
    if lay.rowAreas[i].width > 0: result.add i

var countedAssertions = 0
template ck(c: untyped) =
  inc countedAssertions
  check c

suite "terminal Welcome Screen: a recent panel scrolls to its focused row":

  test "the room is smaller than the list; focus on an option shows the first rows":
    let lay = welcomeLayout(view(Traces), Body)
    let shown = lay.drawn
    ck shown.len > 0 and shown.len < Traces and shown[0] == 0

  test "focus on a row past the room: drawn, as the panel's last row":
    let first = welcomeLayout(view(Traces), Body).drawn
    let room = first.len
    let lay = welcomeLayout(view(15), Body)
    ck lay.drawn.len == room and lay.drawn[^1] == 15
    ck lay.rowAreas[15].row == lay.tracesPanel.row + room
    ck lay.welcomeRowAt(lay.rowAreas[15].row, lay.rowAreas[15].col) == 15

suite "assertion count":
  test "every assertion ran":
    check countedAssertions == 4
