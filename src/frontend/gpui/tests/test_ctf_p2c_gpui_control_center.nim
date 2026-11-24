## CTF-P2c step 4: the GPUI control center and status line gaze mark
## (study §2.4, §2.5, D24, D64-D70), in the story host that mounts them
## (`gpui/agent_harbor/ah_stories.nim`).
##
## * **Two columns, one when narrow**: launching on the left
##   (`launchWidthPx`), the overview on the right; one column below 720px.
## * **The overview** is the waiting sessions in inbox order, each carrying
##   its press and no dot, then the Initiatives panel's own drawing (study
##   D73); an empty fleet says `No initiatives yet.`.
## * **The launch column is the composer's form and send line**; a launch's
##   notice; the new session queued under its initiative.
## * **Presses are routed**: a press on a mode toggle, on a `For` toggle and
##   on a waiting row does what it carries; `Down` and `Enter` walk and open
##   the waiting rows.
## * **The gaze mark**: off draws nothing; tracking and paused draw the eye
##   and the words in the caption role; the pause key and a press pause it.
##   It is as wide and as tall as the web lays it out (the committed layout
##   record `agent-harbor-web-regions.json`, `gaze-mark`, within the layout
##   judge's `PxTolerance`): a 12px eye, the gap and the words at the status
##   bar's 14px. It was drawn with a 14px eye and 12px words, 92px wide where
##   the web's is 102.4px (issue
##   2026-11-24-gpui-omnibox-control-center-and-gaze-captures-fail-the-ctf-p1b-layout-gate).
##
## No mocks: the stories' own viewmodels over the scripted router and action
## source, drawn by the real views through the real isonim-gpui shim.

