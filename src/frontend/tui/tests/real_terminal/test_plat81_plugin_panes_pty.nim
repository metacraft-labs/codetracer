## test_plat81_plugin_panes_pty.nim — plugin panes docked in the terminal's
## layout, `view-event` from a plugin pane back to its plugin, and a plugin's
## editor decorations on screen (Extensibility-Model.md §6, §10 decision 2,
## §11.4.4), on the shipped terminal binary over a real pty, on the real
## `calc` recording with a real `replay-server`.
##
## The `acme-tools` test package is built with the plugin SDK and installed as
## a component (`plugin_process_fixture.installPackage`). Its `metrics` plugin
## draws the mirrored debugger position and decorates the current line; its
## `flame` plugin answers `view-event` by re-pushing its list with the
## activated row marked `✓ … (activated)` — so every assertion below about a
## round trip is about text only the plugin process could have drawn.
##
## No mocks: a real pty, the shipped binary, a real recording, a real
## replay-server and real plugin processes. Every wait is on what the screen
## (or the saved layout document) shows, with a generous ceiling: the CI host
## runs at load above 100.

import std/[json, os, osproc, strutils, tempfiles, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../viewmodel/tests/unit/plugin_process_fixture

const
  Cols = 200
  Rows = 50
  Metrics = "acme-tools.metrics/overview"
  Flame = "acme-tools.flame/flame"

proc words(s: string): seq[string] = strutils.splitWhitespace(s)

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

proc rowOf(sess: var TuiTestSession; needle: string): int =
  ## The first screen row showing `needle`, or -1.
  let lines = sess.screen.splitLines
  for i, l in lines:
    if needle in l: return i
  -1

proc colOf(sess: var TuiTestSession; row: int; needle: string): int =
  ## The display column of `needle` on `row` (cells, not bytes), or -1.
  let line = sess.text(row)
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc command(sess: var TuiTestSession; line: string) =
  sess.send("\e")
  sleep(150)
  sess.send(":" & line & "\r")
  sleep(150)

proc commandShows(sess: var TuiTestSession; line, needle: string;
                  ceilingMs = 90_000): bool =
  var waited = 0
  while waited < ceilingMs:
    sess.command(line)
    if sess.screenHas(needle, ceilingMs = 2_000): return true
    waited += 2_500
  checkpoint "never shown by :" & line & ": " & needle & "\n" & sess.screen
  false

proc click(sess: var TuiTestSession; row, col: int) =
  ## An SGR-1006 left press and release at a 0-based cell.
  sess.send("\e[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sleep(80)
  sess.send("\e[<0;" & $(col + 1) & ";" & $(row + 1) & "m")
  sleep(150)

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
  result = createTempDir("plat81-panes-", "")
  createDir(result / "components")
  discard installPackage(result / "components")

proc quit(sess: var TuiTestSession) =
  sess.command("quit")
  discard sess.waitExit(initDuration(seconds = 30))
  sess.close()

proc grantBoth(sess: var TuiTestSession) =
  # One at a time, each confirmed on the status line before the next is
  # typed: a second command typed while the first plugin's process is
  # starting was measured, at load ~100, to stay unsubmitted in the prompt.
  sess.command("plugins grant acme-tools.metrics")
  discard sess.screenHas("granted acme-tools.metrics", ceilingMs = 20_000)
  sleep(1_000)
  sess.command("plugins grant acme-tools.flame")
  discard sess.screenHas("granted acme-tools.flame", ceilingMs = 20_000)
  sleep(1_000)
  check sess.commandShows("plugins", "acme-tools.metrics  running")
  check sess.commandShows("plugins", "acme-tools.flame  running")
  sess.send("\e")
  sleep(200)

proc savedLayouts(home: string): seq[JsonNode] =
  for f in walkFiles(home / "layout" / "*.json"):
    try: result.add parseFile(f)
    except CatchableError: discard

proc leafParentOf(n: JsonNode; id: string; parent: JsonNode = nil): JsonNode =
  ## The container holding contributed leaf `id` in a saved tree, or nil.
  if n.isNil or n.kind != JObject: return nil
  if n{"contributedPane"}.getStr("") == id:
    return (if parent.isNil: newJObject() else: parent)
  if n.hasKey("children"):
    for c in n["children"]:
      let hit = leafParentOf(c, id, n)
      if not hit.isNil: return hit
  nil

suite "plugin panes docked in the terminal's layout":

  test "a plugin pane docks beside a core pane, draws mirrored state, and its decoration follows a step":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    # PLACED WHEN THE PLUGIN FIRST ACTIVATED: both panes are tabs of the
    # Variables stack, and Variables is still the tab shown.
    check sess.screenHas("Metrics")
    let tabsRow = sess.rowOf("Metrics")
    check tabsRow >= 0
    if tabsRow >= 0:
      let row = sess.text(tabsRow)
      checkpoint "tab strip: " & row
      check "Variables" in row
      check "Flame" in row
    # Shown: the tab is selected and draws the MIRRORED debugger state.
    sess.command("plugins show " & Metrics)
    check sess.screenHas("line main.py")
    check sess.screenHas("position ")
    proc positionShown(sess: var TuiTestSession): string =
      let r = sess.rowOf("position ")
      if r < 0: return ""
      let row = sess.text(r)
      row[row.find("position ") + "position ".len .. ^1].words()[0]
    let posBefore = sess.positionShown()
    # THE DECORATION: `metrics: line N` on the source pane's row for line N,
    # and on the status line.
    check sess.screenHas("◆ metrics: line ")
    let first = sess.rowOf("◆ metrics: line ")
    var firstLine = ""
    if first >= 0:
      let row = sess.text(first)
      let at = row.find("metrics: line ")
      firstLine = row[at + "metrics: line ".len .. ^1].words()[0]
      checkpoint "decorated row " & $first & ": " & row
      # The gutter on that row numbers the same line the decoration names.
      check (" " & firstLine & " ") in row[0 ..< at]
    check sess.screenHas("acme-tools.metrics: metrics: line " & firstLine)
    # A STEP: the pane follows (the new epoch), and so does the decoration —
    # it names the new line, on that line's row.
    sess.command("next")
    var posMoved = false
    for _ in 0 ..< 300:
      let now = sess.positionShown()
      if now.len > 0 and now != posBefore:
        posMoved = true
        break
      sleep(200)
    checkpoint "position before the step: " & posBefore
    check posMoved
    var moved = false
    for _ in 0 ..< 150:
      let r = sess.rowOf("◆ metrics: line ")
      if r >= 0 and r != first:
        let row = sess.text(r)
        let at = row.find("metrics: line ")
        let n = row[at + "metrics: line ".len .. ^1].words()[0]
        if n != firstLine and (" " & n & " ") in row[0 ..< at]:
          moved = true
          break
      sleep(200)
    check moved
    sess.quit()
    removeDir(home)

  test "Enter and a click on a flame row round-trip through view-event":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Flame)
    check sess.screenHas("main 60%")
    check not ("(activated)" in sess.screen)
    # ENTER on the focused flame pane: the host's `applyKey` activates the
    # highlighted row and sends `view-event`; the plugin re-pushes.
    sess.send("\e")
    sleep(200)
    sess.send("\r")
    check sess.screenHas("✓ main 60% (activated)")
    # A CLICK on the other row activates THAT row.
    let r = sess.rowOf("work 40%")
    check r >= 0
    if r >= 0:
      sess.click(r, sess.colOf(r, "work 40%"))
      check sess.screenHas("✓ work 40% (activated)")
      check not ("✓ main 60%" in sess.screen)
    sess.quit()
    removeDir(home)

  test "moved, persisted across a restart, and shown as not loaded once the package is removed":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Metrics)
    check sess.screenHas("line main.py")
    # MOVED with a layout verb, out of the Variables stack into a split.
    sess.command("move-pane left")
    sleep(1_000)
    sess.quit()
    let docs = savedLayouts(home)
    check docs.len > 0
    var parentKind = ""
    for d in docs:
      let p = leafParentOf(d{"layout"}, Metrics)
      if not p.isNil:
        parentKind = p{"kind"}.getStr("")
        checkpoint "saved parent of " & Metrics & ": " & $p
    check parentKind in ["row", "column"]
    # RESTORED: the pane is where it was moved to, drawing mirrored state with
    # no `:plugins show`.
    sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.screenHas("line main.py", ceilingMs = 90_000)
    check sess.rowOf("Metrics") >= 0
    sess.quit()
    # THE PACKAGE REMOVED: the slot stays, saying which extension is missing.
    removeDir(home / "components" / "acme-tools@1.0.0")
    sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.screenHas("This pane is provided")
    check sess.screenHas(Metrics)
    check not ("line main.py" in sess.screen)
    sess.quit()
    var after = ""
    for d in savedLayouts(home): after.add $d
    check Metrics in after
    removeDir(home)

