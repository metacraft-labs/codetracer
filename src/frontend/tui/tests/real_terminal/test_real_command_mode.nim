## test_real_command_mode.nim — CTUI-10, Tier 2.
##
## ## What only this file can say
##
## CTUI-10: *"TermAssert: types `:goto 4500\r` as real bytes and asserts the
## resulting screen, using the IPC settled-frame label. Asserts the `:` prompt
## is visible to the terminal via `cursorPosition`."*
##
## Four of `docs/tui-testing.md`'s "only Tier 2 will do" rows are in play and
## none is reachable in process:
##
##   * **keys as bytes** — `:`, `g`, `o`, `t`, `o`, ` `, `4`, `5`, `0`, `0`,
##     `\r` arriving one byte at a time on a real fd, framed by
##     `testing/test_app_runtime.nim`, decoded by `keymap.keyName`, and
##     classified as text-or-command by `modal_state.isTextEntry`.
##   * **cursor position** — "the model has no cursor". The `:` prompt is a
##     prompt only if the terminal's own cursor is sitting in it.
##   * **cursor shape and visibility** — DECSCUSR and DECTCEM, read back out of
##     libvterm's state, saying which §4.1 mode this is.
##   * **real cell attributes** — the mode indicator's colour, as a NUMBER.
##
## ## THE SPACE IN `:goto 4500` IS THE POINT, AND IT FOUND A DEFECT
##
## `keyName(" ")` answers `"Space"`, because §4.2 binds `Space` to "Toggle
## Breakpoint" and a table cell reading ` ` would be unreadable. CTUI-9's
## text-entry shadowing rule asked `isPrintableKey`, which answers false for a
## five-letter name — so a space typed at a `:` prompt resolved to `krNone` and
## was SILENTLY LOST, and `:goto 4500` could not be typed at all. CTUI-9 could
## not have seen it: it had no text field. The fix is
## `keymap.keyCharacter` / `keymap.isTextKey` and the new
## `KeyResolution.character`; THIS CASE is what measures it, on a real pty,
## because the defect is invisible to any test that hands `insert` a string it
## wrote itself.
##
## ## THE BARRIER IS THE CURSOR, AT A POSITION THE APP CHOSE
##
## `apps/app_command_mode.nim` installs a `FrameEpilogue` that parks the cursor
## in the prompt, so `dual_snap.waitForCompleteFrame`'s `(rows-1, cols-1)` can
## never be satisfied while a prompt is open. `waitForCursorAt` is the same
## barrier argument at the position the epilogue writes: the CUP is emitted
## after the last cell of the last row, so the cursor cannot be there before
## the whole frame has been parsed. With no prompt open the epilogue is empty
## and the ordinary barrier holds.
##
## ## EVERY COLOUR IS ASSERTED ABSOLUTELY
##
## `docs/tui-testing.md`: a differential check is blind to any defect both
## tiers share. So the mode indicator is `fg.idx == 2` for NORMAL and
## `fg.idx == 3` for COMMAND — not "different from each other".
##
## ## It does not skip
##
## A child that will not compile, a child that never parks its cursor, a label
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

import ../../app/commands/interpreter
import ../../app/input/modal_state
import ../../app/views/command_line
import ../../app/views/command_palette
import ../../app/views/search
import ../../app/views/status_bar
import ../../app/views/styled_row
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_command_mode as cmdApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 141

const
  Cols = 100
  Rows = 24
  Label = "commandmode"
  Stem = "app_command_mode"
  FrameTimeoutMs = 20000
  LabelTimeoutMs = 10000

  Green = 2'u8      ## NORMAL's indicator colour.
  Yellow = 3'u8     ## COMMAND's.
  Magenta = 5'u8    ## SEARCH's.

  GotoLine = "goto 4500"
    ## CTUI-10's own example, minus the `:` that opens the prompt.
  UnknownLine = "teleport"
  SearchTerm = "shield"
  PaletteQuery = "orig"
    ## A subsequence of `:origin` and of nothing else in §4.3's table.
  DoubleEscapeBytes = "\x1b\x1b"
    ## The only way to deliver a lone `Esc` through this runtime — see
    ## `docs/tui-testing.md` and `real_terminal/test_real_keybindings.nim`.

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
  ## One row of the terminal, with its right-hand padding removed.
  ##
  ## `strutils.strip` IS QUALIFIED, AND THAT IS NOT STYLE. This file imports
  ## `std/unicode` (for `Rune`), and `unicode.strip` — which wins the overload
  ## on an unqualified call — RETURNS AN ALL-WHITESPACE STRING UNCHANGED.
  ## Measured on nim 2.2.8: `unicode.strip(repeat(' ', 10), leading = false)`
  ## answers ten spaces where `strutils.strip` answers "". So a blank row read
  ## through the unqualified spelling is 100 characters long, and an assertion
  ## that a row is EMPTY fails while every assertion about a row with content
  ## passes — which is exactly how this was found.
  strutils.strip(sess.regionText(row, 0, Cols, 1).split('\n')[0],
                 leading = false)

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

