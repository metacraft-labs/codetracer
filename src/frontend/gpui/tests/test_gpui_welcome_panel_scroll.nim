## test_gpui_welcome_panel_scroll.nim — the GPUI Welcome Screen's recent
## panels keep the keyboard focus on screen.
##
## A recent panel holds at most `WelcomeMaxEntries` rows, but the keys walk
## every row of the model (`native_welcome.rowsOf`). Before this suite the
## panel always drew its first rows, so arrowing past them put the focus on
## a recording nobody could see, and Enter opened it (codetracer-pm issue
## 2026-10-26, `test_plat49_panes_gpui_plan` opening `deep_calls` where it
## meant `call_pages`). The panel now scrolls so the focused row is drawn
## (`shownFrom`), and the click hit-test reads the same rectangles.
##
## Pure: the shared model's rows and the window's placement function; no
## mocks and no window.

import std/unittest

import ../welcome_leaf
import ../window_geometry

const Traces = 12

proc rows(): seq[NativeWelcomeRow] =
  for i in 0 ..< Traces:
    result.add NativeWelcomeRow(kind: nwrRecentTrace, index: i,
                                key: "/r/t" & $i, label: "t" & $i,
                                enabled: true)
  for i, k in ["open-folder", "open-local-trace", "record-new-trace"]:
    result.add NativeWelcomeRow(kind: nwrOption, index: i, key: k, label: k,
                                enabled: true)

const Area = PxRect(x: 0, y: 0, w: 1440, h: 1000)

proc drawn(lay: WelcomeLayoutPx): seq[int] =
  for i in 0 ..< Traces:
    if not lay.rowRects[i].isEmpty: result.add i

var countedAssertions = 0
template ck(c: untyped) =
  inc countedAssertions
  check c

suite "GPUI Welcome Screen: a recent panel scrolls to its focused row":

  test "focus on an option: the panel shows its first rows":
    let lay = welcomeLayoutPx(rows(), Area, Traces)
    ck lay.drawn == @[0, 1, 2, 3, 4, 5, 6, 7]

  test "focus past the room: the focused row is drawn, as the panel's last":
    let r = rows()
    let lay = welcomeLayoutPx(r, Area, 10)
    ck lay.drawn == @[3, 4, 5, 6, 7, 8, 9, 10]
    # Drawn where the panel's last row goes, inside the panel.
    let last = lay.rowRects[10]
    ck last.y == lay.tracesPanel.y + WelcomeMaxEntries * WelcomeRowPx + 4
    # A press there chooses the row the focus is on.
    ck lay.welcomeRowAtPx(last.x + 2, last.y + 2) == 10
    # Nothing below the panel's last row takes a press as a trace.
    ck lay.welcomeRowAtPx(last.x + 2, last.y + WelcomeRowPx + 2) == -1

  test "the default (no focus) is the panel's first rows":
    ck welcomeLayoutPx(rows(), Area).drawn == @[0, 1, 2, 3, 4, 5, 6, 7]

suite "assertion count":
  test "every assertion ran":
    check countedAssertions == 6
