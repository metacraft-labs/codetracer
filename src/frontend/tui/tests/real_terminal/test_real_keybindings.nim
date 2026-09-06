## test_real_keybindings.nim — CTUI-9, Tier 2.
##
## ## What only this file can say
##
## CTUI-9: "TermAssert: drives `sendKey("f10")`, `sendKey("shift+f10")`,
## `sendKey("ctrl+p")`, `sendControl('c')` and asserts the resulting mode via
## the status bar *and* via `cursorShape`/`cursorVisible`. Real xterm byte
## sequences, not synthesized key events — the layer where an F-key binding
## actually breaks."
##
## Three of `docs/tui-testing.md`'s "only Tier 2 will do" rows are in play at
## once and none of them is reachable in process:
##
##   * **keys as bytes** — `ESC [ 2 1 ~` arriving one byte at a time on a real
##     fd, framed by `testing/test_app_runtime.nim`, decoded by
##     `app/input/keymap.keyName`. A Tier-1 suite hands `keyName` a string it
##     wrote itself.
##   * **cursor position, shape, visibility** — "the model has no cursor". The
##     mode's DECSCUSR shape and DECTCEM visibility are read back out of
##     libvterm's own state.
##   * **real cell attributes after parsing** — the mode indicator's colour, as
##     a NUMBER.
##
## ## EVERY COLOUR HERE IS ASSERTED ABSOLUTELY, AND THAT IS A RULE
##
## `docs/tui-testing.md`, "What cross-tier equality cannot catch, and never
## will": a differential check is blind to any defect both tiers share. So the
## mode indicator is asserted as `fg.idx == 2` for NORMAL and `fg.idx == 3` for
## COMMAND — not "different from each other", and not "the same as Tier 1".
##
## ## A MEASURED DEFECT IN THE HARNESS, RECORDED RATHER THAN WORKED AROUND
##
## `TermAssert.sendKey` STRIPS `shift+` and sends the unmodified sequence
## (`TermAssert/src/term_assert.nim:402` at `TermAssert@fd4cce9`: the `while`
## loop consumes `shift+` without recording it, and only `ctrl` and `alt`
## survive into the single-character branch). So `sendKey("shift+f10")` writes
## `ESC [ 2 1 ~` —
## byte for byte what `sendKey("f10")` writes — and cannot exercise
## `Shift+F10`'s binding at all.
##
## This file drives it anyway, because CTUI-9 names it, and ASSERTS THE
## CONSEQUENCE: the second F10 resolves to `step-over` again, exactly like the
## first. Then it sends xterm's real modified-function-key sequence
## `ESC [ 2 1 ; 2 ~` itself and asserts THAT resolves to `reverse-step-over`.
## The two together are what make "Shift+F10 is bound and reachable" a measured
## claim rather than a call to a harness that quietly dropped the modifier.
## (The parameter is `1 + Shift`, i.e. 2 — xterm's ctlseqs, "PC-Style Function
## Keys".)
##
## ## EVERY DRIVEN FRAME IS WAITED FOR BY NAME
##
## `waitForCompleteFrame` cannot be the barrier after an input: the cursor is
## already parked on the bottom-right cell from the previous frame. The child
## labels an input-driven repaint `<label>-stepN` and every case here waits for
## the label of the frame it is about to read. No sleeps, no `waitForText`.
##
## ## It does not skip
##
## A child that will not compile, a child that never finishes a frame, a label
## that never arrives: every one FAILS by name.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine, driven by real key bytes.
##
## ## Templates, not procs, for anything that calls `check`

import std/[options, strutils, times, unicode, unittest]

import term_assert

import ../../app/input/keymap
import ../../app/input/modal_state
import ../../app/views/status_bar
import ../../app/views/styled_row
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_keybindings as keysApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 110

const
  Cols = 90
  Rows = 24
  Label = "keybindings"
  Stem = "app_keybindings"
  FrameTimeoutMs = 20000
  LabelTimeoutMs = 10000

  Green = 2'u8      ## NORMAL's indicator colour.
  Yellow = 3'u8     ## COMMAND's.

  # Real xterm bytes this file writes itself, because `sendKey` cannot.
  ShiftF10Bytes = "\x1b[21;2~"
  DoubleEscapeBytes = "\x1b\x1b"
    ## THE ONLY WAY TO DELIVER A LONE `Esc` THROUGH THIS RUNTIME, and it is a
    ## property of the runtime rather than of the terminal. `runSnapshotApp`
    ## accumulates from `\x1b` while the buffer is still a prefix of the F10
    ## sequence, so a single `\x1b` sits in that buffer until something else
    ## arrives. A second `\x1b` breaks the prefix, is not a CSI, and therefore
    ## falls through the runtime's "honour the byte that broke the prefix" arm
    ## — delivering exactly one `Esc` token to the app. Asserted below by the
    ## mode it produces, so if the runtime's framing ever changes this line
    ## fails rather than silently delivering nothing.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc describeCell(c: term_assert.Cell): string =
  var attrs: seq[string] = @[]
  for a in c.attrs:
    attrs.add $a
  "rune='" & (if c.rune.int32 == 0: " " else: $c.rune) & "' fg=" &
    (case c.fg.kind
     of ckDefault: "default"
     of ckIndexed: "indexed:" & $c.fg.idx
     of ckRgb: "rgb") &
    " attrs={" & attrs.join(",") & "}"

