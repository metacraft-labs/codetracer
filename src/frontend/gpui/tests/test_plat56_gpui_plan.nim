## test_plat56_gpui_plan.nim — PLAT-56: **the Build Output pane in the GPUI
## window**, read from the window's own render plan and measured against the
## desktop. Until PLAT-56 the window drew this pane as a report.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.13, §3.5, §3.7, §3.10.
##
## The shipped `codetracer-gpui` (`just build-gpui`) as the Edit window over
## the PLAT-56 C project, with `--report-window-plan`: `--window-ops` events
## dispatched through the window's own handlers (`build:*`, aimed where the
## pane was drawn), then the window as a plan. `problems:build:<command>` is
## the window's `:build` — the real coloured `gcc` run by the terminal's
## runner. The reference is the REAL Electron app's BUILD panel and status bar
## after the same builds (`src/tests/visual/answers/
## plat56-build-output.electron.json`, `just plat56-capture-electron`):
##
##   * THE LINES: per line its class and text, and per run its colour —
##     equal to the desktop's (the `error: ` run in the desktop's red);
##   * THE VERDICT: the header's words, in the verdict's colour; the footer's
##     build indicator, the desktop's words;
##   * A PRESS ON A LOCATED LINE opens ITS file at ITS line and column in the
##     Edit window's editor (K35), as the desktop's press opened it;
##   * THE HISTORY after a passing build: the picker's entries the
##     desktop's, the failing build shown again from it;
##   * the footer's indicator pressed reveals the pane.
##
## No mocks: the real binary, the real `gcc` on a real project, the real
## Electron app's answers.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../viewmodel/tests/unit/build_fixtures/plat56_c_build

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 21
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  AnswersFile = "src/tests/visual/answers/plat56-build-output.electron.json"
  Fail = "problems:build:" & Plat56FailCommand & ",problems:wait"
  Pass = "problems:build:" & Plat56PassCommand & ",problems:wait"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let answers = parseJson(readFile(repo / AnswersFile))

proc windowPlan(project, ops: string): tuple[plan: JsonNode, trace: string] =
  ## The Edit window over `project` after `ops`: its root, and its gesture
  ## trace — the binary run in `project`, its own scratch homes.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat56-gpui-plan-", "")
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
  let errFile = genTempPath("plat56-gpui-plan-", ".err")
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

proc cssHex(rgb: string): string =
  ## `rgb(r, g, b)` (a computed style) as `#rrggbb`.
  let parts = rgb.strip().replace("rgb(", "").replace(")", "").split(",")
  if parts.len < 3: return ""
  "#" & parts[0].strip.parseInt.toHex(2).toLowerAscii &
        parts[1].strip.parseInt.toHex(2).toLowerAscii &
        parts[2].strip.parseInt.toHex(2).toLowerAscii

proc linesOf(plan: JsonNode): seq[JsonNode] =
  plan.nodesWith("data-ct-build-line")

proc compareLines(plan: JsonNode; want: JsonNode): int =
  ## How many lines of the plan differ from the desktop's (class, text, each
  ## drawn run's colour).
  let lines = plan.linesOf()
  if lines.len != want["lines"].len:
    checkpoint("lines: " & $lines.len & " vs the desktop's " &
               $want["lines"].len)
    return 1000
  for i, w in want["lines"].getElems:
    let l = lines[i]
    var diffs: seq[string] = @[]
    if l.attr("data-ct-build-class") != w["class"].getStr:
      diffs.add "class " & l.attr("data-ct-build-class")
    if l.attr("data-ct-text") != w["text"].getStr: diffs.add "text"
    # The window draws the runs inside its view's columns (a line wider than
    # the pane continues past its right edge, reached by the horizontal
    # bar): the drawn runs are the desktop's first ones.
    let spans = l.nodesWith("data-ct-build-style")
    if spans.len > w["runs"].len or
       (spans.len == 0 and w["runs"].len > 0):
      diffs.add "runs " & $spans.len
    else:
      for k in 0 ..< spans.len:
        # EVERY run's colour, as the desktop's computed one: the compiler's
        # where it wrote one, else the line's class's.
        let want = cssHex(w["runs"][k]["color"].getStr)
        if spans[k].attr("data-ct-colour") != want:
          diffs.add "run " & $k & " colour " & spans[k].attr("data-ct-colour") &
                    " vs " & want
    if diffs.len > 0:
      checkpoint("line " & $i & ": " & diffs.join(", "))
      result += diffs.len

