## test_plat48_gpui_window.nim — PLAT-48, **the GPUI window read from its own
## pixels**: the top bar (the shared menu, the nine debugger controls drawn as
## the desktop's marks, the omnibar), the footer's auto-hide strip and its
## reveal overlay, pin / unpin, and the TOP dock edge.
##
## The record `src/tests/visual/plat48-gpui-window.json` is MEASURED off a
## real window on a headless sway, driven by a real pointer device and real
## keys (`just plat48-gpui-window`, then `just plat48-gpui-window-record` —
## `ci/test/plat48_gpui_window.py` says what every frame is). This suite
## asserts over the committed measurement, the arrangement PLAT-40/41/44/45/47
## use: a compositor is not a CI dependency, the frames are.
##
## What a step DID is read from which pixels changed and from OCR. The
## window's own report — its session's tick, the ViewModel's highlight index,
## which stack a placed pane joined — is carried under
## `ticksReportedByWindow` / `reportedByWindow`, labelled, and is asserted
## only BESIDE the pixel evidence for the same step, never instead of it. The
## geometry sidecar's rectangles say where to look.
##
## The top-docked document of the last case is WRITTEN BY THE TERMINAL
## (`codetracer-tui` on `calc` in a pty, `1`, `:dock top`), not by the
## capture script.
##
## No mocks: a real window, a real compositor, a real pointer, real OCR, the
## real `calc` recording stepped by a real replay-server.

import std/[json, os, strutils, unittest]

import codetracer_embed
import headless_app/layout_model
import ../app/pane_names

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/plat48-gpui-window.json"
  ExpectedAssertions = 119

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc arr(n: JsonNode): seq[int] =
  for v in n.getElems: result.add v.getInt

