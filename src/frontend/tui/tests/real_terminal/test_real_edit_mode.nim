## test_real_edit_mode.nim — PLAT-16, Tier 2.
##
## ## WHAT ONLY THIS FILE CAN SAY
##
## PLAT-16's first integration-test row: *"Editing driven through a real pty.
## Note `TermAssert.sendKey` strips `shift+` **and** `ctrl+`; a modified editing
## key must be written as xterm bytes."*
## CodeTracer-TUI-Edit-Mode.md §7 gives the reason: *"Keystroke-to-buffer
## behaviour, selection, undo and word wrap must be asserted through a real pty
## — a Tier-1 harness cannot see the modifier handling."*
##
## So this suite spawns **the shipped binary** — `build/bin/codetracer-tui
## --edit <project>`, which is what `ct edit --ui=tui <project>` hands off to —
## in a real pty, types real bytes at it, and reads the screen back through
## libvterm. Four things are in play that no in-process harness can observe:
##
##   * **`--edit` reaching a front-end at all.** `main.editInteractive` is a
##     second loop; a Tier-1 suite drives `handleToken` and never runs it.
##   * **Keys as bytes.** `X` is one byte; `Ctrl+z` is `0x1a`; `Ctrl+F5` is
##     `CSI 15 ; 5 ~`. Each is decoded by `keymap.keyName` out of a real fd.
##   * **THE MODIFIER STRIPPING — MEASURED, AND THE MILESTONE'S NOTE IS HALF
##     STALE FOR THIS CHECKOUT.** PLAT-16 says `sendKey` strips `shift+` AND
##     `ctrl+`. Run against `../TermAssert` as this workspace has it
##     (`src/term_assert.nim`, `sendKey`), that is true of `shift+` always and
##     of `ctrl+` only for NAMED keys: the `case key` arms for `f1`..`f12`,
##     the arrows, `home`, `end` and the rest emit a bare sequence and ignore
##     both flags, while the single-character fallback DOES apply
##     `b and 0x1F`. So `sendKey("ctrl+z")` really does send `0x1a`, and
##     `sendKey("ctrl+f5")` sends a plain `F5`.
##
##     Both halves are asserted below rather than trusted: the case named for
##     it drives `sendKey("ctrl+f5")` and requires the product mode NOT to
##     change — because plain `F5` is Continue, which is `asDebugOnly` and
##     therefore inert in Edit mode — and then drives the same chord as
##     `CSI 15 ; 5 ~` and requires it to. That is the note's hazard reproduced
##     on the key it still applies to.
##   * **The alternate screen.** The editor is inside it, and the terminal is
##     given back.
##
## ## AND ONE THING ONLY THIS FILE CAN SAY AT ALL: THE STALE-TRACE NOTICE
##
## PLAT-16's landing pass found that §2.1's notice — the milestone's own named
## deliverable — **could not be produced by the shipped binary**. It needs a
## recording and an edited buffer at the same moment, and no route had both:
## `--edit` opens buffers and has no recording, while the replay entrypoint had
## the recording and wired no `EditServices`, so its `Ctrl+F5` reached an
## editor with no reader. The Tier-1 suite supplied the missing state by hand,
## which is `Verification-Harness-Traps.md` §7 exactly: *"a contract suite's
## passing fixture can be an instance of the defect it exists to catch"*.
##
## The second suite below is the answer, and it is at Tier 2 on purpose: the
## claim is about a ROUTE through a process, so the only standard that settles
## it is the process. It replays a real recording, from inside a real project,
## types a real byte, saves through `:w`, **reads the file back off the disk**,
## toggles back and requires the sentence. Its negative twin removes exactly
## one input — the keystroke — so a build that printed the notice on every
## switch fails one and passes the other.
##
## ## IT DOES NOT SKIP
##
## A missing `build/bin/codetracer-tui` fails this suite by name and names the
## recipe that builds it. `just test-tui-real-terminal` depends on `build-tui`.
##
## ## THE BARRIER IS CONTENT, NOT THE CURSOR, AND THAT IS DELIBERATE
##
## `waitForCompleteFrame`'s bottom-right barrier is satisfied after EVERY
## frame — including the one before the key was handled — which is
## `docs/tui-testing.md`'s "a barrier that is true before the event it names".
## The product's edit loop installs no per-step epilogue, so this suite waits
## for the SCREEN TO SAY the thing it is about to assert, with a deadline, and
## fails loudly rather than asserting against whatever had arrived.
##
## ## No mocks
##
## A compiled binary, a real pty, a real terminal state machine, a real
## directory on disk.

