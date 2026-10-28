## viewmodels/build_output_model.nim — the Build Output pane's MODEL, shared
## by the desktop, the terminal and the GPUI window.
##
## Spec: codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.13 (the
## pane on every front-end), §3.5 (ANSI colour), §3.7 (build history), §3.10
## (the status bar).
##
## Pure: no ViewModel signal, no renderer, no `when defined(js)`; C and
## JavaScript backends. Every front-end reads the SAME answers from it, so the
## desktop's spans, the terminal's cells and the window's text runs cannot
## disagree about which characters a compiler wrote in which colour, which
## lines name a location, or what the header and the status bar say.
##
## ## What it holds
##
##  1. **The line reader** (`BuildLineReader`): a build's raw output, one line
##     at a time and in order, into a `BuildOutputLine` — its text, its styled
##     runs (SGR decoded by PLAT-52's scanner, `terminal_output_model`; every
##     other escape sequence dropped; tabs expanded to the next multiple of
##     eight) — and the line read by the shared diagnostics rule
##     (`build_diagnostics.feedBuildLine`) ON ITS TEXT, so a coloured
##     `src/main.c:5:17: error:` is matched as what the reader sees. A line
##     that names a location keeps its own text and colours and carries the
##     location (path as written, line, column): it is a jump target.
##  2. **The chunk rule** (`chunkLines`): a stream's write split into lines —
##     a write that ends with a newline does not end with an empty line.
##  3. **The words**: the header's verdict, the duration, the status bar's
##     indicator, the history picker's labels.

import std/[strutils, unicode]

import ../store/types
import ./terminal_output_model
import ./build_diagnostics

export build_diagnostics

type
  BuildStatus* = enum
    ## The verdict of a build, shared by every front-end.
    ##
    ## `bsCancelled` (PLAT-56) is the terminal's `bvCancelled` brought into the
    ## core: a build the user stopped is not a build that failed — `bsFailed`
    ## says the compiler rejected the code, a cancellation says nothing about
    ## the code at all — and the header and the status bar say so on every
    ## front-end.
    bsIdle       ## No build has run, or the panel was cleared.
    bsRunning    ## A build is currently in progress.
    bsSucceeded  ## The last build exited 0.
    bsFailed     ## The last build exited non-zero.
    bsCancelled  ## The last build was stopped by the user.

  BuildLineReader* = object
    ## One build's output, read line by line. A FRESH reader per build: the
    ## colour a build left set and the severity keyword it left pending
    ## belong to it, not to the next.
    ansi: AnsiScanner
    attrs: TermAttrs
    diag: BuildLocationScanner

  ReadBuildLine* = object
    ## One raw line, read.
    line*: BuildOutputLine
    fed*: FedBuildLine
      ## The shared diagnostics rule's reading of the line's text (whether it
      ## is a Problems row, and which).

  BuildHistoryEntry* = object
    ## A finished build, kept so the pane can show it again (§3.7).
    number*: int
      ## The build's number in this window, from 1.
    noun*: string
      ## What ran: "build", or "run" for the terminal's `:run`.
    command*: string
    output*: seq[BuildOutputLine]
    problems*: seq[BuildProblemLine]
    status*: BuildStatus
    code*: int
    startMs*: float
    endMs*: float

  BuildSnapshot* = object
    ## What the pane shows: the current build or one from the history.
    number*: int
    noun*: string
    command*: string
    output*: seq[BuildOutputLine]
    problems*: seq[BuildProblemLine]
    status*: BuildStatus
    code*: int
    startMs*: float
    endMs*: float
    latest*: bool
      ## Whether this is the current build (the one the status bar reports).

const
  BuildHistoryMax* = 10
    ## How many finished builds the history keeps (§3.7, `build.maxHistory`'s
    ## default).
  BuildIdleText* = "No build has run."
    ## The pane's empty state: no build in this window yet, or the output
    ## cleared (the desktop's `.build-empty`).
  BuildHistoryLabel* = "History"
    ## The picker's name, in the header (the desktop's `title`).
  BuildLatestLabel* = "Latest build"
    ## The picker's entry for the current build.
  BuildStatusIcons*: array[BuildStatus, string] = ["", "⟳", "✓", "✗", "■"]
    ## The status bar indicator's icon per verdict (§3.10: a spinning icon, a
    ## green checkmark, a red X).
  BuildControlTitles* = ["Run build (no re-record)", "Stop build",
                         "Clear build output", "Toggle auto-scroll"]
    ## The header's four controls, in the desktop's order, by their titles.