suite "PLAT-48: the GPUI window's top bar and auto-hide panels, read from its pixels":

  let rec = parseJson(readFile(repo / Record))

  test "every frame of the capture settled":
    var n = 0
    for k, v in rec["settled"]:
      checkpoint(k)
      ck v.getBool
      inc n
    ck n >= 20

  test "the menu's titles are the shared tree's, drawn in the band":
    let ocr = rec["menuTitlesOcr"].getStr
    let tree = nativeFrontEndMenu("calc")
    for i in tree.visibleChildren():
      checkpoint(tree.children[i].label)
      ck ocr.contains(tree.children[i].label)

  test "a click opens Debug: its popover drawn, Step Over's chord the desktop's":
    let pop = arr(rec["menuOpen"]["popover"])
    let box = arr(rec["menuOpen"]["changedBox"])
    ck rec["menuOpen"]["changed"].getInt > 10_000
    # What changed is the popover (and the title it hangs from), nothing
    # further down the window.
    ck box[0] <= pop[0] and box[0] + box[2] >= pop[0] + pop[2]
    ck box[1] + box[3] <= pop[1] + pop[3] + 40
    ck rec["menuStepOverOcr"].getStr.contains("Step Over")
    ck rec["menuStepOverOcr"].getStr.contains("F10")
    ck rec["menuStepOverShortcut"].getStr == "F10"

  test "the pointer highlights, the keyboard moves on, a click chooses":
    let rep = rec["reportedByWindow"]
    # Hover over Step In: its row repainted (pixels), the ViewModel's
    # highlight on it (the window's report).
    ck rec["menuHover"]["stepInRowChanged"].getInt > 0
    ck rep["menuHoverHighlight"].getInt == 2
    # `Down` then moves the highlight to Step Out — and a pointer that did
    # not move does not take it back.
    ck rec["menuKey"]["stepOutRowChanged"].getInt > 0
    ck rep["menuKeyHighlight"].getInt == 3
    # Choosing Step Over closes the menu (the popover's pixels gone) and
    # moves the debugger.
    ck rec["menuChoose"]["popoverPixelsChanged"].getInt > 10_000
    ck rep["menuClosed"].getBool
    ck rec["ticksReportedByWindow"]["menu-choose"].getInt !=
       rec["ticksReportedByWindow"]["base"].getInt

  test "every control is drawn as the desktop's mark, and clicking it performs it":
    var inked = 0
    for c in TransportControls:
      checkpoint(c.id)
      ck rec["controlMarkInk"].hasKey(c.id)
      if rec["controlMarkInk"].hasKey(c.id) and
         rec["controlMarkInk"][c.id].getInt > 0:
        inc inked
    ck inked == TransportControls.len
    var seen: seq[string] = @[]
    for click in rec["controlClicks"]:
      let id = click["id"].getStr
      let before = click["before"].getInt
      let after = click["after"].getInt
      checkpoint(id & ": " & $before & " -> " & $after)
      seen.add id
      # Every click moved the debugger, and in the direction it names.
      ck after != before
      if id.startsWith("reverse-"):
        ck after < before
      elif id == "run-to-entry":
        ck after == 0
      else:
        ck after > before
    for c in TransportControls:
      ck c.id in seen

  test "a hovered control names itself and its chord":
    let ocr = rec["controlHoverOcr"].getStr
    ck ocr.contains("Next")
    ck ocr.contains("F10")

  test "the omnibar: a tick query goes there, :sym lists the program's functions":
    ck rec["ticksReportedByWindow"]["omni-tick"].getInt == 42
    # The query as drawn in the field, and the first result as drawn.
    ck rec["omnibarQueryOcr"].getStr.contains(":sym add")
    ck rec["omnibarSymOcr"].getStr.startsWith("add")
    let rep = rec["reportedByWindow"]
    ck rep["omnibarQuery"].getStr == ":sym add"
    ck rep["omnibarSymResults"].len >= 1
    ck rep["omnibarSymResults"][0].getStr == "add"

  test "the footer strip is the shared default's docked panes":
    let ocr = rec["footerOcr"].getStr
    for d in sharedDefaultDocked():
      checkpoint(d.title)
      ck ocr.contains(d.title)

  test "a click reveals the pane itself as an overlay; Esc restores every pixel":
    let rect = arr(rec["revealBottom"]["rect"])
    ck rect[2] > 0 and rect[3] > 0
    # An overlay: nothing outside it (and the strip that marks it) moved —
    # the tree did not reflow.
    ck rec["revealBottom"]["changedOutside"].getInt == 0
    # The pane's own content under its title, and the Unpin button.
    let ocr = rec["revealBottom"]["ocr"].getStr
    ck ocr.contains("Build Output")
    ck ocr.contains("Unpin")
    ck rec["revealEscChanged"].getInt == 0
    # Ctrl+O reveals the first docked pane from the keyboard: its own
    # content over the tree.
    ck rec["keyRevealOcr"].getStr.contains("Build Output")
    ck rec["reportedByWindow"]["keyReveal"].getStr == "buildOutput"

  test "pin docks the pane, unpin puts it back where it was":
    # Pinned: its label is drawn in the footer strip.
    ck rec["pinnedFooterOcr"].getStr.contains("State")
    # Unpinned: gone from the footer, drawn as a tab again — into the stack
    # it was pinned from, beside Scratchpad as in the shared default, not
    # appended to the root.
    ck not rec["unpinnedFooterOcr"].getStr.contains("State")
    let tabs = rec["unpinnedTabsOcr"].getStr
    ck tabs.contains("State") and tabs.contains("Scratchpad")
    let rep = rec["reportedByWindow"]
    ck rep["pinnedDocked"].getBool and rep["unpinnedPlaced"].getBool
    var stack: seq[string] = @[]
    for p in rep["unpinnedStack"]: stack.add p.getStr
    ck "state" in stack and "scratchpad" in stack

  test "the TOP edge: a drag docks there, the strip reveals, Esc restores, a drag back":
    let rep = rec["reportedByWindow"]
    ck rec["topStrip"]["ocr"].getStr.contains("State")
    ck rep["topDocked"].getBool
    # The reveal from the top is the pane's own content, and nothing outside
    # it moved; Esc restores every pixel.
    ck rec["topReveal"]["ocr"].getStr.contains("State")
    ck rep["topRevealPane"].getStr == "state"
    ck rec["topReveal"]["changedOutside"].getInt == 0
    ck rec["topEscChanged"].getInt == 0
    ck rep["topBackPlaced"].getBool

  test "a layout document the TERMINAL saved with a top-docked pane opens with its top strip":
    # The terminal's document docks exactly one pane at the top, and the
    # window's top strip draws that pane's name.
    let docked = rec["docTop"]["terminalTopDocked"]
    ck docked.len == 1
    var kind = paneEditor
    var known = false
    for k in PaneKind:
      if $k == docked[0].getStr:
        kind = k
        known = true
    ck known
    checkpoint("terminal docked " & docked[0].getStr & " (" &
               gpuiPaneName(kind) & ")")
    ck rec["docTop"]["ocr"].getStr.contains(gpuiPaneName(kind))
    ck rec["reportedByWindow"]["docTopSlots"].len == 1
    ck rec["reportedByWindow"]["docTopSlots"][0].getStr == docked[0].getStr

  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
