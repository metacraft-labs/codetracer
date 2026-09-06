## test_real_signal_handling.nim — CTUI-14, Tier 2. SIGINT and SIGTERM during a
## live session.
##
## ## Why a SIGNAL is a different subject from a KEY, and needs its own file
##
## §4.2 binds `Ctrl+c` to "Quit Debugger — exit CodeTracer TUI session cleanly",
## and `cfmakeraw` clears `ISIG` precisely so that `0x03` arrives as a BYTE and
## reaches the keymap instead of the line discipline killing the process first.
## `tests/real_terminal/test_real_pty_lifecycle.nim` asserts that path.
##
## This file asserts the OTHER one: a signal that did not come from the
## keyboard. `kill -INT`, `kill -TERM`, a terminal window closing, a supervisor
## shutting a session down. Nothing in the application sees those — the input
## loop is not involved at all — and what has to survive them is
## `nim-termctl`'s async-signal-safe restore, installed by `enableRawMode` and
## running only `write(2)` and `tcsetattr`.
##
## The two are told apart HERE rather than assumed to be the same, because they
## take completely different code paths to the same screen:
##
##   | how it arrives            | who handles it                 | wait status |
##   |---------------------------|--------------------------------|-------------|
##   | `Ctrl+c` as a byte        | `app/input/keymap` -> `kaQuit` | exited, 0   |
##   | `SIGINT` as a signal      | nim-termctl's handler          | killed by 2 |
##   | `SIGTERM` as a signal     | nim-termctl's handler          | killed by 15|
##
## ## THE DOCUMENTED EXIT CODE FOR A SIGNAL IS DEATH BY THAT SIGNAL, measured
##
## The first version of this file asserted 130 and 143 — the shell's `128 + N`
## — and measured `-2` and `-15`. That is not a harness quirk to work around,
## it is the answer: **the front-end dies BY the signal**, after
## `nim-termctl`'s async-signal-safe restore has run, rather than converting it
## into an ordinary exit. `nim-pty` reports a `WIFSIGNALED` child as
## `-WTERMSIG(status)` (`nim_pty/posix.reapNonblocking`), and a shell reports
## the same wait status as `128 + N`; they are one fact in two encodings.
##
## Dying by the signal is also the RIGHT behaviour and not merely the observed
## one: a parent that sent `SIGTERM` learns from `WIFSIGNALED` that its child
## honoured it, and a child that had translated it into `exit(143)` would be
## indistinguishable from one that chose that status for its own reasons.
## `isonim-tui`'s own signal case asserts `130` because ITS fixture app installs
## a handler that calls `quit(130)`; this binary installs a restore and lets the
## signal through, which is a different — and better — contract.
##
## Asserting the NUMBER rather than "non-zero" is the point either way: a crash,
## a usage error and a signal are three different non-zero answers and only one
## of them is what this case is about.
##
## ## THE OBSERVABLE CLAIM IS THE PAIRED ALT-SCREEN LEAVE, not the termios
##
## The draft's "zero termios leakage" is not observable after the child exits —
## `test_real_pty_lifecycle.nim`'s header has the argument and isonim-tui's own
## suite records the same limit. What IS observable is that the restore RAN:
## `CSI ? 1049 l` appears in the byte stream, exactly once, after exactly one
## `CSI ? 1049 h`. A handler that had not been installed, or one that raced the
## exit, leaves the counts unequal.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[options, os, posix, strutils, times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 45

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Cols = 120
  Rows = 40
  KilledBySignal = -1
    ## The sign `nim-pty` gives a child that was KILLED rather than exited:
    ## `reapNonblocking` stores `-WTERMSIG(status)`. Spelled as a multiplier so
    ## the two cases below name one rule rather than two negative literals, and
    ## so the shape of the claim — "killed by exactly this signal" — is legible
    ## in the assertion itself.
  ShellSignalBase = 128
    ## What a SHELL would report for the same wait status (`128 + N`). Not what
    ## this harness reports; carried so the two encodings are named together and
    ## a reader coming from `$?` is not left converting.

var tracePath = ""

