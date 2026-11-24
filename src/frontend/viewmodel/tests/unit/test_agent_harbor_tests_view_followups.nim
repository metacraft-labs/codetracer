## The Tests panel's and the trace links' web views, held to five rules the
## step 3b visual review (CTF-P4 step 3b-2) found broken:
##
## * **A trace link draws a short label** (`traceLinkLabel`): `trace
##   3f9b2c1e`, `trace 8d7e6f5a on harbor.example.invalid`, `recording
##   test_queue_bound_holds`, never the raw URL, which wraps across lines.
##   The URL as written is the link's tooltip and its `data-ah-url`; the
##   timeline line's `text` (from which its `copyText` is made) still holds
##   it, and the link's
##   accessible name is still the timeline's `linkName`.
## * **A trace's actions share one look**: `Download` is the same small
##   secondary button as `Load trace` beside it.
## * **A Record that waits on every platform is said once**: an opened row
##   whose every platform's Record waits behind its Run says so once, above
##   its sub-rows, and no sub-row repeats it.
## * **No platform is switched on and silent**: while a run is shown, every
##   platform switched on says something under its Switch; one the run does
##   not include says `not in this run`. Every Tests story fixture is held
##   to it.
## * **A row's icons are named**: the trailing Run and Record icons carry an
##   accessible name saying what they do (`Run <test> on the platforms
##   switched on`), enabled or not, and a tooltip that starts with it.
##
## No mocks beyond IsoNim's mock renderer (the views' DOM): the viewmodels
## are the stories' own (`createTestsStoryVM`, `createTraceLinksStory`),
## over the viewmodels' scripted synthetic sources, so each check reads the
## state a story shows.