template settledClosedFrame(sess: var TuiTestSession; step: int) =
  ## A frame with NO prompt open: the ordinary bottom-right barrier, then the
  ## label — which is what names the frame, per `docs/tui-testing.md`'s rule
  ## that the cursor barrier proves *a* frame is complete and never *your*
  ## frame.
  waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
  sess.send($TestAppCaptureByte)
  discard waitForSnapshotLabel(sess, stepLabel(Label, step), LabelTimeoutMs)

template settledPromptFrame(sess: var TuiTestSession; step, col: int) =
  ## A frame with a prompt open: the cursor parks in the prompt at `col`, which
  ## is the barrier AND the assertion CTUI-10 asks for.
  waitForCursorAt(sess, cmdApp.promptRowOf(Rows), col, FrameTimeoutMs)
  sess.send($TestAppCaptureByte)
  discard waitForSnapshotLabel(sess, stepLabel(Label, step), LabelTimeoutMs)

template checkField(sess: var TuiTestSession; row: int; label, value: string) =
  ## One `LABEL : value` line, read off the terminal.
  let got = paneRow(sess, row)
  checkpoint("row " & $row & ": '" & got & "' want '" &
             cmdApp.fieldText(label, value) & "'")
  ck got == cmdApp.fieldText(label, value)

template checkMode(sess: var TuiTestSession; mode: ModalMode; colour: uint8) =
  ## THE MODE, THREE WAYS: the field line, the status-bar indicator with its
  ## colour as a number, and the cursor the terminal is actually showing.
  checkField(sess, cmdApp.ModeRow, cmdApp.ModeLabel, $mode)
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

template checkCursorAt(sess: var TuiTestSession; wantRow, wantCol: int) =
  ## The parameters are NOT called `row` / `col`: `std/unittest`'s templates are
  ## not hygienic here, and `pos.row` with a parameter named `row` substitutes
  ## the ARGUMENT into the field access — `pos.23`, which does not compile and
  ## whose error names neither the template nor the call.
  let pos = sess.cursorPosition()
  checkpoint("cursorPosition = (" & $pos.row & "," & $pos.col & "), want (" &
             $wantRow & "," & $wantCol & ")")
  ck pos.row == wantRow
  ck pos.col == wantCol

# ---------------------------------------------------------------------------

