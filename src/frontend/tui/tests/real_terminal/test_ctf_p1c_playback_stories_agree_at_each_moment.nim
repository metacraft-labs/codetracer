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
##     rendered on IsoNim's `MockRenderer` and driven by presses on the bar's
##     buttons, resolved as the page's one pointer listener resolves them
##     (`viewmodel/input/element_press`: the router over the base keymap,
##     then the operation the button carries) and performed by the story
##     host's procedure (`performPlaybackOperation`). This is the StoryBook mount (`storybook_components.nim`'s
##     `mountAgentHarborVM` and `mountPlaybackChrome`) minus the browser: the
##     same story constructor over the same playback, the same generic view
##     instantiated for the mock DOM instead of `WebRenderer`, the strip told
##     the laptop width the browser mount measures. The browser half — the
##     URL parameter and the bar under a real StoryBook story — is the
##     `agent-harbor-playback` play check that `just storybook-check-render`
##     runs.
##   * GPUI — `gpui/agent_harbor/ah_stories.mountAgentHarborStoryGpui`, the
##     GPUI story host's mount, in a real isonim-gpui shadow tree (the shim
##     in process; no window), driven by presses (`mousedown`) dispatched
##     through the shim at its playback bar (`ah_playback_bar.nim`), which the
##     story host routes through its router (`ah_stories.playbackPresses`),
##     and once by Play with its clock advanced to the moment, then Pause.
##   * TERMINAL — `tui/agent_harbor/ah_tui_stories.mountStory`, the terminal
##     story host's mount, driven by its keys (`n` step, `[` and `]` the
##     previous and next named moment), redrawn as the host redraws it
##     (`idle`); and the story host itself, spawned in a real pty with
##     `--moment=<name>` for every named moment, at the laptop and sidebar
##     sizes (`ah_tui_stories.sizesOf`) in both colour modes, its screen
##     compared cell by cell (glyph, ink and ground) with the in-process
##     drawing at that moment.
##
## What is compared is the CTF-P1b cover tests' facts read off each drawing
## (the GPUI `data-ah-*` attributes, the terminal's `AhNode` facts, the web
## views' classes and text): which tabs a strip draws, their labels,
## attention and the active one, `+N`; the list's tree nodes with their
## counts and its rows with their states; the initiative bar's tabs with
## their `n/m` and state, its recording buttons and their states, the
## sessions started elsewhere and the inbox; the Initiatives panel's rows,
## current milestones and session lines; the progress panel's headline,
## status groups and milestones with their deliverable and test counts; the
## fleet's filter counts and rows with a failed row's reason and the
## activity lines each row shows; and each bar's readout (the moment and the
## time). They are compared:
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
## And every story's moments must change it: `MomentChanges`, written by hand
## from the scenarios' scripts, lists the surfaces each moment's entries
## visibly change. A story's moment list (`storyMomentNames`, from the
## scenario's views) must be exactly the moments that name its surface, in
## time order, and at each of them the story must show other facts (less the
## bar's readout) than at the moment before it on its list; every moment
## names a surface of a story over its scenario.
##
## THE ORACLE IS NOT ONE HOST AGAINST ITSELF. At every moment the three hosts
## are held to each other, and at the moments `SpotChecks` names the facts
## written out by hand from the scenario's script
## (nim-agents-isonim-viewmodels `playback_scenarios.nim`) must appear in each
## host's drawing, and those written `!<fact>` must not (a failed row's reason
## said a second time as its activity line). So a host that draws another state disagrees with the
## other two, and a defect all three share (the playback, a viewmodel, a
## story constructor) fails the hand-written facts.
##
## With `CTF_P1C_TUI_OUT=<dir>` the real-terminal test also writes each
## screen it read back at a named moment as `<capture id>.svg` in its colours
## (TermAssert `renderColourSvg`) and `<capture id>.txt`, the capture id being
## `ah_tui_stories.captureIdOf`'s moment name
## (`agent-harbor-<story>-at-<moment>-<size>-<theme>`, the web and GPUI
## moment captures' names): the input of `ci/test/ctf-p1b-tui-capture.sh
## --moments`, as `test_ctf_p1b_tui_views_cover_web_states.nim` is of its
## first-frame captures.
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
import ../../agent_harbor/[ah_tui_playback_bar, ah_tui_canvas]
import ../../../gpui/agent_harbor/ah_stories
import ../../../gpui/agent_harbor/ah_playback_bar
import ../../../viewmodel/views/[isonim_agent_harbor_session_tabs_view,
  isonim_agent_harbor_initiatives_view, isonim_agent_harbor_initiative_tabs_view,
  isonim_agent_harbor_fleet_view, isonim_agent_harbor_playback_view,
  isonim_agent_harbor_session_activity_view, isonim_agent_harbor_inbox_view]
import ../../../viewmodel/input/element_press
import ../../../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                                  keymap_router, scope_path]
from ../../../../common/key_names import kpNative
from ../../../viewmodel/views/isonim_session_tabs_view import SessionTabLabelClass

const
  Stem = "app_agent_harbor_story"
  LaptopW = 1440
  LaptopH = 900
  LaptopCols = 180
  LaptopRows = 56
  MinimumPlaybackStories = 9
    ## One per P2a surface: the session tab strip, the session list, the
    ## initiative tab bar, the Initiatives and Initiative Progress panels and
    ## the fleet list; the session activity timeline's two (CTF-P2b); and the
    ## Inbox's `InboxPlayback` over `inbox-run` (CTF-P3).

let captureOut = getEnv("CTF_P1C_TUI_OUT")
  ## Where the real-terminal test writes its screens; empty: nowhere.

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

proc stateMark(label: string): string =
  ## The state mark a recording button's drawn label carries after its
  ## number (`1 …` loading, `2 ✕` failed, `3 ?` missing), as ` marked <mark>`;
  ## "" for a bare number. The active button keeps its mark too: the active
  ## recording shows that it is still loading until it is ready.
  var rest = label.strip
  while rest.len > 0 and rest[0] in Digits: rest = rest[1 .. ^1]
  rest = rest.strip
  if rest.len > 0: " marked " & rest else: ""

proc timelineLineFacts(kind, text, role, expanded, state: string): seq[string] =
  ## One timeline line as facts: its kind, its text, the role of its text
  ## and its state; and, for a line that is open, `open | <text>`.
  result.add "line " & kind & " | " & text & " <" & role & ">" &
             (if state.len > 0: " {" & state & "}" else: "")
  if expanded == "true": result.add "open | " & text

