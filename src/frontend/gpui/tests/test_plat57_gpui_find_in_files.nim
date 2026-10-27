## test_plat57_gpui_find_in_files.nim — PLAT-57: **Find in Files in the GPUI
## window**, read from the window's own render plan.
##
## The shipped `codetracer-gpui` (`just build-gpui`) on the `multi_root`
## recording, with `--report-window-plan`: the window's root builder, the
## `--window-ops` events dispatched through the window's own key and pointer
## handlers (the omnibox typed into key by key, the Edit menu pressed, the
## pane's rows and toggles pressed where the window drew them), then the
## window as a plan. Asserted:
##
##   * `:grep scale` typed into the omnibox shows the FIND IN FILES pane, and
##     its rows are the recording's sources searched by an oracle in this
##     suite (a plain scan of the recording's `files/` store, independent of
##     the runner): the summary's counts, the file groups and every row's line
##     in order, each with the runner's match as its highlighted run;
##   * the Edit menu's Find in Files, then the query typed, searches the same;
##   * a press on a result opens its file in the editor at its line, and the
##     recording position (the top bar's tick) does not move (K35); `F4` /
##     `Shift+F4` walk the results;
##   * the Match Case toggle runs the search again case-sensitively;
##   * in the pane's field (the omnibox on `:grep`) `Alt+R` turns on Use
##     Regular Expression and `Alt+C` flips Match Case, and a regular
##     expression lists exactly the lines the oracle's own reading of it
##     finds.
##
## No mocks: the real binary, a real recording made by the Python recorder, a
## real `replay-server`, the real shared runner.

import replay_prerequisite
import std/[algorithm, json, os, osproc, sequtils, streams, strtabs, strutils,
            tempfiles, unittest]
import ./gpui_child_env

