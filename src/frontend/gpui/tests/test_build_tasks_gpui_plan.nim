## test_build_tasks_gpui_plan.nim — **build tasks, the task picker, the
## `:build` commands, the Build Output pane's reveal and a build's diagnostics
## in the editor, in the GPUI window**, read from the window's own render plan
## and its gesture trace.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.6, §3.8, §3.9, §3.11,
## §3.12, §5.2.
##
## The shipped `codetracer-gpui` (`just build-gpui`) as the Edit window over
## the PLAT-56 C project carrying a `.codetracer/build.yaml`, with
## `--report-window-plan` and `--window-ops` events dispatched through the
## window's own handlers:
##
##   * `Ctrl+Shift+B` opens the omnibox on the task picker, the default task
##     first; `Enter` builds it with the real `gcc`; `:build: <task>`,
##     `:build`, `problemMatcher: none`, an unknown task named;
##   * Build Output pinned to the footer: a build reveals it, a failed one
##     reveals Problems in its place, a clean success puts it away two
##     seconds on (the window's clock, advanced by `wait:`), a press in it
##     keeps it;
##   * the editor after the failing build, `src/main.c` open: a squiggle per
##     diagnostic at its span in its severity's colour, the gutter's icon on
##     each line, the messages on the pointer's hover; a passing build clears
##     them.
##
## No mocks: the real binary, the real `gcc` on a real project.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../viewmodel/tests/unit/build_fixtures/plat56_c_build

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 30
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  CleanCommand = "gcc -fdiagnostics-color=always -c src/ok.c -o /dev/null"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc taskFile(): string =
  "tasks:\n" &
  "  fail:\n    command: \"" & Plat56FailCommand & "\"\n    default: true\n" &
  "  pass:\n    command: \"" & Plat56PassCommand & "\"\n" &
  "  quiet:\n    command: \"" & Plat56FailCommand & "\"\n" &
  "    problemMatcher: none\n" &
  "  clean:\n    command: \"" & CleanCommand & "\"\n"

proc newProject(): string =
  result = writePlat56Project("ct-build-tasks-gpui-")
  createDir(result / ".codetracer")
  writeFile(result / ".codetracer" / "build.yaml", taskFile())

proc windowPlan(project, ops: string): tuple[plan: JsonNode, trace: string] =
  ## The Edit window over `project` after `ops`: its root, and its gesture
  ## trace — the binary run in `project`, its own scratch homes.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("build-tasks-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("build-tasks-gpui-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, "--edit", project]
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
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc paneOf(plan: JsonNode): JsonNode =
  let hits = plan.nodesWith("data-ct-build")
  if hits.len > 0: hits[0] else: newJObject()

proc omnibox(line: string): string =
  ## The omnibox opened, `line` typed, `Enter`.
  "key:p:control,type:" & line & ",key:enter"

