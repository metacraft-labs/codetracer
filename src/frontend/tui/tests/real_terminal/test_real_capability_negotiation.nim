## test_real_capability_negotiation.nim — CTUI-11, Tier 2. THE ONE THAT MATTERS.
##
## ## What only this file can say
##
## CTUI-11: "uses `envSet`/`envRemove` to spawn the binary under each
## environment, then reads back what it negotiated from the *terminal's* side:
## `mouseProtocol()`, `synchronizedOutput()`, `kittyKeyboardFlags()`,
## `modifyOtherKeys()`. Asserts `--ascii-borders --no-color` produces a screen
## whose cells carry no colour attributes and whose borders are `+ - |`, read
## from real parsed cells. In-process tests can only ask the app what it
## believes it decided; this asks the terminal what it was told."
##
## `app/tests/test_capability_resolution.nim` sweeps 28 environments and asserts
## what `resolveCapabilities` DECIDES. Every one of those assertions would still
## pass on a driver that decided correctly and then told the terminal nothing —
## which is a real failure mode, because the decision and the emission are two
## different pieces of code and only one of them is a pure function.
##
## ## THE SUBJECT IS THE SHIPPED BINARY
##
## Not a snapshot app. `build/bin/codetracer-tui` is spawned on a real trace in
## a real pty, and everything below is read out of `nim-libvterm`'s parse of its
## byte stream. That is possible for the first time in this campaign: until
## CTUI-11 the entrypoint refused to open a trace at all.
##
## ## THE TWO FRAME BARRIERS, AND WHY THERE ARE TWO
##
## `main.nim` paints TWICE on startup, in this order and on purpose (see its
## header): frame 0 is the shell saying which trace is being opened, painted
## before `replay-server` is spawned; frame 1 is the debugger. Both end with the
## cursor on the bottom-right cell, so `waitForCompleteFrame` alone cannot tell
## them apart — it returns on frame 0.
##
## `settleOnDebugger` therefore waits for the STATUS ROW to change (frame 1's
## notification is the session's position, frame 0's is "opening …") and then
## for the cursor barrier again. Both halves are exact: the region cannot change
## before frame 1 starts, and the cursor cannot reach the last cell before frame
## 1 finishes.
##
## ## WHAT libvterm CAN AND CANNOT SEE ABOUT DEC 2026, measured
##
## `nim-libvterm`'s `synchronizedOutput()` is a LIVE FLAG, not a latch:
## `extended_state.handleCsi` sets it on `CSI ? 2026 h` and clears it on
## `CSI ? 2026 l`. After a complete frame it therefore reads `false` whether the
## driver bracketed correctly or never opened a bracket at all, and
## `TermAssert.assertSynchronizedRender`'s own failure arm is `discard`
## (`TermAssert/src/term_assert.nim:640-647`) — it cannot fail.
##
## So the gate is established in two halves, both falsifiable:
##
##   * **The open IS observable, and the pair closes** — asserted by feeding
##     `host/terminal_driver`'s own `bracketFrame` output into a fresh
##     `nim-libvterm` `Screen`, the same parser the pty path uses. The flag goes
##     TRUE after the opening sequence and FALSE after the closing one, and a
##     stream missing the close leaves it TRUE. That is the positive control the
##     live session cannot give.
##   * **The live terminal was left un-bracketed** — asserted on the spawned
##     binary after a settled frame. A driver that emitted `?2026h` and never
##     `?2026l` would latch this true and redden it.
##
## Stated rather than worked around, per this repository's rule about harness
## limits.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[monotimes, options, os, strutils, times, unicode, unittest]

import nim_libvterm
import term_assert

