## test_stop_path_parent_component_gpui_plan.nim — **a stop whose recorded
## path has a `..` component shows THAT file's source**, in the shipped
## `codetracer-gpui`'s window, read from its window plan
## (`--report-window-plan`) after a press on a call-trace row, delivered
## through the window's own pointer handler (`--window-ops=press:<x>:<y>`) at
## the row's place in the geometry the window wrote.
##
## The GPUI half of `tui/tests/real_terminal/
## test_stop_path_parent_component.nim`. `multi_root`'s runner puts
## `app/../shared` on `sys.path`, so the Python recorder reports the stops in
## `helpers.add` and `extra.scale` at `…/multi_root/app/../shared/helpers.py`
## and `…/app/../shared/pkg/extra.py`, while the recording's `files/` store
## holds both under their normalised paths. The window must show the stop's own
## file — its tab, its source, the execution line on it — from the recording
## (no "No verified source" banner), and every line of it (extra.py is one
## line longer than helpers.py; a window clamped to the previous file's length
## left its last line unloaded).
##
## No mocks: the shipped binary, the real `multi_root` recording made by the
## Python recorder, a real `replay-server`.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import gpui/chrome
import ../../tui/tests/fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 22

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  NoVerifiedSource = "No verified source"
  W = 1440
  H = 1400
  RowPx = 26           # `leaves.CallRowPx`

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")

proc multiRoot(): string =
  ## The `multi_root` recording, resolved (and recorded when the cache does
  ## not hold a current one) by the same provider the terminal suite uses —
  ## never the first `multi_root-*` directory found, which may be a stale
  ## recording of an older program or by an older recorder.
  let resolved = resolveFixture(FixtureSpec(
    name: "multi_root",
    program: "test-programs/multi_root/app/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  if resolved.outcome != foRecorded:
    checkpoint("multi_root unavailable: " & resolved.detail)
    return ""
  resolved.tracePath

proc windowPlan(ops, subject: string; geometry: var JsonNode): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("dotdot-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  let geomFile = state / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("dotdot-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  geometry = if fileExists(geomFile): parseFile(geomFile) else: newJNull()
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith("data-ct-execution-line"):
    return parseInt(n.attr("data-ct-execution-line"))
  -1

proc tabsName(plan: JsonNode; file: string): bool =
  for n in plan.nodesWith("data-ct-tabs"):
    if n.attr("data-ct-tabs").contains(file): return true
  false

proc callRowOf(plan: JsonNode; name, args: string): JsonNode =
  ## The call-trace row for `name` called with `args`, found by what the call
  ## is rather than by its number.
  for n in plan.nodesWith("data-call-index"):
    let t = n.textOf
    if t.contains(name & " #") and t.contains(args):
      return n
  nil

proc calltraceBody(geom: JsonNode): seq[int] =
  for n in geom["nodes"]:
    if n{"kind"}.getStr == "tabs" and "calltrace" in n["panes"].to(seq[string]):
      return n["body"].to(seq[int])
  @[]

proc pressOn(row: JsonNode; body: seq[int]): string =
  ## A press and release on `row`'s name (right of its toggle, at its depth's
  ## indent), as the pointer delivers it.
  let at = parseInt(row.attr("data-call-index"))
  let indent = row{"styles"}{"padding_left"}.getStr("0px")
  let x = body[0] + ChromePaddingPx + parseInt(indent[0 ..< indent.len - 2]) + 40
  let y = body[1] + ChromePaddingPx + at * RowPx + RowPx div 2
  "press:" & $x & ":" & $y & ",release:" & $x & ":" & $y

proc checkStopShows(plan: JsonNode; file, other: string; lines: seq[string];
                    line: int) =
  ck plan.tabsName(file)
  ck not plan.tabsName(other)
  let text = plan.textOf
  for l in lines:
    ck text.contains(l)
  ck not text.contains(NoVerifiedSource)
  ck plan.executionLine == line

suite "a stop path with a `..` component, in the GPUI window":

  let mr = multiRoot()
  var geom = newJNull()
  let start = if mr.len > 0: windowPlan("", mr, geom) else: newJNull()
  let body = if mr.len > 0: geom.calltraceBody else: @[]
  let addRow = if mr.len > 0: start.callRowOf("add", "left=2, right=3") else: nil
  let scaleRow =
    if mr.len > 0: start.callRowOf("scale", "value=5, factor=4") else: nil

  test "clicking `add` in the call trace shows helpers.py's source":
    ck mr.len > 0
    ck body.len == 4
    ck not addRow.isNil
    var g: JsonNode
    let plan = windowPlan(addRow.pressOn(body), mr, g)
    plan.checkStopShows("helpers.py", "extra.py",
                        @["def add(left, right):", "return left + right"], 4)

  test "add, then scale: extra.py, every line of it":
    ck not scaleRow.isNil
    var g: JsonNode
    let plan = windowPlan(addRow.pressOn(body) & "," & scaleRow.pressOn(body),
                          mr, g)
    plan.checkStopShows("extra.py", "helpers.py",
                        @["def scale(value, factor):",
                          "result = value * factor", "return result"], 4)

  test "a stop in a file the recording lacks says so, naming the path":
    # helpers.py taken out of the recording's `files/` store: no neighbour
    # (extra.py is still there) answers for it, and the editor names it.
    let copy = getTempDir() / ("dotdot-gpui-missing-" & $getCurrentProcessId())
    removeDir(copy)
    copyDir(mr, copy)
    var removed = 0
    for f in walkDirRec(copy / "files"):
      if f.extractFilename == "helpers.py":
        removeFile(f)
        inc removed
    ck removed == 1
    var g: JsonNode
    let plan = windowPlan(addRow.pressOn(body), copy, g)
    let text = plan.textOf
    ck text.contains("/multi_root/app/../shared/helpers.py in this recording.")
    ck not text.contains("def scale(value, factor):")
    ck not text.contains(NoVerifiedSource)
    # No line of it will arrive, so the editor draws no rows for it.
    ck plan.nodesWith("data-ct-row").len == 0
    removeDir(copy)

  test "the assertion count matches the declared constant":
    check CHECKS == ExpectedAssertions
