## The Tests panel's and the trace links' web views, held to five rules the
## step 3b visual review (CTF-P4 step 3b-2) found broken:
##
## * **A trace link draws a short label** (`traceLinkLabel`): `trace
##   3f9b2c1e`, `trace 8d7e6f5a on harbor.example.invalid`, `recording
##   test_queue_bound_holds`, never the raw URL, which wraps across lines.
##   A no-break space (`LabelSpace`) holds `trace` to its id, `on` to its
##   host and `recording` to its name, so a label breaks only before `on`.
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
## * **Run comes before Record everywhere**: a row's icons and a sub-row's
##   buttons alike; the `⏺⏵` open control, in a sub-row after both and in a
##   row's cell after its word, is one grouped button named `Record and open
##   on <platform>`.
##
## No mocks beyond IsoNim's mock renderer (the views' DOM): the viewmodels
## are the stories' own (`createTestsStoryVM`, `createTraceLinksStory`),
## over the viewmodels' scripted synthetic sources, so each check reads the
## state a story shows.

import std/[sequtils, strutils, tables, unittest]
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
    check traceLinkLabel(one[1]) == "trace\xC2\xA03f9b2c1e"
    let https = linkSpans(SecondTraceHttps, TestRunsServer, [])
    check https.len == 1
    check traceLinkLabel(https[0]) ==
      "trace\xC2\xA08d7e6f5a on\xC2\xA0harbor.example.invalid"
    let rec = linkSpans(RecordingUrl, TestRunsServer, [])
    check rec.len == 1
    check traceLinkLabel(rec[0]) == "recording\xC2\xA0test_queue_bound_holds"
    check LabelSpace == "\xC2\xA0"
    check traceLinkTitle(https[0]).splitLines[0] == SecondTraceHttps
    check traceLinkLabel(LinkPart(kind: lpText, text: "plain")) == ""

  test "a label never hides what tells two traces apart":
    proc label(id: string): string =
      let parts = linkSpans(AgentHarborTracePrefix & id, TestRunsServer, [])
      check parts.len == 1
      if parts.len == 1: traceLinkLabel(parts[0]) else: ""
    # Only a UUID is cut to its first group.
    check label(OneTraceId) == "trace" & LabelSpace & "3f9b2c1e"
    check label("3F9B2C1E-7A4D-4E8B-9C2F-1A2B3C4D5E6F") == "trace" & LabelSpace & "3F9B2C1E"
    # Not UUIDs: neighbours sharing a prefix keep their ends.
    check label("nightly-run-42") != label("nightly-run-43")
    check label("nightly-run-42") == "trace" & LabelSpace & "nightly-\xE2\x80\xA6n-42"
    check label("relay-depth-metric-0041") != label("relay-depth-metric-0042")
    # A short id, and one of exactly 12 characters, are shown whole.
    check label("a") == "trace" & LabelSpace & "a"
    check label("abc-def") == "trace" & LabelSpace & "abc-def"
    check label("abcdef-12345") == "trace" & LabelSpace & "abcdef-12345"
    # An https form's host is shown as written, with its port.
    let ported = linkSpans("https://Harbor.example.invalid:8443/trace/" & OneTraceId,
                           "https://harbor.example.invalid:8443", [])
    check ported.len == 1
    if ported.len == 1:
      check traceLinkLabel(ported[0]) ==
        "trace" & LabelSpace & "3f9b2c1e on" & LabelSpace & "Harbor.example.invalid:8443"

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
          check shown.startsWith("trace" & LabelSpace) or
                shown.startsWith("recording" & LabelSpace)
          # Breakable only before `on`: no other plain space in a label.
          check shown.count(' ') == shown.count(" on" & LabelSpace)
          check l.attr("title").splitLines[0] == url
          check l.attr("aria-label").startsWith("Trace ") or
                l.attr("aria-label").startsWith("Recording ")
          # The no-break space is the label's alone: the accessible name and
          # the tooltip read as before.
          check LabelSpace notin l.attr("aria-label")
          check LabelSpace notin l.attr("title")
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
        kinds.add l.attr("data-ah-link") & ":" & textOf(l).split(LabelSpace)[0]
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

