## The default untracked mode's read-set check, over a read set a REAL
## capture produced (CTC-3g).
##
## In the default mode (`[certificate] untracked = "reads"`) a certificate is
## withheld with ``wrUntrackedInput`` when the run's captured read set names
## an untracked file. Two suites:
##
## * the check on the incremental engine's read-file capture, which runs a
##   process under io-mon's interpose monitor and writes the
##   ``native_readfiles.json`` projection;
## * the same check on `ct test run`'s OWN capture: ``runAndAttest`` runs
##   every process a provider launches through the shared launcher under
##   io-mon (``run_read_capture``) when untracked files exist, and judges them
##   by what those processes read. Driven through the real ``runAndAttest``
##   with a leaf provider that launches a real ``cat`` (see that suite's
##   note for why the leaf is the only seam).
##
## HOW A READ SET IS PRODUCED HERE
## -------------------------------
## For real: ``io_mon_capture.captureReadFilesLive`` runs ``cat <file>``
## under the io-mon monitor, the capture is written as the projection by
## ``writeReadFilesProjection`` — the code the incremental runner uses — and
## ``certificate_issuance.readSetFromProjection`` reads it back. The
## repository is a real git repository and its untracked entries come from
## the real ``probeVcs``. Nothing is fabricated, so there is no mock to
## justify.
##
## The monitor is needed at run time: the io-mon CLI and its interpose shim.
## They are taken from ``$IO_MON`` / ``PATH`` and ``$REPRO_MONITOR_SHIM_LIB``
## when set; otherwise this suite builds both from the workspace's ``io-mon``
## sibling (and the siblings its build names) into a scratch directory. When
## neither works the suite FAILS, naming what is missing: a skipped case here
## would be a read-set check nobody ran.

import std/[options, os, osproc, streams, strtabs, strutils, unittest]

import certificate_issuance
import contracts
import discovery
import process_exec
import run_orchestration
import incremental/io_mon_capture

let scratchRoot = getTempDir() / "ct-test-cert-reads-" & $getCurrentProcessId()

