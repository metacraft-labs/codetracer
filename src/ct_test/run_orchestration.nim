## ct_test parallel-run + partition orchestration.
##
## This module owns the *high-level* test-run orchestration for the
## ``src/ct_test`` cross-language framework: enumerating discovered tests into
## run units, filtering them through a ``--partition`` allow-list, executing the
## selected units in parallel across a worker pool, and aggregating the per-test
## ``TestEvent`` streams into a JSON run summary.
##
## It is the consolidation of the standalone ``ct-test`` repo's
## ``apps/ct-test-runner`` worker pool onto codetracer's provider model. The
## crucial layering boundary (see ``docs/ct-test-run-orchestration-design.md``):
##
## * **This module owns** *what to run and how to aggregate* — the work queue,
##   worker threads, partition filter, and summary writer.
## * **``runquota_process`` owns** *how to launch* — every provider ``run`` proc
##   ultimately shells out through ``process_exec.execCaptured`` →
##   ``runquota_process``, so process launch, output capture, and (when a
##   session is configured) runquota lease governance are NOT reimplemented
##   here. Workers only call ``provider.run(scope)`` and collect events.
##
## Threading note: Nim worker threads receive plain ``ptr`` handles (never
## closures) to the shared queue, result buffer, and registry, guarded by a
## ``Lock`` — mirroring ``ct_test_runner.nim``'s ``Queue`` / ``WorkerArgs``
## shape. The provider ``run`` procs are ``{.gcsafe.}`` so they are safe to
## invoke from the worker threads.

import std/[cpuinfo, json, locks, options, os, sets, strutils, times]

import contracts
import discovery

type
  PartitionMode* = enum
    ## How a run's candidate set is narrowed before execution.
    pmNone = "none"        ## no partition: run every discovered test
    pmFile = "file"        ## ``--partition file:<path>`` allow-list

  PartitionSpec* = object
    ## A parsed ``--partition`` specification. ``allowed`` holds the
    ## fully-qualified test ids that survive the filter (empty when
    ## ``mode == pmNone``, in which case every test is allowed).
    mode*: PartitionMode
    allowed*: HashSet[string]

  RunUnit* = object
    ## One schedulable unit of work: a single discovered ``TestItem`` plus the
    ## owning provider id and the ``TestScope`` the provider's ``run`` proc will
    ## be invoked with. One ``RunUnit`` is produced per discovered item.
    providerId*: string
    item*: TestItem
    scope*: TestScope

  RunUnitOutcome* = object
    ## The events a single ``RunUnit`` produced, tagged with its provider id and
    ## test id so aggregation does not depend on the events carrying them.
    providerId*: string
    testId*: string
    events*: seq[TestEvent]
    diagnostics*: seq[TestDiagnostic]

  TestRunResult* = object
    ## Raw, aggregated output of a run: the flattened events from every executed
    ## unit, plus the bookkeeping the summary is computed from.
    totalDiscovered*: int          ## RunUnits enumerated before partitioning
    skippedByPartition*: int       ## discovered units dropped by the partition
    executedUnits*: int            ## units actually handed to a provider
    threads*: int                  ## worker threads used
    wallTimeMs*: int               ## wall-clock duration of the parallel phase
    outcomes*: seq[RunUnitOutcome] ## per-unit event streams (run order varies)

  TestRunSummary* = object
    ## The reduced, reportable summary derived from a ``TestRunResult``.
    totalDiscovered*: int
    executed*: int
    skippedByPartition*: int
    passed*: int
    failed*: int
    wallTimeMs*: int
    threads*: int

const
  ReproTestThreadsEnv* = "REPRO_TEST_THREADS"
    ## Environment override for the default worker-thread count, matching the
    ## standalone ``ct-test-runner`` so reprobuild's sharding driver can pin the
    ## thread budget uniformly across both runners.
  PartitionFilePrefix* = "file:"

# ---------------------------------------------------------------------------
# Partition parsing
# ---------------------------------------------------------------------------

proc emptyPartition*(): PartitionSpec =
  ## A no-op partition that admits every discovered test.
  PartitionSpec(mode: pmNone, allowed: initHashSet[string]())

