## The Nim provider's build-and-ask path: ``ct test`` builds a Nim test
## source itself, asks the binary which tests it has, and runs them one at a
## time by name.
##
## THE TESTS ENTRY
## ---------------
## A test binary built with nim-entrypoints answers its ``tests`` entry
## (https://github.com/metacraft-labs/nim-entrypoints, README "Tests"):
##
## * ``<binary> --entrypoint=list`` prints the binary's entries as one JSON
##   document (schema ``entrypoints/1``), ``tests`` among them;
## * ``<binary> --entrypoint=tests --list`` prints the name of every test,
##   one per line, on standard output;
## * ``<binary> --entrypoint=tests --run-exact=<name>`` runs exactly the test
##   ``--list`` printed as ``<name>`` (never reading it as a pattern), and
##   exits non-zero when it fails or when no test has that name.
##
## A binary that links reprobuild's ``ct_test_unittest_parallel`` (a
## ``std/unittest`` shim) answers the same entry without nim-entrypoints, and
## names its tests ``<suite>::<test>``, or ``<test>`` outside a suite
## (https://github.com/metacraft-labs/reprobuild,
## ``libs/ct_test_unittest_parallel``).
##
## WHY THE LIST OF ENTRIES IS ASKED FIRST
## --------------------------------------
## ``--entrypoint=tests --list`` alone cannot be trusted. A plain
## ``std/unittest`` binary built with the codetracer Nim fork reads that
## ``--list`` as its own protocol flag and prints its tests' names, exit 0.
## It then reads ``--entrypoint=tests`` and ``--run-exact=<name>`` as test
## filters that match nothing, runs nothing and exits 0, even when the named
## test fails. Trusting the list would turn every one of its tests into a
## vacuous pass. So a binary is listed per test only when
## ``--entrypoint=list`` prints an ``entrypoints/1`` document naming a
## ``tests`` entry selectable at run time. A binary that prints no such
## document has no entries; its tests are not listed through it, and
## ``ct test`` does not run them (the lexical scan still discovers them, and
## the run refuses them, as it always has). A document that names entries
## but no run-time ``tests`` entry, or a probe that exits non-zero, is
## refused the same way, with the reason. This is the rule reprobuild's
## per-test collector applies (``ct_test_nim_unittest/tests_fragment``), so
## the two agree on which binaries are run per test.
##
## WHICH SOURCES ARE BUILT
## -----------------------
## Building is the expensive step, so a source is built only when it imports
## something that can answer the tests entry: ``entrypoints`` (or a module
## under ``entrypoints/``) or ``ct_test_unittest_parallel``. A plain
## ``std/unittest`` file cannot be run per test whatever its binary says
## (above), so building it would only produce a binary that is then refused.
## A file that reaches the entry only through a module of its own is not
## seen by this lexical check; importing one of those modules in the test
## file itself is what makes it collected through the entry.
##
## HOW A SOURCE IS BUILT
## ---------------------
## ``nim c`` from ``PATH``, run in the project root, so the project's own
## ``config.nims`` / ``nim.cfg`` beside and above the source decide its
## search paths and defines, exactly as when the user builds it. The binary
## and the nimcache live in ``ct test``'s cache
## (``<CODETRACER_HOME cache>/ct-test/nim-test-builds/<key>``), never in the
## project. ``-d:nimBetterRun`` makes Nim record every file the compile read
## with its hash and skip the next compile when none changed and the command
## line is the same (measured with the codetracer Nim fork 2.3.1: 4.0 s for
## the first build of a small test, 0.3 s for an unchanged rebuild). So
## every discovery and every run builds again, and a binary is never older
## than the sources Nim read for it. A lock file in the build directory
## serialises the builds of one source, across threads and processes, so two
## compiles never write one nimcache.

import std/[json, os, sets, sha1, strutils]

when not defined(windows):
  import std/posix

import ../contracts
import ../discovery
import ../process_exec
import ../../common/ct_home
import native_m11_common

const
  EntryListArg* = "--entrypoint=list"
    ## Prints a binary's entries (schema ``EntryListSchema``).
  EntryListSchema* = "entrypoints/1"
  TestsEntryArg* = "--entrypoint=tests"
  TestsEntryListArg* = "--list"
  TestsEntryRunExactPrefix* = "--run-exact="
  TestsEntryName = "tests"
  TestsEntryTag* = "nim-tests-entry"
    ## Tag of an item listed by its binary's tests entry, which ``ct test``
    ## runs by name.
  BuildTimeoutMs = 600_000
    ## A compile of one test source; generous, because a cold build of a
    ## test that imports much of a project is slow.
  ListTimeoutMs = 120_000
    ## The two listing commands run the program's start-up, which may do
    ## anything, so they are bounded.
  BuildLockName = "build.lock"

