## Tests for the parallel-run + partition orchestration (run_orchestration.nim).
##
## Coverage:
## * parsePartitionFile — comments, blanks, empty allow-list semantics.
## * enumerateRunUnits — single vs. file scope selection by capability.
## * filterByPartition — allow-list inclusion/exclusion + skip counting.
## * summarize / summaryToJson — pass/fail/skip aggregation from events.
## * runUnits (integration) — an in-process provider whose ``run`` emits real
##   ``TestEvent`` streams is driven through the worker pool with and without a
##   partition file; exact executed/skipped/passed/failed counts and per-test
##   event kinds are asserted.
## * runUnits (worker-heap hand-off) — a high-thread-count run is executed in a
##   CHILD PROCESS and its exit status asserted, because the defect this guards
##   is a fatal signal (see "worker-heap hand-off" below), which no in-process
##   assertion can survive.
##
## The integration provider runs entirely in-process (no toolchain needed) so
## the test is self-contained and deterministic; it exercises the exact
## orchestration path real providers use (worker pool → provider.run(scope) →
## event aggregation), differing only in that the events are produced directly
## rather than via execCaptured. It is a fixture, not a mock of a collaborator:
## nothing is stubbed out of ``run_orchestration`` itself — the real queue, the
## real worker threads, the real aggregation and the real summary reduction all
## run. Only the leaf ``TestProvider.run`` is supplied by the test, exactly as a
## real language adapter would supply it, so the orchestration under test is
## exercised end to end without depending on an external toolchain.

import std/[json, options, os, osproc, sets, strutils, tables, unittest]

import contracts
import discovery
import run_orchestration

# ---------------------------------------------------------------------------
# In-process fixture provider
# ---------------------------------------------------------------------------

const
  FixtureProviderId = "fixture-inproc"
  FixtureLanguage = "fixture"
  FixtureFramework = "inproc"

proc fixtureCapabilities(canRunSingle: bool): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: canRunSingle,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: true,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: true)

proc fixtureInfo(canRunSingle: bool): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    displayName: "In-process fixture provider",
    version: "test",
    capabilities: fixtureCapabilities(canRunSingle))

proc fixtureItem(name: string; line: int; shouldFail: bool): TestItem =
  ## A discovered item whose *selector* encodes the desired outcome
  ## (``::pass`` / ``::fail``) so the in-process ``run`` proc can decide
  ## deterministically from the scope alone (workers are stateless).
  let relative = "tests/" & name & ".fixture"
  let outcome = if shouldFail: "fail" else: "pass"
  let selector = relative & "::" & name & "::" & outcome
  TestItem(
    id: makeTestItemId(FixtureProviderId, FixtureLanguage, FixtureFramework,
      relative, selector),
    providerId: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    name: name,
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: line, startColumn: 1, endLine: line, endColumn: 10),
    selector: selector,
    parentId: "",
    tags: @["fixture"],
    location: LocationProvenance(
      source: lskPattern, detail: "in-process fixture", confidence: lcHigh),
    stale: false,
    staleReason: "")

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Emit a deterministic event stream for one scope: run-started,
  ## test-started, test-finished (status decoded from the selector suffix),
  ## run-finished. This is the shape a real provider's ``run`` would return
  ## after parsing its subprocess output.
  let failed = scope.selector.endsWith("::fail")
  let status = if failed: tsFailed else: tsPassed
  var events: seq[TestEvent] = @[]
  events.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekRunStarted,
    providerId: FixtureProviderId, runId: scope.testId)
  events.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
    providerId: FixtureProviderId, runId: scope.testId, testId: scope.testId)
  events.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
    providerId: FixtureProviderId, runId: scope.testId, testId: scope.testId,
    status: some(status), durationMs: 1)
  events.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekRunFinished,
    providerId: FixtureProviderId, runId: scope.testId)
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc newFixtureProvider(canRunSingle: bool): M1Provider =
  var provider = TestProvider(info: fixtureInfo(canRunSingle))
  provider.run = fixtureRun
  M1Provider(provider: provider, relevantConfigFiles: @[])

proc fixtureRegistry(canRunSingle = true): ProviderRegistry =
  ProviderRegistry(providers: @[newFixtureProvider(canRunSingle)])

