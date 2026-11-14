## test_ctf_p1c_playback_stories_agree_at_each_moment.nim — CTF-P1c: **every
## playback story shows the same state in the web, GPUI and terminal story
## hosts at every named moment of its scenario, and every playback story id
## exists in all three.**
##
## The stories are not listed here. They are read from their one declaration,
## `stories/codetracer_stories.nim`, as the CTF-P1b cover tests read them: a
## playback story is one whose surface and fixture `agent_harbor_stories`
## names in `playbackFixtures`, and its id is the StoryBook generator's own
## `storybookId`.
##
## For each playback story, three hosts mount it, each over its OWN playback
## (`agent_harbor_playback.newAhPlayback`) on its own IsoNim `TestClock`:
##
##   * WEB — the web views (`viewmodel/views/isonim_agent_harbor_*_view.nim`)
##     and the web host's playback bar (`isonim_agent_harbor_playback_view`),
##     rendered on IsoNim's `MockRenderer` and driven by clicks on the bar's
##     buttons. This is the StoryBook mount (`storybook_components.nim`'s
##     `mountAgentHarborVM` and `mountPlaybackChrome`) minus the browser: the
##     same story constructor over the same playback, the same generic view
##     instantiated for the mock DOM instead of `WebRenderer`, the strip told
##     the laptop width the browser mount measures. The browser half — the
##     URL parameter and the bar under a real StoryBook story — is the
##     `agent-harbor-playback` play check that `just storybook-check-render`
##     runs.
##   * GPUI — `gpui/agent_harbor/ah_stories.mountAgentHarborStoryGpui`, the
##     GPUI story host's mount, in a real isonim-gpui shadow tree (the shim
##     in process; no window), driven by clicks dispatched through the shim
##     at its playback bar (`ah_playback_bar.nim`), and once by Play with its
##     clock advanced to the moment, then Pause.
##   * TERMINAL — `tui/agent_harbor/ah_tui_stories.mountStory`, the terminal
##     story host's mount, driven by its keys (`n` step, `[` and `]` the
##     previous and next named moment), redrawn as the host redraws it
##     (`idle`); and the story host itself, spawned in a real pty with
##     `--moment=<name>` for every named moment, its screen compared cell by
##     cell with the in-process drawing at that moment.
##
## What is compared is the CTF-P1b cover tests' facts read off each drawing
## (the GPUI `data-ah-*` attributes, the terminal's `AhNode` facts, the web
## views' classes and text): which tabs a strip draws, their labels,
## attention and the active one, `+N`; the list's tree nodes with their
## counts and its rows with their states; the initiative bar's tabs and
## `n/m`, its recording buttons and their states, the sessions started
## elsewhere and the inbox; the Initiatives panel's rows, current
## milestones and session lines; the progress panel's headline, status
## groups and milestones; the fleet's filter counts and rows; and each bar's
## readout (the moment and the time). They are compared:
##
##   1. at the first frame, then at every named moment going forward (the web
##      by its Next button, GPUI by Play on its clock then Pause, the
##      terminal by stepping entry by entry with `n`), then at every named
##      moment going backward by each host's Previous control (a seek
##      backwards, which rebuilds from the first frame), back to the first
##      frame; and
##   2. at every named moment opened directly (each host's way of opening a
##      story at a moment: the web's `moment` option, GPUI's and the
##      terminal's `--moment`), against what the same host showed when it
##      played there; and
##   3. after every control of every host's bar, pressed in all three from
##      the same state (the terminal's by a click on its button or by its
##      key), so a button that runs another control, or runs it twice, makes
##      its host disagree; each press is also held to what its control does
##      by definition (Step moves the head to the next entry's time, Rewind
##      returns to the first frame, Play and Pause change the state).
##
## THE ORACLE IS NOT ONE HOST AGAINST ITSELF. At every moment the three hosts
## are held to each other, and at the moments `SpotChecks` names the facts
## written out by hand from the scenario's script
## (nim-agents-isonim-viewmodels `playback_scenarios.nim`) must appear in each
## host's drawing. So a host that draws another state disagrees with the
## other two, and a defect all three share (the playback, a viewmodel, a
## story constructor) fails the hand-written facts.
##
## Test doubles, and why each is justified:
##   * `TestClock` (IsoNim) instead of `RealClock`: the hosts play on a real
##     clock; a test that waited on wall time would be slow and flaky, and the
##     playback is defined over an injected clock precisely so a test moves
##     it (`agent_harbor_playback.nim`).
##   * `MockRenderer` (IsoNim) for the web views: `WebRenderer` compiles only
##     under `nim js` against a live DOM, and this lane compiles C. It is one
##     of the renderer backends IsoNim ships and the one every non-JS
##     instantiation of a web view uses (the `vm-unit` lanes drive it the
##     same way); the views' code is unchanged.
## Nothing else is a double: the viewmodels, the playback source and the
## synthetic scenarios are the production ones, the GPUI renderer is the
## shim's, and the terminal is a real pty and libvterm.