proc parsePartitionFile*(path: string): PartitionSpec =
  ## Parse a ``--partition file:`` allow-list file into a ``PartitionSpec``.
  ##
  ## Format (identical to the standalone runner and
  ## codetracer-specs Nim-Parallel-Test-Framework.md §15.1): one fully-qualified
  ## test id per line; ``#`` introduces a trailing comment; blank lines and
  ## comment-only lines are ignored. The result always has ``mode == pmFile``
  ## even when the file is empty, so an empty allow-list correctly skips
  ## everything rather than degrading into "run all".
  result = PartitionSpec(mode: pmFile, allowed: initHashSet[string]())
  for raw in readFile(path).splitLines():
    var line = raw
    let hashIdx = line.find('#')
    if hashIdx >= 0:
      line = line[0 ..< hashIdx]
    line = line.strip()
    if line.len == 0:
      continue
    result.allowed.incl line

proc parsePartitionArg*(arg: string): PartitionSpec =
  ## Parse a ``--partition`` argument value. Only ``file:<path>`` is supported;
  ## ``slice:`` / ``hash:`` sharding intelligence stays in ``repro test`` per
  ## CI-Sharding.md, so they are rejected here with a ``ValueError`` the CLI
  ## turns into a diagnostic.
  if arg.startsWith(PartitionFilePrefix):
    let path = arg[PartitionFilePrefix.len .. ^1]
    if path.len == 0:
      raise newException(ValueError, "--partition file: requires a path")
    if not fileExists(path):
      raise newException(ValueError, "partition file not found: " & path)
    parsePartitionFile(path)
  else:
    raise newException(ValueError,
      "unrecognised --partition spec: " & arg & " (expected file:<path>)")

proc admits*(partition: PartitionSpec; testId: string): bool =
  ## Does ``partition`` allow ``testId`` to run? ``pmNone`` admits everything;
  ## ``pmFile`` admits only ids present in the allow-list.
  case partition.mode
  of pmNone: true
  of pmFile: testId in partition.allowed

# ---------------------------------------------------------------------------
# Run-unit enumeration
# ---------------------------------------------------------------------------

proc providerCapabilities(
    registry: ProviderRegistry; providerId: string): TestCapabilities =
  ## Look up the declared capabilities for ``providerId``. Returns the default
  ## (all-false) capabilities when the provider is unknown, which conservatively
  ## drives ``enumerateRunUnits`` to a file-scoped scope.
  for provider in registry.providers:
    if provider.provider.info.id == providerId:
      return provider.provider.info.capabilities
  TestCapabilities()

proc scopeForItem*(
    response: DiscoverResponse;
    item: TestItem;
    canRunSingle: bool): TestScope =
  ## Build the ``TestScope`` a provider's ``run`` proc is invoked with for a
  ## given discovered ``item``. When the provider can run a single test we build
  ## a ``tskSingle`` scope carrying the item id + selector; otherwise we fall
  ## back to ``tskFile`` so the provider runs the whole owning file.
  ##
  ## The scope's ``file`` is resolved to an absolute path when the discovered
  ## item's file is workspace-relative, so providers receive a path they can use
  ## regardless of the process working directory.
  let absFile =
    if item.file.len == 0:
      ""
    elif isAbsolute(item.file):
      item.file
    else:
      response.workspaceRoot / item.file
  if canRunSingle:
    TestScope(
      kind: tskSingle,
      projectRoot: response.workspaceRoot,
      file: absFile,
      testId: item.id,
      selector: item.selector)
  else:
    TestScope(
      kind: tskFile,
      projectRoot: response.workspaceRoot,
      file: absFile,
      testId: "",
      selector: "")

proc enumerateRunUnits*(
    response: DiscoverResponse;
    registry: ProviderRegistry): seq[RunUnit] =
  ## Flatten a ``DiscoverResponse`` into one ``RunUnit`` per discovered test
  ## item, choosing a single-test or file-scoped ``TestScope`` per the owning
  ## provider's ``canRunSingle`` capability. The owning provider id is taken
  ## from the item (``providerId``) so units survive being mixed across
  ## providers in the same queue.
  result = @[]
  for catalog in response.catalogs:
    for item in catalog.items:
      let providerId =
        if item.providerId.len > 0: item.providerId
        else: catalog.provider.id
      let caps = providerCapabilities(registry, providerId)
      result.add RunUnit(
        providerId: providerId,
        item: item,
        scope: scopeForItem(response, item, caps.canRunSingle))