proc run(cmd: string; args: openArray[string]; cwd: string;
         env: openArray[(string, string)] = []): tuple[output: string; code: int] =
  ## Fixture scaffolding, not the code under test. ``env`` is added to this
  ## process's environment for the child.
  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    childEnv[k] = v
  for (k, v) in env:
    childEnv[k] = v
  var p = startProcess(cmd, workingDir = cwd, args = @args, env = childEnv,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc git(dir: string; args: varargs[string]) =
  let (output, code) = run("git", args, dir)
  doAssert code == 0, "git " & args.join(" ") & " failed in " & dir & ":\n" &
                      output

proc committedRepo(name: string): string =
  result = scratchRoot / name
  removeDir(result)
  createDir(result)
  git(result, "init", "--initial-branch=main", ".")
  git(result, "config", "user.email", "ct-test@example.invalid")
  git(result, "config", "user.name", "ct test suite")
  git(result, "config", "commit.gpgsign", "false")
  writeFile(result / "a.txt", "tracked\n")
  git(result, "add", "-A")
  git(result, "commit", "-q", "-m", "initial")

proc provisionIoMon(): string =
  ## Make the live monitor available, or return why it is not.
  if ioMonLiveCaptureAvailable():
    return ""
  let workspace = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  let ioMon = getEnv("IO_MON_REPO", workspace / "io-mon")
  if not fileExists(ioMon / "cmd" / "io_mon_snoop.nim"):
    return "no io-mon CLI on PATH or in $" & IoMonSnoopEnvVar &
      ", and no io-mon sibling at '" & ioMon & "' to build one from " &
      "(set IO_MON_REPO to an io-mon checkout)"
  let outDir = scratchRoot / "io-mon"
  createDir(outDir)
  if findShimLibrary().len == 0:
    let shim = run("bash", ["scripts/build_shim.sh"], ioMon, [
      ("IO_MON_SHIM_OUT_DIR", outDir / "lib"),
      ("IO_MON_SHIM_NIMCACHE_DIR", outDir / "shim-nimcache")])
    if shim.code != 0:
      return "building the io-mon shim failed:\n" & shim.output
    for kind, path in walkDir(outDir / "lib"):
      if path.extractFilename.startsWith("librepro_monitor_shim"):
        putEnv(IoMonShimEnvVar, path)
  if findSnoopCli().len == 0:
    let binary = outDir / "bin" / IoMonSnoopBinaryName
    let cli = run("nim", ["c", "--hints:off", "--warnings:off",
                          "--nimcache:" & outDir / "cli-nimcache",
                          "-o:" & binary, "cmd/io_mon_snoop.nim"], ioMon)
    if cli.code != 0:
      return "building the io-mon CLI failed:\n" & cli.output
    putEnv(IoMonSnoopEnvVar, binary)
  if not ioMonLiveCaptureAvailable():
    return "io-mon was built but is still not locatable"
  ""

proc captureReading(repo, name: string; files: openArray[string]): ReadSet =
  ## Run `cat` over ``files`` (repository-relative) under the live monitor,
  ## write the capture as the incremental engine's projection, and read it
  ## back as a read set.
  let cat = findExe("cat", followSymlinks = false)
  doAssert cat.len > 0, "no `cat` on PATH"
  var command = @[cat]
  for file in files:
    command.add repo / file
  let traceDir = scratchRoot / ("capture-" & name)
  createDir(traceDir)
  let reads = captureReadFilesLive(command, traceDir / "capture.iomon")
  doAssert reads.isOk, "io-mon capture failed: " & reads.error
  let written = writeReadFilesProjection(traceDir, reads.value)
  doAssert written.isOk, written.error
  readSetFromProjection(traceDir)

let provisioned = provisionIoMon()

suite "the default untracked mode's read-set check, on a real capture":

  test "the live monitor is available":
    checkpoint provisioned
    check provisioned.len == 0

  test "the read-set check withholds for an untracked file a captured read set names":
    ## Control both ways: an untracked file the run did not read only makes
    ## untracked = true; a tracked file the run read is not an untracked
    ## input; and strict mode withholds for every untracked file regardless.
    require provisioned.len == 0
    let repo = committedRepo("read-untracked")
    writeFile(repo / "fixture-input.txt", "an input the test reads\n")
    writeFile(repo / "unread.txt", "never opened\n")
    createDir(repo / "data")
    writeFile(repo / "data" / "table.csv", "1,2\n")
    let probe = probeVcs(repo)
    require probe.determined
    check probe.untrackedPaths == @["data/", "fixture-input.txt", "unread.txt"]

    let readSet = captureReading(repo, "untracked",
                                 ["a.txt", "fixture-input.txt",
                                  "data/table.csv"])
    checkpoint readSet.source
    require readSet.captured
    if readSet.paths.len == 0:
      # A PLATFORM LIMITATION, stated rather than passed over: where the
      # interpose shim cannot reach the process (macOS strips the injection
      # from SIP-protected binaries such as /bin/cat, and arm64e chained-fixups
      # binaries bypass __interpose; see io_mon_capture.ioMonLiveCaptureAvailable)
      # the capture is empty, and this suite cannot verify the check. It fails
      # there by name. The ct-test-certificates CI job runs on Linux, where
      # the capture is real.
      checkpoint "the live capture recorded no reads on this platform " &
        "(hostOS = " & hostOS & "), so the read-set check could not be " &
        "verified here"
    require readSet.paths.len > 0
    # The capture is real: it saw what `cat` opened, by absolute path.
    var sawInput = false
    for path in readSet.paths:
      if path.endsWith("fixture-input.txt"): sawInput = true
      check not path.endsWith("unread.txt")
    check sawInput

    let judged = judgeUntracked(umReads, probe.root, probe.untrackedPaths,
                                readSet)
    check judged.withhold
    check judged.readSetCaptured
    # The read untracked files, by file — a directory entry is resolved to
    # the file under it that was read — and not the unread one, nor the
    # tracked one.
    check judged.offending == @["data/table.csv", "fixture-input.txt"]
    check judged.note.len == 0

    # Control: the run read only tracked files.
    let trackedOnly = captureReading(repo, "tracked", ["a.txt"])
    require trackedOnly.captured
    let clean = judgeUntracked(umReads, probe.root, probe.untrackedPaths,
                               trackedOnly)
    check not clean.withhold
    check clean.offending.len == 0
    check clean.note.len == 0       # judged, not guessed: nothing to say

    # Strict mode needs no read set: every untracked entry withholds.
    let strict = judgeUntracked(umStrict, probe.root, probe.untrackedPaths,
                                trackedOnly)
    check strict.withhold
    check strict.offending == @["data/", "fixture-input.txt", "unread.txt"]

  test "a missing or unreadable projection is no read set, never an empty one":
    let missing = scratchRoot / "no-capture"
    createDir(missing)
    let absent = readSetFromProjection(missing)
    check not absent.captured
    check absent.paths.len == 0
    check "native_readfiles.json" in absent.source
    writeFile(missing / "native_readfiles.json", "{ not json")
    let corrupt = readSetFromProjection(missing)
    check not corrupt.captured
    # Without a read set the default mode issues and says why.
    let judged = judgeUntracked(umReads, missing, ["scratch.log"], corrupt)
    check not judged.withhold
    check "no read set was captured" in judged.note


# ---------------------------------------------------------------------------
# The `ct test run` path: `runAndAttest` captures the read set itself
# ---------------------------------------------------------------------------
#
# The leaf provider below is the one seam, as in `certificate_issuance_test`:
# a test provider is what a language adapter supplies, and this one does what
# a real adapter does — it launches its test as a process through the shared
# launcher (`process_exec.execCaptured`) and reports the outcome. The process
# is a real `cat` of the files the selector names; everything around it — the
# worker pool, the io-mon wrapping, the depfiles, the probe, the judgement —
# is the shipped code. `inproc` reads in process and launches nothing, which
# is what a provider that the monitor cannot see looks like.

const
  ReaderProviderId = "fixture-reader"

proc readerInfo(): TestProviderInfo =
  TestProviderInfo(
    id: ReaderProviderId, language: "fixture", framework: "reader",
    displayName: "Fixture provider that reads files", version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      emitsStructuredEvents: true))