import std/[json, os, osproc, sets, strutils, times, unittest]
from std/unicode import `$`
from nim_agents_isonim_viewmodels/agent_harbor/fixture_source import AgentHarborFixtureRoot

import isonim/core/owner
import isonim/testing/mock_dom
import isonim_gpui/renderer as gpui_renderer
from isonim_gpui/bindings import gpui_reset_tree
import term_assert

import ../../testing/dual_snap
import ../../agent_harbor/ah_tui_stories
import ../../../gpui/agent_harbor/ah_stories
import ../../../viewmodel/views/[isonim_agent_harbor_session_tabs_view,
  isonim_agent_harbor_initiatives_view, isonim_agent_harbor_initiative_tabs_view,
  isonim_agent_harbor_fleet_view, isonim_agent_harbor_playback_view]
from ../../../viewmodel/views/isonim_session_tabs_view import SessionTabLabelClass

const
  Stem = "app_agent_harbor_story"
  LaptopW = 1440
  LaptopH = 900
  LaptopCols = 180
  LaptopRows = 56
  MinimumPlaybackStories = 6
    ## One per P2a surface: the session tab strip, the session list, the
    ## initiative tab bar, the Initiatives and Initiative Progress panels and
    ## the fleet list.

let PrintFacts = existsEnv("CTF_P1C_PRINT_FACTS")
  ## Prints the web's facts at every comparison, for a reader writing or
  ## checking the hand-written ones.

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

# ---------------------------------------------------------------------------
# Reading a GPUI or terminal drawing (both carry the `data-ah-*` facts)
# ---------------------------------------------------------------------------

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc all(root: GpuiElement; fact: string): seq[GpuiElement] =
  collect(root, "data-ah-" & fact, result)

proc attr(e: GpuiElement; fact: string): string = getAttribute(e, "data-ah-" & fact)

proc first(root: GpuiElement; fact: string): GpuiElement =
  let found = root.all(fact)
  if found.len > 0: found[0] else: nil

proc fact[N](root: N; name: string): string =
  ## The first `name` fact under `root` (itself included); "" for none.
  mixin first, attr
  let n = root.first(name)
  if n.isNil: "" else: n.attr(name)

proc activeMark(active: string): string = (if active == "true": " active" else: "")

proc drawnFacts[N](view: N; surface: string): seq[string] =
  ## The facts a GPUI or terminal drawing of `surface` shows, in drawing
  ## order, one line each (the same lines `webFacts` reads off the web).
  mixin all, attr, first
  case surface
  of "agent-harbor-session-tabs":
    for t in view.all("tab"):
      result.add "tab " & t.fact("label") & " [" & t.attr("attention") & "]" &
                 activeMark(t.attr("active"))
    for o in view.all("overflow"): result.add "+N " & o.attr("overflow")
  of "agent-harbor-session-list":
    result.add "summary " & view.fact("summary")
    for g in view.all("folded"):
      result.add "group " & g.fact("title") &
                 (if g.attr("folded") == "true": " folded" else: "")
    for row in view.all("row"):
      result.add "row " & row.fact("title") & " | " & row.fact("status") & " [" &
                 row.attr("attention") & "]" & activeMark(row.attr("active"))
  of "agent-harbor-initiative-tabs":
    for t in view.all("tab"):
      let progress = t.fact("progress")
      result.add "tab " & t.fact("label") & (if progress.len > 0: " | " & progress else: "") &
                 activeMark(t.attr("active"))
    for b in view.all("recording"):
      result.add "recording " & b.attr("recording") & " " & b.attr("recording-state") &
                 activeMark(b.attr("recording-active"))
    for e in view.all("elsewhere"): result.add "elsewhere " & e.attr("elsewhere")
    for i in view.all("inbox"): result.add "inbox " & i.attr("inbox")
  of "agent-harbor-initiatives":
    result.add "summary " & view.fact("summary")
    for row in view.all("initiative"):
      result.add "initiative " & row.fact("title") & " | " & row.fact("progress") &
                 " | current " & row.fact("current") & " [" & row.attr("state") & "]"
      for s in row.all("session"):
        result.add "session " & s.fact("title") & " | " & s.fact("status")
  of "agent-harbor-initiative-progress":
    result.add "headline " & view.fact("summary")
    for g in view.all("group"): result.add "group " & g.attr("group")
    for m in view.all("milestone"):
      result.add "milestone " & m.attr("milestone") &
                 (if m.attr("current") == "true": " current" else: "")
  of "agent-harbor-fleet":
    var counts: seq[string]
    for f in view.all("filter-count"): counts.add f.attr("filter-count")
    result.add "filters " & counts.join(" ")
    for row in view.all("row"):
      result.add "row " & row.fact("title") & " | " & row.fact("status") & " [" &
                 row.attr("category") & "]"
  else: result.add "no reading for surface " & surface