suite "Run comes before Record everywhere":
  proc controls(n: MockNode): seq[string] =
    ## The `data-ah-control` values under `n`, in document order.
    for c in n.all("data-ah-control"): result.add c.attr("data-ah-control")

  test "a row's icons, then each sub-row's buttons, are Run then Record":
    withTests("row-open", proc(vm: TestRunsVM; root: MockNode) =
      var rows, subs = 0
      for row in root.all("class"):
        if row.hasClass("ah-tests-row-actions"):
          inc rows
          check controls(row) == @["play", "record"]
        if row.hasClass("ah-tests-sub-actions"):
          inc subs
          let c = controls(row)
          check c.len >= 2
          if c.len >= 2: check c[0 .. 1] == @[RunLabel, RecordLabel]
      check rows > 0
      check subs >= 2)

  test "a sub-row's record-and-open is one grouped button, after Record":
    withTests("row-open", proc(vm: TestRunsVM; root: MockNode) =
      var grouped = 0
      for sub in root.all("data-ah-platform"):
        if not sub.hasClass("ah-tests-sub"): continue
        for actions in sub.all("class"):
          if not actions.hasClass("ah-tests-sub-actions"): continue
          let opens = actions.all("data-ah-open", "record-and-open")
          if opens.len == 0: continue
          check opens.len == 1
          let o = opens[0]
          inc grouped
          check o.hasClass("ah-tests-open-grouped")
          check o.hasClass("ct-button-sm-secondary")
          # One control: the pane's glyph stays its text, in the pane's order.
          check textOf(o) == "\xE2\x8F\xBA\xE2\x8F\xB5"
          let label = sub.all("class").filterIt(it.hasClass("ah-tests-sub-platform"))
          check label.len == 1
          if label.len == 1:
            let name = "Record and open on " & textOf(label[0])
            check o.attr("aria-label") == name
            check o.attr("title").startsWith(name)
          # After the Run and Record buttons.
          var order: seq[string]
          for n in actions.all("class"):
            if n.hasClass("ah-tests-open"): order.add "open"
            elif n.attributes.hasKey("data-ah-control"): order.add n.attr("data-ah-control")
          check order.find("open") > order.find(RecordLabel)
          check order.find(RecordLabel) > order.find(RunLabel)
      check grouped > 0)

  test "a row's cell draws the same grouped record-and-open, after its word":
    withTests("row-open", proc(vm: TestRunsVM; root: MockNode) =
      # Each platform's name, from the opened row's sub-rows.
      var names: Table[string, string]
      for sub in root.all("data-ah-platform"):
        if not sub.hasClass("ah-tests-sub"): continue
        let label = sub.all("class").filterIt(it.hasClass("ah-tests-sub-platform"))
        if label.len == 1: names[sub.attr("data-ah-platform")] = textOf(label[0])
      var grouped = 0
      for cell in root.all("data-ah-platform"):
        if not cell.hasClass("ah-tests-cell"): continue
        let opens = cell.all("class").filterIt(it.hasClass("ah-tests-open"))
        if opens.len == 0: continue
        check opens.len == 1
        let o = opens[0]
        # The sub-row's control, not a fork of it.
        check o.hasClass("ah-tests-open-grouped")
        check o.hasClass("ct-button-sm-secondary")
        check o.attr("data-ah-open") == "record-and-open"
        check textOf(o) == "\xE2\x8F\xBA\xE2\x8F\xB5"
        let key = cell.attr("data-ah-platform")
        check key in names
        if key in names:
          inc grouped
          let name = "Record and open on " & names[key]
          check o.attr("aria-label") == name
          check o.attr("title").startsWith(name)
        # The cell's mark and word come first; the control is its last part.
        check cell.children.len > 0
        if cell.children.len > 0: check cell.children[^1] == o
      check grouped > 0)

  test "a kept trace's cell control is grouped too, and keeps its title":
    withTests("recorded", proc(vm: TestRunsVM; root: MockNode) =
      var existing = 0
      for cell in root.all("data-ah-platform"):
        if not cell.hasClass("ah-tests-cell"): continue
        for o in cell.all("class").filterIt(it.hasClass("ah-tests-open")):
          check o.hasClass("ah-tests-open-grouped")
          if o.attr("data-ah-open") != "open-existing": continue
          inc existing
          check textOf(o) == "\xE2\x8F\xB5"
          check o.attr("aria-label").len > 0
          check not o.attr("aria-label").startsWith("Record and open on ")
          check o.attr("title") == o.attr("aria-label")
      check existing > 0)
