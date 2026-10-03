## test_plat35_editor_scrollbar.nim — **TIER 3 OVER THE EDITOR'S HORIZONTAL
## SCROLLBAR: `PLAT35-F3`.**
##
## Run (needs the real `isonim-gpui` shim at the baked path, like every suite
## that imports `app/leaves`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat35_editor_scrollbar.nim
##
## ## The finding, and why it is asserted here rather than read
##
## `PLAT35-F3`: *"the editor clips a source line mid-token at the pane's
## right edge with no ellipsis, no wrap and no horizontal scrollbar, so the
## rest of the statement is unrecoverable."* Measured on the frames: 68 of 68
## role-bearing nodes at 1920x1080 and 54 of 54 at 1440x900 carried
## `nowrap; overflow: hidden` with no `text_overflow`, no node anywhere was a
## scrollbar, and readers quoted `value = evaluate`, `results.append(v`,
## `operation = OPERATIONS`.
##
## `codetracer-specs/spec/Methodologies/visual-design-iteration.md` tier 3:
## *"these are assertions, not comparisons, so they need no baseline and
## cannot drift. That makes them the most durable checks in the stack, and
## they should carry as much of the load as possible."* All three halves of
## this finding are expressible structurally and are here: **a scrollbar node
## exists**, **its metric**, and **whether the clipped text is reachable**.
##
## ## THE LEDGER'S ATTRIBUTION OF THIS FINDING WAS WRONG, AND THAT IS WHY IT
## ## SAT OPEN
##
## `tier4-gpui-readings.json` called `PLAT35-F3` *"the GPUI twin of
## PLAT35-PD1 … one decision for both front-ends"*, which parked it behind a
## cross-front-end decision nobody owned. Read off the spec, that is false:
##
##   * `Cross-Renderer-Visual-Alignment.md`'s `PLAT35-PD1` row is about **the
##     state and call-trace panes** — *"at 1440x900 the state and call-trace
##     panes AMPUTATE text … the value text has neither an ellipsis nor a
##     horizontal scrollbar"*. Not the editor.
##   * The same document's §4.1 reads the **Electron editor's** horizontal
##     scrollbar off the live DOM at every probed run: *"the content height
##     passes through — 2574 for the lines, 2586 with the horizontal
##     scrollbar, 2607 with the view zone"*, and *"it is not a race with the
##     horizontal scrollbar — its 12px is in the content height of every
##     probed run"*.
##
## So the reference is RIGHT here and this front-end did not match it, which
## `tools/visual-review-brief.md` settles: *"The Electron front-end is the
## reference. Where the reference is wrong, that is a change to the Electron
## front-end and to the design system — never a licence for the GPUI
## front-end to differ."* The remedy is a horizontal scrollbar. No ellipsis
## and no wrap, which the last case holds in place.
##
## ## What each case would be satisfied by if it stood alone
##
## Stated because an assertion that cannot fail is the defect this campaign
## is about, and most of these need a partner:
##
##   1. *a scrollbar node exists* — satisfied by a node drawn on every frame
##      whatever the content, which is Verification-Harness-Traps §7. So the
##      absence case draws a surface that FITS and requires the node not to
##      exist, and the threshold case walks the pane width across the exact
##      pixel where the content stops fitting and requires the node to appear
##      there and nowhere else.
##   2. *the scrollbar is 12 px* — satisfied by any literal somebody typed.
##      So the metric is read at run time out of the REFERENCE's own bundled
##      source (`monaco-editor`'s `editorOptions.js`) and the case FAILS, not
##      skips, if that file cannot be read.
##   3. *a thumb exists* — satisfied by a zero-width one. So its width is
##      asserted against Monaco's own slider formula, against the 20 px floor
##      Monaco declares, and as a MONOTONE function of the content width, so
##      a constant cannot pass.
##   4. *the clipped text is reachable* — satisfied by a scrollbar that
##      scrolls nothing. So the widest line's last column is required to be
##      OUTSIDE the pane at rest and INSIDE it at the last scroll position,
##      and every column between is required to move by exactly one, read
##      off the drawn plan's TEXT rather than out of the model. (The first
##      draft of that case asked whether the tail was in the plan at all and
##      went red: the text is emitted in full and the CLIP is the shim's
##      flex layout, which the tree does not record. The case says so.)
##
## ## The one thing this suite does NOT assert
##
## Pixels. Nothing here opens a window. The frame-level reading is the
## capture lane's (`ci/test/plat35-gpui-capture.sh`) and the tier-4 ledger's.
##
## And the wheel BINDING — `main.windowPointer`'s `gekWheel` arm, and
## `--window-ops`' `hwheel:`. What is graded HERE is the function that arm
## calls and the clamp it delegates, which is where every decision it makes
## lives; **the arm itself is graded in `test_plat48_gpui_plan.nim`**, which
## drives the shipped binary through `--report-window-plan --window-ops=`. The
## first draft of this paragraph said the binding was in `gpui/main.nim`,
## *"which no suite compiles (§7b)"*, and that is FALSE —
## `test_plat35_text_faces.nim` line 63 is `import ../main`. The true
## statement was that nothing ASSERTED over it, and the review that found the
## difference also found the binding's scripted half BROKEN (the `hwheel` op
## was refused by the argument parser's allow-list). That is why the case in
## the other suite exists and why this sentence now names it rather than
## declaring the ground unreachable.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, math, os, strutils, unicode, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings
import gpui/app/leaves
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar
import gpui/app/dock_projection
import view_vocabulary/pane_views

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 352
  Calc = "test-programs/calc/main.py"
    ## The corpus's own program — `scenarios.json`'s recording is a trace of
    ## it — so the widths here are the widths the frames were graded on and
    ## not a fixture written to make a point.
  MonacoOptions =
    "node_modules/monaco-editor/esm/vs/editor/common/config/editorOptions.js"
  MonacoScrollbarState =
    "node_modules/monaco-editor/esm/vs/base/browser/ui/scrollbar/scrollbarState.js"
  Viewports = [(1920, 1080), (1440, 900)]
    ## `scenarios.json`'s two, which are the two the finding was measured at.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

