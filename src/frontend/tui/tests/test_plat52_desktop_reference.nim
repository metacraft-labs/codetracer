## test_plat52_desktop_reference.nim — PLAT-52: the desktop's Terminal Output
## pane, MEASURED on the real Electron app
## (`src/tests/visual/answers/plat52-terminal.electron.json`, written by
## `scripts/plat52-capture-electron.sh`), against the shared model every
## front-end draws from (`viewmodels/terminal_output_model`, fed here by the
## native producer from a real `replay-server` on the same recording):
##
##   * the same lines, the same fragments, each from the same write;
##   * each fragment's attributes — its colour and ground through the shared
##     palette, its weight, slant and decoration — are what the desktop
##     computed for it (`getComputedStyle`), and the future ones are the
##     desktop's `.future` (half opacity);
##   * a click on line 10's fragment landed, on the desktop, at the tick of
##     the write the model says produced it;
##   * the desktop opens NO menu on a line (so the native panes open none);
##   * the screen: the desktop's rows at each tick its scrubber was dragged to
##     are the model's screen at that tick, and the marks under its slider
##     are the model's marks.
##
## No mocks: the desktop's numbers are the real app's, the model is fed by the
## real engine.

import std/[json, os, strutils, unittest]

import isonim/core/[signals, computation]

import headless_session
import store/types
import viewmodels/terminal_output_vm
import ../../viewmodel/host/terminal_output_source
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 2647

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  AnswersFile = "src/tests/visual/answers/plat52-terminal.electron.json"
  DesktopBodyText = "#f3f3f3"
    ## The desktop's `colors-ui-text-primary-body` (Dark): the colour of a
    ## fragment that names none.
  DesktopFutureText = "#ffffff"
    ## `.future { color: white; opacity: 0.5 }` (`styles/components/
    ## terminal.styl`).

proc spec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc effective(a: TermAttrs): tuple[fg, bg: string] =
  ## The colours a run is DRAWN in (`drawnColours`), as hex.
  let (fg, bg) = drawnColours(a)
  (termHex(fg), termHex(bg))

let answers =
  if fileExists(AnswersFile): parseJson(readFile(AnswersFile))
  else: newJObject()

suite "PLAT-52: the desktop's Terminal Output pane, measured":

  test "the desktop's lines and fragments are the shared model's":
    require answers.hasKey("lines")
    let rec = resolveFixture(spec("terminal_colours"))
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    discard s.loadTerminalOutput()
    let vm = s.session.terminalOutputVM
    let model = vm.lines.val
    let desk = answers["lines"]["linesAfterClick"]
    ck desk.len == model.len
    var fragments = 0
    var coloured = 0
    for i in 0 ..< min(desk.len, model.len):
      ck desk[i]["text"].getStr == lineText(model[i])
      let df = desk[i]["fragments"]
      ck df.len == model[i].fragments.len
      for j in 0 ..< min(df.len, model[i].fragments.len):
        let f = model[i].fragments[j]
        let d = df[j]
        ck d["write"].getInt == f.eventIndex
        ck d["text"].getStr == f.text
        let (fg, bg) = effective(f.style)
        # A future fragment that names no colour is the desktop's
        # `.future { color: white }`.
        let want = if fg.len > 0: fg
                   elif d["tense"].getStr == "future": DesktopFutureText
                   else: DesktopBodyText
        if d["color"].getStr != want:
          checkpoint("line " & $i & " '" & f.text & "': desktop " &
                     d["color"].getStr & ", model " & want)
        ck d["color"].getStr == want
        ck d["background"].getStr ==
           (if bg.len > 0: bg else: "transparent")
        ck (d["weight"].getStr == "700") == f.style.bold
        ck (d["fontStyle"].getStr == "italic") == f.style.italic
        ck (d["decoration"].getStr.contains("underline")) ==
           f.style.underline
        inc fragments
        if fg.len > 0: inc coloured
    checkpoint($fragments & " fragments, " & $coloured & " coloured")
    ck fragments > 250
    ck coloured > 120

  test "the future is the desktop's .future; the click lands at its write":
    require answers.hasKey("lines")
    let rec = resolveFixture(spec("terminal_colours"))
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    discard s.loadTerminalOutput()
    let vm = s.session.terminalOutputVM
    let lines = answers["lines"]
    # At the entry (tick 0) every fragment is still to come: `.future`, at
    # half opacity — the tense the model gives it.
    for line in lines["linesAtStart"]:
      for f in line["fragments"]:
        ck f["tense"].getStr == $fragmentTense(0, 1)
        ck f["opacity"].getStr == "0.5"
    let click = lines["click"]
    ck click["moved"].getBool
    let write = click["write"].getInt
    ck write == vm.lines.val[click["line"].getInt].fragments[0].eventIndex
    ck click["after"]["ticks"].getInt == int(vm.events.val[write].rrTicks)
    # After it, the clicked line is active, the next one future.
    let after = lines["linesAfterClick"]
    ck after[10]["fragments"][0]["tense"].getStr == "active"
    ck after[9]["fragments"][0]["tense"].getStr == "past"
    ck after[11]["fragments"][0]["tense"].getStr == "future"
    ck after[11]["fragments"][0]["opacity"].getStr == "0.5"
    # No menu on a line, on the desktop: the native panes open none either.
    ck lines["lineContextMenu"].len == 0

  test "the desktop's screen, at each tick its scrubber reached, is the model's":
    require answers.hasKey("screen")
    let rec = resolveFixture(spec("terminal_screen"))
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    discard s.loadTerminalOutput()
    let vm = s.session.terminalOutputVM
    let screen = answers["screen"]
    ck screen["view"].getStr == "screen"
    ck screen["rangeMax"].getInt == vm.screen.writeCount - 1
    var marks: seq[string] = @[]
    for m in screen["marks"]:
      marks.add m["kind"].getStr & "@" & $m["write"].getInt
    var want: seq[string] = @[]
    for m in vm.screen.marks:
      want.add $m.kind & "@" & $m.write
    ck marks == want
    var steps = 0
    for step in screen["drag"]:
      # Real-time: the drag moved the desktop's debugger to the write's tick
      # while it was still HELD (no release yet), showing that write.
      let target = step["target"].getInt
      ck step["heldTicks"].getInt == int(vm.screen.writes[target].rrTicks)
      ck step["heldWrite"].getInt == target
      # Released there: the screen as of that tick — its last write.
      ck step["ticks"].getInt == step["heldTicks"].getInt
      let shown = vm.screen.writeAtTick(uint64(step["ticks"].getInt))
      ck step["write"].getInt == shown
      let model = vm.screen.screenAfter(shown)
      var rowsAgree = 0
      for r, row in step["rows"].getElems:
        if row.getStr.strip(leading = false) ==
           model.screenRowText(r).strip(leading = false):
          inc rowsAgree
        else:
          checkpoint("write " & $shown & " row " & $r & ": desktop '" &
                     row.getStr & "'")
      ck rowsAgree == model.rows
      inc steps
    ck steps == 3
    ck screen["afterToggle"].getStr == "lines"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
