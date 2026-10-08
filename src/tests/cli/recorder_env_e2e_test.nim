## recorder_env_e2e_test.nim
##
## `ct record`'s recorder options reach ct-mcr, through the REAL chain, as
## environment twins -- and the recorded program's argv stays exactly what the
## user wrote.  codetracer-specs `CLI/ct/record.md`, "Recorder options".
##
## ## Why end to end
##
## An MCR recording runs `ct` -> `db-backend-record` -> `ct-native-replay
## record --backend mcr` -> `ct-mcr record -o <out> -- <program> <args>`.
## `ct record --use-interpose` used to append `--interpose` to that chain,
## where it travelled behind `--` and was handed to the recorded PROGRAM; the
## recorder never saw it.  The pure table test (`recorder_env_test.nim`)
## cannot see that: only the binaries in between decide where an argument
## lands.  So this runs the shipped `ct`, the real `db-backend-record` and the
## real `ct-native-replay`, with the recorder replaced at the end of the chain.
##
## Mocking justification (workspace policy on mock objects): the RECORDER is
## replaced, through `ct-native-replay`'s own override `CODETRACER_CT_MCR_CMD`,
## by a shell script that writes the argv and the environment it receives to
## a file and exits.  What is under test is what arrives at the recorder's
## door, which a real recorder would consume rather than report; the real one
## is exercised by codetracer-native-recorder's own `CT_INTERPOSE` and
## `CT_PORTABLE` tests.  Everything before the recorder is real.  The
## recording itself then fails (the stub writes no trace), which this test
## does not assert on.
##
## Prerequisites (a missing one FAILS the row, it never skips): the built
## `ct` and `db-backend-record` under `src/build-debug/bin` (or
## CODETRACER_E2E_CT_PATH), and `ct-native-replay` on PATH.
##
## Compile and run:
##   nim c -r src/tests/cli/recorder_env_e2e_test.nim

import std/[os, osproc, strutils, unittest]

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  result = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug") /
           "bin" / "ct"

proc runCase(): seq[string] =
  ## The failures, by name; empty when the options arrived as their twins and
  ## the program's argv is exactly what was written.
  template need(cond: bool, msg: string) =
    if not cond: result.add msg
  let ct = ctBinary()
  if not (fileExists(ct) and fileExists(ct.parentDir / "db-backend-record") and
          findExe("ct-native-replay").len > 0):
    return @["PREREQUISITE MISSING: ct and db-backend-record at " &
             ct.parentDir & ", and ct-native-replay on PATH"]
  let work = getTempDir() / ("ct_recorder_env_e2e_" & $getCurrentProcessId())
  removeDir(work)
  createDir(work)
  defer: removeDir(work)
  let capture = work / "recorder-saw.txt"
  let stub = work / "ct-mcr-stub.sh"
  # The stub recorder: one line per argument, then the CT_ variables.
  writeFile(stub, "#!/bin/sh\n" &
    "{ for a in \"$@\"; do printf 'ARG %s\\n' \"$a\"; done; " &
    "env | grep '^CT_' | sed 's/^/ENV /'; } > " & quoteShell(capture) & "\n" &
    "exit 1\n")
  setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
  # A real native program for `ct` to recognise and send to the MCR backend;
  # it never runs (the stub does not run it).
  let prog = findExe("true")
  if prog.len == 0: return @["PREREQUISITE MISSING: `true` on PATH"]
  let cmd = "cd " & quoteShell(work) &
    " && CODETRACER_CT_MCR_CMD=" & quoteShell(stub) &
    " timeout 300 " & quoteShell(ct) &
    " record -o " & quoteShell(work / "out") &
    " --backend=mcr --use-interpose --portable " &
    quoteShell(prog) & " alpha beta 2>&1"
  let (output, _) = execCmdEx(cmd)
  if not fileExists(capture):
    return @["the recorder stub was never invoked; ct said:\n" & output]
  var args, env: seq[string]
  for line in readFile(capture).splitLines:
    if line.startsWith("ARG "): args.add line[4 .. ^1]
    elif line.startsWith("ENV "): env.add line[4 .. ^1]
  let seen = " (recorder argv " & $args & ", CT_ env " & $env & ")"
  # The options arrive as their twins ...
  need("CT_INTERPOSE=on" in env, "CT_INTERPOSE=on did not reach the recorder" & seen)
  need("CT_PORTABLE=on" in env, "CT_PORTABLE=on did not reach the recorder" & seen)
  # ... and nowhere in the argv, before `--` or after it.
  for flag in ["--interpose", "--use-interpose", "--portable"]:
    need(flag notin args, flag & " is in the recorder's argv" & seen)
  # The program and exactly its arguments follow `--`.
  let dd = args.find("--")
  need(dd >= 0 and args[dd + 1 .. ^1] == @[prog, "alpha", "beta"],
       "the program's argv is not exactly [" & prog & ", alpha, beta]" & seen)

suite "ct record: recorder options arrive at ct-mcr as environment twins":
  test "--use-interpose and --portable reach the recorder; the program's argv is untouched":
    let failures = runCase()
    for f in failures: checkpoint(f)
    check failures.len == 0
