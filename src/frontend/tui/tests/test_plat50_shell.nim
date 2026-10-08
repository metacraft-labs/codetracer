## test_plat50_shell.nim — PLAT-50, the terminal's rendering and routing,
## Tier 1: what the runtime does with a press and a key, without a session.
##
##   * K7 — a right-click on a pane tab opens the desktop's tab menu at the
##     press; Down / Enter choose an entry (Close takes the tab off its
##     strip); Esc closes the menu; an event's content overlay closes on Esc;
##   * deliverable 6 — with no divider row between stacked panes, a press on
##     the lower pane's strip OFF its tabs picks the split above it up: a drag
##     upward gives the lower pane rows;
##   * K31 — a click on a point-list row selects it (the desktop's
##     `PointListVM.selectPoint`), drawn on the selection surface;
##   * the ASCII tier draws a divider's and a field's edge line as `|`;
##   * `--dividers=strip|subtle` is parsed, `strip` by default, anything else
##     refused;
##   * a press on a menu entry chooses that entry; a LONE pane's strip off its
##     label is the divider above it too.
##
## Everything through the product's own entry points
## (`TuiRuntime.handleToken` with the bytes a terminal sends, `shellScreenOf`
## for the frame, `cli.parseTuiCommand`). No session and no mocks: these
## routes act on the layout and the runtime's own models.

import std/[options, strutils, unicode, unittest]

