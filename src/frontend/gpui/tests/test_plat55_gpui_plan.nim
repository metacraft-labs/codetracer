## test_plat55_gpui_plan.nim — PLAT-55: **the Problems pane in the GPUI
## window**, read from the window's own render plan and measured against the
## desktop.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.3; `Planned-Features/
## Edit-Mode-Toolbar.md` §11 (EMT-D21, D22).
##
## The shipped `codetracer-gpui` (`just build-gpui`) as the Edit window over
## the PLAT-55 Noir crate, with `--report-window-plan`: `--window-ops` events
## dispatched through the window's own handlers (`problems:*`, aimed where the
## pane was drawn), then the window as a plan. `problems:build:nargo compile`
## is the window's `:build` — the real `nargo` run by the terminal's runner.
## The reference is the REAL Electron app's panel after the same build
## (`src/tests/visual/answers/plat55-problems.electron.json`,
## `just plat55-capture-electron`):
##
##   * THE ROWS: per row the severity, the icon and its colour, the path, the
##     location and the message — equal to the desktop's; the counts and the
##     buttons (label, active) equal to the desktop's;
##   * THE ERRORS FILTER and GROUP BY FILE, pressed where they were drawn:
##     the rows and the file headers the desktop showed;
##   * THE FIRST ERROR HIGHLIGHTED after the failed build, nothing opened
##     (EMT-D21), as the desktop's panel highlights it;
##   * A PRESS ON A ROW opens ITS file at ITS line in the Edit window's editor
##     (K35); `problems.next` steps to the next error, opening it and
##     announcing; the keys move the selection with the pane focused.
##
## No mocks: the real binary, the real `nargo` on a real crate, the real
## Electron app's answers.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../tui/tests/fixtures/plat55_noir_build

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 23
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  AnswersFile = "src/tests/visual/answers/plat55-problems.electron.json"
  Build = "problems:build:" & Plat55BuildCommand & ",problems:wait"

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
  let state = createTempDir("plat55-gpui-plan-", "")
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
  let errFile = genTempPath("plat55-gpui-plan-", ".err")
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

proc rowsOf(plan: JsonNode): seq[JsonNode] =
  plan.nodesWith("data-ct-problem-index")

proc compareRows(plan: JsonNode; want: JsonNode): int =
  ## How many fields of the plan's rows differ from the desktop's.
  let rows = plan.rowsOf()
  if rows.len != want["rows"].len:
    checkpoint("rows: " & $rows.len & " vs the desktop's " & $want["rows"].len)
    return 1000
  for i, w in want["rows"].getElems:
    let r = rows[i]
    var diffs: seq[string] = @[]
    if r.attr("data-ct-problem-severity") != w["severity"].getStr:
      diffs.add "severity"
    let icon = r.child("data-ct-problem-icon")
    if icon.attr("data-ct-problem-icon") != w["icon"].getStr: diffs.add "icon"
    if icon.colour != cssHex(w["iconColor"].getStr):
      diffs.add "icon colour " & icon.colour
    if r.child("data-ct-problem-path").attr("data-ct-problem-path") !=
       w["path"].getStr: diffs.add "path"
    if r.child("data-ct-problem-location").attr("data-ct-problem-location") !=
       w["location"].getStr: diffs.add "location"
    if r.child("data-ct-problem-message").attr("data-ct-problem-message") !=
       w["message"].getStr: diffs.add "message"
    if diffs.len > 0:
      checkpoint("row " & $i & ": " & diffs.join(", "))
      result += diffs.len

proc buttonsOf(plan: JsonNode): seq[(string, bool)] =
  for b in plan.nodesWith("data-ct-problems-button"):
    result.add (b.attr("data-ct-problems-button"),
                b.attr("data-ct-active") == "true")

proc desktopButtons(want: JsonNode): seq[(string, bool)] =
  for b in want["buttons"].getElems:
    result.add (b["label"].getStr, b["active"].getBool)

proc countsOf(plan: JsonNode): seq[string] =
  let pane = plan.nodesWith("data-ct-problems")[0]
  for attr in ["data-ct-problems-errors", "data-ct-problems-warnings",
               "data-ct-problems-total"]:
    let n = pane.child(attr)
    result.add n.attr(attr)

proc headersOf(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-problems-line"):
    if n.attr("data-ct-problems-line") == "file":
      result.add n.attr("data-ct-text")

proc selectedOf(plan: JsonNode): seq[string] =
  for r in plan.rowsOf():
    if r.attr("data-ct-selected") == "true":
      result.add r.attr("data-ct-problem-index")

suite "PLAT-55: the Problems pane in the GPUI window":

  test "a real failing build: the desktop's rows, counts and buttons":
    let project = writePlat55Project("ct-plat55-gpui-")
    let (plan, tr) = windowPlan(project, Build & ",problems:show")
    let after = answers["after"]
    ck tr.contains("build FAILED")
    ck plan.compareRows(after) == 0
    var counts: seq[string] = @[]
    for c in after["counts"].getElems: counts.add c.getStr
    ck plan.countsOf() == counts
    ck plan.buttonsOf() == desktopButtons(after)
    # EMT-D21: the first error highlighted, nothing opened — the row the
    # desktop's panel highlights for the same build.
    ck plan.selectedOf() == @["1"]
    ck answers["after"]["rows"][1]["selected"].getBool
    ck not tr.contains("problems: opened")
    removeDir(project)

  test "the Errors filter and Group by File, pressed where drawn":
    let project = writePlat55Project("ct-plat55-gpui-")
    let (errorsPlan, _) = windowPlan(project,
      Build & ",problems:show,problems:filter:errors")
    ck errorsPlan.compareRows(answers["errorsOnly"]) == 0
    ck errorsPlan.buttonsOf() == desktopButtons(answers["errorsOnly"])
    let (groupedPlan, _) = windowPlan(project,
      Build & ",problems:show,problems:group")
    var want: seq[string] = @[]
    for h in answers["grouped"]["fileHeaders"].getElems: want.add h.getStr
    ck groupedPlan.headersOf() == want
    ck groupedPlan.compareRows(answers["grouped"]) == 0
    ck groupedPlan.buttonsOf() == desktopButtons(answers["grouped"])
    removeDir(project)

  test "a press on a row opens its file at its line; next error; the keys":
    let project = writePlat55Project("ct-plat55-gpui-")
    let (plan, tr) = windowPlan(project,
      Build & ",problems:show,problems:row:0")
    checkpoint(tr)
    ck tr.contains("problems: opened src/util.nr:2:9")
    ck tr.contains("caret 2:9")
    ck plan.selectedOf() == @["0"]
    # The first `next error` lands on the error the failed build highlighted
    # (EMT-D21); the second steps on.
    let (nplan, ntr) = windowPlan(project,
      Build & ",problems:show,problems:next")
    ck ntr.contains("problems: error 1 of 2")
    ck ntr.contains("problems: opened src/util.nr:3:22")
    ck ntr.contains("caret 3:22")
    ck nplan.selectedOf() == @["1"]
    let (n2plan, n2tr) = windowPlan(project,
      Build & ",problems:show,problems:next,problems:next")
    ck n2tr.contains("problems: error 2 of 2")
    ck n2tr.contains("problems: opened src/main.nr:5:19")
    ck n2plan.selectedOf() == @["2"]
    let (kplan, _) = windowPlan(project,
      Build & ",problems:show,problems:key:list.focus-first," &
      "problems:key:list.focus-next")
    ck kplan.selectedOf() == @["1"]
    removeDir(project)

  test "the assertion count":
    check CHECKS == ExpectedAssertions
