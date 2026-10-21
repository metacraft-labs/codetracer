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

import std/[strutils, unittest]
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

suite "recordTestFailureSentence":
  test "the recorder's own sentence on stdout reaches the failure text":
    ## The measured case: Noir on the desktop.
    let sentence = recordTestFailureSentence(1, "",
      "Assuming recording language LangNoir: currently `ct record-test` " &
      "not supported for this db-based language\n", "", "")
    check sentence.startsWith(RecordTestErrorStem)
    check "not supported for this db-based language" in sentence
    check sentence.endsWith("(exit code 1)")

  test "stderr is preferred over stdout when it has something":
    let sentence = recordTestFailureSentence(2, "", "progress...\n",
      "fatal: loader could not open libfoo.so\n", "")
    check "libfoo.so" in sentence
    check "progress" notin sentence

  test "only the last lines are kept, and the length is bounded":
    var noisy = ""
    for i in 0 ..< 50:
      noisy.add "line " & $i & " " & repeat("x", 100) & "\n"
    noisy.add "error: the real reason\n"
    let sentence = recordTestFailureSentence(1, "", noisy, "", "")
    check "error: the real reason" in sentence
    check "line 0 " notin sentence
    check sentence.len <= RecordTestErrorStem.len + RecorderDetailMaxChars +
                          "… (exit code 1)".len

  test "a recorder that said nothing still yields a sentence with the status":
    check recordTestFailureSentence(1, "", "", "\n  \n", "") ==
      RecordTestErrorStem & "the recorder gave no reason (exit code 1)"
    check recordTestFailureSentence(-1, "SIGKILL", "", "", "") ==
      RecordTestErrorStem & "the recorder gave no reason (ended by signal SIGKILL)"

  test "a recorder that could not be started says so":
    check recordTestFailureSentence(-1, "", "", "", "spawn ct ENOENT") ==
      RecordTestErrorStem & "could not be started: spawn ct ENOENT"