# ---------------------------------------------------------------------------
# Reading the REFERENCE's own numbers, rather than transcribing them
# ---------------------------------------------------------------------------

proc readReference(rel: string): string =
  ## The reference front-end's own bundled source. **Raises rather than
  ## returning ""**: a check whose instrument is missing has to go red, not
  ## quietly pass (Verification-Harness-Traps §4).
  let path = repo / rel
  if not fileExists(path):
    raise newException(IOError,
      "prerequisite missing: " & path & " — the Electron front-end's own " &
      "Monaco bundle is what this suite reads its metrics out of, and a " &
      "transcription here would agree with its own misreading (§30)")
  readFile(path)

proc intAfter(text, needle: string): int =
  ## The integer that follows `needle` in `text`. -1 when the needle is not
  ## there at all, which the caller asserts against rather than defaulting.
  let i = text.find(needle)
  if i < 0: return -1
  var j = i + needle.len
  while j < text.len and text[j] notin {'0' .. '9', '-'}: inc j
  var k = j
  while k < text.len and text[k] in {'0' .. '9'}: inc k
  if k == j: -1 else: parseInt(text[j ..< k])

# ---------------------------------------------------------------------------
# Surfaces
# ---------------------------------------------------------------------------

proc calcSurface(first, last: int): EditorSurface =
  ## A real surface over the corpus's own program.
  editorSurfaceForProject("main.py", readReference(Calc), GpuiMedium, false,
                          viewportTop = first,
                          viewportHeight = last - first + 1)

proc rowsOfWidth(width, count: int): seq[EditorRow] =
  ## `count` held rows whose text is exactly `width` columns wide. For the
  ## threshold sweep, where the point is to put the content width where the
  ## case wants it rather than wherever a file happens to put it.
  for i in 1 .. count:
    result.add EditorRow(line: i, text: repeat('x', width), held: true)

# ---------------------------------------------------------------------------
# Reading the drawn tree
# ---------------------------------------------------------------------------

type Drawn = object
  plan: JsonNode
  pane: GpuiElement

