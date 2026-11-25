## CTF-P2c step 4: the GPUI control center and status line gaze mark
## (study §2.4, §2.5, D24, D64-D70), in the story host that mounts them
## (`gpui/agent_harbor/ah_stories.nim`).
##
## * **Two columns, one when narrow**: launching on the left
##   (`launchWidthPx`), the overview on the right; one column below 720px.
## * **The overview** is the waiting sessions in inbox order, each carrying
##   its press and no dot, then the Initiatives panel's own drawing (study
##   D73); an empty fleet says `No initiatives yet.`.
## * **The launch column is the composer's form and send line**; a launch
##   in flight locks the form (`Launch` busy, `Launching…`); its notice or
##   its failure; the new session queued under its initiative.
## * **Presses are routed**: a press on a mode toggle, on a `For` toggle and
##   on a waiting row does what it carries; `Down` and `Enter` walk and open
##   the waiting rows.
## * **The gaze mark**: off draws nothing; tracking and paused draw the eye
##   and the words in the caption role, in the status line under the control
##   center; the pause key and a press pause it.
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
from ../chrome import contrastRatio
import ../agent_harbor/ah_control_center as cc
from ../agent_harbor/ah_initiative_panels import initiativesHeadPx
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

proc planNodeWith(n: JsonNode; attribute: string): JsonNode =
  ## The first node of a render plan carrying `attribute`.
  let attributes = n{"attributes"}
  if attributes != nil and attributes.kind == JObject and attributes.hasKey(attribute):
    return n
  for c in n{"children"}.getElems:
    let found = planNodeWith(c, attribute)
    if found != nil: return found

proc mount(fixture: string; width = 1440; height = 900; mode = dmDark): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-control-center", fixture, width, height, mode)