proc fixtureResponse(items: seq[TestItem]; workspaceRoot = "/tmp/ws"): DiscoverResponse =
  DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion,
    workspaceRoot: workspaceRoot,
    file: "",
    catalogs: @[TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: fixtureInfo(true),
      items: items,
      diagnostics: @[])],
    diagnostics: @[])

# ---------------------------------------------------------------------------
# Worker-heap hand-off stress (regression guard)
# ---------------------------------------------------------------------------
#
# Nim's ARC/ORC allocator is per-thread and each thread's ``MemRegion`` lives in
# that thread's TLS. A heap block may only be freed while the thread that
# allocated it is still alive — otherwise ``rawDealloc`` follows a dangling
# ``PSmallChunk.owner`` into ``addToSharedFreeList`` and the process dies with
# SIGSEGV. ``runUnits`` used to return worker-allocated results to its caller
# *after* joining the workers, so `ct-test test run` reliably dumped core once
# enough workers had run for glibc to stop caching their retired stacks — and it
# did so only **after** printing a correct-looking summary, so stdout said
# success while `$?` said 139.
#
# On Linux/glibc that boundary is exactly 21 workers: Nim gives every thread its
# own 2 MiB stack (``ThreadStackSize`` in ``std/typedthreads``, independent of
# `ulimit -s`), so glibc's 40 MiB `stack_cache_maxsize` retains exactly 20 of
# them. Fewer workers is NOT safe, only quiet — the same illegal write lands in
# a retired-but-still-mapped region. Running this binary under
# `GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0` removes the cache and makes
# the defect fatal at a single worker; that is the amplifier to reach for when
# stress-testing any threaded Nim code in this repo.
#
# The failure is a fatal signal, so it cannot be observed with ``check``: the
# test binary would die too. The guard therefore re-executes THIS binary in a
# child process and asserts the child's exit status, which is the property the
# CLI contract actually needs ("exit 0 at the default thread count").

const
  StressChildFlag = "--ct-orch-heap-handoff-child"
    ## argv[1] marker that turns this test binary into the stress child.
  StressUnits = 200
    ## Enough units that every worker gets several, and enough total payload
    ## that worker allocations spread across many allocator chunks.
  StressEventsPerUnit = 40
  StressPayloadBytes = 200

proc stressRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Like ``fixtureRun`` but with a bulky event stream: the regression being
  ## guarded is about *heap ownership*, so each unit must make its worker
  ## allocate a non-trivial amount of string/seq payload that then has to
  ## survive the hand-off back to the spawning thread.
  let failed = scope.selector.endsWith("::fail")
  var events: seq[TestEvent] = @[]
  for i in 0 ..< StressEventsPerUnit:
    events.add TestEvent(
      schemaVersion: TestEventSchemaVersion, kind: tekOutput,
      providerId: FixtureProviderId, runId: scope.testId, testId: scope.testId,
      output: repeat("x", StressPayloadBytes) & $i & scope.selector)
  events.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
    providerId: FixtureProviderId, runId: scope.testId, testId: scope.testId,
    status: some(if failed: tsFailed else: tsPassed), durationMs: 1)
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc stressRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo(canRunSingle = true))
  provider.run = stressRun
  ProviderRegistry(providers: @[M1Provider(
    provider: provider, relevantConfigFiles: @[])])

proc stressUnits(registry: ProviderRegistry): seq[RunUnit] =
  var items: seq[TestItem] = @[]
  for i in 0 ..< StressUnits:
    items.add fixtureItem("stress" & $i, i + 1, i mod 3 == 0)
  enumerateRunUnits(fixtureResponse(items), registry)

proc stableSummaryJson(summary: TestRunSummary): JsonNode =
  ## The summary minus the two fields that legitimately vary with the worker
  ## count, so a 32-thread run and a 1-thread run can be compared for equality.
  result = summaryToJson(summary)
  result.delete "wall_time_ms"
  result.delete "threads"

const StressSummaryMarker = "STRESS-SUMMARY "

