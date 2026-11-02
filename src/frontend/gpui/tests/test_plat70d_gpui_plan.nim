## test_plat70d_gpui_plan.nim — PLAT-70 Part D (Find-And-Incremental-Search.md
## §5): **`:grep` and `Ctrl+Shift+F` in the GPUI window**, read from the
## window's own render plan.
##
## The shipped `codetracer-gui` on the `multi_root` recording, with
## `--report-window-plan` and `--window-ops` dispatched through the window's
## own key and pointer handlers. Asserted:
##
##   * `:grep FACTOR` typed into the omnibox lists exactly the rows an oracle
##     in this suite finds (a plain scan of the recording's `files/` store) —
##     the same oracle the terminal's and the desktop's cases grade against
##     (FS-7) — and the tick does not move;
##   * `F4` opens the first result with its match selected in the editor;
##     then `Ctrl+Shift+F` opens Find in Files' field — the omnibox's `:grep`
##     line — SEEDED with that selection (`factor`, not the query
##     `FACTOR`), the seed selected
##     (`data-ct-omnibar-selection`), and typing replaces it (§5.2);
##   * `:grep` alone is `Ctrl+Shift+F`: with nothing selected the field opens
##     on the pane's query, selected.
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
  ExpectedAssertions = 12
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000

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
  let state = createTempDir("plat70d-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("plat70d-gpui-plan-", ".err")
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


proc rowsOf(plan: JsonNode): seq[(string, int)] =
  var file = ""
  proc walk(n: JsonNode; acc: var seq[(string, int)]) =
    if n.kind != JObject: return
    if n.has("data-ct-search-file"):
      file = n.attr("data-ct-search-file")
    elif n.has("data-ct-search-row"):
      acc.add (file, parseInt(n.attr("data-ct-search-line")))
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc omnibarSelection(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-omnibar-selection"):
    result.add n.attr("data-ct-omnibar-selection")

proc omnibarText(plan: JsonNode): string =
  for n in plan.nodesWith("data-ct-omnibar-placeholder"):
    result.add textOf(n)

const GrepFactor = "key:p:control,type::grep FACTOR,key:enter,wait:10000"
  ## Upper case, so the pane's query (`FACTOR`) and the match the editor
  ## selects (`factor`, as the source spells it) are different seeds.

suite "PLAT-70 Part D: :grep and Ctrl+Shift+F in the GPUI window":

  test "`:grep FACTOR`: the oracle's rows (any case); the tick stays":
    let expected = oracle("factor")
    ck expected.len >= 2
    let before = windowPlan("wait:100").plan
    let (plan, _) = windowPlan(GrepFactor)
    checkpoint("pane: " & $rowsOf(plan) & "  oracle: " & $expected)
    ck rowsOf(plan) == expected
    ck tickOf(plan).len > 0 and tickOf(plan) == tickOf(before)

  test "F4 selects the match; Ctrl+Shift+F opens the field on it, selected; typing replaces it":
    let expected = oracle("factor")
    let (plan, gestures) = windowPlan(GrepFactor & ",key:f4,key:f:control+shift")
    ck gestures.contains("opened " & expected[0][0] & ":" & $expected[0][1])
    ck gestures.contains("find in files field 'factor'")
    ck omnibarSelection(plan) == @["factor"]
    ck omnibarText(plan).contains(":grep ")
    let (typed, _) = windowPlan(GrepFactor &
      ",key:f4,key:f:control+shift,type:scale")
    ck omnibarSelection(typed).len == 0
    ck omnibarText(typed).contains(":grep scale")
    ck not omnibarText(typed).contains("factor")

  test "`:grep` alone with nothing selected: the field on the pane's query, selected":
    let (plan, gestures) = windowPlan(GrepFactor &
      ",key:p:control,type::grep,key:enter")
    ck gestures.contains("find in files field 'FACTOR'")
    ck omnibarSelection(plan) == @["FACTOR"]

  test "assertion count":
    check CHECKS == ExpectedAssertions
