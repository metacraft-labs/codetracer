## test_plat49_panes_reference.nim — PLAT-49 part B, the desktop's column
## beside the terminal's and GPUI's: the user's findings 7, 8, 9, 11 and 14
## measured against the REAL Electron app where the desktop is the reference.
##
## Reads `src/tests/visual/answers/plat49-panes.electron.json`, written by the
## real Electron app (`bash scripts/plat49-capture-electron.sh`,
## `src/tests/gui/tests/visual/plat49-panes-capture.spec.ts`), and asserts:
##
##   * finding 8, THE CALL TRACE — every desktop row (toggle, `.call-text`,
##     `.call-args`, `.return-text`) is the row the shared ViewModel makes of
##     the same call (`calltrace_vm.callRowOf` over the store the native
##     decoder fills from a real `replay-server` on the same recording), part
##     for part; the desktop's argument and return colours are the tokens the
##     terminal's `srCallArgs` / `srCallReturn` paint;
##   * finding 14, THE EVENT LOG — the desktop's visible columns, in order,
##     are the ViewModel's default visible columns (its untitled kind column
##     is the ViewModel's `kind`); location is hidden on both;
##   * finding 9, THE FOOTER — the desktop's labels are inside its status
##     bar; its hover preview opens after a delay the shared machine's
##     `HoverPreviewDelayMs` agrees with, its leave dismissal likewise; a
##     click DOCKS (no overlay) and takes `DockedOpenSharePercent` of the
##     layout; a second click collapses it;
##  11. DROP ZONES — where the desktop's drop indicator lands at the sampled
##     points is the HALF on the side `goldenLayoutZone` answers, at every
##     edge sample; at the centre samples the desktop splits top / bottom
##     and the shared rule JOINS — the one deviation, by the user's
##     direction, asserted here so it cannot drift silently; the desktop's
##     header insertion at a tab's left edge is "before", as
##     `goldenLayoutInsertsAfter` says;
##   * finding 7, THE SESSION TABS — the desktop's add control is named
##     "New tab", as the terminal's and GPUI's "+" are
##     (`session_tabs.NewSessionTabTitle`), and is there with one session;
##     with two sessions each tab has a close control
##     (`SessionTabView.closable`), they are separate items with a gap, and
##     the active one has a ground of its own.
##
## And what the review (2026-10-03) measured besides:
##
##   * the FOOTER'S ORDER — the desktop's status bar opens with its file
##     info (language | encoding), and its labels follow; the terminal's
##     status row and GPUI's footer put the same file info
##     (`footer_info.footerFileInfoText`) first and their labels after it;
##   * GOLDENLAYOUT'S GROUND BANDS — near the layout's own edge the
##     indicator is a band of the WHOLE layout, `GoldenLayoutRootBandPx`
##     deep; a drop there makes the event log the root row's last child,
##     full height — what `cmdSplitRootMove` makes of the shared default;
##   * THE DESKTOP'S CELL — a character of its editor's monospace and its
##     line height, which the terminal's `DesktopCellWidthPx` /
##     `DesktopCellHeightPx` carry its pixel measures into cells with;
##   * the EVENT LOG'S COLUMN MENU — the desktop's "Columns +" lists the
##     ViewModel's columns in its order, and showing location / moving
##     output left changes the header as `EventLogVM.showColumn` /
##     `moveColumn` say.
##
## FAILS BY NAME when the answers file is absent. No mocks: the desktop half
## is a capture of the real app; the shared half is the production
## ViewModels over a real recording and a real engine.

import std/[json, options, os, strutils, tables, unittest]

import isonim/core/signals
import codetracer_embed
import headless_session
import headless_app/layout_interaction
import headless_app/auto_hide_hover
import headless_app/session_tabs
import headless_app/footer_info

import ./fixtures/fixture_provider
import ../app/layout/binding
import ../app/theme/roles
import ../../gpui/window_geometry
import ../../gpui/window_top_bar
from ../../gpui/app/leaves import CallArgsColour, CallReturnColour

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 144

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
              "plat49-panes.electron.json"

