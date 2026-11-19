## record_nim_rr_backend_e2e_test.nim
##
## `ct record --backend=rr main.nim` must make an rr recording, not an MCR one.
##
## ## The defect this guards
##
## codetracer-pm issue
## `2026-11-17-ct-record-backend-rr-made-an-mcr-recording.md`.  `ct record`
## honours `--backend rr` for a compiled `.nim` (`honouringBackend`,
## `src/ct/trace/recorder_dispatch.nim`): it builds the program natively and
## hands it to `db-backend-record` with `--trace-kind rr`.  `db-backend-record` then made the recorder selector again
## from recognition alone, got `(Nim, native, MCR)`, and recorded with `ct-mcr`:
## the user asked for rr, got MCR, and nothing said so.  The recording replayed
## (MCR opens a Nim program fine), so every check that only opens it stayed
## green, and the scenarios that asked for an rr recording of a Nim program ran
## on MCR ones.  `record_dispatch_test.nim` asserts `honouringBackend` itself;
## it cannot see a caller that never applies it, which is why this row records
## through the real chain.
##
## It asserts that the recording folder has rr's trace directory (`rr/`) and the
## `trace_db_metadata.json` `ct-native-replay record` writes, neither of which an
## MCR recording has (both carry a `trace.ct`, so that file tells them apart
## not at all), and that the build's nimcache is kept beside it, where the
## replay finds the generated C the program's DWARF names.
##
## Mocking justification (workspace policy on mock objects): none.  The real
## `ct`, `db-backend-record`, the Nim compiler, `ct-native-replay` and `rr`.
##
## Gating: rr needs hardware performance counters.  Where `rr` cannot record on
## this host, or `ct record` reports a recorder or the Nim compiler missing, the
## row prints the workspace's `MISSING-RECORDER SKIP:` marker and the reason, as
## `record_portable_rr_e2e_test.nim` does, rather than pass.  Hybrid CPUs: the
## probe and the recording run on the performance cores where the host has
## them (see `record_portable_rr_e2e_test.nim`).
##
## Compile and run (inside the dev shell):
##   nim c -r src/tests/cli/record_nim_rr_backend_e2e_test.nim

import std/[os, osproc, strutils, unittest]

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len == 0:
    let buildDir = getEnv("CODETRACER_BUILD_DIR",
      currentSourcePath.parentDir.parentDir.parentDir / "build-debug")
    result = buildDir / "bin" / "ct"

proc recorderMissing(output: string): bool =
  ## `requireRecorder`'s wording and the Nim compiler check.
  "was not found" in output or "Nim compiler not found" in output

suite "ct record --backend=rr of a .nim":
  test "makes an rr recording, not an MCR one":
    let ct = ctBinary()
    let rr = findExe("rr")
    check fileExists(ct)
    if rr.len == 0 or findExe("ct-native-replay").len == 0:
      echo "MISSING-RECORDER SKIP: rr — rr or ct-native-replay is not on PATH"
    else:
      let work = getTempDir() / ("ct_nim_rr_backend_" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      var pin = ""
      try:
        let cores = readFile("/sys/devices/cpu_core/cpus").strip()
        if cores.len > 0 and findExe("taskset").len > 0:
          pin = "taskset -c " & cores & " "
      except IOError, OSError: discard
      # `true` from PATH, by the name it was found under: there is no
      # `/bin/true` on NixOS, and there `true` is a link to the coreutils
      # multi-call binary, which run by its own name does not know it is
      # `true`. A probe that cannot run its program would read as "rr
      # cannot record here".
      let probe = execCmdEx(pin & quoteShell(rr) & " record -n -o " &
        quoteShell(work / "probe") & " " &
        quoteShell(findExe("true", followSymlinks = false)) & " 2>&1")
      if probe.exitCode != 0:
        echo "MISSING-RECORDER SKIP: rr — rr cannot record on this host:\n" &
             probe.output
      else:
        let program = work / "main.nim"
        writeFile(program, "proc main() =\n  echo \"nim-rr-backend\"\n\nmain()\n")
        let outDir = work / "out"
        let (recOut, recRc) = execCmdEx("cd " & quoteShell(work) & " && " &
          pin & "timeout 600 " & quoteShell(ct) & " record --backend=rr -o " &
          quoteShell(outDir) & " " & quoteShell(program) & " 2>&1")
        checkpoint(recOut)
        if recorderMissing(recOut):
          echo "MISSING-RECORDER SKIP: " & recOut.strip.splitLines[^1]
        else:
          check recRc == 0
          var entries: seq[string]
          for _, f in walkDir(outDir, relative = true):
            entries.add f
          checkpoint("recording folder: " & $entries)
          check dirExists(outDir / "rr")
          check fileExists(outDir / "trace_db_metadata.json")
          check fileExists(outDir / "nimcache" / "@mmain.nim.c")
      removeDir(work)
