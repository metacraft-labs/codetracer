## test_run_summary_vm_test.nim
##
## AA-2 — `ct test` runs render in the Agent Activity session feed as a
## drillable summary (`codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.2,
## `codetracer-specs/DeepReview/Agent-Activity-Panel.milestones.org` AA-2).
##
## What is asserted here is the *projection*: the runner's own JSON event
## stream folded into the value the panel paints, plus the two rules that
## decide whether a reviewer is offered a recording at all.
##
## TEST DOUBLE JUSTIFICATION (workspace policy — every mock must be justified
## in the test file's header).  **No mocks stand in for anything under test.**
## Two collaborators are supplied by the test rather than by production, and
## neither substitutes for logic:
##
##   1. The event stream itself is written with the runner's **own**
##      serializer (`ct_test/contracts.eventToJsonLine`), not with hand-rolled
##      JSON, so the projection is exercised against the exact bytes
##      `native_m11_common` / `js_common` / `ruby_common` emit and a change to
##      the wire format breaks these tests rather than sliding past them.  One
##      suite additionally pins a *literal* line, so that serializer and
##      parser cannot drift together into agreement on a format nothing else
##      speaks.  Recording a real test would need a recorder toolchain, a
##      child process and a trace on disk to assert a *rendering* rule — the
##      cross-language recording behaviour has its own suites
##      (`just test-ct-providers`), and duplicating them here would test the
##      runner, not the panel.
##   2. `TraceOpenService` is constructed with a capturing `openProc`.  That is
##      the type's designed seam, not a stand-in for one: `trace_open.nim`
##      exists so the host supplies the opening action, and the production
##      wiring (`ui_js.installAgentActivityTraceOpenService`) is asserted by
##      the Playwright suite.  What the capture makes assertable is the thing
##      that matters headlessly — *whether* a request is issued and with what
##      policy — including the case where it must not be issued at all.
##
## `ReplayDataStore` is built over `MockBackendService`, as every ViewModel
## suite in this directory does; nothing here sends a backend request.

import std/[options, strutils, unittest]

import isonim/core/[signals, computation, owner]

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import viewmodels/test_run_summary_vm
import viewmodels/trace_open

import ../../../../ct_test/contracts

const
  ProviderId = "native-m11"
  RunId = "native-m11:record:single:tests/calc.c::test_add"
  AddId = "native-m11/c/gtest/tests/calc.c::test_add"
  SubId = "native-m11/c/gtest/tests/calc.c::test_sub"
  MulId = "native-m11/c/gtest/tests/calc.c::test_mul"

proc ev(kind: TestEventKind; testId: string;
        status = none(TestResultStatus);
        message = ""; output = ""; durationMs = 0;
        trace = none(TraceMetadata)): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: ProviderId,
    runId: RunId,
    testId: testId,
    status: status,
    message: message,
    output: output,
    durationMs: durationMs,
    trace: trace,
    diagnostic: none(TestDiagnostic))

proc traceFor(path: string): Option[TraceMetadata] =
  some(TraceMetadata(
    traceId: "trace-1",
    recordingId: "rec-1",
    path: path,
    backend: "native",
    entryPoint: "tests/calc.c"))

proc stream(events: openArray[TestEvent]): string =
  ## The runner's NDJSON, produced by the runner's own serializer.
  var lines: seq[string] = @[]
  for event in events:
    lines.add eventToJsonLine(event)
  lines.join("\n")

proc makeStore(): ReplayDataStore =
  createReplayDataStore(newMockBackendService(autoRespond = true).toBackendService())

# ---------------------------------------------------------------------------