proc drawnFacts[N](view: N; surface: string): seq[string] =
  ## The facts a GPUI or terminal drawing of `surface` shows, in drawing
  ## order, one line each (the same lines `webFacts` reads off the web).
  mixin all, attr, first
  case surface
  of "agent-harbor-session-tabs":
    for t in view.all("tab"):
      result.add "tab " & t.fact("label") & " [" & t.attr("attention") & "]" &
                 activeMark(t.attr("active"))
    for o in view.all("overflow"):
      result.add "+N " & o.attr("overflow") & " [" & o.attr("overflow-severity") & "]"
  of "agent-harbor-session-list":
    result.add "summary " & view.fact("summary")
    for g in view.all("folded"):
      result.add "group " & g.fact("title") & " | " & g.fact("progress") & " | " &
                 g.fact("counts") & (if g.attr("folded") == "true": " folded" else: "")
    for row in view.all("row"):
      result.add "row " & row.fact("title") & " | " & row.fact("status") & " [" &
                 row.attr("attention") & "]" & activeMark(row.attr("active"))
  of "agent-harbor-initiative-tabs":
    for t in view.all("tab"):
      let progress = t.fact("progress")
      let state = t.attr("state")
      result.add "tab " & t.fact("label") & (if progress.len > 0: " | " & progress else: "") &
                 (if state.len > 0: " [" & state & "]" else: "") &
                 activeMark(t.attr("active"))
    for b in view.all("recording"):
      result.add "recording " & b.attr("recording") & " " & b.attr("recording-state") &
                 activeMark(b.attr("recording-active")) & stateMark(b.attr("recording-label"))
    for m in view.all("recordings-hidden"):
      result.add "recordings +" & m.attr("recordings-hidden") & " [" &
                 m.attr("recordings-hidden-severity") & "]"
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
                 (if m.attr("current") == "true": " current" else: "") &
                 " | " & m.fact("meta")
  of "agent-harbor-fleet":
    var counts: seq[string]
    for f in view.all("filter-count"): counts.add f.attr("filter-count")
    result.add "filters " & counts.join(" ")
    for row in view.all("row"):
      result.add "row " & row.fact("title") & " | " & row.fact("status") & " [" &
                 row.attr("category") & "]"
      # Why a failed row failed, and the activity lines it shows: the
      # reason once, as the failure (never again as an activity line).
      for f in row.all("failure"): result.add "failure " & f.attr("failure")
      for a in row.all("activity"): result.add "activity " & a.attr("activity")
  of "agent-harbor-inbox":
    # CTF-P3: the counts, where the walk is, auto-switch, the rows in the
    # server's order with the item on screen, the explanation strip, and the
    # page under the rows with its answer state.
    result.add "counts " & view.fact("summary")
    result.add "position " & view.fact("stepper-position")
    result.add "auto-switch " & view.fact("inbox-auto-switch")
    for row in view.all("item"):
      result.add "item " & row.attr("item") &
                 (if row.attr("current") == "true": " on screen" else: "")
    for s in view.all("strip"): result.add "strip " & s.attr("strip")
    for k in view.all("item-kind"): result.add "page " & k.attr("item-kind")
    for ph in view.all("phase-text"): result.add "answer " & ph.attr("phase-text")
  of "agent-harbor-session-activity":
    result.add "status " & view.attr("session-status")
    for n in view.all("notice"): result.add "notice " & n.attr("notice")
    for l in view.all("line"):
      result.add timelineLineFacts(l.attr("line-kind"), l.attr("text"), l.attr("role"),
                                   l.attr("expanded"), l.attr("state"))
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
      let severity = o.tokenAfter("ah-att-")
      result.add "+N " & o.textContent.strip(chars = {'+'}) & " [" &
                 (if severity.len > 0: severity else: "none") & "]"
  of "agent-harbor-session-list":
    result.add "summary " & view.textOf("ah-session-list-summary")
    for g in view.byClass("ah-session-group-header"):
      result.add "group " & g.textOf("ah-session-group-title") & " | " &
                 g.textOf("ah-tab-progress") & " | " & g.textOf("ah-session-group-counts") &
                 (if g.textOf("ah-session-group-fold") == "\xE2\x96\xB8": " folded" else: "")
    for row in view.byClass("ah-session-row"):
      result.add "row " & row.textOf("ah-session-row-title") & " | " &
                 row.textOf("ah-session-row-status") & " [" & row.tokenAfter("ah-att-") & "]" &
                 (if row.hasClass("ah-session-row-active"): " active" else: "")
  of "agent-harbor-initiative-tabs":
    for t in view.byClass("ah-tab"):
      if t.hasClass("ah-tab-notice"): continue
      let progress = t.textOf("ah-tab-progress")
      let state = t.tokenAfter("ah-ist-")
      result.add "tab " & t.textOf(SessionTabLabelClass) &
                 (if progress.len > 0: " | " & progress else: "") &
                 (if state.len > 0: " [" & state & "]" else: "") &
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
                 (if b.hasClass("ah-rec-active"): " active" else: "") & stateMark(b.textContent)
    for m in view.byClass("ah-rec-more"):
      let severity = m.tokenAfter("ah-att-")
      result.add "recordings " & m.textContent & " [" &
                 (if severity.len > 0: severity else: "none") & "]"
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
      var meta = ""
      # The meta line's words in drawing order (the failing count between
      # the text before and after it), without the CURRENT tag.
      for host in m.byClass("ah-milestone-meta"):
        for ch in host.children:
          if ch.hasClass("ah-milestone-meta-text") or ch.hasClass("ah-milestone-tests-failing"):
            meta.add ch.textContent
      result.add "milestone " & m.textOf("ah-milestone-id") &
                 (if m.hasClass("ah-milestone-current"): " current" else: "") &
                 " | " & meta
  of "agent-harbor-fleet":
    var counts: seq[string]
    for f in view.byClass("ah-fleet-filter-count"): counts.add f.textContent
    result.add "filters " & counts.join(" ")
    for row in view.byClass("ah-fleet-row"):
      result.add "row " & row.textOf("ah-fleet-row-title") & " | " &
                 row.textOf("ah-fleet-status-label") & " [" & row.tokenAfter("ah-fleet-cat-") & "]"
      for f in row.byClass("ah-fleet-row-failure"): result.add "failure " & f.textContent
      for a in row.byClass("ah-fleet-activity-line"): result.add "activity " & a.textContent
  of "agent-harbor-session-activity":
    let a = proc(n: MockNode; name: string): string =
      if n.attributes.hasKey(name): n.attributes[name] else: ""
    let panel = view.byClass("agent-harbor-activity")
    result.add "status " & (if panel.len > 0: panel[0].a("data-ah-session-status") else: "")
    for n in view.byClass("ah-activity-notice"): result.add "notice " & n.a("data-ah-notice")
    for n in view.byClass("ah-activity-error"): result.add "notice " & n.a("data-ah-notice")
    for l in view.byClass("ah-activity-line"):
      result.add timelineLineFacts(l.a("data-ah-line-kind"), l.a("data-ah-text"),
                                   l.a("data-ah-role"), l.a("data-ah-expanded"),
                                   l.a("data-ah-state"))
  of "agent-harbor-inbox":
    let a = proc(n: MockNode; name: string): string =
      if n.attributes.hasKey(name): n.attributes[name] else: ""
    result.add "counts " & view.textOf("ah-fleet-summary")
    let stepper = view.byClass("ah-inbox-stepper")
    result.add "position " & (if stepper.len > 0: stepper[0].a("data-ah-position") else: "")
    let auto = view.byClass("ah-auto-switch")
    result.add "auto-switch " & (if auto.len > 0: auto[0].a("data-ah-auto-switch") else: "")
    for row in view.byClass("ah-inbox-row"):
      result.add "item " & row.a("data-ah-item") &
                 (if row.hasClass("ah-inbox-row-current"): " on screen" else: "")
    for s in view.byClass("ah-inbox-strip"): result.add "strip " & s.textContent
    for h in view.byClass("ah-item-head"): result.add "page " & h.a("data-ah-kind")
    for ph in view.byClass("ah-item-phase"): result.add "answer " & ph.textContent
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

