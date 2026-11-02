## tui/host/build_problems.nim — PLAT-55. **A native window's builds, read into
## its Problems pane's ViewModel.**
##
## The terminal and the GPUI window run a build with `host/build_runner`
## (`:build <command>`, PLAT-16), whose `BuildSession` holds the output as a
## ring of lines. This is the reader that follows it into the window's
## `ErrorsVM` through the shared rule (`viewmodels/build_diagnostics`, which
## the desktop's Build component calls too), so the native Problems panes list
## exactly the rows the desktop lists for the same output:
##
## * a NEW session (a new `:build`) clears the list and resets the navigation
##   cursor (Edit-Mode-Toolbar.md EMT-D22.7);
## * every line the build writes is read once, in order — counted by
##   `BuildSession.received`, so a line the ring has dropped is never read
##   twice and a line it still holds is never skipped;
## * a build that FAILED highlights its first error without moving the caret
##   or the focus (EMT-D21).
##
## It also answers where a row's file is (`targetOf`): a relative path against
## the build's working directory (EMT-A36), and a row whose file is not there
## is listed and NOT opened, with the reason (EMT-D20).
##
## PLAT-56: the same reader fills the window's `BuildVM` — the Build Output
## pane's ViewModel, the one the desktop's BUILD panel draws: each line is read
## ONCE, by the build's own `BuildLineReader` (`BuildVM.feedOutput`: its text,
## its styled runs, its location), and the diagnostics rule's reading of it is
## what the Problems list gets. A new session begins a new build in the
## `BuildVM` (the last one goes to its history); its end finishes it, with its
## exit code, its end time and whether the user cancelled it.
##
## One per window, shared by every tab: a build is of the working tree, not of
## a recording. The GPUI window imports this module as it imports
## `native_host`; the terminal's pane values are `problems_source`'s and
## `build_output_source`'s.

import std/os

import isonim/core/[owner, computation, signals]

import ../app/build_session
import ../../viewmodel/viewmodels/errors_vm
import ../../viewmodel/viewmodels/build_diagnostics
import ../../viewmodel/viewmodels/build_vm
import ../../viewmodel/store/types

export errors_vm, build_diagnostics, build_vm

type
  BuildProblems* = ref object
    vm*: ErrorsVM
    feed*: BuildProblemsFeed
    build*: BuildVM
      ## PLAT-56: the window's Build Output ViewModel, fed the same lines.
    session: BuildSession
      ## The build being followed (identity: a new `:build` is a new object).
    consumed: int
      ## How many of its lines (`received`) have been read.
    dispose: proc()

  ProblemTarget* = object
    ## Where a diagnostic's file is, or why it cannot be opened.
    ok*: bool
    path*: string
      ## The resolved, absolute path.
    line*, col*: int
    why*: string

proc newBuildProblems*(): BuildProblems =
  ## A reader with a fresh `ErrorsVM` of its own (inside its own reactive
  ## root, released by `close`).
  result = BuildProblems()
  let p = result
  createRoot proc(dispose: proc()) =
    p.vm = createErrorsVM(nil)
    p.build = createBuildVM(nil)
    p.dispose = dispose
  p.feed = newBuildProblemsFeed(p.vm)

proc follow*(p: BuildProblems; session: BuildSession; nowMs = 0'i64): bool =
  ## Read what `session` wrote since the last call. Whether the list (or its
  ## selection) or the build's output changed. `nowMs` (when given) ticks the
  ## running build's elapsed time.
  if p.isNil or session.isNil:
    return false
  if session != p.session:
    p.session = session
    p.consumed = 0
    p.feed.beginBuild(session.workingDir)
    p.build.beginBuild(session.command, float(session.startedMs),
                       noun = $session.kind, taskName = session.taskName,
                       problemMatcher = session.problemMatcher)
    result = true
  let pending = session.received - p.consumed
  if pending > 0:
    # The ring holds the LAST `lines.len` of `received`; anything older that
    # is still unread was dropped by the ring (`truncated`, which the Build
    # pane reports) and cannot be read now.
    let first = max(0, session.lines.len - pending)
    for i in first ..< session.lines.len:
      let read = p.build.feedOutput(session.lines[i],
                                    isStdout = not session.isStderr(i))
      discard p.feed.addRow(read.fed)
    p.consumed = session.received
    result = true
  if session.verdict == bvRunning and nowMs > 0 and p.build.running.val:
    if nowMs - int64(p.build.clockMs.val) >= 100:
      p.build.tickClock(float(nowMs))
      result = true
  if p.feed.active and session.verdict notin {bvIdle, bvRunning}:
    p.feed.endBuild(failed = session.verdict == bvFailed)
    p.build.finishBuild(session.exitCode,
                        float(if session.endedMs > 0: session.endedMs
                              else: max(nowMs, session.startedMs)),
                        cancelled = session.verdict == bvCancelled)
    result = true

proc targetOf*(p: BuildProblems; index: int): ProblemTarget =
  ## Where diagnostic `index` (master) is — or why it cannot be opened, in
  ## words the pane can say (EMT-D20: the row stays listed either way).
  if p.isNil or p.vm.isNil or index < 0 or index >= p.vm.problems.val.len:
    return ProblemTarget(why: "there is no such problem")
  let problem = p.vm.problems.val[index]
  if not problem.isNavigable:
    return ProblemTarget(why: "this problem names no file and line to open")
  let path = resolvedPath(problem.path, p.feed.workingDirectory)
  if not fileExists(path):
    return ProblemTarget(why: problem.path & " was not found (looked for " &
                              path & "); the problem stays listed")
  ProblemTarget(ok: true, path: path, line: problem.line,
                col: max(0, problem.col))

proc targetOf*(p: BuildProblems; path: string; line, col: int): ProblemTarget =
  ## `targetOf` for a raw diagnostic location — what `ErrorsVM.onJumpToProblem`
  ## is handed.
  if p.isNil:
    return ProblemTarget(why: "there is no such problem")
  let resolved = resolvedPath(path, p.feed.workingDirectory)
  if path.len == 0 or line <= 0:
    return ProblemTarget(why: "this problem names no file and line to open")
  if not fileExists(resolved):
    return ProblemTarget(why: path & " was not found (looked for " &
                              resolved & "); the problem stays listed")
  ProblemTarget(ok: true, path: resolved, line: line, col: max(0, col))

proc close*(p: BuildProblems) =
  if not p.isNil and not p.dispose.isNil:
    p.dispose()
    p.dispose = nil