proc readerRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Selector: ``<name>::<how>::<file>[,<file>…]``; ``how`` is ``cat`` (a
  ## launched process reads the files) or ``inproc`` (this process does).
  let parts = scope.selector.split("::")
  let files = parts[2].split(',')
  var ok = true
  if parts[1] == "cat":
    var argv = @["cat"]
    for file in files:
      argv.add scope.projectRoot / file
    ok = execCaptured(argv, cwd = scope.projectRoot).exitCode == 0
  else:
    for file in files:
      discard readFile(scope.projectRoot / file)
  result.value = @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
              providerId: ReaderProviderId, runId: scope.testId,
              testId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
              providerId: ReaderProviderId, runId: scope.testId,
              testId: scope.testId,
              status: some(if ok: tsPassed else: tsFailed), durationMs: 1)]

proc readerItem(name, how: string; files: openArray[string]): TestItem =
  let file = "tests/" & name & "_test.sh"
  let selector = name & "::" & how & "::" & files.join(",")
  TestItem(
    id: makeTestItemId(ReaderProviderId, "fixture", "reader", file, selector),
    providerId: ReaderProviderId, language: "fixture", framework: "reader",
    name: name, kind: tikCase, file: file,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: selector, tags: @["fixture"],
    location: LocationProvenance(source: lskPattern, detail: "fixture",
                                 confidence: lcHigh))

proc runReading(repo: string; items: seq[TestItem];
                mode = umReads): Issuance =
  ## A whole run through the exported entry point, two workers.
  var provider = TestProvider(info: readerInfo())
  provider.run = readerRun
  var registry = ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @[])])
  let response = DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion, workspaceRoot: repo,
    catalogs: @[TestCatalog(schemaVersion: TestCatalogSchemaVersion,
                            provider: readerInfo(), items: items)])
  runAndAttest(registry, response, emptyPartition(), 2,
               @[@["ct", "test", "run", "--workspace", "."]],
               IssuanceOptions(issuer: "ct-test@suite", untrackedMode: mode)).issuance

proc repoWithUntracked(name: string): string =
  result = committedRepo(name)
  writeFile(result / "fixture-input.txt", "an input the test reads\n")
  writeFile(result / "unread.txt", "never opened\n")