proc mountWeb(story: CodeTracerStory; clock: ClockBase; moment = "";
              widthPx = LaptopW): WebMount =
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
      vm.stripWidthPx.val = widthPx
      m.view = renderAgentHarborTabStrip[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-session-list":
      let vm = createSessionListStoryVM(story.fixture, pb)
      m.view = renderAgentHarborSessionList[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-initiative-tabs":
      let vm = createInitiativeTabsStoryVM(story.fixture, pb)
      vm.stripWidth.val = widthPx
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
    of "agent-harbor-session-activity":
      let vm = createSessionActivityStoryVM(story.fixture, pb)
      m.view = renderAgentHarborSessionActivity[MockRenderer, MockNode](r, vm)
      disposeVm = proc() = vm.dispose()
    of "agent-harbor-inbox":
      # `storybook_components`' Inbox mount: the panel over the story's
      # viewmodel and context, its pages visible while it is mounted.
      let vm = createInboxStoryVM(story.fixture, pb)
      m.view = renderAgentHarborInboxPanel[MockRenderer, MockNode](r, vm,
                                                                    inboxStoryContext(story.fixture))
      if vm.showPages: vm.setPagesVisible(true)
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

let webRouter = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
  platform: pkLinux, keyProtocol: kpNative))
  ## StoryBook's: the base keymap's pointer rows (`installBaseElementRouting`).

proc clickWeb(h: Hosts; control: PlaybackControl) =
  ## A press on the web bar's button, as the page's one pointer listener
  ## resolves it (`dom_pointer` calls `resolveElementPress`) and StoryBook's
  ## procedure performs it.
  let found = h.web.bar.byClass("ah-playback-" & $control)
  doAssert found.len == 1, "the web bar draws no " & $control & " button"
  let outcome = resolveElementPress(routerResolver(webRouter, SessionFacts()),
    @[element(ekWindow, "window"), pane(StoryPlaybackScope)], ButtonElementKind,
    found[0].attributes.getOrDefault(OperationAttribute, ""), {}, "Click")
  doAssert h.web.pb.performPlaybackOperation(outcome.operation),
    "a press on the web bar's " & $control & " button ran " & outcome.operation

proc gpuiButton(h: Hosts; control: PlaybackControl): GpuiElement =
  for b in h.gpui.bar.all("playback-control"):
    if b.attr("playback-control") == $control: result = b
  doAssert not result.isNil, "the GPUI bar draws no " & $control & " button"

proc clickGpui(h: Hosts; control: PlaybackControl) =
  ## A primary press on the GPUI bar's button, through the shim, as a window
  ## delivers one (`mousedown`, the left button).
  doAssert gpui_renderer.fireEvent(h.gpuiButton(control), "mousedown",
    GpuiEvent(kind: gekPointerDown)) > 0,
    "the GPUI bar's " & $control & " button heard no press"

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
  Instruction = "Add jitter to the upload client's retries, so clients that fail " &
    "together do not retry together."
  Pipeline = "pytest -q | tee test.log | tail -n 5"
  Question = "Use full jitter or equal jitter for the retry delay?"

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
    "summary 4 sessions" & Dot & "1 running" & Dot & "1 failed" & Dot & "2 ended"]),
  # The initiative bar over initiative-run: its n/m and its recordings,
  # numbered in the order they appeared, the first active.
  ("agent-harbor-initiative-tabs", "", @[
    "tab Telemetry upload retries | 0/3 [working] active"]),
  ("agent-harbor-initiative-tabs", "trace-loading", @[
    "tab Telemetry upload retries | 1/3 [working] active",
    "recording 1 loading active marked \xE2\x80\xA6"]),
  ("agent-harbor-initiative-tabs", "trace-ready", @["recording 1 ready active"]),
  ("agent-harbor-initiative-tabs", "recording-fails", @[
    "recording 1 ready active", "recording 2 failed marked \xE2\x9C\x95"]),
  ("agent-harbor-initiative-tabs", "recording-reloaded", @[
    "tab Telemetry upload retries | 2/3 [working] active",
    "recording 1 ready active", "recording 2 ready", "recording 3 ready"]),
  # The plan done and the session ended: the initiative's tab ends.
  ("agent-harbor-initiative-tabs", "session-ends", @[
    "tab Telemetry upload retries | 3/3 [ended] active"]),
  # The Initiatives panel over front-ends: the route cache's progress and
  # current milestone move at +210 s.
  ("agent-harbor-initiatives", "", @[
    "initiative Route cache on the new storage layer | 1/4" & Dot &
      "25% | current RC-M1: Data model [working]"]),
  ("agent-harbor-initiatives", "milestone-done", @[
    "initiative Route cache on the new storage layer | 2/4" & Dot &
      "50% | current RC-M2: Core change [working]"]),
  # The progress panel over initiative-run: each milestone's deliverables
  # and tests move with its status (one of two deliverables done and the
  # test pending while in progress, failing while blocked, both done and
  # passing once completed), so a completed milestone never reads 0/2.
  ("agent-harbor-initiative-progress", "", @[
    "headline 0 of 3 milestones" & Dot & "0%",
    "milestone TR-M0 current | 1/2 deliverables" & Dot & "Tests: 1 pending"]),
  ("agent-harbor-initiative-progress", "specification-done", @[
    "headline 1 of 3 milestones" & Dot & "33%",
    "milestone TR-M0 | 2/2 deliverables" & Dot & "Tests: 1 passing",
    "!milestone TR-M0 | 0/2 deliverables" & Dot & "Tests: 1 pending"]),
  ("agent-harbor-initiative-progress", "milestone-blocked", @[
    "headline 1 of 3 milestones" & Dot & "33%",
    "milestone TR-M1 current | 1/2 deliverables" & Dot & "Tests: 1 failing"]),
  ("agent-harbor-initiative-progress", "plan-done", @[
    "headline 3 of 3 milestones" & Dot & "100%"]),
  # The fleet: a row per session, its status following the session.
  ("agent-harbor-fleet", "", @["row " & Config & " | needs input [needs-input]"]),
  # A failed row says why once, as its failure; its activity line is the
  # next thing it did, not the same words again.
  ("agent-harbor-fleet", "migration-fails", @["row " & Migration & " | failed [failed]",
    "failure error: the migration test failed", "activity Ran just test",
    "!activity error: the migration test failed"]),
  # A question answered no longer leads a running row: by +210 s each
  # answered session shows what it did after its answer (the port ran
  # `just lint` at +125 s, the bench reported at +160 s, the config at
  # +210 s), and no session is waiting on a question.
  ("agent-harbor-fleet", "milestone-done", @["activity Ran just lint",
    "activity assistant: Reads are three times faster on the new layer.",
    "activity assistant: The config format is TOML.",
    "!activity Asked a single-choice question"]),
  ("agent-harbor-fleet", "port-completes", @["row " & Port & " | completed [ended]"]),
  # The session activity timeline over session-run (CTF-P2b): the jitter
  # session's events, one line or one group each; the logging session's
  # events never show. Before the instruction the session runs with no
  # event; the reads, searches, commands and edits group from their second
  # of a kind, the thoughts and the model request between them inside the
  # group; the second command runs, then fails with exit 1 (a group counts
  # it and does not break); the question waits in the warning role until
  # the operator's answer starts a second turn; the stop hook's three waits
  # are one line; the session completes with its summary.
  ("agent-harbor-session-activity", "", @["status running", "notice empty"]),
  ("agent-harbor-session-activity", "instruction", @[
    "line turn | " & Instruction & " <label>"]),
  ("agent-harbor-session-activity", "reads-grouped", @[
    "line group | Read 4 files <body>", "!line item | Read src/upload/client.py <body>"]),
  ("agent-harbor-session-activity", "searches-grouped", @[
    "line group | Read 4 files <body>", "line group | Searched 3 times <body>"]),
  ("agent-harbor-session-activity", "command-running", @[
    "line group | Ran 2 shell commands Ran " & Pipeline & " <body> {running}"]),
  ("agent-harbor-session-activity", "command-fails", @[
    "line group | Ran 2 shell commands (1 failed) <body> {failed}",
    "!line group | Ran 2 shell commands Ran " & Pipeline & " <body> {running}"]),
  ("agent-harbor-session-activity", "agent-asks", @["status needs input",
    "line item | " & Question & " <warning>"]),
  ("agent-harbor-session-activity", "answered", @["status running",
    "line item | " & Question & " <body>", "line turn | Full jitter. <label>",
    "line item | Resumed by operator <quiet>"]),
  ("agent-harbor-session-activity", "edits-grouped", @[
    "line group | Edited 3 files +40 \xE2\x88\x9212 <body>"]),
  ("agent-harbor-session-activity", "hook-repeats", @["status needs input",
    "line group | Waiting for input (claude stop hook) \xC3\x973 <quiet>",
    "line item | Plan updated: 3 steps, 2 done, 1 in progress <body>"]),
  ("agent-harbor-session-activity", "agent-replies", @["status running",
    "line item | The retry client backs off with full jitter; 18 tests pass. <body>",
    "!line item | Read src/upload/log.py <body>"]),
  ("agent-harbor-session-activity", "session-completes", @["status completed",
    "line item | Status: completed Retries now wait a random time up to the exponential cap. <ended>"]),
  # The Inbox over inbox-run (CTF-P3): the notes session's feedback request
  # waits from before the run and stays; the route cache asks at +10 s; the
  # logging session's ended turn (boosted: its cache is warm) and the schema
  # migration's urgent permission request arrive at +20 s; the operator
  # presses Next at +30 s (the permission request, top of the order); the
  # boost ends at +40 s and the server reorders, the page staying; the
  # operator allows it at +50 s (answered in place, auto-switch off); turns
  # auto-switch on, takes Next to the question and answers it at +60 s, so
  # the inbox moves to the next item; Previous at +70 s returns to the
  # visited question's page, gone from the inbox; Next at +75 s; the ended
  # turn is answered on another front-end at +80 s (nothing moves); the
  # login request arrives at +90 s and nothing takes the screen.
  ("agent-harbor-inbox", "", @["item run-feedback", "auto-switch off", "!page async_feedback"]),
  ("agent-harbor-inbox", "first-wait", @["item run-question", "item run-feedback",
    "!item run-question on screen"]),
  ("agent-harbor-inbox", "four-waiting", @["item run-permission", "item run-ended-turn", "item run-question",
    "item run-feedback"]),
  ("agent-harbor-inbox", "next", @["position 1 of 4", "item run-permission on screen",
    "page permission_gate"]),
  ("agent-harbor-inbox", "boost-ends", @["item run-permission on screen", "item run-question",
    "item run-ended-turn"]),
  ("agent-harbor-inbox", "answered", @["!item run-permission", "!item run-permission on screen",
    "answer Answer sent; waiting for the agent to continue."]),
  ("agent-harbor-inbox", "auto-switch", @["auto-switch on", "!item run-question",
    "item run-ended-turn on screen"]),
  ("agent-harbor-inbox", "resolved-elsewhere", @["!item run-ended-turn", "item run-feedback"]),
  ("agent-harbor-inbox", "arrives-while-reading", @["item run-feedback", "item run-login",
    "!item run-login on screen"])]

