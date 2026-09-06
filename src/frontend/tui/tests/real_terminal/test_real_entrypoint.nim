## test_real_entrypoint.nim — CTUI-0, Tier 2.
##
## ## Why a Tier-2 test exists at all in this milestone
##
## CodeTracer-TUI.milestones.org §"Testing architecture" states the reason
## plainly: without a real terminal the entire Tier-1 suite is
## self-referential, because the in-process harness both emits the ANSI and
## validates the screen it derived from that same emission. Every golden
## recorded from CTUI-2 onward is grounded in cross-tier equality, and CTUI-0
## is what declares the lane those tests will run in.
##
## A declared lane with no files in it is not a neutral placeholder. The lane
## runner fails an empty lane on purpose (`ERROR: lane '<id>' matched no files
## at all`), and the alternative — a recipe that reports success over zero
## files — is the vacuous pass this repository's whole test-lane machinery
## exists to prevent. So the lane is declared WITH the one Tier-2 assertion
## CTUI-0 can honestly make: that the entrypoint this milestone delivers
## behaves the same way through a real pty, parsed by a real terminal state
## machine, as it does through a pipe.
##
## That is a smaller claim than CTUI-2's cross-tier snapshot equality, and it
## is deliberately not dressed up as more: there is no composited screen yet to
## compare. What it does establish, once, is that the harness, the pty and the
## binary genuinely compose on this host — so when CTUI-2 writes the
## equivalence test, a failure there is about the compositor rather than about
## the plumbing.
##
## ## It does not skip
##
## The binary is a prerequisite, not an excuse: a missing `build/bin/
## codetracer-tui` fails this suite by name and names the recipe that builds
## it. `just test-tui-real-terminal` depends on `build-tui`, so on a correct
## run the binary is always there.

## ## What it asserts, and what it deliberately does not repeat
##
## Four cases, and each makes a claim the others do not. In particular the
## binary's existence is asserted ONCE, in the case that exists to report it:
## repeating `fileExists` in every case afterwards counts as four assertions
## and establishes one fact, and a suite that pads its own total is a suite
## whose total means nothing. The cases that follow spawn the binary, so a
## binary that vanished between them fails them by spawning, loudly.

import std/[options, os, strutils, times, unittest]

import term_assert

# The product's own strings, so what the terminal shows is compared with what
# the binary was built to print rather than with a shape. `cli.nim` imports
# `std/strutils` and `src/ct/version` and nothing else — no renderer, no
# grammar archive — so reaching it from here costs this lane nothing.
import ../../app/cli
import ../../../../ct/version

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling, and inside a `const` block the declaration is invisible to it.
const ExpectedAssertions = 17

const BuildRecipe = "just build-tui"

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let tuiBinary = repoRoot() / "build" / "bin" / "codetracer-tui"