proc paneOf(plan: JsonNode): JsonNode =
  let hits = plan.nodesWith("data-ct-build")
  if hits.len > 0: hits[0] else: newJObject()

suite "PLAT-56: the Build Output pane in the GPUI window":

  test "a real failing build: the desktop's lines, verdict and indicator":
    let project = writePlat56Project("ct-plat56-gpui-")
    let (plan, tr) = windowPlan(project, Fail & ",build:show")
    checkpoint(tr)
    let failing = answers["failing"]
    let pane = plan.paneOf()
    ck pane.attr("data-ct-build") == failing["header"].getStr
    ck pane.attr("data-ct-build-status") == "bsFailed"
    ck plan.compareLines(failing) == 0
    let header = pane.child("data-ct-build-header")
    ck header.attr("data-ct-colour").len == 7
    # THE FOOTER'S INDICATOR, the desktop's words.
    let footer = plan.nodesWith("data-ct-footer-build")
    ck footer.len == 1
    if footer.len == 1:
      ck footer[0].attr("data-ct-footer-build") ==
        failing["statusIcon"].getStr & " " & failing["status"].getStr
    # NO MENU ON A LINE: the desktop's is measured empty.
    ck failing["lineContextMenu"].len == 0
    removeDir(project)

  test "a press on a located line opens its file at its line":
    let project = writePlat56Project("ct-plat56-gpui-")
    let (_, tr) = windowPlan(project, Fail & ",build:show,build:line:1")
    checkpoint(tr)
    ck tr.contains("build: opened src/main.c:5:17")
    ck tr.contains("caret 5:17")
    ck answers["failing"]["press"]["opened"]["path"].getStr == "src/main.c"
    ck answers["failing"]["press"]["opened"]["line"].getInt == 5
    let (_, tr2) = windowPlan(project, Fail & ",build:show,build:line:0")
    ck not tr2.contains("build: opened")
    removeDir(project)

  test "a passing build after it; the history; the indicator reveals":
    let project = writePlat56Project("ct-plat56-gpui-")
    let (plan, tr) = windowPlan(project, Fail & "," & Pass & ",build:show")
    checkpoint(tr)
    let passing = answers["passing"]
    let pane = plan.paneOf()
    ck pane.attr("data-ct-build") == passing["header"].getStr
    ck plan.compareLines(passing) == 0
    ck pane.attr("data-ct-build-history") == "1"
    let (hplan, _) = windowPlan(project, Fail & "," & Pass &
      ",build:show,build:control:history")
    var labels: seq[string] = @[]
    for n in hplan.nodesWith("data-ct-build-history-item"):
      labels.add textOf(n)
    let want = answers["history"]["labels"]
    ck labels.len == want.len
    if labels.len == 2:
      ck labels[0] == want[0].getStr
      ck labels[1].startsWith("#1 " & Plat56FailCommand & " — failed (exit code 1), ")
    let (splan, _) = windowPlan(project, Fail & "," & Pass &
      ",build:show,build:control:history,build:history:1")
    ck splan.paneOf().attr("data-ct-build") ==
      answers["history"]["shown"]["header"].getStr
    ck splan.paneOf().attr("data-ct-build-shown") == "0"
    # The footer's indicator, pressed, reveals the pane.
    let (_, rtr) = windowPlan(project, Pass & ",build:status")
    ck rtr.contains("build pane revealed")
    removeDir(project)

  test "the assertion count":
    check CHECKS == ExpectedAssertions
