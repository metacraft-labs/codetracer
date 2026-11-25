## CTF-P2c step 5: GPUI's multi-process recording session tab with its
## process switcher (study §2.6, D25, D76-D83), in the story host that
## mounts it (`gpui/agent_harbor/ah_stories.nim`).
##
## * **The caption bar's tabs**: the recording's tab, active (the active
##   tab's ground, its name in the active tab's ink), then the plain tab.
## * **The tab's facts** are the viewmodel's: the process count, the active
##   and the ringed process, the tooltip naming the bound keys.
## * **The buttons are the recording switcher's own drawing** (the
##   initiative bar's `drawRecordingButton` and `drawRecordingsMore`): five
##   at a laptop's width, two below 720px, `+N` with the failed worker's
##   severity; the ringed process's button carries the ring, and `+N` does
##   when it hides that process.
## * **Presses and keys are routed**: a press on a button selects its
##   process and clears the ring when it was the ringed one; the next and
##   previous keys and a digit move the active process.
##
## No mocks: the stories' own viewmodel drawn by the real views into
## isonim-gpui's element tree.

import std/[json, os, sequtils, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
from ../agent_harbor/ah_initiative_tab_bar import ringInk, RingMarginPx, RecordingButtonGapPx
from ../chrome import contrastRatio
import ../../styles/generated/design_tokens
import ../../stories/agent_harbor_process_switcher_stories
import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../../../tests/visual/agent_harbor/ctf_layout_judge

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc tagged(root: GpuiElement; fact: string): seq[GpuiElement] =
  collect(root, "data-ah-" & fact, result)

proc fact(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc mount(fixture: string; width = 1440; height = 900; mode = dmDark): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-process-switcher", fixture, width, height, mode)

proc planOf(m: AhStoryMount): JsonNode = parseJson(renderPlanJson(r, m.root))

proc allWith(n: JsonNode; name: string; into: var seq[JsonNode]) =
  if n{"attributes"}.kind == JObject and n{"attributes"}.hasKey(name): into.add n
  for c in n{"children"}.getElems: allWith(c, name, into)

proc allWith(n: JsonNode; name: string): seq[JsonNode] = allWith(n, name, result)

proc styleOf(m: AhStoryMount; fact, value, name: string): string =
  ## A style of the element carrying `data-ah-<fact>` = `value`, off the
  ## render plan ("" when value is "", the first such element).
  for n in m.planOf.allWith("data-ah-" & fact):
    if value.len == 0 or n{"attributes"}{"data-ah-" & fact}.getStr == value:
      return n{"styles"}{name}.getStr
  ""

proc tab(m: AhStoryMount): GpuiElement =
  m.view.tagged("tab").filterIt(it.fact("active") == "true")[0]

suite "CTF-P2c: the GPUI process switcher's tab":
  test "the recording's tab, active, then the plain tab":
    for mode in [dmDark, dmLight]:
      let m = mount("three", mode = mode)
      let p = ahPalette(mode)
      check m.view.fact("surface") == ProcessSwitcherSurface
      let t = m.tab
      check t.fact("tab") == EnvelopeFlowTitle
      check m.styleOf("tab", EnvelopeFlowTitle, "bg") == p.activeTab
      check t.tagged("label")[0].fact("label") == EnvelopeFlowTitle
      let others = m.view.tagged("tab").filterIt(it.fact("active") == "false")
      check others.len == 1 and others[0].fact("tab") == OtherTabTitle
      # The plain tab's name in the caption role, quiet beside the active
      # tab's (GPUI review of 2026-11-25: it was the caption token at full
      # strength, nearly the active name's brightness in Dark).
      let ink = others[0].fact("ink")
      check ink == plainTabInk(p)
      check m.styleOf("ink", ink, "bg") == ""   # the plain tab has no fill
      check ink != p.activeTabText
      check contrastRatio(ink, p.ground) >= 4.0
      check contrastRatio(ink, p.ground) < contrastRatio(p.activeTabText, p.ground)
      m.dispose()
    # Dark: CodeTracer's `.session-tab` colour at its 0.7 opacity over the
    # bar (the web's #838383); the caption token alone is the control.
    check plainTabInk(ahPalette(dmDark)) == "#838383"
    check plainTabInk(ahPalette(dmDark)) != ahPalette(dmDark).textCaption
    check contrastRatio(plainTabInk(ahPalette(dmDark)), ahPalette(dmDark).ground) >= 4.5

  test "the tab's facts are the viewmodel's":
    let m = mount("correlation")
    let t = m.tab
    check t.fact("processes") == "3"
    check t.fact("process-active") == "1"
    check t.fact("process-ringed") == "2"
    check t.fact("tooltip").endsWith("Ctrl+Alt+PageDown / Ctrl+Alt+PageUp to move between them")
    m.dispose()

suite "CTF-P2c: the GPUI process switcher's buttons":
  test "the recording switcher's buttons, at the window's slots":
    for (fixture, width, shown, hidden) in [("three", 1440, 3, 0), ("three", 360, 2, 1),
                                            ("many", 1440, 5, 3), ("many", 360, 2, 6)]:
      let m = mount(fixture, width)
      let buttons = m.tab.tagged("recording")
      check buttons.len == shown
      check buttons[0].fact("recording-active") == "true"
      let more = m.tab.tagged("recordings-hidden")
      check more.len == (if hidden > 0: 1 else: 0)
      if hidden > 0: check more[0].fact("recordings-hidden") == $hidden
      if fixture == "many": check more[0].fact("recordings-hidden-severity") == "failed"
      m.dispose()

  test "the ringed process's button carries the ring":
    let m = mount("correlation")
    let b = m.tab.tagged("recording")
    check b.mapIt(it.fact("recording-ringed")) == @["", "true", ""]
    let ring = b[1].tagged("recording-ring")
    check ring.len == 1
    check m.styleOf("recording-ring", "", "border_color") == ringInk(ahPalette(dmDark))
    check ringInk(ahPalette(dmDark)) == "#818cf8"   # brand/400
    check ringInk(ahPalette(dmLight)) == "#4338ca"  # brand/700
    check b[0].tagged("recording-ring").len == 0
    m.dispose()

  test "the ring is 2px, 1px clear of the button, with no halo":
    # Manager note 239: the 1px ring read as another button's outline; the
    # ring is 2px in the ring ink, 1px clear, the tab's fill between (no
    # halo in either theme; study D81).
    for mode in [dmDark, dmLight]:
      let m = mount("correlation", mode = mode)
      let rings = m.tab.tagged("recording-ring")
      check rings.len == 1
      check m.tab.tagged("recording-ring-halo").len == 0
      check m.styleOf("recording-ring", "", "border_width") == "2px"
      # From the button's padding edge, inside its 1px border: the ring's
      # 2px end 1px clear of the button's outline.
      check m.styleOf("recording-ring", "", "left") == "-4px"
      # Clear of its neighbours by as much as its own gap and ring (3px): a
      # 4px margin either side, with the buttons' 2px gap.
      check m.styleOf("recording-ringed", "true", "margin_left") == $RingMarginPx & "px"
      check m.styleOf("recording-ringed", "true", "margin_right") == $RingMarginPx & "px"
      check RingMarginPx + RecordingButtonGapPx - 3 >= 3
      m.dispose()

  test "the ring holds 3:1 against the tab's fill and its halo":
    # The ring is the only mark of its state (WCAG 2.2 SC 1.4.11; study
    # D81). Its control: the action border, which the ring first used, is
    # under 3:1 on Dark's fill, so this check tells the two apart.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      let halo = DesignTokenHex[dtColorsUiSurfaceBaseCanvas][mode]
      check contrastRatio(ringInk(p), p.activeTab) >= 3.0
      check contrastRatio(ringInk(p), halo) >= 3.0
      # And against the bar the tab sits in (manager note 239).
      check contrastRatio(ringInk(p), p.ground) >= 3.0
    check contrastRatio(ahPalette(dmDark).borderAction, ahPalette(dmDark).activeTab) < 3.0

  test "behind +N, the ring is on the chip":
    let m = mount("many")
    check m.processes.markCorrelation("envelope-worker-6", "x")
    let more = m.tab.tagged("recordings-hidden")[0]
    check more.fact("recordings-hidden-ringed") == "true"
    # The ringed control for the layout record's `ps-ringed` region
    # (`data-ah-recording-ringed`), as the web's `.ah-rec-ringed` is on its
    # `.ah-rec-more`.
    check more.fact("recording-ringed") == "true"
    check more.fact("tooltip").startsWith("3 more processes")   # not recordings
    check more.tagged("recording-ring").len == 1
    check m.tab.tagged("recording").allIt(it.fact("recording-ringed") == "")
    m.dispose()

suite "CTF-P2c: the GPUI process switcher's presses and keys":
  test "a press on the ringed button selects it and clears the ring":
    let m = mount("correlation")
    fireEvent(m.tab.tagged("recording")[1], "click")
    check m.tab.fact("process-active") == "2"
    check m.tab.fact("process-ringed") == "0"
    m.dispose()

  test "Ctrl+Alt+PageDown / PageUp and a digit move the active process":
    let m = mount("three")
    check m.processSwitcherKey("Ctrl+Alt+PageDown") == ProcessNextOperation
    check m.tab.fact("process-active") == "2"
    check m.processSwitcherKey("Ctrl+Alt+PageUp") == ProcessPreviousOperation
    check m.tab.fact("process-active") == "1"
    check m.processSwitcherKey("3") == ProcessSelectOperation
    check m.tab.fact("process-active") == "3"
    check m.processSwitcherKey("9") == ""
    m.dispose()

# ---------------------------------------------------------------------------
# The regions the window capture is judged on
# ---------------------------------------------------------------------------

proc matchesFacts(el: GpuiElement; facts: JsonNode): bool =
  ## The story window's region match (`ah_story_window.matches`): every
  ## declared `data-ah-*` attribute present, with its value when one is given.
  for attr, want in facts.pairs:
    let have = getAttribute(el, attr)
    if have.len == 0 or (want.getStr.len > 0 and have != want.getStr): return false
  true

proc anyMatching(node: GpuiElement; facts: JsonNode): bool =
  if node.isNil: return false
  if node.matchesFacts(facts): return true
  for i in 0 ..< childCount(node):
    if anyMatching(nthChild(node, i), facts): return true
  false

suite "CTF-P1b: a process switcher story draws the regions the web draws, and no others":
  test "each region of every process switcher story is matched by its GPUI facts exactly when the web has it":
    # `process-switcher-many-ringed` drew its ring on `+N` with no
    # `data-ah-recording-ringed`, so the capture's `ps-ringed` region was
    # "drawn only on web" (GPUI review of 2026-11-25).
    let regionsDir = repoRoot / "src" / "tests" / "visual"
    let record = loadWebRecord(regionsDir / "agent-harbor-web-regions.json")
    var declared: seq[(string, JsonNode)]
    for region in parseJson(readFile(regionsDir / "agent-harbor-regions.json"))["regions"]:
      declared.add (region["name"].getStr, region["gpui"])
    var stories, compared, ringed = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != ProcessSwitcherSurface: continue
      inc stories
      let sid = storybookId(agentHarborSection(), story)
      for (size, w, h) in Sizes:
        for (mode, theme) in [(dmDark, "dark"), (dmLight, "light")]:
          let id = ViewPrefix & sid[StoryIdPrefix.len .. ^1] & "-" & size & "-" & theme
          let web = record{id}{"regions"}
          if web.isNil:
            problems.add id & ": the web record has no capture"
            continue
          gpui_reset_tree()
          let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, mode)
          for (name, facts) in declared:
            inc compared
            let drawn = m.root.anyMatching(facts)
            if name == "ps-ringed" and drawn: inc ringed
            if web.hasKey(name) and not drawn:
              problems.add id & ": region " & name & " is drawn only on web"
            elif drawn and not web.hasKey(name):
              problems.add id & ": region " & name & " is drawn only on gpui"
          m.dispose()
    for p in problems: checkpoint p
    check stories == 5
    check compared > 0
    # `-correlation` and `-many-ringed`, two sizes, two themes.
    check ringed == 8
    check problems.len == 0
