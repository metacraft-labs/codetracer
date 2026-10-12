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
