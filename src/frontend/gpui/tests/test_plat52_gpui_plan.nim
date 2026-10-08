## test_plat52_gpui_plan.nim — PLAT-52, the GPUI window's Terminal Output
## pane, read off the SHIPPED binary's window plan (`codetracer-gpui
## --report-window-plan --window-ops=…`, the window's own root builder and its
## own pointer and key handlers) over real recordings and a real
## `replay-server`:
##
##   * `terminal_colours` — every line a row of TEXT RUNS, each run carrying
##     its write, its tense and its decoded SGR attributes, in the colours the
##     desktop draws (the shared model's palette); the future at the desktop's
##     `.future` opacity; a press on a run goes to its write (`ct/event-jump`),
##     after which the runs before it are past and after it future, and the
##     scrubber's current-position mark sits on its line; the scrollbar is a
##     SCRUBBER over the whole output — a press at its end shows the last line
##     of the output, a held thumb dragged to the end does too — and neither
##     moves the debugger;
##   * `terminal_screen` — the pane opens the SCREEN view: the recorded 80x24
##     screen as rows of runs, SCALED to the pane; its built-in scrubber is
##     REAL-TIME — held and moved, it moves the debugger to each write it
##     crosses before any release (the user, 2026-10-06); Right steps a write;
##     the marks of the alternate screen and the clear are under the slider.
##
## No mocks: the binary, the engine and the recordings are the product's.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 203

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc fixture(prefix: string): string =
  ## The recording the terminal lanes record (`test_plat52_terminal_output`
  ## records both on its first run; the tui lane runs before this one).
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