import std/[strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import nim_agents/agent_harbor/[test_runs, trace_links]
import nim_agents_isonim_viewmodels/agent_harbor/[synthetic_test_runs, trace_opener_vm]
import ../../views/[isonim_agent_harbor_tests_view, agent_harbor_trace_links_view,
                   agent_harbor_tests_words]
import ../../../stories/agent_harbor_tests_stories

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc collect(n: MockNode; name, value: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name) and (value.len == 0 or n.attributes[name] == value):
    into.add n
  for ch in n.children: collect(ch, name, value, into)

proc all(n: MockNode; name: string; value = ""): seq[MockNode] =
  ## Every node under `n` (itself included) carrying `name`, with `value`
  ## when one is given.
  collect(n, name, value, result)

proc textOf(n: MockNode): string =
  ## The text a reader sees under `n`.
  if n.kind == mnkText: return n.text
  for ch in n.children: result.add textOf(ch)

proc hasClass(n: MockNode; class: string): bool =
  class in n.attr("class").splitWhitespace

proc withTests(fixture: string; body: proc(vm: TestRunsVM; root: MockNode)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createTestsStoryVM(fixture)
    let root = renderAgentHarborTests[MockRenderer, MockNode](MockRenderer(), vm,
      testsStoryContext(fixture))
    body(vm, root)
    vm.dispose()
    disposeRoot()

proc withLinks(fixture: string; body: proc(story: TraceLinksStory; root: MockNode)) =
  createRoot proc(disposeRoot: proc()) =
    let story = createTraceLinksStory(fixture)
    let root = renderAgentHarborTraceLinks[MockRenderer, MockNode](MockRenderer(),
      story.timeline, story.context)
    body(story, root)
    story.timeline.dispose()
    disposeRoot()

const
  OneTraceUrl = AgentHarborTracePrefix & OneTraceId
  SecondTraceHttps = TestRunsServer & "/trace/" & SecondTraceId & "?at=frame-118"
  RecordingUrl = LocalRecordingPrefix & "test_queue_bound_holds?mode=refresh"

suite "a trace link draws a short label (review finding 1)":
  test "the label of each kind":
    let one = linkSpans("see " & OneTraceUrl, TestRunsServer, [])
    check one.len == 2
    check traceLinkLabel(one[1]) == "trace 3f9b2c1e"
    let https = linkSpans(SecondTraceHttps, TestRunsServer, [])
    check https.len == 1
    check traceLinkLabel(https[0]) == "trace 8d7e6f5a on harbor.example.invalid"
    let rec = linkSpans(RecordingUrl, TestRunsServer, [])
    check rec.len == 1
    check traceLinkLabel(rec[0]) == "recording test_queue_bound_holds"
    check traceLinkTitle(https[0]).splitLines[0] == SecondTraceHttps
    check traceLinkLabel(LinkPart(kind: lpText, text: "plain")) == ""

  test "a label never hides what tells two traces apart":
    proc label(id: string): string =
      let parts = linkSpans(AgentHarborTracePrefix & id, TestRunsServer, [])
      check parts.len == 1
      if parts.len == 1: traceLinkLabel(parts[0]) else: ""
    # Only a UUID is cut to its first group.
    check label(OneTraceId) == "trace 3f9b2c1e"
    check label("3F9B2C1E-7A4D-4E8B-9C2F-1A2B3C4D5E6F") == "trace 3F9B2C1E"
    # Not UUIDs: neighbours sharing a prefix keep their ends.
    check label("nightly-run-42") != label("nightly-run-43")
    check label("nightly-run-42") == "trace nightly-\xE2\x80\xA6n-42"
    check label("relay-depth-metric-0041") != label("relay-depth-metric-0042")
    # A short id, and one of exactly 12 characters, are shown whole.
    check label("a") == "trace a"
    check label("abc-def") == "trace abc-def"
    check label("abcdef-12345") == "trace abcdef-12345"
    # An https form's host is shown as written, with its port.
    let ported = linkSpans("https://Harbor.example.invalid:8443/trace/" & OneTraceId,
                           "https://harbor.example.invalid:8443", [])
    check ported.len == 1
    if ported.len == 1:
      check traceLinkLabel(ported[0]) == "trace 3f9b2c1e on Harbor.example.invalid:8443"

  for fixture in ["one-link", "many-links", "local-recording"]:
    test "the drawn links of " & fixture & " name no raw URL":
      withLinks(fixture, proc(story: TraceLinksStory; root: MockNode) =
        let links = root.all("data-ah-url")
        check links.len > 0
        var urls: seq[string]
        for l in links:
          let url = l.attr("data-ah-url")
          urls.add url
          let shown = textOf(l)
          check "://" notin shown
          check shown.startsWith("trace ") or shown.startsWith("recording ")
          check l.attr("title").splitLines[0] == url
          check l.attr("aria-label").startsWith("Trace ") or
                l.attr("aria-label").startsWith("Recording ")
        # The timeline's lines still hold every URL: the label is drawn
        # only, so a line's text and what its Copy copies (derived from it
        # by the viewmodel) are the message's.
        for url in urls:
          var inText = false
          for line in story.timeline.lines:
            if url in line.text: inText = true
          check inText)

  test "the two kinds keep labels of their own":
    withLinks("local-recording", proc(story: TraceLinksStory; root: MockNode) =
      var kinds: seq[string]
      for l in root.all("data-ah-url"):
        kinds.add l.attr("data-ah-link") & ":" & textOf(l).split(' ')[0]
      check "agent-harbor:trace" in kinds
      check "local-recording:recording" in kinds)

suite "a trace's actions share one look (review finding 2)":
  test "Download is the same small secondary button as Load trace":
    withLinks("one-link", proc(story: TraceLinksStory; root: MockNode) =
      let load = root.all("data-ah-control", LoadTraceText)
      check load.len > 0
      var downloads: seq[MockNode]
      for n in root.all("class"):
        if n.hasClass("ah-trace-download"): downloads.add n
      check downloads.len > 0
      for d in downloads:
        check textOf(d) == DownloadText
        for class in ["ct-button-sm-secondary", "ah-trace-button"]:
          check load[0].hasClass(class)
          check d.hasClass(class))

suite "a Record waiting on every platform is said once (review finding 3)":
  test "record-waiting's opened row says it once, above its sub-rows":
    withTests("record-waiting", proc(vm: TestRunsVM; root: MockNode) =
      var open: seq[MockNode]
      for row in root.all("data-ah-test"):
        if row.attr("data-ah-open") == "true": open.add row
      check open.len == 1
      if open.len == 1:
        let subs = open[0].all("data-ah-platform")
        check subs.len >= 2
        check open[0].all("data-ah-waiting", "record").len == 0
        let once = open[0].all("data-ah-waiting", "record-row")
        check once.len == 1
        if once.len == 1:
          check textOf(once[0]) == RecordWaitsOnEveryPlatformText)

  test "a row whose platforms differ keeps each platform's words":
    var row = TestRowView(name: "t", cells: @[TestCellView(recordWaiting: true),
                                               TestCellView()])
    check rowRecordWaitingText(row) == ""
    check cellSaysRecordWaiting(row, row.cells[0])
    check not cellSaysRecordWaiting(row, row.cells[1])
    row.cells[1].recordWaiting = true
    check rowRecordWaitingText(row) == RecordWaitsOnEveryPlatformText
    check not cellSaysRecordWaiting(row, row.cells[0])

suite "no platform is switched on and silent (review finding 4)":
  test "running: Linux arm64 is not in this run":
    withTests("running", proc(vm: TestRunsVM; root: MockNode) =
      let key = platformKey(LinuxArm)
      var heads: seq[MockNode]
      for h in root.all("data-ah-platform", key):
        if h.attributes.hasKey("data-ah-enabled"): heads.add h
      check heads.len == 1
      if heads.len == 1:
        check heads[0].attr("data-ah-enabled") == "true"
        let says = heads[0].all("data-ah-say", "not-in-run")
        check says.len == 1
        if says.len == 1: check textOf(says[0]) == NotInThisRunText)

  for fixture in testsStoryFixtures:
    if fixture == TestsPlaybackFixture: continue
    test "every platform switched on says something while a run is shown: " & fixture:
      withTests(fixture, proc(vm: TestRunsVM; root: MockNode) =
        let run = vm.shownRun
        if run.id.len > 0 and run.platformRuns.len > 0:
          for h in root.all("data-ah-enabled", "true"):
            checkpoint h.attr("data-ah-platform")
            check h.all("data-ah-say").len > 0)

suite "a row's icons are named (review finding 5)":
  for fixture in ["populated", "record-waiting", "no-platform"]:
    test "Run and Record name what they do, enabled or not: " & fixture:
      withTests(fixture, proc(vm: TestRunsVM; root: MockNode) =
        var rows = 0
        for group in vm.groups:
          for row in group.rows:
            for node in root.all("data-ah-test", row.testId):
              if not node.hasClass("ah-tests-row"): continue
              inc rows
              for (kind, name) in [("play", "Run " & row.name & " on the platforms switched on"),
                                   ("record", "Record " & row.name &
                                     " on the platforms switched on that can record")]:
                let icons = node.all("data-ah-control", kind)
                check icons.len == 1
                if icons.len == 1:
                  check icons[0].attr("aria-label") == name
                  check icons[0].attr("title").startsWith(name)
                  if icons[0].attributes.hasKey("disabled"):
                    # Disabled: the tooltip also says why.
                    check icons[0].attr("title").len > name.len
        if vm.groups.len > 0: check rows > 0)

  test "record-waiting's Record icons are disabled and still named":
    withTests("record-waiting", proc(vm: TestRunsVM; root: MockNode) =
      var disabled = 0
      for icon in root.all("data-ah-control", "record"):
        if icon.hasClass("ah-tests-icon-btn") and icon.attributes.hasKey("disabled"):
          inc disabled
          check icon.attr("aria-label").startsWith("Record ")
      check disabled > 0)
