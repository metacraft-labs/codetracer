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
##
## Heap-ownership note (see ``ResultHandoff`` below): mutual exclusion is *not*
## sufficient on its own. Nim's ARC/ORC allocator is per-thread, and a heap
## block may only be freed while the thread that allocated it is still alive,
## so ``runUnits`` additionally takes ownership of the workers' results — by
## re-materialising them in the calling thread's heap — *before* the workers are
## allowed to exit.

import std/[algorithm, cpuinfo, json, locks, options, os, sets, strutils,
             tables, times]

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
    unrunnable*: bool
      ## The owning provider declared it cannot run this unit's scope, so its
      ## ``run`` proc was never invoked and no test was even attempted.
      ##
      ## Deliberately distinct from "ran and reported no finished test": the
      ## first is a *capability* gap the runner can name up front, the second is
      ## a provider that tried and produced nothing. Collapsing them is how a
      ## suite nobody can execute came to look like a suite that passed.
    events*: seq[TestEvent]
    diagnostics*: seq[TestDiagnostic]

  TestRunResult* = object
    ## Raw, aggregated output of a run: the flattened events from every
    ## dispatched unit, plus the bookkeeping the summary is computed from.
    totalDiscovered*: int          ## RunUnits enumerated before partitioning
    skippedByPartition*: int       ## discovered units dropped by the partition
    dispatchedUnits*: int          ## units actually handed to a provider
      ## **Named for what it is.** This used to be called ``executedUnits`` and
      ## was reported to the world as ``executed``, which is what let a run that
      ## dispatched 333 units and finished zero tests print ``"executed": 333``
      ## and exit 0. A dispatched unit is *work handed out*, not a test that
      ## ran; the number of tests that ran lives in ``TestRunSummary.executed``
      ## and is derived from the providers' own ``tekTestFinished`` events.
    threads*: int                  ## worker threads used
    wallTimeMs*: int               ## wall-clock duration of the parallel phase
    outcomes*: seq[RunUnitOutcome] ## per-unit event streams (run order varies)

  TestRunSummary* = object
    ## The reduced, reportable summary derived from a ``TestRunResult``.
    ##
    ## **``executed`` counts TESTS, not units**, and it counts only the three
    ## statuses that mean a test genuinely ran — ``tsPassed``, ``tsFailed``,
    ## ``tsErrored``. This is deliberately the same definition
    ## ``certificate_issuance.AttestedRun.executed`` uses, because two counters
    ## in one binary that disagree about what "executed" means is exactly how
    ## the exit code and the certificate came to contradict each other: the
    ## certificate refused to attest a run (``wrNoTestsExecuted``) that the exit
    ## code called a success.
    ##
    ## The invariant every reader already assumed now actually holds:
    ## ``passed + failed == executed``, and ``executed + skipped`` is the number
    ## of tests that reported a terminal status at all.
    totalDiscovered*: int
    dispatchedUnits*: int
      ## Units handed to a provider. Carries no information the rest of the
      ## summary lacks — it is always ``totalDiscovered - skippedByPartition``
      ## — which is precisely why redefining ``executed`` costs a consumer
      ## nothing: the old value is still reported, under a name that says what
      ## it is.
    skippedByPartition*: int
    executed*: int
      ## Tests that finished as passed, failed or errored.
    passed*: int
    failed*: int
    skipped*: int
      ## Tests that finished as ``tsSkipped``. **Never evidence** — a skip runs
      ## no assertion — but counted so a "nothing executed" verdict can say
      ## *why* to someone who just watched a suite report skips.
    unrunnableUnits*: int
      ## Dispatched units whose provider declares it cannot run them.
    wallTimeMs*: int
    threads*: int

  RunVerdict* = enum
    ## What a finished run is allowed to claim. Three outcomes, because two are
    ## not enough: with only pass/fail, "nothing ran" is indistinguishable from
    ## "everything passed", which is the defect this enum exists to remove.
    rvPassed = "passed"
      ## Tests ran and every one of them passed.
    rvFailed = "failed"
      ## Tests ran and at least one failed or errored.
    rvNothingExecuted = "nothing-executed"
      ## No test reported a terminal status of passed, failed or errored. The
      ## run proves nothing, so it must not report success.
      ##
      ## An all-skipped run lands here too, matching
      ## ``certificate_issuance``'s single ``wrNoTestsExecuted`` reason rather
      ## than inventing a fourth verdict: a skipped test runs no assertion, so
      ## a suite of nothing but skips has established exactly as much as a
      ## suite that never started. The two are told apart in the *message*, not
      ## in the verdict, because they need different remedies but support the
      ## same (empty) claim.

