## test_ct_lens_plugins_pty.nim — the `ct-lens` plugin package
## (`src/plugins/ct-lens/`) on the shipped terminal binary, over a real pty,
## on a real recording with a real `replay-server`.
##
## The package is built with the plugin SDK and installed as a component the
## way `ct install` lays one out; the terminal discovers it, asks for consent,
## and runs its three plugins:
##
## * `ct-lens.history` runs the real `git` on the recording's source and shows
##   the commits that changed the function the debugger is in. The suite asks
##   git the same question itself and checks the pane against git's answer,
##   so the case holds wherever the fixture was recorded, in a repository or
##   not.
## * `ct-lens.watch` reads the core State ViewModel's change set; its command,
##   bound to F7 with a `when` clause over the context key it pushes, adds the
##   changed values as watches in the Variables pane. Its visualiser shows
##   Python's `None` as Python spells it.
## * `ct-lens.jump` lists calls in its docked pane (Enter on one jumps, a
##   `view-event`) and pushes a modal layer (Shift+F7) over the window. It is the
##   plugin PLAT-82's defences are exercised against: the recovery chord, and
##   the input deadline with the process stopped by SIGSTOP — the plugin's own
##   code, unchanged, in a state a debugger or a swapping machine puts a
##   process in.
##
## No mocks: a real pty, the shipped binary, a real recording, a real
## replay-server, real plugin processes and a real git. Every wait is on what
## the screen shows, with a generous ceiling (the CI host runs at load above
## 100).

