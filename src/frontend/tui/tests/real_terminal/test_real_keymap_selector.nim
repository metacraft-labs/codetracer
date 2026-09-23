## test_real_keymap_selector.nim — PLAT-43, Tier 2.
##
## Run (needs `just build-tui`):
##   nim c -r <tui-real-terminal lane flags> \
##     src/frontend/tui/tests/real_terminal/test_real_keymap_selector.nim
##
## ## WHAT ONLY THIS FILE CAN SAY
##
## PLAT-31 built Vim and Kakoune keymaps and graded them in-process; its three
## real-stack boxes stayed unticked because *"driving them through a pty would
## mean first shipping a model selector in the TUI"*. PLAT-43 shipped it
## (`:keymap <name>`, remembered across sessions), and this suite drives it
## through **the shipped binary** in a real pty:
##
##   * a KEY selects each of the three models, and the choice is on disk;
##   * the choice SURVIVES A RESTART — the next session edits under it;
##   * an unknown model is refused BY NAME, typed and stored;
##   * `DIFF-12`/`DIFF-4` with the driver PLAT-31 lacked: every one of PLAT-31's
##     38 divergent tasks, under Vim and under Kakoune, typed as real bytes into
##     the binary and saved with `:w`, produces ON DISK the document the same
##     key names produce in-process through the same model.
##
## ## THE KEY-SYNTHESISER ASSERTION (Verification-Harness-Traps §25)
##
## A driver that drops a modifier hands you a test about a different key. So
## every key name this suite sends is first turned into bytes by `keyBytes`
## and then decoded back by the terminal's OWN decoder (`key_names.keyName`,
## the function the binary runs on the bytes it reads) — and the round trip is
## asserted, for every key, before any key is sent.
##
## NO MOCKS: a real pty, the shipped binary, a real project directory and a
## real state directory (`CODETRACER_TUI_LAYOUT_DIR`, PLAT-6's hook).

import std/[monotimes, os, sequtils, strutils, times, unittest]

import term_assert

import codetracer_embed
import ../../../../common/key_names
import ../../app/edit_binding
import ../../../viewmodel/tests/generators/keymap_task_set
import ./lifecycle_support

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 140
  Rows = 40
  FrameTimeoutMs = 20000
  ProjectFile = "doc.txt"
  QuitByte = "q"
  Tab = "\t"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  KeymapFile = "keymap"

proc keyBytes(name: string): string =
  ## The xterm bytes for one canonical key name. The inverse of
  ## `key_names.keyName` for the keys this suite uses — and asserted to BE its
  ## inverse, key by key, in the first case.
  ## https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  case name
  of "Esc": "\x1b"
  of "Enter": "\r"
  of "Tab": "\t"
  of "Backspace": "\x7f"
  of "Space": " "
  of "Up": "\x1b[A"
  of "Down": "\x1b[B"
  of "Right": "\x1b[C"
  of "Left": "\x1b[D"
  else:
    if name.startsWith("Ctrl+"):
      let rest = name[5 .. ^1]
      case rest
      of "Up": "\x1b[1;5A"
      of "Down": "\x1b[1;5B"
      of "Right": "\x1b[1;5C"
      of "Left": "\x1b[1;5D"
      else:
        if rest.len == 1 and rest[0] in 'a'..'z':
          $char(ord(rest[0]) - ord('a') + 1)
        else: ""
    elif name.len == 1: name
    else: ""

proc asciiDoc(): ScenarioDoc =
  ## The first corpus document that is pure ASCII: caret placement below is
  ## `Down`s and `Right`s, and on ASCII a column is a byte is a grapheme.
  for d in scenarioDocs():
    if d.text.allIt(ord(it) < 128):
      return d
  raise newException(AssertionDefect, "no ASCII scenario document")

proc lineCol(text: string; offset: int): (int, int) =
  var line = 0
  var col = 0
  for i in 0 ..< min(offset, text.len):
    if text[i] == '\n':
      inc line
      col = 0
    else:
      inc col
  (line, col)