suite "CTUI-10 Tier 2: the `:` prompt on a real terminal":

  test "`:goto 4500` typed as real bytes, with the cursor in the prompt":
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
      # grounds every field read below in one comparison rather than in nine.
      let initial = cmdApp.initialRows(Cols, Rows)
      var mismatched: seq[string] = @[]
      var rowsCompared = 0
      for row in 0 ..< Rows:
        inc rowsCompared
        let onScreen = paneRow(sess, row)
        let inModel = strutils.strip(initial[row], leading = false)
        if onScreen != inModel:
          mismatched.add "row " & $row & ": terminal '" & onScreen &
            "' model '" & inModel & "'"
      if mismatched.len > 0:
        for m in mismatched:
          checkpoint(m)
      ck mismatched.len == 0
      ck rowsCompared == Rows
      checkMode(sess, mmNormal, Green)
      # NORMAL parks the cursor on the ordinary barrier: there is no prompt.
      checkCursorAt(sess, Rows - 1, Cols - 1)
      checkField(sess, cmdApp.StatusRow, cmdApp.StatusLabel, "")
      checkField(sess, cmdApp.PromptRow, cmdApp.PromptLabel, "")
      ck paneRow(sess, cmdApp.promptRowOf(Rows)).len == 0

      # ---- `:` OPENS THE PROMPT, AND THE CURSOR MOVES INTO IT --------------
      var step = 0
      sess.send(":")
      inc step
      settledPromptFrame(sess, step, 1)
      checkMode(sess, mmCommand, Yellow)
      # THE ASSERTION CTUI-10 NAMES: the prompt is visible to the terminal via
      # `cursorPosition`, at the column the MODEL says the insertion point is.
      var model = initCommandLineModel(pkCommand)
      discard model.open(pkCommand)
      ck model.cursorColumn() == 1
      checkCursorAt(sess, cmdApp.promptRowOf(Rows), model.cursorColumn())
      ck paneRow(sess, cmdApp.promptRowOf(Rows)) == ":"

      # ---- TYPE `goto 4500`, ONE BYTE AT A TIME ---------------------------
      # The SPACE is the interesting byte: `keyName(" ")` is `"Space"`, and
      # under CTUI-9's rule it was not text. See this file's header.
      for ch in GotoLine:
        sess.send($ch)
        inc step
        discard model.insert($ch)
      settledPromptFrame(sess, step, model.cursorColumn())
      ck step == 1 + GotoLine.len
      ck model.buffer == GotoLine
      ck model.cursorColumn() == 1 + GotoLine.len
      checkCursorAt(sess, cmdApp.promptRowOf(Rows), model.cursorColumn())
      checkField(sess, cmdApp.PromptRow, cmdApp.PromptLabel, GotoLine)
      ck paneRow(sess, cmdApp.promptRowOf(Rows)) == ":" & GotoLine
      # THE SPACE REALLY ARRIVED: the buffer on screen contains one, and it is
      # the byte that separates the verb from its argument.
      ck paneRow(sess, cmdApp.promptRowOf(Rows)).contains(" 4500")
      checkMode(sess, mmCommand, Yellow)
      # Nothing has RUN yet — the prompt is still open.
      checkField(sess, cmdApp.StatusRow, cmdApp.StatusLabel, "")
      checkField(sess, cmdApp.ActionRow, cmdApp.ActionLabel, "")

      # ---- `Enter` RUNS IT --------------------------------------------------
      sess.send("\r")
      inc step
      settledClosedFrame(sess, step)
      ck step == 2 + GotoLine.len
      checkMode(sess, mmNormal, Green)
      checkCursorAt(sess, Rows - 1, Cols - 1)
      # THE INTERPRETER'S ANSWER, ON THE TERMINAL. Compared against the same
      # `runCommand` this suite links, so the screen is asserted to be the
      # product's own answer rather than a string this file invented.
      let expected = runCommand(Dispatcher(), CommandContext(),
                                ":" & GotoLine)
      ck expected.invocation.status == csOk
      ck expected.invocation.kind == cmdGoto
      ck expected.invocation.argument == "4500"
      ck expected.dispatch.action == kaSeekToTick
      checkField(sess, cmdApp.StatusRow, cmdApp.StatusLabel,
                 $expected.invocation.status)
      checkField(sess, cmdApp.CommandRow, cmdApp.CommandLabel,
                 $expected.invocation.kind)
      checkField(sess, cmdApp.ArgumentRow, cmdApp.ArgumentLabel,
                 expected.invocation.argument)
      checkField(sess, cmdApp.ActionRow, cmdApp.ActionLabel,
                 $expected.dispatch.action)
      checkField(sess, cmdApp.ResultRow, cmdApp.ResultLabel,
                 $expected.dispatch.status)
      # …and the message is REPORTED rather than empty. This child has no
      # ViewModels, so the honest answer is `unavailable` naming what is
      # missing — CTUI-10's second contract, on a terminal.
      let message = paneRow(sess, cmdApp.MessageRow)
      checkpoint("message row: '" & message & "'")
      ck message.startsWith(cmdApp.MessageLabel)
      ck message.len > cmdApp.MessageLabel.len + 1
      ck expected.dispatch.status == drUnavailable
      ck message.contains("TimelineVM")
      # The prompt row is empty again: the prompt closed on commit.
      checkpoint("prompt row after commit: '" &
                 paneRow(sess, cmdApp.promptRowOf(Rows)) & "'")
      ck paneRow(sess, cmdApp.promptRowOf(Rows)).len == 0

      # ---- AN UNKNOWN COMMAND IS REPORTED, ON THE TERMINAL -----------------
      sess.send(":")
      inc step
      for ch in UnknownLine:
        sess.send($ch)
        inc step
      sess.send("\r")
      inc step
      settledClosedFrame(sess, step)
      let unknown = runCommand(Dispatcher(), CommandContext(),
                               ":" & UnknownLine)
      ck unknown.invocation.status == csUnknown
      checkField(sess, cmdApp.StatusRow, cmdApp.StatusLabel,
                 $unknown.invocation.status)
      let unknownMessage = paneRow(sess, cmdApp.MessageRow)
      checkpoint("unknown message: '" & unknownMessage & "'")
      ck unknownMessage.contains(UnknownLine)
      checkMode(sess, mmNormal, Green)

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "`/` counts matches live on a real screen, and `n` walks them":
    var sess = spawnChild()
    try:
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      sess.send($TestAppCaptureByte)
      discard waitForSnapshotLabel(sess, Label, LabelTimeoutMs)
      var step = 0

      # THE EXPECTED COUNT, from the model AND from an independent oracle, so
      # the number on the terminal is checked against something that is not the
      # matcher.
      let matches = findMatches(cmdApp.SearchCorpus, SearchTerm, false)
      var oracle = 0
      for line in cmdApp.SearchCorpus:
        oracle += line.count(SearchTerm)
      checkpoint("`" & SearchTerm & "` occurs " & $matches.len &
                 " time(s); oracle says " & $oracle)
      ck matches.len == oracle
      ck matches.len > 2

      sess.send("/")
      inc step
      settledPromptFrame(sess, step, 1)
      checkMode(sess, mmSearch, Magenta)
      ck paneRow(sess, cmdApp.promptRowOf(Rows)) == "/"

      for ch in SearchTerm:
        sess.send($ch)
        inc step
      settledPromptFrame(sess, step, 1 + SearchTerm.len)
      ck paneRow(sess, cmdApp.promptRowOf(Rows)) == "/" & SearchTerm
      # THE LIVE COUNT, on a real terminal, before anything is committed.
      var live = initSearchModel(sscSource, sdirForward)
      ck live.updateQuery(cmdApp.SearchCorpus, SearchTerm) == matches.len
      checkField(sess, cmdApp.MatchesRow, cmdApp.MatchesLabel,
                 live.matchCountText())
      ck live.matchCountText() == "[" & $matches.len & "]"

      # `Enter` commits: the count becomes a position in the ring.
      sess.send("\r")
      inc step
      settledClosedFrame(sess, step)
      discard live.commit(1)
      checkField(sess, cmdApp.MatchesRow, cmdApp.MatchesLabel,
                 live.matchCountText())
      ck live.matchCountText() == "[1/" & $matches.len & "]"
      # SEARCH OUTLIVES ITS PROMPT — that is CTUI-9's phase, and it is what
      # makes `n` mean "next match" here and "step over" in NORMAL.
      checkMode(sess, mmSearch, Magenta)

      # `n` walks the ring, on the terminal.
      var walked = 0
      for i in 1 ..< matches.len:
        sess.send("n")
        inc step
        inc walked
        discard live.nextMatch()
      settledClosedFrame(sess, step)
      ck walked == matches.len - 1
      checkField(sess, cmdApp.MatchesRow, cmdApp.MatchesLabel,
                 live.matchCountText())
      ck live.matchCountText() == "[" & $matches.len & "/" & $matches.len & "]"
      # One more wraps, and the model and the terminal agree that it did.
      sess.send("n")
      inc step
      discard live.nextMatch()
      settledClosedFrame(sess, step)
      ck live.wrapped
      checkField(sess, cmdApp.MatchesRow, cmdApp.MatchesLabel,
                 live.matchCountText())
      ck live.matchCountText() == "[1/" & $matches.len & "]"

      # `Esc` leaves SEARCH. Two bytes, because the runtime cannot deliver a
      # lone `\x1b` — see this file's header.
      sess.send(DoubleEscapeBytes)
      inc step
      settledClosedFrame(sess, step)
      checkMode(sess, mmNormal, Green)

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "`Ctrl+p` opens the palette and it filters on a real screen":
    var sess = spawnChild()
    try:
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      sess.send($TestAppCaptureByte)
      discard waitForSnapshotLabel(sess, Label, LabelTimeoutMs)
      var step = 0

      # §4.2 files the palette under "Search and Palette"; `keymap.nim`'s
      # header records the reading that it is a COMMAND-mode surface, and this
      # is that reading on a terminal.
      sess.sendKey("ctrl+p")
      inc step
      settledPromptFrame(sess, step, 1)
      checkMode(sess, mmCommand, Yellow)
      let title = paneRow(sess, cmdApp.PaletteTopRow)
      checkpoint("palette title row: '" & title & "'")
      ck title.startsWith(command_palette.PaletteTitle)
      # THE DISCOVERY VIEW: §4.3's first command is the first row.
      ck paneRow(sess, cmdApp.PaletteTopRow + 2).contains(
        ":" & Spec43Commands[0].name)

      # Typing filters it.
      for ch in PaletteQuery:
        sess.send($ch)
        inc step
      settledPromptFrame(sess, step, 1 + len(PaletteQuery))
      let filtered = paneRow(sess, cmdApp.PaletteTopRow + 2)
      checkpoint("top palette hit: '" & filtered & "'")
      ck filtered.contains(":origin")
      # …and the row BELOW the last hit is not another command, because there
      # are fewer hits than the discovery view had.
      ck not paneRow(sess, cmdApp.PaletteTopRow + 3).contains(":step")

      sess.send(DoubleEscapeBytes)
      inc step
      settledClosedFrame(sess, step)
      checkMode(sess, mmNormal, Green)
      ck paneRow(sess, cmdApp.PaletteTopRow).len == 0

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