import std/[os, osproc, posix, strutils, tempfiles, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../viewmodel/tests/unit/ct_lens_fixture

const
  Cols = 200
  Rows = 50
  F7 = "\e[18~"
  ShiftF7 = "\e[18;2~"

proc text(sess: var TuiTestSession; r: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(r, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc screen(sess: var TuiTestSession): string =
  discard sess.drainOutput(100)
  for r in 0 ..< Rows:
    result.add sess.text(r) & "\n"

proc statusLine(sess: var TuiTestSession): string =
  discard sess.drainOutput(100)
  sess.text(Rows - 1)

proc screenHas(sess: var TuiTestSession; needle: string;
               ceilingMs = 60_000): bool =
  var waited = 0
  while waited < ceilingMs:
    if needle in sess.screen: return true
    sleep(200)
    waited += 200
  checkpoint "not on screen: " & needle & "\n" & sess.screen
  false

proc statusHas(sess: var TuiTestSession; needle: string;
               ceilingMs = 60_000): bool =
  var waited = 0
  while waited < ceilingMs:
    if needle in sess.statusLine: return true
    sleep(200)
    waited += 200
  checkpoint "not on the status line: " & needle & "\n" & sess.statusLine
  false

proc escapeKey(sess: var TuiTestSession) =
  ## One Escape, on its own: a second ESC byte inside the framer's delay
  ## would make the pair one Alt token.
  sess.send("\e")
  sleep(200)

proc overlayOpen(sess: var TuiTestSession): bool =
  ## A content overlay (`:plugins`, a pane shown by `:plugins show`, the
  ## recovery dialog) is a box; no docked pane draws one.
  "┌" in sess.screen

proc closeOverlay(sess: var TuiTestSession) =
  ## Escape until no overlay is open, waiting on the screen each time. An
  ## Escape is sent only while there is something to close, because an Escape
  ## the framer still holds when the next byte arrives makes the pair one Alt
  ## token, and on a loaded host that byte can be the `:` of the next command.
  for _ in 0 ..< 10:
    if not sess.overlayOpen: return
    sess.send("\e")
    var waited = 0
    while waited < 3_000 and sess.overlayOpen:
      sleep(100)
      waited += 100

proc command(sess: var TuiTestSession; line: string) =
  ## `:line`, typed only once the command line is open: a `:` that did not
  ## open it would leave the rest to be read as keys.
  sess.closeOverlay()
  for _ in 0 ..< 5:
    sess.send(":")
    var waited = 0
    while waited < 3_000 and not sess.statusLine.startsWith(":"):
      sleep(100)
      waited += 100
    if sess.statusLine.startsWith(":"):
      sess.send(line & "\r")
      return

proc commandShows(sess: var TuiTestSession; line, needle: string;
                  ceilingMs = 90_000): bool =
  ## Run `:line` until its overlay shows `needle`. An overlay is a snapshot of
  ## the moment the command ran, so a state still on its way (git still
  ## running, the locals of a stop still loading) is waited for by asking
  ## again, not by waiting on the screen.
  var waited = 0
  while waited < ceilingMs:
    sess.command(line)
    if sess.screenHas(needle, ceilingMs = 2_000): return true
    waited += 2_500
  checkpoint "never shown by :" & line & ": " & needle & "\n" & sess.screen
  false

proc spawnTui(home: string): TuiTestSession =
  let calc = requireFixture(fixtureSpec("calc"))
  discard requireReplayServer()
  newTuiTest(tuiBinary(), @["--theme=dark", calc])
    .width(Cols).height(Rows)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("XDG_STATE_HOME", home / "state")
    .envSet("XDG_CONFIG_HOME", home / "config")
    .envSet("CODETRACER_HOME", home / "ct-home")
    .envSet("CODETRACER_USER_ROOT", home / "user-root")
    .envSet("CODETRACER_COMPONENTS_ROOT", home / "components")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", home / "layout")
    .spawn()

proc newHome(): string =
  result = createTempDir("ct-lens-plugins-", "")
  createDir(result / "components")
  discard installLens(result / "components")

proc grant(sess: var TuiTestSession; plugins: varargs[string]) =
  ## Grant each plugin until `:plugins` reports it running. Asked again
  ## rather than assumed: on a loaded host a command line can be lost to the
  ## framer (see `command`), and granting twice only says so.
  for id in plugins:
    var running = false
    for _ in 0 ..< 6:
      sess.command("plugins grant " & id)
      if sess.commandShows("plugins", id & "  running", ceilingMs = 20_000):
        running = true
        break
    check running

proc calcSource(): string =
  ## The recorded `main.py`, at the path the recording names.
  let calc = requireFixture(fixtureSpec("calc"))
  for f in walkDirRec(calc / "files"):
    if f.endsWith("calc/main.py"):
      return f.substr((calc / "files").len)
  ""

proc gitSays(file: string; first, last: int): string =
  ## What git itself answers for the range: the newest commit's short hash,
  ## or the first line of its refusal.
  let (o, code) = execCmdEx(quoteShellCommand(["git", "-C", file.parentDir,
    "log", "-n", "1", "--format=%h", "-s", "-L",
    $first & "," & $last & ":" & file.extractFilename]))
  if code == 0: o.strip
  else: o.strip.splitLines[0]

proc jumpPid(sess: var TuiTestSession): int =
  ## The jump plugin's own process, as `:plugins` reports it: it captures the
  ## window's keys, so the host runs it apart from its siblings.
  const marker = "ct-lens[ct-lens.jump] running pid "
  if not sess.commandShows("plugins", marker): return 0
  for line in sess.screen.splitLines:
    let at = line.find(marker)
    if at >= 0:
      var digits = ""
      for c in line[at + marker.len .. ^1]:
        if c in Digits: digits.add c
        else: break
      if digits.len > 0: return parseInt(digits)
  0

proc openJump(sess: var TuiTestSession): bool =
  ## Shift+F7 until the mode is named in the indicator. Pressed again rather
  ## than waited for, because the key is live only once the plugin has pushed
  ## the enablement of its operation.
  for _ in 0 ..< 30:
    sess.closeOverlay()
    sess.send(ShiftF7)
    if sess.statusHas("JUMP MODE (ct-lens.jump)", ceilingMs = 3_000):
      return true
  false

proc watchRowShown(sess: var TuiTestSession; name: string): bool =
  ## A `W` (watch) row for `name` in the Variables pane. The name column is
  ## narrow and a compound value carries an expander, so the row is matched
  ## by its scope letter and the name's first characters.
  let head = name[0 ..< min(8, name.len)]
  for line in sess.screen.splitLines:
    let at = line.find("▏W ")
    if at >= 0 and head in line[at .. min(line.high, at + 24)]:
      return true
  false

proc finish(sess: var TuiTestSession; home: string) =
  sess.command("quit")
  discard sess.waitExit(initDuration(seconds = 30))
  sess.close()
  removeDir(home)

suite "ct-lens on a real terminal":

  test "installed and granted, one process runs history and watch; history follows the debugger through git":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.commandShows("plugins", "Waiting for your consent: ct-lens.history")
    check lensPids(home / "components").len == 0
    sess.grant("ct-lens.history", "ct-lens.watch")
    check lensPids(home / "components").len == 1
    # The first stop of `calc` is the module's first line: the function the
    # stop reports is the module, and its range is what git is asked about.
    const head = "History of <__main__> (main.py:"
    check sess.commandShows("plugins show ct-lens.history/history", head)
    var first, last = 0
    for line in sess.screen.splitLines:
      let at = line.find(head)
      if at >= 0:
        let parts = line[at + head.len .. ^1].split(')')[0].split('-')
        first = parseInt(parts[0].strip)
        last = parseInt(parts[^1].strip)
    check first > 0 and last >= first
    let src = calcSource()
    check src.len > 0
    # The recording names its source by the path it was recorded at; when
    # that file is no longer on this machine the plugin says so instead.
    let onDisk = fileExists(src)
    let want = if onDisk: gitSays(src, first, last)
               else: "the source is not on this machine"
    check want.len > 0
    let refused = not onDisk or "not a git repository" in want.toLowerAscii
    check sess.commandShows("plugins show ct-lens.history/history",
      (if not onDisk: want elif refused: "not a git repository" else: want))
    # Its status item, on the status line beside the last note.
    check sess.statusHas("history: " & (if refused: "unavailable" else: want))
    # And its editor decoration: the module's first line, which is on screen
    # at the first stop, carries the commit that last changed it.
    if not refused:
      check sess.screenHas("± history: " & want)
    sess.finish(home)

  test "F7 watches what the step changed; the plugin's visualiser renders Python's None":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.history", "ct-lens.watch")
    # At module level the globals include `__cached__ = None`: the plugin
    # tier shows it as Python spells it, where the built-in rendering says
    # `nil`. (The first stop has no locals yet; one step binds them.)
    var pythonic = false
    for _ in 0 ..< 6:
      sess.command("next")
      if sess.screenHas("NoneT… None", ceilingMs = 10_000):
        pythonic = true
        break
    check pythonic
    # Then: a step whose status item names ONE changed value (the first
    # steps bind every module global, and their watch rows would run past the
    # bottom of the Variables pane), F7, and that value's watch row. The
    # status line is read rather than the plugin's pane: `:plugins show`
    # brings the pane to the front of the Variables stack, and the Variables
    # tab is what this case reads. The round is tried again if the plugin's
    # process is restarted under it: at load 150 the host has called this
    # healthy plugin hung and restarted it, which drops what it pushed.
    var changed = ""
    var refused, watched = false
    for round in 1 .. 3:
      changed = ""
      for _ in 0 ..< 60:
        sess.command("next")
        if sess.statusHas("changed: ", ceilingMs = 8_000):
          let line = sess.statusLine
          let at = line.find("changed: ")
          let list = line[at + "changed: ".len .. ^1].split("  ")[0].strip
          if list.len > 0 and list notin ["none", "…"] and ',' notin list:
            changed = list
            break
      if changed.len == 0:
        checkpoint "round " & $round & ": no step named one changed value; status line:\n" &
          sess.statusLine
        continue
      # F7 on its own: nothing is open (the last `:next` closed its line).
      sleep(500)
      sess.send(F7)
      # Everything the step changed is watched now: the command says why it
      # is off, and the binding no longer holds.
      refused = sess.commandShows("plugins run ct-lens.watch watch.add-changed",
                                  "every changed value is already watched",
                                  ceilingMs = 30_000)
      if not refused:
        # What the host recorded, for whoever reads a red run.
        for f in walkDirRec(home / "state"):
          if f.endsWith("plugins.log"):
            checkpoint "plugin log " & f & ":\n" & readFile(f)
        sess.command("plugins")
        checkpoint "after F7 on " & changed & ":\n" & sess.screen
        continue
      # The watch row arrives with the locals of the next stop.
      for _ in 0 ..< 6:
        sess.command("next")
        for _ in 0 ..< 25:
          if sess.watchRowShown(changed):
            watched = true
            break
          sleep(400)
        if watched: break
      if not watched:
        checkpoint "round " & $round & ": F7 on " & changed &
          " was refused afterwards, but no watch row appeared:\n" & sess.screen
      if watched: break
    check changed.len > 0
    check refused
    check watched
    # And the plugin's own pane, docked in the same stack.
    check sess.commandShows("plugins show ct-lens.watch/changes",
                            "Changed at this step")
    sess.finish(home)

  test "disabling one plugin leaves the other running in the same process":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.history", "ct-lens.watch")
    let pids = lensPids(home / "components")
    check pids.len == 1
    var disabled = false
    for _ in 0 ..< 6:
      sess.command("plugins disable ct-lens.watch")
      if sess.commandShows("plugins", "ct-lens.watch  disabled", ceilingMs = 20_000):
        disabled = true
        break
    check disabled
    check sess.commandShows("plugins", "ct-lens.history  running")
    sess.command("step")
    check sess.commandShows("plugins show ct-lens.history/history", "History of ")
    check lensPids(home / "components") == pids
    sess.finish(home)

  test "plugins granted in an earlier session start by themselves in the next":
    let home = newHome()
    block:
      var first = spawnTui(home)
      settleOnDebugger(first, Cols, Rows)
      first.grant("ct-lens.history", "ct-lens.watch", "ct-lens.jump")
      first.command("quit")
      discard first.waitExit(initDuration(seconds = 30))
      first.close()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.commandShows("plugins", "ct-lens.history  running")
    check sess.commandShows("plugins", "ct-lens.watch  running")
    check sess.commandShows("plugins", "ct-lens.jump  running")
    sess.finish(home)

suite "ct-lens.jump on a real terminal: a mode, and the defences against it":

  test "Shift+F7 names the mode and lists the calls on the status line; a digit picks one and leaves it":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.jump")
    check sess.openJump()
    check sess.statusHas("jump: 1 ")
    sess.send("2")
    var left = false
    for _ in 0 ..< 120:
      if "JUMP MODE (ct-lens.jump)" notin sess.statusLine:
        left = true
        break
      sleep(500)
    check left
    sess.finish(home)

  test "Enter on a call in the docked jump pane jumps to it, without the mode":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.jump")
    # `:plugins show` brings the docked pane to the front and focuses it.
    check sess.commandShows("plugins show ct-lens.jump/calls",
                            "Enter on a call jumps to it")
    check "JUMP MODE (ct-lens.jump)" notin sess.statusLine
    # Enter: the terminal's own key handling activates the highlighted row
    # and sends the plugin a view event; the plugin jumps and says so.
    var jumped = false
    for _ in 0 ..< 5:
      sess.send("\r")
      if sess.screenHas("jumped to ", ceilingMs = 10_000):
        jumped = true
        break
      sess.command("plugins show ct-lens.jump/calls")
    check jumped
    sess.finish(home)

  test "three Escapes take the keyboard back from the mode, and the healthy plugin gets it back":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.history", "ct-lens.jump")
    check sess.openJump()
    sess.escapeKey()
    sess.escapeKey()
    sess.escapeKey()
    check sess.screenHas("RECOVER INPUT")
    check sess.screenHas("The plugins that held the keyboard: ct-lens.jump")
    sess.closeOverlay()
    check "JUMP MODE (ct-lens.jump)" notin sess.statusLine
    # The plugin was healthy: it is running again (not "not responding")
    # without a re-enable, and its key opens the mode again.
    check sess.commandShows("plugins", "ct-lens.jump  running")
    check sess.openJump()
    sess.finish(home)

  test "stopped while it holds the keyboard, the plugin loses it within its deadline; its siblings keep running":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grant("ct-lens.history", "ct-lens.watch", "ct-lens.jump")
    let pid = sess.jumpPid()
    check pid > 0
    check lensPids(home / "components").len == 2
    check sess.openJump()
    check kill(Pid(pid), SIGSTOP) == 0
    sess.send("1")
    check sess.statusHas("`1` went to ct-lens.jump, which did not answer")
    # Then it is stopped and its mode is gone: the keys are the terminal's.
    check sess.screenHas("Plugin 'ct-lens.jump' was stopped")
    check "JUMP MODE (ct-lens.jump)" notin sess.statusLine
    discard kill(Pid(pid), SIGCONT)
    check sess.commandShows("plugins", "ct-lens.history  running")
    check sess.commandShows("plugins", "ct-lens.watch  running")
    sess.finish(home)
