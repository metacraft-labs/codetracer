## test_real_pty_lifecycle.nim — CTUI-14, Tier 2. The terminal is given back,
## on every path this milestone knows how to reach — including the one that used
## to wedge it.
##
## ## THE CLAIM IS RESTATED, AND IT STAYS RESTATED
##
## The draft asked for "zero termios leakage". **That is not observable**, and
## saying so is CTUI-14's own correction rather than a concession made here:
## the slave side of a pty's termios is not reliably introspectable after the
## child has exited, which `isonim-tui`'s `tests/real_terminal/
## test_real_special_cases.nim` records in its own signal case ("we don't
## compare `stty -a` because the slave side of the pty's termios state isn't
## reliably introspectable post-exit"). A suite that asserted it would either be
## reading the master's termios and calling it the slave's, or asserting
## something a passing run cannot distinguish from a failing one.
##
## So the claim is what IS observable, and all three parts of it are asserted
## here:
##
##   1. **A PAIRED ALTERNATE SCREEN.** `CSI ? 1049 h` and `CSI ? 1049 l`, counted
##      in the child's raw byte stream. Counted rather than looked for, because
##      "the leave was sent" is satisfied by a stream with two enters and one
##      leave. The transcript is `TermAssert`'s new `.transcript()` recorder,
##      added by this milestone for exactly this claim: a terminal's LIVE
##      alt-screen state after the child has gone says nothing about whether
##      both sequences were sent, which is the same "live flag, not a latch"
##      property CTUI-11 recorded about DEC 2026.
##   2. **A CLEAN EXIT CODE**, and the RIGHT one — `main.nim` publishes four,
##      and "non-zero" would be satisfied by a crash.
##   3. **NO SURVIVING CHILD**, which for this binary means `replay-server`.
##      `tests/real_terminal/test_real_no_orphans.nim` owns that at a hundred
##      sessions; this file asserts it once per case, because a session that
##      leaked one would otherwise report as a clean exit.
##
## Restoration BEYOND those three needs an outer harness that owns the tty
## before the pty exists, and is explicitly out of scope rather than falsely
## asserted.
##
## ## THE WEDGE, WHICH IS WHY THIS FILE IS THE ONE THAT CARRIES THE DEFECT
##
## CTUI-11 closed one door: `replay-server` exits 2 and writes no DAP at all
## for a folder it cannot open, so `host/native_host.traceFolderProblem` `stat`s
## for the three trace shapes before the tty is claimed. CTUI-14 found the same
## failure arriving through another: **a folder with a recording's SHAPE that
## stalls the handshake**. Reproduced with a garbage `trace.bin`, and the
## reproduction is exact — `replay-server` answers `initialize`,
## `configurationDone` and `launch` IN FULL (`Content-Length: 102`, all 102
## bytes, `success: true`), and then never sends the `stopped` event the
## handshake waits for, and never exits. The old blocking read never
## returned, behind an alternate screen the driver had already claimed, with
## `ISIG` cleared by `cfmakeraw` and no input loop running — so `Ctrl+c` reached
## nothing.
##
## Both halves of the fix are asserted below, and each is PINNED BY A CHECK THAT
## REDDENS:
##
##   * the CLOCK, pinned by running the same folder under two different budgets
##     and asserting that the exit time TRACKS THE BUDGET. An implementation
##     that ignored `CODETRACER_TUI_HANDSHAKE_MS`, or that ended the session for
##     some other reason, produces the same duration twice and fails.
##   * the ESCAPE HATCH, pinned by sending `Ctrl+c` while the budget is set far
##     longer than the test's own patience: the session must end in well under
##     the budget, which is only possible if the key reached the read.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[monotimes, options, os, strutils, times, unittest]

import term_assert