proc drag(sess: var TuiTestSession; fromRow, fromCol, toRow, toCol: int) =
  ## An SGR-1006 left-button drag: press, motion reports along the way
  ## (button 32 = motion with the left button held), release.
  sess.send("\e[<0;" & $(fromCol + 1) & ";" & $(fromRow + 1) & "M")
  sleep(120)
  let steps = 6
  for i in 1 .. steps:
    let r = fromRow + (toRow - fromRow) * i div steps
    let c = fromCol + (toCol - fromCol) * i div steps
    sess.send("\e[<32;" & $(c + 1) & ";" & $(r + 1) & "M")
    sleep(80)
  sess.send("\e[<0;" & $(toCol + 1) & ";" & $(toRow + 1) & "m")
  sleep(300)

suite "plugin panes move, open, stay closed and mark like built-in ones":

  test "a plugin tab dragged with the mouse lands where it is dropped, and persists":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Metrics)
    check sess.screenHas("line main.py")
    let tabRow = sess.rowOf(" Metrics ")
    check tabRow >= 0
    let srcRow = sess.rowOf("#!/usr/bin/env python3")
    check srcRow >= 0
    if tabRow >= 0 and srcRow >= 0:
      let tabCol = sess.colOf(tabRow, " Metrics ") + 3
      let codeCol = sess.colOf(srcRow, "#!/usr/bin/env python3") + 10
      # From the Variables stack's tab strip to the middle of the editor.
      sess.drag(tabRow, tabCol, srcRow + 10, codeCol)
    sess.quit()
    var parent: JsonNode = nil
    for d in savedLayouts(home):
      let p = leafParentOf(d{"layout"}, Metrics)
      if not p.isNil: parent = p
    check not parent.isNil
    if not parent.isNil:
      checkpoint "saved parent of " & Metrics & ": " & $parent
      var withEditor = false
      for c in parent{"children"}:
        if c{"pane"}.getStr("") == "editor": withEditor = true
      check withEditor
    removeDir(home)

  test "a click on a docked plugin pane's label docks it open":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Flame)
    check sess.screenHas("main 60%")
    sess.command("dock bottom")
    var gone = false
    for _ in 0 ..< 50:
      if "main 60%" notin sess.screen:
        gone = true
        break
      sleep(200)
    check gone
    # The bottom strip is on the status row; its label is the pane's title.
    let labelRow = Rows - 1
    let labelCol = sess.colOf(labelRow, "Flame")
    check labelCol >= 0
    if labelCol >= 0:
      sess.click(labelRow, labelCol + 1)
      check sess.screenHas("main 60%")
    sess.quit()
    removeDir(home)

  test "a plugin pane the user closed stays closed in later sessions, and Show pane brings it back":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Flame)
    check sess.screenHas("main 60%")
    sess.command("close-pane")
    var closed = false
    for _ in 0 ..< 50:
      if "main 60%" notin sess.screen:
        closed = true
        break
      sleep(200)
    check closed
    sess.quit()
    # A NEW SESSION: Metrics is placed again, Flame is not.
    sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.screenHas("Metrics", ceilingMs = 90_000)
    sleep(3_000)
    let strip = sess.rowOf("Metrics")
    if strip >= 0:
      checkpoint "tab strip: " & sess.text(strip)
      check "Flame" notin sess.text(strip)
    # Show pane brings it back, and it stays back.
    sess.command("plugins show " & Flame)
    check sess.screenHas("main 60%")
    sess.quit()
    sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    check sess.screenHas("Metrics", ceilingMs = 90_000)
    var back = false
    for _ in 0 ..< 150:
      let r = sess.rowOf("Metrics")
      if r >= 0 and "Flame" in sess.text(r):
        back = true
        break
      sleep(200)
    check back
    sess.quit()
    removeDir(home)

  test "a plugin's declared marker is a glyph in the gutter, on its line":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    check sess.screenHas("◆ metrics: line ")
    let r = sess.rowOf("◆ metrics: line ")
    check r >= 0
    if r >= 0:
      var marked = false
      for _ in 0 ..< 150:
        let row = sess.text(r)
        let at = row.find("metrics: line ")
        let n = row[at + "metrics: line ".len .. ^1].words()[0]
        # THE GUTTER: `★` before the line number, not the end-of-line text.
        let gutter = row[0 ..< row.find(" " & n & " ")]
        if "★" in gutter:
          marked = true
          break
        sleep(200)
      checkpoint "marked row: " & sess.text(r)
      check marked
    sess.quit()
    removeDir(home)

