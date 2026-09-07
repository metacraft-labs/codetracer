## test_real_layout_gestures.nim — PLAT-6, Tier 2.
##
## ## What only this file can say
##
## PLAT-6's milestone note: *"No gesture is driven through a real pty, because
## the binding is not enabled in a running session."* This is the row, closed.
##
## `apps/app_layout_gestures.nim` hosts the SAME `TuiRuntime` `main.nim` builds,
## with PLAT-6's layout binding opted in exactly the way `main.nim` opts it in
## under `--layout-binding`. This file spawns it in a real pty and types
## `:dock bottom\r` one byte at a time. Every step of the path is the product's:
##
##   * the bytes arrive on a real file descriptor and are framed by
##     `host/terminal_driver.InputFramer` — the same framer the shipped driver
##     runs;
##   * `keymap.resolve` decides that `:` opens a prompt and that the letters
##     after it are TEXT rather than commands (CTUI-9's shadowing rule);
##   * `command_line.applyKey` builds the buffer and `Enter` submits it;
##   * `runtime.runPromptLine` recognises the first word as a layout verb and
##     hands the line to `binding.runLayoutCommand`;
##   * `layout_model.apply` decides, and the next frame is painted from what it
##     decided.
##
## None of that is observable from Tier 1. `app/tests/
## test_layout_command_routing.nim` asserts the same route in process and owns
## the parts a terminal cannot answer — the resulting `Layout`, and the screen a
## runtime with no binding paints.
##
## ## THE ASSERTION THAT WOULD CATCH BOTH TIERS BEING WRONG TOGETHER
##
## Comparing the terminal with the in-process model is a DIFFERENTIAL check and
## is blind to any defect the two share — `docs/tui-testing.md` says so, and
## PLAT-6's own status note says so about cross-tier equality. So the row-for-row
## comparison below is paired with assertions made against the SPECIFICATION of
## the decoration rather than against the model's rendering of it: after the
## gesture, the body's last row must be `binding.DockStripGlyph` in every cell
## the pane's own title does not occupy, and the pane's `CALL STACK ───` title
## row must be gone from the screen entirely. A binding that had stopped docking
## — and a renderer that had stopped drawing strips — would fail those whatever
## the two tiers agreed about.
##
## ## It does not skip
##
## A child that will not compile, a child that never parks its cursor, a prompt
## that never opens: every one FAILS by name with the position actually
## observed and the screen that was on it. There is no `when false`, no early
## return on a missing prerequisite, and no `try/except` that turns a failure
## into a pass.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine, driven by real key bytes. The child's `Dispatcher` carries no
## ViewModels, which is not a stand-in for one:
## `app/commands/interpreter.nim` documents nil as "not wired" and answers
## `drUnavailable` by name — and the twelve layout verbs need no debugger at
## all, which is why they are a separate surface.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc` sets a
## module-level global and the case still reports `[OK]` with its failed
## comparison printed directly above it.

import std/[options, strutils, times, unicode, unittest]

import term_assert

import headless_app/layout_model

import ../../app/runtime
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_layout_gestures as gestureApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 46

const
  Stem = "app_layout_gestures"
  Cols = gestureApp.Cols
  Rows = gestureApp.Rows
  FrameTimeoutMs = 20000

  DockLine = "dock bottom"
    ## THE GESTURE. `:dock <edge>` was chosen over `:move-tab` for one reason:
    ## its effect is legible on a terminal without reference to the model. A
    ## docked pane leaves the tree for a one-row strip along the body's edge,
    ## so the screen gains a row of `·` carrying the pane's title and loses that
    ## pane's own title row — two facts a `regionText` can be asked about
    ## directly.
  UndoLine = "undo-layout"

  DockedPaneKind = paneCalltrace
    ## The Compact profile's first projected region, and therefore the pane
    ## `newPaneFocus` starts on. Spelled as a constant and ASSERTED below rather
    ## than assumed: a profile change that moved the first region would
    ## otherwise silently make this case about a different pane.
  DockedPaneTitle = "Call Stack"
  DockedPaneTitleRow = "CALL STACK"

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc paneRow(sess: var TuiTestSession; row: int): string =
  ## One row of the terminal, with its right-hand padding removed.
  ##
  ## `strutils.strip` IS QUALIFIED, AND THAT IS NOT STYLE. This file imports
  ## `std/unicode` for `Rune`, and `unicode.strip` — which wins the overload on
  ## an unqualified call — returns an all-whitespace string UNCHANGED, so an
  ## assertion that a row is empty fails while every assertion about a row with
  ## content passes. Measured on nim 2.2.8; see
  ## `test_real_command_mode.nim`'s note.
  strutils.strip(sess.regionText(row, 0, Cols, 1).split('\n')[0],
                 leading = false)