import std/[monotimes, options, os, strutils, times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

const ExpectedAssertions = 61

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 40
    ## The Standard profile's band (>= 120 wide, >= 35 tall), so the Edit
    ## layout is the file tree beside the editor above the build pane rather
    ## than the Compact arrangement.
  FrameTimeoutMs = 20000

  ProjectFile = "alpha.nim"
  ProjectText = "proc alpha() =\n  echo 1\n"

  CtrlZ = "\x1a"
    ## Ctrl+z on the wire. WRITTEN AS A BYTE, not as `sendKey("ctrl+z")` — see
    ## the module header.
  CtrlF5 = "\x1b[15;5~"
    ## Ctrl+F5: `CSI <code> ; <modifier> ~` with code 15 (F5) and modifier
    ## `1 + Ctrl(4)` = 5.
    ## https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  QuitByte = "q"
  Tab = "\t"

  FixtureName = "calc"
    ## The recording the stale-trace case replays. The same fixture
    ## `test_real_pty_lifecycle.nim` uses, so this lane's prerequisites do not
    ## grow: it is already resolved (and, on a cold cache, recorded) by that
    ## suite.

proc replayProjectDir(): string =
  ## A SECOND project, distinct from `projectDir()` below, because the
  ## stale-trace case WRITES to it and three other cases assert their project
  ## is untouched. One directory shared between them would make `:w` in this
  ## case a failure over there, in whichever order the runner happened to pick.
  result = lifecycle_support.repoRoot() / "test-logs" / "plat16-replay-project"
  createDir(result)
  writeFile(result / ProjectFile, ProjectText)

proc projectDir(): string =
  ## A REAL DIRECTORY, built rather than checked in, on the same rule
  ## `lifecycle_support.wedgeFolder` states about its own fixture: the property
  ## that matters is what the construction says out loud.
  result = lifecycle_support.repoRoot() / "test-logs" / "plat16-edit-project"
  createDir(result)
  writeFile(result / ProjectFile, ProjectText)

proc spawnEditor(dir: string): TuiTestSession =
  newTuiTest(tuiBinary(), @["--edit", dir])
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .spawn()

proc spawnReplay(trace, workingDir: string): TuiTestSession =
  ## The REPLAY entrypoint — `ct replay --ui=tui <trace>`'s handoff — launched
  ## from inside a project.
  ##
  ## `workDir` is the whole point of this spawn. `main.interactive` resolves the
  ## project a replay session edits from `getCurrentDir()`, so the working
  ## directory is an INPUT to the behaviour under test rather than incidental,
  ## and a case that inherited the runner's cwd would be asserting something
  ## about the checkout instead.
  newTuiTest(tuiBinary(), @[trace])
    .width(Cols).height(Rows)
    .workDir(workingDir)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .spawn()

proc waitForScreenText(sess: var TuiTestSession; needle: string;
                       timeoutMs = FrameTimeoutMs): string =
  ## Drain until the screen CONTAINS `needle`, and raise naming what it held
  ## instead. See the module header on why this is not the cursor barrier.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    if last.contains(needle):
      return last
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited before '" & needle & "' appeared; screen was:\n" &
        last & "\nexit code " & $sess.exitCode())
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared within " & $timeoutMs & " ms; screen:\n" &
    last)

proc waitUntilScreenLacks(sess: var TuiTestSession; needle: string;
                          timeoutMs = FrameTimeoutMs): string =
  ## The opposite barrier, for an undo: wait until the screen STOPS containing
  ## something. Needed because "the character is gone" cannot be waited for by
  ## waiting for a character to arrive.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    if not last.contains(needle):
      return last
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited while waiting for '" & needle & "' to go; screen:\n" &
        last)
  raise newException(AssertionFailedError,
    "'" & needle & "' was still on screen after " & $timeoutMs & " ms:\n" &
    last)

# ---------------------------------------------------------------------------