import ../../app/cli
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 59

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Cols = 120
  Rows = 40
  ShortBudgetMs = 1500
  LongBudgetMs = 6000
    ## The two handshake budgets the clock is pinned with. Far enough apart
    ## that scheduling noise on a loaded host cannot make the shorter run look
    ## like the longer one, and both short enough that the case is seconds
    ## rather than a minute.
  ClockToleranceMs = 500
    ## HOW FAR THE MEASURED GAP MAY SIT FROM THE BUDGET GAP, and it is a
    ## measurement tolerance rather than slack in the claim.
    ##
    ## Each run costs `budget + overhead`, where the overhead is the spawn, the
    ## `nix`-free exec, the DAP round trips before the stall and the exit. The
    ## measured gap is therefore `4500 + (overhead_long - overhead_short)`, and
    ## THAT DIFFERENCE HAS EITHER SIGN — which is how this case first failed:
    ## overheads of 26 ms and 25 ms gave a gap of 4499 against an assertion of
    ## `gap >= 4500`. The old comment said "a loaded host makes this LARGER,
    ## never smaller", and that is false: load acts on both runs independently.
    ##
    ## 500 ms is nine times below the 4500 ms signal, so the failure this case
    ## exists to catch — a duration that does not depend on the budget at all,
    ## which gives a gap near ZERO — is still rejected by 4000 ms. Each run's
    ## own overhead is asserted to be inside this tolerance too, so the
    ## tolerance cannot be quietly absorbing a real regression: if the overhead
    ## ever grew to the point where it could explain the gap, the run reporting
    ## it fails first and by name.

var tracePath = ""

