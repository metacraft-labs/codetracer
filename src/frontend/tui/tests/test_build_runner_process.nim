## test_build_runner_process.nim — PLAT-16, Tier 1, and the suite that closes a
## gap the milestone declared rather than measured.
##
## ## WHAT THIS FILE EXISTS FOR
##
## PLAT-16's status note said of `:build` / `:run` that **"no test runs a
## compiler"**, and filed that as an ungraded half. It was worse than ungraded:
## the process half did **the opposite of what its own header promised**.
##
## `host/build_runner.drain` was documented as moving the child's output into
## the session *"WITHOUT blocking"*, bounded by `MaxBytesPerPoll`. It read
## through `osproc.outputStream`, which on POSIX is a C `FILE*`, whose
## `readChar` BLOCKS on an open pipe with nothing in it — so a byte bound
## cannot fire when the first byte never arrives. Measured on 2026-09-14,
## against a child that says nothing for three seconds and then prints one
## line:
##
## ```
## verdict after start: running
##   poll 1: 3005 ms  changed=true  verdict=succeeded
## first poll took 3005 ms
## polls returning false while still running: 0
## ```
##
## `pollBuild` is called from the `dekIdle` arm of the front-end's event loop,
## so that is the whole TUI frozen for as long as the compiler is quiet: no key
## read, no repaint, and `:cancel` unreachable — **CTUI-14's defect, reproduced
## inside the module whose header cites CTUI-14 as its reason to exist**, and
## `deadlineMs` cannot save it because the deadline is only tested on re-entry
## to `pollBuild`, and the loop was inside the read.
##
## After the repair (`O_NONBLOCK` on `p.outputHandle`, and this module owning
## the buffer — `Verification-Harness-Traps.md` §8's remedy for the same
## standard library), the same probe reports:
##
## ```
## first poll took 0 ms
## polls returning false while still running: 150
## ```
##
## ## IT ASSERTS THE EFFECT, NOT THE MODEL
##
## `app/tests/test_edit_mode_build.nim` grades the verdict state machine with
## no process at all, and that is the right shape for a state machine. It
## cannot see this defect: every assertion it makes was true throughout. What
## sees it is a **real child that is deliberately silent**, and a COUNT of how
## many times the loop got back control while it was.
##
## **The count is the load-bearing assertion and the clock is the corroborating
## one**, deliberately (§12a): a wall-clock bound on a single measurement is a
## coin flip with one side hidden, while "how many times did control return"
## goes from 150 to 0 when the defect is restored and is not a statement about
## the scheduler. The clock assertions below are all quoted against a signal
## an order of magnitude larger than the noise, and each names it.
##
## ## No mocks
##
## Real `fork`/`exec` through `osproc`, real pipes, real `/bin/sh`. The only
## thing arranged is the child's *behaviour* — silence, then a line — which is
## the subject rather than a stand-in for it.
##
## ## Templates, not procs, for anything that calls `check`
## (`Verification-Harness-Traps.md` §13.)

import std/[monotimes, os, strutils, times, unittest]

import ../app/build_session
import ../host/build_runner

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 44

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  SilenceMs = 3000
    ## How long the silent child says nothing.
    ##
    ## THE SIGNAL, and every bound below is quoted against it. Three seconds is
    ## long enough that a blocking read is unmistakable (the defect reported
    ## 3005 ms for one poll) and short enough to sit in a Tier-1 lane.
  TickMs = 20
    ## The gap between polls, standing in for `main.IdlePollMs`. With this and
    ## `SilenceMs` a working drain gets control back about 150 times; a
    ## blocking one gets it back once, at the end.
  MinPollsWhileSilent = 20
    ## The floor on that count. Measured at ~150 on an idle host and **0** with
    ## the defect restored, so the floor is seven times below the observed
    ## value and infinitely above the broken one. A non-vacuity floor in §4's
    ## sense: without it, "the build eventually succeeded" is satisfied by the
    ## implementation that froze the terminal for three seconds.

type
  Observation = object
    polls: int
    pollsWhileRunning: int
    worstPollMs: int
    elapsedMs: int