const
  ReproTestThreadsEnv* = "REPRO_TEST_THREADS"
    ## Environment override for the default worker-thread count, matching the
    ## standalone ``ct-test-runner`` so reprobuild's sharding driver can pin the
    ## thread budget uniformly across both runners.
  PartitionFilePrefix* = "file:"

  ExitRunPassed* = 0
    ## Tests ran and all passed.
  ExitTestsFailed* = 1
    ## Tests ran and at least one failed. **Unchanged**, so every consumer that
    ## only ever distinguished "zero" from "non-zero" keeps working, and every
    ## consumer that special-cased 1 keeps working too.
  ExitNothingExecuted* = 2
    ## No test executed. Distinct from ``ExitTestsFailed`` on purpose: "your
    ## tests are broken" and "your runner ran nothing" call for entirely
    ## different investigations, and a CI lane that cannot tell them apart will
    ## debug the wrong one.

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

  ResultHandoff = object
    ## Ownership hand-off barrier between the workers and the spawning thread.
    ##
    ## **Why this exists.** Nim's ARC/ORC allocator is *per thread*: every
    ## thread has its own ``MemRegion``, and that region lives in the thread's
    ## thread-local storage (``lib/system/mmdisp.nim``:
    ## ``var allocator {.rtlThreadVar.}: MemRegion``). Every ``string``/``seq``
    ## payload a worker allocates is therefore stamped with that worker's region
    ## as its owner (``PSmallChunk.owner``).
    ##
    ## Freeing such a block from a *different* thread is supported — but only
    ## while the owning thread is still alive. ``rawDealloc``
    ## (``lib/system/alloc.nim``) notices ``c.owner != addr(a)`` and hands the
    ## cell to the owner via ``addToSharedFreeList``, which dereferences
    ## ``c.owner`` to reach ``c.owner.sharedFreeLists[…]``. Once the worker has
    ## exited, that dereference is a use-after-free: glibc only keeps a bounded
    ## cache of retired thread stacks (``stack_cache_maxsize``, 40 MiB by
    ## default) and unmaps the rest together with their static TLS blocks. Below
    ## the cache limit the write silently lands in a retired region (leaking the
    ## cell, or worse, resurfacing it in a *recycled* region); above it the
    ## process dies with ``SIGSEGV`` inside ``addToSharedFreeList``.
    ##
    ## That is exactly what ``runUnits`` used to do: the aggregated
    ## ``RunUnitOutcome``s were allocated by the workers, the workers were then
    ## joined, and the caller freed the results afterwards — reliably crashing
    ## once enough workers ran for their stacks to overflow glibc's cache. On
    ## Linux/glibc that boundary is 21 workers, and the arithmetic is exact: Nim
    ## gives every thread a 2 MiB stack of its own (``ThreadStackSize`` in
    ## ``std/typedthreads`` is ``1024*256*sizeof(int) - 4096``, independent of
    ## ``ulimit -s``), so glibc's 40 MiB default retains exactly 20 of them and
    ## the 21st worker's region is unmapped by the time the caller frees.
    ##
    ## Below that boundary nothing is safe either — it is the same illegal
    ## write, merely landing in a still-mapped retired region. Setting
    ## ``GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0`` disables the cache
    ## and makes the defect fatal at a *single* worker, which is the only
    ## trustworthy way to stress-test this code path.
    ##
    ## **The protocol.** Workers park here once the queue is drained instead of
    ## returning from their thread proc. The spawning thread waits for all of
    ## them to park, re-materialises the results in its *own* heap region
    ## (``adoptOutcomes``), releases the worker-owned originals — still legal,
    ## the workers are alive and parked — and only then lets the workers exit.
    ## Post-condition: ``runUnits`` hands its caller memory that the calling
    ## thread owns, and no worker-owned allocation outlives its worker.
    lock: Lock
    parked: Cond          ## workers → owner: "another worker has parked"
    releaseCond: Cond     ## owner → workers: "results adopted, you may exit"
    arrived: int          ## workers that have reached the barrier
    released: bool        ## owner is done with the worker-owned results

  WorkerArgs = object
    ## Plain-pointer bundle passed by value to each worker thread. Pointers (not
    ## closures) keep the worker proc ``{.thread.}``-safe; every shared mutation
    ## happens under one of the two locks.
    queue: ptr Queue
    registry: ptr ProviderRegistry
    resultsLock: ptr Lock
    outcomes: ptr seq[RunUnitOutcome]
    handoff: ptr ResultHandoff

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

