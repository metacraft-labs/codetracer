## test_ct_host_refuses_an_unreadable_container_by_name.nim
##
## `ct host --trace-path` given a CTFS container this build does not read — a
## container version it refuses, or a container that opens but whose `meta.dat`
## is refused or absent — exits non-zero with ONE `ct host: error:` line that
## carries the reader's refusal verbatim, and does not crash with a Nim stack
## trace.
##
## ## Why the claim matters
##
## `codetracer-trace-format-spec` `ctfs-container.md` says "A reader must name
## the field it is refusing on". The import reader (`openCtfs` in
## `src/ct/trace/ctfs_sources.nim`) does name it — *"CTFS container version 3
## is not readable: this reader reads versions 5 and 6. Re-record the trace"* —
## but `materializeCtfsSources` used to swallow that into `false`, and its two
## `ct host` callers then either said nothing (`importCtFile`) or carried on into
## `importTrace`, whose own `openCtfs` raised again with nobody to catch it
## (`importTraceFolder`): the user got an `Unhandled ...` stack trace
## (codetracer-pm issue
## `2026-10-04-ct-importer-turns-a-container-refusal-into-false.md`). The
## reason was on screen only by accident, as the last line of a crash.
##
## The same crash had a second route: a container that OPENS, so the
## materialiser has nothing to refuse, but whose `meta.dat` `readCtfsMetaDat`
## refuses (a schema version other than 7) or cannot find. `importTrace` raised
## that from the same two importers, again uncaught.
##
## ## What runs
##
## The real `ct host` (default `src/build-debug/bin/ct`, or `CODETRACER_CT_BIN`)
## with a scratch `CODETRACER_HOME` and `TMPDIR`. It refuses before it starts
## the node index, so nothing else is needed and nothing is left running; a run
## that does not exit within `ExitTimeoutMs` is killed and fails.
##
## No mocks. The containers are hand-built: the CTFS magic and a version byte
## are all `openCtfs` reads before it refuses, a one-member version 5 container
## is all `readCtfsMetaDat` reads before it refuses `meta.dat`'s version, and
## no correct writer produces either. `codetracer-example-recordings`' `mcr/android-arm64/
## trace-portable.ct` is such a container in the wild (version 3) and fails the
## same way, but it is due to be re-recorded, so it is not this suite's fixture.
##
## ## The arms
##
## - A trace FOLDER holding a version 4 `trace.ct` (`importTraceFolder`): red on
##   the unfixed `ct host`, which crashes with an unhandled exception.
## - A bare version 3 `.ct` FILE (`importCtFile`): the other caller of the
##   materialiser, refused the same way.
## - A trace folder holding a version 5 container whose `meta.dat` is schema
##   version 6 (`importTraceFolder` -> `importTrace`): red on a `ct host` that
##   handles only the materialiser's refusal.
## - A bare version 5 `.ct` file with no `meta.dat` at all (`importCtFile` ->
##   `importTrace`): the same route, with the reader's "not found" as reason.
## - A `--manifest` whose `single_ctfs` source names a version 3 container
##   (`importLocalManifest` -> `importCtFile`): the manifest path keeps its own
##   handler, so the refusal arrives on its `failed to load local manifest:`
##   line rather than the `--trace-path` one.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`), the lane of the
## real `ct host` binary; see its entry in `ci/lib/test-lane-files.sh`.

import std/[json, os, osproc, strtabs, strutils, times, unittest]

const
  ExitTimeoutMs = 120_000
    ## Generous: the first run of a debug `ct` on a cold cache is slow, and
    ## the refusal comes before anything is served, so a healthy run exits
    ## in well under a second.

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let
  root = repoRoot()
  ctBinary = getEnv("CODETRACER_CT_BIN", root / "src" / "build-debug" / "bin" / "ct")

proc containerRefusal(version: int): string =
  ## `openCtfs`'s message for `version`, word for word — the same sentence
  ## `src/tests/gui/lib/ctfs-container.ts` (`ctfsVersionRefusal`) matches.
  "CTFS container version " & $version & " is not readable: this reader " &
    "reads versions 5 and 6. Re-record the trace"

