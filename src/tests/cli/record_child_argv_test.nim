## record_child_argv_test.nim
##
## `ct record prog -- a b` records `prog` with the arguments `a b`, and
## `ct record -- prog a b` does the same -- codetracer-pm
## `spec/CLI/ct/record.md`, "Program arguments".  Until 2026-10-01 the first
## form took `a` as the program and dropped `prog`.
##
## A value-taking option written just before `--` is refused by name, and the
## refusal holds only what the user wrote (same section).  Until 2026-11-15
## that option took ct's internal placeholder as its value: `ct record --lang
## -- prog` lost `prog` and said "The required option 'recordProgram' was not
## specified", and `ct record --store-trace-folder-for-pid -- prog` printed
## `\0ct-record-child-program`, NUL bytes included
## (reprobuild-pm issues/2026-11-15-ct-record-separator-placeholder-with-a-nul-byte-leaks-into-error-messages.md).
##
## A shell-completion request (`COMP_LINE` set) on such a line is answered and
## ends with exit 0, before anything reads the configuration (codetracer-pm
## `spec/CLI/ct/README.md`, "Shell completion (`COMP_LINE`)").  Until
## 2026-11-15 the loader answered it and returned a configuration it had not
## parsed, and the split read the `record` fields of it: `ct record -- prog`
## died with a FieldDefect after printing the candidates
## (codetracer-pm issues/2026-11-15-ct-record-separator-with-comp-line-set-crashes-with-a-fielddefect.md).
##
## Mocking justification (workspace policy on mock objects): none.  Every
## parse below is ct's own `CodetracerConf.load`, the parser the binary runs;
## the end-to-end half -- the real `ct` binary -- is the last two tests, and
## runs the shipped `ct` with only the recorder replaced (see
## `recorder_env_e2e_test.nim` for why that replacement is the honest one).
##
## Compile and run:
##   nim c -r src/tests/cli/record_child_argv_test.nim

import std/[os, osproc, sequtils, strutils, unittest]
import confutils
import ../../ct/codetracerconf
import ../../ct/trace/record_child_argv

proc probe(line: seq[string]): RecordProbe =
  ## ct's parser, as `codetracer.nim` probes it: no output, no exit.
  try:
    let conf = CodetracerConf.load(cmdLine = line, printUsage = false,
                                   quitOnFailure = false)
    RecordProbe(parsed: true, args: conf.recordArgs)
  except ConfigurationError:
    RecordProbe(parsed: false)

proc split(ownHalf, afterSeparator: seq[string]): RecordChild =
  ## The whole `ct record ... -- ...` path short of recording: the
  ## missing-value check, then the real parse of the slotted line.
  let missing = recordOptionMissingValue(ownHalf, probe)
  if missing.len > 0:
    return RecordChild(error: recordMissingValueError(missing))
  let conf = CodetracerConf.load(cmdLine = recordParserLine(ownHalf),
                                 printUsage = false, quitOnFailure = false)
  resolveRecordChild(conf.recordProgram, conf.recordArgs, afterSeparator)

proc clean(text: string): bool =
  ## Nothing the user did not write leaks: no control bytes, no slot.
  for c in text:
    if c < ' ' and c != '\n' and c != '\t': return false
  RecordProgramSlot notin text and RecordOwnArgsEnd notin text and
    "ct-record" notin text and "recordProgram" notin text