proc windowPlan(ops: string; subject: string; trace: var string): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if subject.len == 0:
    raise newException(IOError, "prerequisite missing: the recording " &
      "(run the tui lane's test_plat52_terminal_output.nim once)")
  let state = createTempDir("plat52-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat52-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc collect(n: JsonNode; name: string; acc: var seq[JsonNode]) =
  if n.isNil: return
  if attr(n, name).len > 0: acc.add n
  for c in n{"children"}.getElems: collect(c, name, acc)

proc all(n: JsonNode; name: string): seq[JsonNode] =
  collect(n, name, result)

proc text(n: JsonNode): string =
  if n{"tag"}.getStr == "#text": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add text(c)

proc pane(plan: JsonNode): JsonNode =
  let found = plan.all("data-ct-terminal")
  if found.len > 0: found[0] else: newJNull()

proc lineRow(plan: JsonNode; index: int): JsonNode =
  for row in plan.all("data-ct-terminal-line"):
    if attr(row, "data-ct-terminal-line") == $index: return row
  newJNull()

proc tracedWrites(trace: string): seq[string] =
  for line in trace.splitLines:
    if "terminal write " in line: result.add line

let colours = fixture("terminal_colours")
let screen = fixture("terminal_screen")
const Tab = "click:tab:terminalOutput"

suite "PLAT-52: the GPUI window draws the Terminal Output pane":

  test "every line is a row of runs carrying its write, tense and attributes":
    var trace = ""
    let plan = windowPlan(Tab, colours, trace)
    let p = plan.pane
    ck attr(p, "data-ct-terminal") == "lines"
    ck attr(p, "data-ct-terminal-total") == "129"
    ck attr(p, "data-ct-terminal-top") == "0"
    let row0 = plan.lineRow(0)
    ck row0.text == "red plain bold green"
    let runs = row0.all("data-ct-terminal-write")
    ck runs.len == 3
    ck attr(runs[0], "data-ct-terminal-style") == "fg=#bb0000"
    ck runs[0]{"styles"}{"text_color"}.getStr == "#bb0000"
    ck attr(runs[2], "data-ct-terminal-style") == "fg=#00bb00 bold"
    ck runs[2]{"styles"}{"font_weight"}.getStr == "bold"
    # At the program's entry nothing has been written yet.
    ck attr(runs[0], "data-ct-terminal-tense") == "future"
    ck runs[0]{"styles"}{"opacity"}.getStr == "0.5"
    let row3 = plan.lineRow(3).all("data-ct-terminal-write")
    ck attr(row3[0], "data-ct-terminal-style") == "fg=#ff8700"
    ck attr(row3[2], "data-ct-terminal-style") == "fg=#008080"
    ck attr(row3[4], "data-ct-terminal-style") == "fg=#000000 bg=#bbbb00"
    # Monospaced, as every terminal draws it.
    ck attr(row0, "data-ct-text-metric") == "mono/md/regular"

  test "a press on a run goes to its write; the pane follows":
    var trace = ""
    let plan = windowPlan(Tab & ",term:line:10:2", colours, trace)
    let writes = trace.tracedWrites
    checkpoint(trace)
    ck writes.len == 1
    ck writes[0].contains("terminal write 11 at tick 108")
    # Writes before it are past, it is active, after it future.
    let r9 = plan.lineRow(9).all("data-ct-terminal-write")
    let r10 = plan.lineRow(10).all("data-ct-terminal-write")
    let r11 = plan.lineRow(11).all("data-ct-terminal-write")
    ck r9.len > 0 and r10.len > 0 and r11.len > 0
    ck attr(r9[0], "data-ct-terminal-tense") == "past"
    ck attr(r10[0], "data-ct-terminal-tense") == "active"
    ck attr(r11[0], "data-ct-terminal-tense") == "future"
    ck r10[0]{"styles"}{"opacity"}.getStr == ""
    # The scrubber's current-position mark is on that line.
    let marks = plan.all("data-ct-terminal-mark")
    ck marks.len == 1
    ck attr(marks[0], "data-ct-mark-line") == "10"

  test "after the same click, the runs are drawn in the desktop's colours":
    # The real Electron app, measured at the same stop (the same line
    # clicked): every fragment's computed colour and ground.
    let answersFile = repo / "src/tests/visual/answers/plat52-terminal.electron.json"
    require fileExists(answersFile)
    let desk = parseJson(readFile(answersFile))["lines"]
    var trace = ""
    let plan = windowPlan(Tab & ",term:line:10:2", colours, trace)
    var compared = 0
    for li in 0 .. 11:
      let runs = plan.lineRow(li).all("data-ct-terminal-write")
      var deskRuns: seq[JsonNode] = @[]
      for f in desk["linesAfterClick"][li]["fragments"]:
        if f["text"].getStr.len > 0: deskRuns.add f
      ck runs.len == deskRuns.len
      for k in 0 ..< min(runs.len, deskRuns.len):
        let d = deskRuns[k]
        ck runs[k].text == d["text"].getStr
        ck attr(runs[k], "data-ct-terminal-tense") == d["tense"].getStr
        let colour = runs[k]{"styles"}{"text_color"}.getStr
        let ground = runs[k]{"styles"}{"bg"}.getStr
        if d["tense"].getStr != "future":
          if colour != d["color"].getStr:
            checkpoint("line " & $li & " '" & d["text"].getStr & "': GPUI " &
                       colour & ", desktop " & d["color"].getStr)
          ck colour == d["color"].getStr
          ck (if ground.len > 0: ground else: "transparent") ==
             d["background"].getStr
          ck (runs[k]{"styles"}{"font_weight"}.getStr == "bold") ==
             (d["weight"].getStr == "700")
          inc compared
        else:
          # `.future`: half opacity on both.
          ck runs[k]{"styles"}{"opacity"}.getStr == d["opacity"].getStr
    checkpoint("runs compared: " & $compared)
    ck compared >= 25

  test "GPUI's scrollbar scrubs the WHOLE output and never moves the debugger":
    var trace = ""
    let plan = windowPlan(Tab & ",term:track:999", colours, trace)
    let p = plan.pane
    let rows = parseInt(attr(p, "data-ct-terminal-rows"))
    ck rows > 5 and rows < 129
    ck attr(p, "data-ct-terminal-top") == $(129 - rows)
    ck plan.lineRow(128).text == "done"
    ck trace.tracedWrites.len == 0
    let track = plan.all("data-ct-terminal-track")
    ck track.len == 1
    ck parseInt(attr(track[0], "data-ct-thumb-top")) > 0
    var t2 = ""
    let dragged = windowPlan(Tab & ",term:drag:0:1000", colours, t2)
    ck attr(dragged.pane, "data-ct-terminal-top") == $(129 - rows)
    ck t2.tracedWrites.len == 0
    var t3 = ""
    let back = windowPlan(Tab & ",term:track:999,term:track:0", colours, t3)
    ck attr(back.pane, "data-ct-terminal-top") == "0"
    # The wheel scrolls the lines, a row per `TerminalRowPx`.
    var t4 = ""
    let wheeled = windowPlan(Tab & ",term:wheel:5", colours, t4)
    ck attr(wheeled.pane, "data-ct-terminal-top") == "5"
    ck t4.tracedWrites.len == 0

suite "PLAT-52: the GPUI window draws a full-screen program's SCREEN":

  test "the screen view: the recorded screen, scaled, with its marks":
    var trace = ""
    let plan = windowPlan(Tab, screen, trace)
    let p = plan.pane
    ck attr(p, "data-ct-terminal") == "screen"
    ck attr(p, "data-ct-terminal-cols") == "80"
    ck attr(p, "data-ct-terminal-rows") == "24"
    let scale = parseFloat(attr(p, "data-ct-terminal-scale"))
    ck scale > 0.2 and scale < 3.0
    ck plan.all("data-ct-terminal-screen-row").len == 24
    var kinds: seq[string] = @[]
    for m in plan.all("data-ct-terminal-mark"):
      kinds.add attr(m, "data-ct-terminal-mark")
    ck "alt-enter" in kinds and "clear" in kinds and "alt-leave" in kinds
    ck plan.all("data-ct-terminal-view").len == 2

  test "the screen's scrubber is REAL-TIME: a held drag moves the debugger":
    var held = ""
    let during = windowPlan(Tab & ",term:scrub:0:500:hold", screen, held)
    # Held, never released: the debugger moved to each write the drag
    # crossed, in order.
    let writes = held.tracedWrites
    checkpoint(held)
    ck writes.len >= 3
    var order: seq[int] = @[]
    for line in writes:
      let at = line.find("terminal write ")
      order.add parseInt(line[at + "terminal write ".len ..< line.find(" at tick")])
    var increasing = true
    for i in 1 ..< order.len:
      if order[i] <= order[i - 1]: increasing = false
    ck increasing
    let w = parseInt(attr(during.pane, "data-ct-terminal-write"))
    ck w == order[^1]
    var text = ""
    for row in during.all("data-ct-terminal-screen-row"):
      text.add row.text & "\n"
    ck text.contains("dashboard")
    var released = ""
    let after = windowPlan(Tab & ",term:scrub:0:500", screen, released)
    ck released.tracedWrites.len == writes.len
    ck parseInt(attr(after.pane, "data-ct-terminal-write")) >= w

  test "Right steps a write; the toggle shows the lines":
    var trace = ""
    let plan = windowPlan(Tab & ",term:key:Right,term:key:Right", screen,
                          trace)
    let writes = trace.tracedWrites
    ck writes.len == 2
    ck writes[0].contains("terminal write 0 at tick ")
    ck writes[1].contains("terminal write 1 at tick ")
    ck attr(plan.pane, "data-ct-terminal-write") == "1"
    var t2 = ""
    let lines = windowPlan(Tab & ",term:view:lines", screen, t2)
    ck attr(lines.pane, "data-ct-terminal") == "lines"
    ck t2.contains("terminal view lines")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
