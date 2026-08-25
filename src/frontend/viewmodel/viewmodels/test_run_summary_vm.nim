## NOT-A-TEST-LANE-FILE: this is the run-summary VIEWMODEL for Agent Activity
## (AA-2) — production frontend code named after the `ct test` runs it renders,
## hence the `test_*` collision. It declares no `suite`/`test` blocks. Its
## behaviour is asserted by
## `src/tests/gui/tests/agent-activity/test_run_summary_vm_test.nim` (the
## `vm-native` / `vm-js` lanes).

## viewmodels/test_run_summary_vm.nim
##
## AA-2 — a `ct test` execution, as the Agent Activity session feed sees it.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.2: "`ct test`
## executions in the session are rendered as a **summary of the run** rather
## than as raw output: what was run, how many passed, failed and were skipped,
## and how long it took."  The runner already streams exactly that — the
## `test-started` / `recording-created` / `test-finished` events of
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §20.5.5 —
## so this module is a *projection*, never a collector.  Nothing here runs a
## test, reads a file or talks to a process; it turns a stream of `TestEvent`s
## into the value a view paints.
##
## Three rules shape the types below, and each is a milestone deliverable
## rather than a preference:
##
## 1. **A row's drill-down affordance is a fact about the row, not a guess.**
##    `hasRecording` is true only when a `recording-created` event actually
##    carried a trace path.  §2.1.2: "A test with no recording is shown
##    normally with no drill-down affordance — not with an affordance that
##    fails when used."  Because the runner emits `recording-created` *only*
##    after it has a non-empty artefact (see `native_m11_common.recordCommand`,
##    which returns early with `failure` + `record-finished` when the recorder
##    exits non-zero or leaves no `.ct` file), a failed recording structurally
##    cannot produce a trace here.  That is §2.1.2's other rule — "must **not**
##    offer a trace to open (a broken trace tab is worse than none)" — enforced
##    by the shape of the data rather than by a check that could be forgotten.
##
## 2. **Absent data is stated, never rendered as a zero that reads as
##    success.**  This is the rule AA-1 preserved when it deleted the Tests
##    card (`Agent-Activity-Panel.milestones.org`, AA-1 deliverable 4), and
##    AA-2 is what it was preserved *for*.  So `summaryText` refuses to print
##    "0 passed" for a run that reported no tests: it says so in words.
##
## 3. **A run in flight is distinguishable from a finished one.**  §2.1.2's
##    whole reason for streaming events "before process exit" is that the
##    panel need not wait, so `inProgress` is derived from the events seen so
##    far and every intermediate state is a legal, renderable value.
##
## Everything is pure, plain-value and DOM-free — no `cstring`, no JS object,
## no `Option[TraceMetadata]` (the trace is flattened to the three strings
## `TraceOpenRequest` needs) — so the whole contract is assertable headlessly
## on both Nim backends.  See
## `src/tests/gui/tests/agent-activity/test_run_summary_vm_test.nim`,
## registered in `CoreViewModelGateTests`.

import std/[json, options, strutils]

import ../../../ct_test/contracts

