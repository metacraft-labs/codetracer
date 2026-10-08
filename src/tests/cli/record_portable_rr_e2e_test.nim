## record_portable_rr_e2e_test.nim
##
## `ct record --backend=rr --portable` produces a trace that replays after the
## recorded program changes and after the trace is moved -- codetracer-specs
## `CLI/ct/record.md`, "Portable traces" (the `rr` row: `rr pack`).
##
## `ct-native-replay record` runs `rr pack` on every rr recording, which copies
## every file the trace mapped into the trace directory.  This row holds that
## promise to account: it records a program through the real `ct`, rebuilds the
## program so that it prints something else, copies the trace elsewhere, and
## requires `rr replay` of the copy to print what the ORIGINAL printed.
##
## Mocking justification (workspace policy on mock objects): none.  The real
## `ct`, `db-backend-record`, `ct-native-replay`, `rr` and a C compiler.
##
## Gating: rr needs hardware performance counters.  Where `rr` cannot record
## on this host the row prints the workspace's `MISSING-RECORDER SKIP:` marker
## and the reason, as `record_dispatch_e2e_test.nim` does, rather than pass.
##
## Hybrid CPUs: rr counts branches only on performance cores (on an Intel
## hybrid part the efficiency cores have a different PMU, and rr reports "Got 0
## branch events").  So the probe and the recording run under `taskset` on the
## performance-core list `/sys/devices/cpu_core/cpus` when the host has one;
## measured 2026-10-01 on an i9-13900K, unpinned runs failed 1 of 3 that way.
##
## Compile and run:
##   nim c -r src/tests/cli/record_portable_rr_e2e_test.nim

import std/[os, osproc, strutils, unittest]

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len == 0:
    result = currentSourcePath.parentDir.parentDir.parentDir / "build-debug" /
             "bin" / "ct"

suite "ct record --backend=rr --portable":
  test "the trace replays after the program changes and the trace moves":
    let ct = ctBinary()
    let rr = findExe("rr")
    let cc = findExe("cc")
    check fileExists(ct)
    check findExe("ct-native-replay").len > 0
    if rr.len == 0 or cc.len == 0:
      echo "MISSING-RECORDER SKIP: rr — rr or a C compiler is not on PATH"
    else:
      let work = getTempDir() / ("ct_portable_rr_" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      let src = work / "p.c"
      let bin = work / "p"
      proc build(text: string) =
        writeFile(src, "#include <stdio.h>\nint main(void){puts(\"" & text &
                       "\");return 0;}\n")
        let (o, rc) = execCmdEx(quoteShell(cc) & " -O1 -o " & quoteShell(bin) &
                                " " & quoteShell(src))
        check rc == 0
        if rc != 0: echo o
      # Pin to the performance cores where the host has them (see the header).
      var pin = ""
      try:
        let cores = readFile("/sys/devices/cpu_core/cpus").strip()
        if cores.len > 0 and findExe("taskset").len > 0:
          pin = "taskset -c " & cores & " "
      except IOError, OSError: discard
      build("portable-rr-original")
      let probe = execCmdEx(pin & quoteShell(rr) & " record -n -o " &
        quoteShell(work / "probe") & " " & quoteShell(bin) & " 2>&1")
      if probe.exitCode != 0:
        echo "MISSING-RECORDER SKIP: rr — rr cannot record on this host:\n" &
             probe.output
      else:
        let outDir = work / "out"
        let (recOut, recRc) = execCmdEx("cd " & quoteShell(work) & " && " &
          pin & "timeout 300 " & quoteShell(ct) &
          " record --backend=rr --portable -o " &
          quoteShell(outDir) & " " & quoteShell(bin) & " 2>&1")
        checkpoint(recOut)
        check recRc == 0
        var packed: seq[string]
        for kind, f in walkDir(outDir / "rr", relative = true):
          # `rr pack` copies (`mmap_pack_*`); a file on the trace's own
          # filesystem that rr already hard-linked at record time
          # (`mmap_hardlink_*`) is its own copy of the bytes, too.
          if f.startsWith("mmap_pack_") or f.startsWith("mmap_hardlink_"):
            packed.add f
        checkpoint("packed: " & $packed)
        check packed.len > 0
        # The program itself is not always a file in the trace directory: a
        # mapping of a file on a filesystem rr will not hard-link from (tmpfs,
        # say) has its bytes copied into the trace's data stream at record
        # time.  So the row does not look for it by name; the replay below,
        # after the program is rebuilt, is what proves its bytes were kept.
        # Change what the trace mapped, then move the trace.
        build("portable-rr-CHANGED")
        let moved = work / "moved"
        createDir(moved)
        copyDir(outDir, moved / "out")
        let (rep, _) = execCmdEx(pin & "timeout 120 " & quoteShell(rr) &
          " replay -a " & quoteShell(moved / "out" / "rr") & " 2>&1")
        checkpoint(rep)
        check "portable-rr-original" in rep
        check "portable-rr-CHANGED" notin rep
      removeDir(work)
