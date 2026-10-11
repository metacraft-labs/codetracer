## The default untracked mode's read-set check, over a read set a REAL
## capture produced (CTC-3g).
##
## In the default mode (`[certificate] untracked = "reads"`) a certificate is
## withheld with ``wrUntrackedInput`` when the run's captured read set names
## an untracked file. `ct test run` captures no read set today, so the check
## is dormant on that path (``certificate_issuance_test.nim`` covers what it
## does instead). What this suite establishes is that the check is right on
## the read sets that DO exist: the incremental engine's read-file capture,
## which runs a process under io-mon's interpose monitor and writes the
## ``native_readfiles.json`` projection.
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

import std/[os, osproc, streams, strtabs, strutils, unittest]

import certificate_issuance
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

# Module level, not an exit hook: `scratchRoot` is a module-level `let`.
try: removeDir(scratchRoot)
except CatchableError: discard
