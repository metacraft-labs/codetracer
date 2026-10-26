## test_plat70a_gpui_plan.nim — PLAT-70 Part A (Horizontal-Overflow.md §4),
## the GPUI window's text panes scroll sideways, read off the SHIPPED binary's
## window plan (`codetracer-gpui --report-window-plan --window-ops=…`: the
## window's own root builder, and its own pointer and key handlers) over a
## real recording of `test-programs/wide_lines` against a real
## `replay-server`:
##
##   * the EDITOR's bar is the shared scrubber model over the WHOLE document
##     (§4.1: its exact content width, the widest line of the file, not of
##     the rows drawn); a horizontal wheel (`dx`) and Shift + the vertical
##     wheel move it `WheelColumns` a notch and never the rows (HO-6); a press
##     on the bar is a track click that centres its column, a held thumb is
##     followed — and neither moves the caret or the debugger (HO-4); the
##     caret's column is the track's mark; `End` on the wide line brings its
##     end into view (§4.5);
##   * the TERMINAL OUTPUT's line view: its 12 px bar under the lines, the
##     12 x 12 corner that belongs to neither track (HO-7), the wheel, Shift +
##     wheel, a track press, and `Right` / `Left` (CUA's view keys).
##
## No mocks: the binary, the engine and the recording are the product's.

import replay_prerequisite
import std/[json, math, os, osproc, streams, strtabs, strutils, tempfiles,
            unicode, unittest]
import ./gpui_child_env

import codetracer_embed