proc reset*(r: var BuildLineReader) =
  ## Back to a fresh build: default colours, no pending escape sequence, no
  ## pending severity keyword.
  r = BuildLineReader()

proc decode*(r: var BuildLineReader; raw: string): tuple[text: string;
                                                         runs: seq[BuildRun]] =
  ## `raw`'s text and styled runs. SGR sets the attributes (carried to the
  ## next line, as a terminal and `ansi_up` carry them); every other escape
  ## sequence and control is dropped; a tab is expanded to the next multiple
  ## of eight columns.
  var col = 0
  proc add(res: var tuple[text: string; runs: seq[BuildRun]];
           attrs: TermAttrs; s: string; col: var int) =
    if s.len == 0:
      return
    if res.runs.len > 0 and res.runs[^1].style == attrs:
      res.runs[^1].text.add s
    else:
      res.runs.add BuildRun(text: s, style: attrs)
    res.text.add s
    for _ in s.runes:
      inc col
  for t in r.ansi.scanAnsi(raw):
    case t.kind
    of atText:
      add(result, r.attrs, t.text, col)
    of atControl:
      if t.ch == '\t':
        add(result, r.attrs, spaces(TermTabStop - (col mod TermTabStop)), col)
    of atCsi:
      if t.ch == 'm' and t.private == '\0' and t.inter.len == 0:
        r.attrs.applySgr(t)
    of atEsc:
      if t.ch == 'c' and t.inter.len == 0:
        r.attrs = TermAttrs()

proc read*(r: var BuildLineReader; raw: string; isStdout: bool): ReadBuildLine =
  ## One line of the build's output (no newline), in order.
  let (text, runs) = r.decode(raw)
  result.fed = r.diag.feedBuildLine(text)
  result.line = BuildOutputLine(text: text, runs: runs, isStdout: isStdout)
  if result.fed.located:
    let loc = if result.fed.scanned.found: result.fed.scanned
              else: parseBuildLocation(text)
    result.line.severity =
      if result.fed.scanned.found: severityOf(result.fed.scanned.severity)
      else: blsNone
    result.line.locationPath = loc.path
    result.line.locationLine = loc.line
    result.line.locationCol = max(0, loc.col)

proc plainBuildLine*(text: string; isStdout = true;
                     severity = blsNone; path = ""; line = 0;
                     col = 0): BuildOutputLine =
  ## A line a producer wrote itself (no escape sequences): one default run.
  BuildOutputLine(text: text,
                  runs: (if text.len > 0: @[BuildRun(text: text)] else: @[]),
                  isStdout: isStdout, severity: severity,
                  locationPath: path, locationLine: line, locationCol: col)

proc chunkLines*(data: string): seq[string] =
  ## A stream's write as lines: split on `\n` (a `\r` before it dropped);
  ## a write that ENDS with a newline does not end with an empty line, so a
  ## producer that writes line by line and one that writes in blocks give the
  ## same lines. An empty write is one empty line.
  if data.len == 0:
    return @[""]
  result = data.split('\n')
  if data.endsWith("\n"):
    result.setLen(result.len - 1)
  for l in result.mitems:
    if l.endsWith("\r"):
      l.setLen(l.len - 1)

proc located*(line: BuildOutputLine): bool =
  ## Whether a press on the line opens a file.
  line.locationPath.len > 0 and line.locationLine > 0

# ---------------------------------------------------------------------------
# The words
# ---------------------------------------------------------------------------

proc formatBuildDuration*(ms: float): string =
  ## `3.2s`, `1m 4.0s` — the desktop's `buildElapsedStr`.
  let sec = max(0.0, ms) / 1000.0
  if sec < 60.0:
    return formatFloat(sec, ffDecimal, 1) & "s"
  let mins = int(sec) div 60
  $mins & "m " & formatFloat(sec - float(mins * 60), ffDecimal, 1) & "s"