proc observe(rb: RunningBuild; budgetMs: int;
             cancelAfterMs = -1): Observation =
  ## Poll `rb` the way the front-end's loop does, recording what came back.
  ##
  ## THE WORST SINGLE POLL IS KEPT, not the average: the failure this file is
  ## about is one poll that never returns, and an average over a hundred fast
  ## polls and one three-second one is still a small number.
  let start = getMonoTime()
  result = Observation()
  while (getMonoTime() - start).inMilliseconds < budgetMs:
    let before = getMonoTime()
    discard pollBuild(rb, nowMonoMs())
    let took = int((getMonoTime() - before).inMilliseconds)
    inc result.polls
    if took > result.worstPollMs:
      result.worstPollMs = took
    if rb.session.verdict != bvRunning:
      break
    inc result.pollsWhileRunning
    if cancelAfterMs >= 0 and
       (getMonoTime() - start).inMilliseconds >= cancelAfterMs:
      rb.session.requestCancel()
    sleep(TickMs)
  result.elapsedMs = int((getMonoTime() - start).inMilliseconds)

proc describe(o: Observation): string =
  "polls=" & $o.polls & " whileRunning=" & $o.pollsWhileRunning &
    " worstPollMs=" & $o.worstPollMs & " elapsedMs=" & $o.elapsedMs

# ---------------------------------------------------------------------------