proc filterByPartition*(
    units: seq[RunUnit];
    partition: PartitionSpec): tuple[selected: seq[RunUnit]; skipped: int] =
  ## Split enumerated units into those the partition admits and a count of those
  ## it filtered out (``skipped_by_partition``). A unit is matched on its test
  ## item id, the fully-qualified identifier the partition file lists.
  result.selected = @[]
  result.skipped = 0
  for unit in units:
    if partition.admits(unit.item.id):
      result.selected.add unit
    else:
      inc result.skipped

# ---------------------------------------------------------------------------
# Worker pool
# ---------------------------------------------------------------------------

type
  Queue = object
    ## A ``Lock``-protected hand-out queue of run units. ``pos`` is the index of
    ## the next unit to dispatch; workers advance it under the lock.
    lock: Lock
    units: seq[RunUnit]
    pos: int

  WorkerArgs = object
    ## Plain-pointer bundle passed by value to each worker thread. Pointers (not
    ## closures) keep the worker proc ``{.thread.}``-safe; every shared mutation
    ## happens under one of the two locks.
    queue: ptr Queue
    registry: ptr ProviderRegistry
    resultsLock: ptr Lock
    outcomes: ptr seq[RunUnitOutcome]

proc resolveThreadCount*(requested: int): int =
  ## Resolve the effective worker-thread count. An explicit positive
  ## ``requested`` wins; otherwise the ``REPRO_TEST_THREADS`` environment
  ## override applies; otherwise we fall back to ``countProcessors()``. The
  ## result is always clamped to at least 1.
  if requested > 0:
    return max(1, requested)
  let env = getEnv(ReproTestThreadsEnv)
  if env.len > 0:
    try:
      return max(1, parseInt(env.strip()))
    except ValueError:
      discard
  result = countProcessors()
  if result <= 0:
    result = 1

proc findProvider(registry: ptr ProviderRegistry; providerId: string): ptr TestProvider =
  ## Locate the owning provider for a run unit. Returns ``nil`` when the
  ## provider is not registered (the worker records an error outcome instead).
  for i in 0 ..< registry.providers.len:
    if registry.providers[i].provider.info.id == providerId:
      return addr registry.providers[i].provider
  nil

proc nextUnit(queue: ptr Queue; outUnit: var RunUnit): bool =
  ## Hand the next queued unit to a worker, or report exhaustion. Thread-safe.
  acquire(queue.lock)
  defer: release(queue.lock)
  if queue.pos >= queue.units.len:
    return false
  outUnit = queue.units[queue.pos]
  inc queue.pos
  true

proc runUnitOutcome(
    registry: ptr ProviderRegistry; unit: RunUnit): RunUnitOutcome {.gcsafe.} =
  ## Execute one run unit by invoking the owning provider's ``run`` proc with
  ## the unit's scope, and tag the returned events. A missing provider or a
  ## provider with no ``run`` proc yields an error outcome rather than crashing
  ## the worker.
  result = RunUnitOutcome(
    providerId: unit.providerId,
    testId: unit.item.id,
    events: @[],
    diagnostics: @[])
  let provider = findProvider(registry, unit.providerId)
  if provider == nil:
    result.diagnostics.add diagnostic(
      dsError, "no registered provider for id: " & unit.providerId,
      unit.item.file)
    return
  if provider.run == nil:
    result.diagnostics.add diagnostic(
      dsError, "provider has no run implementation: " & unit.providerId,
      unit.item.file)
    return
  let providerResult = provider.run(unit.scope)
  result.events = providerResult.value
  result.diagnostics = providerResult.diagnostics

proc workerLoop(args: WorkerArgs) =
  ## Worker body: drain the queue, run each unit, and append its outcome to the
  ## shared buffer under the results lock.
  while true:
    var unit: RunUnit
    if not nextUnit(args.queue, unit):
      break
    let outcome = runUnitOutcome(args.registry, unit)
    acquire(args.resultsLock[])
    args.outcomes[].add outcome
    release(args.resultsLock[])