import ../../tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 70

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1000
  Program = "test-programs/wide_lines/main.py"
  WideLine = 26
  MinThumbPx = 20

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc recording(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "wide_lines", program: Program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let subject = recording()
let source = readFile(repo / Program).splitLines()

proc windowPlan(ops: string; trace: var string): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat70a-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat70a-gpui-plan-", ".err")
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

proc windowPlan(ops: string): JsonNode =
  var trace = ""
  windowPlan(ops, trace)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc collect(n: JsonNode; name: string; acc: var seq[JsonNode]) =
  if n.isNil: return
  if attr(n, name).len > 0: acc.add n
  for c in n{"children"}.getElems: collect(c, name, acc)

proc all(n: JsonNode; name: string): seq[JsonNode] =
  collect(n, name, result)

proc text(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add text(c)

proc px(n: JsonNode; key: string): int =
  let v = n{"styles"}{key}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc field(stamp, key: string): int =
  ## One `k=v` of a `;`-separated stamp.
  for part in stamp.split(';'):
    let kv = part.split('=')
    if kv.len == 2 and kv[0] == key: return parseInt(kv[1])
  -1

proc editorStamp(plan: JsonNode): string =
  let n = plan.all("data-ct-editor-scroll")
  if n.len == 0: "" else: n[0].attr("data-ct-editor-scroll")

proc codeOf(plan: JsonNode; line: int): string =
  ## The CODE text a drawn row carries, by line number.
  for row in plan.all("data-ct-row"):
    if row.attr("data-ct-row") == $line:
      for col in row.all("data-ct-code-column"):
        result.add text(col)

proc rowLines(plan: JsonNode): seq[string] =
  for row in plan.all("data-ct-row"):
    result.add row.attr("data-ct-row")

proc caretOf(plan: JsonNode): string =
  let n = plan.all("data-ct-caret")
  if n.len == 0: "" else: n[0].attr("data-ct-caret")

proc executionOf(plan: JsonNode): string =
  let n = plan.all("data-ct-execution-line")
  if n.len == 0: "" else: n[0].attr("data-ct-execution-line")

proc widestSourceLine(): int =
  ## The editor's content width read off the file independently: every line
  ## is ASCII or one-column punctuation, with no tab.
  for line in source:
    result = max(result, line.runeLen)

proc terminalLeft(plan: JsonNode): int =
  let n = plan.all("data-ct-terminal-left")
  if n.len == 0: -1 else: parseInt(n[0].attr("data-ct-terminal-left"))

proc terminalHBar(plan: JsonNode): JsonNode =
  for n in plan.all("data-ct-terminal-track"):
    if n.attr("data-ct-terminal-track") == "hbar": return n
  newJNull()

proc terminalLineText(plan: JsonNode; index: int): string =
  for row in plan.all("data-ct-terminal-line"):
    if row.attr("data-ct-terminal-line") == $index: return text(row)

const OutputLine = "<<LEFT-EDGE>> the quick brown fox jumps over the lazy " &
  "dog, 0123456789 the quick brown fox jumps over the lazy dog, 0123456789 " &
  "the quick brown fox jumps over the lazy dog, 0123456789 the quick brown " &
  "fox jumps over the lazy dog, 0123456789 <<RIGHT-EDGE>>"

suite "PLAT-70 Part A: the GPUI window's editor scrolls sideways":

  test "the bar is the scrubber model over the WHOLE document (§4.1, §4.2)":
    let rest = windowPlan("")
    let stamp = rest.editorStamp
    checkpoint("at rest: " & stamp)
    let content = widestSourceLine()
    ck stamp.field("codeCols") == content
    ck stamp.field("leftCols") == 0
    let viewport = stamp.field("viewport")
    let viewCols = content - stamp.field("maxLeftCols")
    ck viewCols > 0
    ck viewCols < content
    let tracks = rest.all("data-ct-editor-scrollbar")
    ck tracks.len == 1
    let thumb = rest.all("data-ct-editor-scrollbar-thumb")[0]
    # `viewportCols / contentCols` of the track, at least 20 px — restated
    # from the specification's sentence, not from the product.
    ck thumb.px("w") == min(viewport, max(MinThumbPx,
         int(round(float(viewport) * float(viewCols) / float(content)))))
    ck tracks[0].px("padding_left") == 0
    # The caret's display column is the track's mark (the caret starts on
    # the execution line, at column 0).
    ck rest.all("data-ct-editor-scrollbar-mark").len == 1

  test "the wheel and Shift + wheel: 6 columns a notch, never the rows":
    let rest = windowPlan("")
    let line = source[WideLine - 1]
    ck rest.codeOf(WideLine) == line
    for (ops, cols) in [("hwheel:editor:6", 6), ("swheel:editor:1", 6),
                        ("swheel:editor:2", 12),
                        ("swheel:editor:2,swheel:editor:-1", 6)]:
      let moved = windowPlan(ops)
      checkpoint(ops & " -> " & moved.editorStamp)
      ck moved.editorStamp.field("leftCols") == cols
      ck moved.codeOf(WideLine) == line.runeSubstr(cols)
      ck moved.rowLines == rest.rowLines              # HO-6: never the rows
      ck moved.executionOf == rest.executionOf

  test "a track press centres its column; a held thumb follows (HO-3, HO-4)":
    let rest = windowPlan("")
    let content = widestSourceLine()
    let viewport = rest.editorStamp.field("viewport")
    let viewCols = content - rest.editorStamp.field("maxLeftCols")
    var hv = HorizontalView(contentCols: content, viewportCols: viewCols)
    discard hv.clickTrack(trackFractionAt(viewport * 900 div 1000, viewport))
    let clicked = windowPlan("hbar:editor:track:900")
    checkpoint("track 900 -> " & clicked.editorStamp)
    ck clicked.editorStamp.field("leftCols") == hv.leftCol
    ck hv.leftCol > 0
    ck clicked.codeOf(WideLine) == source[WideLine - 1].runeSubstr(hv.leftCol)
    ck clicked.rowLines == rest.rowLines
    # HO-4: the caret and the execution line are where they were — a caret
    # placed on the wide line, the track pressed far right and back at its
    # start: the caret is drawn at its own cell again.
    const Caret = "click:code:26@5"
    let placed = windowPlan(Caret)
    ck placed.caretOf == "26:5"
    let away = windowPlan(Caret & ",hbar:editor:track:900")
    ck away.caretOf == ""                      # scrolled off, not moved
    let back = windowPlan(Caret & ",hbar:editor:track:900,hbar:editor:track:0")
    ck back.editorStamp.field("leftCols") == 0
    ck back.caretOf == placed.caretOf
    ck back.executionOf == rest.executionOf
    # A drag of the thumb from rest to the track's middle.
    var dragged = HorizontalView(contentCols: content, viewportCols: viewCols)
    let f = trackFractionAt(viewport * 500 div 1000, viewport)
    discard dragged.dragThumb(f - dragged.barModel.thumbLength / 2.0)
    let held = windowPlan("hbar:editor:drag:0:500")
    checkpoint("drag 0..500 -> " & held.editorStamp)
    ck held.editorStamp.field("leftCols") == dragged.leftCol
    ck dragged.leftCol > 0
    ck held.executionOf == rest.executionOf

  test "caret-follow: End on the wide line shows its end (§4.5)":
    let line = source[WideLine - 1]
    let at = windowPlan("click:code:" & $WideLine & "@5")
    ck at.editorStamp.field("leftCols") == 0
    ck at.caretOf == $WideLine & ":5"
    let viewCols = widestSourceLine() - at.editorStamp.field("maxLeftCols")
    let ended = windowPlan("click:code:" & $WideLine & "@5,key:end")
    checkpoint("End -> " & ended.editorStamp)
    # The caret after the last character, on the view's last column: the
    # margin is not applied past the line's end.
    let left = line.runeLen - viewCols + 1
    ck ended.editorStamp.field("leftCols") == left
    ck ended.codeOf(WideLine) == line.runeSubstr(left)
    ck ended.codeOf(WideLine).endsWith("<<RIGHT-EDGE>>\"")
    ck ended.caretOf == $WideLine & ":" & $(line.runeLen + 1)

suite "PLAT-70 Part A: the GPUI window's Terminal Output scrolls sideways":

  test "the bar under the lines, the corner, the wheel, the keys":
    const Tab = "click:tab:terminalOutput"
    let rest = windowPlan(Tab)
    let bar = rest.terminalHBar
    ck bar.kind == JObject
    let stamp = bar.attr("data-ct-hbar")
    checkpoint("terminal bar: " & stamp)
    ck stamp.field("content") == OutputLine.runeLen
    let viewCols = stamp.field("viewport")
    ck viewCols < OutputLine.runeLen
    ck rest.terminalLeft == 0
    ck rest.terminalLineText(0) == OutputLine.runeSubstr(0, viewCols)
    # The thumb: the model's share of the 12 px track's width.
    let trackW = bar.px("w")
    ck bar.px("h") == 12
    ck bar.attr("data-ct-thumb-px") == $min(trackW, max(MinThumbPx,
         int(round(float(trackW) * float(viewCols) /
                   float(OutputLine.runeLen)))))
    # HO-7: the corner is its own 12 x 12 square, under the vertical track
    # and right of the bar, and the vertical track stops above it.
    let corner = rest.all("data-ct-terminal-corner")
    ck corner.len == 1
    ck corner[0].px("w") == 12 and corner[0].px("h") == 12
    ck corner[0].px("left") == bar.px("left") + trackW
    ck corner[0].px("top") == bar.px("top")
    var vtrack = newJNull()
    for n in rest.all("data-ct-terminal-track"):
      if n.attr("data-ct-terminal-track") == "lines": vtrack = n
    ck vtrack.kind == JObject
    ck vtrack.px("top") + vtrack.px("height") <= corner[0].px("top")
    # The wheel and Shift + wheel: 6 columns a notch.
    for (ops, left) in [("hwheel:terminalOutput:6", 6),
                        ("swheel:terminalOutput:1", 6),
                        ("swheel:terminalOutput:3,swheel:terminalOutput:-1",
                         12)]:
      let moved = windowPlan(Tab & "," & ops)
      ck moved.terminalLeft == left
      ck moved.terminalLineText(0) == OutputLine.runeSubstr(left, viewCols)
      ck moved.terminalLineText(1) == "a short line".runeSubstr(left)
    # A press at the track's end shows the line's end; the corner is no
    # gesture.
    let ended = windowPlan(Tab & ",hbar:terminalOutput:track:1000")
    ck ended.terminalLeft == OutputLine.runeLen - viewCols
    ck ended.terminalLineText(0).endsWith("<<RIGHT-EDGE>>")
    let cornered = windowPlan(Tab & ",hbar:terminalOutput:corner")
    ck cornered.terminalLeft == 0
    # CUA's view keys in the focused line view: `Right`, then `Left`.
    let right = windowPlan(Tab & ",term:blank,key:right")
    ck right.terminalLeft == 6
    let left = windowPlan(Tab & ",term:blank,key:right,key:right,key:left")
    ck left.terminalLeft == 6

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