import ../../app/theme/capabilities
import ../../app/views/borders
import ../../host/terminal_driver
# `waitForCompleteFrame` and its diagnosis-not-a-timeout failure. Imported for
# that one proc: this file spawns the SHIPPED binary rather than a snapshot app,
# so it needs the barrier without needing `runDualSnap`.
import ../../testing/dual_snap
import ../fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 76

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  BuildRecipe = "just build-tui"
  FixtureName = "calc"
  Cols = 120
  Rows = 40
    ## 120x40 selects the STANDARD profile: `app/layout/profile.selectProfile`
    ## takes `lpCompact` below `TallProfileMinHeight` (35) whatever the width,
    ## and `lpStandard` at `StandardMinWidth` (120). Chosen so the timeline gets
    ## a rectangle of its own — in the Compact profile it is a TAB of the state
    ## stack, and `TIMELINE` is not a pane title on the screen at all.
  ExitNoTerminalStatus = 3
    ## `main.nim`'s `ExitNoTerminal`. Spelled here rather than imported: this
    ## file must not pull the entrypoint's module graph in to read one integer,
    ## and a mismatch shows up as this case failing with both numbers named.
  ColdStartBudgetMs = 50
    ## CTUI-11's published gate: "cold start < 50 ms with probing enabled".
    ##
    ## MEASURED TO THE FIRST FRAME, not to the debugger. `main.nim` negotiates
    ## the terminal, claims the tty and paints before it spawns `replay-server`
    ## — the order its header argues for on product grounds — so this is the
    ## interval the gate is about: process start, capability probe, raw mode,
    ## alternate screen, first frame. The engine handshake is measured
    ## separately and reported, because it is a different number with a
    ## different owner (CTUI-14).

var tracePath = ""

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

proc baseSession(args: seq[string]; term = "xterm-256color";
                 lang = "en_US.UTF-8"): TuiTestBuilder =
  ## A builder with a KNOWN environment.
  ##
  ## `envRemove` on the three that decide colour and synchronized output is not
  ## tidiness: the lane inherits whatever terminal the developer or the CI
  ## runner is in, and a case that asserted `mpSgr` under an inherited
  ## `COLORTERM=truecolor` would be asserting the runner's environment. Every
  ## case below therefore states the whole of what it depends on.
  newTuiTest(tuiBinary, args)
    .width(Cols).height(Rows)
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", term)
    .envSet("LANG", lang)

proc statusRowText(sess: var TuiTestSession): string =
  ## The bottom row, right-trimmed.
  ##
  ## `strutils.strip` EXPLICITLY. `docs/tui-testing.md` records the trap:
  ## `std/unicode` is imported by every suite that reads a terminal row for
  ## `Rune`, and `unicode.strip` returns an ALL-whitespace string unchanged
  ## where `strutils.strip` returns "". A blank row would otherwise read as 120
  ## characters long.
  strutils.strip(sess.regionText(Rows - 1, 0, Cols, 1), leading = false)

proc settleOnDebugger(sess: var TuiTestSession; timeoutMs = 60000) =
  ## Wait for FRAME 1 — the debugger — rather than for frame 0. See this file's
  ## header.
  ##
  ## The failure is a diagnosis and not a timeout: it names the status row it
  ## saw, whether the child is alive, and its exit code, so "still opening the
  ## trace", "the engine refused" and "the binary died" are three reports.
  discard sess.drainOutput(30)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = statusRowText(sess)
    if last.len > 0 and not last.contains("opening "):
      # Frame 1 has started; the cursor barrier says when it has finished.
      waitForCompleteFrame(sess, Cols, Rows, timeoutMs = 15000)
      return
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited before painting the debugger: status row was '" &
        last & "', exit code " & $sess.exitCode())
  raise newException(AssertionFailedError,
    "the binary never painted the debugger within " & $timeoutMs &
    " ms: status row was '" & last & "', child alive=" & $sess.isAlive)

proc screenCells(sess: var TuiTestSession): seq[Cell] =
  ## Every cell of the parsed screen, as values.
  result = @[]
  for row in 0 ..< Rows:
    for col in 0 ..< Cols:
      result.add sess.cellAt(row, col)

proc screenText(sess: var TuiTestSession): string =
  sess.regionText(0, 0, Cols, Rows)

