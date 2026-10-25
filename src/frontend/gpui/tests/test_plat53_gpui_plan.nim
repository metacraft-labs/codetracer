## test_plat53_gpui_plan.nim — PLAT-53: **the Test Results pane in the GPUI
## window**, read from the window's own render plan and measured against the
## desktop.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8.
##
## The shipped `codetracer-gpui` (`just build-gpui`) on a recording, started
## in the PLAT-53 Noir crate's directory (the window's project, §8.2), with
## `--report-window-plan`: `--window-ops` events dispatched through the
## window's own pointer handler (`tests:*`, aimed where the pane was drawn),
## then the window as a plan. The reference is the REAL Electron app's pane
## over the same crate (`src/tests/visual/answers/
## plat53-test-results.electron.json`, `just plat53-capture-electron`):
##
##   * BEFORE A RUN: the headline, the ▶'s title, and per row the test id,
##     state, mark, name, location and both controls' titles, glyphs and
##     modes — all equal to the desktop's;
##   * AFTER THE ▶ (the real `ct test run`): the same after the desktop's run,
##     a duration on each row, the failed row's message equal to the
##     desktop's, and the marks and the message in the desktop's computed
##     colours;
##   * THE FAILING TEST'S `⏵` records it (the real `ct record-test`) and opens
##     the recording in a NEW SESSION TAB; `⏵` again opens the same one and
##     runs nothing; Shift held arms the re-record — a new recording, opened;
##   * §5: a run SIGKILLed mid-way (its process group) settles, saying so;
##   * THE EDIT WINDOW, which has no session tabs, states where the recording
##     is instead of opening it.
##
## No mocks: the real binary, a real recording made by the Python recorder, a
## real `replay-server`, the real `ct`, `ct-test` and `nargo` on a real crate,
## the real Electron app's answers.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../tui/tests/fixtures/fixture_provider
import ../../tui/tests/fixtures/plat53_noir_project

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 32
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  AnswersFile = "src/tests/visual/answers/plat53-test-results.electron.json"
  NoSessionTabsInEditText =
    "this window has no session tabs (it is the Edit window), so the " &
    "recording is not opened here; it is at "
    ## `gpui/main.NoSessionTabsInEditText`, spelled again: the suite asserts
    ## the window's words, not the constant's.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let answers = parseJson(readFile(repo / AnswersFile))
let ct = fixture_provider.findCtBinary()

proc calc(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "calc", program: "test-programs/calc/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = calc()

proc windowPlan(project, ops: string; edit = false):
    tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace — the binary run in
  ## `project`, its own scratch homes.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  doAssert ct.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
  let state = createTempDir("plat53-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CT_BIN"] = ct
  env["TEST_CERTIFICATES_DIR"] = state / "certs"
  env["TEST_CERTIFICATES_SYSTEM_DIR"] = state / "certs-system"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat53-gpui-plan-", ".err")
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops]
  if edit:
    args.add @["--edit", project]
  else:
    args.add trace
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    workingDir = project, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc colour(n: JsonNode): string =
  n{"styles"}{"text_color"}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc child(n: JsonNode; attribute: string): JsonNode =
  let hits = n.nodesWith(attribute)
  if hits.len > 0: hits[0] else: newJObject()

proc control(row: JsonNode; which: string): JsonNode =
  for c in row.nodesWith("data-ct-test-control"):
    if c.attr("data-ct-test-control") == which:
      return c
  newJObject()

proc cssHex(rgb: string): string =
  ## `rgb(r, g, b)` (a computed style) as `#rrggbb`.
  let parts = rgb.strip().replace("rgb(", "").replace(")", "").split(",")
  if parts.len < 3: return ""
  "#" & parts[0].strip.parseInt.toHex(2).toLowerAscii &
        parts[1].strip.parseInt.toHex(2).toLowerAscii &
        parts[2].strip.parseInt.toHex(2).toLowerAscii

proc words(s: string): string = s.splitWhitespace().join(" ")

proc headline(plan: JsonNode): string =
  plan.nodesWith("data-ct-tests-headline")[0].attr("data-ct-tests-headline")