type
  TestRunOutcome* = enum
    ## What became of one test.  Wider than the wire's `TestResultStatus`
    ## because a projection of a *partial* stream must be able to say
    ## "started, not finished" — that is the whole point of rule 3 above.
    troRunning = "running"
    troPassed = "passed"
    troFailed = "failed"
    troSkipped = "skipped"
    troErrored = "errored"
    troCancelled = "cancelled"

  TestRunDiagnostic* = object
    ## One recorder/framework diagnostic, reduced to what a feed row shows.
    severity*: string
    message*: string

  TestRunRow* = object
    ## One test inside a run.
    testId*: string
      ## The runner's catalog item id, verbatim.  Stable across events and
      ## used as the row's identity everywhere, including the view's DOM ids.
    name*: string
      ## The short, human-facing name derived from `testId` (see `displayName`).
    outcome*: TestRunOutcome
    durationMs*: int
    output*: string
      ## Captured framework output for this test, in arrival order.  §2.1.2:
      ## "an individual test can be expanded to its status, duration and
      ## captured output."
    diagnostics*: seq[TestRunDiagnostic]
      ## Recorder diagnostics.  §2.1.2 requires these to be *shown* when
      ## recording failed, which is exactly the case where there is no trace.
    tracePath*: string
    traceId*: string
    recordingId*: string
      ## The recording, flattened.  All three are empty unless a
      ## `recording-created` event carried them; see rule 1.
    recordingAttempted*: bool
      ## A `record-started` names this test, so the run was *trying* to
      ## record.  Distinguishes "this run did not record" (no affordance is
      ## expected) from "this run tried to record and failed" (no affordance,
      ## plus diagnostics).

  TestRunSummary* = object
    ## One `ct test` execution.
    runId*: string
    providerId*: string
    commandLine*: string
      ## The command the runner reported in `run-started` / `record-started`.
      ## Quoted, never invented.
    inProgress*: bool
    passed*: int
    failed*: int
    skipped*: int
    errored*: int
    cancelled*: int
    running*: int
    durationMs*: int
    rows*: seq[TestRunRow]
    diagnostics*: seq[TestRunDiagnostic]
      ## Run-level diagnostics — those the runner emitted without a `testId`.
    frameworkOutput*: string
      ## Lines of the stream that were *not* ct-test events, kept verbatim.
      ## §2.1.2: when recording fails "the panel shows the framework output
      ## and recorder diagnostics"; discarding the non-JSON half of a runner's
      ## stdout would throw away precisely the part a human reads.
    openScopes*: int
      ## Run/record scopes started and not yet finished.  Internal to the
      ## incremental projection, but public so a partially-consumed summary
      ## round-trips through a caller that stores it.
    scopeDurationMs*: int
      ## The largest duration any scope-closing event reported, or 0.

proc `==`*(a, b: TestRunDiagnostic): bool {.noSideEffect.} =
  a.severity == b.severity and a.message == b.message

proc `==`*(a, b: TestRunRow): bool {.noSideEffect.} =
  a.testId == b.testId and a.name == b.name and a.outcome == b.outcome and
    a.durationMs == b.durationMs and a.output == b.output and
    a.diagnostics == b.diagnostics and a.tracePath == b.tracePath and
    a.traceId == b.traceId and a.recordingId == b.recordingId and
    a.recordingAttempted == b.recordingAttempted

proc `==`*(a, b: TestRunSummary): bool {.noSideEffect.} =
  a.runId == b.runId and a.providerId == b.providerId and
    a.commandLine == b.commandLine and a.inProgress == b.inProgress and
    a.passed == b.passed and a.failed == b.failed and
    a.skipped == b.skipped and a.errored == b.errored and
    a.cancelled == b.cancelled and a.running == b.running and
    a.durationMs == b.durationMs and a.rows == b.rows and
    a.diagnostics == b.diagnostics and
    a.frameworkOutput == b.frameworkOutput and
    a.openScopes == b.openScopes and a.scopeDurationMs == b.scopeDurationMs

proc hasRecording*(row: TestRunRow): bool {.noSideEffect.} =
  ## Whether this row can be drilled into.
  ##
  ## The single gate for the drill-down affordance, so "shown" and "works"
  ## cannot drift apart (§2.1.2).  A recording exists when the runner said so
  ## *and* named a path; a `recording-created` without one would be a broken
  ## trace tab, which the spec ranks below offering nothing.
  row.tracePath.len > 0

proc recordingFailed*(row: TestRunRow): bool {.noSideEffect.} =
  ## The run tried to record this test and no trace came of it.
  ##
  ## This is the state §2.1.2 singles out: "If recording failed before a trace
  ## was produced, the panel shows the framework output and recorder
  ## diagnostics, and must **not** offer a trace to open."  It is deliberately
  ## *not* the same as `not hasRecording` — a plain `ct test run` records
  ## nothing and has failed at nothing.
  row.recordingAttempted and row.tracePath.len == 0

proc displayName*(testId: string): string {.noSideEffect.} =
  ## The short name for a catalog item id.
  ##
  ## Ids are `provider/language/framework/file::selector`
  ## (`contracts.makeTestItemId`), and the selector is the part a human
  ## recognises.  Falls back to the last path segment, then to the id itself,
  ## because an unrecognised id shape must still render as *something* — a
  ## blank row is indistinguishable from a missing one.
  let separator = testId.rfind("::")
  if separator >= 0 and separator + 2 < testId.len:
    return testId[separator + 2 .. ^1]
  let slash = testId.rfind('/')
  if slash >= 0 and slash + 1 < testId.len:
    return testId[slash + 1 .. ^1]
  testId