suite "PLAT-16 §5: the build process, and the bound that makes it cancellable":

  test "a child that is SILENT for three seconds does not hold the loop":
    # THE CASE THIS FILE EXISTS FOR. See the module header for the two
    # measurements it sits between.
    let rb = startBuild(bkBuild, "sleep 3; echo done", getCurrentDir(),
                        nowMonoMs())
    # A POSITIVE CONTROL ON THE SPAWN (§4): everything below is a statement
    # about a running child, and a child that never started would satisfy some
    # of it for free.
    ck rb.session.verdict == bvRunning
    ck rb.session.lines.len == 0

    let o = observe(rb, budgetMs = SilenceMs * 4)
    checkpoint(describe(o))

    # ---- the assertion that moves from 150 to 0 -------------------------
    ck o.pollsWhileRunning >= MinPollsWhileSilent
    # …and the corroborating clock, quoted against `SilenceMs`. A single poll
    # may not consume a third of the child's whole silence; with the defect one
    # poll consumed ALL of it.
    ck o.worstPollMs < SilenceMs div 3

    # ---- and the output still arrives, whole ----------------------------
    # Non-blocking must not mean lossy, which is the failure a naive fix has.
    ck rb.session.verdict == bvSucceeded
    ck rb.session.exitCode == 0
    ck rb.session.lines == @["done"]
    ck not rb.session.truncated
    # The child really did take its three seconds: without this the case is
    # also satisfied by a `sleep` that did not sleep.
    ck o.elapsedMs >= SilenceMs

  test "a HUNG child is cancelled from the same loop, and the user gets the verdict":
    # §5's requirement in one case: *"A build that hangs must be cancellable."*
    # The child would run for sixty seconds; the cancel arrives after ~200 ms
    # and the loop must act on it. Sixty seconds against a two-second bound is
    # a 30× margin, so this is not a measurement of the scheduler.
    let rb = startBuild(bkBuild, "sleep 60", getCurrentDir(), nowMonoMs())
    ck rb.session.verdict == bvRunning
    let o = observe(rb, budgetMs = 10_000, cancelAfterMs = 200)
    checkpoint(describe(o))
    ck rb.session.verdict == bvCancelled
    ck o.elapsedMs < 2000
    ck o.worstPollMs < 1000
    # THE CANCELLATION IS SAID OUT LOUD in the pane, not only in the verdict.
    ck rb.session.lines.len >= 1
    ck rb.session.lines[0].contains("cancelled")
    # …and `describeVerdict` — what the status bar shows — names the command.
    ck describeVerdict(rb.session).contains("cancelled")
    ck describeVerdict(rb.session).contains("sleep 60")
    # A CANCELLED BUILD IS NOT A FAILED ONE. A `finish` that read only the exit
    # code would say `bvFailed` here, because a terminated process exits
    # non-zero — §5a's two events, held apart on a REAL signal rather than on a
    # number this suite chose.
    ck rb.session.verdict != bvFailed
    ck statusOf(rb.session.verdict) == bsIdle

  test "output written just before the child exits is not lost":
    # THE TAIL. `drain` is bounded per poll, and the poll that notices the exit
    # used to close the pipe immediately after — so everything past the bound
    # was discarded, which for a compiler is exactly the errors the user ran
    # `:build` to read. `pollBuild` now drains a second time, after the exit,
    # before it finishes the session.
    #
    # 20,000 lines is ~108 KB, comfortably past the 64 KiB per-poll bound, and
    # past `MaxBuildLines` too — so this also grades the ring: the FIRST lines
    # are the ones that may be dropped, and the drop is REPORTED.
    let rb = startBuild(bkBuild, "seq 1 20000", getCurrentDir(), nowMonoMs())
    let o = observe(rb, budgetMs = 30_000)
    checkpoint(describe(o) & " lines=" & $rb.session.lines.len)
    ck rb.session.verdict == bvSucceeded
    ck rb.session.lines.len == MaxBuildLines
    ck rb.session.truncated
    # THE LAST LINE THE CHILD WROTE IS THE LAST LINE IN THE PANE.
    ck rb.session.lines[^1] == "20000"
    ck rb.session.lines[0] == "18001"

  test "the deadline bounds a session nobody is watching, and is NOT a cancellation":
    # The other half of §5's pair, and the one no keyboard covers. A one-second
    # budget against a sixty-second child: the margin is the evidence.
    let rb = startBuild(bkBuild, "sleep 60", getCurrentDir(), nowMonoMs(),
                        deadlineMs = 1000)
    let o = observe(rb, budgetMs = 20_000)
    checkpoint(describe(o) & " -> " & describeVerdict(rb.session))
    ck o.elapsedMs < 5000
    # THE VERDICT SAYS A CLOCK DID THIS, NOT THE USER. `requestCancel` is
    # deliberately not called by the deadline path, so a user is never told
    # they stopped a build they did not.
    ck rb.session.verdict == bvFailed
    ck rb.session.verdict != bvCancelled
    ck not rb.session.cancelRequested
    ck rb.session.lines.len >= 1
    ck rb.session.lines[^1].contains("budget")
    ck rb.session.lines[^1].contains("1s")

  test "a failing child reports its exit code and its diagnostics":
    # The ordinary sad path, end to end through a real `sh -c`: stderr is
    # folded into the pane (`poStdErrToStdOut`), the exit code survives, and
    # `errorLines` offers the diagnostic.
    let rb = startBuild(bkBuild,
                        "echo 'a.nim(3, 5) Error: nope' >&2; echo fine; exit 3",
                        getCurrentDir(), nowMonoMs())
    discard observe(rb, budgetMs = 10_000)
    checkpoint(rb.session.lines.join(" | "))
    ck rb.session.verdict == bvFailed
    ck rb.session.exitCode == 3
    # BOTH STREAMS REACHED THE PANE, which is what `poStdErrToStdOut` is for
    # and what a front-end that let the child write on the inherited terminal
    # would have painted over its own alternate screen.
    ck "fine" in rb.session.lines
    let errors = errorLines(rb.session)
    ck errors.len == 1
    ck errors[0].contains("Error: nope")

  test "a line split across two reads is ONE line in the pane":
    # The framing the `pending` buffer exists for, driven by a child that
    # writes half a line, sleeps past several polls, and then finishes it.
    # Without the carry this is two lines and neither is what was printed.
    let rb = startBuild(bkBuild,
                        "printf 'half'; sleep 1; printf 'line\\n'; " &
                        "printf 'trailing-no-newline'",
                        getCurrentDir(), nowMonoMs())
    let o = observe(rb, budgetMs = 15_000)
    checkpoint(describe(o) & " lines=" & $rb.session.lines)
    ck rb.session.verdict == bvSucceeded
    # The straddle was rejoined…
    ck rb.session.lines[0] == "halfline"
    # …and the child's last write, which never got a newline at all, is not
    # silently dropped: a compiler killed mid-diagnostic is exactly the case
    # where the unterminated tail is the interesting part.
    ck rb.session.lines[^1] == "trailing-no-newline"
    ck rb.session.lines.len == 2
    # AND THE SLEEP IN THE MIDDLE DID NOT HOLD THE LOOP. This is the silent
    # child's assertion again, on a child that is silent only in the middle —
    # a second shape of the same subject, so the repair cannot be satisfied by
    # a special case for "has written nothing yet".
    ck o.pollsWhileRunning >= MinPollsWhileSilent

  test "a command the shell cannot run is a verdict, not an exception":
    # `sh -c` always starts, so this exercises 127 out of the shell rather than
    # the `OSError` arm — which is the honest thing to assert, because
    # `shellCommandFor` guarantees the exe exists.
    let rb = startBuild(bkBuild, "no-such-command-4a9f", getCurrentDir(),
                        nowMonoMs())
    discard observe(rb, budgetMs = 10_000)
    checkpoint(describeVerdict(rb.session) & " :: " &
               rb.session.lines.join(" | "))
    ck rb.session.verdict == bvFailed
    ck rb.session.exitCode == 127
    ck rb.session.lines.len >= 1

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