proc paneRow(sess: var TuiTestSession; row: int): string =
  sess.regionText(row, 0, Cols, 1).split('\n')[0].strip(leading = false)

proc settledFrame(sess: var TuiTestSession; step: int): ScreenSnapshot =
  ## Wait for the frame the child declares final at `step`, by name.
  waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
  sess.send($TestAppCaptureByte)
  waitForSnapshotLabel(sess, stepLabel(Label, step), LabelTimeoutMs)

proc spawnChild(): TuiTestSession =
  compileChildApp(Stem)
  newTuiTest(appBinaryPath(Stem),
             @["--cols=" & $Cols, "--rows=" & $Rows,
               "--test-ipc", "--label=" & Label])
    .width(Cols).height(Rows)
    .spawn()

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkField(sess: var TuiTestSession; row: int; label, value: string) =
  ## One `LABEL : value` line, read off the terminal.
  let got = paneRow(sess, row)
  checkpoint("row " & $row & ": '" & got & "' want '" &
             keysApp.fieldText(label, value) & "'")
  ck got == keysApp.fieldText(label, value)

template checkMode(sess: var TuiTestSession; mode: ModalMode;
                   colour: uint8) =
  ## THE MODE, THREE WAYS: the field line, the status-bar indicator with its
  ## colour as a number, and the cursor the terminal is actually showing.
  ##
  ## Three, because each can be right while another is wrong: an app that
  ## printed the mode and never emitted DECSCUSR would satisfy the first two,
  ## and one that emitted the cursor bytes from a stale variable would satisfy
  ## the third alone.
  checkField(sess, keysApp.ModeRow, keysApp.ModeLabel, $mode)
  let bar = paneRow(sess, Rows - 1)
  checkpoint("status bar: '" & bar & "'")
  ck bar.startsWith($statusMode(mode))
  let indicator = sess.cellAt(Rows - 1, 0)
  checkpoint("mode indicator cell " & describeCell(indicator))
  ck indicator.fg.kind == ckIndexed
  ck indicator.fg.idx == colour
  ck caBold in indicator.attrs
  let want = cursorFor(mode)
  checkpoint("cursor: shape=" & $sess.cursorShape() & " visible=" &
             $sess.cursorVisible() & " want " & $want.shape & "/" &
             $want.visible)
  ck sess.cursorVisible() == want.visible
  case want.shape
  of mcsBlock: ck sess.cursorShape() == csBlock
  of mcsUnderline: ck sess.cursorShape() == csUnderline
  of mcsBar: ck sess.cursorShape() == csBar

# ---------------------------------------------------------------------------