proc momentName(moment: string): string =
  if moment.len == 0: "the first frame" else: moment

# What each named moment changes, written out by hand from the scenarios'
# scripts (nim-agents-isonim-viewmodels `playback_scenarios.nim`): the
# surfaces whose drawing the moment's entries must visibly change. A moment
# names at least one surface of a story over its scenario; a story's moments
# are exactly those that name its surface; and at each of them the story
# must show something else than at the moment before it on its list (its
# facts, less the bar's readout), or the moment is one a reader cannot see
# happen.
const
  Strip = "agent-harbor-session-tabs"
  List = "agent-harbor-session-list"
  Panel = "agent-harbor-initiatives"
  Fleet = "agent-harbor-fleet"
  Bar = "agent-harbor-initiative-tabs"
  Progress = "agent-harbor-initiative-progress"
  Activity = "agent-harbor-session-activity"
  Inbox = "agent-harbor-inbox"

let MomentChanges: seq[tuple[moment: string; surfaces: seq[string]]] = @[
  # front-ends: a session's state moves its tab, its row in the list and in
  # the fleet, and its line in the route cache's Initiatives row when it
  # works for the route cache (the migration, the port, the benchmark, which
  # joins the row when it starts). The route cache's milestone moves the
  # Initiatives row and the list's group header (`n/m`); the config session
  # logs a line at the same moment, which its fleet row shows. The
  # importer's removal moves the Initiatives header's count of sessions in
  # no initiative.
  ("new-session", @[Strip, List, Fleet, Panel]),
  ("port-asks", @[Strip, List, Fleet, Panel]),
  ("bench-asks", @[Strip, List, Fleet, Panel]),
  ("port-answered", @[Strip, List, Fleet, Panel]),
  ("migration-fails", @[Strip, List, Fleet, Panel]),
  ("config-answered", @[Strip, List, Fleet]),
  ("milestone-done", @[List, Fleet, Panel]),
  ("importer-ends", @[Strip, List, Fleet]),
  ("port-completes", @[Strip, List, Fleet, Panel]),
  ("importer-removed", @[Strip, List, Fleet, Panel]),
  # initiative-run: milestones move the bar's n/m and the progress panel;
  # recordings move the bar's recording buttons; the session's end ends the
  # initiative's tab.
  ("specification-done", @[Bar, Progress]),
  ("trace-loading", @[Bar]),
  ("trace-ready", @[Bar]),
  ("recording-fails", @[Bar]),
  ("milestone-blocked", @[Progress]),
  ("second-trace-ready", @[Bar]),
  ("queue-done", @[Bar, Progress]),
  ("recording-reloaded", @[Bar]),
  ("plan-done", @[Bar, Progress]),
  ("session-ends", @[Bar]),
  # session-run: every moment is an event of the session in view, which its
  # timeline draws (a line, a group's count, a group's failed or running
  # mark, the question's role, the header's status); the other session's
  # events interleave and name no moment.
  ("instruction", @[Activity]),
  ("reads-grouped", @[Activity]),
  ("searches-grouped", @[Activity]),
  ("command-running", @[Activity]),
  ("command-fails", @[Activity]),
  ("agent-asks", @[Activity]),
  ("answered", @[Activity, Inbox]),
    # `answered` names a moment of two scenarios: session-run's (the
    # operator's answer starts a second turn) and inbox-run's (the
    # permission request answered in place, CTF-P3).
  ("edits-grouped", @[Activity]),
  ("hook-repeats", @[Activity]),
  ("agent-replies", @[Activity]),
  ("session-completes", @[Activity]),
  # inbox-run (CTF-P3): every moment is an inbox event or an operator's
  # press, which the Inbox panel draws (a row, the order, the item on
  # screen, its page, the answer state, auto-switch).
  ("first-wait", @[Inbox]),
  ("four-waiting", @[Inbox]),
  ("next", @[Inbox]),
  ("boost-ends", @[Inbox]),
  ("auto-switch", @[Inbox]),
  ("prev", @[Inbox]),
  ("resolved-elsewhere", @[Inbox]),
  ("arrives-while-reading", @[Inbox])]