proc planInks(m: AhStoryMount; fact: string): seq[(string, string)] =
  ## Every element carrying `data-ah-<fact>` inside the launch form (the
  ## element carrying `data-ah-locked`) in the render plan, a field's
  ## placeholder left out: its fact's value and its text colour, as GPUI is
  ## handed them.
  proc walk(n: JsonNode; inForm: bool; into: var seq[(string, string)]) =
    let a = n{"attributes"}
    let here = inForm or (a.kind == JObject and a.hasKey("data-ah-locked"))
    if here and a.kind == JObject and a.hasKey("data-ah-" & fact) and
        a{"data-ah-value-empty"}.getStr != "true":
      into.add (a{"data-ah-" & fact}.getStr, n{"styles"}{"text_color"}.getStr)
    for c in n{"children"}.getElems: walk(c, here, into)
  walk(parseJson(renderPlanJson(r, m.root)), false, result)

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

  test "a column too short for the whole form folds it to its summary":
    # 760x640: the launch column cannot hold the whole form with the answer
    # and the recent launches under it, and a GPUI window does not scroll:
    # the form folds to its summary, as the terminal's does (study D75,
    # D84); at a laptop's size it is whole.
    for fixture in ["populated", "launching", "launched", "launch-failed"]:
      let m = mount(fixture, 760, 640)
      let summaries = m.view.tagged("form-summary")
      check summaries.len == 1
      check summaries.allIt(not it.fact("form-summary").contains("\xE2\x80\xA6"))
      check m.view.tagged("section").anyIt(it.fact("section") == "RECENT LAUNCHES")
      m.dispose()
    # One column (a sidebar, 360x900): the whole form would leave the
    # overview under `OverviewFloorPx`, so it folds and the waiting list is
    # in view.
    for fixture in ["populated", "launching", "launched", "launch-failed"]:
      let s = mount(fixture, 360, 900)
      check s.view.fact("columns") == "one"
      check s.view.tagged("form-summary").len == 1
      s.dispose()
    # And the waiting list never cuts a row it cannot scroll to: whole rows
    # within its 45%, the rest counted on a `+N more` line.
    for fixture in ["populated", "launching", "launched", "launch-failed"]:
      let s = mount(fixture, 360, 900)
      let section = s.view.tagged("waiting-section")
      check section.len == 1
      if section.len == 1:
        let total = parseInt(section[0].fact("waiting-section"))
        let drawn = s.view.tagged("waiting-session").len
        let more = s.view.tagged("waiting-more")
        let counted = if more.len == 1: parseInt(more[0].fact("waiting-more")) else: 0
        check drawn + counted == total
        # The `+N more` line keeps the panel's inset, as the rows' words do.
        if more.len == 1:
          let node = parseJson(renderPlanJson(r, s.root)).planNodeWith("data-ah-waiting-more")
          check node != nil
          if node != nil:
            check node{"styles"}{"margin_left"}.getStr == $cc.PadXPx & "px"
        # The waiting list leaves the Initiatives panel its head band and
        # `InitiativesFloorPx` under it (study D84, GPUI review round 3).
        let overviewH = s.view.tagged("overview-px").mapIt(parseInt(it.fact("overview-px")))
        let waitingH = s.view.tagged("waiting-px").mapIt(parseInt(it.fact("waiting-px")))
        check overviewH.len == 1 and waitingH.len == 1
        if overviewH.len == 1 and waitingH.len == 1:
          # Under the panel's head as drawn: at this width its summary wraps
          # under its title, two lines, not `HeadPx`'s one.
          let head = s.center.initiatives.initiativesHeadPx(360, cc.TabLinePx)
          check head > cc.HeadPx
          check overviewH[0] - waitingH[0] - cc.ColumnGapPx >= head + cc.InitiativesFloorPx
      s.dispose()
    let whole = mount("populated")
    check whole.view.tagged("form-summary").len == 0
    check whole.view.tagged("field-label").anyIt(it.fact("field-label") == "Session name")
    whole.dispose()

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

  test "launching: the form locked, Launch busy, Launching... where the answer goes":
    let m = mount("launching")
    check m.view.fact("cc-launching") == "true"
    check m.view.tagged("locked").mapIt(it.fact("locked")) == @["true"]
    check m.view.tagged("value").anyIt(it.fact("value") == EmptyShieldTask)
    let send = m.view.tagged("send")[0]
    check send.fact("send") == "Launch"
    check send.fact("send-busy") == "true"
    check send.fact("send-enabled") == "false"
    # Busy is seen, not only told: the design system's spinner before the
    # label, at 3:1 or more on the panel it sits on (WCAG 2.2 SC 1.4.11).
    let spinners = m.view.tagged("busy-spinner")
    check spinners.len == 1
    if spinners.len == 1:
      check contrastRatio(spinners[0].fact("busy-spinner"), ahPalette(dmDark).panel) >= 3.0
    check m.view.tagged("cc-notice-line")[0].fact("cc-notice-line") == "Launching\xE2\x80\xA6"
    # No toggle takes a press while it waits: For and the mode stay.
    let toggles = m.view.tagged("toggle")
    check toggles.len > 0
    check toggles.allIt(it.fact("disabled") == "true")
    # The schedule's disclosure is not one to open while locked (D74).
    check m.view.tagged("schedule-fold-disabled").mapIt(it.fact("schedule-fold-disabled")) ==
      @["true"]
    # The fields read as sent: no field box, a value's words in the label
    # role, above the options not chosen (the disabled role) in both themes
    # (study D74; the caption role fell under the disabled one in Light).
    let boxes = m.view.tagged("readonly")
    check boxes.len > 0
    check boxes.allIt(it.fact("readonly") == "true")
    for t in m.view.carrying(ControlCenterLaunchForOperation): fireEvent(t, "mousedown")
    for t in m.view.carrying(ControlCenterNewInitiativeOperation): fireEvent(t, "mousedown")
    check m.center.launchForTitle == "Shield model hardening"
    check m.center.mode == lmTask
    m.dispose()
    for mode in [dmDark, dmLight]:
      let lm = mount("launching", mode = mode)
      let p = ahPalette(mode)
      # The form's two set values (Repository, Branch); Session name is
      # empty (its placeholder is left out).
      let inks = planInks(lm, "value").filterIt(it[0].len > 0).mapIt(it[1])
      check inks.len == 2
      check inks.allIt(it == p.textLabel)
      check contrastRatio(p.textLabel, p.panel) > contrastRatio(p.textDisabled, p.panel)
      # The schedule's summary is part of what is launched: the label role.
      check planInks(lm, "schedule-summary").mapIt(it[1]) == @[p.textLabel]
      let sp = lm.view.tagged("busy-spinner")
      check sp.len == 1
      if sp.len == 1: check contrastRatio(sp[0].fact("busy-spinner"), p.panel) >= 3.0
      lm.dispose()

  test "launch failed: Could not launch, the instruction back in the field":
    let m = mount("launch-failed")
    check m.view.fact("cc-launching") == "false"
    check m.view.fact("cc-notice-failed") == "true"
    check m.view.tagged("cc-notice-line")[0].fact("cc-notice-line") ==
      "Could not launch: " & LaunchFailure
    check m.view.tagged("value").anyIt(it.fact("value") == EmptyShieldTask)
    check m.view.tagged("send")[0].fact("send-enabled") == "true"
    check m.view.tagged("locked").mapIt(it.fact("locked")) == @["false"]
    check m.view.tagged("busy-spinner").len == 0
    check m.view.tagged("schedule-fold-disabled").mapIt(it.fact("schedule-fold-disabled")) ==
      @["false"]
    check m.view.tagged("readonly").allIt(it.fact("readonly") == "false")
    m.dispose()

  test "launched: the notice, and the new session queued under its initiative":
    let m = mount("launched")
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
    # One column: an empty fleet keeps the whole form where its overview's
    # own lines fit under it (study D84), as the terminal does.
    let es = mount("empty", 360, 900)
    check es.view.fact("columns") == "one"
    check es.view.tagged("form-summary").len == 0
    check es.view.tagged("cc-empty-line").len == 1
    es.dispose()
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

  test "the status line under the control center, as L7 shows it":
    for fixture in ["off", "tracking", "paused"]:
      for (w, h) in [(1440, 900), (360, 900)]:
        let m = gaze(fixture, w, h)
        let centers = m.view.tagged("surface").filterIt(
          it.fact("surface") == "agent-harbor-control-center")
        check centers.len == 1
        # Whole rows, the rest counted (study D84): all three accounted for.
        let more = centers[0].tagged("waiting-more")
        check centers[0].tagged("waiting-session").len +
          (if more.len == 1: parseInt(more[0].fact("waiting-more")) else: 0) == 3
        check centers[0].tagged("waiting-session").len >= 1
        check m.view.tagged("status-line").len == 1
        # As tall as the web's status bar (STATUS_BAR_CONTENT_HEIGHT, 2rem).
        check StatusBarPx == 32
        m.dispose()

  test "a waiting row's question is never cut silently":
    # GPUI review (2026-11-24): at the sidebar size the text system broke a
    # pre-wrapped question onto one more line than measured, and its last
    # word went under the clip with no `…`. Each line is now drawn on its
    # own: every word of the question is on one of at most two lines, the
    # text past the second riding on it to be elided there.
    for (w, h) in [(360, 900), (760, 640), (1440, 900)]:
      let m = gaze("tracking", w, h)
      let whys = m.view.tagged("waiting-why")
      check whys.len >= 1
      for el in whys:
        let lines = (0 ..< childCount(el)).mapIt(textContent(nthChild(el, it)))
        check lines.len in 1 .. 2
        check lines.join(" ").splitWhitespace == el.fact("waiting-why").splitWhitespace
      # And the answer line never ends a line on its ` · ` separator: the
      # separator goes down with the word after it (`breakableWords`).
      for el in m.view.tagged("cc-notice-line"):
        let lines = (0 ..< childCount(el)).mapIt(textContent(nthChild(el, it)))
        check lines.allIt(not it.strip(leading = false).endsWith("\xC2\xB7"))
        check lines.join(" ").splitWhitespace == el.fact("cc-notice-line").splitWhitespace
      m.dispose()

  test "the pause key and a press pause and resume it":
    let m = gaze("tracking")
    check m.gazeKey("Ctrl+Alt+y") == GazeTogglePauseOperation
    check m.view.tagged("gaze-mark")[0].fact("gaze-mark") == "paused"
    fireEvent(m.view.tagged("gaze-mark")[0], "mousedown")
    check m.view.tagged("gaze-mark")[0].fact("gaze-mark") == "tracking"
    m.dispose()

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
