## test_plat62_gpui_constraints.nim — the Constraints pane in the GPUI window,
## read from the window's own render plan.
##
## Spec: `codetracer-pm` `spec/Planned-Features/Noir-Studio.md` § "The
## Constraints pane on the terminal and the GPUI window (PLAT-62)".
##
## The shipped `codetracer-gpui` (`just build-gpui`) with
## `--report-window-plan` over the PLAT-62 crate (`tui/tests/fixtures/
## plat62_noir_circuit`) — measured by the real `nargo info --json` —
## `--window-ops` events dispatched through the window's own pointer handler
## (`constraints:*`, aimed where the pane was drawn), then the window as a
## plan. Asserted:
##
##   * EDIT MODE: the pane the Edit default places, measured the first time it
##     is on screen; its headline, notice, provenance and every row's name,
##     kind, count, place, title and `linked` EQUAL to the real Electron app's
##     on the same crate (`src/tests/visual/answers/plat62-constraints.
##     electron.json`, `just plat62-capture-electron`);
##   * A PRESS (K67): `halve`'s row puts the editor's caret on its declaring
##     line, the line the desktop's press opened; a directive's opens nothing
##     and says why;
##   * THE MENU (K68): its entries in the desktop's order, disabled with the
##     desktop's reasons on a row placed nowhere; Copy Source Location copies;
##   * KEYS: `list.focus-next` and `list.activate` open the next row's line;
##   * ITS RECORDING: the crate's test recorded and opened in a new session
##     tab (Test Results' `⏵`, the real `ct record-test`); there, where the
##     Debug default places no Constraints pane, `:constraints` opens it with
##     the same rows, and a press opens `main`'s line from the recording.
##
## No mocks: the real binary, the real `nargo`, `ct`, `ct-test` and
## `replay-server` on a real crate, the real Electron app's answers.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import ../../tui/tests/fixtures/fixture_provider
import ../../tui/tests/fixtures/plat62_noir_circuit

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 27
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  AnswersFile = "src/tests/visual/answers/plat62-constraints.electron.json"
  DirectiveReasonText =
    "the compiler generated this function (a directive); no source in the " &
    "project declares it"
    ## `constraints_vm.DirectiveReason`, spelled again: the suite asserts the
    ## window's words, not the constant's.

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

proc writeCrate(): string =
  result = createTempDir("ct-plat62-gpui-", "")
  createDir(result / "src")
  writeFile(result / "Nargo.toml", Plat62NargoToml)
  for (path, content) in Plat62Files:
    writeFile(result / path, content)

proc windowPlan(project, ops: string; edit = false; trace = ""):
    tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace — the binary run in
  ## `project`, its own scratch homes.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat62-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CT_BIN"] = ct
  env["TEST_CERTIFICATES_DIR"] = state / "certs"
  env["TEST_CERTIFICATES_SYSTEM_DIR"] = state / "certs-system"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat62-gpui-plan-", ".err")
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

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    if n{"children"}.kind == JArray:
      for c in n["children"]: walk(c, acc)
  walk(plan, result)

proc partOf(row: JsonNode; part: string): string =
  for n in row.nodesWith("data-ct-constraint-part"):
    if n.attr("data-ct-constraint-part") == part:
      var t = ""
      proc collect(x: JsonNode) =
        if x.kind != JObject: return
        if x{"text"}.kind == JString: t.add x["text"].getStr
        if x{"children"}.kind == JArray:
          for c in x["children"]: collect(c)
      collect(n)
      return t.strip()
  ""

proc menuOf(answer: JsonNode): string =
  ## The desktop's menu as the window's trace says it: `labels|…`.
  var labels: seq[string] = @[]
  for e in answer:
    labels.add e["label"].getStr
  labels.join("|")