suite "`ct test run` captures the read set the untracked rule judges":

  test "an untracked file the run read withholds":
    ## Through the real `runAndAttest`: one unit's test process reads the
    ## untracked `fixture-input.txt`, another reads only the tracked `a.txt`,
    ## on two workers. The run's own capture names the untracked file, so
    ## the default mode withholds (Standard.md §3.2) — and names only that
    ## file, not the untracked file nobody read.
    require provisioned.len == 0
    let repo = repoWithUntracked("run-reads-untracked")
    let issuance = runReading(repo, @[
      readerItem("reads_input", "cat", ["fixture-input.txt"]),
      readerItem("reads_tracked", "cat", ["a.txt"])])
    checkpoint issuance.message
    checkpoint issuance.untracked.note
    check issuance.untracked.readSetCaptured
    check not issuance.issued
    check issuance.reason == wrUntrackedInput
    check issuance.untracked.offending == @["fixture-input.txt"]
    check "io-mon" in issuance.message
    # The tests themselves ran and passed: withholding changes no verdict.
    check issuance.vcs.untrackedPaths == @["fixture-input.txt", "unread.txt"]

  test "an untracked file the run did not read only sets untracked = true":
    ## The control: the same repository, the same untracked files, a run
    ## whose test process reads only tracked files. The read set is captured
    ## and judged — no note, nothing offending — so the certificate issues,
    ## reporting `untracked = true` because untracked files are present.
    require provisioned.len == 0
    let repo = repoWithUntracked("run-reads-tracked")
    let issuance = runReading(repo, @[
      readerItem("reads_tracked", "cat", ["a.txt"])])
    checkpoint issuance.message
    check issuance.untracked.readSetCaptured
    check issuance.issued
    check issuance.untracked.offending.len == 0
    check issuance.untracked.note.len == 0
    check issuance.certificate.vcs.untracked

  test "a unit whose test the monitor could not see leaves the read set not captured":
    ## A provider that reads in process launches nothing the monitor wraps.
    ## Its reads are unknown, so the whole read set is "not captured" — never
    ## a set that silently lacks that unit — even though the other unit's
    ## launch was captured. The default mode then issues with
    ## `untracked = true` and says why.
    require provisioned.len == 0
    let repo = repoWithUntracked("run-reads-inproc")
    let issuance = runReading(repo, @[
      readerItem("reads_input_inproc", "inproc", ["fixture-input.txt"]),
      readerItem("reads_tracked", "cat", ["a.txt"])])
    checkpoint issuance.untracked.note
    check not issuance.untracked.readSetCaptured
    check issuance.issued
    check issuance.certificate.vcs.untracked
    check NoReadSetOnRunPath in issuance.untracked.note
    check "launched no process" in issuance.untracked.note

  test "without the monitor, the read set is not captured and says why":
    require provisioned.len == 0
    let repo = repoWithUntracked("run-reads-no-monitor")
    let saved = getEnv(IoMonSnoopEnvVar)
    let savedPath = getEnv("PATH")
    putEnv(IoMonSnoopEnvVar, repo / "no-such-io-mon")
    # `io-mon` may also be on PATH in a dev shell; hide it for this case.
    var path: seq[string]
    for dir in savedPath.split(PathSep):
      if not fileExists(dir / IoMonSnoopBinaryName):
        path.add dir
    putEnv("PATH", path.join($PathSep))
    let issuance = runReading(repo, @[
      readerItem("reads_input", "cat", ["fixture-input.txt"])])
    putEnv(IoMonSnoopEnvVar, saved)
    putEnv("PATH", savedPath)
    checkpoint issuance.untracked.note
    check not issuance.untracked.readSetCaptured
    check issuance.issued
    check "io-mon monitor is not available" in issuance.untracked.note

  test "a shim override naming no file is no read set, never a failed run":
    ## io-mon's shim discovery refuses a `$REPRO_MONITOR_SHIM_LIB` that names
    ## no file (it raises rather than fall through to another shim). The run
    ## must neither crash nor capture with some other shim: the read set is
    ## "not captured", with the reason, and the certificate issues with
    ## `untracked = true`. Before this was handled the exception escaped
    ## `runAndAttest` and `ct test run` died.
    require provisioned.len == 0
    let repo = repoWithUntracked("run-reads-bad-shim")
    let saved = getEnv(IoMonShimEnvVar)
    putEnv(IoMonShimEnvVar, repo / "no-such-shim.so")
    var issuance: Issuance
    var raised = ""
    try:
      issuance = runReading(repo, @[
        readerItem("reads_input", "cat", ["fixture-input.txt"])])
    except CatchableError as err:
      raised = err.msg
    putEnv(IoMonShimEnvVar, saved)
    checkpoint raised
    checkpoint issuance.untracked.note
    check raised.len == 0
    check not issuance.untracked.readSetCaptured
    check issuance.issued
    check issuance.certificate.vcs.untracked
    check "shim could not be located" in issuance.untracked.note

  test "strict mode and a run with no untracked file start no capture":
    ## A capture only where it can change the outcome: strict mode needs no
    ## read set, and with no untracked file nothing could be implicated.
    require provisioned.len == 0
    let clean = committedRepo("run-reads-clean")
    let issuance = runReading(clean, @[
      readerItem("reads_tracked", "cat", ["a.txt"])])
    check issuance.issued
    check not issuance.untracked.readSetCaptured
    check not issuance.certificate.vcs.untracked
    let repo = repoWithUntracked("run-reads-strict")
    let strict = runReading(repo, @[
      readerItem("reads_tracked", "cat", ["a.txt"])], umStrict)
    check not strict.issued
    check not strict.untracked.readSetCaptured

# Module level, not an exit hook: `scratchRoot` is a module-level `let`.
try: removeDir(scratchRoot)
except CatchableError: discard