proc canRunScope*(capabilities: TestCapabilities; kind: TestScopeKind): bool =
  ## Does a provider declaring ``capabilities`` claim it can run a ``kind``
  ## scope? This is the *declared* capability from ``TestProviderInfo``, which
  ## is the only thing the orchestrator can consult before dispatching.
  case kind
  of tskProject: capabilities.canRunProject
  of tskFile: capabilities.canRunFile
  of tskSingle: capabilities.canRunSingle

proc runUnitOutcome(
    registry: ptr ProviderRegistry; unit: RunUnit): RunUnitOutcome {.gcsafe.} =
  ## Execute one run unit by invoking the owning provider's ``run`` proc with
  ## the unit's scope, and tag the returned events. A missing provider, a
  ## provider with no ``run`` proc, or a provider that declares it cannot run
  ## this scope yields an error outcome rather than crashing the worker — or,
  ## worse, silently producing nothing.
  result = RunUnitOutcome(
    providerId: unit.providerId,
    testId: unit.item.id,
    unrunnable: false,
    events: @[],
    diagnostics: @[])
  let provider = findProvider(registry, unit.providerId)
  if provider == nil:
    result.unrunnable = true
    result.diagnostics.add diagnostic(
      dsError, "no registered provider for id: " & unit.providerId,
      unit.item.file)
    return
  if provider.run == nil:
    result.unrunnable = true
    result.diagnostics.add diagnostic(
      dsError, "provider has no run implementation: " & unit.providerId,
      unit.item.file)
    return

  # ---- The upstream half of "a run that ran nothing reported success" -------
  # A provider whose declared capabilities say it cannot run this scope is not
  # asked to. Several shipped providers (``nim-unittest``, ``python-pytest``,
  # ``python-unittest``, every ``smart-*`` harness) declare
  # ``canRunProject/File/Single = false`` and wire ``run`` to a stub that
  # returns a *warning* diagnostic and an empty event stream. Dispatching to
  # that stub was indistinguishable, downstream, from a provider that ran and
  # found nothing to report — and the warning went nowhere, because the run
  # summary never surfaced per-unit diagnostics.
  #
  # So the refusal is recorded HERE, as an error, before the stub can turn it
  # into silence. The unit still exists and is still counted (it was genuinely
  # discovered); what changes is that "no provider could run this" is now a
  # fact the summary carries rather than an absence the summary cannot see.
  #
  # This does NOT implement the missing providers — that is its own milestone —
  # and it deliberately does not fail the run on its own (see ``runVerdict``).
  if not provider.info.capabilities.canRunScope(unit.scope.kind):
    result.unrunnable = true
    result.diagnostics.add diagnostic(
      dsError,
      "provider '" & unit.providerId & "' declares it cannot run a " &
      $unit.scope.kind & " scope, so this test was discovered but never " &
      "executed",
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

proc parkUntilReleased(handoff: ptr ResultHandoff) =
  ## Announce that this worker has finished producing results and block until
  ## the spawning thread has taken ownership of them (see ``ResultHandoff``).
  ##
  ## Parking — rather than returning — is what keeps this worker's ``MemRegion``
  ## mapped while the owner frees the blocks this worker allocated.
  acquire(handoff.lock)
  inc handoff.arrived
  signal(handoff.parked)
  while not handoff.released:
    wait(handoff.releaseCond, handoff.lock)
  release(handoff.lock)

proc workerMain(args: WorkerArgs) {.thread.} =
  ## Top-level thread entry point. Worker threads cannot capture closures, so
  ## the per-thread state arrives by value as ``WorkerArgs``.
  ##
  ## The barrier is reached from a ``finally`` so that a worker which dies on an
  ## unexpected exception still (a) reports its arrival — the owner would
  ## otherwise wait forever — and (b) keeps its heap region alive until the
  ## owner has adopted whatever results it did manage to append.
  try:
    workerLoop(args)
  finally:
    parkUntilReleased(args.handoff)

proc adoptOutcomes(source: seq[RunUnitOutcome]): seq[RunUnitOutcome] =
  ## Re-materialise ``source`` in the **calling** thread's heap region.
  ##
  ## ``source`` is a borrowed (non-``sink``) parameter and stays live across the
  ## loop, so the compiler cannot turn ``add source[i]`` into a move: it must
  ## emit ``=copy``. ``RunUnitOutcome`` and everything it transitively contains
  ## (``TestEvent``, ``TestDiagnostic``, ``TraceMetadata`` and its
  ## ``Table[string, string]``) are pure value types with no ``ref`` fields, so
  ## ``=copy`` is a genuine deep copy: every payload in the result is freshly
  ## allocated here rather than aliased from a worker's region.
  result = newSeqOfCap[RunUnitOutcome](source.len)
  for i in 0 ..< source.len:
    result.add source[i]

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
    dispatchedUnits: selected.len,
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

  var handoff = ResultHandoff(arrived: 0, released: false)
  initLock(handoff.lock)
  initCond(handoff.parked)
  initCond(handoff.releaseCond)

  # Never spin up more workers than there are units to run; ``resolveThreadCount``
  # has already floored the request at 1.
  let workerCount = min(threadCount, selected.len)
  result.threads = workerCount

  let args = WorkerArgs(
    queue: addr queue,
    registry: addr registry,
    resultsLock: addr resultsLock,
    outcomes: addr outcomes,
    handoff: addr handoff)

  var workers = newSeq[Thread[WorkerArgs]](workerCount)
  let wallStart = epochTime()

  # Track how many threads actually started: ``createThread`` raises when the
  # OS refuses one, and both the barrier wait below and ``joinThread`` must be
  # driven by the real count rather than the requested one.
  var started = 0
  try:
    while started < workerCount:
      createThread(workers[started], workerMain, args)
      inc started
  except CatchableError:
    # The OS refused a thread (``ResourceExhaustedError``). Continue with the
    # workers we did get rather than failing the whole run; if none started we
    # fall back to draining the queue on this thread below.
    discard

  if started == 0:
    # No worker could be started: drain the queue here instead of silently
    # reporting zero outcomes. Everything is then allocated on this thread, so
    # the hand-off below degrades to a plain (redundant) copy.
    result.threads = 1
    workerLoop(args)
  else:
    # Wait for every started worker to reach the barrier. At that point the
    # queue is drained and ``outcomes`` is complete and stable.
    acquire(handoff.lock)
    while handoff.arrived < started:
      wait(handoff.parked, handoff.lock)
    release(handoff.lock)
    result.threads = started

  result.wallTimeMs = int((epochTime() - wallStart) * 1000)

  # Take ownership while the workers are still parked and their heap regions
  # are still mapped: copy the results into this thread's region, then release
  # every worker-owned allocation. Doing this after ``joinThreads`` is the
  # use-after-free documented on ``ResultHandoff``. Both halves matter — moving
  # instead of copying, or moving the ``reset`` below the joins, each restores
  # the crash on its own.
  result.outcomes = adoptOutcomes(outcomes)
  reset(outcomes)

  # Deliberately NOT wrapped in a ``try/finally``. Nothing from here to the
  # joins can raise in practice (``std/locks`` only looks fallible to Nim's
  # effect inference), and a ``finally`` would have to run the release+join on
  # the *barrier-wait* failure path too — signalling the workers and freeing
  # ``outcomes`` while they may still be appending to it, which is a worse
  # failure than the one it would be guarding against. If an exception does
  # escape here, the scope destructors still free the worker-owned results
  # while the workers are parked and alive, so the lifetime rule above holds.
  acquire(handoff.lock)
  handoff.released = true
  broadcast(handoff.releaseCond)
  release(handoff.lock)

  for i in 0 ..< started:
    joinThread(workers[i])

  deinitCond(handoff.parked)
  deinitCond(handoff.releaseCond)
  deinitLock(handoff.lock)
  deinitLock(queue.lock)
  deinitLock(resultsLock)

# ---------------------------------------------------------------------------
# Summary aggregation
# ---------------------------------------------------------------------------

proc summarize*(runResult: TestRunResult): TestRunSummary =
  ## Reduce a ``TestRunResult`` into the counts a run is reported by.
  ##
  ## A test is counted once per ``tekTestFinished`` event carrying a status.
  ## ``tsPassed`` increments ``passed``, ``tsFailed``/``tsErrored`` increment
  ## ``failed``, and all three increment ``executed`` — because all three mean a
  ## test genuinely ran. ``tsSkipped`` increments ``skipped`` and **nothing
  ## else**: a skip runs no assertion, so it is neither passed, nor failed, nor
  ## executed. That is the same rule ``certificate_issuance.recordUnitResult``
  ## applies, and it is stated in one voice in both places on purpose.
  ##
  ## ``dispatchedUnits`` is carried through unchanged. It is the count of units
  ## handed to a provider, which is *not* a count of tests and must never again
  ## be reported as one.
  result = TestRunSummary(
    totalDiscovered: runResult.totalDiscovered,
    dispatchedUnits: runResult.dispatchedUnits,
    skippedByPartition: runResult.skippedByPartition,
    executed: 0,
    passed: 0,
    failed: 0,
    skipped: 0,
    unrunnableUnits: 0,
    wallTimeMs: runResult.wallTimeMs,
    threads: runResult.threads)
  for outcome in runResult.outcomes:
    if outcome.unrunnable:
      inc result.unrunnableUnits
    for event in outcome.events:
      if event.kind != tekTestFinished:
        continue
      if event.status.isNone:
        continue
      case event.status.get
      of tsPassed:
        inc result.executed
        inc result.passed
      of tsFailed, tsErrored:
        inc result.executed
        inc result.failed
      of tsSkipped:
        inc result.skipped

proc unrunnableByProvider*(runResult: TestRunResult):
    seq[tuple[providerId: string; units: int]] =
  ## Which providers refused how many units, sorted by provider id.
  ##
  ## Sorted rather than table-ordered so the report is byte-identical between
  ## runs; a diagnostic that reorders itself run to run is one nobody can diff.
  ## Aggregated rather than listed per unit because a workspace can produce
  ## hundreds of refusals from a handful of providers, and three hundred
  ## identical lines is not a report.
  var counts = initTable[string, int]()
  for outcome in runResult.outcomes:
    if outcome.unrunnable:
      counts.mgetOrPut(outcome.providerId, 0) += 1
  result = @[]
  for providerId, units in counts:
    result.add (providerId: providerId, units: units)
  result.sort(proc(a, b: tuple[providerId: string; units: int]): int =
    cmp(a.providerId, b.providerId))

proc runVerdict*(summary: TestRunSummary): RunVerdict =
  ## What this run is allowed to claim.
  ##
  ## Order matters and is load-bearing:
  ##
  ## 1. ``failed > 0`` wins outright, so the failing case keeps its exit status
  ##    no matter what else the run did or did not manage.
  ## 2. Otherwise ``executed == 0`` is ``rvNothingExecuted``. **This is the
  ##    whole fix**: with only pass/fail, a run that finished no test was
  ##    indistinguishable from a run in which everything passed, and reported
  ##    the latter.
  ## 3. Only a run that executed at least one test and failed none passes.
  ##
  ## A run with *some* executed tests and *some* unrunnable units passes, and
  ## that is deliberate — see ``runVerdictReport``.
  if summary.failed > 0: rvFailed
  elif summary.executed == 0: rvNothingExecuted
  else: rvPassed

proc summaryToJson*(summary: TestRunSummary): JsonNode =
  ## Serialise a run summary to the machine-readable schema.
  ##
  ## ``executed`` now means *tests that finished with a real status* rather
  ## than *units dispatched*. Nothing is lost by that redefinition: the old
  ## value is reported as ``dispatched``, and it was in any case always exactly
  ## ``total - skipped_by_partition``. What is gained is that ``executed``
  ## finally means what its name, and every one of its neighbours in this
  ## object, already implied — so ``passed + failed == executed`` is now a real
  ## invariant instead of a coincidence.
  ##
  ## ``verdict`` is emitted alongside the counts so a consumer never has to
  ## re-derive the run's own conclusion (and never has to re-derive it
  ## *wrongly*); it mirrors the process exit status exactly.
  %*{
    "total": summary.totalDiscovered,
    "dispatched": summary.dispatchedUnits,
    "executed": summary.executed,
    "skipped": summary.skipped,
    "skipped_by_partition": summary.skippedByPartition,
    "passed": summary.passed,
    "failed": summary.failed,
    "unrunnable": summary.unrunnableUnits,
    "wall_time_ms": summary.wallTimeMs,
    "threads": summary.threads,
    "verdict": $summary.runVerdict
  }

proc runExitCode*(summary: TestRunSummary): int =
  ## The process exit status for a finished run.
  ##
  ## ``0`` only when tests ran and all passed. ``ExitTestsFailed`` (1) is
  ## unchanged for the failing case. ``ExitNothingExecuted`` (2) is new, and is
  ## the point: the shipped binary used to exit 0 for a run that finished no
  ## test at all, while the certificate path refused to attest the very same
  ## run — the exit code and the attestation actively contradicted each other.
  case summary.runVerdict
  of rvPassed: ExitRunPassed
  of rvFailed: ExitTestsFailed
  of rvNothingExecuted: ExitNothingExecuted

proc runVerdictReport*(summary: TestRunSummary):
    tuple[message, remedy: string] =
  ## Why this run is not a success, and what would make it one.
  ##
  ## An exit code that changes from 0 to non-zero with no explanation is worse
  ## than the bug it fixes, so every non-zero verdict carries both halves — the
  ## same contract ``certificate_issuance.Issuance`` holds itself to, in the
  ## same voice, because a user meeting both messages in one run should not
  ## have to work out that they are about the same thing.
  ##
  ## Returns two empty strings for ``rvPassed``: there is nothing to explain.
  case summary.runVerdict
  of rvPassed:
    ("", "")
  of rvFailed:
    ($summary.failed & " of " & $summary.executed &
       " executed tests did not pass",
     "fix the failing tests and re-run")
  of rvNothingExecuted:
    # Four ways to execute nothing, and they send an operator to four different
    # places. "No tests executed" alone is baffling to someone who just watched
    # a suite report skips, or who passed a partition file that matched
    # nothing, and would send them hunting a discovery bug that is not there.
    if summary.skipped > 0:
      ("no test executed: all " & $summary.skipped &
         " that finished were skipped, so this run proves nothing",
       "a skipped test runs no assertion and is not evidence, so a run of " &
       "nothing but skips cannot report success; un-skip at least one test, " &
       "or narrow the run to a suite that actually executes")
    elif summary.dispatchedUnits == 0:
      ("no test executed: no unit was dispatched at all (" &
         $summary.totalDiscovered & " discovered, " &
         $summary.skippedByPartition & " removed by the partition allow-list)",
       "check the workspace and any --partition allow-list: an allow-list " &
       "that admits nothing runs nothing, and a run that runs nothing " &
       "cannot report success")
    elif summary.unrunnableUnits >= summary.dispatchedUnits:
      ("no test executed: all " & $summary.dispatchedUnits &
         " dispatched units were handed to a provider that declares it " &
         "cannot run them, so nothing was even attempted",
       "no shipped ct_test provider can yet run these suites; the run's " &
       "`unrunnable` count and the `errors` list say which providers " &
       "refused. Run those suites with their own runner until a provider " &
       "implements them — an exit status of 0 here would mean 'the tests " &
       "passed', which nothing in this run establishes")
    else:
      ("no test executed: " & $summary.dispatchedUnits &
         " units were dispatched but no provider reported a finished test",
       # Deliberately does NOT point at a flag: `run` emits only the summary,
       # and its `--json` is accepted but changes nothing, so a remedy naming
       # either would send an operator somewhere that cannot help them.
       "the providers were asked to run and emitted no test-finished event " &
       "at all; run the suite with its own runner to see what it does, and " &
       "treat this as a provider defect rather than a passing suite")

proc unrunnableNotice*(summary: TestRunSummary): string =
  ## The warning a run owes its user when it executed *some* tests but was
  ## handed units nothing could run.
  ##
  ## This case stays **green**, and the reasoning is the certificate's: partial
  ## coverage is normal (test-certificates-spec Standard.md §8), and a
  ## certificate is issued for a partial run while a zero run withholds. The
  ## exit code answers "did the tests you asked for pass?" — a unit no provider
  ## can run is one the runner could not ask about, which narrows the answer's
  ## scope rather than falsifying it. A run that could ask about *nothing* has
  ## no answer at all, and that is the case that reddens.
  ##
  ## Reddening here instead would fail a great many runs that legitimately pass
  ## today, since discovery routinely turns up suites whose providers are still
  ## unimplemented. So the narrowing is reported loudly, in the summary as
  ## ``unrunnable`` and on stderr as this line, and never hidden.
  ##
  ## Empty when there is nothing to warn about.
  if summary.unrunnableUnits == 0 or summary.runVerdict == rvNothingExecuted:
    return ""
  let tests =
    if summary.executed == 1: "1 executed test covers"
    else: $summary.executed & " executed tests cover"
  $summary.unrunnableUnits & " of " & $summary.dispatchedUnits &
    " dispatched units were never attempted: their provider declares it " &
    "cannot run them. This run's " & tests & " only the rest."