proc formatDurationMs*(durationMs: int): string {.noSideEffect.} =
  ## A duration, at the precision a reviewer can act on.
  ##
  ## Sub-second runs are reported in milliseconds because that is the unit the
  ## runner measures in; anything longer rounds, because trailing milliseconds
  ## on a two-minute suite are noise.
  if durationMs < 0:
    return ""
  if durationMs < 1000:
    return $durationMs & "ms"
  if durationMs < 60_000:
    let tenths = (durationMs + 50) div 100
    return $(tenths div 10) & "." & $(tenths mod 10) & "s"
  let totalSeconds = (durationMs + 500) div 1000
  $(totalSeconds div 60) & "m " & $(totalSeconds mod 60) & "s"

proc newTestRunSummary*(): TestRunSummary =
  TestRunSummary(rows: @[], diagnostics: @[])

proc rowIndex(summary: TestRunSummary; testId: string): int =
  for i, row in summary.rows:
    if row.testId == testId:
      return i
  -1

proc ensureRow(summary: var TestRunSummary; testId: string): int =
  result = summary.rowIndex(testId)
  if result >= 0:
    return
  summary.rows.add TestRunRow(
    testId: testId,
    name: displayName(testId),
    outcome: troRunning,
    diagnostics: @[])
  result = summary.rows.len - 1

proc toOutcome(status: TestResultStatus): TestRunOutcome =
  case status
  of tsPassed: troPassed
  of tsFailed: troFailed
  of tsSkipped: troSkipped
  of tsErrored: troErrored

proc diagnosticsFrom(event: TestEvent; fallbackSeverity: string):
    seq[TestRunDiagnostic] =
  ## The diagnostic an event carries, or the one its message implies.
  ##
  ## The runner reports the same failure two ways depending on the provider —
  ## a structured `diagnostic`, or a bare `message` — and a reviewer needs the
  ## text either way, so neither shape is allowed to be the only one handled.
  result = @[]
  if event.diagnostic.isSome:
    let value = event.diagnostic.get
    var message = value.message
    if value.file.len > 0:
      message = value.file & ": " & message
    result.add TestRunDiagnostic(severity: $value.severity, message: message)
  elif event.message.len > 0:
    result.add TestRunDiagnostic(
      severity: fallbackSeverity, message: event.message)

proc appendOutput(target: var string; chunk: string) =
  if chunk.len == 0:
    return
  if target.len > 0 and not target.endsWith("\n"):
    target.add "\n"
  target.add chunk

proc recount(summary: var TestRunSummary) =
  ## Re-derive every count from the rows.
  ##
  ## Counters are recomputed rather than incremented at each event because an
  ## event may *change* a row's outcome (a `failure` after a `test-started`,
  ## a `record-finished` after a `failure`), and an incremental counter that
  ## missed one of those transitions would report a total that no longer
  ## matches the rows below it — the precise class of defect this milestone
  ## family exists to prevent.
  summary.passed = 0
  summary.failed = 0
  summary.skipped = 0
  summary.errored = 0
  summary.cancelled = 0
  summary.running = 0
  var rowDurations = 0
  for row in summary.rows:
    rowDurations += max(row.durationMs, 0)
    case row.outcome
    of troRunning: inc summary.running
    of troPassed: inc summary.passed
    of troFailed: inc summary.failed
    of troSkipped: inc summary.skipped
    of troErrored: inc summary.errored
    of troCancelled: inc summary.cancelled
  # A run is in flight while any scope is open or any row has not landed.
  # Neither half is sufficient alone: providers that emit no `run-started`
  # still emit `test-started` (so rows carry the signal), and a multi-test
  # run passes through moments where one test has finished and the next has
  # not begun (so the open scope carries it).
  summary.inProgress = summary.openScopes > 0 or summary.running > 0
  summary.durationMs =
    if summary.scopeDurationMs > 0: summary.scopeDurationMs
    else: rowDurations