proc runStressChild(threads: int) =
  ## Child-process body: run ``StressUnits`` units across ``threads`` workers,
  ## report the summary, and then explicitly release the whole result — the
  ## release is the operation that used to fault, so forcing it here makes the
  ## failure land inside the child rather than depending on teardown timing.
  var registry = stressRegistry()
  let units = stressUnits(registry)
  var runResult = runUnits(registry, units, emptyPartition(), threads = threads)
  let summary = summarize(runResult)
  echo StressSummaryMarker, $stableSummaryJson(summary)
  echo "STRESS-THREADS ", runResult.threads
  reset(runResult)
  echo "STRESS-RELEASED"

when isMainModule:
  # Must run before any `suite` body executes, so the child does nothing but
  # the stress run. Placed here (rather than at the end of the file) because
  # `suite` blocks execute as the module body is evaluated.
  let childArgs = commandLineParams()
  if childArgs.len == 2 and childArgs[0] == StressChildFlag:
    runStressChild(parseInt(childArgs[1]))
    quit(0)

proc tempPartitionFile(name, content: string): string =
  let path = getTempDir() / ("ct-orch-part-" & name & "-" &
    $getCurrentProcessId() & ".txt")
  writeFile(path, content)
  path

# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------

suite "partition file parsing":
  test "ignores blanks and comments, keeps ids":
    let path = tempPartitionFile("basic", """
# a leading comment
fixture-inproc/fixture/inproc/tests/a.fixture::a::pass

  fixture-inproc/fixture/inproc/tests/b.fixture::b::fail   # trailing comment
# another comment

""")
    defer: removeFile(path)
    let spec = parsePartitionFile(path)
    check spec.mode == pmFile
    check spec.allowed.len == 2
    check "fixture-inproc/fixture/inproc/tests/a.fixture::a::pass" in spec.allowed
    check "fixture-inproc/fixture/inproc/tests/b.fixture::b::fail" in spec.allowed

  test "empty file yields an empty allow-list that admits nothing":
    let path = tempPartitionFile("empty", "\n# only a comment\n\n")
    defer: removeFile(path)
    let spec = parsePartitionFile(path)
    check spec.mode == pmFile
    check spec.allowed.len == 0
    check not spec.admits("anything")

  test "emptyPartition admits everything":
    let spec = emptyPartition()
    check spec.mode == pmNone
    check spec.admits("any-id")

  test "parsePartitionArg rejects non-file specs":
    expect ValueError:
      discard parsePartitionArg("slice:1/4")
    expect ValueError:
      discard parsePartitionArg("hash:deadbeef")
    expect ValueError:
      discard parsePartitionArg("file:")

  test "parsePartitionArg reads a file: spec":
    let path = tempPartitionFile("arg", "id-one\nid-two\n")
    defer: removeFile(path)
    let spec = parsePartitionArg("file:" & path)
    check spec.mode == pmFile
    check spec.allowed == toHashSet(@["id-one", "id-two"])

suite "run-unit enumeration":
  test "single-capable provider builds tskSingle scopes":
    let items = @[fixtureItem("a", 2, false), fixtureItem("b", 3, true)]
    let response = fixtureResponse(items)
    let units = enumerateRunUnits(response, fixtureRegistry(canRunSingle = true))
    check units.len == 2
    for i, unit in units:
      check unit.providerId == FixtureProviderId
      check unit.scope.kind == tskSingle
      check unit.scope.testId == items[i].id
      check unit.scope.selector == items[i].selector
      check unit.scope.projectRoot == response.workspaceRoot
      # workspace-relative file is resolved to an absolute path
      check unit.scope.file == response.workspaceRoot / items[i].file

  test "non-single provider falls back to tskFile scopes":
    let items = @[fixtureItem("a", 2, false)]
    let response = fixtureResponse(items)
    let units = enumerateRunUnits(response, fixtureRegistry(canRunSingle = false))
    check units.len == 1
    check units[0].scope.kind == tskFile
    check units[0].scope.testId == ""
    check units[0].scope.selector == ""
    check units[0].scope.file == response.workspaceRoot / items[0].file

  test "enumeration covers items across multiple catalogs":
    var response = fixtureResponse(@[fixtureItem("a", 2, false)])
    response.catalogs.add TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: fixtureInfo(true),
      items: @[fixtureItem("b", 3, true), fixtureItem("c", 4, false)],
      diagnostics: @[])
    let units = enumerateRunUnits(response, fixtureRegistry())
    check units.len == 3