proc barFacts[N](root: N): string =
  ## The playback bar's readout: its state, moment and time.
  mixin all, attr, first
  "playback " & root.fact("playback") & " | " & root.fact("playback-moment") & " | " &
    root.fact("playback-time")

# ---------------------------------------------------------------------------
# Reading the web views (their classes and text)
# ---------------------------------------------------------------------------

proc classes(n: MockNode): seq[string] =
  if n.kind != mnkElement or not n.attributes.hasKey("class"): return @[]
  n.attributes["class"].splitWhitespace

proc hasClass(n: MockNode; cls: string): bool = cls in n.classes

proc collectClass(n: MockNode; cls: string; into: var seq[MockNode]) =
  if n.isNil: return
  if n.hasClass(cls): into.add n
  for ch in n.children: collectClass(ch, cls, into)

proc byClass(n: MockNode; cls: string): seq[MockNode] = collectClass(n, cls, result)

proc textOf(n: MockNode; cls: string): string =
  ## The text of the first element under `n` classed `cls`; "" for none.
  let found = n.byClass(cls)
  if found.len > 0: found[0].textContent else: ""

proc tokenAfter(n: MockNode; prefix: string): string =
  ## The rest of `n`'s first class token starting with `prefix`.
  for c in n.classes:
    if c.startsWith(prefix): return c[prefix.len .. ^1]

proc webFacts(view: MockNode; surface: string): seq[string] =
  case surface
  of "agent-harbor-session-tabs":
    for t in view.byClass("ah-tab"):
      result.add "tab " & t.textOf(SessionTabLabelClass) & " [" & t.tokenAfter("ah-att-") & "]" &
                 (if t.hasClass("active"): " active" else: "")
    for o in view.byClass("ah-tab-overflow-count"):
      result.add "+N " & o.textContent.strip(chars = {'+'})
  of "agent-harbor-session-list":
    result.add "summary " & view.textOf("ah-session-list-summary")
    for g in view.byClass("ah-session-group-header"):
      result.add "group " & g.textOf("ah-session-group-title") &
                 (if g.textOf("ah-session-group-fold") == "\xE2\x96\xB8": " folded" else: "")
    for row in view.byClass("ah-session-row"):
      result.add "row " & row.textOf("ah-session-row-title") & " | " &
                 row.textOf("ah-session-row-status") & " [" & row.tokenAfter("ah-att-") & "]" &
                 (if row.hasClass("ah-session-row-active"): " active" else: "")
  of "agent-harbor-initiative-tabs":
    for t in view.byClass("ah-tab"):
      if t.hasClass("ah-tab-notice"): continue
      let progress = t.textOf("ah-tab-progress")
      result.add "tab " & t.textOf(SessionTabLabelClass) &
                 (if progress.len > 0: " | " & progress else: "") &
                 (if t.hasClass("active"): " active" else: "")
    for b in view.byClass("ah-rec-button"):
      var number = ""
      for ch in b.textContent:
        if ch in Digits: number.add ch else: break
      var state = ""
      for c in b.classes:
        if c.startsWith("ah-rec-") and c notin ["ah-rec-button", "ah-rec-active"]:
          state = c["ah-rec-".len .. ^1]
      result.add "recording " & number & " " & state &
                 (if b.hasClass("ah-rec-active"): " active" else: "")
    for e in view.byClass("ah-elsewhere-count"): result.add "elsewhere " & e.textContent
    for i in view.byClass("ah-inbox-position"): result.add "inbox " & i.textContent
  of "agent-harbor-initiatives":
    result.add "summary " & view.textOf("ah-fleet-summary")
    for row in view.byClass("ah-initiative-row"):
      result.add "initiative " & row.textOf("ah-initiative-title") & " | " &
                 row.textOf("ah-initiative-progress-text") & " | current " &
                 row.textOf("ah-initiative-current-text") & " [" & row.tokenAfter("ah-ist-") & "]"
      for s in row.byClass("ah-initiative-session"):
        result.add "session " & s.textOf("ah-initiative-session-title") & " | " &
                   s.textOf("ah-initiative-session-status")
  of "agent-harbor-initiative-progress":
    result.add "headline " & view.textOf("ah-fleet-summary")
    for g in view.byClass("ah-progress-group-name"): result.add "group " & g.textContent
    for m in view.byClass("ah-milestone"):
      result.add "milestone " & m.textOf("ah-milestone-id") &
                 (if m.hasClass("ah-milestone-current"): " current" else: "")
  of "agent-harbor-fleet":
    var counts: seq[string]
    for f in view.byClass("ah-fleet-filter-count"): counts.add f.textContent
    result.add "filters " & counts.join(" ")
    for row in view.byClass("ah-fleet-row"):
      result.add "row " & row.textOf("ah-fleet-row-title") & " | " &
                 row.textOf("ah-fleet-status-label") & " [" & row.tokenAfter("ah-fleet-cat-") & "]"
  else: result.add "no reading for surface " & surface

