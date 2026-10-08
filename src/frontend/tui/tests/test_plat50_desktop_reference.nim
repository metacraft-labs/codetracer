## test_plat50_desktop_reference.nim — PLAT-50: the terminal's and the shared
## models' answers held against THE DESKTOP'S, measured on the real Electron
## app (`src/tests/gui/tests/visual/plat50-desktop-capture.spec.ts`, which
## writes `src/tests/visual/answers/plat50-desktop.electron.json`).
##
##   * the RIGHT-CLICK MENUS — a pane tab, a docked pane's label, a call with
##     children, a leaf, a call argument, the editor's text on a plain line
##     and on a breakpoint's, a Variables row, an inline value — are the
##     shared models' (`headless_app/pane_clicks`), label for label, in the
##     desktop's order, and a Files node has none;
##   * the COLOURS the terminal paints its chrome with are the tokens the
##     desktop's chrome resolves to (its caption bar, transport buttons,
##     omnibox ground and border, the ground behind its tabs, its splitters,
##     its menu surface and border, the inactive tab title, the pane ground) —
##     read through this front-end's role table (`theme/roles`);
##   * the OMNIBOX's width is the desktop's share of the bar
##     (`clamp(24em, 24vw, 40em)`) and centred, as measured;
##   * the CLICKS the terminal mirrors did on the desktop what the terminal's
##     suites assert (`real_terminal/test_plat50_clicks.nim`): a call-trace
##     row and an event-log row move the debugger (the event to tick 68, line
##     111), a gutter click puts a breakpoint on the line and a right-click on
##     it disables it; a header click orders the event log (ascending, then
##     descending); an argument's
##     left press opens no tooltip and moves nothing; the status bar's copy
##     control copies the location.
##
## Reads files and pure values; no session. No mocks.

import std/[json, os, strutils, unittest]

import headless_app/layout_model
import headless_app/pane_clicks
import ../app/theme/roles
import ../app/views/top_bar

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 51

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "justfile"):
    dir = dir.parentDir
  dir

let answers = parseFile(repoRoot() / "src" / "tests" / "visual" / "answers" /
                        "plat50-desktop.electron.json")

proc labelsOf(key: string): seq[string] =
  for l in answers["menus"][key]:
    result.add l.getStr

proc dark(token: DesignToken): string = tokenHex(token, dmDark)

suite "PLAT-50: the desktop's right-click menus are the shared models'":

  test "a tab, a dock label, a call, a leaf, an argument; no Files menu":
    ck labelsOf("tab") == tabContextMenu(paneVcs, maximised = false).labels
    ck labelsOf("dockLabelBottom") ==
       dockLabelContextMenu(paneBuildOutput, leBottom).labels
    ck labelsOf("callTraceWithChildren") ==
       callTraceContextMenu(3, hasChildren = true, expanded = true).labels
    ck labelsOf("callTraceLeaf") ==
       callTraceContextMenu(4, hasChildren = false, expanded = false).labels
    ck labelsOf("callArgument") ==
       callArgumentContextMenu(4, "left", "2").labels
    # The desktop's Files node has no menu (its entries ran nothing).
    ck labelsOf("filesNode").len == 0

  test "the editor's text, on a plain line and on a breakpoint's":
    ck labelsOf("editorText") == editorTextContextMenu("main.py", 31).labels
    # The capture opens this menu on the breakpoint its gutter right-click has
    # just DISABLED (`clicks.gutterDisabled`), so its entry is "Enable".
    ck labelsOf("editorTextOnBreakpoint") ==
       editorTextContextMenu("main.py", 31, breakpoint = lbDisabled,
                             fileHasBreakpoints = true,
                             anyBreakpoints = true).labels

  test "a variable's":
    ck labelsOf("variablesRow") == variablesContextMenu("value").labels
    # (An inline value's menu is not measured: the desktop draws no flow
    # value in the capture's window, so `flowValueContextMenu` follows
    # `ui/flow.createContextMenuItems`' code.)

