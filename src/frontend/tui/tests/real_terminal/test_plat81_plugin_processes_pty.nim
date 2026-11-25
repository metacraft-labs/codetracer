## test_plat81_plugin_processes_pty.nim — plugins run out of process
## (Extensibility-Model.md §11), on the shipped terminal binary, over a real
## pty, on a real recording with a real `replay-server`.
##
## The `acme-tools` test package (`viewmodel/tests/unit/plugin_packages/`) is
## built with the plugin SDK and installed as a component the way `ct install`
## lays one out; the terminal discovers it, asks for consent, starts ONE
## process for its two plugins, and draws what they push. `flame` misbehaves on
## request (its `mode` setting, written to the user's plugin settings).
##
## No mocks: a real pty, the shipped binary, a real recording, a real
## replay-server and real plugin processes. Every wait is on what the screen
## shows, with a generous ceiling (the CI host runs at load above 100).

import std/[json, os, osproc, posix, strutils, tempfiles, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../viewmodel/tests/unit/plugin_process_fixture

const
  Cols = 200
  Rows = 50

proc text(sess: var TuiTestSession; r: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(r, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc screen(sess: var TuiTestSession): string =
  discard sess.drainOutput(100)
  for r in 0 ..< Rows:
    result.add sess.text(r) & "\n"

proc screenHas(sess: var TuiTestSession; needle: string;
               ceilingMs = 60_000): bool =
  var waited = 0
  while waited < ceilingMs:
    if needle in sess.screen: return true
    sleep(200)
    waited += 200
  checkpoint "not on screen: " & needle & "\n" & sess.screen
  false


proc escapeKey(sess: var TuiTestSession) =
  ## One Escape, on its own: a second ESC byte inside the framer's delay
  ## would make the pair one Alt token.
  sess.send("\e")
  sleep(200)

proc promptShows(sess: var TuiTestSession; text: string; ceilingMs: int): bool =
  ## The bottom line is the open prompt's sigil and buffer (§3.3.6).
  var waited = 0
  while waited < ceilingMs:
    discard sess.drainOutput(100)
    if sess.text(Rows - 1).startsWith(text): return true
    sleep(100)
    waited += 200
  false

proc command(sess: var TuiTestSession; line: string) =
  ## Each step is confirmed on the screen before the next. Sent blind, as
  ## `ESC`, 100 ms, `:line⏎`, a command was lost at load ~190: a stalled TUI
  ## reads the queued ESC and `:` together, as ONE Alt+`:` token, and the
  ## rest of the line went to whatever had focus. So the Escape goes alone,
  ## the prompt must show the whole line before Enter, and a prompt that
  ## does not is cancelled and typed again.
  for attempt in 1 .. 5:
    sess.escapeKey()
    sess.send(":")
    if not sess.promptShows(":", 10_000):
      continue
    sess.send(line)
    if sess.promptShows(":" & line, 10_000):
      sess.send("\r")
      return
  checkpoint "the prompt never showed :" & line & "\n" & sess.screen

proc commandShows(sess: var TuiTestSession; line, needle: string;
                  ceilingMs = 90_000): bool =
  ## Run `:line` until its overlay shows `needle`. An overlay is a snapshot
  ## of the moment the command ran, so a state still on its way (a plugin
  ## starting) is waited for by asking again, not by waiting on the screen.
  var waited = 0
  while waited < ceilingMs:
    sess.command(line)
    if sess.screenHas(needle, ceilingMs = 2_000): return true
    waited += 2_500
  checkpoint "never shown by :" & line & ": " & needle & "\n" & sess.screen
  false

proc tickShown(screen: string): int =
  ## The stop's tick as the screen reads it: the title bar's `tick: N / M`
  ## (on every stop, a module's too, where the Variables pane is empty and
  ## shows no `tick N` title); -1 when none is.
  for marker in ["tick: ", "tick "]:
    var at = screen.find(marker)
    while at >= 0:
      var digits = ""
      var i = at + marker.len
      while i < screen.len and screen[i] in Digits:
        digits.add screen[i]
        inc i
      if digits.len > 0: return parseInt(digits)
      at = screen.find(marker, at + marker.len)
  -1

proc annotatedAndPlain(line, needle: string): tuple[annotated, plain: bool] =
  ## Whether `needle` is on `line` inside an editor annotation (`/* … */`),
  ## and whether it is there outside one (another pane on the same row).
  var rest = line
  while true:
    let open = rest.find("/*")
    if open < 0: break
    let close = rest.find("*/", open + 2)
    let stop = if close < 0: rest.len else: close + 2
    if needle in rest[open ..< stop]: result.annotated = true
    rest = rest[0 ..< open] & rest[stop .. ^1]
  if needle in rest: result.plain = true

proc settledTick(sess: var TuiTestSession; ceilingMs = 60_000): int =
  ## The tick of a stop that HOLDS STILL: the same on three reads in a row.
  ## The panes redraw in pieces after a move, so one read can catch the
  ## title of the old stop under the source of the new one.
  var last = -2
  var same = 0
  var waited = 0
  while waited < ceilingMs:
    let t = tickShown(sess.screen)
    if t >= 0 and t == last:
      inc same
      if same >= 2: return t
    else:
      same = 0
    last = t
    sleep(300)
    waited += 300
  last

proc tickMoves(sess: var TuiTestSession; from0: int;
               ceilingMs = 60_000): int =
  ## Wait for the screen to settle on a stop other than tick `from0`; its
  ## tick, or `from0` when it never moved.
  var waited = 0
  while waited < ceilingMs:
    let t = sess.settledTick(ceilingMs = 10_000)
    if t >= 0 and t != from0: return t
    waited += 1_000
  checkpoint "the screen stayed at tick " & $from0 & "\n" & sess.screen
  from0

proc pluginPids(home: string): seq[int] =
  ## The plugin processes of THIS test's install, by their executable's path
  ## under `home`: other suites on the same machine run the same package.
  let (o, _) = execCmdEx("pgrep -f " & quoteShell(home / "components" /
                         "acme-tools@1.0.0/bin/acme-tools-plugins"))
  for l in o.splitLines:
    if l.strip.len > 0: result.add parseInt(l.strip)

proc spawnTui(home: string; extra: seq[string] = @[]): TuiTestSession =
  let calc = requireFixture(fixtureSpec("calc"))
  discard requireReplayServer()
  newTuiTest(tuiBinary(), @["--theme=dark"] & extra & @[calc])
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

proc newHome(manifest = ""; settings: JsonNode = nil): string =
  result = createTempDir("plat81-plugins-", "")
  createDir(result / "components")
  discard installPackage(result / "components", manifest)
  if not settings.isNil:
    createDir(result / "user-root")
    writeFile(result / "user-root" / "plugin-settings.json", $settings)

suite "Extensibility-Model §11 on a real terminal":

  test "installing is not accepting; granted, one process runs both plugins and draws their panes":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins")
    check sess.screenHas("Waiting for your consent: acme-tools.metrics")
    check pluginPids(home).len == 0
    sess.command("plugins review acme-tools.metrics")
    check sess.screenHas("runs the native program")
    sess.command("plugins grant acme-tools.metrics")
    sess.command("plugins grant acme-tools.flame")
    check sess.commandShows("plugins", "acme-tools.metrics  running")
    check sess.commandShows("plugins", "acme-tools.flame  running")
    check pluginPids(home).len == 1
    # The pane, from the mirrored debugger state.
    check sess.commandShows("plugins show acme-tools.metrics/overview",
                            "line main.py")
    let before = sess.screen
    # A plugin command from the palette's line runs a real step on the primary.
    sess.command("plugins run acme-tools.metrics metrics.step")
    check sess.commandShows("plugins show acme-tools.metrics/overview",
                            "position 2")
    check before != sess.screen
    # SIGKILL: restarted, both plugins back, the debugger never stopped.
    let pid = pluginPids(home)[0]
    discard kill(Pid(pid), SIGKILL)
    var restarted = false
    for _ in 0 ..< 300:
      let now = pluginPids(home)
      if now.len == 1 and now[0] != pid:
        restarted = true
        break
      sleep(200)
    check restarted
    check sess.commandShows("plugins", "acme-tools.metrics  running")
    sess.command("next")
    check sess.screenHas("tick")
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    check pluginPids(home).len == 0
    removeDir(home)

  test "a plugin's relayed jump, watch and step out are shown at once, with no :next":
    # The terminal pumps each move to its stop in its loop. A relayed action
    # applied to the session behind the loop moved the replay but kept the
    # screen at the old stop until the user's next step: these three commands
    # relay `calltrace.doubleClickEntry`, `state.addWatch` and
    # `debugControls.stepOut`, and every check below is made BEFORE any key
    # of the user's moves the debugger.
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins grant acme-tools.metrics")
    sess.command("plugins grant acme-tools.flame")
    check sess.commandShows("plugins", "acme-tools.metrics  running")
    let start = sess.settledTick()
    check start >= 0
    # The jump: the call trace pane's own jump to the `mul` call.
    sess.command("plugins run acme-tools.metrics metrics.jump")
    let jumped = sess.tickMoves(start)
    check jumped != start
    check sess.screenHas("main.py:39")
    # The watch: its row in the Variables pane at once, as `:watch` draws it.
    sess.command("plugins run acme-tools.metrics metrics.watch")
    check sess.screenHas("left*9")
    # Step out of `mul`: a later stop, shown.
    sess.command("plugins run acme-tools.metrics metrics.stepout")
    let stepped = sess.tickMoves(jumped)
    check stepped > jumped
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(home)

  test "a plugin's computed visualiser answers reach the Variables pane AND the editor's values":
    # `metrics` with `computeVisualiser` on publishes a COMPUTED row: the
    # terminal asks it about the values on screen (a `visualise` query, never
    # waited for) and renders them again with its answers (`acme=<value>`) —
    # in the Variables pane and in the source pane's inline values alike.
    let home = newHome(settings = %*{"plugins": {"acme-tools.metrics":
      {"settings": {"computeVisualiser": true}}}})
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins grant acme-tools.metrics")
    sess.command("plugins grant acme-tools.flame")
    check sess.commandShows("plugins", "acme-tools.metrics  running")
    # A stop inside `mul`, where `left` and `right` are ints on screen.
    let start = sess.settledTick()
    sess.command("plugins run acme-tools.metrics metrics.jump")
    discard sess.tickMoves(start)
    var inPane, inEditor = false
    var waited = 0
    while waited < 60_000 and not (inPane and inEditor):
      for line in sess.screen.splitLines:
        let (annotated, plain) = annotatedAndPlain(line, "acme=")
        if annotated: inEditor = true
        if plain: inPane = true
      if not (inPane and inEditor):
        sleep(300)
        waited += 300
    if not (inPane and inEditor):
      checkpoint "pane " & $inPane & " editor " & $inEditor & "\n" & sess.screen
    check inPane
    check inEditor
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(home)

  test "Ctrl+Alt+letter reaches a plugin's binding, and `J` is not `j`":
    # `metrics` binds `ctrl+alt+k` (a legacy terminal sends `ESC 0x0b`) to its
    # step and `J` to `metrics.count`. The terminal used to drop the Alt of
    # an ESC-prefixed control byte it did not bind itself (so the chord
    # arrived as the `Ctrl+k` chord prefix), and folded every key to lower
    # case (so the binding `J` took `j` too).
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins grant acme-tools.metrics")
    sess.command("plugins grant acme-tools.flame")
    check sess.commandShows("plugins", "acme-tools.metrics  running")
    let start = sess.settledTick()
    sess.escapeKey()
    sess.send("\x1b\x0b")
    check sess.tickMoves(start) != start
    # `j` first, then `J`, then the tally through the same pipe: the tally
    # counts the keys that reached the plugin before it, in order.
    sess.send("j")
    sleep(200)
    sess.send("J")
    sess.command("plugins run acme-tools.metrics metrics.tally")
    check sess.screenHas("metrics tally 1")
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(home)

  test "--no-extensions starts no plugin process":
    let home = newHome()
    var sess = spawnTui(home, @["--no-extensions"])
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins")
    check sess.screenHas("--no-extensions")
    check pluginPids(home).len == 0
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(home)

  test "a plugin that swallows keys loses the keyboard; three Escapes recover":
    var doc = packageManifest()
    doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
    let home = newHome($doc, %*{"plugins": {"acme-tools.flame":
      {"settings": {"mode": "swallow-input"}}}})
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.command("plugins grant acme-tools.metrics")
    sess.command("plugins grant acme-tools.flame")
    check sess.screenHas("FLAME MODE (acme-tools.flame)")
    # No Escape first: the layer binds `escape`, and an Escape is delivered
    # to a layer like any key (§11.7.6), so it would be the key the plugin
    # never answers.
    sess.send("j")
    check sess.screenHas("`j` went to acme-tools.flame, which did not answer")
    sess.escapeKey()
    sess.escapeKey()
    sess.escapeKey()
    check sess.screenHas("RECOVER INPUT")
    check sess.screenHas("acme-tools.flame")
    # The dialog offers the way back, not only the ways to turn a plugin off.
    check sess.screenHas(":plugins re-enable <id>")
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(home)
