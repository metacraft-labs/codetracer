## recorder_output_test.nim
##
## `ct record` and `ct record-test` read the recording id from the recorder's
## `recordingId:` marker. Until 2026-10-12 `recordTest` read `lines[^2]`
## behind `lines.len > 0`, so one line of output read `lines[-1]` and raised
## an `IndexDefect` (codetracer-pm
## `issues/2026-09-29-record-test-reads-lines-2-behind-a-length-1-guard.md`),
## and a traced program's trailing output after the marker hid it.
##
## Mocking justification (workspace policy on mock objects): none. The helper
## is pure and is called with the strings a recorder prints.
##
## Compile and run:
##   nim c -r src/tests/cli/recorder_output_test.nim

import std/unittest
import ../../ct/trace/recorder_output

suite "recordingIdFromOutput":
  test "a marker followed by a newline is found":
    check recordingIdFromOutput("building...\nrecordingId: 42\n") == "42"

  test "output that holds no marker reports none instead of raising":
    check recordingIdFromOutput("") == ""
    check recordingIdFromOutput("\n") == ""
    check recordingIdFromOutput("error: build failed\n") == ""

  test "a marker on the only line, without a newline, is found":
    check recordingIdFromOutput("recordingId: 7") == "7"

  test "the traced program's output after the marker does not hide it":
    check recordingIdFromOutput("board\nrecordingId: 1\n---------\n") == "1"

  test "the last marker wins":
    check recordingIdFromOutput("recordingId: old\nrecordingId: new\n") == "new"

  test "a marker without an id reports none":
    check recordingIdFromOutput("recordingId:\n") == ""

  test "surrounding whitespace is not part of the id":
    check recordingIdFromOutput("recordingId:   abc  \r\n") == "abc"