import ../../tui/tests/fixtures/fixture_provider
from viewmodels/product_mode import editorTabLabel
  # the editor tab's title for a file (its folder and name, as the desktop's)

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 26
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  Pattern = "scale"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc multiRoot(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "multi_root",
    program: "test-programs/multi_root/app/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = multiRoot()

proc windowPlan(ops: string): tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat57-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("plat57-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, trace]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
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

proc tickOf(plan: JsonNode): string =
  ## The footer's location's ticks — the desktop's `.location-path`,
  ## `<path>:<line>#<ticks>` (`data-ct-footer-position`); "" when the footer
  ## shows no location or it carries no ticks.
  let loc = plan.nodesWith("data-ct-footer-position")
  if loc.len != 1: return ""
  let t = loc[0].attr("data-ct-footer-position")
  let at = t.rfind('#')
  if at < 0 or at == t.high: return ""
  for c in t[at + 1 .. ^1]:
    if c notin {'0' .. '9'}: return ""
  t[at + 1 .. ^1]

proc oracle(pattern: string): seq[(string, int)] =
  ## Every line of every file in the recording's `files/` store containing
  ## `pattern`, any case, the store's prefix removed — read here, not by the
  ## runner.
  let store = trace / "files"
  var files: seq[string] = @[]
  for path in walkDirRec(store):
    files.add path
  files.sort()
  for path in files:
    if path.extractFilename.startsWith("."): continue
    let text = readFile(path)
    if '\0' in text: continue
    var n = 0
    for line in text.splitLines():
      inc n
      if line.toLowerAscii.contains(pattern.toLowerAscii):
        result.add (path[store.len .. ^1], n)

proc wordEndOracle(name: string): seq[(string, int)] =
  ## The oracle's reading of the regular expression `sc[a]le\b`: the lines
  ## holding `name`, any case, with no word character after it.
  for (path, line) in oracle(name):
    let text = readFile(trace / "files" / path).splitLines()[line - 1]
    let t = text.toLowerAscii
    var at = t.find(name)
    while at >= 0:
      if at + name.len >= t.len or t[at + name.len] notin IdentChars:
        result.add (path, line)
        break
      at = t.find(name, at + 1)

const Grep = "key:p:control,type::grep " & Pattern & ",key:enter,wait:10000"

suite "PLAT-57: Find in Files in the GPUI window":

  test "`:grep` in the omnibox: the pane lists the oracle's rows, grouped, highlighted":
    let expected = oracle(Pattern)
    var files: seq[string] = @[]
    for (f, _) in expected:
      if f notin files: files.add f
    ck expected.len >= 4 and files.len >= 2
    let (plan, gestures) = windowPlan(Grep)
    ck gestures.contains("find in files '" & Pattern & "'")
    let pane = plan.nodesWith("data-ct-search")
    ck pane.len == 1 and pane[0].attr("data-ct-search") == Pattern
    let summary = plan.nodesWith("data-ct-search-summary")
    ck summary.len == 1 and textOf(summary[0]) ==
      $expected.len & " results in " & $files.len & " files"
    var groups: seq[string] = @[]
    for n in plan.nodesWith("data-ct-search-file"):
      groups.add n.attr("data-ct-search-file")
    ck groups == files
    var rows: seq[(string, int)] = @[]
    var hits = 0
    var file = ""
    # In plan (paint) order: a header names the group of the rows after it.
    proc walk(n: JsonNode) =
      if n.kind != JObject: return
      if n.has("data-ct-search-file"):
        file = n.attr("data-ct-search-file")
      elif n.has("data-ct-search-row"):
        rows.add (file, parseInt(n.attr("data-ct-search-line")))
        for h in n.nodesWith("data-ct-search-hit"):
          if textOf(h).toLowerAscii == Pattern: inc hits
      for c in n{"children"}.getElems: walk(c)
    walk(plan)
    checkpoint("pane: " & $rows & "  oracle: " & $expected)
    ck rows == expected
    ck hits == expected.len

  test "the Edit menu's Find in Files, then the query: the same rows":
    let (plan, gestures) = windowPlan(
      "menu:Edit,key:enter,type:" & Pattern & ",key:enter,wait:10000")
    ck gestures.contains("menu action findInFiles")
    ck plan.nodesWith("data-ct-search-row").len == oracle(Pattern).len

  test "a press on a result opens its file at its line; the tick stays":
    let expected = oracle(Pattern)
    let before = windowPlan(Grep).plan
    let last = expected.len - 1
    let (plan, gestures) = windowPlan(Grep & ",search:row:" & $last)
    ck gestures.contains("opened " & expected[last][0] & ":" &
                         $expected[last][1])
    ck tickOf(plan).len > 0 and tickOf(plan) == tickOf(before)
    var shown = false
    for n in plan.nodesWith("data-ct-row"):
      if n.attr("data-ct-row") == $expected[last][1] and
         textOf(n).contains("def scale(value, factor):"):
        shown = true
    ck shown
    var active: seq[string] = @[]
    for n in plan.nodesWith("data-ct-tab-active"):
      active.add textOf(n)
    ck editorTabLabel(expected[last][0], false) in active
    let selected = plan.nodesWith("data-ct-selected")
    ck selected.len == 1 and selected[0].attr("data-ct-search-row") == $last

  test "F4 opens the first result, again the next; Shift+F4 the previous":
    let expected = oracle(Pattern)
    let (_, gestures) = windowPlan(Grep & ",key:f4,key:f4,key:f4:shift")
    let opened = gestures.splitLines().filterIt(it.contains("gesture opened ") and
                                                it.contains(":"))
    checkpoint($opened)
    ck opened.len == 3
    ck opened[0].endsWith(expected[0][0] & ":" & $expected[0][1])
    ck opened[1].endsWith(expected[1][0] & ":" & $expected[1][1])
    ck opened[2].endsWith(expected[0][0] & ":" & $expected[0][1])

  test "Match Case runs the search again, case-sensitively":
    let (plan, gestures) = windowPlan(
      "key:p:control,type::grep Scale,key:enter,wait:10000," &
      "search:option:case,wait:10000")
    ck gestures.contains("search option case true")
    ck plan.nodesWith("data-ct-search-row").len == 0
    let summary = plan.nodesWith("data-ct-search-summary")
    ck summary.len == 1 and textOf(summary[0]) == "No results for \"Scale\""

  test "the field's keys: Alt+R makes the query a regular expression, Alt+C flips the case":
    let expected = wordEndOracle(Pattern)
    checkpoint("oracle: " & $expected)
    ck expected.len >= 2 and expected.len < oracle(Pattern).len
    let (plan, gestures) = windowPlan(
      "key:p:control,type::grep sc[a]le\\b,key:r:alt,key:c:alt,key:c:alt," &
      "key:enter,wait:10000")
    ck gestures.contains("search option regex true")
    ck gestures.contains("search option case true") and
       gestures.contains("search option case false")
    var rows: seq[(string, int)] = @[]
    var file = ""
    proc walk(n: JsonNode) =
      if n.kind != JObject: return
      if n.has("data-ct-search-file"):
        file = n.attr("data-ct-search-file")
      elif n.has("data-ct-search-row"):
        rows.add (file, parseInt(n.attr("data-ct-search-line")))
      for c in n{"children"}.getElems: walk(c)
    walk(plan)
    ck rows == expected
    var states: seq[string] = @[]
    for n in plan.nodesWith("data-ct-search-option"):
      states.add n.attr("data-ct-search-option") & "=" & n.attr("data-ct-active")
    ck states == @["case=false", "word=false", "regex=true"]

  test "assertion count":
    check CHECKS == ExpectedAssertions