suite "AA-2 the event stream projects into a correct run summary":

  test "a three-test run reports every outcome, name and duration":
    let summary = projectTestRun(@[
      ev(tekRunStarted, "", message = "ctest --output-on-failure"),
      ev(tekTestStarted, AddId),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 83),
      ev(tekTestStarted, SubId),
      ev(tekFailure, SubId, some(tsFailed), message = "expected 1, got 2"),
      ev(tekTestFinished, SubId, some(tsFailed), durationMs = 12),
      ev(tekTestStarted, MulId),
      ev(tekTestFinished, MulId, some(tsSkipped), durationMs = 0),
      ev(tekRunFinished, "", some(tsFailed), durationMs = 140),
    ])

    check summary.rows.len == 3
    check summary.passed == 1
    check summary.failed == 1
    check summary.skipped == 1
    check summary.errored == 0
    check summary.running == 0
    check not summary.inProgress
    check summary.durationMs == 140
    check summary.runId == RunId
    check summary.providerId == ProviderId
    check summary.commandLine == "ctest --output-on-failure"

    check summary.rows[0].testId == AddId
    check summary.rows[0].name == "test_add"
    check summary.rows[0].outcome == troPassed
    check summary.rows[0].durationMs == 83
    check summary.rows[1].outcome == troFailed
    check summary.rows[1].diagnostics.len == 1
    check summary.rows[1].diagnostics[0].message == "expected 1, got 2"
    check summary.rows[2].outcome == troSkipped

  test "captured output is attached to the test that produced it":
    let summary = projectTestRun(@[
      ev(tekTestStarted, AddId),
      ev(tekOutput, AddId, output = "first line"),
      ev(tekOutput, AddId, output = "second line"),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 5),
    ])
    check summary.rows[0].output == "first line\nsecond line"

  test "folding event by event equals folding the whole stream":
    # §2.1.2's reason for streaming: the panel renders as events arrive.  The
    # two must not disagree, or the finished card would differ from the one
    # the reviewer watched being built.
    let events = @[
      ev(tekRecordStarted, AddId, message = "ct-mcr record"),
      ev(tekTestStarted, AddId),
      ev(tekOutput, AddId, output = "running"),
      ev(tekRecordingCreated, AddId, trace = traceFor("/tmp/traces/add")),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 41),
      ev(tekRecordFinished, AddId, some(tsPassed), durationMs = 41),
    ]
    var incremental = newTestRunSummary()
    for event in events:
      incremental.ingestTestEvent(event)
    check incremental == projectTestRun(events)

  test "the literal wire line the runner writes is recognised":
    # Serializer and parser could drift together into a private agreement;
    # this pins the shape a third party (a CI artefact, a log) would carry.
    let line = """{"schemaVersion":1,"kind":"test-finished",""" &
      """"providerId":"native-m11","runId":"r1",""" &
      """"testId":"native-m11/c/gtest/tests/calc.c::test_add",""" &
      """"message":"passed","output":"","durationMs":83,""" &
      """"status":"passed","trace":null,"diagnostic":null}"""
    let parsed = parseTestEventLine(line)
    require parsed.isSome
    check parsed.get.kind == tekTestFinished
    check parsed.get.status == some(tsPassed)
    check parsed.get.durationMs == 83

suite "AA-2 a finished run renders passed/failed/skipped and duration":

  test "the collapsed line names only the outcomes that occurred":
    let summary = projectTestRun(@[
      ev(tekRunStarted, ""),
      ev(tekTestStarted, AddId),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 1200),
      ev(tekTestStarted, SubId),
      ev(tekTestFinished, SubId, some(tsFailed), durationMs = 300),
      ev(tekRunFinished, "", some(tsFailed), durationMs = 1500),
    ])
    check summary.summaryText == "1 passed, 1 failed · 1.5s"

  test "durations read at the precision the runner measured":
    check formatDurationMs(0) == "0ms"
    check formatDurationMs(83) == "83ms"
    check formatDurationMs(1500) == "1.5s"
    check formatDurationMs(63_000) == "1m 3s"

  test "a run that reported no tests says so instead of printing 0 passed":
    # The rule AA-1 preserved when it deleted the Tests card: absent data is
    # stated, never rendered as a zero that reads as success.
    let summary = projectTestRun(@[
      ev(tekRunStarted, "", message = "ctest -R nothing"),
      ev(tekRunFinished, "", some(tsPassed), durationMs = 12),
    ])
    check summary.rows.len == 0
    check summary.summaryText == "No tests reported"
    check "0 passed" notin summary.summaryText
    check "0/0" notin summary.summaryText

