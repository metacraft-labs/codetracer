## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/build_session.nim — PLAT-16. `:build` and `:run`, their verdicts, and
## the cancellation the specification makes a requirement rather than a nicety.
##
## ## THE VERDICT STATES ARE NOT RE-SPECIFIED HERE
##
## CodeTracer-TUI-Edit-Mode.md §5: *"The verdict states are specified in
## Edit-Mode-Toolbar § 9.2 and are not repeated here."* They already exist in
## the core as `viewmodels/build_vm.BuildStatus` — `bsIdle`, `bsRunning`,
## `bsSucceeded`, `bsFailed` — which is the enum the Electron front-end's Build
## panel is driven by. This module reaches it through the facade.
##
## IT ADDS EXACTLY ONE STATE, AND THE ADDITION IS THE DELIVERABLE. §5 requires
## *"A build that hangs must be cancellable"*, and a build the user stopped is
## not a build that failed: `bsFailed` means the compiler rejected the code and
## the user must go and read an error, while a cancellation means nothing is
## known about the code at all. Merging them is Verification-Harness-Traps §5a
## — *"a repair that gives an existing return value a new reason merges two
## events"* — so `BuildVerdict` is `BuildStatus` PLUS `bvCancelled`, mapped in
## one direction only, and `statusOf` is what converts for a consumer that
## wants the core's four.
##
## ## WHAT IS HERE AND WHAT IS IN `host/`
##
## Here: the state machine, the output ring, the verdict, and the CANCEL FLAG.
## In `host/build_runner.nim`: the process, and the poll loop that watches the
## flag. That split is the same one `app/runtime.nim` makes for the input loop,
## and it is what lets the whole verdict surface be asserted at Tier 1 with no
## compiler installed.
##
## ## THE INTERRUPT PATTERN IS `DapReadBound`'s, NAMED
##
## §5: *"CTUI-14 found that a stalled DAP handshake hung after the alt screen
## was claimed, with `Ctrl+c` unable to break out because `cfmakeraw` had
## cleared `ISIG` before the input loop started. … `DapReadBound`'s
## clock-and-interrupt pattern is the precedent and the requirement."* So a
## build carries BOTH bounds: a deadline for a session nobody is watching, and
## an interrupt for one somebody is. `BuildSession.requestCancel` is the second;
## `deadlineMs` is the first.

import std/strutils

import codetracer_embed

export BuildStatus

type
  BuildKind* = enum
    ## Which of §5's two triggers started this.
    ##
    ## A SEPARATE AXIS FROM THE VERDICT, because "the build failed" and "the run
    ## failed" are the same verdict about different work and a user reading the
    ## pane needs to know which one they are looking at.
    bkBuild = "build"
    bkRun = "run"

  BuildVerdict* = enum
    ## `BuildStatus` plus the one state a cancellable build needs. See the
    ## module header on why cancellation is not `bvFailed`.
    bvIdle = "idle"
    bvRunning = "running"
    bvSucceeded = "succeeded"
    bvFailed = "failed"
    bvCancelled = "cancelled"

  BuildSession* = ref object
    ## One build or run, from the command to the verdict.
    kind*: BuildKind
    command*: string
      ## The command line, as it will be run and as the pane shows it.
    verdict*: BuildVerdict
    exitCode*: int
      ## Meaningful only for `bvSucceeded` / `bvFailed`.
    lines*: seq[string]
      ## The output, oldest first, capped at `MaxBuildLines`.
    truncated*: bool
      ## Whether output was dropped. REPORTED: a pane that silently lost the
      ## first thousand lines of a compiler's output would hide the first
      ## error, which is the only line that matters.
    cancelRequested*: bool
      ## Set by `requestCancel`, read by the host's poll loop. A FLAG AND NOT A
      ## CALLBACK, so `app/` can ask for a cancellation without knowing a
      ## process exists.
    deadlineMs*: int64
      ## Wall-clock budget. `0` means no deadline.
    startedMs*: int64