proc failureLines(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-tests-line"):
    if n.attr("data-ct-tests-line") == "failure":
      result.add n.textOf

proc rowsOf(plan: JsonNode): seq[JsonNode] =
  plan.nodesWith("data-ct-test-id")

proc compareRows(plan: JsonNode; want: JsonNode; ran: bool): int =
  ## How many fields of the plan's rows differ from the desktop's.
  let rows = plan.rowsOf()
  if rows.len != want["rows"].len:
    checkpoint("rows: " & $rows.len & " vs the desktop's " & $want["rows"].len)
    return 1000
  for i, w in want["rows"].getElems:
    let r = rows[i]
    var diffs: seq[string] = @[]
    if r.attr("data-ct-test-id") != w["testId"].getStr: diffs.add "id"
    if r.attr("data-ct-test-state") != w["state"].getStr: diffs.add "state"
    let mark = r.child("data-ct-test-mark")
    if mark.textOf != w["mark"].getStr: diffs.add "mark"
    if ran and mark.colour != cssHex(w["markColor"].getStr):
      diffs.add "mark colour " & mark.colour
    if r.child("data-ct-test-name").attr("data-ct-test-name") !=
       w["name"].getStr: diffs.add "name"
    if r.child("data-ct-test-where").attr("data-ct-test-where") !=
       w["where"].getStr: diffs.add "where"
    let duration = r.child("data-ct-test-duration").attr("data-ct-test-duration")
    if (duration.len > 0) != (w["duration"].getStr.len > 0):
      diffs.add "duration '" & duration & "'"
    let refresh = r.control("refresh")
    if refresh.textOf != w["refresh"]["label"].getStr or
       refresh.attr("data-ct-title") != w["refresh"]["title"].getStr or
       refresh.attr("data-ct-disabled") != $w["refresh"]["disabled"].getBool:
      diffs.add "refresh '" & refresh.attr("data-ct-title") & "'"
    let open = r.control("open")
    if open.textOf != w["open"]["label"].getStr or
       open.attr("data-ct-title") != w["open"]["title"].getStr or
       open.attr("data-ct-open-mode") != w["open"]["mode"].getStr or
       open.attr("data-ct-disabled") != $w["open"]["disabled"].getBool:
      diffs.add "open '" & open.attr("data-ct-title") & "'"
    if diffs.len > 0:
      checkpoint("row " & $i & ": " & diffs.join(", "))
      result += diffs.len

suite "PLAT-53: the Test Results pane in the GPUI window":

  test "before a run: row for row the desktop's":
    let project = writePlat53Project("ct-plat53-gpui-")
    let (plan, _) = windowPlan(project, "tests:show")
    let before = answers["before"]
    ck plan.headline == before["headline"].getStr
    let run = plan.nodesWith("data-ct-tests-run")[0]
    ck run.attr("data-ct-tests-run") == before["run"]["title"].getStr
    ck run.textOf == before["run"]["label"].getStr
    ck run.attr("data-ct-disabled") == $before["run"]["disabled"].getBool
    ck plan.compareRows(before, ran = false) == 0
    removeDir(project)

  test "the ▶: the desktop's verdicts, message and colours":
    let project = writePlat53Project("ct-plat53-gpui-")
    let (plan, tr) = windowPlan(project, "tests:show,tests:run,tests:wait")
    let after = answers["after"]
    ck tr.contains("tests settled: 1 passed, 1 failed")
    ck plan.headline.startsWith("1 passed, 1 failed")
    ck after["headline"].getStr.startsWith("1 passed, 1 failed")
    ck plan.compareRows(after, ran = true) == 0
    var message = ""
    var colours: seq[string] = @[]
    for n in plan.nodesWith("data-ct-tests-line"):
      if n.attr("data-ct-tests-line") == "message":
        message.add " " & n.textOf
        for c in n{"children"}.getElems:
          if c.colour.len > 0: colours.add c.colour
    ck message.words == after["rows"][1]["message"].getStr.words
    ck colours.len > 0 and colours[0] == cssHex(after["rows"][1]["messageColor"].getStr)
    ck plan.failureLines.len == after["failure"].len
    removeDir(project)

  test "the failing test's ⏵ opens its recording in a new tab; again, and with Shift":
    let project = writePlat53Project("ct-plat53-gpui-")
    let (plan, tr) = windowPlan(project,
      "tests:show,tests:open:test_fails,tests:wait," &
      "tests:open:test_fails,tests:wait," &
      "tests:open:test_fails:shift,tests:wait")
    var recordings: seq[string] = @[]
    var opened: seq[string] = @[]
    for line in tr.splitLines():
      let at = line.find("tests: opened the recording ")
      if at >= 0:
        recordings.add line[at + "tests: opened the recording ".len .. ^1].split(' ')[0]
      if line.contains(" as tab ") and line.contains("opened "):
        opened.add line
    checkpoint(tr)
    # Three opens: a record-and-open, an open of THAT recording (nothing
    # recorded), and a Shift-armed re-record opened.
    ck recordings.len == 3
    ck opened.len == 3
    ck recordings.len == 3 and recordings[0] == recordings[1]
    ck recordings.len == 3 and recordings[2] != recordings[0]
    ck tr.contains("tests: open test_fails (record-and-open)")
    ck tr.contains("tests: open test_fails (open-existing)")
    ck tr.contains("tests: open test_fails (refresh-and-open)")
    let fails = plan.rowsOf()[1]
    ck recordings.len == 3 and fails.attr("data-ct-recording-id") == recordings[2]
    ck fails.control("open").attr("data-ct-open-mode") == "open-existing"
    # The window shows the last tab opened: that recording's session.
    ck recordings.len == 3 and
       tr.contains("session shown") and tr.contains(recordings[2])
    removeDir(project)

  test "a press selects a row; the window's keys move the selection":
    let project = writePlat53Project("ct-plat53-gpui-")
    let (plan, tr) = windowPlan(project,
      "tests:show,tests:row:test_passes,key:down")
    let rows = plan.rowsOf()
    ck rows.len == 2 and rows[1].attr("data-ct-selected") == "true"
    ck rows.len == 2 and rows[0].attr("data-ct-selected") == ""
    ck tr.contains("operation list.focus-next")
    removeDir(project)

  test "§5: a run killed mid-way settles, saying so":
    let project = writePlat53Project("ct-plat53-gpui-")
    let (plan, tr) = windowPlan(project,
      "tests:show,tests:run,tests:kill,tests:wait")
    ck tr.contains("tests settled: run failed, no tests ran")
    ck plan.headline == "run failed, no tests ran"
    # The failure block, wrapped to the pane: read as one text.
    ck plan.failureLines.join(" ").words.contains("ended by signal 9")
    ck plan.nodesWith("data-ct-tests-run")[0].attr("data-ct-disabled") == "false"
    removeDir(project)

  test "the Edit window states where the recording is":
    let project = writePlat53Project("ct-plat53-gpui-edit-")
    let (plan, tr) = windowPlan(project,
      "tests:show,tests:open:test_fails,tests:wait", edit = true)
    ck plan.rowsOf().len == 2
    ck plan.failureLines.join(" ").words.startsWith(NoSessionTabsInEditText.words)
    ck not tr.contains(" as tab ")
    removeDir(project)

  test "the assertion count":
    check CHECKS == ExpectedAssertions
