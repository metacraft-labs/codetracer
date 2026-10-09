## test_plat51_dropzones_reference.nim — PLAT-51 deliverable 10: THE
## POINTER-TRACE DIFFERENTIAL (Layout-ViewModel §4.2.2, "How it is proved").
##
## The real Electron app's GoldenLayout 2.6.0 was driven by
## `src/tests/gui/tests/visual/plat51-desktop-capture.spec.ts` ("GoldenLayout's
## drop decisions"): a tab picked up with the real mouse, then a DENSE GRID
## over the layout put through GoldenLayout's own `getArea` and
## `highlightDropZone`, and RECORDED DRAG PATHS walked with the real mouse
## (tab -> header slot, -> another stack's middle, -> its left edge, -> the
## outer band, -> outside the layout), at three window sizes — each sample's
## decision read back from GoldenLayout's own objects: the area's index in
## `_itemAreas`, the stack's `_dropSegment` and `_dropIndex`, and where the one
## placeholder is (`src/tests/visual/answers/plat51-dropzones-<W>x<H>.electron.json`,
## one file per window size).
##
## Here the SAME geometry (what GoldenLayout measured) and the SAME samples, in
## the same order, go through the shared port (`headless_app/golden_layout_hit`)
## and the decisions must be IDENTICAL at every sample:
##
##   * with `centreShare == 0` — GoldenLayout's algorithm, exactly: area,
##     segment, header index and placeholder;
##   * with the product's `NativeCentreShare` — the user's smaller middle that
##     joins: every sample a hover area matches afresh is identical outside
##     the centred box, and inside it the port says `centre` where
##     GoldenLayout says top or bottom — the declared deviation, and nothing
##     else.
##
## No mocks: the answers are the real app's; the subject is the shipped port.

import std/[json, os, strutils, unittest]

import headless_app/layout_interaction

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 16

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  AnswerSizes = ["1400x900", "1100x760", "1720x1020"]
    ## One capture per window size, in the order the capture measured them
    ## (one file would exceed the repository's 500 KB limit on added files).
  AnswersFile = "plat51-dropzones-<W>x<H>.electron.json"

proc answersPath(size: string): string =
  "src" / "tests" / "visual" / "answers" /
    ("plat51-dropzones-" & size & ".electron.json")

proc rectOf(n: JsonNode): GlRect =
  GlRect(x1: n["x1"].getFloat, y1: n["y1"].getFloat,
         x2: n["x2"].getFloat, y2: n["y2"].getFloat)

proc segmentOf(s: string): GlSegment =
  for seg in GlSegment:
    if $seg == s:
      return seg
  segNone

proc geometryOf(g: JsonNode): GlGeometry =
  result = GlGeometry(ground: rectOf(g["ground"]),
                      rootIsStack: g["rootIsStack"].getBool,
                      placeholderPx: g["placeholderPx"].getFloat)
  for s in g["stacks"]:
    var st = GlStack(element: rectOf(s["element"]), header: rectOf(s["header"]),
                     content: rectOf(s["content"]), empty: s["empty"].getBool)
    for t in s["tabs"]:
      st.tabs.add rectOf(t)
    for slot in s{"tabsAt"}.getElems:
      var tabs: seq[GlRect] = @[]
      for t in slot:
        tabs.add rectOf(t)
      st.tabsAt.add tabs
    result.stacks.add st

proc initialState(g: JsonNode; geom: GlGeometry): GlDragState =
  ## GoldenLayout's state when the geometry was read: each stack's segment
  ## and index, and the placeholder.
  result = glDragState(geom)
  for i, s in g["stacks"].getElems:
    result.stacks[i].segment = segmentOf(s{"segment0"}.getStr)
    let idx = s{"dropIndex0"}
    result.stacks[i].dropIndex =
      if idx.isNil or idx.kind != JInt: -1 else: idx.getInt
  result.placeholderStack = g{"phStack0"}.getInt(-1)
  result.placeholderIndex = g{"phIndex0"}.getInt(-1)

proc samplesOf(run: JsonNode): seq[JsonNode] =
  ## The grid, then each path, in the order GoldenLayout saw them.
  for s in run["grid"]:
    result.add s
  for _, path in run["paths"]:
    for s in path:
      result.add s

proc near(a, b: float): bool = abs(a - b) < 1e-6

proc loadAnswers(): JsonNode =
  ## The three captures as ONE document (`runs` in capture order); null when
  ## any of them is missing, so the first case says which to produce.
  var runs = newJArray()
  for size in AnswerSizes:
    let f = answersPath(size)
    if not fileExists(f):
      return newJNull()
    for run in parseJson(readFile(f))["runs"]:
      runs.add run
  %*{"runs": runs}

let answers = loadAnswers()