suite "CTUI-14 Tier 2: signals during a live session":

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

  test "SIGINT during a live session is killed by 2, alt screen paired":
    var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
    settleOnDebugger(sess, Cols, Rows)
    # THE SESSION IS GENUINELY LIVE, which is what "during an active session"
    # means and what makes the restore a restore rather than a no-op: the panes
    # are painted and the terminal is in raw mode on the alternate screen.
    let screen = sess.screenContents()
    ck screen.contains("SOURCE")
    ck screen.contains("CALL STACK")
    let before = altScreenCounts(sess)
    ck before.enters == 1
    ck before.leaves == 0

    sess.sendSignal(SIGINT)
    let status = sess.waitExit(initDuration(seconds = 30))
    let after = altScreenCounts(sess)
    checkpoint("SIGINT -> exit " &
               (if status.isSome: $status.get() else: "none") & ", alt " &
               $after.enters & "/" & $after.leaves)
    ck status.isSome
    # KILLED BY EXACTLY SIGINT. A `!= 0` here would be satisfied by the binary
    # having quit through the keymap, which is a completely different path and
    # is asserted in `test_real_pty_lifecycle.nim`; a `< 0` would be satisfied
    # by death on any signal at all, including a crash.
    ck status.get() == KilledBySignal * int(SIGINT)
    ck status.get() == -2
    # …and the same wait status is what a shell prints as `130`.
    ck ShellSignalBase - status.get() == 130
    ck after.enters == 1
    ck after.leaves == 1
    ck sess.transcriptDroppedBytes() == 0
    ck sess.transcriptBytes().contains(ShowCursorSequence)
    ck noSurvivingReplayServer()
    sess.close()

  test "SIGTERM during a live session is killed by 15, alt screen paired":
    # THE SECOND SIGNAL, and not a copy of the first: `SIGINT` is what a
    # keyboard interrupt becomes when `ISIG` is set and what `kill -INT` sends,
    # while `SIGTERM` is what a supervisor, a `kill` with no argument and a
    # closing session send. `nim-termctl` installs a handler for both and this
    # is what says so from outside the process.
    var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
    settleOnDebugger(sess, Cols, Rows)
    let before = altScreenCounts(sess)
    ck before.enters == 1
    ck before.leaves == 0

    sess.sendSignal(SIGTERM)
    let status = sess.waitExit(initDuration(seconds = 30))
    let after = altScreenCounts(sess)
    checkpoint("SIGTERM -> exit " &
               (if status.isSome: $status.get() else: "none") & ", alt " &
               $after.enters & "/" & $after.leaves)
    ck status.isSome
    ck status.get() == KilledBySignal * int(SIGTERM)
    ck status.get() == -15
    ck ShellSignalBase - status.get() == 143
    ck after.enters == 1
    ck after.leaves == 1
    ck sess.transcriptDroppedBytes() == 0
    ck sess.transcriptBytes().contains(ShowCursorSequence)
    ck noSurvivingReplayServer()
    sess.close()

  test "the two signals are distinguishable, and neither is the quit key":
    # THE ARM THAT MAKES THE TWO CASES ABOVE MEAN SOMETHING. Three exits, three
    # different codes, from three different mechanisms — asserted TOGETHER so a
    # binary that answered one number for every ending would redden here even
    # though each case above would still pass its own `isSome`.
    var codes: seq[int] = @[]
    var endings = 0
    for ending in ["key", "int", "term"]:
      var sess = tuiSession(@[tracePath], cols = Cols, rows = Rows)
      settleOnDebugger(sess, Cols, Rows)
      case ending
      of "key": sess.send("q")
      of "int": sess.sendSignal(SIGINT)
      else: sess.sendSignal(SIGTERM)
      let status = sess.waitExit(initDuration(seconds = 30))
      let counts = altScreenCounts(sess)
      checkpoint(ending & " -> exit " &
                 (if status.isSome: $status.get() else: "none") & ", alt " &
                 $counts.enters & "/" & $counts.leaves)
      ck status.isSome
      # EVERY ENDING LEAVES A PAIRED ALTERNATE SCREEN, which is the claim the
      # whole file is restated around and the one that is the same across all
      # three paths.
      ck counts.enters == 1
      ck counts.leaves == 1
      codes.add status.get()
      sess.close()
      inc endings
    checkpoint("endings exercised: " & $endings & ", codes: " & $codes)
    ck endings == 3
    ck codes.len == 3
    ck codes[0] == 0
    ck codes[1] == -2
    ck codes[2] == -15
    # THREE DISTINCT CODES. Written as a comparison rather than as three
    # equalities so the claim "these are distinguishable" is itself asserted.
    ck codes[0] != codes[1]
    ck codes[1] != codes[2]
    ck codes[0] != codes[2]
    ck noSurvivingReplayServer()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