suite "AA-2 drilling into a test with a recording":

  test "a recorded test carries the trace the runner produced":
    let summary = projectTestRun(@[
      ev(tekRecordStarted, AddId, message = "ct-mcr record"),
      ev(tekTestStarted, AddId),
      ev(tekRecordingCreated, AddId, trace = traceFor("/tmp/traces/add")),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 41),
      ev(tekRecordFinished, AddId, some(tsPassed)),
    ])
    check summary.rows[0].hasRecording
    check summary.rows[0].tracePath == "/tmp/traces/add"
    check summary.rows[0].traceId == "trace-1"
    check summary.rows[0].recordingId == "rec-1"
    check not summary.rows[0].recordingFailed

  test "opening it issues one request through the existing trace-open path":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var opened: seq[TraceOpenRequest] = @[]
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = opened.add request)

      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:1",
        content: stream(@[
          ev(tekRecordStarted, AddId, message = "ct-mcr record"),
          ev(tekTestStarted, AddId),
          ev(tekRecordingCreated, AddId, trace = traceFor("/tmp/traces/add")),
          ev(tekTestFinished, AddId, some(tsPassed), durationMs = 41),
          ev(tekRecordFinished, AddId, some(tsPassed)),
        ]),
        role: aamrAgent)])

      check vm.testRunCount.val == 1
      check vm.openTestRecording("s:1", AddId, topCurrentTab)
      check opened.len == 1
      check opened[0].tracePath == "/tmp/traces/add"
      check opened[0].recordingId == "rec-1"
      check opened[0].testId == AddId
      check opened[0].policy == topCurrentTab

      check vm.openTestRecording("s:1", AddId, topNewTab)
      check opened.len == 2
      check opened[1].policy == topNewTab

      dispose()

suite "AA-2 a test without a recording offers no drill-down":

  test "a plain run records nothing and claims nothing":
    let summary = projectTestRun(@[
      ev(tekRunStarted, "", message = "ctest"),
      ev(tekTestStarted, AddId),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 9),
      ev(tekRunFinished, "", some(tsPassed), durationMs = 9),
    ])
    check not summary.rows[0].hasRecording
    check not summary.rows[0].recordingFailed
    check summary.rows[0].tracePath == ""

  test "asking to open it opens nothing and reports so":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var opened: seq[TraceOpenRequest] = @[]
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = opened.add request)

      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:1",
        content: stream(@[
          ev(tekRunStarted, "", message = "ctest"),
          ev(tekTestStarted, AddId),
          ev(tekTestFinished, AddId, some(tsPassed), durationMs = 9),
          ev(tekRunFinished, "", some(tsPassed), durationMs = 9),
        ]),
        role: aamrAgent)])

      check not vm.openTestRecording("s:1", AddId)
      check opened.len == 0
      # An unknown test and an unknown run are equally inert.
      check not vm.openTestRecording("s:1", "no-such-test")
      check not vm.openTestRecording("no-such-anchor", AddId)
      check opened.len == 0

      dispose()

suite "AA-2 a failed recording shows diagnostics and offers no trace":

  test "a recorder that exits non-zero leaves output and no trace":
    # Exactly what `native_m11_common.recordCommand` emits when ct-mcr fails:
    # failure + record-finished, and deliberately no recording-created.
    let summary = projectTestRun(@[
      ev(tekRecordStarted, AddId, message = "ct-mcr record"),
      ev(tekTestStarted, AddId),
      ev(tekOutput, AddId, output = "ct-mcr: cannot open perf events"),
      ev(tekFailure, AddId, some(tsFailed),
         message = "ct-mcr exited with 1",
         output = "ct-mcr: cannot open perf events"),
      ev(tekRecordFinished, AddId, some(tsFailed), message = "failed"),
    ])
    check summary.rows[0].outcome == troFailed
    check summary.rows[0].recordingAttempted
    check summary.rows[0].recordingFailed
    check not summary.rows[0].hasRecording
    check summary.rows[0].tracePath == ""
    check "cannot open perf events" in summary.rows[0].output
    check summary.rows[0].diagnostics.len == 1
    check summary.rows[0].diagnostics[0].message == "ct-mcr exited with 1"
    check summary.rows[0].diagnostics[0].severity == "error"

  test "a recorder that produced no artefact is errored, not passed":
    let summary = projectTestRun(@[
      ev(tekRecordStarted, AddId, message = "ct-mcr record"),
      ev(tekTestStarted, AddId),
      ev(tekFailure, AddId, some(tsErrored),
         message = "ct-mcr did not produce a non-empty .ct artifact"),
      ev(tekRecordFinished, AddId, some(tsErrored), message = "errored"),
    ])
    check summary.rows[0].outcome == troErrored
    check summary.errored == 1
    check summary.passed == 0
    check summary.rows[0].recordingFailed
    check not summary.rows[0].hasRecording

  test "the panel refuses to open the trace of a failed recording":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var opened = 0
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = inc opened)
      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:1",
        content: stream(@[
          ev(tekRecordStarted, AddId, message = "ct-mcr record"),
          ev(tekFailure, AddId, some(tsFailed),
             message = "ct-mcr exited with 1"),
          ev(tekRecordFinished, AddId, some(tsFailed)),
        ]),
        role: aamrAgent)])
      check not vm.openTestRecording("s:1", AddId)
      check opened == 0
      dispose()

  test "run-level diagnostics survive when no test owns them":
    let summary = projectTestRun(@[
      ev(tekRecordStarted, "", message = "ct-mcr record"),
      ev(tekDiagnostic, "", message = "codetracer-native-recorder not found"),
    ])
    check summary.diagnostics.len == 1
    check summary.diagnostics[0].message ==
      "codetracer-native-recorder not found"
    check summary.rows.len == 0