proc navKeys(d: ScenarioDoc; t: EditingTask): seq[string] =
  let (line, col) = lineCol(d.text, caretOffset(d, t.caret))
  for _ in 0 ..< line: result.add "Down"
  for _ in 0 ..< col: result.add "Right"

proc divergentTasks(): seq[EditingTask] =
  for t in TaskSet:
    if t.id notin CoincidentOperationTasks:
      result.add t

proc stateDirFor(name: string): string =
  result = lifecycle_support.repoRoot() / "test-logs" / "plat43-state" / name
  removeDir(result)
  createDir(result)

proc projectFor(name, text: string): string =
  result = lifecycle_support.repoRoot() / "test-logs" / "plat43-project" / name
  removeDir(result)
  createDir(result)
  writeFile(result / ProjectFile, text)

proc spawnEditor(project, stateDir: string): TuiTestSession =
  newTuiTest(tuiBinary(), @["--edit", project])
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet(StateDirEnvVar, stateDir)
    .spawn()

proc waitForScreenText(sess: var TuiTestSession; needle: string;
                       timeoutMs = FrameTimeoutMs): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    if last.contains(needle):
      return last
    if not sess.isAlive:
      raise newException(AssertionDefect,
        "the binary exited before '" & needle & "' appeared; screen was:\n" & last)
  raise newException(AssertionDefect,
    "'" & needle & "' never appeared within " & $timeoutMs & " ms; screen:\n" & last)

proc sendKey(sess: var TuiTestSession; name: string) =
  ## One key, as bytes. A lone ESC is followed by a pause long enough that the
  ## next byte cannot be read as the rest of an escape sequence.
  sess.send(keyBytes(name))
  discard sess.drainOutput(if name == "Esc": 250 else: 30)

proc quit(sess: var TuiTestSession) =
  sess.send(QuitByte)
  discard sess.waitExit(initDuration(seconds = 10))
  sess.close()

proc selectByKeys(sess: var TuiTestSession; name: string): string =
  ## `Tab` off the editor, then `:keymap <name>` typed and submitted.
  sess.send(Tab)
  discard waitForScreenText(sess, "focus ")
  sess.send(":keymap " & name & "\r")
  waitForScreenText(sess, "keymap")

proc saveByKeys(sess: var TuiTestSession) =
  ## Leave any insert mode (`Esc` changes no text), `Tab` off the editor, `:w`.
  sess.sendKey("Esc")
  sess.send(Tab)
  discard waitForScreenText(sess, "focus ")
  sess.send(":w\r")
  discard waitForScreenText(sess, "wrote " & ProjectFile)

proc inProcess(model: KeymapModel; text: string; keys: seq[string]): string =
  ## The same key NAMES through the same model, in-process — the document the
  ## binary's bytes must reproduce.
  let s = newEditSession(model)
  discard s.openFile(ProjectFile, text)
  let buf = s.activeBuffer()
  var now = 0'i64
  for k in keys:
    inc now
    discard buf.applyEditKey(k, now)
  buf.text

