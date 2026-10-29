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
## The expected colours are the DESKTOP's, measured by the Electron captures
## (`plat47-desktop-parity.electron.json`, `plat50-desktop.electron.json`),
## never the constants the window paints with. The regions a drop must tint
## are derived from the window's own pixels (the editor's box is its focus
## outline, shown after the first press since the 2026-10-17 redesign) and
## the lifted arrangement the drag draws (PLAT-51: the dragged pane is lifted
## out first), and what a drop DID is read from which pixels changed.
##
## No mocks: a real window, a real compositor, a real pointer, real OCR.

import std/[algorithm, json, os, sequtils, strutils, unittest]

import gpui/window_top_bar   # `GpuiTopBandPx`: the band above the layout (PLAT-48)
import gpui/chrome          # `crFocusOutline` (PLAT-51), the window's edges
from gpui/window_geometry import TabStripPx, FooterPx,
  EditorHScrollBandPx
  # the pane's tab strip, the window's footer (PLAT-49 part B), the editor's
  # row pitch and its horizontal scrollbar's band
from headless_app/golden_layout_hit import GlSideAreaPx
  # GoldenLayout's ground band, where a drop splits the whole layout
from gpui/app/leaves import EditorScrollbarThumbColour, EditorVScrollbarPx
  # the editor's scrollbar thumb (Monaco's `scrollbarSlider.background`, a
  # quoted reference value, not a constant of this window's choosing) and
  # its vertical scrubber's width (Monaco's `verticalScrollbarSize`)

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/plat47-gpui-window.json"
  Desktop = "src/tests/visual/answers/plat47-desktop-parity.electron.json"
  Desktop50 = "src/tests/visual/answers/plat50-desktop.electron.json"
    ## The desktop's tab strip colours (PLAT-50's capture).
  ExpectedAssertions = 133
    ## 104 -> 125 (the Electron-parity redesign, 2026-10-17, re-captured and
    ## measured): three more frames settled (counted per frame); the outline
    ## absent before the first press and drawn on the editor's own box; the
    ## tabs told apart by title colour and bridge; the indent guides' 4f
    ## shaped as guides; the band's start read against a found number; the
    ## drag read against its lifted frame (the lift, the editor's box, the
    ## smaller middle's strip, the slot's strip, the press's focus); the
    ## commit read from the dropped pane's own outline; the dock by the pin,
    ## to the footer, its label in the reveal's reach.
    ## PLAT-50: +1, the docked reveal is read by the span of its change.
    ## 125 -> 130 (2026-10-23, Scrollbar-Scrubbers.md §4.1): B1's band end
    ## reads both halves against the vertical scrubber — the measured row is
    ## a band row, the scrubber lies along the editor's right edge, the end,
    ## the run past it, its colour, and that colour told from the thumb over
    ## the ground (one end check became six).
    ## 130 -> 133: validate capture platform, font and expected pitch before
    ## comparing the band against that capture rather than the test host.
  GhostBoxPx = 160 * 32

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
    # Three frames since the redesign: the first screen before any press,
    # the press on the Variables tab alone, and the drag's lifted frame.
    ck n == 22

  test "B2: the focused pane is closed in a 1px border of the focus colour":
    # The desktop's outline is #6366f1; PLAT-51 made the native focus colour
    # subtler (ui/border/secondary, `crFocusOutline`), which the recorder
    # searches the frame for.
    ck desk["focus"]["outline"].getStr == "#6366f1"
    ck chromeOf(crFocusOutline) == "#3a3a3a"
    let ring = rec["focusRing"]
    # Since 2026-10-17 the outline is an OVERLAY shown after the first press,
    # as the desktop's `.ct-selected-outline`: none on the first screen.
    ck ring["pristine"].kind == JNull
    ck ring["bbox"].kind == JArray
    # After the press on the editor's body it is drawn ON the editor's own
    # box (no frame inset: the panes start at their edge, as GoldenLayout's).
    ck arr(ring["bbox"]) == arr(ring["editorRect"])
    for side in ["top", "bottom", "left", "right"]:
      let s = ring["sides"][side]
      checkpoint(side & ": " & $s)
      # Every pixel of the side is the outline colour (the rounded corners
      # left out): exactly one pixel wide, closed.
      ck s["ring"].getInt == s["of"].getInt and s["of"].getInt > 100
      if side == "top":
        # One in from the top is the focused pane's STRIP, whose ground is
        # the focus colour too (PLAT-51) — the outline is still one pixel,
        # the strip under it is the pane's.
        ck ring["stripGround"].getStr == chromeOf(crFocusOutline)
      else:
        ck s["inside"].getInt == 0

  test "B2: the active tab is told from the same label inactive, as the desktop tells it":
    # The desktop draws no heavier face for the active tab: its TITLE is the
    # label tier (#c8c8c8) where an inactive one is the disabled tier, and
    # the active tab runs on down into its pane's body (`.lm_active`'s
    # bridge) where an inactive one stops above the strip's ground. The same
    # label read active and inactive — before and after the click on VCS —
    # so the difference is not one of letters.
    let strip = parseJson(readFile(repo / Desktop50))["chrome"]["strip"]
    proc grey(h: string): int = parseHexInt(h[1 .. 2])
    for pane in ["fileTree", "vcs"]:
      let t = rec["tabs"][pane]
      let (activeKey, inactiveKey) =
        if pane == "fileTree": ("base", "vcs") else: ("vcs", "base")
      let a = t[activeKey]
      let i = t[inactiveKey]
      checkpoint(pane & ": active " & $a & " inactive " & $i)
      # The title's ink, within an antialiasing step of the desktop's.
      ck abs(grey(a["titleInk"].getStr) - grey(strip["activeTitle"].getStr)) <= 3
      ck abs(grey(i["titleInk"].getStr) - grey(strip["inactiveTitle"].getStr)) <= 3
      # The bridge: the pane's own ground under the active tab, the strip's
      # ground (the window's, behind the tabs) under the inactive one.
      ck a["bridge"].getStr == t["bodyGround"].getStr
      ck a["bridge"].getStr == strip["paneGround"].getStr
      ck i["bridge"].getStr == strip["groundBehindTabs"].getStr

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
    # And the colours that were painted there before PLAT-47 B1 are gone:
    # no row is a band of 4f (the old execution band). 4f is the indent
    # guides' colour now (`editorIndentGuide`), and what is drawn in it is
    # guide-shaped — 1 px wide, a vertical run.
    ck px["oldBand4f4f4f"].getInt == 0
    ck px["indentGuide4f4f4f"].getInt > 20
    ck px["chromePaneFill"].getInt == 0

  test "B1: the execution band is Monaco's — the code column to the right edge, not the gutter":
    let b = rec["band"]
    checkpoint($b)
    ck b["rows"].kind == JArray
    let rows = arr(b["rows"])
    # The pixels were captured on another host. Validate the recorded
    # provenance against Monaco's platform rule, then compare the band with
    # that capture's expected pitch, never the compiling host's pitch.
    let context = rec["captureContext"]
    let platform = context["platform"].getStr
    let fontPx = context["editorFontPx"].getInt
    let pitch = context["editorRowPx"].getInt
    ck platform in ["linux", "darwin", "win32"]
    ck fontPx == CodeFontPx
    ck pitch == int(float(fontPx) * (if platform == "darwin": 1.5 else: 1.35) + 0.5)
    # One full row: squeezed rows (too many fetched lines for the pane)
    # remain red, even when this record is read on a different platform.
    ck rows[1] - rows[0] + 1 == pitch
    # It starts right of the line number it belongs to…
    ck b["activeNumberMaxX"].kind == JInt
    ck b["startX"].getInt > b["activeNumberMaxX"].getInt
    ck b["gutterAtBandRow"].getStr == desk["editor"]["background"].getStr
    # …and runs to the code column's right edge: the editor's, which fills
    # its pane to the edge (`EditorPadSidePx`) — UNDER the vertical scrubber
    # (M73), which is an overlay there as Monaco's is and takes no width
    # from the code column (Scrollbar-Scrubbers.md §4.1). Where the scrubber
    # is shown and its thumb covers the measured row, the thumb is
    # composited over the band: the band's own colour ends at the scrubber's
    # left edge and every pixel from there to the right edge is the thumb
    # over the BAND. A band that stopped at the scrubber would read the
    # thumb over the editor's GROUND there instead; one that stopped short
    # of it, the ground. Everywhere else the band shows to the edge.
    let y = b["row"].getInt
    ck y >= rows[0] and y <= rows[1]
    let vbar = b["vscrollbar"]
    let thumbOver =
      vbar.kind == JObject and vbar["shown"].getBool and
      arr(vbar["thumb"])[1] <= y and
      y < arr(vbar["thumb"])[1] + arr(vbar["thumb"])[3]
    checkpoint("thumb over the measured row: " & $thumbOver)
    # The scrubber's left edge is the WINDOW's stated geometry, and that
    # geometry is held to the spec rather than trusted: a scrubber
    # `EditorVScrollbarPx` wide whose right edge is the editor's own (the
    # box its focus outline closes), not one inset from it.
    let ring = arr(rec["focusRing"]["bbox"])
    let barRect = if thumbOver: arr(vbar["rect"]) else: @[0, 0, 0, 0]
    ck (not thumbOver) or
       (barRect[2] == EditorVScrollbarPx and
        barRect[0] + barRect[2] == ring[0] + ring[2])
    let scrubLeft = barRect[0]
    ck b["endX"].getInt ==
         (if thumbOver: scrubLeft - 1
          else: b["bodyRight"].getInt - EditorPadSidePx)
    let run = b["afterBandRun"].getElems.mapIt(it.getStr)
    ck run.len == (if thumbOver: b["bodyRight"].getInt - scrubLeft + 1 else: 0)
    # The thumb's colour composited over a ground, channel by channel, as
    # the renderer blends a `#rrggbbaa` fill (source-over): the band's, and
    # for contrast the editor ground's. Both grounds are the DESKTOP's
    # measured colours.
    proc rgb(h: string): array[3, int] =
      [parseHexInt(h[1 .. 2]), parseHexInt(h[3 .. 4]), parseHexInt(h[5 .. 6])]
    proc over(ground: string): array[3, float] =
      let t = rgb(EditorScrollbarThumbColour)
      let a = float(parseHexInt(EditorScrollbarThumbColour[7 .. 8])) / 255.0
      let g = rgb(ground)
      for k in 0 .. 2: result[k] = float(g[k]) + (float(t[k]) - float(g[k])) * a
    let overBand = over(desk["editor"]["executionLine"].getStr)
    let overGround = over(desk["editor"]["background"].getStr)
    checkpoint("thumb over band " & $overBand & ", over ground " & $overGround)
    var offColour: seq[string]
    for h in run:
      let c = rgb(h)
      for k in 0 .. 2:
        if abs(float(c[k]) - overBand[k]) > 1.0:
          offColour.add h
          break
    checkpoint("pixels past the band not the thumb over the band: " & $offColour)
    ck offColour.len == 0
    # And the two composites are told apart at that tolerance, so the run's
    # colour does say which of the two the thumb lies over.
    ck (0 .. 2).toSeq.anyIt(abs(overBand[it] - overGround[it]) > 2.0)

  test "deliverable 5: a divider dragged 80 px moves the pane edge 80 px, live and committed":
    let r = rec["resize"]
    checkpoint($r)
    let before = r["baseRingLeft"].getInt
    # Within a pixel: the layout rounds each pane's share as golden-layout
    # does (floored, the leftover pixels to the first panes —
    # `window_geometry.addNode`), as the model's own case allows
    # (`test_plat47_window_gestures`).
    ck abs(r["liveRingLeft"].getInt - before - 80) <= 1
    ck abs(r["doneRingLeft"].getInt - before - 80) <= 1
    # A press that is not on a divider resizes nothing.
    ck r["pressBodyRingLeft"].getInt == r["doneRingLeft"].getInt
    # (PLAT-51: the press places the read-only editor's CARET — a bar one
    # cell wide at most — and, the pointer now over the editor, Monaco shows
    # its horizontal scrollbar in the band along the editor's bottom
    # (`EditorHScrollBandPx`); nothing else changes.)
    let box = if r["pressBodyChanged"].getInt == 0: @[0, 0, 0, 0]
              else: arr(r["pressBodyChangedBox"])
    let editorBottom = arr(rec["focusRing"]["bbox"])[1] +
                       arr(rec["focusRing"]["bbox"])[3]
    let caretOnly =
      r["pressBodyChanged"].getInt == 0 or
      (box[2] <= 12 and box[3] <= rec["captureContext"]["editorRowPx"].getInt + 2) or
      (box[0] >= r["doneRingLeft"].getInt and
       box[1] >= editorBottom - 1 - EditorHScrollBandPx and
       box[1] + box[3] <= editorBottom and box[3] <= EditorHScrollBandPx)
    ck caretOnly
    # The layout document the window wrote carries the new weight: the Files
    # column's share grew by 80 px of the row's extent (the shared default
    # gives it 20).
    let saved = r["savedLayout"]
    ck saved.kind == JObject
    let files = saved["layout"]["children"][0]
    ck files["children"][0]["pane"].getStr == "fileTree"
    # The row's extent: the window less its edges (`WindowEdgePx`) and the
    # two splitters between its three columns (`ChromeGapPx`).
    let frameW = rec["frame"][0].getInt
    let extent = frameW - 2 * WindowEdgePx - 2 * ChromeGapPx
    let want = 20.0 + 100.0 * 80.0 / float(extent)
    checkpoint("files weight " & $files["weight"].getFloat & " want " & $want)
    ck abs(files["weight"].getFloat - want) < 0.2

  test "deliverable 6: each drop kind tints exactly its region, and the ghost follows the pointer":
    let d = rec["drop"]
    # PLAT-51: the drag LIFTS the Variables pane out first and the window is
    # laid out again without it — the lifted frame drew something else
    # (State's column given to the Scratchpad) and nothing indicated. The
    # editor is untouched by the lift: the box its outline closed before the
    # drag is the box the lifted arrangement gives it.
    ck d["liftedChangedPixels"].getInt > 0
    ck "state" notin d["liftedPanes"].getElems.mapIt(it.getStr)
    let pane = arr(d["editorBox"])
    ck pane == arr(d["liftedEditorRect"])
    # The tint is the pane's CONTENT, below its tab strip (PLAT-49 part B:
    # GoldenLayout highlights half of a stack's content area).
    let body = @[pane[0], pane[1] + TabStripPx, pane[2], pane[3] - TabStripPx]
    let half = (body[2] + 1) div 2
    # SPLIT on the editor's right edge band: its right half.
    let split = arr(d["drop-split"]["tintBBox"])
    checkpoint("split " & $split & " body " & $body)
    ck split == @[body[0] + body[2] - half, body[1], half, body[3]]
    ck d["drop-split"]["changedPixels"].getInt == half * body[3]
    # THE SMALLER MIDDLE over the editor's centre (PLAT-51): a join after
    # its one tab, highlighted on its STRIP — `TabStripPx` tall, from its
    # left edge, nothing below it. (GoldenLayout's placeholder caret at the
    # slot runs on past the strip's right end, into the splitter: no wider
    # than the splitter.)
    let whole = arr(d["drop-whole"]["tintBBox"])
    checkpoint("whole " & $whole)
    ck whole[0] == pane[0] and whole[1] == pane[1] and whole[3] == TabStripPx and
       whole[2] >= pane[2] and whole[2] <= pane[2] + ChromeGapPx
    ck d["drop-whole"]["changedPixels"].getInt <= whole[2] * whole[3]
    # TAB SLOT over the Call Trace stack's second tab: its strip, one row of
    # tabs tall, at the top of that stack — nothing below the strip.
    let slot = arr(d["drop-slot"]["tintBBox"])
    let slotPtr = arr(d["pointers"]["drop-slot"])
    let ct = arr(d["liftedRects"]["calltrace"]["strip"])
    checkpoint("slot " & $slot & " strip " & $ct)
    ck slot[1] <= slotPtr[1] and slot[1] + slot[3] > slotPtr[1]
    ck slot[1] == ct[1] and slot[3] == TabStripPx
    # (The tabs moved apart for GoldenLayout's placeholder run on past the
    # stack's right end, into the window's edge: no further than it.)
    ck slot[0] == ct[0] and slot[0] + slot[2] <= ct[0] + ct[2] + WindowEdgePx
    ck slot[0] <= slotPtr[0] and slot[0] + slot[2] >= slotPtr[0]
    ck d["drop-slot"]["changedPixels"].getInt <= slot[2] * slot[3]
    # THE LEFT MARGIN: GoldenLayout's ground band along the layout's left
    # edge (`GlSideAreaPx` wide), the layout's whole height — a split of the
    # whole layout; no drop docks since PLAT-51.
    let dock = arr(d["drop-dock"]["tintBBox"])
    checkpoint("dock " & $dock)
    ck dock[0] == WindowEdgePx and dock[2] == int(GlSideAreaPx)
    # The layout's whole height: the window less the top bar's band above
    # the layout (PLAT-48) and the footer below it (PLAT-49); the layout
    # runs into both with no padding since the redesign.
    ck dock[3] == rec["frame"][1].getInt - GpuiTopBandPx - FooterPx
    # The ghost label was drawn beside the pointer in every one.
    for k in ["drop-split", "drop-whole", "drop-slot", "drop-dock"]:
      ck d[k]["ghostChangedPixels"].getInt > 100

  test "deliverable 6: Esc cancels — every pixel back — and a release then does nothing":
    let d = rec["drop"]
    # The press on the Variables tab focuses that pane (its outline and
    # strip) before any motion: the frame the cancel must restore.
    ck d["pressFocusChangedPixels"].getInt > 0
    ck d["cancelChangedPixels"].getInt == 0
    ck d["releasedChangedPixels"].getInt == 0

  test "deliverable 6: a release performs the indicated split":
    let d = rec["drop"]
    let box = arr(d["editorBox"])
    let ring = arr(d["commitRing"])
    checkpoint("commit ring " & $ring & " editor " & $box)
    # The dropped pane is focused after the drop, so the outline is ITS box:
    # the editor's right half, to the editor's old right edge…
    ck ring[0] > box[0] and ring[0] + ring[2] == box[0] + box[2]
    ck abs(ring[2] - box[2] div 2) <= 8
    # …and the editor keeps its left edge and gives up that half to the
    # dragged pane.
    var editorKept, stateRight = false
    for n in d["commitArrangement"]:
      let r = arr(n["rect"])
      if n["panes"].getElems.len == 1 and n["panes"][0].getStr == "editor":
        editorKept = r[0] == box[0] and r[0] + r[2] < ring[0]
      if n["panes"].getElems.len == 1 and n["panes"][0].getStr == "state":
        stateRight = r == ring
    ck editorKept
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

  test "a pane docked by its pin stays on screen: a footer label, revealed by a hover, hidden by Esc":
    let d = rec["dock"]
    checkpoint($d["strips"])
    # Docked by the tab's pin icon (`.lm_pin_tab`: GoldenLayout docks
    # nothing on a drop since PLAT-51, and the pin docks to the footer): out
    # of the tree, the LAST label in the footer's strip after the shared
    # default's, and the saved document says so.
    ck "state" notin d["treePanes"].getElems.mapIt(it.getStr)
    var edges: seq[string] = @[]
    var bottomSlots: seq[string] = @[]
    for st in d["strips"]:
      edges.add st["edge"].getStr
      if st["edge"].getStr == "bottom":
        for sl in st["slots"]: bottomSlots.add sl["pane"].getStr
    edges.sort()
    ck edges == @["bottom"]
    ck bottomSlots.len >= 2 and bottomSlots[^1] == "state"
    ck d["edge"].getStr == "bottom"
    var savedEdge = ""
    for e in d["savedLayout"]["docked"]:
      if e["pane"].getStr == "state": savedEdge = e["edge"].getStr
    ck savedEdge == "bottom"
    # The label is drawn, its ink on its chip.
    ck d["stripInk"].getInt > 50
    ck d["slotText"].getStr.splitWhitespace().join("").contains("tate")
    # The pointer resting on the label (PLAT-49 part B, the desktop's
    # preview; a click docks it open) draws the pane over the tree, against
    # the bottom edge: the pixels that changed are the revealed region and
    # the label itself (lit while its pane is previewed), and the pane's own
    # text is in it.
    ck d["revealed"]["pane"].getStr == "state"
    let rr = arr(d["revealed"]["rect"])
    let bb = arr(d["revealChangedBBox"])
    var label: seq[int]
    for st in d["strips"]:
      for sl in st["slots"]:
        if sl["pane"].getStr == "state": label = arr(sl["rect"])
    checkpoint("reveal " & $rr & " label " & $label & " changed " & $bb)
    ck label.len == 4
    ck rr[1] + rr[3] == rec["frame"][1].getInt - FooterPx
    let reach = @[min(rr[0], label[0]), min(rr[1], label[1]),
                  max(rr[0] + rr[2], label[0] + label[2]),
                  max(rr[1] + rr[3], label[1] + label[3])]
    ck bb[0] >= reach[0] and bb[1] >= reach[1] and
       bb[0] + bb[2] <= reach[2] + 1 and bb[1] + bb[3] <= reach[3]
    # PLAT-50: the revealed pane and the editor under it are both
    # ui/surface/base/panel (the window's colours are the desktop's
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
