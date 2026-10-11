## test_plat68_keymaps_pty.nim — PLAT-68 Phase A, Tier 2: the CUA default,
## the key decoders and the terminal's key protocol, through the SHIPPED
## binary on a real pty.
##
## Run (needs `just build-tui`):
##   nim c -r <tui-real-terminal lane flags> \
##     src/frontend/tui/tests/real_terminal/test_plat68_keymaps_pty.nim
##
## WHAT ONLY THIS FILE CAN SAY — the milestone's real-stack boxes for Phase A:
##
##   * **CUA, no stored preference.** Edit mode opens under CUA; typed text,
##     `Shift+Right` ×3, `Ctrl+C`, `End`, `Ctrl+V`, `Ctrl+Z`, `Ctrl+Y`,
##     `Ctrl+Shift+K` as `CSI 107 ; 6 u`, `Home` / `End` in every xterm
##     spelling, `Ctrl+S` — and the file ON DISK equals the document the same
##     key names produce in-process through the same base. The legacy fallback
##     `Ctrl+K Ctrl+K` deletes the line on a terminal that negotiated legacy,
##     and does nothing on one that negotiated the Kitty protocol.
##   * **Negotiation** (Base-Keymaps §7.2): the binary's query bytes are read off
##     the pty; the reply is written as the protocol specifies; the push
##     (`CSI > 1 u`) or `modifyOtherKeys` (`CSI > 4 ; 2 m`) follows; and after
##     SIGTERM, SIGHUP and a crash (SIGSEGV) the pop (`CSI < u`) or reset
##     (`CSI > 4 ; 0 m`) is in the bytes the binary wrote (KL-9).
##     `--capabilities` names the negotiated protocol.
##   * **Base switching.** `:keymap emacs`, `vim`, `kakoune`, `cua` each change
##     the document one fixed keystroke sequence produces; `--keymap` overrides
##     the stored value for one session and does not persist; a stored
##     `default` becomes `cua` with the notice, once, and the file is rewritten.
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK. No emulator that implements the
## Kitty keyboard protocol runs in CI, and the harness's libvterm does not
## answer `CSI ? u`. So this suite answers it: when the binary's query is in the
## bytes it wrote, the suite writes `CSI ? 1 u` (Kitty flags: disambiguate)
## and then the DA1 fence, exactly as the Kitty keyboard specification says a
## terminal implementing it does. Nothing of the binary is replaced — the
## bytes are the protocol's, and the binary under test reads them through its
## own framer and probe. The same suite is to be run by hand on kitty, foot,
## WezTerm and Ghostty, with the results recorded in PLAT-68's status.
##
## THE KEY-SYNTHESISER ASSERTION (Verification-Harness-Traps §25): every key
## name this suite sends is turned into bytes by `keyBytes` and decoded back by
## the terminal's own decoder (`key_names.keyName`) before any session starts —
## a driver that dropped a modifier would otherwise hand us a test about a
## different key.
##
## NO MOCKS: a real pty, the shipped binary, real project and state
## directories (`CODETRACER_TUI_LAYOUT_DIR`), files read back from disk.

import std/[monotimes, os, posix, strutils, times, unittest]

import term_assert

import codetracer_embed
import ../../../../common/key_names
import ../../app/edit_binding
import ./lifecycle_support

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedChecks = 133
    ## Measured 2026-10-11 (132 + the sequence test's save, asserted after
    ## its document). A case that stopped running is not a case that passed.
  Cols = 140
  Rows = 40
  FrameTimeoutMs = 20000
  ProjectFile = "doc.txt"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  KeymapFile = "keymap"
  KittyQuery = "\e[?u"
  KittyReply = "\e[?1u"
  Da1Reply = "\e[?62;22c"
  KittyPush = "\e[>1u"
  KittyPop = "\e[<u"
  MokOn = "\e[>4;2m"
  MokOff = "\e[>4;0m"
  Pause = "<pause>"
    ## Not a key: a wall-clock pause longer than the undo grouping delay, so
    ## the edits on either side are two undo steps in the binary as in-process.
  PauseMs = 700

