## test_plat65_gpui_nim_tracing.nim — Nim's compile-time tracing in the GPUI
## window: each of the four actions, by its chord and by the editor's menu,
## opens a NEW SESSION TAB on a recording whose first stop is inside the
## traced construct.
##
## Spec: codetracer-pm `spec/Planned-Features/Nim-Compile-Time-Tracing-
## Milestones.md` (M6, M9–M11); `spec/GUI/Multi-Window-Tab-Management.md`
## "Which tab a replay opens in".
##
## The shipped `codetracer-gpui` (`just build-gpui`) over a real recording of
## the project (`tui/tests/fixtures/plat65_nim_project`: `nim e --trace
## build.nims`), in the project folder, with `--report-window-plan`:
## `--window-ops` events dispatched through the window's own handlers — a
## press on the editor's text places the caret (`click:code`), `key:` events
## are the chord (`Ctrl+K T <letter>`), a right press opens the editor's menu
## and `ctx:` presses its entry, `wait:` lets the trace settle — then the
## window as a plan and its gesture trace:
##
##   * EVAL in `build.nims`: a second session tab, stopped in the script;
##   * STATIC BLOCK in `tracing.nim` (opened from the Files pane): a new tab,
##     stopped inside the block;
##   * CONSTANT from the menu on the `cubes` entry of that recording: a third
##     tab, stopped in the initializer or the `compute` it calls;
##   * MACRO by its chord on `twice:` there: a third tab, stopped in the
##     macro's body;
##   * on an ordinary `proc` line the menu offers neither the static nor the
##     constant entry, and the chord is refused and says why; with no
##     nimsuggest the action starts nothing and says why.
##
## No mocks: the compiler, nimsuggest, replay-server and the window are the
## real ones. Prerequisites missing → `MISSING-PREREQ SKIP:` naming them.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../tui/tests/fixtures/plat65_nim_project
import ./gpui_child_env

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 22

var countedAssertions = 0
var skipped = false

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1600
  H = 1000
  Wait = "wait:120000"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc chord(letter: string): string =
  "key:k:control,key:t,key:" & letter