proc draw(surface: EditorSurface; viewportPx, leftCols: int): Drawn =
  gpui_reset_tree()
  var r: GpuiRenderer
  let pane = r.createElement("div")
  discard renderEditor(r, pane, sourcePaneView(GpuiMedium).root, surface,
                       viewportPx, leftCols)
  Drawn(plan: parseJson(renderPlanJson(r, pane)), pane: pane)

proc nodesWith(plan: JsonNode; attr: string): seq[JsonNode] =
  var found: seq[JsonNode] = @[]
  proc walk(n: JsonNode) =
    if n.isNil: return
    let a = n{"attributes"}
    if not a.isNil and a{attr}.getStr.len > 0:
      found.add n
    for c in n{"children"}.getElems: walk(c)
  walk(plan)
  found

proc styleOf(n: JsonNode; key: string): string =
  let s = n{"styles"}
  if s.isNil: "" else: s{key}.getStr

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc codeTextByLine(plan: JsonNode): seq[(int, string)] =
  ## Every drawn row's CODE text, by line number, read out of the plan.
  for row in nodesWith(plan, EditorRowAttribute):
    let line = parseInt(row{"attributes"}[EditorRowAttribute].getStr)
    var code = ""
    for col in nodesWith(row, EditorCodeColumnAttribute):
      code.add textOf(col)
    result.add (line, code)

# ---------------------------------------------------------------------------
# The window's own rectangle
# ---------------------------------------------------------------------------

proc geometryAt(w, h: int): WindowGeometry =
  let layout = initLayout(sharedDefaultLayout().tree)
  let proj = projectDock(layout, DockViewport(width: w, height: h,
                                              dockExtent: 300))
  doAssert proj.status == dpsProjected
  windowGeometryOf(layout, proj.state, w, h, GpuiTopBandPx)