proc hover(sess: var TuiTestSession; row, col: int) =
  ## The pointer passing over a cell with no button held (SGR-1006 motion,
  ## button 35), which the terminal reports under `?1003`.
  sess.send("\e[<35;" & $(col + 1) & ";" & $(row + 1) & "M")
  sleep(60)

suite "a docked plugin pane previews on hover":

  test "resting on a docked plugin pane's label previews it, and leaving dismisses it":
    let home = newHome()
    var sess = spawnTui(home)
    settleOnDebugger(sess, Cols, Rows)
    sess.grantBoth()
    sess.command("plugins show " & Flame)
    check sess.screenHas("main 60%")
    sess.command("dock bottom")
    var gone = false
    for _ in 0 ..< 50:
      if "main 60%" notin sess.screen:
        gone = true
        break
      sleep(200)
    check gone
    let labelRow = Rows - 1
    let labelCol = sess.colOf(labelRow, "Flame")
    check labelCol >= 0
    if labelCol >= 0:
      # REST on the label: the preview opens after the delay, drawn from the
      # plugin's last view, without a click.
      sess.hover(labelRow, labelCol + 1)
      sess.hover(labelRow, labelCol + 2)
      check sess.screenHas("main 60%", ceilingMs = 10_000)
      # LEAVE the label and the overlay: the preview closes after its delay.
      sess.hover(5, 40)
      sess.hover(6, 41)
      var dismissed = false
      for _ in 0 ..< 50:
        if "main 60%" notin sess.screen:
          dismissed = true
          break
        sleep(200)
      check dismissed
    sess.quit()
    removeDir(home)