suite "PLAT-62: the GPUI window's Constraints pane":

  test "Edit mode: the desktop's rows, measured the first time it is shown":
    let project = writeCrate()
    let (plan, tr) = windowPlan(project, "constraints:show,constraints:wait",
                                edit = true)
    checkpoint(tr)
    ck tr.contains("constraints: measuring " & project)
    let before = answers["before"]
    let pane = plan.nodesWith("data-ct-constraints")
    ck pane.len == 1 and pane[0].attr("data-ct-constraints") ==
                         before["headline"].getStr
    ck plan.nodesWith("data-ct-constraints-provenance").len == 1 and
       plan.nodesWith("data-ct-constraints-provenance")[0].attr(
         "data-ct-constraints-provenance") == before["provenance"].getStr
    ck plan.nodesWith("data-ct-constraints-notice").len ==
       (if before["notice"].getStr.len > 0: 1 else: 0)
    let rows = plan.nodesWith("data-ct-constraint-row")
    ck rows.len == before["rows"].len
    var same = 0
    for i, want in before["rows"].getElems:
      if i >= rows.len: break
      let r = rows[i]
      if r.attr("data-ct-constraint-row") == $want["index"].getInt and
         r.attr("data-ct-constraint-name") == want["name"].getStr and
         (r.partOf("name") == want["name"].getStr or
          (r.partOf("name").endsWith("…") and
           want["name"].getStr.startsWith(r.partOf("name")[0 ..< ^"…".len]))) and
         r.partOf("kind") == want["kind"].getStr and
         r.partOf("count") == want["count"].getStr and
         r.attr("data-ct-constraint-where") == want["where"].getStr and
         r.attr("data-ct-constraint-title") == want["title"].getStr and
         r.attr("data-ct-constraint-linked") == $want["linked"].getBool:
        inc same
      else:
        checkpoint("row " & $i & ": " & $r & " vs " & $want)
    ck same == 4
    removeDir(project)

  test "a press opens the declaring line; a directive's says why":
    let project = writeCrate()
    let (plan, tr) = windowPlan(project,
      "constraints:show,constraints:wait,constraints:row:1",
      edit = true)
    checkpoint(tr)
    ck tr.contains("constraints: press row 1")
    ck tr.contains("caret " & $Plat62HalveLine & ":15")
    ck answers["pressedPlaced"]["line"].getInt == Plat62HalveLine
    ck tr.contains("constraints: opened src/main.nr:" & $Plat62HalveLine)
    var selected: seq[string] = @[]
    for n in plan.nodesWith("data-ct-selected"):
      if n.has("data-ct-constraint-row"):
        selected.add n.attr("data-ct-constraint-row")
    ck selected == @["1"]
    let (_, tr2) = windowPlan(project,
      "constraints:show,constraints:wait,constraints:row:2", edit = true)
    ck tr2.contains("constraints: " & DirectiveReasonText)
    ck not tr2.contains("constraints: opened")
    removeDir(project)

  test "the row's menu: the desktop's entries; Copy Source Location":
    let project = writeCrate()
    let (_, tr) = windowPlan(project,
      "constraints:show,constraints:wait," &
      "constraints:menu:0,ctx:Copy Source Location," &
      "constraints:menu:3,ctx:Copy Name", edit = true)
    checkpoint(tr)
    ck tr.contains("context menu constraint-row " &
                   answers["placedMenu"].menuOf)
    ck tr.contains("copied the row: src/main.nr:3")
    ck tr.contains("context menu constraint-row " &
                   answers["nowhereMenu"].menuOf)
    ck tr.contains("copied the row: directive_integer_quotient")
    ck answers["nowhereMenu"][0]["disabled"].getBool
    ck answers["nowhereMenu"][0]["reason"].getStr == DirectiveReasonText
    removeDir(project)

  test "keys, with the pane focused":
    let project = writeCrate()
    let (_, tr) = windowPlan(project,
      "constraints:show,constraints:wait,constraints:key:list.focus-first," &
      "constraints:key:list.focus-next,constraints:key:list.activate",
      edit = true)
    checkpoint(tr)
    ck tr.contains("constraints: opened src/main.nr:" & $Plat62HalveLine)
    removeDir(project)

  test "its recording: `:constraints` in the recording's tab":
    let project = writeCrate()
    let trace = calc()
    let (plan, tr) = windowPlan(project,
      "tests:show,tests:open:test_main,tests:wait," &
      "constraints:show,constraints:wait,constraints:row:0", trace = trace)
    checkpoint(tr)
    # The recording of the crate's test opened in a new session tab …
    ck tr.contains("tests: opened the recording ")
    ck tr.contains("session shown")
    # … where the Constraints pane was opened, measured and drawn.
    ck tr.contains("constraints: measuring " & project)
    let rows = plan.nodesWith("data-ct-constraint-row")
    ck rows.len == 4
    if rows.len == 4:
      ck rows[0].attr("data-ct-constraint-where") == "src/main.nr:3"
      ck rows[3].attr("data-ct-constraint-name") == "directive_integer_quotient"
    # A press on `main` opens its line from the recording.
    ck tr.contains("constraints: opened src/main.nr:" & $Plat62MainLine)
    removeDir(project)

  test "the assertion count":
    check CHECKS == ExpectedAssertions
