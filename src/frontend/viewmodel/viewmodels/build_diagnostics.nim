## viewmodels/build_diagnostics.nim
##
## **From a build's output lines to the Problems pane's rows — one rule for
## every front-end.**
##
## The desktop's Build component (`ui/build.nim`'s `appendBuild`) reads each
## line of a build's output in order and publishes a Problems row for the
## lines that name a location. The terminal and the GPUI window run their
## builds natively (`tui/host/build_runner`), and their Problems panes must
## list exactly the rows the desktop lists for the same output, so the rule is
## here, and the desktop calls it too:
##
## 1. EVERY line goes through the caller's `BuildLocationScanner`, in order and
##    once — including the lines with no location, because `nargo` puts the
##    severity keyword on the line above the location (Edit-Mode-Toolbar.md
##    EMT-A35b; `ui/build_location_parser`'s header).
## 2. A line is a row only where the stateless matcher places a location too
##    and the line does not mention `Hint` — the desktop's `matchLocation`
##    guard, kept as it is: a Nim `Hint:` line is chatter, not a problem.
## 3. The row carries the scanner's reading (the header's severity and
##    sentence carried down onto a `┌─` line), the path AS THE COMPILER WROTE
##    IT. The rows are equal across front-ends because nothing here rewrites
##    them; resolving a relative path is the jump's business (`resolvedPath`).
##
## `BuildProblemsFeed` is the stateful half a native host drives: it owns the
## scanner and the ErrorsVM it fills, clears the list when a new build starts
## (EMT-D22.7) and highlights the first error — without moving focus — when a
## build fails (EMT-D21). The desktop keeps its own wiring (its feed is the
## component's scanner and its IPC handlers); the native front-ends share this
## one, and PLAT-56's Build Output pane on GPUI reads the same build.
##
## Pure: no filesystem, no process. C and JavaScript backends.

import std/strutils

import ../../ui/build_location_parser
import ../store/types
import ./errors_vm

export build_location_parser

type
  FedBuildLine* = object
    ## What one line of output was, read by the shared rule.
    scanned*: ParsedBuildLocation
      ## The scanner's reading (severity carried from a header line).
    located*: bool
      ## Whether the desktop's matcher places a location on the line
      ## (`matchLocation`: not a `Hint` line, and `parseBuildLocation` found
      ## one). The desktop splits such a line into its location and message.
    problem*: bool
      ## Whether the line is a Problems row (`located` and `scanned.found`).
    row*: BuildProblemLine
      ## The row, when `problem`.

proc severityOf*(sev: BuildSeverity): BuildLineSeverity =
  ## The parser's severity as the ViewModel's (`ui/build`'s
  ## `parserSeverityToVM`, which now calls this).
  case sev
  of SevError: blsError
  of SevWarning: blsWarning
  of SevInfo: blsInfo

proc isHintLine*(raw: string): bool =
  ## The desktop's `matchLocation` guard: a line that says `Hint` anywhere is
  ## never a row.
  "Hint" in raw

proc feedBuildLine*(scanner: var BuildLocationScanner;
                    raw: string): FedBuildLine =
  ## One line of a build's output, in order, read by the desktop's rule (the
  ## module header).
  result.scanned = scanner.scan(raw)
  result.located = not raw.isHintLine and parseBuildLocation(raw).found
  if result.located and result.scanned.found:
    result.problem = true
    result.row = BuildProblemLine(
      severity: severityOf(result.scanned.severity),
      path: result.scanned.path,
      line: result.scanned.line,
      col: result.scanned.col,
      message: result.scanned.message)

proc isAbsoluteBuildPath*(path: string): bool =
  ## A path a compiler wrote that needs no working directory: POSIX `/…`, or
  ## a Windows drive (`C:\…`, `C:/…`) or UNC (`\\…`) path.
  if path.len == 0:
    return false
  if path[0] == '/' or path.startsWith("\\\\"):
    return true
  path.len >= 3 and path[0] in {'A'..'Z', 'a'..'z'} and path[1] == ':' and
    path[2] in {'/', '\\'}

proc resolvedPath*(path, workingDirectory: string): string =
  ## Where a diagnostic's file is: an absolute path as written; a relative one
  ## against the BUILD'S working directory, not the project root
  ## (Edit-Mode-Toolbar.md §11.1.4, EMT-A36 — a task run in `packages/a`
  ## reports paths relative to there). A leading `./` is dropped.
  if path.len == 0 or path.isAbsoluteBuildPath or workingDirectory.len == 0:
    return path
  var rel = path
  while rel.startsWith("./"):
    rel = rel[2 .. ^1]
  if workingDirectory.endsWith("/"): workingDirectory & rel
  else: workingDirectory & "/" & rel

type
  BuildProblemsFeed* = ref object
    ## A native host's reader of one build after another into the window's
    ## `ErrorsVM` (the module header).
    vm*: ErrorsVM
    scanner: BuildLocationScanner
    workingDirectory*: string
      ## The running (or last) build's working directory, which a relative
      ## diagnostic resolves against.
    active*: bool
      ## Whether a build is being fed.

proc newBuildProblemsFeed*(vm: ErrorsVM): BuildProblemsFeed =
  BuildProblemsFeed(vm: vm)

proc beginBuild*(f: BuildProblemsFeed; workingDirectory: string) =
  ## A new build starts: the list is cleared and the navigation cursor reset
  ## (EMT-D22.7), and no pending keyword of the last build carries over.
  if f.isNil:
    return
  f.scanner.reset()
  f.workingDirectory = workingDirectory
  f.active = true
  if not f.vm.isNil:
    f.vm.clearProblems()

proc feedLine*(f: BuildProblemsFeed; raw: string): bool =
  ## One line of the build's output. Whether it became a row.
  if f.isNil:
    return false
  let fed = f.scanner.feedBuildLine(raw)
  if fed.problem and not f.vm.isNil:
    f.vm.appendProblem(fed.row)
  fed.problem

proc endBuild*(f: BuildProblemsFeed; failed: bool) =
  ## The build ended. A failed one highlights its first error WITHOUT moving
  ## the caret or the focus (EMT-D21: a build never steals focus; the row is
  ## selected so that `next error` has an origin).
  if f.isNil:
    return
  f.active = false
  if failed and not f.vm.isNil:
    discard f.vm.highlightFirstError()