proc metaDatRefusal(version: int): string =
  ## `parseCtfsMetaDat`'s message for a schema version other than 7 and above
  ## the superseded-packing range, word for word.
  "meta.dat: version " & $version & " is not readable: this reader reads " &
    "version 7 only. Re-record the trace"

const MissingMetaDat = "CTFS file not found: meta.dat"
  ## `findEntry`'s message for a container with no `meta.dat` member.

proc writeContainerHeader(path: string; version: int) =
  ## One 1024-byte block 0: the CTFS magic (`ctfs-container.md` §1), the
  ## container version at offset 5, block size 1024 at offset 8, no entries.
  var data = newString(1024)
  for i in 0 ..< data.len: data[i] = '\0'
  for i, b in [0xC0, 0xDE, 0x72, 0xAC, 0xE2]:
    data[i] = char(b)
  data[5] = char(version)
  data[9] = char(4)  # 1024, little-endian
  createDir(path.parentDir)
  writeFile(path, data)

proc base40(name: string): uint64 =
  ## A member name as `FileEntry.Name` stores it (`ctfs-container.md` §1):
  ## base-40 digits, least significant first.
  const Alphabet = "\0" & "0123456789abcdefghijklmnopqrstuvwxyz./-"
  var multiplier = 1'u64
  for c in name:
    let index = Alphabet.find(c)
    doAssert index > 0, "not a base-40 character: " & c
    result += uint64(index) * multiplier
    multiplier *= 40