import ../app/runtime
import ../app/cli
import ../app/views/shell
import ../app/views/borders
import ../app/layout/binding
import ../app/layout/project
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/theme/cell_style
import ../app/views/point_list
import headless_app/layout_model

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 35

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Enter = "\r"
  Esc = "\x1b"
  Down = "\x1b[B"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  result = newTuiRuntime(newTuiApp(), caps(), cols, rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc press(rt: TuiRuntime; row, col: int; code = 0) =
  discard rt.handleToken(sgr(code, row, col), 0)
  discard rt.handleToken(sgr(code, row, col, release = true), 0)

proc cellOf(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

suite "PLAT-50: a tab's right-click menu in the terminal":

  test "right-click a tab: the desktop's menu; Down and Enter choose Close":
    let rt = newRuntime(200, 50)
    let rows = rt.shellScreenOf().rows
    let col = rows[1].cellOf(" VCS ")
    ck col > 0
    rt.press(1, col + 2, 2)
    ck rt.app.contextMenu.open
    ck rt.app.contextMenu.menu.labels == @["Pin to Left", "Pin to Bottom",
                                            "Pin to Right", "Close",
                                            "Maximise container"]
    let area = rt.shellScreenOf().contextMenuArea
    ck area.row == 2 and area.col <= col + 2
    # The keyboard starts on the first entry; three Downs reach Close.
    for _ in 0 ..< 3:
      discard rt.handleToken(Down, 0)
    ck rt.app.contextMenu.selected == 3
    discard rt.handleToken(Enter, 0)
    ck not rt.app.contextMenu.open
    ck not rt.shellScreenOf().rows[1].contains(" VCS ")
    ck rt.shellScreenOf().rows[1].contains(" Files ")

  test "a press on an entry chooses THAT entry: Close, not its neighbour":
    let rt = newRuntime(200, 50)
    let col = rt.shellScreenOf().rows[1].cellOf(" VCS ")
    rt.press(1, col + 2, 2)
    let area = rt.shellScreenOf().contextMenuArea
    # The frame's top edge is the area's first row; entry i is one below it.
    let closeRow = area.row + 1 + 3
    ck rt.shellScreenOf().rows[closeRow].contains("Close")
    rt.press(closeRow, area.col + 3)
    ck not rt.app.contextMenu.open
    ck not rt.shellScreenOf().rows[1].contains(" VCS ")
    ck not rt.maximize.active

  test "Esc closes the menu, and an event's content overlay":
    let rt = newRuntime(200, 50)
    let col = rt.shellScreenOf().rows[1].cellOf(" Files ")
    rt.press(1, col + 2, 2)
    ck rt.app.contextMenu.open
    discard rt.handleToken(Esc, 0)
    ck not rt.app.contextMenu.open
    rt.app.content = ContentOverlay(open: true, title: "event #2 at tick 88",
                                    text: "6 * 7 = 42")
    let screen = rt.shellScreenOf()
    ck screen.contentArea.width > 0
    var shown = false
    for r in screen.rows:
      if r.contains("6 * 7 = 42"): shown = true
    ck shown
    discard rt.handleToken(Esc, 0)
    ck not rt.app.content.open

suite "PLAT-50: the strip is the divider above it":

  test "a press on the lower pane's strip off its tabs resizes the split":
    let rt = newRuntime(200, 50)
    let screen = rt.shellScreenOf()
    var stripRow = -1
    for r, line in screen.rows:
      if line.contains(" Event Log ") and r > 1:
        stripRow = r
    ck stripRow > 10
    # The row above the strip is a pane's content, no rule.
    ck not screen.rows[stripRow - 1].contains("─")
    # Right of the strip's tabs: its empty ground.
    let tabsEnd = screen.rows[stripRow].cellOf("Terminal Output") +
                  "Terminal Output".len + 4
    discard rt.handleToken(sgr(0, stripRow, tabsEnd), 0)
    for k in 1 .. 4:
      discard rt.handleToken(sgr(32, stripRow - k, tabsEnd), 0)
    discard rt.handleToken(sgr(0, stripRow - 4, tabsEnd, release = true), 0)
    var moved = -1
    for r, line in rt.shellScreenOf().rows:
      if line.contains(" Event Log ") and r > 1:
        moved = r
    ck moved >= 0 and moved < stripRow
    # A press ON a tab of the strip is still the tab's (it activates).
    # (PLAT-51: the Terminal Output tab — the Timeline is removed.)
    let tl = rt.shellScreenOf().rows[moved].cellOf("Terminal Output")
    rt.press(moved, tl + 1)
    var outputActive = false
    for span in rt.shellScreenOf().styledRows[moved]:
      if span.text.contains("Terminal Output") and span.style.role == srTabActive:
        outputActive = true
    ck outputActive

  test "a LONE pane's strip off its label is the divider above it too":
    let rt = newRuntime(200, 50)
    # The point list alone under the editor: a one-tab strip, no stack.
    discard rt.app.layoutBinding.dispatch(cmdSplit(paneEditor, panePointList,
                                                   saColumn))
    var stripRow = -1
    var labelCol = -1
    for r, line in rt.shellScreenOf().rows:
      let c = line.cellOf(" Points ")
      if c >= 0 and r > 1:
        stripRow = r
        labelCol = c
    ck stripRow > 5
    # Past its label, on the strip's ground.
    let off = labelCol + " Points ".len + 6
    discard rt.handleToken(sgr(0, stripRow, off), 0)
    for k in 1 .. 3:
      discard rt.handleToken(sgr(32, stripRow - k, off), 0)
    discard rt.handleToken(sgr(0, stripRow - 3, off, release = true), 0)
    var moved = -1
    for r, line in rt.shellScreenOf().rows:
      if line.contains(" Points ") and r > 1: moved = r
    ck moved >= 0 and moved < stripRow

suite "PLAT-50: a point's row is selected by a click":

  test "a click on a point-list row selects it, on the selection ground":
    let rt = newRuntime(200, 50)
    discard rt.app.layoutBinding.dispatch(cmdAddPane(panePointList))
    discard rt.app.layoutBinding.dispatch(cmdMoveTab(panePointList,
                                                     paneEventLog, 0))
    rt.app.points = initPointListPaneModel(@[
      PointListPaneRow(kind: "breakpoint", path: "/a/main.py", line: 3,
                       enabled: true),
      PointListPaneRow(kind: "breakpoint", path: "/a/main.py", line: 9,
                       enabled: true)], loaded = true)
    var screen = rt.shellScreenOf()
    var rr, cc = -1
    for r, line in screen.rows:
      let c = line.cellOf("main.py:9")
      if c >= 0 and rr < 0:
        rr = r
        cc = c
    ck rr > 0
    ck rt.app.points.selected == -1
    rt.press(rr, cc)
    ck rt.app.points.selected == 1
    screen = rt.shellScreenOf()
    var onSelection = false
    for span in screen.styledRows[rr]:
      if span.text.contains("main.py:9") and
         span.style.surface == srSurfaceSelection:
        onSelection = true
    ck onSelection

suite "PLAT-50: the edges degrade, and --dividers is parsed":

  test "the ASCII tier draws the edge lines as |":
    ck asciiFor(DividerGlyph) == "|"
    ck asciiFor("▕") == "|"

  test "--dividers=strip|subtle, strip by default, anything else refused":
    let plain = parseTuiCommand(@["/tmp/trace"])
    ck plain.kind == tckOpenTrace and plain.dividers == dcStrip
    let subtle = parseTuiCommand(@["--dividers=subtle", "/tmp/trace"])
    ck subtle.kind == tckOpenTrace and subtle.dividers == dcSubtle
    let strip = parseTuiCommand(@["--dividers=strip", "/tmp/trace"])
    ck strip.dividers == dcStrip
    let bad = parseTuiCommand(@["--dividers=loud", "/tmp/trace"])
    ck bad.kind == tckUsageError
    ck bad.message.contains("unknown dividers 'loud'")
    ck dividerLineRole(dcSubtle) == srBorderPane

suite "PLAT-50 shell: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