type
  EntryCollectionKind* = enum
    eckListed     ## built, has the entry, listed: run per test by name
    eckNoEntry    ## built, but no tests entry (or a refused one)
    eckNotBuilt   ## no binary: no ``nim``, or the compile failed

  EntryCollection* = object
    ## What building and asking one test source gave.
    kind*: EntryCollectionKind
    binary*: string
      ## The built binary (absolute), when there is one.
    names*: seq[string]
      ## The names ``--entrypoint=tests --list`` printed, in listing order
      ## (``eckListed`` only).
    problem*: string
      ## Why the source is not listed per test (``eckNoEntry``,
      ## ``eckNotBuilt``), as one message for a diagnostic.

  EntryProbe = object
    hasTestsEntry: bool
    refusal: string   ## non-empty: the binary has entries but no usable tests

proc runExactArgv*(binary, name: string): seq[string] =
  ## The command line that runs the test ``--list`` printed as ``name``.
  @[binary, TestsEntryArg, TestsEntryRunExactPrefix & name]

proc listArgv*(binary: string): seq[string] =
  ## The command line that lists ``binary``'s tests.
  @[binary, TestsEntryArg, TestsEntryListArg]

proc entryListArgv*(binary: string): seq[string] =
  ## The command line that asks ``binary`` which entries it has.
  @[binary, EntryListArg]

proc importsTestsEntry*(modules: openArray[string]): bool =
  ## Does a source that imports ``modules`` (as ``nim_unittest``'s import
  ## scan reads them) import something that answers the tests entry? See
  ## "WHICH SOURCES ARE BUILT" in the module header.
  for raw in modules:
    let module = raw.strip(chars = {' ', '\t', '\r', '\n', '"', '`', ','})
    if module == "entrypoints" or module.startsWith("entrypoints/") or
        module == "ct_test_unittest_parallel":
      return true
  false

proc probeEntryList(output: string): EntryProbe =
  ## Read the standard output of ``<binary> --entrypoint=list``. Not an
  ## ``entrypoints/1`` document: the binary has no entries. A document whose
  ## entries include ``tests`` selectable at run time: it has the entry. Any
  ## other document is a refusal, with the reason.
  var document: JsonNode
  try:
    document = parseJson(output.strip())
  except CatchableError:
    return EntryProbe(hasTestsEntry: false)
  if document.kind != JObject or
      document{"schema"}.getStr() != EntryListSchema:
    return EntryProbe(hasTestsEntry: false)
  let entries = document{"entries"}
  if entries.isNil or entries.kind != JArray:
    return EntryProbe(refusal: EntryListArg & " prints an " &
      EntryListSchema & " document without an \"entries\" list")
  for entry in entries:
    if entry.kind != JObject or entry{"name"}.getStr() != TestsEntryName:
      continue
    let select = entry{"select"}
    if not select.isNil and select.kind == JArray:
      for kind in select:
        if kind.getStr() == "runtime":
          return EntryProbe(hasTestsEntry: true)
    return EntryProbe(refusal: "its tests entry cannot be selected at run " &
      "time (" & EntryListArg & " lists it without \"runtime\")")
  EntryProbe(refusal: "it has entries (" & EntryListArg & " prints an " &
    EntryListSchema & " document) but no tests entry; register it with " &
    "`import entrypoints/tests`, or link ct_test_unittest_parallel")

proc entryListHasTests*(output: string): bool =
  ## Whether ``output``, the standard output of ``<binary>
  ## --entrypoint=list``, names a ``tests`` entry selectable at run time.
  probeEntryList(output).hasTestsEntry

proc parseTestListing*(output: string): tuple[names: seq[string];
    problem: string] =
  ## The test names in ``output``, the standard output of ``<binary>
  ## --entrypoint=tests --list``, in listing order. A listing with no test,
  ## an empty name or a name listed twice is refused (``problem`` says why):
  ## ``--run-exact=<name>`` runs every test of that name, so a duplicate could
  ## not be run as the one test its item stands for, and an empty listing
  ## would run nothing and look like a pass.
  var lines = output.split('\n')
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  var seen = initHashSet[string]()
  var duplicates: seq[string] = @[]
  for index, raw in lines:
    # A carriage return can only be a text-mode line ending: the tests entry
    # refuses a name that contains one.
    let name = if raw.endsWith('\r'): raw[0 ..< raw.high] else: raw
    if name.len == 0:
      return (@[], "the listing has an empty test name (line " &
        $(index + 1) & "), which --run-exact= cannot select")
    if seen.containsOrIncl(name):
      if name notin duplicates:
        duplicates.add name
      continue
    result.names.add name
  if duplicates.len > 0:
    return (@[], "the listing names " & duplicates.join(", ") &
      " more than once; each test run by name needs a name of its own")
  if result.names.len == 0:
    return (@[], "the listing names no tests")

