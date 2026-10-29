## test_plat60_gpui_low_level_code.nim — PLAT-60: **the Low Level Code pane in
## the GPUI window**, read off the SHIPPED binary's window plan
## (`codetracer-gpui --report-window-plan --window-ops=…`: the window's own
## root builder and its own pointer and key handlers) over the real
## `noir_space_ship` recording (the Noir producer's) and a real
## `replay-server`:
##
##   * the pane is in no layout until `view.low-level-code` (Alt+1, the
##     desktop's `aLowLevel1`) opens it BESIDE THE SOURCE: on the editor's
##     rows, to its right;
##   * the listing is the ENGINE's: its instructions' offsets and source lines
##     are the answer `ct/load-asm-function` gives for the stop's function,
##     asked here over a session of this suite's own on the same recording —
##     and they are the terminal's listing (the same ViewModel);
##   * the execution pointer (`▸`, `data-ct-executing`) is on the
##     instruction of the line the editor's execution pointer is on;
##   * SOURCE → INSTRUCTIONS: the editor's caret on a line marks the
##     instructions generated from it (`data-ct-linked`); INSTRUCTION →
##     SOURCE: the listing's cursor (a list key) puts the editor's
##     cross-reference (`data-ct-cross-ref`) on its source line;
##   * a right press opens the shared menu; a press on an instruction moves
##     the debugger to its line (the editor's execution line follows);
##   * the header says a step goes by line, and `sync on` turns syncing off.
##
## No mocks: the binary, the engine and the recording are the product's.

import replay_prerequisite
import ../../../common/replay_server_path
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import headless_session
import isonim/core/signals
import gpui/app/leaves
import gpui/low_level_code_leaf
import codetracer_embed

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 39

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc fixture(prefix: string): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