suite "PLAT-50: the terminal's chrome is the desktop's tokens":

  test "the caption bar, its controls, the omnibox":
    let c = answers["chrome"]
    ck c["bar"]["ground"].getStr == dark(dtColorsUiSurfacePrimaryDefault)
    ck RoleSpecs[srSurfaceTopBar].bg == dtColorsUiSurfacePrimaryDefault
    # A transport button has no ground of its own: the bar's.
    ck c["transportButton"]["ground"].getStr == c["bar"]["ground"].getStr
    # The menu button's and the omnibox's border: ui/border/secondary, the
    # colour of the terminal's edge lines (`srBorderPane`).
    ck c["menuButton"]["border"].getStr == dark(dtColorsUiBorderSecondary)
    ck c["omnibox"]["border"].getStr == dark(dtColorsUiBorderSecondary)
    ck RoleSpecs[srBorderPane].fg == dtColorsUiBorderSecondary
    # The desktop's field is the bar's ground inside that border; the
    # terminal's is one subtle step off it (the input surface), never the
    # old raised slab.
    ck c["omnibox"]["ground"].getStr == c["bar"]["ground"].getStr
    ck RoleSpecs[srSurfaceField].bg == dtColorsUiSurfaceInputDefault
    ck RoleSpecs[srSurfaceField].bg != dtColorsUiSurfaceBaseRaised

  test "the strip, its tabs, the splitters, the pane":
    let s = answers["chrome"]["strip"]
    ck s["groundBehindTabs"].getStr == dark(dtColorsUiSurfacePrimaryDefault)
    ck s["splitter"].getStr == dark(dtColorsUiSurfacePrimaryDefault)
    ck RoleSpecs[srTabBar].bg == dtColorsUiSurfacePrimaryDefault
    ck RoleSpecs[srTabInactive].bg == dtColorsUiSurfacePrimaryDefault
    # The default divider is drawn in the splitters' colour.
    ck RoleSpecs[dividerLineRole(dcStrip)].fg == dtColorsUiSurfacePrimaryDefault
    ck dividerLineRole(dcSubtle) == srBorderPane
    ck s["inactiveTitle"].getStr == dark(dtColorsUiTextPrimaryDisabled)
    ck RoleSpecs[srTabInactive].fg == dtColorsUiTextPrimaryDisabled
    ck s["paneGround"].getStr == dark(dtColorsUiSurfaceBasePanel)
    ck RoleSpecs[srSurfacePanel].bg == dtColorsUiSurfaceBasePanel

  test "the open menu's surface and border":
    let m = answers["menu"]
    ck m["ground"].getStr == dark(dtColorsUiSurfacePrimaryDefault)
    ck m["border"].getStr == dark(dtColorsUiBorderPrimary)
    ck RoleSpecs[srSurfaceMenu].bg == dtColorsUiSurfacePrimaryDefault
    ck RoleSpecs[srBorderMenu].fg == dtColorsUiBorderPrimary
    # Distinct from the pane ground it opens over.
    ck dark(dtColorsUiSurfacePrimaryDefault) != dark(dtColorsUiSurfaceBasePanel)

suite "PLAT-50: the omnibox's geometry is the desktop's":

  test "24% of the bar, clamped; centred":
    let share = answers["omniboxShare"].getFloat
    ck abs(share - OmnibarDesktopShare) < 0.01
    let c = answers["chrome"]
    let w = c["viewportWidth"].getFloat
    let centre = answers["omniboxCentre"].getFloat
    # Centred between the bar's two equal-share neighbours: within the
    # window controls' offset (72 px) of the window's middle.
    ck abs(centre - w / 2) <= 40
    ck omnibarDesktopCells(200) == 48
    ck omnibarDesktopCells(80) == OmnibarDesktopFloorCells
    ck omnibarDesktopCells(400) == OmnibarDesktopCeilingCells

suite "PLAT-50: the clicks did on the desktop what the terminal does":

  test "a call-trace row and an event-log row move the debugger; the gutter":
    let k = answers["clicks"]
    ck k["callTraceRow"]["moved"].getBool
    ck k["eventLogRow"]["moved"].getBool
    ck k["eventLogRow"]["to"]["ticks"].getInt == 68
    ck k["eventLogRow"]["to"]["line"].getInt == 111
    ck k["gutterBreakpoint"].getBool
    ck k["gutterDisabled"].getBool

  test "a header orders the log; the full callstack; an argument; the location":
    let k = answers["clicks"]
    # The `output` header: ascending, then descending — different firsts.
    let sorted = k["eventLogSort"]
    ck sorted["ascending"].getStr != sorted["descending"].getStr
    ck sorted["ascending"].getStr.endsWith("1 + 2 * 3 - 4 / 2 = 2")
    ck sorted["descending"].getStr.endsWith("checksum = 73")
    # The header carries the arrow, as the native front-ends draw it.
    ck sorted["header"].getStr == "output ▼"
    # An argument's left press opens no tooltip and moves nothing (only the
    # call's name is the desktop row's press target; K38).
    ck not k["callArgumentClick"]["tooltip"].getBool
    ck not k["callArgumentClick"]["moved"].getBool
    # The status bar's copy control: the location, path and line.
    ck k["statusLocationCopied"].getStr.contains("main.py")

suite "PLAT-50 desktop reference: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