proc keyBytes(name: string): string =
  ## The bytes for one canonical key name, in the encoding a terminal on the
  ## negotiated protocol sends. The inverse of `keyName`, asserted key by key.
  case name
  of "Esc": "\e"
  of "Enter": "\r"
  of "Tab": "\t"
  of "Backspace": "\x7f"
  of "Space": " "
  of "Up": "\e[A"
  of "Down": "\e[B"
  of "Right": "\e[C"
  of "Left": "\e[D"
  of "End": "\e[F"
  of "F6": "\e[17~"
  of "Shift+Right": "\e[1;2C"
  of "Shift+Left": "\e[1;2D"
  of "Ctrl+Shift+k": "\e[107;6u"
  of "Ctrl+Space": "\x00"
  else:
    if name.startsWith("Ctrl+") and name.len == 6 and name[5] in 'a'..'z':
      $char(ord(name[5]) - ord('a') + 1)
    elif name.startsWith("Alt+") and name.len == 5:
      "\e" & name[4]
    elif name.len == 1: name
    else: ""

const
  HomeEndSpellings = [("\e[H", "Home"), ("\e[F", "End"), ("\eOH", "Home"),
                      ("\eOF", "End"), ("\e[1~", "Home"), ("\e[4~", "End"),
                      ("\e[7~", "Home"), ("\e[8~", "End")]
    ## Every xterm spelling of the two keys
    ## (`issues/2026-10-10-tui-key-decoder-drops-home-and-end.md`), each sent
    ## as itself rather than through `keyBytes`.

proc stateDirFor(name: string): string =
  result = lifecycle_support.repoRoot() / "test-logs" / "plat68-state" / name
  removeDir(result)
  createDir(result)

proc projectFor(name, text: string): string =
  result = lifecycle_support.repoRoot() / "test-logs" / "plat68-project" / name
  removeDir(result)
  createDir(result)
  writeFile(result / ProjectFile, text)

proc spawnEditor(project, stateDir: string; term = "xterm-256color";
                 extra: seq[string] = @[]): TuiTestSession =
  newTuiTest(tuiBinary(), extra & @["--edit", project])
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
               "TMUX")
    .envSet("TERM", term)
    .envSet("LANG", "en_US.UTF-8")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", "4000")
    .envSet(StateDirEnvVar, stateDir)
    .spawn()

proc answerProbe(sess: var TuiTestSession; kitty: bool) =
  ## Wait for the binary's start-up query round, then answer it the way a
  ## terminal does: the Kitty flags first when it implements the protocol,
  ## then the DA1 fence.
  let deadline = getMonoTime() + initDuration(milliseconds = FrameTimeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(20)
    if sess.transcriptBytes().contains(KittyQuery): break
  check sess.transcriptBytes().contains(KittyQuery)
  sess.send((if kitty: KittyReply else: "") & Da1Reply)

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
        "the binary exited before '" & needle & "' appeared; screen:\n" & last)
  raise newException(AssertionDefect,
    "'" & needle & "' never appeared within " & $timeoutMs & " ms; screen:\n" & last)

