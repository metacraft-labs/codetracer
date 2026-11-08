## test_plat70f_gpui_plan.nim — the pointer's shape in the GPUI window
## (Pointer-Affordances.md §4; PA-2's GPUI half), read from the window's own
## render plan, and a click on a hop row.
##
## The shipped `codetracer-gpui` on the `calc` recording, with
## `--report-window-plan` and `--window-ops` dispatched through the window's own
## handlers. The plan carries each element's `cursor` from the shared function;
## while a tab is held, the window's override is the gesture's.
##
## No mocks: the real binary, a real recording of the `calc` program, a real
## `replay-server`.

import replay_prerequisite
import std/[json, os, osproc, sets, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import ../../tui/tests/fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 33
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc calcTrace(): string =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = calcTrace()

proc windowPlan(ops: string; extra: seq[string] = @[]):
    tuple[plan: JsonNode, trace: string] =
  let state = createTempDir("plat70f-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("plat70f-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops] & extra & @[trace]
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

proc cursor(n: JsonNode): string =
  n{"styles"}{"cursor"}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc allCursors(plan: JsonNode): HashSet[string] =
  proc walk(n: JsonNode; acc: var HashSet[string]) =
    if n.kind != JObject: return
    let c = n.cursor
    if c.len > 0: acc.incl c
    for k in n{"children"}.getElems: walk(k, acc)
  walk(plan, result)

proc tickOf(plan: JsonNode): string =
  let loc = plan.nodesWith("data-ct-footer-position")
  if loc.len != 1: return ""
  let t = loc[0].attr("data-ct-footer-position")
  let at = t.rfind('#')
  if at < 0 or at == t.high: return ""
  t[at + 1 .. ^1]

const
  AtExpressions = "click:event:3:left,wait:2000"
  FocusVariables = "key:w:alt,type:V,key:enter"
  ToExpressions = AtExpressions & "," & FocusVariables &
                  repeat(",key:down", 19)

suite "the pointer's shape in the GPUI window":
  test "the render plan carries each element's shape":
    let (plan, _) = windowPlan(AtExpressions)
    proc every(attribute, shape: string) =
      let nodes = plan.nodesWith(attribute)
      checkpoint(attribute & " (" & $nodes.len & " nodes)")
      ck nodes.len > 0
      for n in nodes:
        if n.cursor != shape:
          checkpoint(attribute & " is " & n.cursor & ", not " & shape)
          ck false
          return
    every("data-call-index", "pointer")
    every("data-ct-code-column", "text")
    every("data-ct-tab-pane", "pointer")
    every("data-ct-divider-vertical", "col-resize")
    every("data-ct-divider-horizontal", "row-resize")
    let (framed, _) = windowPlan(AtExpressions, @["--window-chrome=client"])
    for n in framed.nodesWith("data-ct-window-drag"):
      ck n.cursor == "grab"
    ck framed.nodesWith("data-ct-window-drag").len > 0
    # A control's own enablement decides between its two shapes.
    var pointing, refusing = 0
    for c in plan.nodesWith("data-ct-control"):
      if c.attr("data-ct-enabled") == "false":
        ck c.cursor == "not-allowed"
        inc refusing
      else:
        ck c.cursor == "pointer"
        inc pointing
    ck pointing > 0

  test "an element nobody can click has no shape of its own":
    let (plan, _) = windowPlan(AtExpressions)
    for n in plan.nodesWith("data-ct-footer-note"):
      ck n.cursor == ""

  test "every shape of the set is reachable, and nothing outside it":
    let (plan, _) = windowPlan(AtExpressions)
    let (held, _) = windowPlan(AtExpressions & ",hold:state:calltrace")
    var names = plan.allCursors
    for name in names:
      ck name in ["default", "pointer", "text", "col-resize", "row-resize",
                  "grab", "grabbing", "not-allowed"]
    ck "pointer" in names
    ck "text" in names
    ck held.attr("data-ct-window-cursor") == "grabbing"

  test "during a tab drag the window's override is the gesture's":
    let (rest, _) = windowPlan(AtExpressions)
    ck rest.attr("data-ct-window-cursor") == ""
    let (held, _) = windowPlan(AtExpressions & ",hold:state:calltrace")
    ck held.attr("data-ct-window-cursor") == "grabbing"
    let (cancelled, _) = windowPlan(AtExpressions &
                                    ",hold:state:calltrace,key:escape")
    ck cancelled.attr("data-ct-window-cursor") == ""

suite "a click on a hop row in the GPUI window":
  test "seeks to the hop's tick, with the cursor on it":
    let open = ToExpressions & ",key:o:control+shift"
    let (opened, g0) = windowPlan(open)
    checkpoint(g0)
    let hops = opened.nodesWith("data-ct-origin-hop")
    ck hops.len >= 1
    ck hops[0].cursor == "pointer"
    let tick = hops[0].attr("data-ct-origin-tick")
    let key = hops[0].attr("data-ct-origin-hop") & "#" &
              hops[0].attr("data-ct-origin-path")
    let (clicked, g1) = windowPlan(open & ",click:hop:" & key & ":left,wait:1500")
    checkpoint(g1)
    ck clicked.tickOf == tick
    var onHop = false
    for h in clicked.nodesWith("data-ct-origin-hop"):
      if h.attr("data-ct-origin-hop") == hops[0].attr("data-ct-origin-hop") and
         h.attr("data-state-selected") == "true":
        onHop = true
    ck onHop

suite "the count":
  test "assertion count":
    check CHECKS == ExpectedAssertions