suite "AA-2 an in-progress run renders incrementally":

  test "each prefix of the stream is a legal, honest summary":
    let events = @[
      ev(tekRunStarted, "", message = "ctest"),
      ev(tekTestStarted, AddId),
      ev(tekTestFinished, AddId, some(tsPassed), durationMs = 20),
      ev(tekTestStarted, SubId),
      ev(tekTestFinished, SubId, some(tsFailed), durationMs = 30),
      ev(tekRunFinished, "", some(tsFailed), durationMs = 60),
    ]
    var summary = newTestRunSummary()

    summary.ingestTestEvent(events[0])
    check summary.inProgress
    check summary.rows.len == 0
    check summary.summaryText == "Running tests…"

    summary.ingestTestEvent(events[1])
    check summary.inProgress
    check summary.running == 1
    check summary.rows[0].outcome == troRunning

    summary.ingestTestEvent(events[2])
    check summary.passed == 1
    check summary.running == 0
    # The run scope is still open, so the panel must not claim the run ended.
    check summary.inProgress

    summary.ingestTestEvent(events[3])
    check summary.inProgress
    check summary.running == 1
    check "1 passed" in summary.summaryText
    check "1 running" in summary.summaryText

    summary.ingestTestEvent(events[4])
    summary.ingestTestEvent(events[5])
    check not summary.inProgress
    check summary.summaryText == "1 passed, 1 failed · 60ms"

  test "a stream cut off mid-test still says the run is in flight":
    let partial = stream(@[
      ev(tekRunStarted, "", message = "ctest"),
      ev(tekTestStarted, AddId),
    ])
    let summary = parseTestRun(partial)
    require summary.isSome
    check summary.get.inProgress
    check summary.get.rows[0].outcome == troRunning