import std/[json, math, os, sequtils, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
import ../../stories/agent_harbor_control_center_stories
from ../../viewmodel/input/element_press import OperationAttribute
import ../../../tests/visual/agent_harbor/ctf_layout_judge

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc tagged(root: GpuiElement; fact: string): seq[GpuiElement] =
  collect(root, "data-ah-" & fact, result)

proc carrying(root: GpuiElement; operation: string): seq[GpuiElement] =
  var all: seq[GpuiElement]
  collect(root, OperationAttribute, all)
  all.filterIt(getAttribute(it, OperationAttribute) == operation)

proc fact(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc mount(fixture: string; width = 1440; height = 900; mode = dmDark): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-control-center", fixture, width, height, mode)

proc gaze(fixture: string; width = 1440; height = 900): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-status-gaze", fixture, width, height)

suite "CTF-P2c: the GPUI control center":
  test "two columns at laptop, one column below 720px":
    for (w, h, columns) in [(1440, 900, "two"), (1920, 1080, "two"), (360, 900, "one"),
                            (760, 640, "two")]:
      let m = mount("populated", w, h)
      check m.view.fact("columns") == columns
      check m.view.tagged("cc-launch").len == 1
      check m.view.tagged("cc-overview").len == 1
      m.dispose()

  test "the waiting sessions in inbox order, then the Initiatives panel's own drawing":
    let m = mount("populated")
    let overview = m.view.tagged("cc-overview")[0]
    let panels = overview.tagged("surface").filterIt(it.fact("surface") == "agent-harbor-initiatives")
    check panels.len == 1
    # The waiting list first, then the panel (study D73).
    check overview.nthChild(0).fact("waiting-section") == "3"
    check overview.tagged("initiative").len == 4
    let rows = overview.tagged("waiting-session")
    check rows.mapIt(it.fact("waiting-title")) == @[
      "Make calculate_damage safe for masses above u32",
      "Fix the negative-field test that times out on macOS",
      "Write the 0.4 changelog"]
    for row in rows:
      check getAttribute(row, OperationAttribute) == ControlCenterOpenSessionOperation
      check row.tagged("mark").len == 0
    m.dispose()

  test "the launch column is the composer's form and send line; recent launches":
    let m = mount("populated")
    let launch = m.view.tagged("cc-launch")[0]
    check launch.tagged("field-label").mapIt(it.fact("field-label")).anyIt(it == "Repository")
    check launch.tagged("send").len == 1
    check launch.tagged("recent-launch").mapIt(it.fact("recent-launch")) == @[
      "Asteroid fields generated from seeds, end to end",
      "Make the regeneration cap configurable per ship"]
    m.dispose()

  test "launching: the notice, and the new session queued under its initiative":
    let m = mount("launching")
    check m.view.tagged("cc-notice-line")[0].fact("cc-notice-line").startsWith("Started on hub-a")
    check m.view.fact("cc-launch-for") == "Shield model hardening"
    check m.view.tagged("session").anyIt(it.fact("session") == LaunchedSession)
    check not m.view.tagged("waiting-session").anyIt(it.fact("waiting-session") == LaunchedSession)
    m.dispose()

  test "an empty fleet, loading and error":
    let e = mount("empty")
    check e.view.tagged("cc-empty-line")[0].fact("cc-empty-line") == "No initiatives yet."
    check e.view.tagged("initiative").len == 0
    e.dispose()
    let l = mount("loading")
    check l.view.fact("cc-state") == "asLoading"
    check l.view.tagged("waiting-section").len == 0
    l.dispose()
    let x = mount("error")
    check x.view.fact("cc-state") == "asError"
    x.dispose()

  test "a press on a toggle and on a waiting row does what it carries":
    let m = mount("populated")
    fireEvent(m.view.carrying(ControlCenterNewInitiativeOperation)[0], "mousedown")
    check m.center.mode == lmInitiative
    check m.view.fact("cc-mode") == "initiative"
    let shield = m.view.carrying(ControlCenterLaunchForOperation).filterIt(
      getAttribute(it, "data-ah-target") == "shield-hardening")
    fireEvent(shield[0], "mousedown")
    check m.view.fact("cc-launch-for") == "Shield model hardening"
    let row = m.view.carrying(ControlCenterOpenSessionOperation)[1]
    fireEvent(row, "mousedown")
    check m.center.requestedSession.val == getAttribute(row, "data-ah-target")
    m.dispose()

  test "Down and Enter walk and open the waiting rows":
    let m = mount("populated")
    check m.controlCenterKey("Down") == ControlCenterNextOperation
    let first = m.center.waiting[0].item.id
    check m.view.tagged("waiting-focused").filterIt(it.fact("waiting-focused") == "true")
      .mapIt(it.fact("waiting-session")) == @[first]
    check m.controlCenterKey("Enter") == ControlCenterOpenOperation
    check m.center.requestedSession.val == first
    m.dispose()

suite "CTF-P2c: the GPUI gaze mark":
  test "off draws nothing; tracking and paused draw the eye and the words":
    let off = gaze("off")
    check off.view.tagged("gaze-mark").len == 0
    off.dispose()
    for (fixture, glyph, words) in [("tracking", TrackingGlyph, "Gaze"),
                                    ("paused", PausedGlyph, "Gaze paused")]:
      let m = gaze(fixture)
      let mark = m.view.tagged("gaze-mark")
      check mark.len == 1
      check mark[0].fact("gaze-mark") == fixture
      check mark[0].tagged("glyph")[0].fact("glyph") == glyph
      check mark[0].fact("accessible-name") == words
      check mark[0].fact("tooltip").contains("Ctrl+Alt+Y")
      m.dispose()

  test "the pause key and a press pause and resume it":
    let m = gaze("tracking")
    check m.gazeKey("Ctrl+Alt+y") == GazeTogglePauseOperation
    check m.view.tagged("gaze-mark")[0].fact("gaze-mark") == "paused"
    fireEvent(m.view.tagged("gaze-mark")[0], "mousedown")
    check m.view.tagged("gaze-mark")[0].fact("gaze-mark") == "tracking"
    m.dispose()

proc planNodeWith(n: JsonNode; attribute: string): JsonNode =
  ## The first node of a render plan carrying `attribute`.
  let attributes = n{"attributes"}
  if attributes != nil and attributes.kind == JObject and attributes.hasKey(attribute):
    return n
  for c in n{"children"}.getElems:
    let found = planNodeWith(c, attribute)
    if found != nil: return found

proc pxOf(style: string): float =
  ## A `<n>px` style's pixels; NaN (never within a tolerance) for anything else.
  if not style.endsWith("px"):
    checkpoint "not a px style: '" & style & "'"
    return NaN
  parseFloat(style[0 ..< ^2])

suite "CTF-P2c: the GPUI gaze mark has the web's size":
  test "tracking and paused are as wide and as tall as the web record, both sizes and themes":
    let record = loadWebRecord(repoRoot / "src" / "tests" / "visual" /
                               "agent-harbor-web-regions.json")
    var compared = 0
    var problems: seq[string]
    for fixture in ["tracking", "paused"]:
      for (size, w, h) in Sizes:
        for (mode, theme) in [(dmDark, "dark"), (dmLight, "light")]:
          let id = "agent-harbor-status-gaze-" & fixture & "-" & size & "-" & theme
          let web = record{id}{"regions"}{"gaze-mark"}
          if web.isNil:
            problems.add id & ": the web record has no gaze-mark"
            continue
          gpui_reset_tree()
          let m = r.mountAgentHarborStoryGpui("agent-harbor-status-gaze", fixture, w, h, mode)
          let mark = parseJson(renderPlanJson(r, m.root)).planNodeWith("data-ah-gaze-mark")
          m.dispose()
          if mark.isNil:
            problems.add id & ": no gaze mark drawn"
            continue
          inc compared
          # The render plan's own names for the box's width and height.
          for (edge, style) in [("w", "w"), ("h", "h")]:
            let got = pxOf(mark{"styles"}{style}.getStr)
            if not (abs(got - web[edge].getFloat) <= PxTolerance):
              problems.add id & ": " & style & " " & $got & "px, the web's " &
                           $web[edge].getFloat & "px"
    for p in problems: checkpoint p
    check compared == 8
    check problems.len == 0
