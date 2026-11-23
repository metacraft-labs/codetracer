## The Tests panel's and the trace links' story constructors (CTF-P4).
##
## A story of the `agent-harbor-tests` surface is a `TestRunsVM` built by
## `createTestsStoryVM` over the story's fixture, under the production view
## `isonim_agent_harbor_tests_view`; a story of the `agent-harbor-trace-links`
## surface is a session's `SessionTimelineVM` with the pane's
## `TraceOpenerVM` (`createTraceLinksStory`), under
## `agent_harbor_trace_links_view`. StoryBook and the IsoNim Editor instance
## reach them through `mountCodeTracerStory` (`storybook_components.nim`),
## so both surfaces build the same viewmodels for the same story.
##
## Every story shows invented data only: the synthetic test runs and
## sessions of nim-agents-isonim-viewmodels (`synthetic_test_runs.nim`, the
## `test-run` playback scenario). Their sources are the viewmodels' scripted
## test-run source, so every press a story's reader makes is answered from
## its script and recorded, and nothing reaches a server. The states no data
## shows (`loading`, `error`) are the data-source seam's pending and failing
## sources.
##
## A story fixture names the viewmodel fixture it is built over and what the
## reader has done on it (a row opened, Shift held, Cancel pressed, a trace
## loaded): the constructor does that through the viewmodels' own calls, as
## a reader's presses would, so a story never shows a state the viewmodels
## cannot reach.
##
## This module only says which source and which reader state each fixture
## names; its constructors are called inside a reactive root and the caller
## disposes what they return.

import std/strutils

import isonim/core/[signals, owner]
import nim_agents/agent_harbor/[test_runs, trace_links, operator_actions]
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, scripted_actions,
  synthetic_test_runs, test_runs_vm, trace_opener_vm, session_timeline_vm,
  action_tracker]
import ./agent_harbor_playback
import ../viewmodel/views/agent_harbor_tests_words

export test_runs_vm, trace_opener_vm, session_timeline_vm, agent_harbor_tests_words

# ---------------------------------------------------------------------------
# The Tests panel
# ---------------------------------------------------------------------------

const
  TestsSessionLabel* = "Relay backpressure: bound the relay queues"
    ## The invented session whose change the stories test.
  TestsPlaybackFixture* = "playback-test-run"
    ## The Tests panel's playback story: the `test-run` scenario.
  testsStoryFixtures* = [
    "populated", "running", "finished", "split", "reused", "recording",
    "recorded", "recorded-shift", "row-open", "cancel-confirm", "cancelling",
    "cancelled", "refused-unpushed", "stream-lost", "platforms",
    "record-disabled", "unservable", "one-platform", "no-platform",
    "discovering", "discovery-failed", "not-in-catalog", "filtered", "long",
    "long-keyboard", "selected", "empty", "loading", "error",
    "record-waiting", TestsPlaybackFixture]
    ## Every fixture an `agent-harbor-tests` story may name.
  StreamLostReason* = "the connection to the server reset"
    ## The lost stream's reason in `stream-lost` (invented).
  SelectedTestName* = "test_slow_station_is_told_to_slow_down"
    ## The test `selected` was opened at from the Changes panel.

proc testsSourceFixture(fixture: string): string =
  ## The viewmodel fixture (`synthetic_test_runs.TestRunsFixtureNames`) a
  ## story fixture is built over.
  case fixture
  of "recorded-shift": "recorded"
  of "cancel-confirm", "cancelling": "cancel"
  of "long-keyboard": "long"
  of "record-waiting": "populated"
  else: fixture

proc testsStoryContext*(fixture: string): AgentHarborTestsContext =
  ## The session a Tests story shows, and whether its legend starts open
  ## (`platforms`, which shows what the marks mean).
  AgentHarborTestsContext(sessionLabel: TestsSessionLabel,
                          legendOpen: fixture == "platforms",
                          shiftReachable: true)

proc scriptedOf(vm: TestRunsVM): ScriptedTestRunSource =
  ScriptedTestRunSource(vm.feed.source)

