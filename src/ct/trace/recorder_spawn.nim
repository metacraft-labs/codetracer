## recorder_spawn — how `ct record` runs `db-backend-record`, and how it learns
## the recording id.
##
## `ct record` used to start the recorder with its stdout and stderr merged
## into a pipe (to find the `recordingId:` marker in them) and its stdin a
## pipe nobody writes. The recorder runs the traced program with
## `poParentStreams`, so the PROGRAM inherited those pipes: a TUI had no
## terminal to draw on and read no keys, and anything reading stdin blocked
## forever. Agent Harbor's session viewer (`ah session view`) recorded that
## way drew nothing and could not be closed.
##
## When `ct` itself runs on a terminal the program is the user's: the
## recorder, and through it the program, gets `ct`'s own stdin, stdout and
## stderr, and the recorder writes the recording id to a file
## (`--recording-id-file`) instead of `ct` reading it off a stream the program
## shares. Without a terminal (the GUI, CI, a script capturing `ct record`) the
## relay stays as it was: those callers read the merged output.
##
## "On a terminal" is stdin OR stdout: a caller that captures ct's stdout
## from a terminal session still gets the recording id on stdout (the
## recorder prints the marker there itself), but the recorder's stderr then
## goes to ct's stderr instead of being merged into stdout.
##
## Asserted by `recorder_spawn_test.nim` beside this file.

import std/[os, osproc, streams, strutils, tempfiles, terminal]
import recorder_output

const RecordingIdFileArg* = "--recording-id-file"
  ## The recorder's option naming the file it writes the recording id to.

proc ctHasTerminal*(): bool =
  ## Whether `ct` runs on a terminal the recorded program should have.
  isatty(stdin) or isatty(stdout)

proc relayRecorderOutput(p: Process): tuple[lines: seq[string], exitCode: int] =
  ## Relay the recorder's merged stdout/stderr to our own stdout AS IT
  ## ARRIVES, keeping every line so the `recordingId:` marker can be found
  ## afterwards. (`osproc.readLines` waits for the child to exit, which hid
  ## `ct record --server`'s live guidance until the server had stopped.)
  var lines: seq[string] = @[]
  let stream = p.outputStream
  var line = ""
  while stream.readLine(line):
    echo line
    flushFile(stdout)
    lines.add(line)
  (lines, p.waitForExit)

proc runRecorder*(exe: string; args: seq[string]; interactive: bool;
                  idFileDir: string): tuple[lines: seq[string], exitCode: int] =
  ## Run the recorder `exe` with `args` (its options first, the program
  ## last). `lines` carries the `recordingId:` marker on success either way:
  ## relayed from the merged output, or rebuilt from the id file the recorder
  ## wrote (`interactive`, which hands it our own streams).
  if not interactive:
    let p = startProcess(exe, args = args, options = {poStdErrToStdOut, poUsePath})
    result = relayRecorderOutput(p)
    p.close()
    return
  # A fresh, exclusively created file per run: a pid-named one in a shared
  # temp directory could collide across pid namespaces or be planted by
  # another user.
  createDir(idFileDir)
  let (idHandle, idFile) = createTempFile("ct-recording-id-", "", idFileDir)
  idHandle.close()
  try:
    let p = startProcess(exe, args = @[RecordingIdFileArg, idFile] & args,
                         options = {poParentStreams, poUsePath})
    result.exitCode = p.waitForExit
    p.close()
    let id = readFile(idFile).strip
    if id.len > 0:
      result.lines = @[RecordingIdMarker & id]
  finally:
    removeFile(idFile)
