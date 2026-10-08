## test_plat47_gpui_window.nim — PLAT-47 part B, **the GPUI window read from
## its own pixels**: the editor painted from the one editor theme (B1), the
## focus border and the bold active tab drawn (B2), the call trace scrolled
## to its end by the wheel (B3), the VCS pane (deliverable 4) and its
## refresh on the desktop's interval, a divider drag (deliverable 5), the four
## drop indications (deliverable 6), a pane docked by a drop that stays on
## screen as a strip label and is revealed and hidden from it, and editor
## rows a full line high (the descenders drawn).
##
## The record `src/tests/visual/plat47-gpui-window.json` is MEASURED off a
## real window on a headless sway, driven by a real pointer device and a
## real key (`just plat47-gpui-window`, then `just plat47-gpui-window-record`
## — `ci/test/plat47_gpui_window.py` says what every frame is). This suite
## asserts over the committed measurement, the arrangement PLAT-40/41/44/45
## use: a compositor is not a CI dependency, the frames are.
##
## The expected colours are the DESKTOP's, measured by the Electron capture
## (`plat47-desktop-parity.electron.json`), never the constants the window
## paints with. The regions a drop must tint are derived from the window's
## own pixels (the editor's box is its focus ring), and what a drop DID is
## read from which pixels changed.
##
## No mocks: a real window, a real compositor, a real pointer, real OCR.

import std/[algorithm, json, os, sequtils, strutils, unittest]

import gpui/window_top_bar   # `GpuiTopBandPx`: the band above the layout (PLAT-48)
from gpui/window_geometry import TabStripPx, FooterPx
  # the pane's tab strip, and the window's footer (PLAT-49 part B)

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/plat47-gpui-window.json"
  Desktop = "src/tests/visual/answers/plat47-desktop-parity.electron.json"
  ExpectedAssertions = 103
    ## PLAT-50: +1, the docked reveal is read by the span of its change.
  GhostBoxPx = 160 * 32
  EditorRowPx = 26
    ## One editor row's pitch in the window (`window_geometry.GpuiEditorRowPx`).
  PanePaddingPx = 12
    ## The pane's own padding in the window: the code column's right edge is
    ## the editor's box minus its 1px border minus this.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc arr(n: JsonNode): seq[int] =
  for v in n.getElems: result.add v.getInt

