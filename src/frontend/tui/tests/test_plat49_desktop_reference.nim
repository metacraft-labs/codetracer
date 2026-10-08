## test_plat49_desktop_reference.nim — PLAT-49 part A, the desktop's column
## beside the terminal's and GPUI's: the user's findings measured against the
## REAL Electron app where the desktop is the reference.
##
## Reads `src/tests/visual/answers/plat49-chrome.electron.json`, written by
## the real Electron app (`bash scripts/plat49-capture-electron.sh`,
## `src/tests/gui/tests/visual/plat49-chrome-capture.spec.ts`), and asserts:
##
##   * finding 1, THE MENU — the desktop's caption bar holds ONE root button
##     and shows no first-level title; opened, its first level is the shared
##     tree's folders, below the button; a folder's submenu opens to the
##     RIGHT of the first level, level with the folder's row. The terminal's
##     top bar (`top_bar.topBarLayout` / `menuDropdowns`) and the GPUI band
##     (`window_top_bar.gpuiTopBarLayout` / `gpuiMenuPopovers`) lay the same
##     open Menu ViewModel out in the same relations;
##   * finding 5, THE TOOLTIPS — every transport button's tooltip on the
##     desktop is the ViewModel's `transportTooltip` over the desktop's own
##     binding — the very text the GPUI window's hover popover draws;
##   * finding 6, THE PLACEHOLDER — the desktop's palette input shows the
##     Omnibar ViewModel's `OmnibarPlaceholder`, the words the terminal's
##     field and GPUI's draw.
##
## FAILS BY NAME when the answers file is absent. No mocks: the desktop half
## is a capture of the real app; the terminal and GPUI halves are the
## production layout functions over the production ViewModels.

import std/[json, os, strutils, tables, unittest]

import codetracer_embed
import ../app/views/top_bar
import ../../gpui/window_top_bar

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 49

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "justfile"):
    dir = dir.parentDir
  dir

let answers = repoRoot() / "src" / "tests" / "visual" / "answers" /
              "plat49-chrome.electron.json"

proc sharedFirstLevel(): seq[string] =
  let tree = nativeFrontEndMenu("calc")
  for i in tree.visibleChildren():
    result.add tree.children[i].label

proc openOnDebug(): MenuVM =
  ## The menu open with its Debug folder entered — the state the desktop's
  ## capture hovered into.
  result = newMenuVM(nativeFrontEndMenu("calc"))
  result.open()
  while result.highlightedItem().label != "Debug":
    result.moveHighlight(1)
  doAssert result.enterFolder()

suite "PLAT-49: the desktop is the reference":

  test "the answers exist":
    if not fileExists(answers):
      checkpoint("missing " & answers & " — run `bash scripts/plat49-capture-electron.sh`")
    ck fileExists(answers)

  if fileExists(answers):
    let a = parseJson(readFile(answers))

    test "the desktop's menu: one root button, the first level inside it, submenus to the right":
      ck a["closed"]["rootButtons"].getInt == 1
      ck a["closed"]["visibleFirstLevelTitles"].len == 0
      var labels: seq[string]
      for s in a["open"]["labels"]: labels.add s.getStr
      ck labels == sharedFirstLevel()
      ck a["open"]["firstLevelBelowButton"].getBool
      ck a["open"]["nestedRightOfFirstLevel"].getBool
      ck a["open"]["nestedLevelWithFolder"].getBool
      ck a["open"]["nestedFirstLabels"][0].getStr == "Continue"

    test "the terminal draws the same menu: one button, a first level below it, a cascade":
      let closed = TopBarModel(menu: newMenuVM(nativeFrontEndMenu("calc")),
                               omnibar: newOmnibarVM(), hoveredControl: -1)
      let lay = topBarLayout(closed, 200)
      var buttons = 0
      for s in lay.segments:
        if s.part == tpMenuButton: inc buttons
      ck buttons == 1
      let row = rowText(closed, 200)
      for t in sharedFirstLevel():
        ck row.find(" " & t & " ") < 0
      let m = TopBarModel(menu: openOnDebug(), omnibar: newOmnibarVM(),
                          hoveredControl: -1)
      let drops = menuDropdowns(m, topBarLayout(m, 200), 200, 50)
      ck drops.len == 2
      var first: seq[string]
      for it in drops[0].level.items: first.add it.label
      ck first == sharedFirstLevel()
      ck drops[0].area.row == 1                      # below the button's row
      ck drops[0].area.col == lay.segmentOf(tpMenuButton).col
      ck drops[1].area.col >= drops[0].area.col + drops[0].area.width
      var debugRow = -1
      for dr in drops[0].rows:
        if dr.item >= 0 and drops[0].level.items[dr.item].label == "Debug":
          debugRow = dr.row
      # Level with the folder: the cascade's FIRST ITEM on the folder's row
      # (PLAT-50: its frame one row above).
      ck drops[1].rows[0].row == debugRow

    test "GPUI draws the same menu: one button, a first level below it, a cascade":
      let menu = openOnDebug()
      let lay = gpuiTopBarLayout(menu, newOmnibarVM(), @[], 1920)
      var buttons = 0
      for s in lay.segs:
        if s.part == gtMenuButton: inc buttons
      ck buttons == 1
      let pops = gpuiMenuPopovers(menu, lay, 1920, 1080)
      ck pops.len == 2
      let button = lay.segOf(gtMenuButton).rect
      ck pops[0].rect.x == button.x
      ck pops[0].rect.y >= button.y + button.h
      ck pops[1].rect.x >= pops[0].rect.x + pops[0].rect.w
      let levels = menu.openLevels()
      var debugY = -1
      for r in pops[0].rows:
        if r.item >= 0 and levels[0].items[r.item].label == "Debug":
          debugY = r.rect.y
      ck abs(pops[1].rect.y - debugY) <= 4

    test "every transport tooltip is the ViewModel's, over the desktop's binding":
      let bindings = desktopBindings()
      var compared = 0
      for c in TransportControls:
        let desk = a["tooltips"]{c.id}.getStr
        checkpoint(c.id & ": desktop '" & desk & "'")
        ck desk == transportTooltip(c.id, bindings.getOrDefault(c.clientAction))
        # …which is exactly what GPUI's hover popover draws for it.
        ck desk == controlTooltip(controlIndex(c.id),
                                  bindings.getOrDefault(c.clientAction))
        inc compared
      ck compared == TransportControls.len

    test "the desktop's omnibar placeholder is the Omnibar ViewModel's":
      ck a["omnibarPlaceholder"].getStr == OmnibarPlaceholder
      ck TopBarPlaceholder == OmnibarPlaceholder

suite "PLAT-49 desktop reference: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