proc rgbHex(css: string): string =
  ## `rgb(187, 247, 208)` -> `#bbf7d0`.
  let inner = css.replace("rgb(", "").replace(")", "")
  result = "#"
  for part in inner.split(','):
    result.add toHex(parseInt(part.strip()), 2).toLowerAscii

suite "PLAT-49 part B: the desktop is the reference":

  test "the answers exist":
    if not fileExists(answers):
      checkpoint("missing " & answers &
                 " — run `bash scripts/plat49-capture-electron.sh`")
    ck fileExists(answers)

  if fileExists(answers):
    let a = parseFile(answers)

    test "every desktop call-trace row is the ViewModel's row of that call":
      let r = resolveFixture("calc")
      ck r.outcome == foRecorded
      let s = newHeadlessDebugSession(r.tracePath, getEnv("REPLAY_SERVER_BIN"))
      try:
        s.requestAndLoadCalltrace(height = 40, depth = 20)
        let store = s.session.store
        let lines = store.calltrace.lines.val
        let args = store.calltrace.args.val
        var compared = 0
        for i, desk in a["calltrace"].getElems:
          ck i < lines.len
          if i >= lines.len: break
          let l = lines[i]
          let row = callRowOf(l, (if l.callKey in args: args[l.callKey]
                                  else: @[]))
          var argsText = "("
          for k, x in row.args:
            if k > 0: argsText.add ", "
            argsText.add x.name & "=" & x.value
          argsText.add ")"
          checkpoint("desktop '" & desk["text"].getStr & desk["args"].getStr &
                     "' => '" & desk["returnText"].getStr & "'")
          ck desk["text"].getStr == row.callee & " #" & $row.index
          ck desk["args"].getStr == argsText
          ck desk["returnText"].getStr == row.returnValue
          ck desk["toggle"].getStr == $row.toggle
          inc compared
        ck compared >= 10
      finally:
        s.close()
      # The desktop's colours (Dark) are the tokens GPUI paints them in, and
      # the terminal's argument colour; the terminal's return colour is the
      # design system's information-primary (#93c5fd Dark, #2563eb Light —
      # the desktop's Light value exactly), chosen over on-color (#bfdbfe
      # Dark) because on-color has no legible Light value.
      let first = a["calltrace"][0]
      ck rgbHex(first["argColour"].getStr) == CallArgsColour
      ck rgbHex(first["argColour"].getStr) ==
         DesignTokenHex[RoleSpecs[srCallArgs].fg][dmDark]
      ck rgbHex(first["returnColour"].getStr) == CallReturnColour
      ck DesignTokenHex[RoleSpecs[srCallReturn].fg][dmLight] == "#2563eb"

    test "the desktop's visible event-log columns are the ViewModel's":
      var desk: seq[string] = @[]
      var deskLocationVisible = true
      for c in a["eventLog"]["columns"].getElems:
        if c["title"].getStr == "location":
          deskLocationVisible = c["visible"].getBool
        if c["visible"].getBool:
          desk.add (if c["title"].getStr.len == 0: "kind"
                    else: c["title"].getStr)
      var shared: seq[string] = @[]
      for col in defaultEventLogColumns().visibleColumns:
        shared.add eventLogColumnTitle(col)
      checkpoint("desktop " & $desk & " / shared " & $shared)
      ck desk == shared
      ck not deskLocationVisible
      ck not defaultEventLogColumns().isVisible(elcLocation)

    test "the desktop's footer: in the status bar, a delayed preview, a click docks":
      let f = a["footer"]
      ck f["labelsInsideStatusBar"].getBool
      var labels: seq[string] = @[]
      for l in f["labels"].getElems: labels.add l.getStr
      var shared: seq[string] = @[]
      for d in sharedDefaultDocked(): shared.add d.title
      ck labels == shared
      # The preview: not at 120 ms, up by 720 ms — the shared delay between.
      ck not f["overlayAfter120ms"].getBool
      ck f["overlayAfterHover"].getBool
      ck HoverPreviewDelayMs > 120 and HoverPreviewDelayMs < 720
      # Leaving: still up at 100 ms, gone by 900 ms.
      ck f["overlayAfterLeave100ms"].getBool
      ck not f["overlayAfterLeave"].getBool
      ck LeaveDismissDelayMs > 100 and LeaveDismissDelayMs < 900
      # A hover never docks; a click docks with no overlay, and takes the
      # share the shared rule gives it; a second click collapses it.
      ck not f["dockedAfterHover"].getBool
      ck f["dockedAfterClick"].getBool
      ck not f["overlayAfterClick"].getBool
      let before = f["layoutHeightBefore"].getInt
      let docked = f["dockedBox"]["h"].getInt
      ck before - f["layoutHeightDocked"].getInt == docked
      let share = 100 * docked div before
      checkpoint("desktop docked share " & $share & "%")
      ck abs(share - binding.DockedOpenSharePercent) <= 1
      ck abs(share - window_geometry.DockedOpenSharePercent) <= 1
      ck not f["dockedAfterSecondClick"].getBool
      ck f["layoutHeightAfter"].getInt == before

    test "the desktop's drop indicator is the half the shared rule names":
      let z = a["dropZones"]
      proc half(name: string): string =
        let r = z[name]
        if r.kind != JObject: return "none"
        let (x, y, w, h) = (r["x"].getFloat, r["y"].getFloat, r["w"].getFloat,
                            r["h"].getFloat)
        if abs(w - 0.5) < 0.05 and abs(h - 1.0) < 0.05:
          return (if x < 0.25: "left" else: "right")
        if abs(h - 0.5) < 0.05 and abs(w - 1.0) < 0.05:
          return (if y < 0.25: "top" else: "bottom")
        "other"
      proc shared(fx, fy: float): DropZone =
        goldenLayoutZone(int(fx * 1000), int(fy * 1000), 1000, 1000)
      for (name, fx, fy, side, zone) in [
          ("left", 0.1, 0.5, "left", dzLeftEdge),
          ("left-top", 0.2, 0.1, "left", dzLeftEdge),
          ("right-bottom", 0.8, 0.9, "right", dzRightEdge),
          ("top", 0.5, 0.1, "top", dzTopEdge),
          ("bottom", 0.5, 0.9, "bottom", dzBottomEdge)]:
        checkpoint(name & ": desktop " & half(name))
        ck half(name) == side
        ck shared(fx, fy) == zone
      # THE DEVIATION, BY THE USER'S DIRECTION: GoldenLayout has no centre on
      # a stack's body — its middle splits top or bottom — and the shared
      # rule joins there ("the centre joins the stack").
      for (name, fx, fy) in [("top-mid", 0.5, 0.4), ("centre-left", 0.3, 0.45),
                             ("centre-right", 0.7, 0.55),
                             ("bottom-mid", 0.5, 0.6)]:
        ck half(name) in ["top", "bottom"]
        ck shared(fx, fy) == dzCentre
      # A tab's left edge: GoldenLayout's placeholder goes BEFORE it.
      ck z["headerPlaceholderIndex"].getInt == 0
      ck not goldenLayoutInsertsAfter(4, 100)
      ck GoldenLayoutEdgeShare == 0.25

    test "the desktop's session tabs: named add, a close each, separate items":
      let t = a["sessionTabs"]
      # The add control's name, the native strips' "+" tooltip; and it is
      # there with one session, as the native "+" is.
      ck t["addTitle"].getStr == "New tab"
      ck t["addTitle"].getStr == NewSessionTabTitle
      ck t["addVisibleWithOneSession"].getBool
      ck t["barClassSingle"].getStr.contains("single-session")
      let tabs = t["tabs"].getElems
      ck tabs.len == 2
      var actives = 0
      for x in tabs:
        ck x["close"].getBool
        if x["active"].getBool: inc actives
      ck actives == 1
      # Separate items: the second starts after the first and its gap.
      ck tabs[1]["x"].getInt >= tabs[0]["x"].getInt + tabs[0]["w"].getInt + 2
      ck tabs[0]["marginRight"].getStr == "4px"
      ck SessionTabGapPx == 4
      ck tabs[0]["background"].getStr != tabs[1]["background"].getStr
      ck tabs[0]["radius"].getStr == "6px"

