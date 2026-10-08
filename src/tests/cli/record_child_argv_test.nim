## record_child_argv_test.nim
##
## `ct record prog -- a b` records `prog` with the arguments `a b`, and
## `ct record -- prog a b` does the same -- codetracer-specs
## `CLI/ct/record.md`, "Program arguments".  Until 2026-10-01 the first form
## took `a` as the program and dropped `prog`.
##
## Mocking justification (workspace policy on mock objects): none.  The pure
## resolver is called with what the parser hands it; the end-to-end half --
## the real `ct` binary on both forms -- is the last test below, and it runs
## the shipped `ct` with only the recorder replaced (see
## `recorder_env_e2e_test.nim` for why that replacement is the honest one).
##
## Compile and run:
##   nim c -r src/tests/cli/record_child_argv_test.nim

import std/[os, osproc, strutils, unittest]
import ../../ct/trace/record_child_argv

const P = "\0placeholder"

suite "ct record: the program and its arguments around --":
  test "program after --":
    let r = resolveRecordChild(P, @[], @["prog", "a", "--b"], P)
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a", "--b"]

  test "program before --: every word after it is an argument":
    let r = resolveRecordChild("prog", @[P], @["a", "--b"], P)
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a", "--b"]

  test "words between the program and -- stay its first arguments":
    let r = resolveRecordChild("prog", @["x", P], @["a"], P)
    check r.program == "prog"
    check r.args == @["x", "a"]

  test "program before an empty --":
    let r = resolveRecordChild("prog", @[P], @[], P)
    check r.error == ""
    check r.program == "prog"
    check r.args.len == 0

  test "no program anywhere is refused by name":
    let r = resolveRecordChild(P, @[], @[], P)
    check "names no program" in r.error

  test "the real ct: both forms hand the recorder the same program and arguments":
    let ct = getEnv("CODETRACER_E2E_CT_PATH",
      currentSourcePath.parentDir.parentDir.parentDir / "build-debug" /
      "bin" / "ct")
    check fileExists(ct)
    check findExe("ct-native-replay").len > 0
    let prog = findExe("true")
    if fileExists(ct) and findExe("ct-native-replay").len > 0:
      let work = getTempDir() / ("ct_record_child_argv_" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      let stub = work / "stub.sh"
      writeFile(stub, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$SAW\"\nexit 1\n")
      setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
      proc afterDashDash(line: string, tag: string): seq[string] =
        let saw = work / tag
        discard execCmdEx("cd " & quoteShell(work) & " && SAW=" & quoteShell(saw) &
          " CODETRACER_CT_MCR_CMD=" & quoteShell(stub) & " timeout 300 " &
          quoteShell(ct) & " record -o " & quoteShell(work / ("out-" & tag)) &
          " --backend=mcr " & line & " 2>&1")
        if not fileExists(saw): return @["<recorder not invoked>"]
        let words = readFile(saw).splitLines()
        let dd = words.find("--")
        if dd < 0: return @["<no -- in the recorder argv>"]
        result = words[dd + 1 .. ^1]
        while result.len > 0 and result[^1] == "": result.setLen(result.len - 1)
      let before = afterDashDash(quoteShell(prog) & " -- alpha --beta", "before")
      let after = afterDashDash("-- " & quoteShell(prog) & " alpha --beta", "after")
      checkpoint("program before --: " & $before)
      checkpoint("program after --: " & $after)
      check before.len == 3 and before[1 .. 2] == @["alpha", "--beta"]
      check after.len == 3 and after[1 .. 2] == @["alpha", "--beta"]
      check before == after
      removeDir(work)