proc ingestTestEvent*(summary: var TestRunSummary; event: TestEvent) =
  ## Fold one runner event into `summary`.
  ##
  ## Incremental by construction: calling this for each event as it arrives
  ## and rendering in between is exactly what §2.1.2's "the events stream
  ## before process exit precisely so the panel need not wait" asks for, and
  ## it produces the same value as folding the whole stream at once.
  if event.runId.len > 0 and summary.runId.len == 0:
    summary.runId = event.runId
  if event.providerId.len > 0 and summary.providerId.len == 0:
    summary.providerId = event.providerId

  case event.kind
  of tekRunStarted, tekRecordStarted:
    inc summary.openScopes
    if summary.commandLine.len == 0 and event.message.len > 0:
      summary.commandLine = event.message
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      if event.kind == tekRecordStarted:
        summary.rows[index].recordingAttempted = true
  of tekTestStarted:
    if event.testId.len > 0:
      discard summary.ensureRow(event.testId)
  of tekOutput:
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      summary.rows[index].output.appendOutput(event.output)
    else:
      summary.frameworkOutput.appendOutput(event.output)
  of tekFailure:
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      summary.rows[index].outcome =
        if event.status.isSome: toOutcome(event.status.get) else: troFailed
      summary.rows[index].diagnostics.add diagnosticsFrom(event, "error")
      summary.rows[index].output.appendOutput(event.output)
      if event.durationMs > 0:
        summary.rows[index].durationMs = event.durationMs
    else:
      summary.diagnostics.add diagnosticsFrom(event, "error")
      summary.frameworkOutput.appendOutput(event.output)
  of tekCancellation:
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      summary.rows[index].outcome = troCancelled
      summary.rows[index].diagnostics.add diagnosticsFrom(event, "warning")
    else:
      summary.diagnostics.add diagnosticsFrom(event, "warning")
  of tekTestFinished, tekRecordFinished:
    if event.kind == tekRecordFinished:
      summary.openScopes = max(summary.openScopes - 1, 0)
      summary.scopeDurationMs = max(summary.scopeDurationMs, event.durationMs)
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      if event.status.isSome:
        summary.rows[index].outcome = toOutcome(event.status.get)
      if event.durationMs > 0:
        summary.rows[index].durationMs = event.durationMs
      # A terminal record event may carry the trace the recording produced.
      # It is accepted for the same reason `recording-created` is, and under
      # the same gate: only a non-empty path becomes an affordance.
      if event.trace.isSome and summary.rows[index].tracePath.len == 0:
        let trace = event.trace.get
        if trace.path.len > 0:
          summary.rows[index].tracePath = trace.path
          summary.rows[index].traceId = trace.traceId
          summary.rows[index].recordingId = trace.recordingId
  of tekRunFinished:
    summary.openScopes = max(summary.openScopes - 1, 0)
    summary.scopeDurationMs = max(summary.scopeDurationMs, event.durationMs)
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      # `run-finished` reports the *run's* status.  It settles a row only
      # when that row never reported one of its own, so an aggregate verdict
      # cannot overwrite the specific one a `failure` already recorded.
      if summary.rows[index].outcome == troRunning and event.status.isSome:
        summary.rows[index].outcome = toOutcome(event.status.get)
      if summary.rows[index].durationMs == 0 and event.durationMs > 0:
        summary.rows[index].durationMs = event.durationMs
  of tekRecordingCreated:
    if event.testId.len > 0 and event.trace.isSome:
      let trace = event.trace.get
      let index = summary.ensureRow(event.testId)
      summary.rows[index].recordingAttempted = true
      if trace.path.len > 0:
        summary.rows[index].tracePath = trace.path
        summary.rows[index].traceId = trace.traceId
        summary.rows[index].recordingId = trace.recordingId
  of tekDiagnostic:
    if event.testId.len > 0:
      let index = summary.ensureRow(event.testId)
      summary.rows[index].diagnostics.add diagnosticsFrom(event, "error")
    else:
      summary.diagnostics.add diagnosticsFrom(event, "error")
  of tekDiscoveryStarted, tekDiscoveryFinished:
    # Discovery is a different command with a different surface (the editor's
    # gutter controls).  A discovery event in a run's stream says nothing
    # about what passed, so it contributes nothing here.
    discard

  summary.recount()