suite "partition filtering":
  test "selects admitted units and counts the rest as skipped":
    let items = @[
      fixtureItem("a", 2, false),
      fixtureItem("b", 3, true),
      fixtureItem("c", 4, false)]
    let response = fixtureResponse(items)
    let units = enumerateRunUnits(response, fixtureRegistry())
    var allowed = initHashSet[string]()
    allowed.incl items[0].id
    allowed.incl items[2].id
    let spec = PartitionSpec(mode: pmFile, allowed: allowed)
    let (selected, skipped) = filterByPartition(units, spec)
    check selected.len == 2
    check skipped == 1
    check selected[0].item.id == items[0].id
    check selected[1].item.id == items[2].id

  test "no partition selects everything":
    let items = @[fixtureItem("a", 2, false), fixtureItem("b", 3, true)]
    let units = enumerateRunUnits(fixtureResponse(items), fixtureRegistry())
    let (selected, skipped) = filterByPartition(units, emptyPartition())
    check selected.len == 2
    check skipped == 0

suite "summary aggregation":
  test "counts passed, failed, and ignores skipped":
    proc finished(status: TestResultStatus): TestEvent =
      TestEvent(
        schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
        providerId: FixtureProviderId, runId: "r", testId: "t",
        status: some(status))
    let runResult = TestRunResult(
      totalDiscovered: 5,
      skippedByPartition: 1,
      executedUnits: 4,
      threads: 2,
      wallTimeMs: 7,
      outcomes: @[
        RunUnitOutcome(events: @[finished(tsPassed)]),
        RunUnitOutcome(events: @[finished(tsPassed)]),
        RunUnitOutcome(events: @[finished(tsFailed)]),
        RunUnitOutcome(events: @[finished(tsSkipped)])])
    let summary = summarize(runResult)
    check summary.totalDiscovered == 5
    check summary.executed == 4
    check summary.skippedByPartition == 1
    check summary.passed == 2
    check summary.failed == 1
    check summary.threads == 2
    check summary.wallTimeMs == 7
    check runExitCode(summary) == 1

  test "errored status counts as failed":
    let runResult = TestRunResult(
      totalDiscovered: 1, executedUnits: 1, threads: 1,
      outcomes: @[RunUnitOutcome(events: @[TestEvent(
        schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
        providerId: FixtureProviderId, runId: "r", testId: "t",
        status: some(tsErrored))])])
    let summary = summarize(runResult)
    check summary.failed == 1
    check runExitCode(summary) == 1

  test "summaryToJson uses the cross-runner schema keys":
    let summary = TestRunSummary(
      totalDiscovered: 3, executed: 2, skippedByPartition: 1,
      passed: 1, failed: 1, wallTimeMs: 9, threads: 4)
    let node = summaryToJson(summary)
    check node["total"].getInt == 3
    check node["executed"].getInt == 2
    check node["skipped_by_partition"].getInt == 1
    check node["passed"].getInt == 1
    check node["failed"].getInt == 1
    check node["wall_time_ms"].getInt == 9
    check node["threads"].getInt == 4

# ---------------------------------------------------------------------------
# Integration: full worker-pool run via an in-process provider
# ---------------------------------------------------------------------------