suite "PLAT-51: GoldenLayout's drop decisions, through the shared port":

  test "the capture is there and measured three window sizes":
    if answers.kind == JNull:
      checkpoint("no " & AnswersFile &
                 " — run `bash scripts/plat51-capture-electron.sh`")
    require answers.kind == JObject
    ck answers["runs"].len == 3

  test "calculateItemAreas: the port lists GoldenLayout's own areas":
    for run in answers["runs"]:
      let geom = geometryOf(run["geometry"])
      let mine = glItemAreas(geom)
      let theirs = run["geometry"]["areas"].getElems
      checkpoint($run["size"] & ": " & $mine.len & " areas, GoldenLayout " &
                 $theirs.len)
      ck mine.len == theirs.len
      var same = 0
      for i in 0 ..< min(mine.len, theirs.len):
        let t = theirs[i]
        if near(mine[i].rect.x1, t["x1"].getFloat) and
           near(mine[i].rect.y1, t["y1"].getFloat) and
           near(mine[i].rect.x2, t["x2"].getFloat) and
           near(mine[i].rect.y2, t["y2"].getFloat) and
           abs(mine[i].surface - t["surface"].getFloat) < 1e-3 and
           (mine[i].kind == gakSide) == (t["side"].getStr.len > 0):
          inc same
        else:
          checkpoint("area " & $i & " differs: " & $mine[i] & " vs " & $t)
      ck same == theirs.len

  test "GoldenLayout's algorithm (no centre): IDENTICAL at every sample":
    var total = 0
    var headerSamples = 0
    var sideSamples = 0
    for run in answers["runs"]:
      let geom = geometryOf(run["geometry"])
      let areas = glItemAreas(geom)
      var st = initialState(run["geometry"], geom)
      var mismatches = 0
      for s in run.samplesOf():
        let x = s["x"].getFloat
        let y = s["y"].getFloat
        if x < 0 and y < 0:
          continue   # a path step GoldenLayout saw no move for
        let at = glAreaAt(areas, x, y)
        discard glPointerStep(geom, areas, st, x, y, 0.0)
        inc total
        var ok = at == s["area"].getInt
        let stack = s["stack"].getInt
        if ok and stack >= 0:
          ok = $st.stacks[stack].segment ==
                 (if s["segment"].getStr.len == 0: "none"
                  else: s["segment"].getStr)
          if ok and st.stacks[stack].segment == segHeader:
            inc headerSamples
            ok = st.stacks[stack].dropIndex == s["dropIndex"].getInt
        elif ok and at >= 0 and areas[at].kind == gakSide:
          inc sideSamples
        if ok:
          ok = st.placeholderStack == s["phStack"].getInt and
               (st.placeholderStack < 0 or
                st.placeholderIndex == s["phIndex"].getInt)
        if not ok:
          inc mismatches
          if mismatches <= 5:
            checkpoint($run["size"] & " (" & $x & ", " & $y & "): GoldenLayout " &
                       $s & "; port area " & $at & " state " & $st)
      checkpoint($run["size"] & ": " & $mismatches & " mismatches")
      ck mismatches == 0
    checkpoint("samples " & $total & ", header " & $headerSamples & ", side " &
               $sideSamples)
    echo "PLAT-51 differential: ", total, " samples identical (header ",
         headerSamples, ", side ", sideSamples, ")"
    ck total > 3000
    ck headerSamples > 50
    ck sideSamples > 50

  test "the product's smaller middle: identical outside the box, centre inside it":
    var identical = 0
    var deviated = 0
    var wrong = 0
    for run in answers["runs"]:
      let geom = geometryOf(run["geometry"])
      let areas = glItemAreas(geom)
      for s in run["grid"]:
        let x = s["x"].getFloat
        let y = s["y"].getFloat
        let at = glAreaAt(areas, x, y)
        if at < 0 or areas[at].kind == gakSide:
          continue
        let stack = areas[at].stack
        let fresh = glStackSegmentAt(geom.stacks[stack], x, y, 0.0)
        if fresh == segNone:
          continue   # a boundary: the decision is the sample before's
        let ours = glStackSegmentAt(geom.stacks[stack], x, y, NativeCentreShare)
        let theirs = segmentOf(s["segment"].getStr)
        if ours == theirs:
          inc identical
        elif ours == segCentre and theirs in {segTop, segBottom}:
          inc deviated
        else:
          inc wrong
          if wrong <= 5:
            checkpoint("(" & $x & ", " & $y & "): ours " & $ours & ", theirs " &
                       $theirs)
    checkpoint("identical " & $identical & ", the centre's deviation " &
               $deviated & ", other " & $wrong)
    echo "PLAT-51 product rules: identical ", identical, ", centre ",
         deviated, ", other ", wrong
    ck wrong == 0
    ck deviated > 50
    ck identical > deviated

suite "PLAT-51: assertion count":
  test "assertion count":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