suite "PLAT-49 part B review: the desktop's footer order, ground bands, cell, column menu":
  if fileExists(answers):
    let a = parseFile(answers)

    test "the file info first, then the labels — on every front-end":
      var fileInfoX = -1
      var stripX = -1
      var deskInfo = ""
      for p in a["footer"]["statusParts"].getElems:
        if p["id"].getStr == "file-info-status":
          fileInfoX = p["x"].getInt
        if p["id"].getStr == "auto-hide-bottom-strip":
          stripX = p["x"].getInt
        if p["cls"].getStr.contains("file-info-status-language"):
          deskInfo = p["text"].getStr
      ck fileInfoX >= 0 and stripX > fileInfoX
      # The language the desktop names for `calc/main.py`, and the shared
      # answer's, are one; the terminal's lead and GPUI's are its width.
      ck deskInfo == footerFileInfoParts("calc/main.py")[0]
      ck footerFileInfoText("calc/main.py") == deskInfo & " | UTF-8"
      ck footerLeadCells(footerFileInfoText("calc/main.py")) > 0
      ck footerLeadPx(footerFileInfoText("calc/main.py")) > 0

    test "near the layout's own edge the drop splits the whole layout":
      let z = a["dropZones"]
      let band = z["rootBand"]
      let lay = band["layout"]
      ck band["right"].kind == JObject
      let right = band["right"]
      checkpoint("desktop right band " & $right & " in " & $lay)
      ck abs(right["w"].getInt - GoldenLayoutRootBandPx) <= 2
      ck abs(right["h"].getInt - lay["h"].getInt) <= 2
      ck abs(right["x"].getInt + right["w"].getInt -
             (lay["x"].getInt + lay["w"].getInt)) <= 2
      let drop = z["rootDrop"]
      ck drop["rootIsRow"].getBool
      ck drop["lastFullHeight"].getBool
      var tabs: seq[string] = @[]
      for t in drop["lastTabs"].getElems: tabs.add t.getStr.toLowerAscii
      ck tabs == @["event log"]
      # The model's root split of the shared default, the same shape.
      let shared = initLayout(sharedDefaultLayout().tree,
                              sharedDefaultLayout().docked)
      let o = shared.apply(cmdSplitRootMove(paneEventLog, saRow, ssAfter))
      ck o.kind == loApplied
      ck o.layout.tree.kind == lnRow
      ck o.layout.tree.children[^1].kind == lnPane and
         o.layout.tree.children[^1].pane == paneEventLog

    test "a terminal cell stands for the desktop's character":
      let c = a["cellPx"]
      checkpoint("desktop cell " & $c)
      ck abs(c["width"].getFloat - DesktopCellWidthPx) <= 0.5
      ck abs(c["height"].getFloat - DesktopCellHeightPx) <= 1.0

    test "the desktop's column menu is the ViewModel's":
      let m = a["eventLogMenu"]
      ck m["button"].getBool
      var options: seq[string] = @[]
      for o in m["options"].getElems: options.add o["column"].getStr
      var order: seq[string] = @[]
      for c in DesktopEventLogColumnOrder: order.add $c
      ck options == order
      proc header(name: string): seq[string] =
        for h in m[name].getElems:
          result.add (if h.getStr.len == 0: "kind" else: h.getStr)
      proc titles(c: EventLogColumns): seq[string] =
        for col in c.visibleColumns: result.add eventLogColumnTitle(col)
      var c = defaultEventLogColumns()
      ck header("headerBefore") == titles(c)
      discard c.showColumn(elcLocation)
      ck header("headerAfterShowLocation") == titles(c)
      discard c.moveColumn(elcOutput, -1)
      ck header("headerAfterMoveOutputLeft") == titles(c)
      ck header("headerRestored") == titles(defaultEventLogColumns())
      ck not m["openAfterSecondClick"].getBool

suite "PLAT-49 part B desktop reference: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