proc changesOf(moment: string): seq[string] =
  for c in MomentChanges:
    if c.moment == moment: return c.surfaces

proc listProblems(story: CodeTracerStory): seq[string] =
  ## The story's moment list against `MomentChanges`: it must name exactly
  ## the scenario's moments that name the story's surface, in time order.
  let scenario = playbackScenario(playbackScenarioNameOf(story.fixture))
  var wanted: seq[string]
  for name in scenario.momentNames:
    if story.surface in changesOf(name): wanted.add name
  let listed = storyMomentNames(story.surface, story.fixture)
  if listed != wanted:
    result.add storybookId(section, story) & ": its moments are " & listed.join(", ") &
      ", but the moments that change it are " & wanted.join(", ")

proc momentChangeProblems(story: CodeTracerStory;
                          seen: seq[(string, seq[string])]): seq[string] =
  ## Every moment of `seen` (the web's facts at each of the story's moments
  ## going forward, the bar's readout first) that names the story's surface
  ## and shows the same as the moment before it on the story's list.
  for i in 1 .. seen.high:
    let (name, facts) = seen[i]
    if story.surface notin changesOf(name): continue
    if facts[1 .. ^1] == seen[i - 1][1][1 .. ^1]:
      result.add storybookId(section, story) & " at " & name & ": shows the same as at " &
        momentName(seen[i - 1][0]) & ", though the moment changes it"

proc spotProblems(surface, moment: string; facts: seq[string]): seq[string] =
  ## A fact written `!<fact>` must NOT be shown.
  for spot in SpotChecks:
    if spot.surface != surface or spot.moment != moment: continue
    for want in spot.facts:
      if want.startsWith("!"):
        if want[1 .. ^1] in facts:
          result.add "the hand-written fact '" & want[1 .. ^1] & "' is shown, and must not be"
      elif want notin facts: result.add "the hand-written fact '" & want & "' is not shown"

proc spotMomentsOf(surface: string): seq[string] =
  for spot in SpotChecks:
    if spot.surface == surface and spot.moment notin result: result.add spot.moment

# ---------------------------------------------------------------------------
# Comparing the hosts
# ---------------------------------------------------------------------------

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

proc themeOf(mode: DesignMode): string = (if mode == dmDark: "dark" else: "light")

proc spawnAt(id, moment: string; cols = LaptopCols; rows = LaptopRows;
             mode = dmDark): TuiTestSession =
  var args = @["--story=" & id, "--theme=" & themeOf(mode), "--cols=" & $cols,
               "--rows=" & $rows]
  if moment.len > 0: args.add "--moment=" & moment
  result = newTuiTest(appBinaryPath(Stem), args)
    .width(cols).height(rows)
    .envSet("TERM", "xterm-256color")
    .envSet("COLORTERM", "truecolor")
    .envSet("LANG", "en_US.UTF-8")
    .spawn()
  waitForCompleteFrame(result, cols, rows)

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

proc hexOf(c: Color): string =
  ## A terminal cell's colour as the drawing spells it (`#rrggbb`).
  case c.kind
  of ckRgb: "#" & toHex(int(c.r), 2).toLowerAscii & toHex(int(c.g), 2).toLowerAscii &
            toHex(int(c.b), 2).toLowerAscii
  of ckIndexed: "indexed:" & $int(c.idx)
  of ckDefault: ""

proc screenColourProblems(sess: var TuiTestSession; m: AhTuiMount): seq[string] =
  ## Every cell's ink and ground the terminal shows against the in-process
  ## drawing's, as the CTF-P1b cover test holds them: the colours a capture
  ## is written in are the drawing's.
  var shown = 0
  let g = m.canvas.grid
  for r in 0 ..< m.rows:
    for c in 0 ..< m.cols:
      let cell = sess.cellAt(r, c)
      if cell.width == 0: continue
      let want = g.styleAt(r, c)
      let fg = hexOf(cell.fg)
      let bg = hexOf(cell.bg)
      if fg != want.fg or bg != want.bg:
        if shown < 3:
          result.add "the terminal shows " & fg & " on " & bg & " at (" & $r & "," & $c &
                     "), the drawing " & want.fg & " on " & want.bg
        inc shown
  if shown > 3: result.add "... and " & $(shown - 3) & " more cells"

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
    # One per surface the hosts draw, except the surfaces declared to have
    # none (`surfacesWithoutPlayback`, each with its reason): both hosts
    # draw every playback surface, and every surface they draw is one or
    # declared.
    var gpuiSurfaces, tuiSurfaces, without: HashSet[string]
    for s in GpuiAgentHarborSurfaces: gpuiSurfaces.incl s
    for s in TuiAgentHarborSurfaces: tuiSurfaces.incl s
    for s in surfacesWithoutPlayback: without.incl s
    ck (surfaces * without).len == 0
    ck without <= gpuiSurfaces and without <= tuiSurfaces
    ck surfaces + without == gpuiSurfaces
    ck surfaces + without == tuiSurfaces
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
    var expectedCompared = 0
      ## Opened, each moment forward, each but the last back, the first
      ## frame back, and each moment and the first frame opened directly.
    var spotted = 0
    for story in playbackStories():
      let names = storyMomentNames(story.surface, story.fixture)
      ck names.len > 0
      failures.add listProblems(story)
      expectedCompared += 3 * names.len + 2
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
      failures.add momentChangeProblems(story, seen)
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
    # Every moment names a surface of a story over its scenario.
    for story in playbackStories():
      let scenario = playbackScenarioNameOf(story.fixture)
      for name in playbackScenario(scenario).momentNames:
        var named = false
        for other in playbackStories():
          if playbackScenarioNameOf(other.fixture) == scenario and
              other.surface in changesOf(name):
            named = true
        if not named:
          failures.add scenario & " at " & name & ": the moment names no playback story's surface"
    if failures.len > 0:
      echo "Playback stories whose hosts disagree (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck compared == expectedCompared
    ck spotted >= SpotChecks.len
    echo "  compared ", compared, " moments (", spotted, " with hand-written facts)"

  test "the story host opens each moment on a real terminal":
    # Every size and colour mode the captures are taken at, so each capture
    # written below is a screen held to the in-process drawing at its moment.
    var failures: seq[string]
    var shown = 0
    var expectedShown = 0
      ## The first frame and each of the story's moments, at every size and
      ## in both modes.
    var written = 0
    var firstFrames = 0
      ## The first frames shown (no capture is written of one).
    for story in playbackStories():
      firstFrames += sizesOf(story.surface).len * 2
      let id = storybookId(section, story)
      let names = storyMomentNames(story.surface, story.fixture)
      expectedShown += (names.len + 1) * sizesOf(story.surface).len * 2
      for name in @[""] & names:
        for (sizeName, cols, rows) in sizesOf(story.surface):
          for mode in [dmDark, dmLight]:
            let at = id & " at " & momentName(name) & " @ " & sizeName & "/" & themeOf(mode)
            let m = mountStory(story, cols, rows, mode, newTestClock(), name)
            var sess = spawnAt(id, name, cols, rows, mode)
            let problems = screenTextProblems(sess, m) & screenColourProblems(sess, m)
            if problems.len > 0:
              failures.add at & ": " & problems.join("; ")
            else: inc shown
            if captureOut.len > 0 and name.len > 0:
              # Written whatever the comparison said: a reader of a failed
              # run sees the screen that failed, and the run fails anyway.
              let p = ahPalette(mode)
              let capture = captureIdOf(id, sizeName, themeOf(mode), name)
              createDir(captureOut)
              writeFile(captureOut / (capture & ".svg"),
                        renderColourSvg(sess.screen, defaultFg = p.textBody,
                                        defaultBg = p.ground))
              writeFile(captureOut / (capture & ".txt"), renderPlain(sess.screen))
              inc written
            sess.send("q")
            sess.close()
            m.dispose()
    if failures.len > 0:
      echo "Moments the story host shows otherwise on a terminal (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck shown + failures.len == expectedShown
    ck shown >= MinimumPlaybackStories * 5 * TuiSizes.len * 2
    if captureOut.len > 0:
      # One capture per story, named moment, size and mode, none skipped.
      ck written == (shown + failures.len) - firstFrames
      echo "  wrote ", written, " terminal captures at named moments to ", captureOut

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

  test "a fact that must not be shown is reported when it is":
    # The failed row's reason said again as its activity line, as the fleet
    # showed it before the viewmodel left that line out.
    let twice = @["row " & Migration & " | failed [failed]",
                  "failure error: the migration test failed",
                  "activity error: the migration test failed", "activity Ran just test"]
    let problems = spotProblems("agent-harbor-fleet", "migration-fails", twice)
    ck problems.len == 1
    ck problems.join(" ").contains("'activity error: the migration test failed' is shown, and must not be")

  test "a moment that changes nothing it names is reported":
    # The same facts at two moments: the second one names the story's
    # surface, so it is reported, naming the story and the moment; a moment
    # that names another surface is not.
    let story = playbackStories()[0]
    var h = mount(story)
    let facts = h.factsOf(hWeb)
    h.dispose()
    var named, other = ""
    for c in MomentChanges:
      if story.surface in c.surfaces and named.len == 0: named = c.moment
      if story.surface notin c.surfaces and other.len == 0: other = c.moment
    ck named.len > 0 and other.len > 0
    let problems = momentChangeProblems(story, @[("", facts), (named, facts)])
    ck problems.len == 1
    ck problems.join(" ").contains(storybookId(section, story) & " at " & named)
    ck momentChangeProblems(story, @[("", facts), (other, facts)]).len == 0
    var moved = facts
    moved[^1] = moved[^1] & " (moved)"
    ck momentChangeProblems(story, @[("", facts), (named, moved)]).len == 0