# ---------------------------------------------------------------------------
# The build directory and its lock
# ---------------------------------------------------------------------------

proc nimCompiler(): string =
  findExe("nim")

proc buildDirFor*(file: string): string =
  ## Where ``file``'s binary and nimcache live. Keyed by the source's
  ## absolute path and the compiler, so two checkouts, or two Nims, never
  ## share a nimcache. Under ``CODETRACER_HOME`` when it is set, so a test
  ## run's builds stay in its scratch home.
  let key = $secureHash(normalizedPath(absolutePath(file)) & "\0" &
    nimCompiler())
  ctCacheDir() / "ct-test" / "nim-test-builds" / key[0 ..< 20].toLowerAscii

proc binaryPathFor*(file: string): string =
  buildDirFor(file) / splitFile(file).name.addFileExt(ExeExt)

when defined(windows):
  # The same exclusive-open lock ``certificate_local_store`` takes on its
  # store root.
  proc lockCreateFile(path: WideCString; access, share: uint32;
                      security: pointer; disposition, flags: uint32;
                      templateFile: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc lockCloseHandle(handle: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc lockLastError(): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
  type BuildLock = pointer
else:
  proc flockCall(fd, operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
  type BuildLock = cint

proc acquireBuildLock(dir: string): BuildLock =
  ## Hold ``<dir>/build.lock`` exclusively. ``flock`` on POSIX: it is held
  ## by the open file description, so two threads of one process that each
  ## open the file exclude each other too. On Windows an exclusive open
  ## (share mode 0) is retried while another holder has it.
  let path = dir / BuildLockName
  when defined(windows):
    while true:
      # GENERIC_READ | GENERIC_WRITE, no sharing, OPEN_ALWAYS, normal file.
      result = lockCreateFile(newWideCString(path), 0xC0000000'u32, 0, nil,
        4, 0x80, nil)
      if result != cast[pointer](-1):
        return
      let error = lockLastError()
      if error != 32: # ERROR_SHARING_VIOLATION: another holder has it
        raiseOSError(OSErrorCode(error), path)
      sleep(20)
  else:
    result = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if result < 0:
      raiseOSError(osLastError(), path)
    while flockCall(result, 2) != 0: # LOCK_EX
      if errno == EINTR:
        continue
      let error = osLastError()
      discard posix.close(result)
      raiseOSError(error, path)

proc releaseBuildLock(lock: BuildLock) =
  ## Closing the descriptor releases the lock. The lock file stays: another
  ## process may already have it open.
  when defined(windows):
    discard lockCloseHandle(lock)
  else:
    discard posix.close(lock)

# ---------------------------------------------------------------------------
# Build and ask
# ---------------------------------------------------------------------------

proc commandTail(output: string; lines = 12): string =
  ## The last lines of a command's output, for a diagnostic.
  let all = output.strip.splitLines
  all[max(0, all.len - lines) .. ^1].join("\n")

proc buildArgv*(compiler, file, dir: string): seq[string] =
  ## The compile of ``file`` into ``dir``. See "HOW A SOURCE IS BUILT".
  @[compiler, "c", "--hints:off", "--colors:off", "-d:nimBetterRun",
    "--nimcache:" & (dir / "nimcache"),
    "--out:" & (dir / splitFile(file).name.addFileExt(ExeExt)),
    normalizedPath(absolutePath(file))]

proc buildAndAskLocked(projectRoot, file, dir: string): EntryCollection =
  let compiler = nimCompiler()
  if compiler.len == 0:
    return EntryCollection(kind: eckNotBuilt,
      problem: "`nim` is not on PATH, so ct test could not build it")
  let binary = dir / splitFile(file).name.addFileExt(ExeExt)
  let build = execCaptured(buildArgv(compiler, file, dir), cwd = projectRoot,
    timeoutMs = BuildTimeoutMs)
  if build.timedOut or build.exitCode != 0 or not fileExists(binary):
    let how =
      if build.timedOut: "timed out after " & $(BuildTimeoutMs div 1000) & " s"
      else: "exited " & $build.exitCode
    return EntryCollection(kind: eckNotBuilt,
      problem: "`nim c` of it " & how & ":\n" & commandTail(build.output))

  result = EntryCollection(kind: eckNoEntry, binary: binary)
  let probe = execCaptured(entryListArgv(binary), cwd = projectRoot,
    timeoutMs = ListTimeoutMs)
  if probe.timedOut or probe.exitCode != 0:
    result.problem = "its binary's " & EntryListArg & " " &
      (if probe.timedOut: "timed out" else: "exited " & $probe.exitCode) &
      ":\n" & commandTail(probe.stderr)
    return
  let entries = probeEntryList(probe.stdout)
  if not entries.hasTestsEntry:
    result.problem =
      if entries.refusal.len > 0: "its binary is not run per test: " &
        entries.refusal
      else: "its binary has no tests entry (" & EntryListArg & " prints no " &
        EntryListSchema & " document), so its tests are not listed or run " &
        "through it: a std/unittest binary without the entry would list " &
        "them and then run none under --run-exact"
    return
  let listing = execCaptured(listArgv(binary), cwd = projectRoot,
    timeoutMs = ListTimeoutMs)
  if listing.timedOut or listing.exitCode != 0:
    result.problem = "its binary's " & TestsEntryArg & " " &
      TestsEntryListArg & " " &
      (if listing.timedOut: "timed out" else: "exited " & $listing.exitCode) &
      ":\n" & commandTail(listing.stderr)
    return
  if listing.truncated:
    result.problem = "its binary's test list is longer than ct test " &
      "captures, so it cannot be read whole"
    return
  let parsed = parseTestListing(listing.stdout)
  if parsed.problem.len > 0:
    result.problem = "its binary's test list is refused: " & parsed.problem
    return
  result.kind = eckListed
  result.names = parsed.names

proc collectThroughEntry*(projectRoot, file: string): EntryCollection =
  ## Build ``file`` and ask the binary for its tests (see the module header).
  ## Never raises: every way of not getting a list is a ``problem``.
  {.cast(gcsafe).}:
    try:
      let dir = buildDirFor(file)
      createDir(dir)
      let lock = acquireBuildLock(dir)
      try:
        result = buildAndAskLocked(projectRoot, file, dir)
      finally:
        releaseBuildLock(lock)
    except CatchableError as error:
      result = EntryCollection(kind: eckNotBuilt,
        problem: "ct test could not build it: " & error.msg)

# ---------------------------------------------------------------------------
# Running one test by name
# ---------------------------------------------------------------------------

proc runThroughEntry*(providerId: string; scope: TestScope):
    ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Run the one test ``scope.selector`` names, as its binary's tests entry
  ## lists it. The source is built again first (a no-op when nothing it reads
  ## changed) and its list read again, so the run never executes a binary
  ## older than its sources, and a test that is no longer listed is not
  ## reported as passing. Anything that keeps the named test from running
  ## finishes it ``tsErrored``: it was asked for and did not run.
  ##
  ## The outcome is the exit code: 0 passed, anything else failed. The tests
  ## entry has no status of its own for a skip (the shim and
  ## ``std/unittest`` exit 0 for a test that called ``skip``), so a skipped
  ## test reads as passed here.
  let
    runId = providerId & ":single:" & scope.selector
    testId = if scope.testId.len > 0: scope.testId else: scope.selector
  var events = @[event(tekRunStarted, providerId, runId, testId,
    message = "ct test: build " & scope.file & ", then " & TestsEntryArg &
      " " & TestsEntryRunExactPrefix & scope.selector)]
  proc refuse(reason: string): ProviderResult[seq[TestEvent]] =
    var refused = events
    refused.add unitOutcomeEvents(providerId, runId, testId, tsErrored,
      reason)
    ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError, reason, scope.file)],
      value: refused)

  if scope.kind != tskSingle:
    return refuse("the Nim provider runs one test at a time, by the name " &
      "its binary lists; a " & $scope.kind & " scope was asked for")
  let collected = collectThroughEntry(scope.projectRoot, scope.file)
  if collected.kind != eckListed:
    return refuse("test '" & scope.selector & "' was not run: " &
      collected.problem)
  if scope.selector notin collected.names:
    return refuse("test '" & scope.selector & "' was not run: its binary " &
      "no longer lists it (it lists " & collected.names.join(", ") & ")")

  events.add event(tekTestStarted, providerId, runId, testId,
    message = scope.selector)
  {.cast(gcsafe).}:
    let outcome = execCaptured(runExactArgv(collected.binary, scope.selector),
      cwd = scope.projectRoot)
  if outcome.output.len > 0:
    events.add event(tekOutput, providerId, runId, testId,
      output = outcome.output, durationMs = outcome.durationMs)
  events.add unitOutcomeEvents(providerId, runId, testId, outcome.exitCode,
    "test '" & scope.selector & "' exited with " & $outcome.exitCode,
    outcome.output, outcome.durationMs)
  if outcome.exitCode == 0:
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)
  else:
    ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError, "test '" & scope.selector &
        "' failed with exit code " & $outcome.exitCode, scope.file)],
      value: events)