suite "build tasks in the GPUI window":

  test "Ctrl+Shift+B: the picker, the default first; Enter builds it":
    let project = newProject()
    let (plan, tr) = windowPlan(project, "key:b:control+shift")
    checkpoint(tr)
    ck tr.contains("build tasks: Enter runs fail")
    let shown = textOf(plan)
    ck shown.contains(Plat56FailCommand)
    ck shown.find("fail") < shown.find("history")
    let (plan2, tr2) = windowPlan(project,
      "key:b:control+shift,key:enter,problems:wait,build:show")
    checkpoint(tr2)
    ck tr2.contains("running task fail: " & Plat56FailCommand)
    ck plan2.paneOf().attr("data-ct-build") == "build failed (exit code 1)"
    removeDir(project)

  test "the omnibox commands: a task, the default, none, unknown":
    let project = newProject()
    var (plan, tr) = windowPlan(project, omnibox(":build: pass") &
                                ",problems:wait,build:show")
    checkpoint(tr)
    ck plan.paneOf().attr("data-ct-build") == "build succeeded"
    (plan, tr) = windowPlan(project, omnibox(":build") &
                            ",problems:wait,build:show")
    ck plan.paneOf().attr("data-ct-build") == "build failed (exit code 1)"
    let footer = plan.nodesWith("data-ct-footer-build")
    ck footer.len == 1 and footer[0].attr("data-ct-footer-build") ==
      "✗ Build failed: 2 errors, 1 warning"
    (plan, tr) = windowPlan(project, omnibox(":build: quiet") &
                            ",problems:wait,build:show")
    let quiet = plan.nodesWith("data-ct-footer-build")
    ck quiet.len == 1 and quiet[0].attr("data-ct-footer-build") ==
      "✗ Build failed (exit code 1)"
    (plan, tr) = windowPlan(project, omnibox(":build: deploy"))
    ck tr.contains("no build task 'deploy' (fail, pass, quiet, clean)")
    removeDir(project)

  test "the reveal: Build Output pinned to the footer":
    let project = newProject()
    let pin = "dock:buildOutput"
    var (_, tr) = windowPlan(project, pin & "," & omnibox(":build: fail") &
                             ",problems:wait")
    checkpoint(tr)
    ck tr.contains("build pane revealed")
    ck tr.contains("problems pane revealed")
    # A clean success: revealed, put away two seconds on — not before.
    (_, tr) = windowPlan(project, pin & "," & omnibox(":build: clean") &
                         ",problems:wait,wait:1500")
    ck tr.contains("build pane revealed")
    ck not tr.contains("build pane dismissed")
    (_, tr) = windowPlan(project, pin & "," & omnibox(":build: clean") &
                         ",problems:wait,wait:2100")
    ck tr.contains("build pane dismissed")
    # A success with a warning stays.
    (_, tr) = windowPlan(project, pin & "," & omnibox(":build: pass") &
                         ",problems:wait,wait:2100")
    ck not tr.contains("build pane dismissed")
    # The wheel in the revealed pane keeps it.
    (_, tr) = windowPlan(project, pin & "," & omnibox(":build: clean") &
                         ",problems:wait,build:wheel:1,wait:2100")
    checkpoint(tr)
    ck not tr.contains("build pane dismissed")
    removeDir(project)

  test "the editor: squiggles, gutter icons, the hover; cleared by a new build":
    let project = newProject()
    let opened = omnibox(":build: fail") &
                 ",problems:wait,build:show,build:line:1"
    var (plan, tr) = windowPlan(project, opened)
    checkpoint(tr)
    ck tr.contains("build: opened src/main.c:5:17")
    var squiggles: seq[string]
    var icons: seq[string]
    for n in plan.nodesWith("data-ct-diagnostic"):
      let v = n.attr("data-ct-diagnostic")
      if ' ' in v: squiggles.add v
      else: icons.add v & " " & textOf(n)
    checkpoint(squiggles.join(" | ") & " || " & icons.join(" | "))
    ck "error 5:16-17" in squiggles
    ck "warning 4:9-15" in squiggles
    ck "error 10:12-26" in squiggles
    ck "info 10:12-26" in squiggles
    ck "warning@4 ⚠" in icons
    ck "error@5 ●" in icons
    ck "error@10 ●" in icons
    for n in plan.nodesWith("data-ct-diagnostic"):
      if n.attr("data-ct-diagnostic") == "warning 4:9-15":
        ck n{"styles"}{"bg"}.getStr.len > 0
    # THE HOVER over `undefined_name` (line 10, column 14), the clock run.
    (plan, tr) = windowPlan(project, opened & ",hover-code:10:14,wait:600")
    checkpoint(tr)
    let tips = plan.nodesWith("data-ct-cell-tooltip")
    ck tips.len == 1
    if tips.len == 1:
      ck textOf(tips[0]).contains("‘undefined_name’ undeclared")
      ck textOf(tips[0]).contains("note: each undeclared identifier")
    # A NEW BUILD CLEARS THEM.
    (plan, tr) = windowPlan(project, opened & "," & omnibox(":build: pass") &
                            ",problems:wait")
    ck plan.nodesWith("data-ct-diagnostic").len == 0
    removeDir(project)

  test "the assertion count":
    check CHECKS == ExpectedAssertions