suite "PLAT-16 Tier 2: editing in a real terminal":

  test "the binary this lane tests exists and can be executed":
    # A PREREQUISITE, NOT AN EXCUSE. Asserted once, in the case that exists to
    # report it: repeating it in every case counts as four assertions and
    # establishes one fact.
    checkpoint("binary: " & tuiBinary())
    ck fileExists(tuiBinary())
    ck fpUserExec in getFilePermissions(tuiBinary())

  test "`--edit <project>` opens the project in EDIT mode, with the file on screen":
    let dir = projectDir()
    var sess = spawnEditor(dir)
    try:
      let screen = waitForScreenText(sess, "EDIT ")
      checkpoint(screen)
      # THE PRODUCT MODE IS LEGIBLE FROM THE WINDOW (Mode-Transitions.md §7):
      # the pane's own title and the status line's separate indicator.
      ck screen.contains("EDIT " & ProjectFile)
      ck screen.contains("[EDIT]")
      # …and the INPUT mode indicator is still NORMAL, beside it, which is the
      # orthogonality visible on a terminal rather than in a type.
      ck screen.contains("NORMAL [EDIT]")
      # §2's Requirement: the pane says WHICH SOURCE it is showing, always.
      ck screen.contains("the working tree")
      # THE FILE'S CONTENT IS THERE, from the real disk through the real host.
      ck screen.contains("proc alpha() =")
      ck screen.contains("echo 1")
      # Edit mode's OWN pane set (§4): a file tree and a build surface, and no
      # call stack.
      ck screen.contains("FILES")
      ck screen.contains("BUILD")
      ck screen.contains(ProjectFile)
      ck not screen.contains("CALL STACK")
      # The build pane is a statement rather than a blank.
      ck screen.contains("[idle]")
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

  test "a typed byte reaches the buffer, and the dirty marker appears":
    let dir = projectDir()
    var sess = spawnEditor(dir)
    try:
      discard waitForScreenText(sess, "proc alpha() =")
      # THE BUFFER IS CLEAN BEFORE THE KEY. Without this the marker assertion
      # below is satisfied by a pane that always draws it.
      ck not sess.screenContents().contains("[+]")

      # ONE BYTE, ON A REAL FD, into the widget's own `insertText`.
      sess.send("Z")
      let typed = waitForScreenText(sess, "Zproc alpha() =")
      checkpoint(typed)
      # THE CHARACTER IS IN THE FILE'S FIRST LINE, at the caret, which opened
      # at (1, 0).
      ck typed.contains("Zproc alpha() =")
      # …AND THE BUFFER IS MARKED MODIFIED. Mode-Transitions.md §5 requires an
      # unsaved buffer to survive a switch; the marker is what lets a user know
      # they have one.
      ck typed.contains("[+]")
      # NOTHING WAS WRITTEN TO DISK: `:w` is the only thing that writes, and it
      # was not typed.
      ck readFile(dir / ProjectFile) == ProjectText
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

  test "Ctrl+z undoes, written as the byte 0x1a":
    let dir = projectDir()
    var sess = spawnEditor(dir)
    try:
      discard waitForScreenText(sess, "proc alpha() =")
      sess.send("Z")
      discard waitForScreenText(sess, "Zproc alpha() =")
      ck sess.screenContents().contains("[+]")

      # THE BYTE, NOT `sendKey("ctrl+z")`. It happens to work in this checkout
      # (see the module header) and the discipline is kept anyway: the
      # workspace pins no `TermAssert` revision, so this lane can be built
      # against one where it does not, and writing the byte costs nothing and
      # depends on neither behaviour.
      sess.send(CtrlZ)
      let undone = waitUntilScreenLacks(sess, "Zproc alpha() =")
      checkpoint("after the Ctrl+z byte: " & undone.splitLines()[2].strip())
      ck undone.contains("proc alpha() =")
      ck not undone.contains("Zproc")
      # THE DIRTY MARKER IS GONE, which is the assertion that says the marker
      # is a COMPARISON against the loaded bytes rather than a flag a mutation
      # set. A flag would still be true here.
      ck not undone.contains("[+]")
      # AND NOTHING WAS EVER WRITTEN. `:w` is the only thing that writes.
      ck readFile(dir / ProjectFile) == ProjectText
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

  test "`sendKey(\"ctrl+f5\")` loses the modifier; the raw bytes do not":
    # PLAT-16's note, reproduced on the key it still applies to in this
    # checkout. See the module header for the measurement.
    let dir = projectDir()
    var sess = spawnEditor(dir)
    try:
      discard waitForScreenText(sess, "NORMAL [EDIT]")

      # ---- THE STRIPPED SPELLING: a plain F5 arrives -----------------------
      sess.sendKey("ctrl+f5")
      # `F5` is Continue, which `keymap.scopeOf` makes `asDebugOnly`, so in
      # Edit mode it resolves `krInertInMode` and the user is TOLD
      # (Mode-Transitions.md §8.1). That message is the evidence the plain key
      # arrived; "the mode did not change" alone would also be true of a key
      # that was never delivered.
      let inert = waitForScreenText(sess, "needs a replay session")
      checkpoint(inert.splitLines()[^1].strip())
      ck inert.contains("continue")
      ck inert.contains("Ctrl+F5 switches")
      # AND THE PRODUCT MODE DID NOT MOVE.
      ck inert.contains("NORMAL [EDIT]")
      ck not inert.contains("[DEBUG]")

      # ---- THE BYTES: the modifier survives --------------------------------
      sess.send(CtrlF5)
      let switched = waitForScreenText(sess, "NORMAL [DEBUG]")
      ck switched.contains("NORMAL [DEBUG]")
      ck not switched.contains("NORMAL [EDIT]")
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

  test "Ctrl+F5 switches the product mode, as bytes, and the indicator moves":
    let dir = projectDir()
    var sess = spawnEditor(dir)
    try:
      discard waitForScreenText(sess, "NORMAL [EDIT]")
      # THE TOGGLE, as `CSI 15 ; 5 ~`.
      sess.send(CtrlF5)
      let debug = waitForScreenText(sess, "NORMAL [DEBUG]")
      checkpoint(debug.splitLines()[^1].strip())
      # The PRODUCT indicator moved and the INPUT one did not: both are on the
      # row and only one changed, which is the orthogonality claim on a real
      # terminal.
      ck debug.contains("NORMAL [DEBUG]")
      ck not debug.contains("[EDIT]")
      # …and the pane set moved with it (Mode-Transitions.md §4 requirement 4:
      # mode and layout change together or not at all).
      ck not debug.contains("EDIT " & ProjectFile)
      ck debug.contains("CALL STACK")

      # BACK, and the editor is the one that was there — §6's reversibility,
      # through a real terminal.
      sess.send(CtrlF5)
      let back = waitForScreenText(sess, "EDIT " & ProjectFile)
      ck back.contains("NORMAL [EDIT]")
      ck back.contains("proc alpha() =")
      ck back.contains("FILES")
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