suite "PLAT-35 tier 3 — PLAT35-F3: the editor's horizontal scrollbar":

  test "the metrics are the REFERENCE's own, read out of its Monaco bundle":
    # `tools/visual-review-brief.md`: the Electron front-end is the
    # reference. The desktop editor passes no `scrollbar` bag at all
    # (`ui/editor.nim`'s `createMonacoEditor` for the main editor), so what
    # it gets is Monaco's defaults — and those are these.
    let options = readReference(MonacoOptions)
    ck intAfter(options, "horizontalScrollbarSize: ") == EditorScrollbarPx
    ck EditorScrollbarPx == 12
    # The same 12 px `Cross-Renderer-Visual-Alignment.md` §4.1 measured in
    # the Electron editor's live content height: 2574 for the lines, 2586
    # with the horizontal scrollbar. Two independent readings of one value.
    let state = readReference(MonacoScrollbarState)
    ck intAfter(state, "const MINIMUM_SLIDER_SIZE = ") ==
       EditorScrollbarMinThumbPx
    ck EditorScrollbarMinThumbPx == 20
    # **AND THE VISIBILITY RULE IS THE REFERENCE'S TOO**: `horizontal: 1`
    # in that defaults block is `ScrollbarVisibility.Auto` — shown only when
    # the content does not fit. The comment is in the file beside the value,
    # so the enum is not being guessed at.
    let defaults = options.find("horizontalScrollbarSize: 12")
    ck defaults > 0
    let window = options[max(0, defaults - 400) ..< defaults]
    ck window.contains("horizontal: 1 /* ScrollbarVisibility.Auto */")

  test "NO scrollbar when the content fits — in the model and in the tree":
    # §7's half: an existence check alone is satisfied by a bar drawn on
    # every frame. This is the frame it must not be drawn on.
    let rows = rowsOfWidth(10, 5)
    let scroll = editorHScrollOf(rows, 1, 4000)
    ck not scroll.present
    ck scroll.contentPx < 4000
    ck scroll.maxLeftCols == 0
    let drawn = draw(EditorSurface(medium: GpuiMedium, rows: rows), 4000, 0)
    ck nodesWith(drawn.plan, EditorScrollbarAttribute).len == 0
    ck nodesWith(drawn.plan, EditorScrollbarThumbAttribute).len == 0
    # And the editor still says what its extent WAS, so "fits" and "nobody
    # measured the pane" are different readings (§5a).
    ck getAttribute(drawn.pane, EditorScrollMetricAttribute).contains(
         "viewport=4000")

  test "no scrollbar when no caller supplied a width, and it is not a guess":
    # A default width here would be this front-end inventing a pane size.
    let rows = rowsOfWidth(200, 5)
    ck not editorHScrollOf(rows, 1, 0).present
    let drawn = draw(EditorSurface(medium: GpuiMedium, rows: rows), 0, 0)
    ck nodesWith(drawn.plan, EditorScrollbarAttribute).len == 0
    ck getAttribute(drawn.pane, EditorScrollMetricAttribute).contains(
         "viewport=0")

  test "it appears at the exact pixel the content stops fitting, both ways":
    # The §7 case. Sweeping the PANE across the threshold rather than
    # asserting one width: a predicate that is constant in either direction
    # fails here, and so does one off by a pixel.
    let rows = rowsOfWidth(40, 3)
    let content = editorHScrollOf(rows, 1, 1).contentPx
    ck content > 0
    for px in (content - 3) .. (content + 3):
      let scroll = editorHScrollOf(rows, 1, px)
      ck scroll.present == (content > px)
      let drawn = draw(EditorSurface(medium: GpuiMedium, rows: rows), px, 0)
      ck (nodesWith(drawn.plan, EditorScrollbarAttribute).len == 1) ==
         (content > px)

  test "exactly one track and exactly one thumb, and the thumb is inside it":
    let drawn = draw(calcSurface(5, 40), 326, 0)
    let tracks = nodesWith(drawn.plan, EditorScrollbarAttribute)
    ck tracks.len == 1
    ck tracks[0]{"attributes"}[EditorScrollbarAttribute].getStr == "horizontal"
    ck nodesWith(drawn.plan, EditorScrollbarThumbAttribute).len == 1
    # Inside the TRACK and not merely in the pane, so a thumb appended beside
    # its track — which would never move with it — fails.
    ck nodesWith(tracks[0], EditorScrollbarThumbAttribute).len == 1

  test "the drawn track is 12 px tall, and so is its thumb":
    # The metric, read off the plan's own styles. Not off the shadow tree:
    # the shim's ABI has `gpui_get_attribute` and no style read-back, so
    # this is the only instrument that can answer it.
    let drawn = draw(calcSurface(5, 40), 326, 0)
    let track = nodesWith(drawn.plan, EditorScrollbarAttribute)[0]
    let thumb = nodesWith(drawn.plan, EditorScrollbarThumbAttribute)[0]
    ck styleOf(track, "h") == $EditorScrollbarPx & "px"
    ck styleOf(thumb, "h") == $EditorScrollbarPx & "px"
    ck styleOf(track, "w") == "326px"
    # AN OVERLAY AT THE PANE'S BOTTOM, as Monaco's is — not a row in the
    # flex column. Appended to the column it was eaten by the pane's own
    # `overflow: hidden` on all three 1440x900 frames (one scanline of it
    # survived in `gutterLanes.png`, against twelve at 1920x1080).
    ck styleOf(track, "position") == "absolute"
    ck styleOf(track, "bottom") == "0px"
    # Inset by the pane's padding, so the track covers exactly the span the
    # rows do. `ChromePaddingPx` and not a literal: `stylePaneBox` adds the
    # same one.
    ck styleOf(track, "left") == $ChromePaddingPx & "px"
    # The thumb is painted and the track is not, which is the reference's
    # own look.
    ck styleOf(thumb, "bg") == EditorScrollbarThumbColour
    ck styleOf(track, "bg") == ""

  test "the thumb's share of the track is the viewport's share of the content":
    # Monaco's own formula (`scrollbarState.js`, `_computeValues`), with
    # `representableSize == visibleSize` because this scrollbar has no
    # arrows. Asserted over a RANGE of content widths, so a constant thumb
    # cannot pass.
    var widths: seq[int] = @[]
    for cols in [40, 60, 80, 120, 200, 400]:
      let scroll = editorHScrollOf(rowsOfWidth(cols, 3), 1, 326)
      ck scroll.present
      ck scroll.thumbPx == min(326, max(EditorScrollbarMinThumbPx,
        int(floor(326.0 * 326.0 / float(scroll.contentPx)))))
      widths.add scroll.thumbPx
    # STRICTLY NARROWER as the content grows, until the floor binds. A thumb
    # that ignored the content would be flat here.
    for i in 1 ..< widths.len:
      ck widths[i] <= widths[i - 1]
    ck widths[0] > widths[^1]
    # And the floor is REACHED rather than merely declared: 4000 columns of
    # content in a 326 px pane is 0.8% of the track, 2 px without it.
    let huge = editorHScrollOf(rowsOfWidth(4000, 3), 1, 326)
    ck huge.thumbPx == EditorScrollbarMinThumbPx
    ck int(floor(326.0 * 326.0 / float(huge.contentPx))) <
       EditorScrollbarMinThumbPx

  test "the scroll is clamped by the model, in both directions":
    let rows = rowsOfWidth(100, 3)
    let rest = editorHScrollOf(rows, 1, 326)
    ck rest.present
    ck rest.maxLeftCols > 0
    ck editorHScrollOf(rows, 1, 326, -5).leftCols == 0
    ck editorHScrollOf(rows, 1, 326, rest.maxLeftCols + 50).leftCols ==
       rest.maxLeftCols
    ck editorHScrollOf(rows, 1, 326, 7).leftCols == 7
    # `maxLeftCols` is exactly the code columns that do not fit, with the
    # gutter's own width taken out of the pane — and the gutter's width is
    # asked of `gutterRuns` rather than recomputed.
    ck rest.gutterCols == gutterText(EditorRow(line: 1), 1).runeLen
    let visibleCode = int(floor(float(326 - columnsPx(rest.gutterCols)) /
                                EditorColumnPx))
    ck rest.maxLeftCols == 100 - visibleCode
    # A pane that holds everything scrolls nowhere.
    ck editorHScrollOf(rows, 1, 4000, 9).leftCols == 0

  test "THE CLIPPED TEXT IS REACHABLE: the last column arrives at the end":
    # The half of this finding that "no ellipsis, no wrap" does not cover.
    # `PLAT35-F3` says the rest of the statement is UNRECOVERABLE; this is
    # what makes it recoverable, read out of the drawn plan's text.
    let surface = calcSurface(5, 40)
    let widest = editorCodeColumns(surface.rows)
    ck widest == 79   # calc's own lines, in the window the frames drew
    let scroll = editorHScrollOf(surface.rows, editorNumberWidth(surface.rows),
                                 326)
    ck scroll.present
    ck scroll.maxLeftCols > 0
    # The widest line, and its last column.
    var widestLine = 0
    var widestText = ""
    for row in surface.rows:
      if row.text.runeLen == widest:
        widestLine = row.line
        widestText = row.text
        break
    ck widestLine > 0
    let tail = widestText.runeSubstr(widest - 8)
    proc codeOf(leftCols: int): string =
      for (line, code) in codeTextByLine(draw(surface, 326, leftCols).plan):
        if line == widestLine: return code
      ""
    # **WHERE THE CLIP IS, SAID EXACTLY, because the first draft of this case
    # asserted the wrong thing and went red for the right reason.** The row's
    # TEXT is drawn in full at rest — `renderEditor` emits every character —
    # and what cuts it off is the pane: the shim's flex layout clips at the
    # pane's edge and nothing in the tree records that. So "is the tail
    # reachable" is not "is the tail in the plan"; it is "does the tail's
    # column fall inside the pane", which is arithmetic over the same two
    # numbers the scrollbar is decided from.
    let visibleCodeCols = int(floor(float(326 - columnsPx(scroll.gutterCols)) /
                                    EditorColumnPx))
    ck codeOf(0) == widestText
    ck visibleCodeCols < widest          # the clip the finding named
    ck scroll.maxLeftCols == widest - visibleCodeCols
    # AT THE LAST SCROLL POSITION the last column is inside the pane, and
    # the head has gone off the left — both read off the DRAWN text.
    let scrolled = codeOf(scroll.maxLeftCols)
    ck scrolled.endsWith(tail)
    ck scrolled.runeLen == widest - scroll.maxLeftCols
    ck scrolled.runeLen <= visibleCodeCols
    ck not scrolled.startsWith(widestText.runeSubstr(0, 4))
    ck scrolled == widestText.runeSubstr(scroll.maxLeftCols)
    # And every intermediate position moves by exactly one column, so the
    # range between the two ends is covered rather than jumped.
    for cols in 0 .. scroll.maxLeftCols:
      ck codeOf(cols).runeLen == widest - cols
    # The GUTTER DOES NOT MOVE — the desktop's line-number margin does not
    # either. A scroll that took the numbers with it would be a different
    # product.
    let atRest = draw(surface, 326, 0).plan
    let atEnd = draw(surface, 326, scroll.maxLeftCols).plan
    proc gutters(plan: JsonNode): seq[string] =
      for run in nodesWith(plan, GutterLaneAttribute): result.add textOf(run)
    ck gutters(atRest) == gutters(atEnd)
    ck gutters(atRest).len > 0

  test "the thumb travels the whole track, and lands flush at the end":
    let surface = calcSurface(5, 40)
    let nw = editorNumberWidth(surface.rows)
    let rest = editorHScrollOf(surface.rows, nw, 326, 0)
    let last = editorHScrollOf(surface.rows, nw, 326, rest.maxLeftCols)
    ck rest.thumbLeftPx == 0
    ck last.thumbLeftPx == last.viewportPx - last.thumbPx
    ck last.thumbLeftPx > 0
    # Monotone in between, so a thumb pinned at one end cannot pass.
    var prev = -1
    for cols in 0 .. rest.maxLeftCols:
      let at = editorHScrollOf(surface.rows, nw, 326, cols)
      ck at.thumbLeftPx >= prev
      prev = at.thumbLeftPx

  test "no ellipsis and no wrap — the remedy is a scrollbar, not either":
    # The reference has neither in its editor, and
    # `editing_core.terminalWrapSettings` turns soft wrap off in every
    # editor this product ships. This is the assertion that stops a later
    # change from "fixing" the clip the other way.
    let drawn = draw(calcSurface(5, 40), 326, 0)
    var rows = 0
    for row in nodesWith(drawn.plan, EditorRowAttribute):
      inc rows
      ck styleOf(row, "white_space") == "nowrap"
      ck styleOf(row, "overflow") == "hidden"
      ck styleOf(row, "text_overflow") == ""
      for col in nodesWith(row, EditorCodeColumnAttribute):
        ck styleOf(col, "text_overflow") == ""
    ck rows == 36

  test "the window's editor rectangle: the pane, less the pane's padding":
    # `editorBodyWidthOf` is what the window hands `renderEditor`, and it has
    # to be the SAME rectangle `editorRowsOf` answers from — a scrollbar
    # deciding against a width the pane does not have is worse than none.
    for (w, h) in Viewports:
      let g = geometryAt(w, h)
      let i = g.tabsNodeOfPane("editor")
      ck i >= 0
      ck editorBodyWidthOf(g) == g.nodes[i].body.w - 2 * ChromePaddingPx
      ck editorBodyWidthOf(g) < g.nodes[i].body.w
      # AND THE CONTENT REALLY DOES NOT FIT AT EITHER VIEWPORT, which is the
      # product claim `PLAT35-F3` made and the reason this suite exists. If
      # a later layout change made the editor wide enough for 88 columns,
      # this goes red and the finding is genuinely closed by the layout
      # instead of by the scrollbar.
      let surface = calcSurface(5, 40)
      let scroll = editorHScrollOf(surface.rows,
                                   editorNumberWidth(surface.rows),
                                   editorBodyWidthOf(g))
      ck scroll.present
      echo "  viewport ", w, "x", h, ": editor body ", g.nodes[i].body.w,
           " px, inner ", editorBodyWidthOf(g), " px, content ",
           scroll.contentPx, " px (", scroll.gutterCols, "+",
           scroll.codeCols, " cols), thumb ", scroll.thumbPx,
           " px, maxLeftCols ", scroll.maxLeftCols

  test "every case ran":
    echo "PLAT35-F3 scrollbar checks: ", CHECKS
    check CHECKS == ExpectedAssertions
