## test_ct_host_imports_a_recordings_symbol_index.nim
##
## `ct host --trace-path <folder>` imports a recording WITH the symbol index
## `ct record` wrote beside it (`symbols.json`), so the command palette's
## `:sym` finds the recording's functions in the imported copy.
##
## ## Why the claim matters
##
## `ct record` writes `symbols.json` (ctags over the recorded sources,
## `db_backend_record.recordSymbols`) into the recording folder, and the
## desktop reads it from the folder of the recording it opens
## (`index/traces.loadSymbols`). The importer copied the container, `rr/`,
## `files/` and `paths.json` into the recording store and left the index
## behind, so `:sym main` answered "No matching result found." in every
## recording the desktop opened through `ct host --trace-path`.
##
## ## What runs
##
## The real `ct host` (default `src/build-debug/bin/ct`, or `CODETRACER_CT_BIN`)
## with a scratch `CODETRACER_HOME` and `TMPDIR`, on a copy of the shared
## native fixture recording (`frontend/tui/tests/fixtures/native_recording`)
## carrying a symbol index in the shape `recordSymbols` writes. The suite
## reads what the import wrote into the recording store and stops `ct host`
## once it has.
##
## Without `ct-native-replay` or `rr` the case skips, printing
## `MISSING-PREREQ SKIP:` with what is missing.
##
## No mocks.
##
## Lane: `ct-host-admission`, the lane of the real `ct host` binary.

import std/[os, osproc, strtabs, strutils, times, unittest]

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

suite "ct host imports a recording's symbol index":

  test "the recording store's copy holds symbols.json, byte for byte":
    let rec = nativeRecording()
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skip()
    else:
      check fileExists(ctBinary)
      let scratch = getTempDir() / "ct-host-symbols-import-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch / "tmp")
      defer: removeDir(scratch)
      # A copy of the recording, with the index `ct record` writes beside it.
      let source = scratch / "recording"
      copyDir(rec.tracePath, source)
      const index = """[{"name":"main","path":"/src/main.c","line":3,"kind":"function"}]"""
      writeFile(source / "symbols.json", index)
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
      # THE CLAIM: the symbol index came with it.
      check fileExists(imported / "symbols.json")
      if fileExists(imported / "symbols.json"):
        check readFile(imported / "symbols.json") == index