proc windowPlan(p: NimProject; ops: string; trace: var string;
                nimsuggest = ""): JsonNode =
  ## The replay window over the project's starting recording after `ops`:
  ## its root, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat65-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_DATA_HOME"] = state / "data"
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  if nimsuggest.len > 0:
    env["CODETRACER_NIMSUGGEST"] = nimsuggest
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat65-gpui-", ".err")
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add p.recording
  let proc0 = startProcess("/bin/sh",
    args = @["-c", "exec timeout 600 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args,
    workingDir = p.root, env = env, options = {})
  let output = proc0.outputStream.readAll()
  let rc = proc0.waitForExit()
  proc0.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc sessionTabs(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-session-tab"):
    result.add n.attr("data-ct-session-tab")

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith("data-ct-execution-line"):
    return parseInt(n.attr("data-ct-execution-line"))
  -1

proc menuLabels(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-context-entry"):
    result.add n.attr("data-ct-context-entry")

proc fileRowId(plan: JsonNode; name: string): string =
  ## The id of the Files row named `name` ("" when there is none).
  proc walk(n: JsonNode; found: var string) =
    if n.kind != JObject or found.len > 0: return
    if n.attr("data-view-kind") == "Tree" and
       n.attr("data-view-id").startsWith("fileTree") and
       n.textOf.strip.endsWith(name):
      found = n.attr("data-view-id")
      return
    for c in n{"children"}.getElems: walk(c, found)
  walk(plan, result)

proc count(text, needle: string): int =
  var at = text.find(needle)
  while at >= 0:
    inc result
    at = text.find(needle, at + needle.len)

proc startsWithAny(tabs: seq[string]; stem: string): int =
  for t in tabs:
    if t.startsWith(stem): inc result

var project: NimProject
var tracingRow = ""

proc ensureProject() =
  ## The project and its `tracing.nim` Files row, made by whichever case
  ## runs first (a filtered run starts anywhere).
  if project.root.len > 0:
    return
  project = writeNimProject("gpui")
  var trace = ""
  tracingRow = windowPlan(project, "", trace).fileRowId("tracing.nim")

suite "PLAT-65: Nim's compile-time tracing in the GPUI window":

  test "eval: Ctrl+K T E in build.nims opens a new session tab in the script":
    let missing = missingPrereq()
    if missing.len > 0:
      echo "  MISSING-PREREQ SKIP: ", missing
      skipped = true
      skip()
    else:
      ensureProject()
      var trace = ""
      checkpoint("tracing.nim row: " & tracingRow)
      ck tracingRow.len > 0
      let plan = windowPlan(project,
        "click:code:4@1," & chord("e") & "," & Wait, trace)
      checkpoint(trace)
      ck trace.count("— opened in a new session tab") == 1
      let tabs = plan.sessionTabs
      checkpoint("tabs: " & $tabs)
      ck tabs.len == 2
      ck tabs.startsWithAny("build-eval") == 1
      ck plan.executionLine in BuildLines

  test "static block: a press in the block, Ctrl+K T S":
    if skipped:
      skip()
    else:
      ensureProject()
      var trace = ""
      let plan = windowPlan(project,
        "click:file:" & tracingRow & ":left,click:code:20@3," & chord("s") &
        "," & Wait, trace)
      checkpoint(trace)
      let tabs = plan.sessionTabs
      checkpoint("tabs: " & $tabs)
      ck tabs.len == 2
      ck tabs.startsWithAny("tracing-static-block") == 1
      ck plan.executionLine in StaticLines

  test "constant from the editor's menu, macro by its chord, each a new tab":
    if skipped:
      skip()
    else:
      ensureProject()
      let toStatic = "click:file:" & tracingRow & ":left,click:code:20@3," &
                     chord("s") & "," & Wait
      var trace = ""
      let menu = windowPlan(project, toStatic & ",click:code:15@3:right",
                            trace)
      let labels = menu.menuLabels
      checkpoint("menu: " & $labels)
      ck "Trace Constant Initializer" in labels
      ck "Trace Static Block Execution" notin labels
      let constant = windowPlan(project, toStatic &
        ",click:code:15@3:right,ctx:Trace Constant Initializer," & Wait, trace)
      checkpoint(trace)
      let tabs = constant.sessionTabs
      checkpoint("tabs: " & $tabs)
      ck tabs.len == 3
      ck tabs.startsWithAny("tracing-constant") == 1
      let stop = constant.executionLine
      checkpoint("constant stop: " & $stop)
      ck stop == CubesLine or stop in ComputeLines
      let macroPlan = windowPlan(project, toStatic &
        ",click:code:26@1," & chord("m") & "," & Wait, trace)
      checkpoint(trace)
      let mtabs = macroPlan.sessionTabs
      checkpoint("tabs: " & $mtabs)
      ck mtabs.len == 3
      ck mtabs.startsWithAny("tracing-macro") == 1
      ck macroPlan.executionLine in MacroLines

  test "a proc line offers neither; no nimsuggest starts nothing; each says why":
    if skipped:
      skip()
    else:
      ensureProject()
      var trace = ""
      let open = "click:file:" & tracingRow & ":left"
      let menu = windowPlan(project, open & ",click:code:6@1:right", trace)
      let labels = menu.menuLabels
      checkpoint("menu: " & $labels)
      ck "Trace Static Block Execution" notin labels
      ck "Trace Constant Initializer" notin labels
      let refused = windowPlan(project, open & ",click:code:6@1," &
                               chord("s") & "," & Wait, trace)
      ck trace.contains("is neither")
      # One session: the window draws no strip — no tab was added.
      ck refused.sessionTabs.len == 0
      let absent = windowPlan(project, open & ",click:code:18@3," &
                              chord("s") & "," & Wait, trace,
                              nimsuggest = project.root / "no-nimsuggest")
      ck trace.contains("nimsuggest is not available")
      ck absent.sessionTabs.len == 0

suite "PLAT-65 GPUI suite cleanup":
  test "the project is removed":
    if project.root.len > 0:
      project.removeProject()

suite "PLAT-65 GPUI suite self-check":
  test "the assertion count is the one declared":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