proc projectTestRun*(events: openArray[TestEvent]): TestRunSummary =
  ## Fold a whole event stream at once.  Equivalent to `ingestTestEvent` per
  ## event, and asserted to be so.
  result = newTestRunSummary()
  for event in events:
    result.ingestTestEvent(event)

proc parseTestEventLine*(line: string): Option[TestEvent] {.noSideEffect.} =
  ## Recognise one line of a runner stream as a ct-test event, or decline.
  ##
  ## The test is deliberately strict, and both halves matter:
  ##
  ## - the line must parse as a JSON **object** carrying a `kind` that is one
  ##   of `TestEventKind`'s wire names, and
  ## - it must carry a `schemaVersion`.
  ##
  ## Either alone would misfire: agents print plenty of JSON with a `kind`
  ## field, and plenty with a `schemaVersion`.  Together they identify the
  ## runner's own NDJSON without needing to know what command produced it,
  ## which is what lets an *arbitrary* `ct test` invocation in a session feed
  ## be recognised.  Anything that does not match is not an error — it is
  ## framework output, and the caller keeps it verbatim.
  let stripped = line.strip
  if stripped.len < 2 or stripped[0] != '{':
    return none(TestEvent)
  var node: JsonNode
  try:
    {.cast(noSideEffect).}:
      node = parseJson(stripped)
  except CatchableError:
    return none(TestEvent)
  if node.isNil or node.kind != JObject:
    return none(TestEvent)
  if not node.hasKey("kind") or node["kind"].kind != JString:
    return none(TestEvent)
  if not node.hasKey("schemaVersion") or node["schemaVersion"].kind != JInt:
    return none(TestEvent)
  try:
    {.cast(noSideEffect).}:
      return some(testEventFromJson(node))
  except CatchableError:
    return none(TestEvent)

proc parseTestRun*(text: string): Option[TestRunSummary] =
  ## Project a blob of runner output into a run summary, or decline.
  ##
  ## `none` means "this is not a `ct test` run" — the caller renders the text
  ## as the ordinary message it is.  A run is claimed only when at least one
  ## real event was found, so a session message that merely *mentions*
  ## `ct test` does not become an empty summary card claiming a run happened.
  var summary = newTestRunSummary()
  var eventCount = 0
  for line in text.splitLines():
    let parsed = parseTestEventLine(line)
    if parsed.isSome:
      inc eventCount
      summary.ingestTestEvent(parsed.get)
    elif line.strip.len > 0:
      summary.frameworkOutput.appendOutput(line)
  if eventCount == 0:
    return none(TestRunSummary)
  some(summary)

proc totalTests*(summary: TestRunSummary): int {.noSideEffect.} =
  summary.rows.len

proc summaryText*(summary: TestRunSummary): string {.noSideEffect.} =
  ## The one line the collapsed card shows.
  ##
  ## Obeys AA-1's preserved rule literally: a run that reported no tests says
  ## so in words rather than printing "0 passed", because a zero there reads
  ## as a suite that ran clean.  See `Agent-Activity-Panel.milestones.org`,
  ## AA-1 deliverable 4, and `review_entry.coverageText`, which returns an
  ## empty badge for the same reason.
  var parts: seq[string] = @[]
  if summary.rows.len == 0:
    if summary.inProgress:
      return "Running tests…"
    return "No tests reported"
  if summary.passed > 0:
    parts.add $summary.passed & " passed"
  if summary.failed > 0:
    parts.add $summary.failed & " failed"
  if summary.errored > 0:
    parts.add $summary.errored & " errored"
  if summary.skipped > 0:
    parts.add $summary.skipped & " skipped"
  if summary.cancelled > 0:
    parts.add $summary.cancelled & " cancelled"
  if summary.running > 0:
    parts.add $summary.running & " running"
  result = parts.join(", ")
  if summary.durationMs > 0:
    result.add " · " & formatDurationMs(summary.durationMs)

proc rowFor*(summary: TestRunSummary; testId: string): Option[TestRunRow]
    {.noSideEffect.} =
  let index = summary.rowIndex(testId)
  if index < 0: none(TestRunRow) else: some(summary.rows[index])