proc windowPlan(ops: string; subject: string; trace: var string): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if subject.len == 0:
    raise newException(IOError, "prerequisite missing: a tui-fixtures " &
      "recording (the tui lane records them on its first run)")
  let state = createTempDir("plat60-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat60-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc windowPlan(ops: string; subject: string): JsonNode =
  var t: string
  windowPlan(ops, subject, t)

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

proc instructions(plan: JsonNode): seq[JsonNode] =
  plan.nodesWith(LowLevelRowAttribute)

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith(EditorExecutionAttribute):
    return parseInt(n.attr(EditorExecutionAttribute))
  -1

const AnswersFile = "src/tests/visual/answers/plat60-low-level-code.electron.json"
  ## The desktop's Low Level Code view on this recording, captured from the
  ## real Electron app (`just plat60-capture-electron`).

proc listingRows(plan: JsonNode): seq[string] =
  ## The pane's rows in the capture's spelling, in drawing order.
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.kind != JObject: return
    if n.has(LowLevelLineAttribute):
      acc.add "source " & n.attr(LowLevelLineAttribute) & " active=" &
              $(n.attr("data-ct-active") == "true")
    elif n.has(LowLevelRowAttribute):
      acc.add "instruction " & n.attr("data-ct-offset") & " " &
              n.attr("data-ct-instruction") & " " & n.attr("data-ct-source") &
              " active=" & $(n.attr("data-ct-active") == "true") &
              " executing=" & $(n.attr("data-ct-executing") == "true")
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc desktopRows(listing: JsonNode): seq[string] =
  for r in listing.getElems:
    if r["kind"].getStr == "source":
      result.add "source " & $r["line"].getInt & " active=" & $r["active"].getBool
    else:
      result.add "instruction " & r["offset"].getStr & " " & r["name"].getStr &
                 " " & r["source"].getStr & " active=" & $r["active"].getBool &
                 " executing=" & $r["executing"].getBool

let desk = parseJson(readFile(repo / AnswersFile))

proc lineOf(row: JsonNode): int =
  parseInt(row.attr("data-ct-source").rsplit(':')[^1])

suite "PLAT-60: the Low Level Code pane in the GPUI window":

  let subject = fixture("noir_space_ship")

  test "view.low-level-code opens it beside the source with the engine's listing":
    let before = windowPlan("", subject)
    ck before.nodesWith(LowLevelAttribute).len == 0
    var trace = ""
    let plan = windowPlan("lowlevel:show", subject, trace)
    let panes = plan.nodesWith(LowLevelAttribute)
    ck panes.len == 1
    if panes.len == 0:
      checkpoint(trace)
      return
    # BESIDE THE SOURCE: the editor's region split along its row — the two
    # panes are as tall as each other, the editor no taller than before.
    let editor = plan.nodesWith(EditorExecutionAttribute)
    ck editor.len == 1
    if editor.len == 1:
      ck editor[0]{"styles"}{"h"}.getStr == panes[0]{"styles"}{"h"}.getStr
      ck before.nodesWith(EditorExecutionAttribute)[0]{"styles"}{"h"}.getStr ==
         editor[0]{"styles"}{"h"}.getStr
    let rows = plan.instructions
    # THE ENGINE'S LISTING, asked over this suite's own session.
    let session = newHeadlessDebugSession(subject, getEnv(ReplayServerBinEnv))
    let fn = session.session.store.asmFunction
    let answer = session.sendRawDapRequest("ct/load-asm-function", %*{
      "path": fn.path, "name": fn.name, "key": fn.key, "forceReload": false})
    discard session.drainEvents()
    session.close()
    let engine = answer{"body", "instructions"}.getElems
    ck engine.len > 1
    ck rows.len == engine.len
    for i in 0 ..< min(rows.len, engine.len):
      let offset = engine[i]{"offset"}.getInt
      ck rows[i].attr("data-ct-offset") ==
         (if offset < 0: "<no step id>" else: "StepId(" & $offset & ")")
      ck rows[i].attr("data-ct-source") ==
         engine[i]{"highLevelPath"}.getStr & ":" &
         $engine[i]{"highLevelLine"}.getInt
    # THE DESKTOP'S LISTING, row for row, marks included.
    ck plan.listingRows == desktopRows(desk["listing"])
    # The execution pointer, on the editor's execution line.
    var executing: seq[JsonNode] = @[]
    for r in rows:
      if r.attr("data-ct-executing") == "true": executing.add r
    ck executing.len == 1
    if executing.len == 1:
      ck executing[0].lineOf == plan.executionLine
      ck executing[0].textOf.startsWith(LowLevelPointerGlyph)
    # The header: what a step does, and the sync toggle.
    ck panes[0].attr("data-ct-low-level-stepping") == SteppingByLineText
    ck plan.nodesWith("data-ct-low-level-sync")[0].attr(
         "data-ct-low-level-sync") == "sync on"

  test "the cross-reference both ways, the menu, a press, sync off":
    let plan0 = windowPlan("lowlevel:show", subject)
    let lines = block:
      var acc: seq[int] = @[]
      for n in plan0.nodesWith(LowLevelLineAttribute):
        acc.add parseInt(n.attr(LowLevelLineAttribute))
      acc
    ck lines.len >= 2
    let here = plan0.executionLine
    var other = -1
    for l in lines:
      if l != here: other = l
    ck other > 0
    # SOURCE → INSTRUCTIONS.
    let linked = windowPlan("lowlevel:show,lowlevel:caret:" & $other, subject)
    var marked = 0
    for r in linked.instructions:
      if r.attr("data-ct-linked") == "true":
        inc marked
        ck r.lineOf == other
    ck marked >= 1
    # INSTRUCTION → SOURCE: two list keys from the pointer.
    let crossed = windowPlan("lowlevel:show,lowlevel:key:list.focus-next," &
                             "lowlevel:key:list.focus-next", subject)
    var selected: seq[JsonNode] = @[]
    for r in crossed.instructions:
      if r.attr("data-ct-selected") == "true": selected.add r
    ck selected.len == 1
    let refs = crossed.nodesWith(EditorCrossRefAttribute)
    ck refs.len == 1
    if selected.len == 1 and refs.len == 1:
      ck refs[0].textOf.contains($selected[0].lineOf)
    # The row's menu: the shared entries, in order.
    var target = -1
    for r in plan0.instructions:
      if r.lineOf == other: target = parseInt(r.attr(LowLevelRowAttribute))
    ck target >= 0
    var trace = ""
    discard windowPlan("lowlevel:show,lowlevel:menu:" & $target, subject, trace)
    var want: seq[string] = @[]
    for l in LowLevelMenuLabels: want.add l
    ck trace.contains("context menu low-level-row " & want.join("|"))
    var deskMenu: seq[string] = @[]
    for e in desk["rowMenu"]: deskMenu.add e["label"].getStr
    ck want == deskMenu
    # A PRESS: the debugger goes to that line; the pointer follows.
    let moved = windowPlan("lowlevel:show,lowlevel:row:" & $target, subject)
    ck moved.executionLine == other
    # As the desktop's click on the same instruction: the listing it shows.
    ck other == desk["click"]["targetLine"].getInt
    ck moved.listingRows == desktopRows(desk["listingAfter"])
    var now = -1
    for r in moved.instructions:
      if r.attr("data-ct-executing") == "true": now = r.lineOf
    ck now == other
    # Go to Source Line from the menu does the same.
    let viaMenu = windowPlan("lowlevel:show,lowlevel:menu:" & $target &
                             ",lowlevel:choose:Go to Source Line", subject)
    ck viaMenu.executionLine == other
    # SYNC OFF: said, and the cross-reference goes.
    let off = windowPlan("lowlevel:show,lowlevel:key:list.focus-next," &
                         "lowlevel:sync", subject)
    ck off.nodesWith("data-ct-low-level-sync")[0].attr(
         "data-ct-low-level-sync") == "sync off"
    ck off.nodesWith("data-ct-low-level-notice").len == 1
    ck off.nodesWith(EditorCrossRefAttribute).len == 0

suite "PLAT-60 GPUI suite self-check":
  test "plat60_gpui_assertion_count_is_measured":
    checkpoint("assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