proc spawnChild(): TuiTestSession =
  compileChildApp(Stem)
  newTuiTest(appBinaryPath(Stem),
             @["--cols=" & $Cols, "--rows=" & $Rows])
    .width(Cols).height(Rows)
    .spawn()

proc tokensOf(line: string): seq[string] =
  ## `:`, every character, then `Enter` — as the tokens a terminal delivers.
  result = @[":"]
  for ch in line:
    result.add $ch
  result.add "\r"

proc bottomStripRow(rt: TuiRuntime): int =
  ## Where the binding says a bottom dock strip is, read from its own geometry.
  for s in rt.layoutGeometry().strips:
    if s.edge == leBottom:
      return s.area.row
  -1

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template typeAt(sess: var TuiTestSession; line: string) =
  ## Type `:<line>` and press Enter, waiting on an EXACT barrier at every
  ## observable step rather than sleeping.
  ##
  ##   * `:` opens the prompt, which moves the cursor OFF the bottom-right
  ##     barrier and into the prompt at column 1;
  ##   * every character moves it one column further right;
  ##   * `Enter` closes the prompt, which puts it BACK on the bottom-right cell.
  ##
  ## Each of those is a position the cursor was not at a moment earlier, which
  ## is what makes it a barrier rather than a poll that is satisfied by the
  ## previous frame.
  block:
    sess.send(":")
    waitForCursorAt(sess, Rows - 1, 1, FrameTimeoutMs)
    ck paneRow(sess, Rows - 1) == ":"
    for ch in line:
      sess.send($ch)
    waitForCursorAt(sess, Rows - 1, 1 + line.len, FrameTimeoutMs)
    let onPrompt = paneRow(sess, Rows - 1)
    checkpoint("prompt reads: '" & onPrompt & "'")
    ck onPrompt == ":" & line
    sess.send("\r")
    waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)

template ckScreenMatches(sess: var TuiTestSession; want: seq[string];
                         label: string) =
  ## Every row of the terminal against every row the in-process runtime
  ## painted. A DIFFERENTIAL check — see this file's header on what it cannot
  ## see and what is asserted beside it.
  block:
    var compared = 0
    var stale: seq[string] = @[]
    for row in 0 ..< Rows:
      inc compared
      let got = paneRow(sess, row)
      let expected = strutils.strip(want[row], leading = false)
      if got != expected:
        stale.add "row " & $row & ":\n  model:    '" & expected &
          "'\n  terminal: '" & got & "'"
    if stale.len > 0:
      checkpoint(label & ":\n" & stale[0 .. min(4, stale.high)].join("\n"))
    ck compared == Rows
    ck stale.len == 0

# ---------------------------------------------------------------------------