suite "PLAT-16 §2.1 Tier 2: the stale-trace notice, on the route a user has":

  test "a recording, an edit, a save, and the switch back TELLS the user":
    # THE CASE PLAT-16 NAMED IN ADVANCE, ON THE SHIPPED BINARY:
    # *"edit, toggle to Debug on an existing trace, and assert the user is
    # TOLD. A test that only checks the toggle succeeds would pass while the
    # user is misled."*
    #
    # It is here, at Tier 2, because of what the landing pass found at Tier 1:
    # the in-process case asserted the notice against a session built by hand
    # (`app.traceName = "demo.ct"` plus a hand-opened buffer), and **no shipped
    # route could reach that state**. `ct edit --ui=tui` had the buffer and no
    # recording; `ct replay --ui=tui` had the recording and no `EditServices`,
    # so its `Ctrl+F5` arrived at an editor with no reader. The green fixture
    # was an instance of the defect (Verification-Harness-Traps §7), and the
    # only standard that can close that is a case whose subject is a PROCESS.
    #
    # Two of the landing pass's three findings are graded here at once, because
    # a user meets them in one gesture: F1 (the route exists at all) and F2
    # (`:w` does not silence the notice — saving makes a recording MORE stale,
    # and the disk is checked here rather than a field).
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      # NOT A SKIP. `docs/tui-testing.md` rule 1.
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    let project = replayProjectDir()
    checkpoint("trace: " & resolved.tracePath & "  project: " & project)
    ck readFile(project / ProjectFile) == ProjectText

    var sess = spawnReplay(resolved.tracePath, project)
    try:
      # ---- the debugger, on a real recording -------------------------------
      settleOnDebugger(sess, Cols, Rows)
      let opened = sess.screenContents()
      ck opened.contains("NORMAL [DEBUG]")
      ck opened.contains("CALL STACK")
      # THE POSITIVE CONTROL ON THE ABSENCE BELOW: the notice is not on screen
      # before the edit, so "it appeared" is an event rather than a constant.
      ck not opened.contains("predates")

      # ---- Ctrl+F5 into Edit mode, and there is something to edit ----------
      sess.send(CtrlF5)
      let editing = waitForScreenText(sess, "NORMAL [EDIT]")
      checkpoint(editing.splitLines()[^1].strip())
      # The project is the WORKING DIRECTORY, and the front-end says so rather
      # than leaving the user to infer it from a file tree.
      #
      # THE COUNT AND THE VERB, NOT THE PATH, and the tier split is the reason:
      # `statusBarText` right-aligns the notification and truncates it from the
      # TAIL, so an absolute project path is a claim whose survival depends on
      # how deep this checkout happens to sit — which would make the assertion
      # a statement about the runner's directory layout. That the message names
      # the ROOT is asserted where there is no truncation, in
      # `app/tests/test_edit_mode_source.nim`; what only a real pty can say is
      # that a real walk of a real directory found the file and said how many.
      ck editing.contains("editing ")
      ck editing.contains("1 file(s)")
      # …and it really opened the file, off the real disk.
      ck editing.contains("EDIT " & ProjectFile)
      ck editing.contains("proc alpha() =")
      ck editing.contains("FILES")

      # ---- a real byte into the buffer -------------------------------------
      sess.send("Z")
      let typed = waitForScreenText(sess, "Zproc alpha() =")
      ck typed.contains("[+]")

      # ---- `:w`, which needs the focus off the editor ----------------------
      # While the editor is focused every printable key is text, `:` included —
      # `app/runtime.handleToken`'s step 1a records why, and `Tab` is the key
      # deliberately left as an escape. This is the ergonomic hole named in
      # PLAT-16's status note, driven here rather than described.
      sess.send(Tab)
      discard waitForScreenText(sess, "focus ")
      sess.send(":w\r")
      discard waitForScreenText(sess, "wrote " & ProjectFile)
      # THE EFFECT IS ON THE DISK, not in a field. `readFile` is the assertion
      # that cannot be satisfied by a front-end that reports a write politely.
      let onDisk = readFile(project / ProjectFile)
      checkpoint("on disk after :w: " & onDisk.splitLines()[0])
      ck onDisk != ProjectText
      ck onDisk.startsWith("Zproc alpha() =")

      # ---- back to Debug, and the user is told -----------------------------
      sess.send(CtrlF5)
      let told = waitForScreenText(sess, "predates")
      checkpoint(told.splitLines()[^1].strip())
      ck told.contains("NORMAL [DEBUG]")
      # The three things that must survive the status line's truncation: the
      # fact, the file, and the consequence.
      ck told.contains("predates")
      ck told.contains(ProjectFile)
      ck told.contains("line numbers")
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

  test "with NO edit, the same route says nothing — the notice is not a constant":
    # §7a: a negative control nobody has falsified is a self-comparison wearing
    # a negation. This is the positive case above with exactly ONE input
    # removed — the keystroke — so a build that printed the notice on every
    # switch, or one that printed it because a recording was open, fails here
    # and passes there.
    let resolved = resolveFixture(FixtureName)
    ck resolved.outcome == foRecorded
    let project = replayProjectDir()
    var sess = spawnReplay(resolved.tracePath, project)
    try:
      settleOnDebugger(sess, Cols, Rows)
      sess.send(CtrlF5)
      discard waitForScreenText(sess, "NORMAL [EDIT]")
      sess.send(CtrlF5)
      let back = waitForScreenText(sess, "NORMAL [DEBUG]")
      checkpoint(back.splitLines()[^1].strip())
      ck not back.contains("predates")
      ck back.contains("switched to DEBUG mode")
      # AND THE FILE WAS NOT WRITTEN by a round trip that touched nothing.
      # `replayProjectDir` rewrote it above, so this is an equality rather than
      # a disjunction: `:w` is the only thing in this front-end that writes.
      ck readFile(project / ProjectFile) == ProjectText
    finally:
      sess.send(QuitByte)
      discard sess.waitExit(initDuration(seconds = 10))
      sess.close()

suite "PLAT-16 Tier 2: `--edit` refusals":

  test "`--edit` with `--headless` is refused on the ordinary screen":
    # §8 open decision 4: an EXPLICIT usage error rather than an untested
    # combination. 200 columns so the one-line diagnostic is not wrapped.
    var sess = newTuiTest(tuiBinary(), @["--edit", projectDir(), "--headless"])
      .width(200).height(24).spawn()
    let status = sess.waitExit(initDuration(seconds = 20))
    discard sess.drainOutput(60)
    let screen = sess.screenContents()
    checkpoint("screen: " & screen.strip())
    ck status.isSome
    ck status.get() == 2
    ck screen.contains("codetracer-tui:")
    ck screen.contains("--headless")
    ck screen.contains("--edit")
    sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