suite "parallel run integration":
  setup:
    # Three passing tests, two failing — fixed across the suite so the exact
    # counts below are stable regardless of worker count.
    let items = @[
      fixtureItem("alpha", 2, false),
      fixtureItem("beta", 3, true),
      fixtureItem("gamma", 4, false),
      fixtureItem("delta", 5, true),
      fixtureItem("epsilon", 6, false)]
    let response = fixtureResponse(items)
    var registry = fixtureRegistry(canRunSingle = true)
    let units = enumerateRunUnits(response, registry)

  test "runs every unit with no partition (deterministic counts)":
    # Fixed thread count for determinism per the design's worker-pool note.
    let runResult = runUnits(registry, units, emptyPartition(), threads = 3)
    check runResult.totalDiscovered == 5
    check runResult.executedUnits == 5
    check runResult.skippedByPartition == 0
    check runResult.outcomes.len == 5
    # Each unit produced the full four-event lifecycle.
    for outcome in runResult.outcomes:
      check outcome.events.len == 4
      check outcome.events[0].kind == tekRunStarted
      check outcome.events[1].kind == tekTestStarted
      check outcome.events[2].kind == tekTestFinished
      check outcome.events[3].kind == tekRunFinished
    let summary = summarize(runResult)
    check summary.passed == 3
    check summary.failed == 2
    check summary.executed == 5
    check summary.skippedByPartition == 0
    check runExitCode(summary) == 1

  test "single-threaded run yields identical counts":
    let runResult = runUnits(registry, units, emptyPartition(), threads = 1)
    let summary = summarize(runResult)
    check runResult.threads == 1
    check summary.passed == 3
    check summary.failed == 2
    check summary.executed == 5

  test "partition file restricts the executed set":
    # Allow only the two passing tests alpha + gamma; everything else is
    # skipped_by_partition and must not run.
    let path = tempPartitionFile("integration",
      items[0].id & "\n" & items[2].id & "\n")
    defer: removeFile(path)
    let spec = parsePartitionFile(path)
    let runResult = runUnits(registry, units, spec, threads = 2)
    check runResult.totalDiscovered == 5
    check runResult.executedUnits == 2
    check runResult.skippedByPartition == 3
    check runResult.outcomes.len == 2
    var executedIds = initHashSet[string]()
    for outcome in runResult.outcomes:
      executedIds.incl outcome.testId
    check executedIds == toHashSet(@[items[0].id, items[2].id])
    let summary = summarize(runResult)
    check summary.passed == 2
    check summary.failed == 0
    check summary.executed == 2
    check summary.skippedByPartition == 3
    check runExitCode(summary) == 0

  test "high worker counts return safely and match a single-threaded run":
    # Regression guard for the worker-heap hand-off (see the block comment
    # above ``StressChildFlag``). Pre-fix this child exits 139 with
    # `SIGSEGV … addToSharedFreeList`; the summary it printed first was already
    # correct, which is precisely why the exit status has to be asserted.
    #
    # 32 workers is above the 21-worker Linux/glibc threshold at which retired
    # worker stacks (and the thread-local ``MemRegion``s inside them) stop being
    # cached and start being unmapped, with enough headroom that the guard does
    # not depend on the cache size to the byte. `countProcessors()` is folded in
    # so it also covers "the default thread count on this machine", which is
    # what the CLI uses when `--threads` is omitted.
    #
    # ``StressUnits`` must stay comfortably above this too: ``runUnits`` starts
    # ``min(threads, units)`` workers, so a small unit count would silently cap
    # the pool below the threshold and neuter the guard.
    let threads = max(32, osproc.countProcessors())
    let child = execCmdEx(
      quoteShellCommand([getAppFilename(), StressChildFlag, $threads]))
    checkpoint "child output:\n" & child.output
    check child.exitCode == 0
    check "STRESS-RELEASED" in child.output

    # The parallel result must equal the serial one. A single-threaded run
    # never leaves the calling thread, so it is the trustworthy reference.
    var stressReg = stressRegistry()
    let stressUnitList = stressUnits(stressReg)
    let serial = summarize(
      runUnits(stressReg, stressUnitList, emptyPartition(), threads = 1))

    var childSummary = newJNull()
    var childThreads = 0
    for line in child.output.splitLines():
      if line.startsWith(StressSummaryMarker):
        childSummary = parseJson(line[StressSummaryMarker.len .. ^1])
      elif line.startsWith("STRESS-THREADS "):
        childThreads = parseInt(line["STRESS-THREADS ".len .. ^1].strip())
    check childSummary == stableSummaryJson(serial)
    check childSummary["executed"].getInt == StressUnits
    # The run must actually have been concurrent, or it proves nothing.
    check childThreads == threads

  test "empty partition skips everything and runs nothing":
    let path = tempPartitionFile("none", "# no ids here\n")
    defer: removeFile(path)
    let spec = parsePartitionFile(path)
    let runResult = runUnits(registry, units, spec, threads = 2)
    check runResult.executedUnits == 0
    check runResult.skippedByPartition == 5
    check runResult.outcomes.len == 0
    let summary = summarize(runResult)
    check summary.passed == 0
    check summary.failed == 0
    check runExitCode(summary) == 0