suite "PLAT-6 Tier 2: a layout gesture through a real pty":

  test "`:dock bottom` typed as real bytes rearranges a real terminal":
    var sess = spawnChild()
    try:
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      # THE POSITIVE CONTROL on every comparison below: a screen that parsed to
      # nothing satisfies a `strip()`-wise equality for free.
      ck sess.screenContents().strip().len > 0

      # THE IN-PROCESS TWIN, built through the app's OWN constructor so the two
      # runtimes are the same two calls rather than two readings of them.
      let model = gestureApp.newBoundRuntime(Cols, Rows)
      ck model.layoutBindingEnabled()
      let (hadFocus, focused) = model.focus.focusedPane()
      ck hadFocus
      checkpoint("the focused pane is " & $focused)
      ck focused == DockedPaneKind

      # ---- THE UNGESTURED SCREEN -------------------------------------------
      ckScreenMatches(sess, model.shellScreenOf().rows, "before the gesture")
      # ABSOLUTE, not differential: there is no dock strip yet, and the pane
      # that is about to be docked is on the screen under its own title.
      let before = sess.screenContents()
      ck not before.contains(DockStripGlyph)
      ck before.contains(DockedPaneTitleRow)
      # …and the Compact profile's tab stack is there, which is what says this
      # is the arrangement the case was written against.
      ck before.contains("[Variables]")
      ck model.bottomStripRow() < 0

      # ---- THE GESTURE, ONE BYTE AT A TIME ---------------------------------
      typeAt(sess, DockLine)
      # The same tokens through the in-process runtime, so the model's answer
      # is produced by the same path rather than by a shortcut.
      var driven = 0
      for token in tokensOf(DockLine):
        discard model.handleToken(token, 0'i64)
        inc driven
      ck driven == DockLine.len + 2

      # THE MODEL. Only the layout can be asked whether the pane left the tree.
      checkpoint("after the gesture: " & model.app.notification)
      ck model.app.layoutBinding.layout.dockedIndex(DockedPaneKind) >= 0
      ck not model.app.layoutBinding.layout.tree.contains(DockedPaneKind)
      ck model.app.layoutBinding.userModified

      # THE TERMINAL, differentially…
      ckScreenMatches(sess, model.shellScreenOf().rows, "after :dock bottom")

      # …AND ABSOLUTELY. This is the pair that survives both tiers being wrong
      # together: the strip's cells are asserted against `DockStripGlyph` and
      # the pane's title against the pane's own name, neither of which is read
      # off the model's rendering.
      let stripRow = model.bottomStripRow()
      checkpoint("the bottom dock strip is on row " & $stripRow)
      ck stripRow > 0
      ck stripRow == Rows - 2          ## the body's last row, above the status
      let stripText = sess.regionText(stripRow, 0, Cols, 1).split('\n')[0]
      checkpoint("strip row: '" & stripText & "'")
      ck stripText.startsWith(DockedPaneTitle)
      var glyphCells = 0
      var wrongCells: seq[string] = @[]
      for col in textCells(DockedPaneTitle) ..< Cols:
        let rune = $sess.cellAt(stripRow, col).rune
        if rune == DockStripGlyph:
          inc glyphCells
        else:
          wrongCells.add "(" & $stripRow & "," & $col & ") is '" & rune & "'"
      if wrongCells.len > 0:
        checkpoint(wrongCells[0 .. min(4, wrongCells.high)].join(", "))
      # EXACT, not "more than none" (Verification-Harness-Traps §4b): the strip
      # spans the body's full width and the label takes its first cells, so the
      # number of glyph cells is knowable.
      ck glyphCells == Cols - textCells(DockedPaneTitle)
      ck wrongCells.len == 0
      # AND THE PANE IS GONE FROM THE BODY. A strip drawn beside a pane that
      # was never removed would satisfy every assertion above.
      let after = sess.screenContents()
      ck not after.contains(DockedPaneTitleRow)
      ck after.contains(DockStripGlyph)

      # ---- `:undo-layout` PUTS IT BACK, ON THE TERMINAL --------------------
      typeAt(sess, UndoLine)
      for token in tokensOf(UndoLine):
        discard model.handleToken(token, 0'i64)
      ck model.app.layoutBinding.layout.dockedIndex(DockedPaneKind) < 0
      ck model.bottomStripRow() < 0
      let restored = sess.screenContents()
      ck not restored.contains(DockStripGlyph)
      ck restored.contains(DockedPaneTitleRow)
      ckScreenMatches(sess, model.shellScreenOf().rows, "after :undo-layout")

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "a word that is not a layout verb still reaches §4.3, on the terminal":
    # THE NEGATIVE TWIN of the case above, through the same prompt and the same
    # binary. The routing is a PREFIX rather than a replacement, and a child
    # that had started swallowing every `:` line would pass every assertion in
    # the first case.
    var sess = spawnChild()
    try:
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      ck sess.screenContents().strip().len > 0
      let model = gestureApp.newBoundRuntime(Cols, Rows)

      typeAt(sess, "teleport")
      for token in tokensOf("teleport"):
        discard model.handleToken(token, 0'i64)
      checkpoint("`:teleport` -> " & model.app.notification)
      # §4.3's interpreter answered, by name, and the layout did not move.
      ck model.app.notification.toLowerAscii().contains("unknown command")
      ck not model.app.layoutBinding.userModified
      # The terminal says the same thing, and it says it on the status row.
      let status = paneRow(sess, Rows - 1)
      checkpoint("status row: '" & status & "'")
      ck status.toLowerAscii().contains("teleport")
      ck not sess.screenContents().contains(DockStripGlyph)
      ckScreenMatches(sess, model.shellScreenOf().rows, "after :teleport")

      sess.send($TestAppQuitByte)
      let exited = sess.waitExit(initDuration(seconds = 10))
      ck exited.isSome
      ck exited.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