proc workerMain(args: WorkerArgs) {.thread.} =
  ## Top-level thread entry point. Worker threads cannot capture closures, so
  ## the per-thread state arrives by value as ``WorkerArgs``.
  workerLoop(args)

proc runUnits*(
    registry: var ProviderRegistry;
    units: seq[RunUnit];
    partition: PartitionSpec = emptyPartition();
    threads = 0): TestRunResult =
  ## Run ``units`` in parallel, honouring the partition allow-list and the
  ## requested thread count, and aggregate the per-unit event streams.
  ##
  ## ``registry`` is taken ``var`` because the worker threads need a stable
  ## ``ptr`` into the live provider closures; the registry itself is not
  ## mutated. ``threads == 0`` resolves to ``REPRO_TEST_THREADS`` / CPU count.
  let (selected, skipped) = filterByPartition(units, partition)
  let threadCount = resolveThreadCount(threads)

  result = TestRunResult(
    totalDiscovered: units.len,
    skippedByPartition: skipped,
    executedUnits: selected.len,
    threads: threadCount,
    wallTimeMs: 0,
    outcomes: @[])

  if selected.len == 0:
    return

  var queue = Queue(units: selected, pos: 0)
  initLock(queue.lock)

  var resultsLock: Lock
  initLock(resultsLock)
  var outcomes: seq[RunUnitOutcome] = @[]

  # Never spin up more workers than there are units to run; ``resolveThreadCount``
  # has already floored the request at 1.
  let workerCount = min(threadCount, selected.len)
  result.threads = workerCount

  let args = WorkerArgs(
    queue: addr queue,
    registry: addr registry,
    resultsLock: addr resultsLock,
    outcomes: addr outcomes)

  var workers = newSeq[Thread[WorkerArgs]](workerCount)
  let wallStart = epochTime()
  for i in 0 ..< workerCount:
    createThread(workers[i], workerMain, args)
  joinThreads(workers)
  result.wallTimeMs = int((epochTime() - wallStart) * 1000)

  deinitLock(queue.lock)
  deinitLock(resultsLock)

  result.outcomes = outcomes

# ---------------------------------------------------------------------------
# Summary aggregation
# ---------------------------------------------------------------------------

proc summarize*(runResult: TestRunResult): TestRunSummary =
  ## Reduce a ``TestRunResult`` into pass/fail counts. A test is counted once
  ## per ``tekTestFinished`` event carrying a status: ``tsPassed`` increments
  ## ``passed``; every other terminal status (``tsFailed`` / ``tsErrored`` /
  ## ``tsSkipped``) is treated as not-passed and, for failed/errored, counted as
  ## ``failed``. ``tsSkipped`` is neither passed nor failed.
  result = TestRunSummary(
    totalDiscovered: runResult.totalDiscovered,
    executed: runResult.executedUnits,
    skippedByPartition: runResult.skippedByPartition,
    passed: 0,
    failed: 0,
    wallTimeMs: runResult.wallTimeMs,
    threads: runResult.threads)
  for outcome in runResult.outcomes:
    for event in outcome.events:
      if event.kind != tekTestFinished:
        continue
      if event.status.isNone:
        continue
      case event.status.get
      of tsPassed:
        inc result.passed
      of tsFailed, tsErrored:
        inc result.failed
      of tsSkipped:
        discard

proc summaryToJson*(summary: TestRunSummary): JsonNode =
  ## Serialise a run summary to the JSON shape the standalone runner emits, so
  ## downstream consumers (reprobuild sharding, CI dashboards) read one schema
  ## across both runners.
  %*{
    "total": summary.totalDiscovered,
    "executed": summary.executed,
    "skipped_by_partition": summary.skippedByPartition,
    "passed": summary.passed,
    "failed": summary.failed,
    "wall_time_ms": summary.wallTimeMs,
    "threads": summary.threads
  }

proc runExitCode*(summary: TestRunSummary): int =
  ## A run fails (non-zero exit) iff any executed test failed or errored.
  if summary.failed > 0: 1 else: 0
