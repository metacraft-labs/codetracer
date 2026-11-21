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

proc command(sess: var TuiTestSession; line: string) =
  sess.send("\e")
  sleep(100)
  sess.send(":" & line & "\r")

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

proc escapeKey(sess: var TuiTestSession) =
  ## One Escape, on its own: a second ESC byte inside the framer's delay
  ## would make the pair one Alt token.
  sess.send("\e")
  sleep(200)

proc pluginPids(home: string): seq[int] =
  ## The plugin processes of THIS test's install, by their executable's path
  ## under `home`: other suites on the same machine run the same package.
  let (o, _) = execCmdEx("pgrep -f " & quoteShell(home / "components" /
                         "acme-tools@1.0.0/bin/acme-tools-plugins"))
  for l in o.splitLines:
    if l.strip.len > 0: result.add parseInt(l.strip)

proc spawnTui(home: string; extra: seq[string] = @[]): TuiTestSession =
  let calc = requireFixture(fixtureSpec("calc"))
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
    sess.send("\e")
    sleep(1_200)
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