suite "PLAT-43 Tier 2: the keymap selector in a real terminal":

  test "the binary exists, and the key synthesiser is the decoder's inverse":
    ck fileExists(tuiBinary())
    var used = @["Esc", "Tab", "Enter", "Up", "Down", "Left", "Right"]
    for t in divergentTasks():
      for k in t.vimKeys & t.kakouneKeys:
        if k notin used: used.add k
    for k in used:
      let bytes = keyBytes(k)
      checkpoint(k & " -> " & bytes.escape)
      ck bytes.len > 0
      ck keyName(bytes) == k

  test "a KEY selects each model, the choice is on disk, and a restart keeps it":
    let d = asciiDoc()
    for model in KeymapModel:
      let state = stateDirFor("select-" & $model)
      let project = projectFor("select-" & $model, d.text)
      var sess = spawnEditor(project, state)
      try:
        discard waitForScreenText(sess, "EDIT " & ProjectFile)
        let told = selectByKeys(sess, $model)
        checkpoint(told.splitLines()[^1])
        ck told.contains("keymap " & $model)
      finally:
        sess.quit()
      ck readFile(state / KeymapFile) == $model & "\n"

      # THE RESTART. `x` is the probe: Vim deletes the character under the
      # caret, Kakoune deletes the selection (the first character), and the
      # product default inserts an `x`. The expectation is computed, not
      # typed: the same key through the same model, in-process.
      var again = spawnEditor(project, state)
      try:
        discard waitForScreenText(again, "EDIT " & ProjectFile)
        again.sendKey("x")
        again.saveByKeys()
      finally:
        again.quit()
      let onDisk = readFile(project / ProjectFile)
      let expected = inProcess(model, d.text, @["x", "Esc"])
      checkpoint($model & ": on disk starts " & onDisk[0 ..< min(12, onDisk.len)].escape)
      ck onDisk == expected

  test "an unknown model is refused by name — typed, and stored":
    let d = asciiDoc()
    let state = stateDirFor("refused")
    writeFile(state / KeymapFile, "nano\n")
    let project = projectFor("refused", d.text)
    var sess = spawnEditor(project, state)
    try:
      let opened = waitForScreenText(sess, "'nano'")
      ck opened.contains("'nano'")
      let typed = selectByKeys(sess, "emacs")
      discard waitForScreenText(sess, "'emacs'")
      ck sess.screenContents().contains("'emacs'")
      checkpoint(typed.splitLines()[^1])
    finally:
      sess.quit()
    # The refused preference is left as evidence, and the refused command
    # wrote nothing.
    ck readFile(state / KeymapFile) == "nano\n"

  test "DIFF-12 through the binary: PLAT-31's divergent tasks, Vim and Kakoune":
    let d = asciiDoc()
    let tasks = divergentTasks()
    ck tasks.len == DivergentOperationTasks
    var compared = 0
    var mismatches: seq[string] = @[]
    for model in [kmVim, kmKakoune]:
      for t in tasks:
        let taskKeys = if model == kmVim: t.vimKeys else: t.kakouneKeys
        let keys = navKeys(d, t) & taskKeys
        let name = $model & "-" & t.id
        let state = stateDirFor(name)
        writeFile(state / KeymapFile, $model & "\n")
        let project = projectFor(name, d.text)
        var sess = spawnEditor(project, state)
        try:
          discard waitForScreenText(sess, "EDIT " & ProjectFile)
          for k in keys:
            sess.sendKey(k)
          sess.saveByKeys()
        finally:
          sess.quit()
        let onDisk = readFile(project / ProjectFile)
        let expected = inProcess(model, d.text, keys & @["Esc"])
        inc compared
        if onDisk != expected:
          mismatches.add name
    checkpoint("mismatches: " & mismatches.join(", "))
    ck compared == 2 * DivergentOperationTasks
    ck mismatches.len == 0