suite "CTUI-9 Tier 2: the keymap on a real terminal":

  test "F10, Shift+F10 and Ctrl+p are resolved from real xterm bytes":
    var sess = spawnChild()
    try:
      # ---- THE UNDRIVEN FRAME ---------------------------------------------
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      ck sess.snapshots().len == 0
      sess.send($TestAppCaptureByte)
      let frame0 = waitForSnapshotLabel(sess, stepLabel(Label, 0),
                                        LabelTimeoutMs)
      ck frame0.label == Label
      ck frame0.rows == Rows
      ck frame0.cols == Cols
      # The whole screen agrees with the model for the PRISTINE state, which
      # grounds every field read below in one comparison rather than in six.
      let initial = keysApp.initialRows(Cols, Rows)
      var mismatched: seq[string] = @[]
      var rowsCompared = 0
      for row in 0 ..< Rows:
        inc rowsCompared
        let onScreen = paneRow(sess, row)
        let inModel = initial[row].strip(leading = false)
        if onScreen != inModel:
          mismatched.add "row " & $row & ": terminal '" & onScreen &
            "' model '" & inModel & "'"
      if mismatched.len > 0:
        for m in mismatched:
          checkpoint(m)
      ck mismatched.len == 0
      ck rowsCompared == Rows
      checkMode(sess, mmNormal, Green)
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaNone)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "")
      checkField(sess, keysApp.PendingRow, keysApp.PendingLabel, "")
      ck paneRow(sess, keysApp.QuitRow) != keysApp.QuitText

      # ---- F10: §4.2's "Step Over (Forward)" ------------------------------
      sess.sendKey("f10")
      discard settledFrame(sess, 1)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "F10")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaStepOver)
      checkField(sess, keysApp.KindRow, keysApp.KindLabel, $krAction)
      checkMode(sess, mmNormal, Green)

      # ---- `sendKey("shift+f10")`: THE HARNESS DROPS THE MODIFIER ---------
      # Driven because CTUI-9 names it, and asserted for what it ACTUALLY
      # does. See this file's header: `sendKey` strips `shift+`, so these are
      # the same bytes as above and must resolve the same way.
      sess.sendKey("shift+f10")
      discard settledFrame(sess, 2)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "F10")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaStepOver)

      # ---- THE REAL Shift+F10 SEQUENCE ------------------------------------
      sess.send(ShiftF10Bytes)
      discard settledFrame(sess, 3)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "Shift+F10")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel,
                 $kaReverseStepOver)
      # …and it is a DIFFERENT action from the unmodified key, which is the
      # whole point of sending the bytes by hand.
      ck $kaReverseStepOver != $kaStepOver
      checkMode(sess, mmNormal, Green)

      # ---- Ctrl+p: the palette, and therefore COMMAND ----------------------
      sess.sendKey("ctrl+p")
      discard settledFrame(sess, 4)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "Ctrl+p")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel,
                 $kaCommandPalette)
      checkMode(sess, mmCommand, Yellow)
      # THE CURSOR CHANGED, and both fields did. A terminal that had never
      # parsed the DECSCUSR would still be showing NORMAL's block.
      ck sess.cursorShape() == csBar
      ck sess.cursorVisible()

      # ---- Esc: back to NORMAL --------------------------------------------
      sess.send(DoubleEscapeBytes)
      discard settledFrame(sess, 5)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "Esc")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel,
                 $kaReturnToNormal)
      checkMode(sess, mmNormal, Green)
      ck sess.cursorShape() == csBlock
      ck not sess.cursorVisible()

      # ---- Ctrl+c: §4.2's "Quit Debugger" ----------------------------------
      # It reaches the application AS A BYTE, which is only true because
      # `enterRawMode` clears ISIG — with the line discipline's default the
      # pty would turn 0x03 into SIGINT and the child would die before reading
      # anything. The frame below is the proof that it did not.
      sess.sendControl('c')
      discard settledFrame(sess, 6)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "Ctrl+c")
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaQuit)
      ck paneRow(sess, keysApp.QuitRow) == keysApp.QuitText
      ck sess.isAlive

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "a pending prefix is visible on a real screen, and completes":
    var sess = spawnChild()
    try:
      discard settledFrame(sess, 0)
      checkField(sess, keysApp.FocusRow, keysApp.FocusLabel, "calltrace")

      # `Ctrl+w` alone: PENDING, and it says so — in the field line AND in the
      # status bar's notification area, which is the row that is on screen in
      # every profile.
      sess.sendKey("ctrl+w")
      discard settledFrame(sess, 1)
      checkField(sess, keysApp.KeyRow, keysApp.KeyLabel, "Ctrl+w")
      checkField(sess, keysApp.KindRow, keysApp.KindLabel, $krPending)
      checkField(sess, keysApp.PendingRow, keysApp.PendingLabel, "Ctrl+w-")
      let bar = paneRow(sess, Rows - 1)
      checkpoint("status bar while pending: '" & bar & "'")
      ck bar.endsWith("Ctrl+w-")
      # The mode did NOT change: a prefix is not a mode.
      checkMode(sess, mmNormal, Green)

      # `l` completes it — §4.2's "Focus the pane to the … right".
      sess.send("l")
      discard settledFrame(sess, 2)
      checkField(sess, keysApp.KindRow, keysApp.KindLabel, $krAction)
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaFocusRight)
      checkField(sess, keysApp.PendingRow, keysApp.PendingLabel, "")
      checkField(sess, keysApp.FocusRow, keysApp.FocusLabel, "editor")
      let cleared = paneRow(sess, Rows - 1)
      checkpoint("status bar after completion: '" & cleared & "'")
      ck not cleared.endsWith("Ctrl+w-")

      # …and `l` ON ITS OWN is a different action entirely — §4.2's "Expand
      # Node" — which is the positive twin that makes the line above a
      # statement about the PREFIX rather than about `l`.
      sess.send("l")
      discard settledFrame(sess, 3)
      checkField(sess, keysApp.ActionRow, keysApp.ActionLabel, $kaExpandNode)
      checkField(sess, keysApp.FocusRow, keysApp.FocusLabel, "editor")

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "the mode indicator has one colour per mode, and no two are the same":
    # A pure assertion about the style table, made HERE because the numbers it
    # names are the ones the two cases above read off a real screen. Keeping it
    # beside them is what stops a palette change from making those absolute
    # assertions wrong without a red run.
    var seen: seq[string] = @[]
    var modesChecked = 0
    for m in [umNormal, umCommand, umSearch, umInspect, umVisual, umSeek]:
      inc modesChecked
      let style = modeStyle(m)
      checkpoint($m & " -> " & describe(style))
      ck style.bold
      ck style.fg.len > 0
      ck style.fg notin seen
      seen.add style.fg
    ck modesChecked == 6
    ck seen.len == 6
    ck modeStyle(umNormal).fg == "green"
    ck modeStyle(umCommand).fg == "yellow"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
