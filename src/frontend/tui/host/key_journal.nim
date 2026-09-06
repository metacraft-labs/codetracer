## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## host/key_journal.nim — CTUI-14. §6.2's `--record-keys` and `--replay-keys`:
## a session's input, as a file.
##
## ## What a journal is, and why it is a file of TOKENS
##
## The unit is one COMPLETE INPUT TOKEN — a byte, or a whole escape sequence —
## which is exactly what `host/terminal_driver.InputFramer` produces and exactly
## what `app/input/keymap.keyName` consumes. It is deliberately not raw bytes:
## a byte stream would have to be re-framed on replay, and a journal that could
## disagree with the live framer about where one key ends would replay a
## different session than the one it recorded.
##
## The file is one token per line, in `strutils.escape`'s quoted form:
##
##     "n"
##     "\x1b[21~"
##     ":"
##     "g"
##
## `escape`/`unescape` round-trip every byte including `\n` and `\x1b`, so the
## format is exact AND a person can read it — which matters, because the first
## thing anyone does with a recorded bug report is look at it.
##
## ## Why this is worth a module rather than two `writeLine`s
##
## Three callers want it and none of them is the user who asked for the flag:
##
##   * **A bug report.** "It happens after I do this" becomes a file.
##   * **`benchmarks/tui_benchmarks.nim`.** §8's input-latency metrics are
##     measured over a fixed key sequence, and a benchmark whose input drifted
##     between runs would be measuring the input.
##   * **`tests/real_terminal/test_real_high_latency.nim`.** Its whole assertion
##     is that the final screen after 100 steps equals the zero-latency run's
##     final screen FOR THE SAME KEY SEQUENCE. "The same" has to be a fact
##     rather than an intention, and a journal is what makes it one.
##
## ## `--replay-keys` ENDS THE SESSION, and that is §6.2's own wording
##
## "Replay input events from file and exit." So a journal that runs out is not
## an idle terminal waiting for more; it is the end of the run. `main.nim` reads
## `exhausted` and stops, which is what makes a replay a fixed amount of work
## and therefore something a benchmark can time.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it touches files and fds.".}

import std/[os, strutils]

import ./native_host

type
  KeyJournal* = ref object
    ## The input side of one session: what is being written down, and what is
    ## being played back. Never both — `app/cli.parseTuiCommand` refuses the
    ## pair, because a replay that recorded would be copying its own input file.
    recordPath*: string
    replayPath*: string
    handle: File
    recordOpen: bool
    queue: seq[string]
    position: int
    recorded*: int
      ## How many tokens have been written down. Counted rather than derived
      ## from the file, so a caller can assert on it without reading back what
      ## it just wrote — which would be the code under test producing its own
      ## expected value.

proc encodeToken*(token: string): string =
  ## One token as one line of a journal.
  strutils.escape(token)

proc decodeToken*(line: string): (bool, string) =
  ## One line of a journal back into a token, or `(false, …)` for a line that
  ## is not one.
  ##
  ## Blank lines and `#` comments are skipped by the reader rather than
  ## rejected here, so a journal stays editable by hand: the common use is
  ## trimming a recorded session down to the three keys that reproduce
  ## something.
  let trimmed = strutils.strip(line)
  if trimmed.len < 2 or trimmed[0] != '"' or trimmed[^1] != '"':
    return (false, "")
  try:
    (true, strutils.unescape(trimmed))
  except ValueError:
    (false, "")

proc parseJournal*(text: string): (seq[string], seq[string]) =
  ## `(tokens, problems)` for a whole journal file.
  ##
  ## BOTH HALVES ARE RETURNED. A journal with one unreadable line among ninety
  ## is still a journal, and the caller decides — `main.nim` refuses the whole
  ## file, because a replay that silently skipped a key would produce a screen
  ## nobody could account for.
  var tokens: seq[string] = @[]
  var problems: seq[string] = @[]
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let trimmed = strutils.strip(rawLine)
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let (ok, token) = decodeToken(trimmed)
    if ok:
      tokens.add token
    else:
      problems.add "line " & $lineNo & ": " & trimmed
  (tokens, problems)

proc openKeyJournal*(recordPath, replayPath: string): KeyJournal =
  ## A journal that records, replays, or does neither.
  ##
  ## Both failures raise `TuiHostError` with the path in the message, and both
  ## happen BEFORE the terminal is claimed when `main.nim` calls this in the
  ## right order — which is the same rule `native_host.traceFolderProblem`
  ## exists for: a diagnosis a user can act on belongs on the ordinary screen.
  result = KeyJournal(recordPath: recordPath, replayPath: replayPath,
                      recordOpen: false, queue: @[], position: 0, recorded: 0)
  if replayPath.len > 0:
    if not fileExists(replayPath):
      raise newException(TuiHostError,
        "no such key journal: " & replayPath &
        " — record one with `--record-keys=" & replayPath & "`")
    let (tokens, problems) = parseJournal(readFile(replayPath))
    if problems.len > 0:
      raise newException(TuiHostError,
        replayPath & ": " & $problems.len &
        " line(s) are not journal entries, starting at " & problems[0] &
        " — an entry is one token in nim's `escape` form, e.g. \"\\\"n\\\"\"")
    if tokens.len == 0:
      # AN EMPTY JOURNAL IS REFUSED rather than replayed as a session that
      # ends immediately. The two are indistinguishable on the screen, and
      # only one of them is what the user meant.
      raise newException(TuiHostError,
        replayPath & ": the journal has no entries to replay")
    result.queue = tokens
  if recordPath.len > 0:
    var f: File
    if not open(f, recordPath, fmWrite):
      raise newException(TuiHostError,
        "cannot write the key journal " & recordPath)
    result.handle = f
    result.recordOpen = true

proc isReplaying*(j: KeyJournal): bool =
  j.queue.len > 0

proc pendingReplay*(j: KeyJournal): int =
  ## How many tokens are still to be played. `0` on a live session.
  max(0, j.queue.len - j.position)

proc exhausted*(j: KeyJournal): bool =
  j.isReplaying and j.position >= j.queue.len

proc nextReplayToken*(j: KeyJournal): (bool, string) =
  ## The next token to feed the runtime, or `(false, "")` when the journal has
  ## run out — which §6.2 says ends the session.
  if not j.isReplaying or j.position >= j.queue.len:
    return (false, "")
  let token = j.queue[j.position]
  inc j.position
  (true, token)

proc note*(j: KeyJournal; token: string) =
  ## Write one token down, if this journal is recording.
  ##
  ## FLUSHED PER TOKEN. A journal exists to survive the session that produced
  ## it, and the sessions worth recording are exactly the ones that end badly:
  ## a buffered write would lose the last few keys of every crash it was
  ## opened for.
  if not j.recordOpen:
    return
  j.handle.writeLine(encodeToken(token))
  j.handle.flushFile()
  inc j.recorded

proc close*(j: KeyJournal) =
  if j.isNil or not j.recordOpen:
    return
  j.handle.close()
  j.recordOpen = false

proc describe*(j: KeyJournal): string =
  ## For the status line and for a benchmark's log.
  if j.isNil:
    return "no key journal"
  if j.isReplaying:
    "replaying " & $j.queue.len & " token(s) from " & j.replayPath
  elif j.recordPath.len > 0:
    "recording keys to " & j.recordPath
  else:
    "no key journal"