proc createTestsStoryVM*(fixture: string; playback: AhPlayback = nil): TestRunsVM =
  ## The viewmodel of the Tests story named by `fixture`
  ## (`testsStoryFixtures`). Raises `ValueError` for an unknown fixture
  ## rather than showing some other state under the story's name.
  if fixture notin testsStoryFixtures:
    raise newException(ValueError, "no Agent Harbor Tests story fixture named " & fixture)
  if fixture == TestsPlaybackFixture:
    if playback.isNil or playback.fixture != fixture:
      raise newException(ValueError, "the Tests playback story needs its host's playback " &
                         "of " & TestsPlaybackFixture)
    result = newTestRunsVM(playback.source, testRunsScope(), serverOrigin = TestRunsServer)
    result.load()
    return
  let source = testRunsFixture(testsSourceFixture(fixture))
  case fixture
  of "cancelling":
    # The cancel is sent and not answered yet.
    ScriptedTestRunSource(source).script.setRule(oaCancelTestRun, neverAnswered())
  of "record-waiting":
    # The header's Run is sent and not answered yet.
    ScriptedTestRunSource(source).script.setRule(oaStartTestRun, neverAnswered())
  else: discard
  result = newTestRunsVM(source, testRunsScope(), serverOrigin = TestRunsServer)
  result.load()
  let depth = relayTestId("test_depth_metric_reports_each_queue")
  case fixture
  of "recording":
    # The depth metric's row open: on Linux it is being recorded; on macOS,
    # where it passed and nothing is recorded, the open control records and
    # opens (`⏺⏵`).
    result.toggleRow(depth)
  of "recorded":
    # The test whose recording was not kept, opened: no open control, the
    # pane's sentence instead. The depth metric's kept trace is `⏵` in its
    # closed row.
    result.toggleRow(relayTestId("test_queue_bound_holds"))
  of "recorded-shift":
    # Shift held where the host reports it: the kept trace's control records
    # again, then opens (`⟳⏵`), and says so.
    result.shiftHeld.val = true
  of "row-open":
    # A failure with its location and output, and a test that errored with
    # the diagnostic its platform left.
    result.toggleRow(depth)
    result.toggleRow(relayTestId("relay_codec::window::tests::slides"))
  of "cancel-confirm":
    result.cancel()
  of "cancelling":
    result.cancel()
    discard result.confirmCancel()
  of "refused-unpushed":
    discard result.run()
  of "stream-lost":
    discard result.scriptedOf.sendUpdate(TestRunUpdate(kind: truLost, testRunId: "run-2",
                                                       reason: StreamLostReason))
  of "record-disabled", "unservable":
    # Windows x86-64's row open: its Record disabled with the backend's
    # reason; on the unservable Windows arm64, Run refused by name.
    result.toggleRow(depth)
    if fixture == "unservable": discard result.run(RunScope(kind: scTest, testId: depth))
  of "filtered":
    result.setFilter(tfFailing)
    result.setQuery("metric")
  of "long-keyboard":
    # The keyboard far down the long catalog: on its last test (the last
    # row of the last file's group, so far past the list's foot at every
    # size), then `Right` once onto its first platform's cell. The row is
    # put under the keyboard with `select` and the selection taken off
    # again, which leaves exactly the keyboard's row: pressing `Down` the
    # whole way rebuilds every row per press (`focusables`), which does not
    # finish inside the render check's time limit (codetracer-pm issue
    # 2026-11-23, the Tests viewmodel's rows).
    let tests = result.feed.tests
    if tests.len > 0:
      result.select(tests[^1].id)
      result.selected.val = ""
    discard result.runTestsOperation(TestsNextCellOperation)
  of "selected":
    result.select(relayTestId(SelectedTestName))
  of "record-waiting":
    # Run pressed, its start still being sent: the header's Run says
    # `Sending…`, its Record and every cell's Record wait behind it, in
    # words (the study's D31). The depth metric's row is open to show a
    # cell's waiting Record beside its control.
    discard result.run()
    result.toggleRow(depth)
  else: discard

# ---------------------------------------------------------------------------
# The trace links
# ---------------------------------------------------------------------------

const
  traceLinksStoryFixtures* = [
    "one-link", "many-links", "malformed", "connecting", "replaying",
    "unavailable", "gone", "download", "download-failed", "summary",
    "summary-open", "file-links", "local-recording", "link"]
    ## Every fixture an `agent-harbor-trace-links` story may name (`link`
    ## is the timeline's own fixture, for the session timeline's story).
  FileMenuOpenAt* = "src/relay/flow.py"
    ## The ambiguous file link whose menu `file-links` shows open.

type
  TraceLinksStory* = object
    ## A trace-link story's viewmodels and its host's records.
    timeline*: SessionTimelineVM
    context*: AgentHarborTraceLinksContext

proc traceLinksSourceFixture(fixture: string): string =
  case fixture
  of "connecting": "one-link"
  of "summary-open": "summary"
  else: fixture

proc agentTrace(id: string): TraceReference =
  parseTraceReference(AgentHarborTracePrefix & id, TestRunsServer).reference

proc createTraceLinksStory*(fixture: string): TraceLinksStory =
  ## The viewmodels of the trace-link story named by `fixture`
  ## (`traceLinksStoryFixtures`): the session's timeline, the pane's opener
  ## over the same source and tracker, and the host's request record.
  ## Raises `ValueError` for an unknown fixture.
  if fixture notin traceLinksStoryFixtures:
    raise newException(ValueError, "no Agent Harbor trace-link story fixture named " & fixture)
  let source = traceLinkFixture(traceLinksSourceFixture(fixture))
  if fixture == "connecting":
    source.script.setRule(oaOpenTraceReplay, neverAnswered())
  let tracker = newActionTracker()
  let timeline = newSessionTimelineVM(source, TestRunsSessionId,
                                      serverOrigin = TestRunsServer)
  timeline.load()
  let opener = newTraceOpenerVM(source, TestRunsSessionId, tracker)
  result = TraceLinksStory(timeline: timeline, context: AgentHarborTraceLinksContext(
    opener: opener, requests: TraceLinkHostRequests()))
  let trace = agentTrace(OneTraceId)
  case fixture
  of "connecting", "replaying", "unavailable", "gone":
    opener.load(trace)
  of "download", "download-failed":
    opener.download(trace)
  of "summary-open":
    # The recorded run open, and both its tests open: the failure with its
    # kept trace's button, and the test whose recording was not kept.
    for line in timeline.lines:
      if line.itemKind == "test-run" and line.id.endsWith("run-8"):
        timeline.toggle(line.id)
    result.context.openTests = @[relayTestId("test_depth_metric_reports_each_queue"),
                                 relayTestId("test_queue_bound_holds")]
  of "file-links":
    result.context.fileMenuOpen = FileMenuOpenAt
  of "local-recording":
    # The recording's button pressed: the host is asked to open it, and no
    # action is sent.
    let local = parseTraceReference(LocalRecordingPrefix & "test_queue_bound_holds",
                                    TestRunsServer).reference
    opener.load(local)
  else: discard