suite "ct record: the program and its arguments around --":
  test "program after --":
    let r = split(@["record"], @["prog", "a", "--b"])
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a", "--b"]

  test "program before --: every word after it is an argument":
    let r = split(@["record", "prog"], @["a", "--b"])
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a", "--b"]

  test "words between the program and -- stay its first arguments":
    let r = split(@["record", "prog", "x"], @["a"])
    check r.program == "prog"
    check r.args == @["x", "a"]

  test "program before an empty --":
    let r = split(@["record", "prog"], @[])
    check r.error == ""
    check r.program == "prog"
    check r.args.len == 0

  test "no program anywhere is refused by name":
    let r = split(@["record"], @[])
    check "names no program" in r.error
    check clean(r.error)

  test "an option's value before -- is not the program":
    let r = split(@["record", "-o", "out", "--lang", "python"], @["prog", "a"])
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a"]
    let s = split(@["record", "-o", "out", "prog", "x"], @["a"])
    check s.program == "prog"
    check s.args == @["x", "a"]

  test "a switch right before -- takes no value":
    let r = split(@["record", "--use-interpose"], @["prog", "a"])
    check r.error == ""
    check r.program == "prog"
    check r.args == @["a"]

  test "a string option with no value before -- is refused by name":
    for opt in ["--lang", "--backend", "--with-diff", "-o", "--output-folder"]:
      let r = split(@["record", opt], @["prog"])
      checkpoint(opt & ": " & r.error)
      check ("`" & opt & "` needs a value") in r.error
      check clean(r.error)
      check r.program == ""

  test "an integer option with no value before -- is refused by name":
    let r = split(@["record", "--store-trace-folder-for-pid"], @["prog"])
    checkpoint(r.error)
    check "`--store-trace-folder-for-pid` needs a value" in r.error
    check clean(r.error)

  test "an empty `--opt=` before -- names the option, not the `=`":
    let r = split(@["record", "--lang="], @["prog"])
    check "`--lang` needs a value" in r.error
    check clean(r.error)

  test "the option is found after the program too":
    let r = split(@["record", "prog", "--lang"], @["a"])
    check "`--lang` needs a value" in r.error

  test "the option waiting for a value is named, not a switch after it":
    # The pinned parser keeps `--lang` waiting across `--upload`, a switch;
    # the refusal must name `--lang`, not the last word.
    let r = split(@["record", "--lang", "--upload"], @["prog"])
    check "`--lang` needs a value" in r.error
    check "`--upload`" notin r.error
    let s = split(@["record", "--upload", "--use-interpose", "--lang"], @["prog"])
    check "`--lang` needs a value" in s.error
    let t = split(@["record", "-o", "out", "--upload"], @["prog"])
    check t.error == ""
    check t.program == "prog"

  test "a line with an error of its own is left to the real parse":
    check recordOptionMissingValue(@["record", "--no-such-flag"], probe) == ""
    check recordOptionMissingValue(@["record"], probe) == ""

  test "the real ct: an option missing its value before -- is refused by name, with no control bytes":
    let ct = getEnv("CODETRACER_E2E_CT_PATH",
      currentSourcePath.parentDir.parentDir.parentDir / "build-debug" /
      "bin" / "ct")
    check fileExists(ct)
    if fileExists(ct):
      let work = getTempDir() / ("ct_record_missing_value_" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      let stub = work / "stub.sh"
      let saw = work / "saw"
      writeFile(stub, "#!/bin/sh\ntouch \"$SAW\"\nexit 1\n")
      setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
      for opt in ["--store-trace-folder-for-pid", "--lang"]:
        let errFile = work / "err"
        let (_, code) = execCmdEx("cd " & quoteShell(work) & " && SAW=" &
          quoteShell(saw) & " CODETRACER_CT_MCR_CMD=" & quoteShell(stub) &
          " timeout 300 " & quoteShell(ct) & " record --backend=mcr " & opt &
          " -- " & quoteShell(findExe("true")) & " 2>" & quoteShell(errFile))
        let err = if fileExists(errFile): readFile(errFile) else: ""
        checkpoint(opt & ": exit " & $code & ", stderr " & err.escape)
        check code == 1
        check ("`" & opt & "` needs a value") in err
        check '\0' notin err
        check clean(err)
        check not fileExists(saw)
      removeDir(work)

  test "the real ct: a completion request on a `record ... --` line answers once and exits 0":
    # The argv is the line being completed, as bash's `complete -C` hands it
    # over; `COMP_LINE` / `COMP_POINT` are what the loader completes.  Each
    # line reaches a different reader of the unparsed configuration: the
    # split's own resolution (`recordProgram`, program after or before `--`)
    # and the missing-value probe (`recordArgs`, an option just before `--`).
    # The candidate `--lang=` is printed by the loader for `ct record --la`;
    # it appears once, so the loader was asked once.  The recorder is a stub
    # that leaves a file behind: a completion must record nothing.
    let ct = getEnv("CODETRACER_E2E_CT_PATH",
      currentSourcePath.parentDir.parentDir.parentDir / "build-debug" /
      "bin" / "ct")
    check fileExists(ct)
    if fileExists(ct):
      let work = getTempDir() / ("ct_record_completion_" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      let stub = work / "stub.sh"
      let saw = work / "saw"
      writeFile(stub, "#!/bin/sh\ntouch \"$SAW\"\nexit 1\n")
      setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
      let prog = quoteShell(findExe("true"))
      const compLine = "ct record --la"
      for line in ["-- " & prog, prog & " -- a", "--lang -- " & prog,
                   "--backend=mcr -- " & prog]:
        let outFile = work / "out"
        let errFile = work / "err"
        let (_, code) = execCmdEx("cd " & quoteShell(work) & " && SAW=" &
          quoteShell(saw) & " CODETRACER_CT_MCR_CMD=" & quoteShell(stub) &
          " COMP_LINE=" & quoteShell(compLine) & " COMP_POINT=" &
          $compLine.len & " timeout 300 " & quoteShell(ct) & " record " &
          line & " >" & quoteShell(outFile) & " 2>" & quoteShell(errFile))
        let output = if fileExists(outFile): readFile(outFile) else: ""
        let err = if fileExists(errFile): readFile(errFile) else: ""
        checkpoint("record " & line & ": exit " & $code & ", stdout " &
          output.escape & ", stderr " & err.escape)
        check code == 0
        check err == ""
        check "Defect" notin output & err
        check output.splitLines().count("--lang=") == 1
        check not fileExists(saw)
      removeDir(work)

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
