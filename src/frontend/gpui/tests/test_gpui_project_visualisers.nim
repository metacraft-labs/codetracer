## test_gpui_project_visualisers.nim — the GPUI window's Variables pane renders
## values through the open checkout's project-definition visualisers.
##
## The terminal session reads the checkout it opens (`.codetracer/`) and its
## Variables pane draws a value through a visualiser the project declared
## (`tui_session.wireDefinitions`). The GPUI window used to draw every value
## through the built-in presenters only. This suite starts the shipped
## `codetracer-gpui` the way a user does — IN a checkout, on a recording — and
## reads the Variables pane's value cells off the window's own plan
## (`--report-window-plan`):
##
##   * in a checkout whose `.codetracer/visualisers.toml` declares a summary
##     for the type the Python recorder names `List`, the row for
##     `EXPRESSIONS` (a list of five strings) draws that summary;
##   * the SAME binary on the SAME recording at the SAME stop, started in a
##     checkout with no `.codetracer/`, draws the built-in rendering — the
##     negative twin, so a pane that drew the summary for any reason fails.
##
## ## NO MOCKS
##
## None: the shipped binary, the real `isonim-gpui` shim, a real `replay-server`,
## and the `calc` fixture recorded by the real Python recorder. Each run has
## its own state, config and home directories, so the user's are never read or
## written.
##
## Run (needs `build/bin/codetracer-gpui` and the shim, like every suite that
## reads `--report-window-plan`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_gpui_project_visualisers.nim

import replay_prerequisite
import ../../tui/tests/fixtures/fixture_provider
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import gpui/app/leaves

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 6
  StopOps = "stepIn=21,stepOut=1"
    ## The stop `test_plat40_state_pane_columns.nim` reads as a frame entered
    ## and returned from: the module frame, where `EXPRESSIONS` is bound.
  Summary = "calc exprs"
    ## Short enough to fit the value cell at 1440 px: the pane cuts a longer
    ## one with `…`, and the cut text no longer contains the summary.
  Visualisers = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "List"
matchKind = "typeName"
summary = "calc exprs"
"""

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = requireFixture(fixtureSpec("calc"))

proc windowPlan(checkout: string): JsonNode =
  ## The window's root as the shipped binary reports it, started with its
  ## working directory in `checkout` — the project a replay window reads.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("gpui-project-vis-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["DYLD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("DYLD_LIBRARY_PATH"): ":" & getEnv("DYLD_LIBRARY_PATH")
     else: "")
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state / "state"
  env["XDG_CONFIG_HOME"] = state / "config"
  env["XDG_DATA_HOME"] = state / "data"
  env["CODETRACER_HOME"] = state / "ct-home"
  let args = @["--report-window-plan", "--width=1440", "--height=900",
               "--replay-ops=" & StopOps, calc]
  let errFile = genTempPath("gpui-project-vis-", ".err")
  let p = startProcess("/bin/sh", workingDir = checkout,
    args = @["-c", gpuiRunScript("2>" & quoteShell(errFile)), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui " & gpuiExitText(rc) & ": " & err)
    raise newException(IOError, "the window plan run failed")
  parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n.isNil: return ""
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc nodesWith(n: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.isNil or n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(n, result)

proc textOf(n: JsonNode): string =
  if n.isNil: return ""
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc valueOf(plan: JsonNode; variable: string): string =
  ## The value cell of the Variables pane's row for `variable`, or a marker
  ## naming what was missing.
  var pane: JsonNode = nil
  for n in plan.nodesWith(PaneRoleAttribute):
    if n.attr(PaneRoleAttribute) == "state": pane = n
  if pane.isNil: return "<no state pane>"
  for row in pane.nodesWith(StateRowAttribute):
    if row.attr("data-view-id") == variable:
      for cell in row.nodesWith(StateColumnAttribute):
        if cell.attr(StateColumnAttribute) == StateValueColumn:
          return cell.textOf
      return "<no value cell>"
  "<no row for " & variable & ">"

proc checkout(withDefinitions: bool): string =
  result = createTempDir("gpui-project-vis-checkout-", "")
  if withDefinitions:
    createDir(result / ".codetracer")
    writeFile(result / ".codetracer" / "visualisers.toml", Visualisers)

suite "the GPUI Variables pane reads the checkout's visualisers":

  test "a declared visualiser draws the row, and without one the built-in does":
    let declared = checkout(withDefinitions = true)
    let bare = checkout(withDefinitions = false)
    try:
      let withDefs = windowPlan(declared).valueOf("EXPRESSIONS")
      let without = windowPlan(bare).valueOf("EXPRESSIONS")
      checkpoint("with the checkout's definitions: " & withDefs)
      checkpoint("without: " & without)
      # THE POSITIVE CONTROL: the row exists and has a value in both runs.
      ck not without.startsWith("<")
      ck without.len > 0
      # The negative twin first: no definitions, the built-in rendering —
      # the list's own elements, and no summary.
      ck Summary notin without
      ck "2 + 3" in without
      # The checkout's visualiser draws the row.
      ck withDefs.contains(Summary)
      ck "2 + 3" notin withDefs
    finally:
      removeDir(declared)
      removeDir(bare)

suite "every case in this file ran":
  test "the assertion count is the one this file declares":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
