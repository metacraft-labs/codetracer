## The scenarios' `record-program` stage caches only a recording `ct record`
## finished.
##
## The stage records into the fixture cache's entry for the program, and a
## later run reuses that entry. It used to record straight into the entry: a
## recording the stage's time limit cut off stayed there half written (a `.ct`
## without its folded `filemap.bin`), and every later run replayed it and
## failed ("PROVENANCE: ... the trace carries no filemap.bin"; the two Crystal
## sudoku scenarios, after one loaded run timed out recording them). It now
## records into a staging folder and renames it into place on success.
##
## The one stand-in, and why it is not a mock: `ct` is a shell script named by
## `CT_BIN` (the variable the stage's `findCtBinary` reads first) that writes
## a `.ct` container where `-o` points and then exits as the real one does
## when stopped (137) or when done (0). What is tested is the stage's handling
## of the folder `ct record` writes into, which a real recorder would make
## nondeterministic to interrupt; the stage code under test is the real one.

import std/[os, strutils, unittest]
import ../../../tests/scenarios/stages/ct_stages
import ./fixtures/fixture_provider

proc fakeCt(dir: string; exitCode: int): string =
  ## A `ct` whose `record -o <dest> <program>` writes `<dest>/trace.ct` and
  ## exits `exitCode`.
  result = dir / ("fake-ct-" & $exitCode)
  writeFile(result, "#!/bin/sh\n" &
    "out=\"\"\nwhile [ $# -gt 0 ]; do\n" &
    "  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift; fi\n  shift\ndone\n" &
    "mkdir -p \"$out\" && printf 'not a whole recording' > \"$out/trace.ct\"\n" &
    "exit " & $exitCode & "\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

suite "the record-program stage's fixture cache":
  let scratch = getTempDir() / ("ct-stage-cache-" & $getCurrentProcessId())
  createDir(scratch)
  # A program path no other scenario uses, so its cache entry is this test's.
  let program = scratch / "record_stage_probe.c"
  writeFile(program, "int main(void) { return 0; }\n")
  let name = program.replace("/", "_").replace(".", "_")
  let entry = fixtureCacheRoot(repo()) / (name & "-scenario")
  let savedCt = getEnv("CT_BIN")

  test "a recording `ct record` did not finish is not cached":
    removeDir(entry)
    putEnv("CT_BIN", fakeCt(scratch, 137))
    let s = newStageState(scratch / "run1")
    expect IOError:
      discard s.recordProgram(program, "")
    check not isUsableTraceDir(entry)
    check not dirExists(entry & ".partial")

  test "a finished recording is cached under the entry's name":
    removeDir(entry)
    putEnv("CT_BIN", fakeCt(scratch, 0))
    let s = newStageState(scratch / "run2")
    check s.recordProgram(program, "") == entry
    check fileExists(entry / "trace.ct")
    check not dirExists(entry & ".partial")

  removeDir(entry)
  removeDir(scratch)
  if savedCt.len > 0: putEnv("CT_BIN", savedCt) else: delEnv("CT_BIN")