suite "CTUI-14 Tier 2: the pty lifecycle, and the wedge that used to end it":

  test "the binary and the fixture this lane needs exist":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      # NOT A SKIP. `docs/tui-testing.md` rule 1: a missing prerequisite fails
      # by name and names the recipe that produces one.
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    checkpoint("trace: " & tracePath)
    ck dirExists(tracePath)
    # THE GARBAGE FOLDER IS BUILT HERE, once, and it is built rather than
    # checked in: a 4 KB file of urandom in a repository would be a fixture
    # nobody could read, and the property that matters — "shape-valid, and not
    # a recording" — is what the construction says out loud.
    let wedge = wedgeFolder()
    checkpoint("shape-valid non-recording: " & wedge)
    ck fileExists(wedge / "trace.bin")
    ck getFileSize(wedge / "trace.bin") == WedgeBytes

  test "a session quit with `:quit` exits 0 with a paired alternate screen":
    # §4.3's `quit` command, typed at the `:` prompt, which is the exit path
    # the milestone names. `q` and `Ctrl+c` reach the same `kaQuit`; this one
    # goes through the command interpreter, so it also proves the prompt is
    # usable on a real terminal at the moment the session ends.
    var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
    settleOnDebugger(sess, Cols, Rows)
    let beforeQuit = altScreenCounts(sess)
    checkpoint("before quit: " & $beforeQuit.enters & " enter(s), " &
               $beforeQuit.leaves & " leave(s)")
    # THE ENTER IS OBSERVABLE AND THE LEAVE HAS NOT HAPPENED YET, which is what
    # makes the pair below a pair rather than a coincidence.
    ck beforeQuit.enters == 1
    ck beforeQuit.leaves == 0

    sess.send(":quit\r")
    let status = sess.waitExit(initDuration(seconds = 30))
    checkpoint("exit: " & (if status.isSome: $status.get() else: "none"))
    ck status.isSome
    ck status.get() == ExitOk
    let after = altScreenCounts(sess)
    checkpoint("after quit: " & $after.enters & " enter(s), " &
               $after.leaves & " leave(s); transcript " &
               $sess.transcriptBytes().len & " bytes, " &
               $sess.transcriptDroppedBytes() & " dropped")
    # A TRUNCATED TRANSCRIPT WOULD MAKE THE COUNTS BELOW UNSOUND.
    ck sess.transcriptDroppedBytes() == 0
    ck after.enters == 1
    ck after.leaves == 1
    # …and the cursor was given back, which is the third sequence the restore
    # writes and the one a user notices when it is missing.
    ck sess.transcriptBytes().contains(ShowCursorSequence)
    ck noSurvivingReplayServer()
    sess.close()

  test "`q` and Ctrl+c reach the same clean exit through the same restore":
    # THE OTHER TWO QUIT KEYS §4.2 binds, so `:quit` above is one path of three
    # rather than the only one that was ever tried. Both are asserted on the
    # SAME three observables, because "it exited" is not the claim.
    var paths = 0
    for key in ["q", "\x03"]:
      var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
      settleOnDebugger(sess, Cols, Rows)
      sess.send(key)
      let status = sess.waitExit(initDuration(seconds = 30))
      let counts = altScreenCounts(sess)
      checkpoint("key " & escape(key) & " -> exit " &
                 (if status.isSome: $status.get() else: "none") &
                 ", alt " & $counts.enters & "/" & $counts.leaves)
      ck status.isSome
      ck status.get() == ExitOk
      ck counts.enters == 1
      ck counts.leaves == 1
      ck sess.transcriptDroppedBytes() == 0
      sess.close()
      inc paths
    checkpoint("quit paths exercised: " & $paths)
    ck paths == 2
    ck noSurvivingReplayServer()

  test "THE WEDGE: a stalled handshake ends on the clock, not on the user":
    # The folder passes every `stat` `traceFolderProblem` makes — it holds a
    # `trace.bin` — and `replay-server` accepts it and then stops answering.
    # Before CTUI-14 this hung for ever with the alternate screen claimed.
    let wedge = wedgeFolder()
    let started = getMonoTime()
    var sess = tuiSession(@[wedge], cols = Cols, rows = Rows,
                          handshakeMs = ShortBudgetMs)
    let status = sess.waitExit(initDuration(seconds = 30))
    let elapsedMs = (getMonoTime() - started).inMilliseconds
    let counts = altScreenCounts(sess)
    let screen = sess.screenContents()
    checkpoint("exit " & (if status.isSome: $status.get() else: "none") &
               " after " & $elapsedMs & " ms; alt " & $counts.enters & "/" &
               $counts.leaves)
    ck status.isSome
    # EXIT 4 EXACTLY. `main.nim` separates "this folder is not a recording" (2,
    # refused before the tty is claimed) from "the engine stopped answering",
    # and a `!= 0` here would be satisfied by the binary crashing.
    ck status.get() == ExitEngineStalled
    # THE ALTERNATE SCREEN WAS CLAIMED AND GIVEN BACK. The claim is what made
    # the old failure unrecoverable, and it is deliberately still made: the
    # user sees `opening …` while the engine is asked.
    ck counts.enters == 1
    ck counts.leaves == 1
    ck sess.transcriptDroppedBytes() == 0
    # …and the diagnosis is on the ORDINARY screen, naming what to do.
    checkpoint("last screen: " & strutils.strip(screen))
    ck screen.contains("stopped answering")
    ck screen.contains("replay-server")
    ck noSurvivingReplayServer()
    sess.close()

  test "THE CLOCK IS REAL: the exit time tracks the budget it was given":
    # THE CHECK THAT PINS THE FIX. A binary that ended the stalled session for
    # any other reason — the engine exiting, a read error, a fixed internal
    # timeout — produces the same duration under both budgets. Two runs, and
    # the assertion is on the DIFFERENCE.
    let wedge = wedgeFolder()
    var durations: seq[int64] = @[]
    for budget in [ShortBudgetMs, LongBudgetMs]:
      let started = getMonoTime()
      var sess = tuiSession(@[wedge], cols = Cols, rows = Rows,
                            handshakeMs = budget)
      let status = sess.waitExit(initDuration(seconds = 60))
      let elapsedMs = (getMonoTime() - started).inMilliseconds
      checkpoint("budget " & $budget & " ms -> exit " &
                 (if status.isSome: $status.get() else: "none") & " after " &
                 $elapsedMs & " ms")
      ck status.isSome
      ck status.get() == ExitEngineStalled
      # NOT BEFORE THE BUDGET. A clock that fired early would be a clock that
      # could cut a slow-but-working engine off.
      ck elapsedMs >= budget
      # AND NOT LONG AFTER IT. This run's own overhead — spawn, exec, the DAP
      # round trips before the stall, the exit — is what the gap assertion
      # below tolerates, so it is asserted here rather than assumed. An
      # overhead that grew large enough to explain the gap on its own reddens
      # this line first, which is what stops the tolerance below from becoming
      # a place for a regression to hide.
      ck elapsedMs - budget <= ClockToleranceMs
      durations.add elapsedMs
      sess.close()
    ck durations.len == 2
    let gap = durations[1] - durations[0]
    checkpoint("short " & $durations[0] & " ms, long " & $durations[1] &
               " ms, difference " & $gap & " ms (budgets differ by " &
               $(LongBudgetMs - ShortBudgetMs) & " ms)")
    # THE MEASURED GAP IS THE BUDGET GAP, within the measurement's own noise,
    # AND THE ASSERTION IS TWO-SIDED.
    #
    # It used to read `gap >= LongBudgetMs - ShortBudgetMs` on the argument
    # that "a loaded host makes this LARGER, never smaller". That argument is
    # wrong — the two runs pay their overheads independently, so the gap is
    # `4500 + (overhead_long - overhead_short)` and the bracket has either
    # sign. It failed at 4499 ms with overheads of 26 ms and 25 ms.
    #
    # Two-sided is also STRICTLY STRONGER than what it replaces, not weaker:
    # `gap >= 4500` accepted an arbitrarily large gap, so a long run that hung
    # for an extra ten seconds passed it. What the case is for is that the
    # duration TRACKS THE BUDGET, and a budget-independent implementation puts
    # the gap near zero — rejected here by 4000 ms.
    let drift = abs(gap - (LongBudgetMs - ShortBudgetMs))
    checkpoint("drift from the budget gap: " & $drift & " ms (tolerance " &
               $ClockToleranceMs & " ms, signal " &
               $(LongBudgetMs - ShortBudgetMs) & " ms)")
    ck drift <= ClockToleranceMs
    # NON-VACUITY: the tolerance must stay far below the signal, or the line
    # above stops distinguishing "tracks the budget" from anything at all.
    ck ClockToleranceMs * 4 < LongBudgetMs - ShortBudgetMs
    ck noSurvivingReplayServer()

  test "THE ESCAPE HATCH IS REAL: Ctrl+c ends a stalled open at once":
    # The half of the fix that answers an ATTENDED session. The budget is set
    # far longer than this case is willing to wait, so an exit inside it is
    # only possible if the keystroke reached the read — which is the whole
    # point: `cfmakeraw` has cleared `ISIG`, so `Ctrl+c` is a byte on an fd
    # that nothing was reading before CTUI-14.
    let wedge = wedgeFolder()
    const Budget = 60_000
    var sess = tuiSession(@[wedge], cols = Cols, rows = Rows,
                          handshakeMs = Budget)
    # Wait for FRAME 0 — the alternate screen claimed and `opening …` painted —
    # so the key is sent while the process is inside the handshake rather than
    # before it has started one.
    waitForOpeningFrame(sess, Cols, Rows)
    ck altScreenCounts(sess).enters == 1
    let started = getMonoTime()
    sess.send("\x03")
    let status = sess.waitExit(initDuration(seconds = 20))
    let elapsedMs = (getMonoTime() - started).inMilliseconds
    let counts = altScreenCounts(sess)
    checkpoint("Ctrl+c during a stalled open -> exit " &
               (if status.isSome: $status.get() else: "none") & " after " &
               $elapsedMs & " ms, alt " & $counts.enters & "/" &
               $counts.leaves)
    ck status.isSome
    # THE USER ENDED IT, so it is not a failure — the same status `q` produces
    # everywhere else in this program.
    ck status.get() == ExitOk
    # AND IT IS THE KEY, NOT THE CLOCK. Two orders of magnitude inside the
    # budget; a run that waited the clock out could not reach here.
    ck elapsedMs < Budget div 4
    ck counts.enters == 1
    ck counts.leaves == 1
    ck sess.screenContents().contains("cancelled")
    ck noSurvivingReplayServer()
    sess.close()

  test "a folder that is not a recording at all still refuses before the tty":
    # CTUI-11's DOOR, re-asserted here because CTUI-14 changed the code around
    # it: the two failures are told apart by the exit code AND by whether the
    # alternate screen was ever claimed, and a change that made the cheap
    # refusal go through the expensive path would be invisible in the exit code
    # alone.
    var sess = tuiSession(@[lifecycle_support.repoRoot()], cols = Cols,
                          rows = Rows)
    let status = sess.waitExit(initDuration(seconds = 20))
    let counts = altScreenCounts(sess)
    let screen = sess.screenContents()
    checkpoint("checkout root -> exit " &
               (if status.isSome: $status.get() else: "none") & ", alt " &
               $counts.enters & "/" & $counts.leaves & ": " &
               strutils.strip(screen))
    ck status.isSome
    ck status.get() == ExitUsage
    # NOT CLAIMED AT ALL, which is the whole difference from the case above.
    ck counts.enters == 0
    ck counts.leaves == 0
    ck screen.contains("not a CodeTracer recording")
    sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