suite "CTF-P1c: a press on a bar's button is routed":
  # Input-Routing-And-Keymaps.md §5.1: the bars hold no handler that decides
  # what a press does. A user's row for a press on a playback button takes
  # it over, so the press does not move the playback; a bar whose button ran
  # its control itself would move it here.
  test "CONTROL: a user's row for the press takes it over in the GPUI host":
    let story = playbackStories()[0]
    gpui_reset_tree()
    let rebound = parseUserKeymap(
      """[ { "key": "click", "command": "debugger.continue",
             "when": "paneKind == storyPlayback && elementKind == button" } ]""")
    ck rebound.errors.len == 0
    var m = gr.mountAgentHarborStoryGpui(story.surface, story.fixture, LaptopW, LaptopH,
                                         dmDark, "", newTestClock(), "",
                                         keymap = rebound)
    var step: GpuiElement
    for b in m.bar.all("playback-control"):
      if b.attr("playback-control") == $pcStep: step = b
    ck not step.isNil
    ck gpui_renderer.fireEvent(step, "mousedown", GpuiEvent(kind: gekPointerDown)) > 0
    ck m.playback.source.position == 0
    m.dispose()
    # The same press with no user row steps the playback.
    gpui_reset_tree()
    m = gr.mountAgentHarborStoryGpui(story.surface, story.fixture, LaptopW, LaptopH,
                                     dmDark, "", newTestClock(), "")
    step = nil
    for b in m.bar.all("playback-control"):
      if b.attr("playback-control") == $pcStep: step = b
    ck gpui_renderer.fireEvent(step, "mousedown", GpuiEvent(kind: gekPointerDown)) > 0
    ck m.playback.source.position > 0
    # A modified press with no row of its own is the plain press.
    let before = m.playback.source.position
    ck gpui_renderer.fireEvent(step, "mousedown",
      GpuiEvent(kind: gekPointerDown, modifiers: {gmControl})) > 0
    ck m.playback.source.position > before
    m.dispose()

  test "CONTROL: a user's row takes over a key and a press in the terminal host":
    let story = playbackStories()[0]
    let rebound = parseUserKeymap("""[
      { "key": "n", "command": "debugger.continue",
        "when": "paneKind == storyPlayback" },
      { "key": "click", "command": "debugger.continue",
        "when": "paneKind == storyPlayback && elementKind == button" } ]""")
    ck rebound.errors.len == 0
    var m = mountStory(story, LaptopCols, LaptopRows, dmDark, newTestClock(), "",
                       keymap = rebound)
    ck not m.handleInput("n")
    ck m.lastOperation == "debugger.continue"
    var step: AhNode
    for b in m.canvas.root.first("playback").all("playback-control"):
      if b.attr("playback-control") == $pcStep: step = b
    ck not step.isNil
    discard m.handleInput("\x1b[<0;" & $(step.col + 1) & ";" & $(step.row + 1) & "M")
    ck m.lastOperation == "debugger.continue"
    ck m.playback.source.position == 0
    m.dispose()
    # The same key and press with no user row step the playback, each
    # through its row: the key's (`overlay_rows`), the button's operation.
    m = mountStory(story, LaptopCols, LaptopRows, dmDark, newTestClock(), "")
    ck m.handleInput("n")
    ck m.lastOperation == "story-playback.step"
    let afterKey = m.playback.source.position
    ck afterKey > 0
    for b in m.canvas.root.first("playback").all("playback-control"):
      if b.attr("playback-control") == $pcStep: step = b
    discard m.handleInput("\x1b[<0;" & $(step.col + 1) & ";" & $(step.row + 1) & "M")
    ck m.lastOperation == "story-playback.step"
    ck m.playback.source.position > afterKey
    m.dispose()