proc waitForEditorTab(sess: var TuiTestSession): string =
  ## PLAT-49: the editor's tab names the file on the strip that carries Edit
  ## mode's source statement ("the working tree").
  let deadline = getMonoTime() + initDuration(milliseconds = FrameTimeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    for line in last.splitLines():
      if line.contains("the working tree") and line.contains(" " & ProjectFile & " "):
        return last
    if not sess.isAlive:
      raise newException(AssertionDefect, "the binary exited; screen:\n" & last)
  raise newException(AssertionDefect, "the editor never opened; screen:\n" & last)

proc sendKey(sess: var TuiTestSession; name: string) =
  if name == Pause:
    sleep(PauseMs)
    return
  sess.send(keyBytes(name))
  discard sess.drainOutput(if name == "Esc": 250 else: 40)

proc offEditorAndRun(sess: var TuiTestSession; command, expect: string): string =
  ## `F6` off the editor (no base binds it in a buffer), then a `:` command.
  sess.sendKey("F6")
  discard waitForScreenText(sess, "focus ")
  sess.send(":" & command & "\r")
  waitForScreenText(sess, expect)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.close()

proc inProcess(base: BaseKeymap; text: string; keys: seq[string];
               protocol: KeyProtocol): string =
  ## The same key names through the same base, in-process — the document the
  ## binary's bytes must reproduce. `Pause` moves the clock past the undo
  ## grouping delay, as it moves the wall clock for the binary.
  let s = newEditSession(base, KeyDelivery(frontEnd: feTerminal,
                                           platform: hostPlatform(),
                                           keyProtocol: protocol))
  discard s.openFile(ProjectFile, text)
  let buf = s.activeBuffer()
  var now = 1_000'i64
  for k in keys:
    if k == Pause:
      now += PauseMs
      continue
    now += 40
    discard buf.applyEditKey(k, now)
  buf.text

const
  StartDoc = "alpha\n    beta\ngamma\n"

  CuaSequence = @[
    # Typed text at the start of the file, then `Shift+Right` ×3 selects the
    # first three characters of `alpha`; `Ctrl+C` copies them; `End`, then a
    # pause so the paste is its own undo step; `Ctrl+V` pastes; `Ctrl+Z`
    # undoes the paste and `Ctrl+Y` redoes it.
    "x", "y", Pause, "Shift+Right", "Shift+Right", "Shift+Right", "Ctrl+c",
    "End", Pause, "Ctrl+v", Pause, "Ctrl+z", Pause, "Ctrl+y",
    # Down to `    beta` and delete it with VS Code's `Ctrl+Shift+K`.
    "Down", Pause, "Ctrl+Shift+k", Pause]

suite "PLAT-68 Tier 2: the key synthesiser is the decoder's inverse":
  test "every key this suite sends decodes back to its own name":
    ck fileExists(tuiBinary())
    var names = @["Esc", "Enter", "Tab", "Backspace", "Space", "Up", "Down",
                  "Right", "Left", "End", "F6", "Shift+Right", "Shift+Left",
                  "Ctrl+Shift+k", "Ctrl+Space", "Ctrl+c", "Ctrl+v", "Ctrl+z",
                  "Ctrl+y", "Ctrl+s", "Ctrl+k", "Ctrl+f", "Ctrl+e", "Alt+w",
                  "Alt+y", "d", "x", "q"]
    for k in CuaSequence:
      if k != Pause and k notin names: names.add k
    for k in names:
      let bytes = keyBytes(k)
      checkpoint(k & " -> " & bytes.escape)
      ck bytes.len > 0
      ck keyName(bytes) == k
    for (bytes, name) in HomeEndSpellings:
      ck keyName(bytes) == name

suite "PLAT-68 Tier 2: Edit mode under CUA, with no stored preference":
  test "the milestone's sequence, Ctrl+S, and the file on disk":
    let state = stateDirFor("cua-sequence")
    let project = projectFor("cua-sequence", StartDoc)
    ck not fileExists(state / KeymapFile)
    var sess = spawnEditor(project, state)
    var saved = true
    try:
      sess.answerProbe(kitty = true)
      discard waitForEditorTab(sess)
      ck sess.transcriptBytes().contains(KittyPush)
      for k in CuaSequence:
        sess.sendKey(k)
      sess.send(keyBytes("Ctrl+s"))
      # THE DOCUMENT IS THE VERDICT, THE STATUS LINE IS NOT: a run whose keys
      # went wrong (a dropped `Shift` turns `Ctrl+Shift+K` into a pending
      # `Ctrl+K` prefix that then swallows the save) must fail on the file
      # below, so the save message is waited for without raising and asserted
      # after the document.
      try:
        discard waitForScreenText(sess, "wrote " & ProjectFile)
      except AssertionDefect:
        saved = false
    finally:
      sess.sendKey("F6")
      sess.quit()
    let onDisk = readFile(project / ProjectFile)
    let expected = inProcess(bkCua, StartDoc, CuaSequence, kpKitty)
    checkpoint("on disk: " & onDisk.escape & " expected: " & expected.escape)
    ck onDisk == expected
    # And what that document IS, so the equality is not two copies of one
    # mistake: `xy` typed, `alp` selected, copied and pasted at the line's
    # end, the paste undone and redone, `    beta` deleted.
    ck onDisk == "xyalphaalp\ngamma\n"
    ck saved
    # Nothing was stored: the default is CUA, not a remembered choice.
    ck not fileExists(state / KeymapFile)

  test "Home and End in every xterm spelling move the caret":
    let state = stateDirFor("cua-home-end")
    let project = projectFor("cua-home-end", "    mid\n")
    var sess = spawnEditor(project, state)
    var keys: seq[string] = @[]
    try:
      sess.answerProbe(kitty = false)
      discard waitForEditorTab(sess)
      var marker = 'a'
      for (bytes, name) in HomeEndSpellings:
        sess.send(bytes)
        discard sess.drainOutput(40)
        sess.sendKey($marker)
        keys.add name
        keys.add $marker
        inc marker
      sess.send(keyBytes("Ctrl+s"))
      discard waitForScreenText(sess, "wrote " & ProjectFile)
    finally:
      sess.sendKey("F6")
      sess.quit()
    let onDisk = readFile(project / ProjectFile)
    checkpoint("on disk: " & onDisk.escape)
    ck onDisk == inProcess(bkCua, "    mid\n", keys, kpModifyOtherKeys)
    # `Home` is VS Code's two-stage `line-start-smart`: from the end it stops
    # at the first non-blank, so every Home marker lands after the indent.
    ck onDisk == "    gecamidbdfh\n"

  test "the legacy fallback Ctrl+K Ctrl+K deletes the line only on a legacy terminal":
    for (term, kitty, deletes) in [("screen-256color", false, true),
                                   ("xterm-256color", true, false)]:
      let name = "fallback-" & term
      let state = stateDirFor(name)
      let project = projectFor(name, "one\ntwo\n")
      var sess = spawnEditor(project, state, term)
      try:
        sess.answerProbe(kitty)
        discard waitForEditorTab(sess)
        let bytes = sess.transcriptBytes()
        if term.startsWith("screen"):
          ck KittyPush notin bytes
          ck MokOn notin bytes
        sess.sendKey("Ctrl+k")
        sess.sendKey("Ctrl+k")
        sess.send(keyBytes("Ctrl+s"))
        discard waitForScreenText(sess, "wrote " & ProjectFile)
      finally:
        sess.sendKey("F6")
        sess.quit()
      let onDisk = readFile(project / ProjectFile)
      checkpoint(term & ": " & onDisk.escape)
      ck onDisk == (if deletes: "two\n" else: "one\ntwo\n")

suite "PLAT-68 Tier 2: the terminal's key protocol, negotiated and restored (KL-9)":
  proc protocolSession(name, term: string; kitty: bool): TuiTestSession =
    let state = stateDirFor(name)
    let project = projectFor(name, "x\n")
    result = spawnEditor(project, state, term)
    result.answerProbe(kitty)
    discard waitForEditorTab(result)

  test "Kitty when the terminal answers, modifyOtherKeys on an xterm that does not, nothing otherwise":
    for (term, kitty, want, notWanted) in [
        ("xterm-256color", true, KittyPush, MokOn),
        ("xterm-256color", false, MokOn, KittyPush),
        ("screen-256color", false, "", KittyPush)]:
      var sess = protocolSession("negotiate-" & term & $kitty, term, kitty)
      try:
        let bytes = sess.transcriptBytes()
        let query = bytes.find(KittyQuery)
        ck query >= 0
        ck bytes.find("\e[c", query) > query     # the fence comes after it
        if want.len > 0: ck bytes.find(want) > query
        ck notWanted notin bytes
        if term.startsWith("screen"): ck MokOn notin bytes
        ck sess.transcriptDroppedBytes() == 0
      finally:
        sess.sendKey("F6")
        sess.quit()

  test "the pop or the reset is written on SIGTERM, SIGHUP and a crash":
    for (sig, sigName) in [(SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"),
                           (SIGSEGV, "SIGSEGV")]:
      for kitty in [true, false]:
        var sess = protocolSession("restore-" & sigName & $kitty,
                                   "xterm-256color", kitty)
        let on = if kitty: KittyPush else: MokOn
        let off = if kitty: KittyPop else: MokOff
        let enabledAt = sess.transcriptBytes().find(on)
        ck enabledAt >= 0
        sess.sendSignal(sig)
        discard sess.waitExit(initDuration(seconds = 10))
        discard sess.drainOutput(100)
        let bytes = sess.transcriptBytes()
        checkpoint(sigName & " kitty=" & $kitty & " tail " &
                   bytes[max(0, bytes.len - 80) .. ^1].escape)
        ck bytes.find(off, enabledAt) > enabledAt
        # The undo comes BEFORE the alternate screen is left: the Kitty stack
        # is per screen.
        ck bytes.find(off, enabledAt) < bytes.rfind("\e[?1049l")
        sess.close()

  test "--capabilities names the negotiated protocol":
    var sess = newTuiTest(tuiBinary(), @["--capabilities"])
      .width(Cols).height(Rows).transcript()
      .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "TMUX")
      .envSet("TERM", "xterm-256color")
      .envSet("CT_TUI_PROBE_TIMEOUT_MS", "4000")
      .spawn()
    sess.answerProbe(kitty = true)
    discard sess.waitExit(initDuration(seconds = 10))
    discard sess.drainOutput(100)
    let report = sess.transcriptBytes()
    checkpoint(report[max(0, report.len - 300) .. ^1])
    ck "keys=kitty(probe)" in report
    sess.close()

suite "PLAT-68 Tier 2: switching the base":
  const
    Sequence = @["d", "d", "x"]
      ## Under CUA and Emacs the letters type; under Vim `dd` deletes the
      ## line and `x` a character; under Kakoune `d` deletes the selection.

  test "`:keymap <base>` changes the document one keystroke sequence produces":
    var documents: seq[string] = @[]
    for base in [bkEmacs, bkVim, bkKakoune, bkCua]:
      let name = "switch-" & $base
      let state = stateDirFor(name)
      if base == bkCua: writeFile(state / KeymapFile, "vim\n")
      let project = projectFor(name, StartDoc)
      var sess = spawnEditor(project, state)
      try:
        sess.answerProbe(kitty = false)
        discard waitForEditorTab(sess)
        let told = offEditorAndRun(sess, "keymap " & $base, "keymap " & $base)
        checkpoint(told.splitLines()[^1])
        sess.send("\e[17;2~")          # Shift+F6: back onto the editor
        discard sess.drainOutput(150)
        for k in Sequence: sess.sendKey(k)
        sess.sendKey("Esc")
        discard offEditorAndRun(sess, "w", "wrote " & ProjectFile)
      finally:
        sess.quit()
      ck readFile(state / KeymapFile) == $base & "\n"
      let onDisk = readFile(project / ProjectFile)
      let expected = inProcess(base, StartDoc, Sequence & @["Esc"],
                               kpModifyOtherKeys)
      checkpoint($base & ": " & onDisk.escape)
      ck onDisk == expected
      documents.add onDisk
    for i in 0 ..< documents.len:
      for j in i + 1 ..< documents.len:
        ck documents[i] != documents[j] or (i, j) == (0, 3)
    # CUA and Emacs both TYPE the three letters: the one pair that agrees.
    ck documents[0] == documents[3]

  test "`--keymap` holds for one session and is not stored":
    let state = stateDirFor("flag")
    writeFile(state / KeymapFile, "vim\n")
    let project = projectFor("flag", StartDoc)
    var sess = spawnEditor(project, state, extra = @["--keymap=emacs"])
    try:
      sess.answerProbe(kitty = false)
      discard waitForEditorTab(sess)
      let told = offEditorAndRun(sess, "keymap", "keymap emacs")
      ck told.contains("keymap emacs (flag)")
    finally:
      sess.quit()
    ck readFile(state / KeymapFile) == "vim\n"

  test "a stored `default` is read as `cua`, said once, and rewritten":
    let state = stateDirFor("migrate")
    writeFile(state / KeymapFile, "default\n")
    let project = projectFor("migrate", StartDoc)
    var sess = spawnEditor(project, state)
    try:
      sess.answerProbe(kitty = false)
      let first = waitForScreenText(sess, "keymap 'default' is now 'cua'")
      ck first.contains("keymap 'default' is now 'cua'")
    finally:
      sess.sendKey("F6")
      sess.quit()
    ck readFile(state / KeymapFile) == "cua\n"
    var again = spawnEditor(project, state)
    try:
      again.answerProbe(kitty = false)
      discard waitForEditorTab(again)
      discard again.drainOutput(300)
      ck not again.screenContents().contains("is now 'cua'")
    finally:
      again.sendKey("F6")
      again.quit()

suite "PLAT-68 Tier 2 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedChecks
