## recorder_output — the `recordingId:` marker a recorder prints when it has
## made a recording.
##
## The marker is not reliably on any fixed line. A recorder runs the traced
## program as a child with its stdout merged into the recorder's, so a
## trailing banner from the program can land after the marker, and output
## need not end in a newline. Every captured line is scanned and the last
## marker wins; a fixed index such as `lines[^2]` both misses a late marker
## and, behind a guard that does not establish it, raises an `IndexDefect`.
##
## PURE: asserted by `src/tests/cli/recorder_output_test.nim`.

import std/strutils

const RecordingIdMarker* = "recordingId:"

proc recordingIdFromLines*(lines: openArray[string]): string =
  ## The id on the last line that starts with the marker, or "" when no line
  ## does or the last marker carries no id.
  for line in lines:
    if line.startsWith(RecordingIdMarker):
      result = line[RecordingIdMarker.len .. ^1].strip

proc recordingIdFromOutput*(output: string): string =
  ## `recordingIdFromLines` over `output` split into lines.
  recordingIdFromLines(output.splitLines())

const
  RecordTestErrorStem* = "ct record-test error: "
    ## The prefix every failed `ct record-test` run is reported under, so a
    ## reader (and the Test Results pane's failure block) can tell the
    ## recorder's sentence from the host's own.

  RecorderDetailMaxChars* = 400
    ## How much of the recorder's own output a failure sentence may carry. A
    ## sentence, not a log: the full output is in the CodeTracer log.

  RecorderDetailMaxLines = 3

proc recorderDetail*(output: string): string =
  ## The last few non-blank lines of `output`, joined with " ", bounded to
  ## `RecorderDetailMaxChars` (the END is kept: a recorder states its reason
  ## last). "" when `output` has nothing to say.
  var lines: seq[string]
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len > 0:
      lines.add line
  if lines.len > RecorderDetailMaxLines:
    lines = lines[^RecorderDetailMaxLines .. ^1]
  result = lines.join(" ")
  if result.len > RecorderDetailMaxChars:
    result = "…" & result[result.len - RecorderDetailMaxChars .. ^1]

proc recordTestFailureSentence*(exitCode: int; signal, stdoutText,
                                stderrText, spawnError: string): string =
  ## Why a `ct record-test` run made no recording, in the recorder's OWN words.
  ##
  ## `ct record-test` states its reason and exits 1 — for a language it has
  ## no test route for, "Assuming recording language <lang>: currently
  ## `ct record-test` not supported for this db-based language", on STDOUT —
  ## and the Electron main process used to keep only "Exit with code 1",
  ## because `electron_lib.readProcessOutput` discards output on a non-zero
  ## exit. A user was told the run failed and never why.
  ##
  ## Stderr is preferred when it has anything, since that is where a crash
  ## or a loader lands; otherwise stdout, where `recordTest` prints its own
  ## `error:` / "Assuming recording language" sentences. The exit status (or
  ## signal) is appended in parentheses so the sentence still carries it.
  ##
  ## PURE: asserted by `src/tests/cli/recorder_output_test.nim`.
  if spawnError.len > 0:
    return RecordTestErrorStem & "could not be started: " & spawnError
  let fromStderr = recorderDetail(stderrText)
  let detail = if fromStderr.len > 0: fromStderr else: recorderDetail(stdoutText)
  let status =
    if signal.len > 0: "ended by signal " & signal
    else: "exit code " & $exitCode
  if detail.len == 0:
    return RecordTestErrorStem & "the recorder gave no reason (" & status & ")"
  RecordTestErrorStem & detail & " (" & status & ")"