const
  MaxBuildLines* = 2000
    ## The output ring's size. A compiler's output is unbounded and a terminal
    ## pane is not; 2000 lines is far past the first error and far short of a
    ## memory problem.

  DefaultBuildDeadlineMs* = 15 * 60 * 1000
    ## Fifteen minutes. Long enough for a real cold build, short enough that a
    ## session nobody is watching does not sit forever — which is the half of
    ## §5's requirement the keyboard cannot cover.

proc newBuildSession*(kind: BuildKind; command: string;
                      nowMs: int64 = 0;
                      deadlineMs = DefaultBuildDeadlineMs): BuildSession =
  BuildSession(kind: kind, command: command, verdict: bvIdle, exitCode: 0,
               lines: @[], truncated: false, cancelRequested: false,
               deadlineMs: deadlineMs, startedMs: nowMs)

proc start*(s: BuildSession; nowMs: int64) =
  if s.isNil:
    return
  s.verdict = bvRunning
  s.startedMs = nowMs
  s.cancelRequested = false

proc appendLine*(s: BuildSession; line: string) =
  if s.isNil:
    return
  if s.lines.len >= MaxBuildLines:
    s.lines.delete(0)
    s.truncated = true
  s.lines.add line

proc requestCancel*(s: BuildSession) =
  ## Ask for the build to stop. IDEMPOTENT and valid at any time: a user
  ## pressing the cancel key twice has not made a second request, and a request
  ## that arrives after the build finished must not resurrect it — which is why
  ## this sets a flag and `finish` is what decides the verdict.
  if not s.isNil:
    s.cancelRequested = true

proc expired*(s: BuildSession; nowMs: int64): bool =
  ## Whether the wall-clock budget is gone. The half of §5's requirement that
  ## covers a session nobody is watching.
  not s.isNil and s.verdict == bvRunning and s.deadlineMs > 0 and
    nowMs - s.startedMs > s.deadlineMs

proc finish*(s: BuildSession; exitCode: int) =
  ## The process ended. THE CANCEL FLAG WINS.
  ##
  ## A cancelled process exits non-zero (a signal, usually), and answering
  ## `bvFailed` for it would tell the user their code is broken when what
  ## happened is that they stopped the build. See the module header on why
  ## these are two states.
  if s.isNil:
    return
  s.exitCode = exitCode
  s.verdict =
    if s.cancelRequested: bvCancelled
    elif exitCode == 0: bvSucceeded
    else: bvFailed

proc statusOf*(verdict: BuildVerdict): BuildStatus =
  ## The CORE's four-state view, for a consumer that shares it with the desktop.
  ##
  ## `bvCancelled` maps onto `bsIdle` and NOT onto `bsFailed`: `build_vm`'s own
  ## documentation says `bsFailed` is "last build returned a non-zero exit code
  ## with output present", which is a claim about the code, and a cancelled
  ## build makes no claim about the code at all. The lossy direction is the
  ## only one that exists — nothing converts back — so the distinction cannot
  ## be lost by a round trip.
  case verdict
  of bvIdle, bvCancelled: bsIdle
  of bvRunning: bsRunning
  of bvSucceeded: bsSucceeded
  of bvFailed: bsFailed

proc describeVerdict*(s: BuildSession): string =
  ## The one line the status bar and the pane's header show.
  if s.isNil:
    return "no build has been run"
  let what = $s.kind
  case s.verdict
  of bvIdle: what & ": not started"
  of bvRunning: what & " running: " & s.command
  of bvSucceeded: what & " succeeded: " & s.command
  of bvFailed: what & " FAILED (exit " & $s.exitCode & "): " & s.command
  of bvCancelled: what & " cancelled: " & s.command

proc errorLines*(s: BuildSession): seq[string] =
  ## Output lines that look like a compiler diagnostic, so the pane can offer
  ## them first.
  ##
  ## A HEURISTIC, AND LABELLED AS ONE. It matches `path(line, col) Error:` —
  ## Nim's own shape — and the `error:` / `warning:` substring every
  ## GCC/Clang/rustc line carries. It decides what is OFFERED, never what is
  ## shown: the full output is always in `lines`, so a diagnostic this misses
  ## is one the user scrolls to rather than one they never see.
  result = @[]
  for line in s.lines:
    let lower = line.toLowerAscii
    if lower.contains("error:") or lower.contains(" error ") or
       lower.contains("warning:"):
      result.add line
