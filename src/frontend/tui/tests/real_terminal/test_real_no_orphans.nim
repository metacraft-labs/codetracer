## test_real_no_orphans.nim — CTUI-14, Tier 2. A hundred sessions leave nothing
## behind.
##
## ## What this asserts that no other suite does
##
## Every other lifecycle case in this tree looks at ONE session and asks whether
## it ended correctly. A leak is invisible that way: one orphaned
## `replay-server` per session is a clean-looking exit ninety-nine times and an
## exhausted machine on the hundredth. The claim here is cumulative, and the
## only way to make it is to run the loop.
##
## The pattern is `isonim-tui`'s `tests/real_terminal/test_real_special_cases.
## test_real_no_orphan_processes`, and it is followed rather than reinvented.
## Two things are STRONGER here, both because this binary has something
## isonim-tui's static app does not — a child of its own:
##
##   * **`waitpid` is drained rather than sampled.** isonim-tui checks
##     `waitpid(-1, …, WNOHANG) <= 0`, which is satisfied by `0` — the answer
##     that means "there are live children, and I will not block for them".
##     `lifecycle_support.reapableChildren` loops until the kernel says
##     `ECHILD` and returns the COUNT, so "there were three zombies" and "there
##     were none" are different numbers rather than the same `<= 0`.
##   * **`replay-server` is counted directly.** It is a GRANDCHILD of this
##     process — the TUI spawns it — so a leaked one is reparented to `init` and
##     `waitpid` in this process will never see it at all. `/proc` is walked for
##     it instead, against a baseline taken when the module loaded, so a
##     developer's own session in another terminal is not counted as this
##     suite's leak.
##
## ## THE DETECTOR ITSELF HAS A POSITIVE ARM
##
## "No orphans were found" is the check a broken detector passes most reliably.
## So one `replay-server` is deliberately started, found by the same function
## the sweep uses, and killed — and the sweep is only trusted afterwards.
##
## ## Why the hundred sessions are STALLED opens rather than full debugger runs
##
## The subject of an orphan test is the CHILD PROCESS LIFECYCLE, and the
## stalled-handshake path is the one that exercises it hardest: `replay-server`
## is spawned, the handshake raises, and the session is thrown away by an
## `except` rather than by the ordinary `close`. That is exactly the path that
## leaked before CTUI-14 — `newHeadlessDebugSession` had no reaping guard, so a
## handshake that raised left the child running with nobody holding it. It is
## also two orders of magnitude faster than a full open, which is what makes a
## hundred of them a test rather than a coffee break.
##
## Five FULL debugger sessions run afterwards, so the ordinary path is covered
## too and the hundred are not the only shape this file has ever seen.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[monotimes, options, os, osproc, posix, strutils, times, unittest]

import term_assert

import ../../app/cli
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 18

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Cols = 100
  Rows = 30
  Sessions = 100
    ## CTUI-14's own number. Asserted against the loop's own counter below, so
    ## a `break` or a `continue` that skipped a session reddens the file rather
    ## than quietly making the claim smaller.
  FullSessions = 5
  StallBudgetMs = 300
    ## The handshake budget for the hundred. Long enough that the DAP exchange
    ## before the stall completes on a loaded host, short enough that a hundred
    ## sessions is under a minute.

var tracePath = ""