suite "CTUI-0 Tier 2: the entrypoint through a real pty":

  test "the binary this lane tests exists and can be executed":
    # First, and separately, so a missing build reports as a missing build
    # rather than as a spawn failure inside libvterm several assertions later.
    # This is the ONLY case that asserts it; see the note at the top of the
    # file.
    if not fileExists(tuiBinary):
      checkpoint("missing " & tuiBinary & " — run `" & BuildRecipe & "`")
    ck fileExists(tuiBinary)
    if fileExists(tuiBinary):
      # `fileExists` is true of a zero-byte file and of one nothing may run.
      # Both spawn, and both report through libvterm as an empty screen, which
      # is the least legible way for a build defect to arrive.
      let perms = getFilePermissions(tuiBinary)
      checkpoint("binary: " & $getFileSize(tuiBinary) & " bytes, perms " & $perms)
      ck fpUserExec in perms

  test "--version reaches a real terminal's screen":
    var sess = newTuiTest(tuiBinary, @["--version"]).width(80).height(24).spawn()
    sess.waitForText("codetracer-tui", initDuration(seconds = 10))
    let screen = sess.screenContents()
    checkpoint("screen: " & screen.strip())
    # The positive control on the scan: a screen that parsed to nothing
    # satisfies every "contains" written over it only by going red here first.
    ck screen.strip().len > 0
    ck screen.contains("codetracer-tui")
    # THE VERSION ITSELF, not the shape of one. `screen.contains(".")` was true
    # of any screen with a full stop anywhere on it — including the help text,
    # a stack trace, or a shell prompt — so it asserted that SOMETHING was
    # printed rather than that the product's version was. `CodeTracerVersionStr`
    # is what `cli.nim` builds `TuiVersionText` out of, so this is the compiled
    # binary's own version read back through a pty and a terminal state machine.
    checkpoint("expected version: " & CodeTracerVersionStr)
    ck screen.contains(CodeTracerVersionStr)
    let status = sess.waitExit(initDuration(seconds = 10))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "--help reaches a real terminal's screen, in full":
    var sess = newTuiTest(tuiBinary, @["--help"]).width(100).height(40).spawn()
    sess.waitForText("usage:", initDuration(seconds = 10))
    let screen = sess.screenContents()
    checkpoint("screen: " & screen.strip())
    # EVERY LINE, not two needles. The help text is a `const` in `app/cli.nim`,
    # so the whole of it is knowable here — and a Tier-2 claim about it that
    # checked two substrings would pass over a screen that had truncated,
    # scrolled away or wrapped the rest. 100x40 is chosen so it cannot: the
    # longest line is 77 columns and the text is 14 rows.
    var checkedLines = 0
    var missing: seq[string] = @[]
    for rawLine in TuiHelpText.splitLines():
      let line = rawLine.strip()
      if line.len == 0:
        continue
      inc checkedLines
      if not screen.contains(line):
        missing.add(line)
    # The non-vacuity floor (Verification-Harness-Traps §4b): `missing.len == 0`
    # is satisfied by a loop that inspected nothing, which is what a
    # `TuiHelpText` that stopped resolving would produce.
    checkpoint("help lines checked: " & $checkedLines)
    ck checkedLines >= 8
    if missing.len > 0:
      checkpoint("help lines absent from the terminal: " & missing.join(" | "))
    ck missing.len == 0
    let status = sess.waitExit(initDuration(seconds = 10))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "on a real tty the entrypoint does not report a missing terminal":
    # THE ONE THING ONLY TIER 2 CAN SEE, and the campaign's rule says so:
    # anything involving the terminal as a peer is asserted here and nowhere
    # else. `host/native_host.stdoutIsTerminal` is `isatty(STDOUT_FILENO)`, so
    # every in-process harness — which reads a pipe — necessarily observes the
    # FALSE branch. Only a pty can observe the true one.
    #
    # WHAT CTUI-11 CHANGED HERE, and why the assertion moved rather than being
    # deleted. Before the driver existed this case ran the entrypoint on a
    # directory that is not a trace and asserted exit 3 — the "opening a trace
    # needs a terminal driver this milestone does not build yet" refusal. That
    # refusal is gone: `main.nim` now negotiates the terminal and then decides
    # whether the folder is a recording at all. A directory that is not one is
    # refused as a USAGE error (2), NAMING THE FOLDER AND WHAT IS MISSING FROM
    # IT, before the tty is claimed.
    #
    # That ORDER is itself the assertion, and it was written from a hang.
    # Checking the shape after `driver.start()` left this very command with the
    # alternate screen claimed, `opening ...` on the status line, and no input
    # loop yet running: `replay-server` exits 2 on a folder it cannot open and
    # writes no DAP at all, so the handshake's blocking read never returned and
    # no key could end it. `host/native_host.traceFolderProblem` is the `stat`
    # that now runs first.
    #
    # Exit 3 still exists and still means "there is no screen here"; it is
    # asserted in `test_real_capability_negotiation.nim`, which runs the binary
    # with its stdout redirected to a file. The claim this case makes is the one
    # only a pty can make: on a REAL terminal that branch is not taken.
    #
    # 200 columns deliberately: the entrypoint's diagnostics are one long line
    # each, and a wrapped line would let the negative assertion below pass
    # because the needle straddled a row boundary rather than because the note
    # was absent.
    var sess = newTuiTest(tuiBinary, @[repoRoot()]).width(200).height(24).spawn()
    let status = sess.waitExit(initDuration(seconds = 30))
    discard sess.drainOutput(60)
    let screen = sess.screenContents()
    checkpoint("screen: " & screen.strip())
    # THE POSITIVE TWIN of the negative assertion below, through the same
    # stream and the same run: if stderr never reached the terminal, this goes
    # red rather than leaving "does not contain" true for free.
    ck screen.contains("codetracer-tui:")
    ck status.isSome
    ck status.get() == 2
    # The refusal names the folder AND what is missing from it, so a user
    # learns which argument was wrong and why rather than that "something" was.
    ck screen.contains(repoRoot())
    ck screen.contains("not a CodeTracer recording")
    # AND THE TERMINAL WAS GIVEN BACK. `driver.stop()` runs on this path before
    # anything is written to stderr, so the message lands on the ordinary
    # screen rather than inside the alternate one — where it would vanish with
    # it and the user would see nothing at all.
    ck not screen.contains("note: standard output")
    sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