proc durationMs*(s: BuildSnapshot; nowMs: float): float =
  ## How long the build ran: to its end, or (running) to `nowMs`.
  if s.startMs <= 0.0:
    return 0.0
  if s.status == bsRunning: max(0.0, nowMs - s.startMs)
  elif s.endMs > 0.0: max(0.0, s.endMs - s.startMs)
  else: 0.0

proc nounOf(s: BuildSnapshot): string =
  if s.noun.len > 0: s.noun else: "build"

proc headerText*(s: BuildSnapshot): string =
  ## The header's verdict (the desktop's `build-command-label`): "running
  ## <command>", "build succeeded", "build failed (exit code N)", "build
  ## cancelled", or nothing when idle.
  case s.status
  of bsIdle: ""
  of bsRunning: "running " & s.command
  of bsSucceeded: s.nounOf & " succeeded"
  of bsFailed: s.nounOf & " failed (exit code " & $s.code & ")"
  of bsCancelled: s.nounOf & " cancelled"

proc durationText*(s: BuildSnapshot; nowMs: float): string =
  ## The header's duration (the desktop's `build-duration`): the elapsed time
  ## while running, "in <duration>" once ended, nothing when idle.
  case s.status
  of bsIdle: ""
  of bsRunning: formatBuildDuration(s.durationMs(nowMs))
  else:
    if s.startMs > 0.0 and s.endMs > 0.0:
      "in " & formatBuildDuration(s.durationMs(nowMs))
    else: ""

proc countWords*(problems: openArray[BuildProblemLine]): string =
  ## "2 errors, 1 warning" — the counts the status bar names, nothing for none.
  var errors, warnings = 0
  for p in problems:
    case p.severity
    of blsError: inc errors
    of blsWarning: inc warnings
    else: discard
  var parts: seq[string] = @[]
  if errors > 0:
    parts.add $errors & (if errors == 1: " error" else: " errors")
  if warnings > 0:
    parts.add $warnings & (if warnings == 1: " warning" else: " warnings")
  parts.join(", ")

proc statusText*(s: BuildSnapshot; nowMs: float): string =
  ## The status bar's build indicator (§3.10), for the CURRENT build: nothing
  ## when idle; "Building… 3.2s"; "Build succeeded in 3.2s"; "Build failed: 2
  ## errors, 1 warning" (or "Build failed (exit code N)" with no diagnostic);
  ## "Build cancelled".
  let noun = s.nounOf.capitalizeAscii
  case s.status
  of bsIdle: ""
  of bsRunning:
    (if s.nounOf == "build": "Building… " else: "Running… ") &
      formatBuildDuration(s.durationMs(nowMs))
  of bsSucceeded:
    if s.startMs > 0.0 and s.endMs > 0.0:
      noun & " succeeded in " & formatBuildDuration(s.durationMs(nowMs))
    else: noun & " succeeded"
  of bsFailed:
    let counts = countWords(s.problems)
    if counts.len > 0: noun & " failed: " & counts
    else: noun & " failed (exit code " & $s.code & ")"
  of bsCancelled: noun & " cancelled"

proc shortVerdict(status: BuildStatus; code: int): string =
  case status
  of bsIdle: "not run"
  of bsRunning: "running"
  of bsSucceeded: "succeeded"
  of bsFailed: "failed (exit code " & $code & ")"
  of bsCancelled: "cancelled"

proc historyLabel*(e: BuildHistoryEntry): string =
  ## One entry of the history picker: "#2 nargo compile — failed (exit code
  ## 1), 0.4s".
  var label = "#" & $e.number & " " & e.command & " — " &
              shortVerdict(e.status, e.code)
  if e.startMs > 0.0 and e.endMs > 0.0:
    label.add ", " & formatBuildDuration(e.endMs - e.startMs)
  label

proc snapshotOf*(e: BuildHistoryEntry): BuildSnapshot =
  BuildSnapshot(number: e.number, noun: e.noun, command: e.command, output: e.output,
                problems: e.problems, status: e.status, code: e.code,
                startMs: e.startMs, endMs: e.endMs, latest: false)

proc entryOf*(s: BuildSnapshot): BuildHistoryEntry =
  BuildHistoryEntry(number: s.number, noun: s.noun, command: s.command, output: s.output,
                    problems: s.problems, status: s.status, code: s.code,
                    startMs: s.startMs, endMs: s.endMs)