suite "AA-2 recognising a ct test run in the session feed":

  test "ordinary prose is not a test run":
    check parseTestRun("I will now run ct test on the calculator").isNone
    check parseTestRun("").isNone
    check parseTestRun("{\"kind\":\"tool_call\",\"name\":\"bash\"}").isNone
    check parseTestRun("{\"schemaVersion\":1,\"items\":[]}").isNone

  test "non-event lines are kept as framework output, not discarded":
    let text = "$ ct test run --file tests/calc.c --json-events\n" &
      stream(@[
        ev(tekRunStarted, "", message = "ctest"),
        ev(tekTestStarted, AddId),
        ev(tekTestFinished, AddId, some(tsPassed), durationMs = 4),
        ev(tekRunFinished, "", some(tsPassed), durationMs = 4),
      ]) & "\nctest: 1 test from 1 test suite ran."
    let summary = parseTestRun(text)
    require summary.isSome
    check summary.get.rows.len == 1
    check "ct test run --file" in summary.get.frameworkOutput
    check "1 test from 1 test suite ran" in summary.get.frameworkOutput

  test "the feed anchors each run to the message it replaces":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let runText = stream(@[
        ev(tekRunStarted, "", message = "ctest"),
        ev(tekTestStarted, AddId),
        ev(tekTestFinished, AddId, some(tsPassed), durationMs = 4),
        ev(tekRunFinished, "", some(tsPassed), durationMs = 4),
      ])
      vm.setMessages(@[
        AgentActivityMessageEntry(id: "s:0", content: "let me run the tests",
                                  role: aamrAgent),
        AgentActivityMessageEntry(id: "s:1", content: runText, role: aamrAgent),
        AgentActivityMessageEntry(id: "s:2", content: "all good",
                                  role: aamrAgent),
      ])
      check vm.messages.val.len == 3
      check vm.testRuns.val.len == 1
      check vm.testRuns.val[0].anchorId == "s:1"
      check vm.testRunIndex("s:0") == -1
      check vm.testRunIndex("s:1") == 0
      check vm.testRunFor("s:1").isSome
      check vm.testRunFor("s:2").isNone
      dispose()

  test "a session with no ct test run projects no runs at all":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[
        AgentActivityMessageEntry(id: "s:0", content: "hello",
                                  role: aamrUser),
        AgentActivityMessageEntry(id: "s:1", content: "hi", role: aamrAgent),
      ])
      check vm.testRuns.val.len == 0
      check vm.testRunCount.val == 0
      dispose()

  test "two runs in one session are independently addressable":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let first = stream(@[
        ev(tekRunStarted, "", message = "ctest -R add"),
        ev(tekTestStarted, AddId),
        ev(tekTestFinished, AddId, some(tsFailed), durationMs = 4),
        ev(tekRunFinished, "", some(tsFailed), durationMs = 4),
      ])
      let second = stream(@[
        ev(tekRunStarted, "", message = "ctest -R add"),
        ev(tekTestStarted, AddId),
        ev(tekTestFinished, AddId, some(tsPassed), durationMs = 6),
        ev(tekRunFinished, "", some(tsPassed), durationMs = 6),
      ])
      vm.setMessages(@[
        AgentActivityMessageEntry(id: "s:1", content: first, role: aamrAgent),
        AgentActivityMessageEntry(id: "s:5", content: second, role: aamrAgent),
      ])
      check vm.testRuns.val.len == 2
      check vm.testRuns.val[0].summary.failed == 1
      check vm.testRuns.val[1].summary.passed == 1

      # The same test id in both runs must expand independently.
      vm.toggleTest("s:1", AddId)
      check vm.isTestExpanded("s:1", AddId)
      check not vm.isTestExpanded("s:5", AddId)
      dispose()

suite "AA-2 expansion state":

  test "runs and tests are collapsed until asked for, and toggle back":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:1",
        content: stream(@[
          ev(tekRunStarted, "", message = "ctest"),
          ev(tekTestStarted, AddId),
          ev(tekTestFinished, AddId, some(tsPassed), durationMs = 4),
          ev(tekRunFinished, "", some(tsPassed), durationMs = 4),
        ]),
        role: aamrAgent)])

      check not vm.isTestRunExpanded("s:1")
      vm.toggleTestRun("s:1")
      check vm.isTestRunExpanded("s:1")
      vm.toggleTestRun("s:1")
      check not vm.isTestRunExpanded("s:1")

      check not vm.isTestExpanded("s:1", AddId)
      vm.toggleTest("s:1", AddId)
      check vm.isTestExpanded("s:1", AddId)
      vm.toggleTest("s:1", AddId)
      check not vm.isTestExpanded("s:1", AddId)

      dispose()

  test "clearing the conversation clears the runs it carried":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:1",
        content: stream(@[
          ev(tekRunStarted, "", message = "ctest"),
          ev(tekTestStarted, AddId),
          ev(tekTestFinished, AddId, some(tsPassed), durationMs = 4),
          ev(tekRunFinished, "", some(tsPassed), durationMs = 4),
        ]),
        role: aamrAgent)])
      vm.toggleTestRun("s:1")
      vm.clearConversation()
      check vm.testRuns.val.len == 0
      check not vm.isTestRunExpanded("s:1")
      dispose()
