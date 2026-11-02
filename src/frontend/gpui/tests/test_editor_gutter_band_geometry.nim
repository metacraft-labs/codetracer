## The rendered GPUI gutter must consume the shared band map. No mock renderer:
## this reads the tree emitted by app/leaves through the real isonim-gpui shim.
## The textual gutter's three runs remain an accessibility/reader format; they
## must not become a second definition of the element geometry. These checks
## inspect styles and ownership in the tree, not frame-level pixel parity.

import std/[json, sequtils, strutils, unittest]
import isonim_gpui/[renderer, bindings]
import ../app/leaves
import ../chrome
import ../../view_vocabulary/pane_views
import ../../viewmodel/viewmodels/editor_gutter_lanes

const BandAttribute = "data-ct-gutter-band"

proc nodesWith(n: JsonNode; attr: string): seq[JsonNode] =
  if n{"attributes"}{attr}.getStr.len > 0: result.add n
  for c in n{"children"}.getElems:
    result.add nodesWith(c, attr)

proc style(n: JsonNode; key: string): string =
  # The shim serializes normalized GPUI names, not the input CSS spelling.
  let normalized = case key
    of "width": "w"
    of "height": "h"
    else: key.replace("-", "_")
  n{"styles"}{normalized}.getStr

proc draw(mark: EditorMark; sticky = false): JsonNode =
  gpui_reset_tree()
  var r: GpuiRenderer
  let root = r.createElement("div")
  var surface = editorSurfaceForProject("example.py", "def f():\n  pass\n",
                                         GpuiMedium, false)
  surface.rows[0].mark = mark
  surface.rows[0].pointer = eptExecution
  let headers = if sticky: @[(line: 1, text: "def f():", top: 0)] else: @[]
  discard renderEditor(r, root, sourcePaneView(GpuiMedium).root, surface, 800,
                       sticky = headers)
  parseJson(renderPlanJson(r, root))

suite "GPUI editor gutter tree follows the shared band map":
  test "every row reserves every band in map order and width":
    let expected = resolveBands(CodeFontPx, EditorGutterPx)
    for mark in EditorMark:
      let plan = draw(mark)
      let rows = nodesWith(plan, EditorRowAttribute)
      check rows.len > 0
      for row in rows:
        let children = row{"children"}.getElems
        check children.len >= 2
        let gutter = children[0]
        check gutter.style("display") == "flex"
        check gutter.style("width") == $EditorGutterPx & "px"
        check children[1]{"attributes"}{EditorCodeColumnAttribute}.getStr == "true"
        let bands = nodesWith(row, BandAttribute)
        check bands.len == expected.len
        check bands.mapIt(it{"attributes"}{BandAttribute}.getStr) ==
              expected.mapIt($it.band)
        if bands.len != expected.len: continue
        check gutter{"children"}.getElems == bands
        var edge = 0
        for i, band in expected:
          checkpoint $mark & " " & $band.band
          check edge == band.leftPx
          check bands[i].style("width") == $(band.rightPx - band.leftPx) & "px"
          check bands[i].style("flex-shrink") == "0"
          check bands[i].style("height") == $EditorLinePx & "px"
          check bands[i].style("position") != "absolute"
          check bands[i].style("padding-left") in ["", "0px"]
          edge += parseInt(bands[i].style("width").replace("px", ""))
        check edge == EditorGutterPx

  test "marks occupy their owner band and folding occupies its own band":
    for mark in EditorMark:
      let plan = draw(mark)
      let bands = nodesWith(plan, BandAttribute)
      let discs = nodesWith(plan, "data-ct-mark-glyph")
      check discs.len == (if mark == emNone: 0 else: 1)
      var folds = 0
      var ownedDiscs = 0
      for band in bands:
        let owner = band{"attributes"}{BandAttribute}.getStr
        if owner == $gcBreakpoint.bandFor:
          check band.style("position") == "relative"
          let bandWidth = parseFloat(band.style("width").replace("px", ""))
          for disc in nodesWith(band, "data-ct-mark-glyph"):
            inc ownedDiscs
            check disc in discs
            check disc.style("position") == "absolute"
            check disc.style("left") == (if mark == emTracepoint: "11px" else: "0px")
            let left = parseFloat(disc.style("left").replace("px", ""))
            let width = parseFloat(disc.style("width").replace("px", ""))
            check left >= 0
            check left + width <= bandWidth
            let top = parseFloat(disc.style("top").replace("px", ""))
            let height = parseFloat(disc.style("height").replace("px", ""))
            check top + height / 2 == float(EditorLinePx) / 2
        else:
          check nodesWith(band, "data-ct-mark-glyph").len == 0
        for fold in nodesWith(band, "data-ct-fold"):
          if fold{"attributes"}{"data-ct-fold"}.getStr == "expanded":
            inc folds
            check owner == $gcFoldingChevron.bandFor
            check fold.style("width") == $gbFolding.widthPx(CodeFontPx) & "px"
            check band.style("position") == "relative"
            let holders = band{"children"}.getElems
            check holders.len == 1
            for holder in holders:
              check holder.style("position") == "absolute"
              check holder.style("left") == "0px"
              let left = parseFloat(holder.style("left").replace("px", ""))
              let width = parseFloat(holder.style("width").replace("px", ""))
              let bandWidth = parseFloat(band.style("width").replace("px", ""))
              check left >= 0
              check left + width <= bandWidth
              let top = parseFloat(holder.style("top").replace("px", ""))
              let height = parseFloat(holder.style("height").replace("px", ""))
              # Preserve the ordinary icon's center before it was fitted to
              # the narrower band: a 14 px box, 3 px below the row's top.
              check top + height / 2 == 10.0
      check folds > 0
      check ownedDiscs == discs.len

  test "sticky folding keeps its separate overlay":
    let plan = draw(emBreakpoint, sticky = true)
    let rows = nodesWith(plan, "data-ct-sticky-line")
    check rows.len == 1
    for row in rows:
      let gutter = row{"children"}[0]
      check gutter.style("width") == $EditorGutterPx & "px"
      check nodesWith(gutter, BandAttribute).len == ord(high(GutterBand)) + 1
      let overlays = gutter{"children"}.getElems.filterIt(
        it.style("position") == "absolute")
      check overlays.len == 1
      for overlay in overlays:
        check overlay.style("left") == $StickyFoldX & "px"
        check nodesWith(overlay, "data-ct-fold").len == 1