suite "CTF-P1c: the playback bars' buttons keep their names at every width":
  # At the sidebar's 360px (45 cells) every host draws each control as a
  # glyph (`compactControlLabel`). Each button must still name its control
  # (the web's `aria-label`; GPUI's and the terminal's `accessible-name`,
  # beside the `button` fact that holds what is drawn) and say what it does (the web's `title`;
  # `tooltip`), and the terminal's must carry its key: the glyph alone tells
  # a reader nothing.
  proc nameProblems(host, size: string; pb: AhPlayback; control: PlaybackControl;
                    name, tip: string): seq[string] =
    let at = host & " " & size & " " & $control & ": "
    if name != pb.controlLabel(control):
      result.add at & "named '" & name & "', not '" & pb.controlLabel(control) & "'"
    if tip != controlTitle(control):
      result.add at & "tooltip '" & tip & "', not '" & controlTitle(control) & "'"

  test "every host's bar names each control and says what it does, laptop and sidebar":
    let story = playbackStories()[0]
    var problems: seq[string]
    # The web: one bar at every width (its stylesheet hides the word below
    # 45rem); its buttons' names and tooltips are attributes.
    block:
      let r = MockRenderer()
      let pb = newAhPlayback(story.surface, story.fixture, newTestClock())
      var bar: MockNode
      createRoot proc(disposeRoot: proc()) =
        bar = renderAgentHarborPlaybackBar[MockRenderer, MockNode](r, pb)
      let buttons = bar.byClass(PlaybackButtonClass)
      ck buttons.len == ord(high(PlaybackControl)) + 1
      for i, b in buttons:
        proc attrOf(name: string): string =
          if b.attributes.hasKey(name): b.attributes[name] else: ""
        problems.add nameProblems("web", "any", pb, PlaybackControl(i),
                                  attrOf("aria-label"), attrOf("title"))
        ck b.textOf("ah-playback-glyph") == pb.compactControlLabel(PlaybackControl(i))
    # GPUI, laptop and sidebar.
    for (size, w) in [("laptop", LaptopW), ("sidebar", 360)]:
      gpui_reset_tree()
      let pb = newAhPlayback(story.surface, story.fixture, newTestClock())
      let host = gr.createElement("div")
      drawPlaybackBar(gr, host, pb, ahPalette(dmDark), w, nil)
      let buttons = host.all("playback-control")
      ck buttons.len == ord(high(PlaybackControl)) + 1
      for b in buttons:
        let control = parseEnum[PlaybackControl](b.attr("playback-control"))
        problems.add nameProblems("GPUI", size, pb, control, b.attr("accessible-name"), b.attr("tooltip"))
        if size == "sidebar": ck b.attr("button") == pb.compactControlLabel(control)
    # The terminal, 180 and 45 cells.
    for (size, cols) in [("laptop", LaptopCols), ("sidebar", 45)]:
      let pb = newAhPlayback(story.surface, story.fixture, newTestClock())
      var c = newAhCanvas(cols, 3, ahPalette(dmDark))
      c.drawPlaybackBar(pb, 0)
      let buttons = c.root.all("playback-control")
      ck buttons.len == ord(high(PlaybackControl)) + 1
      for b in buttons:
        let control = parseEnum[PlaybackControl](b.attr("playback-control"))
        problems.add nameProblems("terminal", size, pb, control, b.attr("accessible-name"), b.attr("tooltip"))
        if b.attr("key") != TuiKeys[control]:
          problems.add "terminal " & size & " " & $control & ": key '" & b.attr("key") & "'"
        if size == "sidebar": ck b.attr("button") == pb.compactControlLabel(control)
    for p in problems: echo "  ", p
    ck problems.len == 0

suite "CTF-P1c: the terminal's readout is one group, on a bar of its own":
  # The web and GPUI print `<moment> +m:ss` as one readout after the
  # controls, and draw a hairline over the bar. The terminal's time must
  # start `ReadoutGap` cells after the moment it belongs to (not at the
  # bar's far end), and the bar must stand on a ground of its own, a step off
  # both the window's and a panel's, since the terminal separates areas by
  # their grounds. At every moment's name, so the longest names are held too.
  proc readoutProblems(story: CodeTracerStory; size: string; cols: int;
                       mode: DesignMode; moment: string): seq[string] =
    let pb = newAhPlayback(story.surface, story.fixture, newTestClock())
    pb.openAtMoment(moment)
    let p = ahPalette(mode)
    var c = newAhCanvas(cols, 3, p)
    c.fill(0, 0, cols, 1, c.tone.frame)
    c.fill(1, 0, cols, 1, c.tone.body)
    c.drawPlaybackBar(pb, 2)
    let at = story.surface & " " & size & " " & $mode & " at " & moment & ": "
    let m = c.root.first("playback-moment")
    let t = c.root.first("playback-time")
    if m.isNil or t.isNil:
      return @[at & "no moment or no time drawn"]
    if t.col != m.col + m.width + ReadoutGap:
      result.add at & "the time starts at cell " & $t.col & ", not " &
        $(m.col + m.width + ReadoutGap) & " (" & $ReadoutGap &
        " cells after the moment, which ends at " & $(m.col + m.width) & ")"
    for k in [0, cols div 2, cols - 1]:
      let bg = c.bgAt(2, k)
      if bg == c.tone.frame or bg == c.tone.body:
        result.add at & "the bar's ground at cell " & $k & " is " & bg &
          ", the same as the window's or a panel's"

  test "the time follows the moment, and the bar is a step off what is above it":
    var problems: seq[string]
    for story in playbackStories():
      let names = newAhPlayback(story.surface, story.fixture, newTestClock()).momentNames
      ck names.len > 0
      for (size, cols) in [("laptop", LaptopCols), ("sidebar", 45)]:
        for mode in [dmDark, dmLight]:
          for name in names:
            problems.add readoutProblems(story, size, cols, mode, name)
    for p in problems: echo "  ", p
    ck problems.len == 0

suite "CTF-P1c: the terminal's recording buttons are each a ground of their own":
  # The web and GPUI draw each recording as its own square, equal gaps
  # apart. In the terminal two buttons must be parted by at least one cell
  # of another ground (the tab's), so `2✕` and `3` never read as one block
  # and a failed button's `✕` never takes the gap. At every moment and size
  # that shows two or more recordings, in both modes.
  test "every two recording buttons have a cell of the tab's ground between them":
    var problems: seq[string]
    var pairs = 0
    for story in playbackStories():
      if story.surface != "agent-harbor-initiative-tabs": continue
      let names = newAhPlayback(story.surface, story.fixture, newTestClock()).momentNames
      for (size, cols) in [("laptop", LaptopCols), ("sidebar", 45)]:
        for mode in [dmDark, dmLight]:
          for name in names:
            let m = mountStory(story, cols, LaptopRows, mode, newTestClock(), name)
            let buttons = m.view.all("recording")
            for i in 1 ..< buttons.len:
              let a = buttons[i - 1]
              let b = buttons[i]
              inc pairs
              let at = size & " " & $mode & " at " & name & ", recordings " &
                a.attr("recording") & " and " & b.attr("recording") & ": "
              let gap = b.col - (a.col + a.width)
              if gap < 1:
                problems.add at & "no cell between them"
                continue
              let left = m.canvas.bgAt(a.row, a.col + a.width - 1)
              let right = m.canvas.bgAt(b.row, b.col)
              let between = m.canvas.bgAt(a.row, a.col + a.width)
              if between == left or between == right:
                problems.add at & "the cell between them is on a button's ground (" &
                  between & ")"
    # The scenario shows three recordings side by side on the laptop bar.
    ck pairs > 0
    for p in problems: echo "  ", p
    ck problems.len == 0