suite "PLAT-47 part B: the GPUI window, read from its pixels":

  let rec = parseJson(readFile(repo / Record))
  let desk = parseJson(readFile(repo / Desktop))

  test "every frame of the capture settled":
    var n = 0
    for k, v in rec["settled"]:
      checkpoint(k)
      ck v.getBool
      inc n
    ck n == 19

  test "B2: the focused pane is closed in a 1px border of the desktop's outline colour":
    ck desk["focus"]["outline"].getStr == "#565656"
    let ring = rec["focusRing"]
    ck ring["bbox"].kind == JArray
    for side in ["top", "bottom", "left", "right"]:
      let s = ring["sides"][side]
      checkpoint(side & ": " & $s)
      # Every pixel of the side is the outline colour, and the pixel one in
      # is not: exactly one pixel wide, closed.
      ck s["ring"].getInt == s["of"].getInt and s["of"].getInt > 100
      ck s["inside"].getInt == 0

  test "B2: the active tab is drawn heavier than the same label inactive":
    for pane in ["fileTree", "vcs"]:
      let t = rec["tabs"][pane]
      let (activeKey, inactiveKey) =
        if pane == "fileTree": ("base", "vcs") else: ("vcs", "base")
      let a = t[activeKey]["mass"].getFloat
      let i = t[inactiveKey]["mass"].getFloat
      checkpoint(pane & ": active " & $a & " inactive " & $i)
      # Ink normalised by each label's own colour: the weight, not the tier.
      ck a > 1.4 * i
      ck t[activeKey]["ink"].getStr != t[inactiveKey]["ink"].getStr

  test "B1: the editor's ground and every token class are the desktop's colours":
    let px = rec["editor"]["pixelsByDesktopColour"]
    checkpoint($px)
    let body = arr(rec["editor"]["body"])
    # The ground IS the ground: most of the body is exactly the desktop's.
    ck px["ground"].getInt > body[2] * body[3] div 2
    for cls in ["keyword", "string", "comment", "identifier", "lineNumber"]:
      ck px[cls].getInt > 20
    # The active line's NUMBER only (PLAT-51: the execution mark is the
    # desktop's arrow in its own colour now, not a glyph in the number's).
    ck px["activeLineNumber"].getInt > 5
    # Punctuation is thin; that its colour is painted at all is the claim.
    ck px["delimiter"].getInt > 0
    # And the colours that were painted there before PLAT-47 B1 are gone.
    ck px["oldBand4f4f4f"].getInt == 0
    ck px["chromePaneFill"].getInt == 0

  test "B1: the execution band is Monaco's — the code column to the right edge, not the gutter":
    let b = rec["band"]
    checkpoint($b)
    ck b["rows"].kind == JArray
    let rows = arr(b["rows"])
    # ONE FULL TEXT ROW: 26 px at the window's text size. Squeezed rows (the
    # fetch window holding more lines than the pane shows) were 18.
    ck rows[1] - rows[0] + 1 >= EditorRowPx - 2
    # It starts right of the line number it belongs to…
    ck b["startX"].getInt > b["activeNumberMaxX"].getInt
    ck b["gutterAtBandRow"].getStr == desk["editor"]["background"].getStr
    # …and runs to the code column's right edge.
    ck b["endX"].getInt == b["bodyRight"].getInt - PanePaddingPx

  test "deliverable 5: a divider dragged 80 px moves the pane edge 80 px, live and committed":
    let r = rec["resize"]
    checkpoint($r)
    let before = r["baseRingLeft"].getInt
    ck r["liveRingLeft"].getInt - before == 80
    ck r["doneRingLeft"].getInt - before == 80
    # A press that is not on a divider resizes nothing.
    ck r["pressBodyRingLeft"].getInt == r["doneRingLeft"].getInt
    # (PLAT-51: the press places the read-only editor's CARET — a bar one
    # cell wide at most; nothing else changes.)
    let caretOnly =
      r["pressBodyChanged"].getInt == 0 or
      (arr(r["pressBodyChangedBox"])[2] <= 12 and
       arr(r["pressBodyChangedBox"])[3] <= EditorRowPx + 2)
    ck caretOnly
    # The layout document the window wrote carries the new weight: the Files
    # column's share grew by 80 px of the row's extent (the shared default
    # gives it 20).
    let saved = r["savedLayout"]
    ck saved.kind == JObject
    let files = saved["layout"]["children"][0]
    ck files["children"][0]["pane"].getStr == "fileTree"
    let frameW = rec["frame"][0].getInt
    let extent = frameW - 2 * PanePaddingPx - 2 * 8
    let want = 20.0 + 100.0 * 80.0 / float(extent)
    checkpoint("files weight " & $files["weight"].getFloat & " want " & $want)
    ck abs(files["weight"].getFloat - want) < 0.2

  test "deliverable 6: each drop kind tints exactly its region, and the ghost follows the pointer":
    let d = rec["drop"]
    let pane = arr(d["editorBody"])
    # The tint is the pane's CONTENT, below its tab strip (PLAT-49 part B:
    # GoldenLayout highlights half of a stack's content area).
    let body = @[pane[0], pane[1] + TabStripPx, pane[2], pane[3] - TabStripPx]
    let half = (body[2] + 1) div 2
    # SPLIT on the editor's right edge band: its right half.
    let split = arr(d["drop-split"]["tintBBox"])
    checkpoint("split " & $split & " body " & $body)
    ck split == @[body[0] + body[2] - half, body[1], half, body[3]]
    ck d["drop-split"]["changedPixels"].getInt == half * body[3]
    # WHOLE PANE over the editor's centre: all of it.
    ck arr(d["drop-whole"]["tintBBox"]) == body
    # Every pixel of it changed, bar the ghost label's own box (the record
    # leaves the 160x32 box beside the pointer out of the tint's count).
    ck d["drop-whole"]["changedPixels"].getInt >= body[2] * body[3] - GhostBoxPx
    ck d["drop-whole"]["changedPixels"].getInt <= body[2] * body[3]
    # TAB SLOT over the Call Trace stack's second tab: its strip, one row of
    # tabs tall, at the top of that stack — nothing below the strip.
    let slot = arr(d["drop-slot"]["tintBBox"])
    let slotPtr = arr(d["pointers"]["drop-slot"])
    checkpoint("slot " & $slot)
    ck slot[1] <= slotPtr[1] and slot[1] + slot[3] > slotPtr[1]
    ck slot[3] <= 32
    ck slot[0] <= slotPtr[0] and slot[0] + slot[2] >= slotPtr[0]
    ck d["drop-slot"]["changedPixels"].getInt <= slot[2] * slot[3]
    # DOCK EDGE in the left margin: a band along the layout's left edge, the
    # layout's whole height.
    let dock = arr(d["drop-dock"]["tintBBox"])
    checkpoint("dock " & $dock)
    ck dock[0] == PanePaddingPx and dock[2] < 100
    # The layout's whole height: the window less its padding and, since
    # PLAT-48, the top bar's band above the layout and, since PLAT-49, the
    # footer (the status bar holding the bottom labels) below it.
    ck dock[3] >= rec["frame"][1].getInt - 2 * PanePaddingPx - GpuiTopBandPx -
                  FooterPx
    # The ghost label was drawn beside the pointer in every one.
    for k in ["drop-split", "drop-whole", "drop-slot", "drop-dock"]:
      ck d[k]["ghostChangedPixels"].getInt > 100

  test "deliverable 6: Esc cancels — every pixel back — and a release then does nothing":
    let d = rec["drop"]
    ck d["cancelChangedPixels"].getInt == 0
    ck d["releasedChangedPixels"].getInt == 0

  test "deliverable 6: a release performs the indicated split":
    let d = rec["drop"]
    let body = arr(d["editorBody"])
    let ring = arr(d["commitRing"])
    checkpoint("commit ring " & $ring & " body " & $body)
    # The editor keeps its left edge and gives up its right half to the
    # dragged pane.
    ck ring[0] == body[0] - 1
    ck abs((ring[2] - 2) - body[2] div 2) <= 8
    var stateRight = false
    for n in d["commitArrangement"]:
      if n["panes"].getElems.len == 1 and n["panes"][0].getStr == "state":
        let r = arr(n["rect"])
        stateRight = r[0] > ring[0] + ring[2] - 1 and
                     r[0] < body[0] + body[2]
    ck stateRight

  test "deliverable 4: the VCS pane shows the branch and the three changed files":
    let text = rec["vcs"]["text"].getStr
    checkpoint(text)
    ck rec["vcs"]["active"].getStr == "vcs"
    for line in ["plat47-vcs", "Working Tree (3)", "A added.txt",
                 "M notes.txt", "? scratch.txt"]:
      ck line in text

  test "the editor's rows are whole lines: the descenders are drawn":
    # `python3` on `calc`'s first line OCR'd as `nvthon3` while the rows were
    # squeezed (the p and y cut off at the baseline).
    let text = rec["editor"]["text"].getStr
    checkpoint(text)
    ck "python3" in text

  test "deliverable 4: the VCS pane refreshes on the desktop's interval, with no input":
    let r = rec["vcsRefresh"]
    let text = r["text"].getStr
    checkpoint(text)
    # A file another program wrote while the window was open is listed, the
    # count moved with it, and the refresh redrew the pane once.
    ck "? late.txt" in text
    ck "Working Tree (4)" in text
    ck r["refreshes"].getInt == 1
    # What changed on screen is inside the VCS pane.
    let bb = arr(r["changedBBox"])
    let pane = arr(r["paneBody"])
    ck r["changedPixels"].getInt > 0
    ck bb[0] >= pane[0] and bb[1] >= pane[1] and
       bb[0] + bb[2] <= pane[0] + pane[2] and bb[1] + bb[3] <= pane[1] + pane[3]

  test "a pane docked by a drop stays on screen: a strip label, revealed by a hover, hidden by Esc":
    let d = rec["dock"]
    checkpoint($d["strips"])
    # Docked: out of the tree, one label in the left strip, and the saved
    # document says so. (Since PLAT-48 the shared default's footer panels
    # are a bottom strip beside it, and the saved document docks them too.)
    ck "state" notin d["treePanes"].getElems.mapIt(it.getStr)
    var edges: seq[string] = @[]
    var leftSlots: seq[string] = @[]
    for st in d["strips"]:
      edges.add st["edge"].getStr
      if st["edge"].getStr == "left":
        for sl in st["slots"]: leftSlots.add sl["pane"].getStr
    edges.sort()
    ck edges == @["bottom", "left"]
    ck leftSlots == @["state"]
    var savedEdge = ""
    for e in d["savedLayout"]["docked"]:
      if e["pane"].getStr == "state": savedEdge = e["edge"].getStr
    ck savedEdge == "left"
    # The strip is drawn, with its label's ink on it, reading down.
    ck d["stripInk"].getInt > 50
    ck d["slotText"].getStr.splitWhitespace().join("").contains("tate")
    # The pointer resting on the label (PLAT-49 part B, the desktop's
    # preview; a click docks it open) draws the pane over the tree, against the left
    # edge: the pixels that changed are the revealed region (and the label's
    # own weight), and the pane's own text is in it.
    ck d["revealed"]["pane"].getStr == "state"
    let rr = arr(d["revealed"]["rect"])
    let bb = arr(d["revealChangedBBox"])
    checkpoint("reveal " & $rr & " changed " & $bb)
    ck bb[0] + bb[2] <= rr[0] + rr[2] + 1 and bb[1] >= rr[1] and
       bb[1] + bb[3] <= rr[1] + rr[3]
    # PLAT-50: the revealed pane and the editor under it are both
    # ui/surface/base/panel now (the window's colours are the desktop's
    # tokens), so the pixels that change are the TEXT, not a whole new
    # ground: what proves the pane is drawn over the region is that the
    # change spans it — most of its width and of its height — not a
    # pixel count that assumed two grounds.
    ck d["revealChangedPixels"].getInt > 0
    ck bb[2] >= rr[2] * 3 div 4 and bb[3] >= rr[3] div 2
    ck "Locals" in d["revealText"].getStr
    # Esc: every pixel back — the reveal never touched the arrangement.
    ck d["dismissChangedPixels"].getInt == 0

  test "B3: the wheel scrolls the call trace to its end, paging it in sections":
    let c = rec["calltrace"]
    checkpoint(c["endText"].getStr)
    # (The pane's heading counted the whole trace — `603 call(s)` — until
    # PLAT-49 removed in-pane headings; the tab strip names the pane.)
    ck "leaf #602" in c["endText"].getStr
    ck "leaf #602" notin c["baseText"].getStr
    ck c["sectionLoads"].getInt > 1

suite "assertion tally":
  test "count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
