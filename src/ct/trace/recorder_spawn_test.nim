## Unit tests for ``recorder_spawn``: how ``ct record`` runs
## ``db-backend-record`` and learns the recording id.
##
## A ``/bin/sh`` script stands in for the recorder (mocking justification:
## none -- it is a real executable the spawn really runs). It reports where
## its stdin and stdout lead, prints the ``recordingId:`` marker the real
## recorder prints, and writes the id to ``--recording-id-file`` when given
## one.
##
## * interactive: the recorder (and so the program it runs with
##   ``poParentStreams``) has OUR stdin and stdout -- the same open files,
##   which is what a TUI needs -- and the id comes back through the file;
## * not interactive: the merged-output relay, as the GUI and CI read it,
##   still finds the marker and the exit code.
##
## Compile and run:
##   nim c -r src/ct/trace/recorder_spawn_test.nim

when not defined(linux):
  {.fatal: "recorder_spawn_test reads /proc/<pid>/fd: Linux only".}

import std/[os, strutils, unittest]
import recorder_spawn, recorder_output

proc fakeRecorder(dir: string): string =
  result = dir / "fake-db-backend-record"
  writeFile(result, """#!/bin/sh
report=$FAKE_RECORDER_REPORT
idfile=""
if [ "$1" = --recording-id-file ]; then idfile=$2; shift 2; fi
echo "stdin=$(readlink /proc/$$/fd/0)" > "$report"
echo "stdout=$(readlink /proc/$$/fd/1)" >> "$report"
echo "args=$*" >> "$report"
echo "recordingId:01a1e000-0000-7000-8000-000000000042"
[ -n "$idfile" ] && echo "01a1e000-0000-7000-8000-000000000042" > "$idfile"
exit 3
""")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc reportOf(path: string): tuple[stdin, stdout, args: string] =
  for line in readFile(path).splitLines:
    if line.startsWith("stdin="): result.stdin = line[6 .. ^1]
    elif line.startsWith("stdout="): result.stdout = line[7 .. ^1]
    elif line.startsWith("args="): result.args = line[5 .. ^1]

suite "recorder_spawn":
  let dir = getTempDir() / ("recorder-spawn-test-" & $getCurrentProcessId())
  createDir(dir)
  let recorder = fakeRecorder(dir)
  let report = dir / "report"
  putEnv("FAKE_RECORDER_REPORT", report)

  test "interactive: the recorder gets our own stdin and stdout, the id comes back by file":
    removeFile(report)
    let (lines, code) = runRecorder(recorder, @["-o", "out", "prog", "arg"],
                                    interactive = true, idFileDir = dir / "ids")
    check code == 3
    check recordingIdFromLines(lines) == "01a1e000-0000-7000-8000-000000000042"
    let r = reportOf(report)
    check r.stdin == expandSymlink("/proc/self/fd/0")
    check r.stdout == expandSymlink("/proc/self/fd/1")
    check r.args == "-o out prog arg"
    # The id file is ct's, not the recording's: it is gone afterwards.
    var left = 0
    for _ in walkFiles(dir / "ids" / "ct-recording-id-*"): inc left
    check left == 0

  test "not interactive: the merged output is relayed and the marker found in it":
    removeFile(report)
    let (lines, code) = runRecorder(recorder, @["-o", "out", "prog"],
                                    interactive = false, idFileDir = dir / "ids")
    check code == 3
    check recordingIdFromLines(lines) == "01a1e000-0000-7000-8000-000000000042"
    let r = reportOf(report)
    check r.stdout.startsWith("pipe:")
    check r.stdout != expandSymlink("/proc/self/fd/1")
    check r.args == "-o out prog"

  removeDir(dir)