suite "CTF-P1c: the terminal's fleet rows take one shape":
  # The web's fleet rows are all one shape at laptop width. The terminal's
  # must be too: every row with its status word on the title's line, or
  # every row with it on a line of its own, never the two mixed in one list;
  # and a status and meta on the title's line end at least two cells before
  # the Agent column, so the id never reads as the start of the agent's cell.
  test "a list's rows all put the status on the same line, with a gutter":
    var problems: seq[string]
    var lists = 0
    for story in playbackStories():
      if story.surface != "agent-harbor-fleet": continue
      let names = newAhPlayback(story.surface, story.fixture, newTestClock()).momentNames
      for mode in [dmDark, dmLight]:
        for name in names:
          let m = mountStory(story, LaptopCols, LaptopRows, mode, newTestClock(), name)
          let at = $mode & " at " & name & ": "
          var shapes: seq[bool]
          for row in m.view.all("row"):
            let status = row.first("status")
            if status.isNil: continue
            let inline = status.row == row.row
            shapes.add inline
            if inline:
              let meta = row.first("meta")
              var agentAt = -1
              for cell in row.all("col"):
                if cell.attr("col") == "agent": agentAt = cell.col
              if not meta.isNil and agentAt >= 0 and agentAt - (meta.col + meta.width) < 2:
                problems.add at & "row '" & row.attr("row") & "': its meta ends " &
                  $(agentAt - (meta.col + meta.width)) & " cell(s) before the Agent column"
          inc lists
          if shapes.len > 1 and true in shapes and false in shapes:
            problems.add at & "rows mix the status on the title's line and below it"
    ck lists > 0
    for p in problems: echo "  ", p
    ck problems.len == 0

suite "CTF-P1c: the terminal's milestone band is the web's":
  # The web bands every other milestone of Initiative Progress at its wide
  # width on `by-mode(colors-ui-surface-primary-secondary-hover,
  # colors-ui-surface-base-card)`: in both modes a step off the panel, in
  # Light a step DARKER. A band lighter than Light's panel reads as a header
  # strip. So a milestone that is not on the panel must be on the web's
  # band, and some must be (the scenario has groups of two and three).
  test "every other milestone sits on the web's band, in both modes":
    var problems: seq[string]
    var banded = 0
    for story in playbackStories():
      if story.surface != "agent-harbor-initiative-progress": continue
      let names = newAhPlayback(story.surface, story.fixture, newTestClock()).momentNames
      for mode in [dmDark, dmLight]:
        let p = ahPalette(mode)
        let want = if mode == dmDark: p.hover else: p.menu
        for name in names:
          let m = mountStory(story, LaptopCols, LaptopRows, mode, newTestClock(), name)
          # A milestone is on the panel (an item of the list), on the band,
          # or (the current one) raised; never on any other ground.
          for ms in m.view.all("milestone"):
            if ms.attr("current") == "true": continue
            let bg = m.canvas.bgAt(ms.row, ms.col + ms.width - 1)
            if bg == want: inc banded
            elif bg != p.panel:
              problems.add $mode & " at " & name & ", " & ms.attr("milestone") &
                ": on " & bg & ", neither the panel's " & p.panel &
                " nor the web's band " & want
    ck banded > 0
    for p in problems: echo "  ", p
    ck problems.len == 0

suite "CTF-P1c: a +N chip takes the most severe status of what it hides":
  # At sidebar width the session strip hides the failed migration behind
  # its `+N` at migration-fails, and the initiative bar hides the failed
  # agent session recording behind the recordings' `+N` at recording-fails
  # (hand-written from the scenarios). In every host the chip must say
  # failed: its status, its failure mark, its words in the error colour and
  # its accessible name; the moment before, it says nothing of the sort.
  proc storyOf(surface: string): CodeTracerStory =
    for story in playbackStories():
      if story.surface == surface: return story
    doAssert false, "no playback story over " & surface

  proc chipsAt(story: CodeTracerStory; moment: string): seq[string] =
    ## Each host's chip as `<host> <status> | <accessible name>`, and in
    ## the terminal and GPUI its mark's colour and its words' colour.
    let web = mountWeb(story, newTestClock(), moment, widthPx = 360)
    let chipClass = if story.surface == "agent-harbor-session-tabs": "ah-tab-overflow-count"
                    else: "ah-rec-more"
    for c in web.view.byClass(chipClass):
      let status = c.tokenAfter("ah-att-")
      result.add "web " & (if status.len > 0: status else: "none") & " | " &
                 c.attributes.getOrDefault("title")
    web.dispose()
    let (count, severity) = if story.surface == "agent-harbor-session-tabs":
                              ("overflow", "overflow-severity")
                            else: ("recordings-hidden", "recordings-hidden-severity")
    gpui_reset_tree()
    let g = gr.mountAgentHarborStoryGpui(story.surface, story.fixture, 360, LaptopH, dmDark,
                                         "", newTestClock(), moment)
    let p = ahPalette(dmDark)
    for c in g.view.all(count):
      var marks: seq[string]
      for m in c.all("mark"): marks.add m.attr("mark")
      let ink = c.first("ink")
      result.add "GPUI " & c.attr(severity) & " | " & c.attr("tooltip") &
                 " | mark " & marks.join(",") &
                 (if marks.len > 0 and marks[0] == p.markOf(saFailed).colour: " (failed)" else: "") &
                 (if not ink.isNil and ink.attr("ink") == p.textError:
                    " | words in the error colour" else: "")
    g.dispose()
    let t = mountStory(story, 45, LaptopRows, dmDark, newTestClock(), moment)
    for c in t.view.all(count):
      var marks: seq[string]
      for m in c.all("mark"): marks.add m.attr("mark")
      let ink = t.canvas.grid.styleAt(c.row, c.col + c.width - 2).fg
      result.add "terminal " & c.attr(severity) & " | " & c.attr("tooltip") &
                 " | mark " & marks.join(",") &
                 (if marks.len > 0 and marks[0] == p.markOf(saFailed).colour: " (failed)" else: "") &
                 (if ink == p.textError: " | words in the error colour" else: "")
    t.dispose()

  test "a failed hidden tab or recording marks the chip failed, in every host":
    let p = ahPalette(dmDark)
    let failedMark = " | mark " & p.markOf(saFailed).colour & " (failed)" &
                     " | words in the error colour"
    for (surface, before, at, title) in [
        ("agent-harbor-session-tabs", "port-answered", "migration-fails",
         "more tabs, 1 failed"),
        ("agent-harbor-initiative-tabs", "trace-ready", "recording-fails",
         "1 more recording, 1 failed to load")]:
      let story = storyOf(surface)
      let then = chipsAt(story, before)
      let now = chipsAt(story, at)
      checkpoint surface & " at " & before & ": " & then.join("; ")
      checkpoint surface & " at " & at & ": " & now.join("; ")
      ck now.len == 3
      for line in then: ck "failed" notin line.split(" | ")[0]
      ck now.len == 3 and now[0].startsWith("web failed | ") and title in now[0]
      ck now.len == 3 and now[1].startsWith("GPUI failed | ") and title in now[1] and
        now[1].endsWith(failedMark)
      ck now.len == 3 and now[2].startsWith("terminal failed | ") and title in now[2] and
        now[2].endsWith(failedMark)

suite "CTF-P1c: assertion count":
  test "every assertion ran":
    echo "CHECKS: ", countedAssertions
    check countedAssertions >= 20