proc webBarFacts(bar: MockNode): string =
  "playback " & bar.tokenAfter("ah-playback-") & " | " & bar.textOf("ah-playback-moment") &
    " | " & bar.textOf("ah-playback-time")

# ---------------------------------------------------------------------------
# The three hosts
# ---------------------------------------------------------------------------

type
  Host = enum hWeb = "web", hGpui = "GPUI", hTui = "terminal"

  WebMount = ref object
    ## The StoryBook mount of a playback story, on the mock DOM.
    pb: AhPlayback
    view, bar: MockNode
    dispose: proc()

  Hosts = object
    story: CodeTracerStory
    clocks: array[Host, TestClock]
    web: WebMount
    gpui: AhStoryMount
    tui: AhTuiMount

let section = agentHarborSection()
let gr = GpuiRenderer()

proc mountWeb(story: CodeTracerStory; clock: ClockBase; moment = ""): WebMount =
  ## `storybook_components.mountAgentHarborVM` + `mountPlaybackChrome`, on
  ## the mock DOM (see the header).
  let r = MockRenderer()
  let m = WebMount(pb: newAhPlayback(story.surface, story.fixture, clock))
  var disposeRoot: proc()
  var disposeVm: proc()
  createRoot proc(disposeOwner: proc()) =
    disposeRoot = disposeOwner
    let pb = m.pb
    case story.surface
    of "agent-harbor-session-tabs":
      let vm = createSessionTabsStoryVM(story.fixture, pb)
      vm.stripWidthPx.val = LaptopW
      m.view = renderAgentHarborTabStrip[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-session-list":
      let vm = createSessionListStoryVM(story.fixture, pb)
      m.view = renderAgentHarborSessionList[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-initiative-tabs":
      let vm = createInitiativeTabsStoryVM(story.fixture, pb)
      vm.stripWidth.val = LaptopW
      m.view = renderAgentHarborInitiativeTabBar[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-initiatives":
      let vm = createInitiativesStoryVM(story.fixture, pb)
      m.view = renderAgentHarborInitiativesPanel[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-initiative-progress":
      let vm = createProgressStoryVM(story.fixture, pb)
      m.view = renderAgentHarborProgressPanel[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-fleet":
      let vm = createFleetStoryVM(story.fixture, pb)
      m.view = renderAgentHarborFleetPanel[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    else: raise newException(ValueError, "no web view for " & story.surface)
    m.bar = renderAgentHarborPlaybackBar[MockRenderer, MockNode](r, pb)
  m.pb.openAtMoment(moment)
  m.dispose = proc() =
    m.pb.dispose()
    if disposeVm != nil: disposeVm()
    if disposeRoot != nil: disposeRoot()
  m

proc mount(story: CodeTracerStory; moment = ""): Hosts =
  ## The story in all three hosts, each on its own test clock.
  result.story = story
  for h in Host: result.clocks[h] = newTestClock()
  result.web = mountWeb(story, result.clocks[hWeb], moment)
  gpui_reset_tree()
  let frameTitle = if story.kind == "panel": frameTitleOf(story) else: ""
  result.gpui = gr.mountAgentHarborStoryGpui(story.surface, story.fixture, LaptopW, LaptopH,
                                             dmDark, frameTitle, result.clocks[hGpui], moment)
  result.tui = mountStory(story, LaptopCols, LaptopRows, dmDark, result.clocks[hTui], moment)

proc dispose(h: Hosts) =
  h.web.dispose()
  h.gpui.dispose()
  h.tui.dispose()

proc factsOf(h: Hosts; host: Host): seq[string] =
  ## What `host` shows now: its bar's readout, then the story's facts.
  case host
  of hWeb: @[webBarFacts(h.web.bar)] & webFacts(h.web.view, h.story.surface)
  of hGpui: @[barFacts(h.gpui.bar)] & drawnFacts(h.gpui.view, h.story.surface)
  of hTui:
    discard h.tui.idle()   # as the story host redraws between inputs
    let bar = h.tui.canvas.root.first("playback")
    @[barFacts(bar)] & drawnFacts(h.tui.view, h.story.surface)

# The hosts' controls, each driven as its host's reader drives it.

proc clickWeb(h: Hosts; control: PlaybackControl) =
  let found = h.web.bar.byClass("ah-playback-" & $control)
  doAssert found.len == 1, "the web bar draws no " & $control & " button"
  found[0].fireEvent("click")

proc clickGpui(h: Hosts; control: PlaybackControl) =
  var target: GpuiElement
  for b in h.gpui.bar.all("playback-control"):
    if b.attr("playback-control") == $control: target = b
  doAssert not target.isNil, "the GPUI bar draws no " & $control & " button"
  gpui_renderer.fireEvent(target, "click")

proc keyTui(h: Hosts; key: string) =
  doAssert h.tui.handleInput(key), "the terminal host did not take the key " & key

proc clickTui(h: Hosts; control: PlaybackControl) =
  ## A press on the terminal bar's button, as the terminal reports it (SGR,
  ## 1-based).
  var target: AhNode
  for b in h.tui.canvas.root.first("playback").all("playback-control"):
    if b.attr("playback-control") == $control: target = b
  doAssert not target.isNil, "the terminal bar draws no " & $control & " button"
  doAssert h.tui.handleInput("\x1b[<0;" & $(target.col + 1) & ";" & $(target.row + 1) & "M"),
    "the terminal host did not take a press on its " & $control & " button"

const TuiKeys: array[PlaybackControl, string] = [" ", "n", "[", "]", "0"]
  ## The terminal's key for each control, as its story host documents them
  ## (`ah_tui_story_host.nim`), written out here rather than read from the
  ## bar's own table, so a key bound to the wrong control is caught.

proc momentOf(h: Hosts; host: Host): string =
  case host
  of hWeb: h.web.pb.currentMoment
  of hGpui: h.gpui.playback.currentMoment
  of hTui: h.tui.playback.currentMoment

# ---------------------------------------------------------------------------
# The hand-written facts
# ---------------------------------------------------------------------------
#
# Written from the scenarios' scripts (nim-agents-isonim-viewmodels
# `playback_scenarios.nim`: who starts when, asks, is answered, fails, ends,
# which milestone moves and which recording loads), not read off any host.
# Each line must appear among a host's facts at that moment.

const
  Port = "Port the route cache to the new storage layer"
  Migration = "Migrate cached routes without a cold start"
  Importer = "Profile the importer on the large fixture"
  Config = "Answer the question about the config format"
  Bench = "Benchmark route cache reads on the new layer"
  Dot = " \xC2\xB7 "

type SpotCheck = tuple[surface, moment: string; facts: seq[string]]

let SpotChecks: seq[SpotCheck] = @[
  # The strip, in launch order, the first tab active: four sessions, the
  # config question waiting; the bench appears at +30 s, asks at +90 s; the
  # migration fails at +180 s; the importer ends at +240 s and is removed
  # at +330 s.
  ("agent-harbor-session-tabs", "", @[
    "playback paused | first frame | +0:00",
    "tab " & Importer & " [running] active", "tab " & Migration & " [running]",
    "tab " & Port & " [running]", "tab " & Config & " [needs-input]"]),
  ("agent-harbor-session-tabs", "new-session", @[
    "playback paused | new-session | +0:30",
    "tab " & Bench & " [queued]"]),
  ("agent-harbor-session-tabs", "bench-asks", @[
    "tab " & Port & " [needs-input]", "tab " & Bench & " [needs-input]"]),
  ("agent-harbor-session-tabs", "migration-fails", @[
    "tab " & Migration & " [failed]", "tab " & Port & " [running]"]),
  # The tree: the route cache's node and the node of no initiative, their
  # counts following the sessions; a row's status follows its session.
  ("agent-harbor-session-list", "port-asks", @[
    "summary 5 sessions" & Dot & "2 need input" & Dot & "3 running",
    "row " & Port & " | needs input [needs-input]"]),
  ("agent-harbor-session-list", "config-answered", @[
    "summary 5 sessions" & Dot & "4 running" & Dot & "1 failed",
    "row " & Migration & " | failed [failed]"]),
  ("agent-harbor-session-list", "importer-removed", @[
    "summary 4 sessions" & Dot & "1 running" & Dot & "1 failed"]),
  # The initiative bar over initiative-run: its n/m and its recordings,
  # numbered in the order they appeared, the first active.
  ("agent-harbor-initiative-tabs", "", @[
    "tab Telemetry upload retries | 0/3 active"]),
  ("agent-harbor-initiative-tabs", "trace-loading", @[
    "tab Telemetry upload retries | 1/3 active", "recording 1 loading active"]),
  ("agent-harbor-initiative-tabs", "trace-ready", @["recording 1 ready active"]),
  ("agent-harbor-initiative-tabs", "recording-fails", @[
    "recording 1 ready active", "recording 2 failed"]),
  ("agent-harbor-initiative-tabs", "recording-reloaded", @[
    "tab Telemetry upload retries | 2/3 active",
    "recording 1 ready active", "recording 2 ready", "recording 3 ready"]),
  # The Initiatives panel over front-ends: the route cache's progress and
  # current milestone move at +210 s.
  ("agent-harbor-initiatives", "", @[
    "initiative Route cache on the new storage layer | 1/4" & Dot &
      "25% | current RC-M1: Data model [working]"]),
  ("agent-harbor-initiatives", "milestone-done", @[
    "initiative Route cache on the new storage layer | 2/4" & Dot &
      "50% | current RC-M2: Core change [working]"]),
  # The progress panel over initiative-run.
  ("agent-harbor-initiative-progress", "", @[
    "headline 0 of 3 milestones" & Dot & "0%", "milestone TR-M0 current"]),
  ("agent-harbor-initiative-progress", "milestone-blocked", @[
    "headline 1 of 3 milestones" & Dot & "33%", "milestone TR-M1 current"]),
  ("agent-harbor-initiative-progress", "plan-done", @[
    "headline 3 of 3 milestones" & Dot & "100%"]),
  # The fleet: a row per session, its status following the session.
  ("agent-harbor-fleet", "", @["row " & Config & " | needs input [needs-input]"]),
  ("agent-harbor-fleet", "migration-fails", @["row " & Migration & " | failed [failed]"]),
  ("agent-harbor-fleet", "port-completes", @["row " & Port & " | completed [ended]"])]

proc spotProblems(surface, moment: string; facts: seq[string]): seq[string] =
  for spot in SpotChecks:
    if spot.surface != surface or spot.moment != moment: continue
    for want in spot.facts:
      if want notin facts: result.add "the hand-written fact '" & want & "' is not shown"

proc spotMomentsOf(surface: string): seq[string] =
  for spot in SpotChecks:
    if spot.surface == surface and spot.moment notin result: result.add spot.moment

# ---------------------------------------------------------------------------
# Comparing the hosts
# ---------------------------------------------------------------------------

proc momentName(moment: string): string =
  if moment.len == 0: "the first frame" else: moment

proc hostsFacts(h: Hosts; at: string; problems: var seq[string]): array[Host, seq[string]] =
  ## Every host's facts now; a problem naming `at` for each host whose facts
  ## are not the web's.
  for host in Host: result[host] = h.factsOf(host)
  if PrintFacts:
    echo "== ", at, "\n  ", result[hWeb].join("\n  ")
  for host in [hGpui, hTui]:
    if result[host] != result[hWeb]:
      var diff: seq[string]
      for f in result[hWeb]:
        if f notin result[host]: diff.add "web only: " & f
      for f in result[host]:
        if f notin result[hWeb]: diff.add $host & " only: " & f
      if diff.len == 0: diff.add "the same facts in another order"
      problems.add at & ": the web and " & $host & " disagree: " & diff.join("; ")

proc agreement(h: Hosts; moment, how: string): seq[string] =
  ## The three hosts' facts against each other and the hand-written ones;
  ## empty when they agree. Each problem names the story and the moment.
  let id = storybookId(section, h.story)
  let at = id & " at " & momentName(moment) & " (" & how & ")"
  let facts = h.hostsFacts(at, result)
  for host in Host:
    if h.momentOf(host) != moment:
      result.add at & ": the " & $host & " host is at '" & h.momentOf(host) & "'"
    for p in spotProblems(h.story.surface, moment, facts[host]):
      result.add at & ": " & $host & ": " & p

proc playbackStories(): seq[CodeTracerStory] =
  for story in section.stories:
    if isPlaybackStory(story.surface, story.fixture): result.add story

# ---------------------------------------------------------------------------
# The real terminal
# ---------------------------------------------------------------------------

proc spawnAt(id, moment: string): TuiTestSession =
  var args = @["--story=" & id, "--theme=dark", "--cols=" & $LaptopCols,
               "--rows=" & $LaptopRows]
  if moment.len > 0: args.add "--moment=" & moment
  result = newTuiTest(appBinaryPath(Stem), args)
    .width(LaptopCols).height(LaptopRows)
    .envSet("TERM", "xterm-256color")
    .envSet("COLORTERM", "truecolor")
    .envSet("LANG", "en_US.UTF-8")
    .spawn()
  waitForCompleteFrame(result, LaptopCols, LaptopRows)

proc screenTextProblems(sess: var TuiTestSession; m: AhTuiMount): seq[string] =
  ## Every row the terminal shows against the in-process drawing's.
  for r in 0 ..< m.rows:
    var shown = ""
    for c in 0 ..< m.cols:
      let cell = sess.cellAt(r, c)
      if cell.width == 0: continue
      shown.add(if cell.rune.int32 == 0: " " else: $cell.rune)
    let drawn = cellsText(m.canvas.grid, r, 0, m.cols)
    if shown != drawn:
      result.add "row " & $r & ": the terminal shows '" & shown.strip & "', the drawing '" &
                 drawn.strip & "'"
      if result.len >= 3: return

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

putEnv("AGENT_HARBOR_FIXTURES", AgentHarborFixtureRoot)
compileChildApp(Stem)

suite "CTF-P1c: the playback stories are declared once, in every host":
  test "every playback story id exists in the web, GPUI and terminal hosts":
    let stories = playbackStories()
    ck stories.len >= MinimumPlaybackStories
    var surfaces: HashSet[string]
    for story in stories: surfaces.incl story.surface
    # One per surface the hosts draw.
    ck surfaces.len == GpuiAgentHarborSurfaces.len
    ck surfaces.len == TuiAgentHarborSurfaces.len
    # The terminal story host lists its stories from the same declaration;
    # its listing is read from the binary, not computed here.
    let listing = execCmdEx(appBinaryPath(Stem) & " --list").output.splitLines
    # The web: StoryBook's index and the section's CSF module, as the
    # generator writes them (`just storybook-stories`).
    var indexed: HashSet[string]
    for entry in parseJson(storyIndex(@[section]))["stories"]:
      indexed.incl entry["id"].getStr & " " & entry["surface"].getStr & " " &
                   entry["fixture"].getStr
    let csf = csfModule(section)
    for story in stories:
      let id = storybookId(section, story)
      checkpoint id
      ck hasGpuiRendering(story.surface)
      ck hasTuiRendering(story.surface)
      ck id in listing
      ck (id & " " & story.surface & " " & story.fixture) in indexed
      ck ("export const " & story.exportName & " = story(\"" & story.kind & "\", \"" &
          story.surface & "\", \"" & story.fixture & "\"") in csf

suite "CTF-P1c: the three hosts agree at every named moment":
  test "test_ctf_p1c_playback_stories_agree_at_each_moment":
    var failures: seq[string]
    var compared = 0
    var spotted = 0
    for story in playbackStories():
      let names = playbackScenario(playbackScenarioNameOf(story.fixture)).momentNames
      ck names.len == 10
      var h = mount(story)
      var seen: seq[(string, seq[string])]
        ## What the web showed at each moment going forward.
      template compare(moment, how: string) =
        failures.add h.agreement(moment, how)
        inc compared
        if moment in spotMomentsOf(story.surface): inc spotted
      compare("", "opened")
      seen.add ("", h.factsOf(hWeb))
      # Forward: the web by Next, GPUI by Play on its clock then Pause, the
      # terminal by stepping entry by entry.
      for name in names:
        h.clickWeb(pcNext)
        let source = h.gpui.playback.source
        let due = source.scenario.momentMs(name)
        h.clickGpui(pcPlay)
        h.clocks[hGpui].advance(float(due - source.currentMs))
        h.clickGpui(pcPlay)   # now Pause
        var steps = 0
        while h.tui.playback.currentMoment != name and steps < 200:
          h.keyTui("n")
          inc steps
        compare(name, "played forward")
        seen.add (name, h.factsOf(hWeb))
      # Backward, by each host's Previous control: a seek backwards rebuilds.
      for i in countdown(names.high - 1, 0):
        h.clickWeb(pcPrevious)
        h.clickGpui(pcPrevious)
        h.keyTui("[")
        compare(names[i], "sought back")
        if h.factsOf(hWeb)[1 .. ^1] != seen[i + 1][1][1 .. ^1]:
          failures.add storybookId(section, story) & " at " & names[i] &
                       ": sought back, the web shows another state than when it played there"
      h.clickWeb(pcPrevious)
      h.clickGpui(pcPrevious)
      h.keyTui("[")
      compare("", "sought back")
      h.dispose()
      # Opened directly at each moment: the same as when played there.
      for (name, wanted) in seen:
        var o = mount(story, name)
        failures.add o.agreement(name, "opened at the moment")
        inc compared
        if o.factsOf(hWeb)[1 .. ^1] != wanted[1 .. ^1]:
          failures.add storybookId(section, story) & " at " & momentName(name) &
                       ": opened there, the web shows another state than when it played there"
        o.dispose()
    if failures.len > 0:
      echo "Playback stories whose hosts disagree (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck compared >= MinimumPlaybackStories * 31
    ck spotted >= SpotChecks.len
    echo "  compared ", compared, " moments (", spotted, " with hand-written facts)"

  test "the story host opens each moment on a real terminal":
    var failures: seq[string]
    var shown = 0
    for story in playbackStories():
      let id = storybookId(section, story)
      let names = playbackScenario(playbackScenarioNameOf(story.fixture)).momentNames
      for name in @[""] & names:
        let m = mountStory(story, LaptopCols, LaptopRows, dmDark, newTestClock(), name)
        var sess = spawnAt(id, name)
        let problems = screenTextProblems(sess, m)
        if problems.len > 0:
          failures.add id & " at " & momentName(name) & ": " & problems.join("; ")
        else: inc shown
        sess.send("q")
        sess.close()
        m.dispose()
    if failures.len > 0:
      echo "Moments the story host shows otherwise on a terminal (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck shown >= MinimumPlaybackStories * 11

  test "the story host's keys play and seek on a real terminal":
    # The keys a reader presses, through the pty: `]` to the next named
    # moment twice, `[` back one (a seek backwards), each frame the same as
    # the in-process drawing driven by the same keys.
    for story in playbackStories():
      let id = storybookId(section, story)
      checkpoint id
      let m = mountStory(story, LaptopCols, LaptopRows, dmDark, newTestClock())
      var sess = spawnAt(id, "")
      for key in ["]", "]", "["]:
        ck m.handleInput(key)
        sess.send(key)
        sess.waitForText(m.playback.momentLabel, initDuration(seconds = 10))
        waitForCompleteFrame(sess, LaptopCols, LaptopRows)
        ck screenTextProblems(sess, m).len == 0
      ck m.playback.currentMoment == m.playback.momentNames[0]
      sess.send("q")
      sess.close()
      m.dispose()

  test "every control of every host's bar moves the three hosts alike":
    # The agreement above drives each host forward by a different control
    # (the web by Next, GPUI by Play, the terminal by Step) and all three
    # back by Previous. Here every control is pressed in every host from the
    # same state, the terminal's by a click on its button or by its key, and
    # after each press the hosts must agree and the press must have done
    # what its control does.
    type By = enum byClick, byKey
    const Script = [(pcStep, byClick), (pcStep, byKey), (pcStep, byClick),
                    (pcPlay, byKey), (pcPlay, byClick), (pcNext, byClick),
                    (pcPrevious, byClick), (pcStep, byKey), (pcRewind, byKey),
                    (pcStep, byClick), (pcNext, byKey), (pcPlay, byClick),
                    (pcPlay, byKey), (pcPrevious, byKey), (pcRewind, byClick)]
    const PlayedMs = 45_000.0
      ## How long the clocks run while a story plays.
    var failures: seq[string]
    var pressed = 0
    for story in playbackStories():
      let id = storybookId(section, story)
      var h = mount(story)
      for i, (control, by) in Script:
        let at = id & " after " & $control & " by " & $by & " (press " & $(i + 1) & ")"
        let before = h.web.pb.source.position
        let nextEntryMs = h.web.pb.source.nextMs
        let wasPlaying = h.web.pb.playing
        h.clickWeb(control)
        h.clickGpui(control)
        if by == byKey: h.keyTui(TuiKeys[control]) else: h.clickTui(control)
        inc pressed
        if h.web.pb.playing:
          for clock in h.clocks: clock.advance(PlayedMs)
        discard h.hostsFacts(at, failures)
        let positions = [h.web.pb.source.position, h.gpui.playback.source.position,
                         h.tui.playback.source.position]
        if positions[1] != positions[0] or positions[2] != positions[0]:
          failures.add at & ": the web, GPUI and terminal playbacks are at entries " & $positions
        # What the control does by definition, on the web's playback (the
        # other two are held to it above).
        let after = h.web.pb.source.position
        case control
        of pcStep:
          # One step: the head at the next entry's time, every entry due
          # then delivered (several entries can share a time).
          if after <= before or h.web.pb.source.currentMs != nextEntryMs:
            failures.add at & ": Step moved from entry " & $before & " to " & $after &
                         ", the head to " & $h.web.pb.source.currentMs & " ms, not to the next " &
                         "entry's " & $nextEntryMs & " ms"
        of pcRewind:
          if after != 0 or h.web.pb.playing:
            failures.add at & ": Rewind left the playback at entry " & $after
        of pcPlay:
          if wasPlaying == h.web.pb.playing and not h.web.pb.finished:
            failures.add at & ": Play/Pause left the playback " & h.web.pb.stateLabel
        of pcNext, pcPrevious:
          if h.web.pb.currentMoment.len == 0 and after != 0:
            failures.add at & ": " & $control & " left the playback between moments"
      h.dispose()
    if failures.len > 0:
      echo "Presses after which the hosts disagree (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck pressed == playbackStories().len * Script.len

suite "CTF-P1c: the comparison can fail":
  # Positive controls: a host at another moment, and a drawing that does not
  # follow its viewmodel, must each be reported, or the green runs above
  # would mean nothing.
  test "one host a moment ahead is a disagreement naming the story and the moment":
    let story = playbackStories()[0]
    var h = mount(story)
    ck h.agreement("", "opened").len == 0
    h.keyTui("]")
    let problems = h.agreement("", "opened").join(" ")
    ck problems.contains(storybookId(section, story))
    ck problems.contains("the web and terminal disagree")
    ck problems.contains("the terminal host is at")
    h.dispose()

  test "a hand-written fact no host shows is reported for every host":
    let story = playbackStories()[0]
    var h = mount(story)
    let facts = h.factsOf(hWeb)
    ck spotProblems(story.surface, "", facts).len == 0
    ck spotProblems(story.surface, "", facts[0 .. ^2]).len +
       spotProblems(story.surface, "", facts[1 .. ^1]).len > 0
    h.dispose()

suite "CTF-P1c: assertion count":
  test "every assertion ran":
    echo "CHECKS: ", countedAssertions
    check countedAssertions >= 20