suite "CTUI-14 Tier 2: a hundred sessions leave no unreaped children":

  test "the binary and the fixture this lane needs exist":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    ck dirExists(tracePath)
    ck fileExists(wedgeFolder() / "trace.bin")

  test "THE DETECTOR WORKS: a live replay-server is found, and then is not":
    # THE POSITIVE ARM. Without it, `survivingReplayServers().len == 0` is the
    # assertion a detector that always answers `@[]` passes best.
    let bin = replayServerPath()
    if bin.len == 0:
      checkpoint("no replay-server found; set REPLAY_SERVER_BIN, or build one" &
                 " with `cd src/db-backend && cargo build`")
    ck bin.len > 0

    # BEFORE: whatever was already running, and none of it is ours.
    checkpoint("survivors before: " & describeSurvivors())
    ck survivingReplayServers(graceMs = 0).len == 0

    let child = startProcess(bin, args = @["dap-server", "--stdio"],
                             options = {poStdErrToStdOut})
    # The process needs a moment to appear in `/proc` with its final `comm`.
    var found: seq[int] = @[]
    for _ in 0 ..< 100:
      found = survivingReplayServers(graceMs = 0)
      if found.len > 0:
        break
      sleep(20)
    checkpoint("detector found: " & $found)
    ck found.len == 1
    ck found[0] == child.processID

    child.terminate()
    discard child.waitForExit(timeout = 5000)
    child.close()
    # AND THEN IT IS GONE, through the same function. A detector that could
    # only ever answer "yes" would redden here.
    checkpoint("survivors after the kill: " & describeSurvivors())
    ck noSurvivingReplayServer()

  test "a hundred back-to-back sessions leave no orphan and no zombie":
    # Drain anything this process was already owed, so the count after the loop
    # is about the loop.
    let stragglers = reapableChildren()
    checkpoint("children reaped before the loop: " & $stragglers)

    let wedge = wedgeFolder()
    let started = getMonoTime()
    var ran = 0
    var exits: seq[int] = @[]
    for i in 0 ..< Sessions:
      var sess = tuiSession(@[wedge], cols = Cols, rows = Rows,
                            handshakeMs = StallBudgetMs)
      let status = sess.waitExit(initDuration(seconds = 30))
      if status.isSome:
        exits.add status.get()
      sess.close()
      inc ran
    let elapsedMs = (getMonoTime() - started).inMilliseconds
    checkpoint($ran & " sessions in " & $elapsedMs & " ms (" &
               $(elapsedMs div max(1, ran)) & " ms each)")
    # THE LOOP RAN ALL OF THEM. A `break` would otherwise make every claim
    # below true of a smaller number.
    ck ran == Sessions
    # …AND EVERY ONE OF THEM ENDED, with the code the stalled path publishes.
    # `exits.len == Sessions` is what says none of them was still running when
    # its session was closed.
    checkpoint("exit codes seen: " & $exits.len & " of " & $Sessions)
    ck exits.len == Sessions
    var wrongCode = 0
    for code in exits:
      if code != ExitEngineStalled:
        inc wrongCode
    checkpoint("sessions that did not exit " & $ExitEngineStalled & ": " &
               $wrongCode)
    ck wrongCode == 0

    # NO ZOMBIE OF OUR OWN: the pty children are all reaped.
    let leftover = reapableChildren()
    checkpoint("children still reapable after the loop: " & $leftover)
    ck leftover == 0
    # NO ORPHANED GRANDCHILD: every `replay-server` the hundred sessions
    # spawned is gone. This is the assertion `waitpid` structurally cannot
    # make, because a reparented process is not this process's child.
    let survivors = survivingReplayServers()
    checkpoint("surviving replay-server processes: " & $survivors)
    ck survivors.len == 0

  test "five FULL debugger sessions leave nothing behind either":
    # The ordinary path, so the hundred above are not the only shape asserted.
    # Five rather than a hundred because a full open is a `replay-server`
    # spawn plus a DAP handshake plus the first `stackTrace`, `ct/load-locals`
    # and `ct/event-load` — measured at 66 ms idle and tens of seconds on a
    # loaded host.
    discard reapableChildren()
    var ran = 0
    var clean = 0
    for i in 0 ..< FullSessions:
      var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
      settleOnDebugger(sess, Cols, Rows)
      sess.send("q")
      let status = sess.waitExit(initDuration(seconds = 30))
      let counts = altScreenCounts(sess)
      if status.isSome and status.get() == ExitOk and
         counts.enters == 1 and counts.leaves == 1:
        inc clean
      sess.close()
      inc ran
    checkpoint($ran & " full sessions, " & $clean & " with exit 0 and a" &
               " paired alternate screen")
    ck ran == FullSessions
    ck clean == FullSessions
    ck reapableChildren() == 0
    let survivors = survivingReplayServers()
    checkpoint("surviving replay-server processes: " & $survivors)
    ck survivors.len == 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
