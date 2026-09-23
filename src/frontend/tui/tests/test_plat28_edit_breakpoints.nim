## PLAT-28 — breakpoints in EDIT mode, and breakpoints that move with the text.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat28_edit_breakpoints.nim
##
## CodeTracer-TUI-Edit-Mode.md §3: *"setting a breakpoint while editing is a
## normal thing to do"*. Until 2026-09-23 `F9` in an edit session went to the
## engine's breakpoint service — which an edit session does not have — and
## answered "unavailable", and the session's points (`EditSession.points`)
## held line numbers no edit moved. This suite asserts, without a terminal:
##
##   * `F9` and `:break [line]` toggle a point on the edit session, at the
##     caret or the given line, and refuse by name what they cannot place;
##   * a point follows its line through the edits that matter — a line opened
##     above it moves it down, `dd` on its line removes it (Editor-ViewModel
##     §8.2: *"a breakpoint on a deleted line is not a breakpoint on the line
##     that took its place"*), `J` keeps it — and a point in ANOTHER file is
##     untouched;
##   * Debug mode still sends `F9` to the engine.
##
## NO MOCKS: the real runtime, the real edit session and the shipped keymaps;
## keys enter as the bytes a terminal sends, through `handleToken`.

import std/[strutils, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 40
  FileA = "src/alpha.py"
  TextA = "one\ntwo\nthree\nfour\nfive\n"
  FileB = "src/beta.py"
  F9 = "\x1b[20~"
  Enter = "\r"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(model = kmProductDefault): TuiRuntime =
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession(model)
  discard app.editSession.openFile(FileA, TextA)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.focus.focusPaneKind(paneEditor)

proc runPrompt(rt: TuiRuntime; line: string) =
  discard rt.prompt.open(pkCommand)
  for ch in line:
    discard rt.prompt.applyKey($ch, @[])
  discard rt.handleToken("\r", 0)

proc typeKeys(rt: TuiRuntime; tokens: openArray[string]) =
  var now = 0'i64
  for t in tokens:
    now += 1
    discard rt.handleToken(t, now)

proc linesOf(rt: TuiRuntime; path: string): seq[int] =
  for p in rt.app.editSession.points:
    if p.path == path: result.add p.line

proc caretTo(rt: TuiRuntime; line: int) =
  ## Down from the top, through the keymap, so the caret is where a user's
  ## keys would have put it.
  let buf = rt.app.editSession.activeBuffer()
  while buf.caretLine > line: rt.typeKeys(["\x1b[A"])
  while buf.caretLine < line: rt.typeKeys(["\x1b[B"])

suite "PLAT-28: breakpoints are placed in Edit mode":

  test "F9 toggles a breakpoint at the caret, on the edit session":
    let rt = editingRuntime()
    rt.caretTo(3)
    rt.typeKeys([F9])
    ck rt.linesOf(FileA) == @[3]
    ck rt.app.notification == "breakpoint at " & FileA & ":3"
    ck rt.app.editSession.points[0].kind == sptBreakpoint
    rt.typeKeys([F9])
    ck rt.linesOf(FileA).len == 0
    ck rt.app.notification == "removed the breakpoint at " & FileA & ":3"

  test "`:break N` places one on line N; a name or a missing line is refused":
    let rt = editingRuntime()
    rt.runPrompt(":break 4")
    ck rt.linesOf(FileA) == @[4]
    rt.runPrompt(":break main")
    ck rt.app.notification.startsWith("`main` is not a line number")
    rt.runPrompt(":break 99")
    ck rt.app.notification == FileA & " has no line 99"
    ck rt.linesOf(FileA) == @[4]

  test "Debug mode still sends F9 to the engine":
    let rt = editingRuntime()
    rt.app.modes = initModeRegister(pmDebug)
    rt.typeKeys([F9])
    ck rt.linesOf(FileA).len == 0
    ck not rt.app.notification.startsWith("breakpoint at")

suite "PLAT-28: a breakpoint follows its line":

  test "a line opened ABOVE it moves it down; one opened below does not":
    let rt = editingRuntime()
    rt.runPrompt(":break 3")
    rt.caretTo(1)
    rt.typeKeys([Enter])                    # the product default: a newline
    ck rt.app.editSession.activeBuffer().text == "\none\ntwo\nthree\nfour\nfive\n"
    ck rt.linesOf(FileA) == @[4]
    rt.caretTo(5)
    rt.typeKeys(["\x1b[F", Enter])          # End, then a new line after 5
    ck rt.linesOf(FileA) == @[4]

  test "`dd` on its line REMOVES it; the line that took its place gets nothing":
    let rt = editingRuntime(kmVim)
    rt.runPrompt(":break 2")
    rt.runPrompt(":break 4")
    rt.caretTo(2)
    rt.typeKeys(["d", "d"])
    ck rt.app.editSession.activeBuffer().text == "one\nthree\nfour\nfive\n"
    ck rt.linesOf(FileA) == @[3]            # `four`, one line up

  test "`J` keeps it, on the joined line":
    let rt = editingRuntime(kmVim)
    rt.runPrompt(":break 3")
    rt.caretTo(2)
    rt.typeKeys(["J"])
    ck rt.app.editSession.activeBuffer().text == "one\ntwo three\nfour\nfive\n"
    ck rt.linesOf(FileA) == @[2]

  test "a point in ANOTHER file is not moved by this file's edits":
    let rt = editingRuntime()
    discard rt.app.editSession.togglePointAt(FileB, 2)
    rt.runPrompt(":break 2")
    rt.caretTo(1)
    rt.typeKeys([Enter])
    ck rt.linesOf(FileA) == @[3]
    ck rt.linesOf(FileB) == @[2]
    # …and the model's state is lent the points for one key only.
    ck rt.app.editSession.activeBuffer().doc.state.trackedLines.len == 0

suite "PLAT-28: Vim's and Kakoune's `o` / `O` open a line AND enter insert mode":
  ## Found by this milestone's pty case: both keymaps bound `o` / `O` to
  ## `insert-blank-line-*`, which stays in normal mode, so a Vim user's
  ## `O # new` opened an empty line and then ran `#`, `Space` (a breakpoint)
  ## and `n`, `e`, `w` as commands.

  test "Vim `O` then text: the text is on a new line ABOVE, the breakpoint moves":
    let rt = editingRuntime(kmVim)
    rt.runPrompt(":break 2")
    rt.caretTo(2)
    rt.typeKeys(["O", "#", " ", "n", "e", "w", "\x1b"])
    ck rt.app.editSession.activeBuffer().text == "one\n# new\ntwo\nthree\nfour\nfive\n"
    ck rt.linesOf(FileA) == @[3]

  test "Vim `o` below the LAST line, and Kakoune `o` / `O`":
    let vim = editingRuntime(kmVim)
    vim.caretTo(5)
    vim.typeKeys(["o", "z", "\x1b"])
    ck vim.app.editSession.activeBuffer().text == "one\ntwo\nthree\nfour\nfive\nz\n"
    let kak = editingRuntime(kmKakoune)
    kak.caretTo(3)
    kak.typeKeys(["o", "b", "\x1b", "O", "a", "\x1b"])
    ck kak.app.editSession.activeBuffer().text == "one\ntwo\nthree\na\nb\nfour\nfive\n"

suite "PLAT-28 edit breakpoints — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