suite "PLAT-31 Tier 2: a pending prefix times out at its bound, on a real pty":
  ## PLAT-31's last real-stack box. The bound is asserted EXACTLY at the value
  ## level (`editing_keymap`'s `nowMs` parameter: at, one before and one past
  ## `EditingPendingTimeoutMs`); what only a pty can say is that the SHIPPED
  ## binary reads the clock at all — that a `d` a user typed and walked away
  ## from is not still waiting when they come back. Real time cannot be held
  ## to a millisecond, so the two sides are asserted with margins that dwarf
  ## scheduling noise: a second key 30 ms after the first, and one
  ## `PastBoundMs` after it.

  const PastBoundMs = int(EditingPendingTimeoutMs) + 900

  proc typedUnderVim(name: string; keys: seq[string]; pauseAfterFirstMs: int): string =
    let d = asciiDoc()
    let state = stateDirFor(name)
    writeFile(state / KeymapFile, "vim\n")
    let project = projectFor(name, d.text)
    var sess = spawnEditor(project, state)
    try:
      discard waitForScreenText(sess, "EDIT " & ProjectFile)
      for i, k in keys:
        sess.sendKey(k)
        if i == 0 and pauseAfterFirstMs > 0:
          # A WALL-CLOCK pause. `drainOutput` returns once the terminal goes
          # quiet, which it does within milliseconds of a `d` that draws
          # nothing — measured: a "pause" through it was no pause at all.
          sleep(pauseAfterFirstMs)
      sess.saveByKeys()
    finally:
      sess.quit()
    readFile(project / ProjectFile)

  test "within the bound `g` `U` `w` upper-cases a word; past it the `g` is gone":
    # `g U` is a CHORD in the resolver's trie (`vim_keymap`'s `operatorRows`),
    # which is what the bound governs. Not `d`: that enters Vim's
    # operator-pending MODE, which — as in Vim — waits without a timeout.
    let original = asciiDoc().text
    let composed = typedUnderVim("prefix-within", @["g", "U", "w"], 0)
    let expected = inProcess(kmVim, original, @["g", "U", "w", "Esc"])
    ck composed == expected
    ck composed != original
    # PAST THE BOUND: the `g` has been dropped when `U` arrives, so the chord
    # never completes and the file is written back unchanged.
    let timedOut = typedUnderVim("prefix-past", @["g", "U", "w"], PastBoundMs)
    ck timedOut == original

suite "PLAT-36 Tier 2: a `:source`d mapping, typed on a real pty":
  ## PLAT-36's real-stack box: a TRANSLATED mapping driven through the
  ## shipped binary, asserted to produce the document the same keystrokes'
  ## right-hand side produces under the hand-written Vim keymap. The
  ## configuration is a real file in the project; `:source` is typed, the
  ## mapped key is typed, `:w` writes, and the file ON DISK is compared.
  ##
  ## Two mappings, both rows of `DIFF-5`'s table: `Q` → `D` is one operation,
  ## `Z` → `jJ` is two and so replays through the macro the import installs —
  ## the path that only works if `:source` installed the macros as well as
  ## the bindings.

  const
    VimrcFile = "vimrc"
    Vimrc = "nnoremap Q D\nnnoremap Z jJ\n"
    ShiftTab = "\x1b[Z"

  proc typedAfterSource(name: string; keys: seq[string]): string =
    let d = asciiDoc()
    let state = stateDirFor(name)
    let project = projectFor(name, d.text)
    writeFile(project / VimrcFile, Vimrc)
    var sess = spawnEditor(project, state)
    try:
      discard waitForScreenText(sess, "EDIT " & ProjectFile)
      sess.send(Tab)
      discard waitForScreenText(sess, "focus ")
      sess.send(":source " & VimrcFile & "\r")
      let told = waitForScreenText(sess, "sourced " & VimrcFile)
      checkpoint(told.splitLines().filterIt(it.contains("sourced")).join(" | "))
      ck told.contains("2 of 2 mapping line(s) translated")
      # Back onto the editor: `Shift+Tab` is the focus ring's reverse step,
      # and never the editor's key (PLAT-43's ownership case).
      sess.send(ShiftTab)
      discard sess.drainOutput(100)
      for k in keys:
        sess.sendKey(k)
      sess.saveByKeys()
    finally:
      sess.quit()
    # `:source` is a session's choice and is not remembered.
    ck not fileExists(state / KeymapFile)
    readFile(project / ProjectFile)

  test "`Q` is `D` and `Z` is `jJ`, through the binary, on disk":
    let original = asciiDoc().text
    for (name, mapped, rhs) in [("source-single", @["Q"], @["D"]),
                                ("source-macro", @["Z", "Z"],
                                 @["j", "J", "j", "J"])]:
      let onDisk = typedAfterSource(name, mapped)
      let expected = inProcess(kmVim, original, rhs & @["Esc"])
      checkpoint(name & ": on disk starts " &
                 onDisk[0 ..< min(24, onDisk.len)].escape)
      ck onDisk == expected
      ck onDisk != original

suite "PLAT-43 Tier 2 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