proc writeContainerWithMetaDat(path, metaDat: string) =
  ## A version 5 container with one member, `meta.dat`, stored as a single
  ## direct block (`MapBlock` tagged with bit 63, `ctfs-container.md` §2) in
  ## block 1. Its bytes are whatever the caller passes.
  doAssert metaDat.len <= 1024
  writeContainerHeader(path, 5)
  var data = readFile(path)
  data.setLen(2048)
  for i in 1024 ..< 2048: data[i] = '\0'
  for i, c in metaDat: data[1024 + i] = c
  proc putU64(data: var string; at: int; value: uint64) =
    for i in 0 ..< 8:
      data[at + i] = char((value shr (8 * i)) and 0xff)
  # Entry 0 starts right after the 16-byte header.
  data.putU64(16, uint64(metaDat.len))
  data.putU64(24, (1'u64 shl 63) or 1'u64)
  data.putU64(32, base40("meta.dat"))
  writeFile(path, data)

proc metaDatOfVersion(version: int): string =
  ## A `meta.dat` header stamped with `version`: the magic and the version are
  ## all the reader looks at before it refuses (`internal-files.md`
  ## §"Metadata (meta.dat)"); the rest is zero.
  result = "CTMD" & char(version) & "\0"
  result.add repeat('\0', 6)

proc runHostWith(scratch, argument: string): tuple[output: string, exitCode: int] =
  ## `ct host <argument>` to completion, stdout and stderr together (the
  ## refusal must reach the user on either). Killed and reported as exit -1
  ## if it has not exited within `ExitTimeoutMs`.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["CODETRACER_HOME"] = scratch / "ct-home"
  env["TMPDIR"] = scratch / "tmp"
  env["CODETRACER_IN_UI_TEST"] = "1"
  createDir(scratch / "tmp")
  # The output goes to a file and the exit is polled, rather than reading a
  # pipe: a child that printed nothing and never exited would block a pipe
  # read past any timeout.
  let logPath = scratch / "ct-host.log"
  env["CT_TEST_LOG"] = logPath
  let wrapper = "exec >\"$CT_TEST_LOG\" 2>&1; exec \"$@\""
  # The shell from PATH, not a fixed path: NixOS has no `/bin/bash`, and the
  # wrapper is plain POSIX `sh`.
  let shell = findExe("sh")
  doAssert shell.len > 0, "no `sh` on PATH to start `ct host` through"
  let p = startProcess(shell, workingDir = root, env = env,
    args = @["-c", wrapper, "sh", ctBinary, "host", argument],
    options = {})
  let started = epochTime()
  var exitCode = -1
  while true:
    exitCode = p.peekExitCode()
    if exitCode != -1:
      break
    if (epochTime() - started) * 1000 > ExitTimeoutMs:
      p.kill()
      discard p.waitForExit()
      exitCode = -1
      break
    sleep(100)
  p.close()
  result = ((try: readFile(logPath) except IOError: ""), exitCode)

proc runHost(scratch, tracePath: string): tuple[output: string, exitCode: int] =
  ## `ct host --trace-path=<tracePath>`, as `runHostWith` runs it.
  runHostWith(scratch, "--trace-path=" & tracePath)

template checkRefusedByName(run: tuple[output: string, exitCode: int];
                            reason: string;
                            marker = "ct host: error: cannot import ") =
  # Bound once: a template parameter is re-evaluated at every use, and each
  # evaluation of `runHost(...)` would start `ct host` again.
  let r = run
  checkpoint("ct host output:\n" & r.output)
  check r.exitCode != 0
  check r.exitCode != -1  # it exited by itself
  check r.output.contains(marker)
  check r.output.contains(reason)
  # The refusal and the error marker are on the same line: the reason is the
  # error, not a stray line beside some other failure.
  var onOneLine = false
  for line in r.output.splitLines():
    if line.startsWith(marker) and line.contains(reason):
      onOneLine = true
  check onOneLine
  # Not a crash.
  check not r.output.contains("Unhandled")
  check not r.output.contains("Error: unhandled exception")
  check not r.output.contains("Traceback")
  check not r.output.contains("imported as trace id")

suite "ct host refuses a container it cannot read, by name":
  setup:
    let scratch = getTempDir() / ("ct-host-refusal-" & $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
  teardown:
    removeDir(scratch)

  test "the binary under test exists":
    checkpoint("CODETRACER_CT_BIN / src/build-debug/bin/ct: " & ctBinary)
    check fileExists(ctBinary)

  test "a trace folder holding a version 4 container":
    let folder = scratch / "folder"
    writeContainerHeader(folder / "trace.ct", 4)
    checkRefusedByName(runHost(scratch, folder), containerRefusal(4))

  test "a bare version 3 .ct file":
    let ct = scratch / "file" / "recording.ct"
    writeContainerHeader(ct, 3)
    checkRefusedByName(runHost(scratch, ct), containerRefusal(3))

  test "a trace folder whose container opens but whose meta.dat is version 6":
    let folder = scratch / "metadat-folder"
    writeContainerWithMetaDat(folder / "trace.ct", metaDatOfVersion(6))
    checkRefusedByName(runHost(scratch, folder), metaDatRefusal(6))

  test "a bare .ct file whose container opens but has no meta.dat":
    let ct = scratch / "metadat-file" / "recording.ct"
    writeContainerHeader(ct, 5)
    checkRefusedByName(runHost(scratch, ct), MissingMetaDat)

  test "a manifest whose single_ctfs source is a version 3 container":
    ## `importCtFile` is reached from a manifest as well. There the refusal
    ## is the manifest handler's to report, and it must still carry the
    ## reader's reason rather than end in a crash or a `--trace-path` line
    ## naming a file the user never passed.
    let ct = scratch / "manifest" / "recording.ct"
    writeContainerHeader(ct, 3)
    let manifest = scratch / "manifest" / "manifest.json"
    writeFile(manifest, $(%*{
      "schema": "codetracer.trace-storage.v1",
      "source": {"kind": "single_ctfs", "file": {"path": ct}}}))
    let run = runHostWith(scratch, "--manifest=" & manifest)
    checkRefusedByName(run, containerRefusal(3),
      marker = "ct host: error: failed to load local manifest: ")
    check not run.output.contains("cannot import")