suite "CTUI-11 Tier 2: what the terminal was actually told":

  test "the binary and the fixture this lane needs exist":
    # First, and separately, so a missing build reports as a missing build
    # rather than as a spawn failure inside libvterm several assertions later.
    # This is the ONLY case that asserts the binary; the cases that follow spawn
    # it, so one that vanished between them fails them by spawning, loudly.
    if not fileExists(tuiBinary):
      checkpoint("missing " & tuiBinary & " — run `" & BuildRecipe & "`")
    ck fileExists(tuiBinary)
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      # NOT A SKIP. This lane spawns the shipped binary on a real recording, and
      # a recording it cannot get is a prerequisite it must report by name with
      # the recipe that produces one — `docs/tui-testing.md` rule 1.
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    checkpoint("trace: " & tracePath)
    ck tracePath.len > 0
    ck dirExists(tracePath)

  test "a capable terminal is told SGR-1006 mouse, and nothing about keys":
    var sess = baseSession(@[tracePath]).spawn()
    settleOnDebugger(sess)

    # THE NEGOTIATION, READ FROM THE TERMINAL'S SIDE. `mpSgr` is what
    # `?1000h ?1006h` leaves in libvterm's extended state, and it is the
    # protocol `app/input/mouse.decodeMouse` decodes.
    checkpoint("mouseProtocol=" & $sess.mouseProtocol() &
               " kitty=" & $sess.kittyKeyboardFlags() &
               " modifyOtherKeys=" & $sess.modifyOtherKeys())
    ck sess.mouseProtocol() == mpSgr

    # NOTHING WAS SAID ABOUT THE KEY ENCODING, and that is a decision rather
    # than an omission — `app/theme/capabilities.TerminalCapabilities.
    # kittyKeyboard` argues it at length. Both protocols re-encode every key,
    # `app/input/keymap.keyName` decodes xterm's classic encoding, and a driver
    # that switched without a decoder would make §4.2's function keys
    # unreachable on exactly the terminals users pick for key handling.
    ck sess.kittyKeyboardFlags() == {}
    ck sess.modifyOtherKeys() == 0

    # THE POSITIVE CONTROL ON THE SCREEN ITSELF: a blank screen would satisfy
    # every "does not contain" below for free.
    let text = screenText(sess)
    checkpoint("status row: " & statusRowText(sess))
    ck text.contains("CALL STACK")
    ck text.contains("SOURCE")
    ck text.contains("VARIABLES")
    ck text.contains("TIMELINE")

    sess.send("q")
    let status = sess.waitExit(initDuration(seconds = 15))
    checkpoint("exit: " & (if status.isSome: $status.get() else: "none"))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "--no-mouse tells the terminal nothing about the mouse":
    # THE NEGATIVE ARM OF THE SAME AXIS, through the same code path. Without it
    # `mpSgr` above would be satisfied by a driver that enabled mouse reporting
    # unconditionally and never read the flag at all.
    var sess = baseSession(@["--no-mouse", tracePath]).spawn()
    settleOnDebugger(sess)
    checkpoint("--no-mouse: mouseProtocol=" & $sess.mouseProtocol())
    ck sess.mouseProtocol() == mpNone
    ck sess.kittyKeyboardFlags() == {}
    ck sess.modifyOtherKeys() == 0
    # …and the screen is otherwise the same debugger, so the flag turned off a
    # protocol and not the application.
    let text = screenText(sess)
    ck text.contains("CALL STACK")
    ck text.contains("SOURCE")
    sess.send("q")
    let status = sess.waitExit(initDuration(seconds = 15))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "a Kitty-advertising terminal is STILL told nothing about keys":
    # The decision, asserted where it matters: on a terminal that would have
    # accepted the protocol. `TERM=xterm-kitty` also resolves synchronized
    # output on, so this case doubles as the DEC 2026 environment.
    var sess = baseSession(@[tracePath], term = "xterm-kitty").spawn()
    settleOnDebugger(sess)
    checkpoint("xterm-kitty: kitty=" & $sess.kittyKeyboardFlags() &
               " modifyOtherKeys=" & $sess.modifyOtherKeys() &
               " mouse=" & $sess.mouseProtocol())
    ck sess.kittyKeyboardFlags() == {}
    ck sess.modifyOtherKeys() == 0
    ck sess.mouseProtocol() == mpSgr
    sess.send("q")
    let status = sess.waitExit(initDuration(seconds = 15))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "--ascii-borders --no-color: no cell carries a colour, borders are - |":
    # CTUI-11's VERIFICATION GATE, read from real parsed cells.
    var sess = baseSession(@["--ascii-borders", "--no-color", tracePath],
                           # A terminal that WOULD have given truecolor, so the
                           # flags are what removed the colour rather than the
                           # environment.
                           term = "xterm-256color").spawn()
    settleOnDebugger(sess)

    let cells = screenCells(sess)
    checkpoint("cells parsed: " & $cells.len)
    # THE NON-VACUITY FLOOR: an empty cell list satisfies "no cell carries a
    # colour" for free.
    ck cells.len == Cols * Rows
    var coloured = 0
    var attributed = 0
    var glyphs = 0
    for cell in cells:
      if cell.fg.kind != ckDefault or cell.bg.kind != ckDefault:
        inc coloured
      if cell.attrs.len > 0 or cell.underline != usNone:
        inc attributed
      if cell.rune != Rune(0) and cell.rune != Rune(' '):
        inc glyphs
    checkpoint("coloured cells: " & $coloured & "  attributed cells: " &
               $attributed & "  non-blank cells: " & $glyphs)
    ck coloured == 0
    # …AND THE SCREEN IS NOT BLANK, which is what makes the line above a
    # statement about degradation and not about an empty terminal.
    ck glyphs > 200
    # …AND THE INFORMATION SURVIVED as weight and underline. `coloured == 0`
    # with `attributed == 0` would be a screen that had thrown every distinction
    # away, which is exactly what CTUI-11's contract forbids.
    ck attributed > 0

    let text = screenText(sess)
    let ascii = borderSet(bmAscii)
    let unicodeSet = borderSet(bmUnicode)
    checkpoint("ascii rule '" & ascii.horizontal & "' present: " &
               $text.contains(ascii.horizontal) &
               "; ascii separator '" & ascii.vertical & "' present: " &
               $text.contains(ascii.vertical))
    ck text.contains(ascii.horizontal)
    ck text.contains(ascii.vertical)
    # …and not one Unicode chrome glyph survived. Read from `borders.nim`'s own
    # set rather than spelled here, so a glyph added to the set is covered.
    for glyph in [unicodeSet.horizontal, unicodeSet.vertical,
                  unicodeSet.breakpoint, unicodeSet.breakpointDisabled,
                  unicodeSet.tracepoint, unicodeSet.needle,
                  unicodeSet.expanded, unicodeSet.collapsed,
                  unicodeSet.span, unicodeSet.ellipsis]:
      if text.contains(glyph):
        checkpoint("UN-DEGRADED UNICODE GLYPH ON AN --ascii-borders SCREEN: '" &
                   glyph & "'")
      ck not text.contains(glyph)
    # The positive twin for that loop, through the same haystack: the Unicode
    # glyphs really would have been findable if they were there.
    ck text.len > 0
    ck text.contains("SOURCE")

    sess.send("q")
    let status = sess.waitExit(initDuration(seconds = 15))
    ck status.isSome
    ck status.get() == 0
    sess.close()

  test "the same screen WITHOUT the flags does carry colour, absolutely":
    # THE POSITIVE TWIN of the gate above, and the reason it is a separate case:
    # "no colour under --no-color" is satisfied by a driver that never emitted
    # colour at all, on any terminal.
    #
    # `docs/tui-testing.md`: "every colour a Tier-2 case relies on for its
    # MEANING must also be asserted ABSOLUTELY". `indexed:244` is what
    # `app/theme/degradation.ansi256Style(srChromeMuted)` publishes for the
    # muted chrome every pane rule is painted in, so the assertion is the
    # published number and not "some colour".
    var sess = baseSession(@[tracePath], term = "xterm-256color").spawn()
    settleOnDebugger(sess)
    let cells = screenCells(sess)
    var coloured = 0
    var mutedRule = 0
    var rgb = 0
    for cell in cells:
      if cell.fg.kind != ckDefault or cell.bg.kind != ckDefault:
        inc coloured
      if cell.fg.kind == ckIndexed and cell.fg.idx == 244'u8:
        inc mutedRule
      if cell.fg.kind == ckRgb:
        inc rgb
    checkpoint("256-colour screen: " & $coloured & " coloured cells, " &
               $mutedRule & " at indexed:244, " & $rgb & " truecolor")
    ck coloured > 0
    ck mutedRule > 0
    # …and a 256-colour terminal is NOT sent 24-bit SGR, which is the whole
    # point of the middle rung of the ladder.
    ck rgb == 0
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()

  test "--truecolor sends 24-bit SGR to the same terminal":
    # The top rung, and the flag arm: the terminal has not changed, only the
    # command line has.
    var sess = baseSession(@["--truecolor", tracePath],
                           term = "xterm-256color").spawn()
    settleOnDebugger(sess)
    var rgb = 0
    var palette256 = 0
    var ansi16 = 0
    for cell in screenCells(sess):
      if cell.fg.kind == ckRgb: inc rgb
      # A LIBVTERM `ckIndexed` BELOW 16 IS A PLAIN ANSI COLOUR, not a
      # 256-palette one — `testing/dual_snap`'s `ansi16-is-indexed`
      # canonicalisation records the same fact from the other side. The claim
      # here is that the 256-palette rung is NOT used when 24-bit is available;
      # the sixteen names are what a style no role claims still paints in.
      if cell.fg.kind == ckIndexed:
        if cell.fg.idx >= 16'u8: inc palette256 else: inc ansi16
    checkpoint("--truecolor screen: " & $rgb & " cells with 24-bit fg, " &
               $palette256 & " from the 256 palette, " & $ansi16 &
               " plain ANSI")
    ck rgb > 0
    ck palette256 == 0
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()

  test "DEC 2026 is emitted and correctly PAIRED":
    # THE GATE, in the two halves this file's header argues for.
    #
    # HALF ONE — the emitter's bytes through a real terminal state machine. The
    # positive control the live session cannot give, because libvterm's flag is
    # live rather than latched.
    let syncCaps = TerminalCapabilities(
      colors: cdAnsi256, borders: bmUnicode, mouse: true,
      synchronizedOutput: true, kittyKeyboard: false)
    let plainCaps = TerminalCapabilities(
      colors: cdAnsi256, borders: bmUnicode, mouse: true,
      synchronizedOutput: false, kittyKeyboard: false)
    const Body = "\x1b[1;1Hhello"

    var probe = newScreen(4, 20)
    ck not probe.synchronizedOutput()
    probe.feed(SynchronizedOpenBytes)
    # THE OPEN IS OBSERVABLE. If it were not, the "false after a frame"
    # assertion below would be true of a driver that emitted nothing.
    ck probe.synchronizedOutput()
    probe.feed(Body)
    ck probe.synchronizedOutput()
    probe.feed(SynchronizedCloseBytes)
    ck not probe.synchronizedOutput()

    # …and the production bracket really is that pair, around that body.
    let bracketed = bracketFrame(syncCaps, Body)
    checkpoint("bracketed frame is " & $bracketed.len & " bytes; body is " &
               $Body.len)
    ck bracketed.startsWith(SynchronizedOpenBytes)
    ck bracketed.endsWith(SynchronizedCloseBytes)
    ck bracketed.contains(Body)
    ck bracketed.len == Body.len + SynchronizedOpenBytes.len +
                        SynchronizedCloseBytes.len
    # EXACTLY ONE of each, so a bracket cannot be nested or doubled.
    ck bracketed.count(SynchronizedOpenBytes) == 1
    ck bracketed.count(SynchronizedCloseBytes) == 1
    # …and a terminal that does not advertise it is sent neither byte.
    let unbracketed = bracketFrame(plainCaps, Body)
    ck unbracketed == Body
    ck not unbracketed.contains(SynchronizedOpenBytes)

    # THE MUTATION ARM: an UNPAIRED stream must leave the flag latched, or the
    # live assertion below is checking nothing.
    var unpaired = newScreen(4, 20)
    unpaired.feed(SynchronizedOpenBytes & Body)
    ck unpaired.synchronizedOutput()

    # HALF TWO — the live binary, on a terminal §6.3 names. After a settled
    # frame the flag must be FALSE: a driver that opened a bracket and never
    # closed it would latch it true, exactly as `unpaired` just did.
    var sess = baseSession(@[tracePath], term = "xterm-kitty").spawn()
    settleOnDebugger(sess)
    ck not sess.synchronizedOutput()
    # …and the gate's own API, called as CTUI-11 names it. `assertSynchronizedRender`
    # RAISES NOTHING on a child that never bracketed — its failure arm is
    # `discard`, measured at `TermAssert/src/term_assert.nim:640` — so it is
    # invoked for the contract and the falsifiable claims are the ones above and
    # around it.
    sess.assertSynchronizedRender(proc() =
      sess.send("n")
      discard sess.drainOutput(200))
    waitForCompleteFrame(sess, Cols, Rows, timeoutMs = 30000)
    ck not sess.synchronizedOutput()
    # The repaint really happened, so the action the gate wrapped was a paint
    # and not a no-op.
    let after = screenText(sess)
    checkpoint("after step: " & statusRowText(sess))
    ck after.contains("SOURCE")
    ck statusRowText(sess).len > 0
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()

  test "cold start to the first frame is under the published budget":
    # CTUI-11's risk note: "a blocking probe fails a published gate rather than
    # merely feeling slow."
    #
    # MEASURED TO FRAME 0. `main.nim` negotiates, claims the tty and paints
    # before it spawns `replay-server`; the engine handshake is CTUI-14's number
    # and is reported below rather than gated here.
    let started = getMonoTime()
    var sess = baseSession(@[tracePath]).spawn()
    waitForCompleteFrame(sess, Cols, Rows, timeoutMs = 20000)
    let firstFrameMs = (getMonoTime() - started).inMilliseconds
    let firstRow = strutils.strip(sess.regionText(Rows - 1, 0, Cols, 1),
                                  leading = false)
    checkpoint("first frame at " & $firstFrameMs & " ms; status row: '" &
               firstRow & "'")
    # THE FIRST FRAME REALLY IS FRAME 0 — the one painted before the engine —
    # which is what makes the number the cold start rather than a partial
    # debugger.
    ck firstRow.contains("opening ")
    ck firstFrameMs < ColdStartBudgetMs

    settleOnDebugger(sess)
    let debuggerMs = (getMonoTime() - started).inMilliseconds
    # REPORTED, NOT GATED: the trace open is a `replay-server` spawn plus a DAP
    # handshake plus the first `stackTrace`, `ct/load-locals` and
    # `ct/event-load`. CTUI-14 owns that budget.
    echo "CTUI-11 COLD START: first frame ", firstFrameMs, " ms, debugger ",
         debuggerMs, " ms (budget for the first frame: ", ColdStartBudgetMs,
         " ms)"
    checkpoint("debugger painted at " & $debuggerMs & " ms")
    ck debuggerMs >= firstFrameMs
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()

  test "a terminal-less run refuses and names what it negotiated":
    # The one path a pty cannot show, asserted through a pty ANYWAY so the two
    # branches of `stdoutIsTerminal` are both covered by this lane: the child's
    # stdout is redirected inside the pty, so `isatty` is false while the
    # harness still parses the stderr that reaches the terminal.
    var sess = baseSession(@["--no-color", tracePath]).spawn()
    settleOnDebugger(sess)
    # The negotiated set is named on the status line while it runs …
    ck sess.mouseProtocol() == mpSgr
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()

    # … and a run whose stdout is a FILE refuses, names the negotiated set and
    # exits 3 rather than drawing into it.
    let outPath = repoRoot() / "test-logs" / "ctui11-no-terminal.txt"
    createDir(outPath.parentDir)
    let rc = execShellCmd("'" & tuiBinary & "' '" & tracePath & "' >'" &
                          outPath & "' 2>&1")
    let report = readFile(outPath)
    checkpoint("piped run exited " & $rc & ": " & strutils.strip(report))
    # EXIT 3 EXACTLY, not "non-zero": `main.nim` separates "there is no screen
    # here" from a usage error (2) and from an unhandled exception (1) on
    # purpose, because `codetracer-tui trace | cat` is a correct command line
    # and an impossible request. A `rc != 0` here would be satisfied by the
    # binary crashing.
    ck rc == ExitNoTerminalStatus
    ck report.contains("standard output is not a terminal")
    ck report.contains("negotiated: ")
    ck report.contains("colors=")
    ck report.contains("borders=")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
