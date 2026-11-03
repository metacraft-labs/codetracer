## test_ct_host_imports_an_rr_recording_with_its_rr_trace.nim
##
## `ct host --trace-path <folder>` given an rr recording's folder — the folder
## `ct-native-replay record` writes: the rr trace in `rr/` beside a
## metadata-only `trace.ct` — imports the recording WITH its rr trace, so the
## replay of the imported copy is the rr one.
##
## ## Why the claim matters
##
## The importer copied only the CTFS container into the recording store
## (`storage_and_import.importTrace`, the CTFS shape). The copy then held a
## `trace.ct` and no `rr/`; the replay server, which prefers `rr/` when a
## folder has one (`dap_server.rs::resolve_replay_trace_path`), found none,
## handed the container to the worker, and the worker read it as an MCR
## recording and refused: "ct-mcr binary not found". So the desktop opened an
## imported rr recording as an empty session (codetracer-pm issue
## `2026-11-01-importing-an-rr-recording-folder-drops-its-rr-trace.md`).
##
## ## What runs
##
## The real `ct host` (default `src/build-debug/bin/ct`, or `CODETRACER_CT_BIN`)
## with a scratch `CODETRACER_HOME` and `TMPDIR`, on a real rr recording of the
## shared native fixture `codetracer-native-test-programs/c/sudoku_solver`
## (`frontend/tui/tests/fixtures/native_recording`). The suite reads what the
## import wrote into the recording store and stops `ct host` once it has; it
## does not need the hosted session.
##
## Without `ct-native-replay` or `rr` the case skips, printing
## `MISSING-PREREQ SKIP:` with what is missing.
##
## No mocks.
##
## Lane: `ct-host-admission`, the lane of the real `ct host` binary.

import std/[algorithm, os, osproc, strtabs, strutils, times, unittest]

import ../../frontend/tui/tests/fixtures/native_recording

const ImportTimeoutMs = 120_000

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not (dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile")):
    let parent = dir.parentDir
    doAssert parent != dir, "no codetracer checkout above " & currentSourcePath()
    dir = parent
  dir

let root = repoRoot()
let ctBinary = getEnv("CODETRACER_CT_BIN", root / "src" / "build-debug" / "bin" / "ct")

proc importedId(output: string): string =
  ## The recording id `ct host` prints once the import is done, "" before.
  const marker = "imported as trace id "
  let at = output.find(marker)
  if at < 0: return ""
  output[at + marker.len .. ^1].splitLines()[0].strip()

proc filesUnder(dir: string): seq[string] =
  for path in walkDirRec(dir, relative = true):
    result.add path
  result.sort()

suite "ct host imports an rr recording with its rr trace":

  test "the recording store's copy holds the rr trace":
    let rec = nativeRecording()
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skip()
    else:
      check fileExists(ctBinary)
      let source = rec.tracePath
      require dirExists(source / "rr")
      require fileExists(source / "trace.ct")
      let scratch = getTempDir() / "ct-host-rr-import-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch / "tmp")
      defer: removeDir(scratch)
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
      env["CODETRACER_HOME"] = scratch / "ct-home"
      env["TMPDIR"] = scratch / "tmp"
      env["CODETRACER_IN_UI_TEST"] = "1"
      let logPath = scratch / "ct-host.log"
      env["CT_TEST_LOG"] = logPath
      let shell = findExe("sh")
      doAssert shell.len > 0, "no `sh` on PATH to start `ct host` through"
      let p = startProcess(shell, workingDir = root, env = env,
        args = @["-c", "exec >\"$CT_TEST_LOG\" 2>&1; exec \"$@\"", "sh",
                 ctBinary, "host", "--trace-path", source, "0", "--port=0",
                 "--idle-timeout=1ms", "--backend-socket-port=0",
                 "--frontend-socket=0"],
        options = {})
      # The import is done when the id is printed; the host that follows is
      # not this suite's subject, so it is stopped then.
      let started = epochTime()
      var output = ""
      while true:
        output = try: readFile(logPath) except IOError: ""
        if output.importedId.len > 0 or p.peekExitCode() != -1 or
           (epochTime() - started) * 1000 > ImportTimeoutMs:
          break
        sleep(200)
      if p.peekExitCode() == -1:
        p.terminate()
        discard p.waitForExit()
      p.close()
      checkpoint("ct host output:\n" & output)
      let id = output.importedId
      check id.len == 36
      let imported = scratch / "ct-home" / "data" / id
      check fileExists(imported / "trace.ct")
      # THE CLAIM: the rr trace came with it, file for file.
      check dirExists(imported / "rr")
      if dirExists(imported / "rr"):
        check filesUnder(imported / "rr") == filesUnder(source / "rr")
