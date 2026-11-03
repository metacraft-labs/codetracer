## test_plat60_gpui_native_low_level_code.nim — **the Low Level Code pane in
## the GPUI window over a NATIVE recording**, read off the SHIPPED binary's
## window plan (`codetracer-gpui --report-window-plan --window-ops=…`: the
## window's own root builder and key handlers) over an rr recording of the
## shared native fixture (`codetracer-native-test-programs/c/sudoku_solver`,
## recorded by `tui/tests/fixtures/native_recording`) and a real
## `replay-server` with `ct-native-replay`:
##
##   * `view.low-level-code` opens the pane on the stop's function (`main`, at
##     the recording's entry) and the listing is the ENGINE's — its machine
##     code at its load addresses under `main.c`'s lines, the answer
##     `ct/load-asm-function` gives over this suite's own session;
##   * the execution pointer (`data-ct-executing`) is the instruction at the
##     stop's pc (`StopLocation.frameOffset`), on the editor's execution line;
##   * the header says a step goes BY INSTRUCTION — the engine announced it —
##     and F10 pressed in the listing moves the pointer to the next
##     instruction (from one that falls through); Shift+F10 then returns it.
##
## No mocks: the binary, the engine, the replay worker and the recording are
## the product's. Without `ct-native-replay` or `rr` the cases skip, each
## printing `MISSING-PREREQ SKIP:` with what is missing.

import replay_prerequisite
import ../../../common/replay_server_path
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import headless_session
import isonim/core/signals
import gpui/app/leaves
import gpui/low_level_code_leaf
import codetracer_embed
import ../../tui/tests/fixtures/native_recording

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 12

var countedAssertions = 0
var skipped = false

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

proc executingRow(plan: JsonNode): JsonNode =
  for r in plan.instructions:
    if r.attr("data-ct-executing") == "true": return r
  nil

proc nextOffset(engine: seq[JsonNode]; offset: string): string =
  ## The offset of the instruction after the one at `offset`, as the pane
  ## writes it (its load address).
  proc text(e: JsonNode): string = $e{"offset"}.getBiggestInt
  for i, e in engine:
    if e.text == offset and i + 1 < engine.len:
      return engine[i + 1].text
  ""

proc mnemonicOf(row: JsonNode): string =
  row.attr("data-ct-instruction").split(' ')[0]

proc fallsThrough(mnemonic: string): bool =
  mnemonic.len > 0 and mnemonic[0] != 'j' and
    not mnemonic.startsWith("call") and not mnemonic.startsWith("ret")

suite "the Low Level Code pane in the GPUI window, native (rr) recording":

  let rec = nativeRecording()

  test "the stop's machine code, its pointer, and steps by instruction":
    if not rec.ok:
      echo "  ", missingNativePrereq(rec)
      skipped = true
      skip()
    else:
      # THE ENGINE'S LISTING, asked over this suite's own session.
      let session = newHeadlessDebugSession(rec.tracePath,
                                            getEnv(ReplayServerBinEnv))
      let fn = session.session.store.asmFunction
      let pc = session.session.store.stop.val.frameOffset
      let answer = session.sendRawDapRequest("ct/load-asm-function", %*{
        "path": fn.path, "name": fn.name, "key": fn.key, "forceReload": false})
      discard session.drainEvents()
      session.close()
      checkpoint("ct/load-asm-function: " & ($answer)[0 ..< min(400, ($answer).len)])
      ck answer{"success"}.getBool(false)
      var trace = ""
      let plan = windowPlan("lowlevel:show", rec.tracePath, trace)
      let panes = plan.nodesWith(LowLevelAttribute)
      ck panes.len == 1
      if panes.len == 0:
        checkpoint(trace)
        return
      let rows = plan.instructions
      let engine = answer{"body", "instructions"}.getElems
      ck engine.len > 10
      # The pane draws the rows in view (a function's machine code is longer
      # than the pane): each drawn instruction is the engine's at its index.
      ck rows.len > 10
      var same = true
      for r in rows:
        let i = parseInt(r.attr(LowLevelRowAttribute))
        if i < 0 or i >= engine.len:
          same = false
          break
        let e = engine[i]
        let source = if e{"highLevelLine"}.getInt > 0:
                       e{"highLevelPath"}.getStr & ":" & $e{"highLevelLine"}.getInt
                     else: ""
        if r.attr("data-ct-offset") != $e{"offset"}.getBiggestInt or
           r.attr("data-ct-source") != source:
          checkpoint("row " & $i & ": " & $r{"attributes"} & " vs " & $e)
          same = false
          break
      ck same
      # THE EXECUTION POINTER: the stop's instruction, on the editor's line.
      let at = plan.executingRow
      ck not at.isNil
      if at.isNil: return
      ck at.attr("data-ct-offset") == $pc
      ck parseInt(at.attr("data-ct-source").rsplit(':')[^1]) ==
         plan.executionLine
      ck at.textOf.startsWith(LowLevelPointerGlyph)
      # The header: a step goes by instruction.
      ck panes[0].attr("data-ct-low-level-stepping") == SteppingByInstructionText
      # F10 in the listing: the next instruction, from one that falls through.
      var ops = "lowlevel:show"
      var here = at
      var stepped = 0
      for _ in 0 ..< 6:
        ops.add ",key:f10"
        let after = windowPlan(ops, rec.tracePath).executingRow
        if after.isNil:
          ck false
          break
        if here.mnemonicOf.fallsThrough:
          let want = engine.nextOffset(here.attr("data-ct-offset"))
          if after.attr("data-ct-offset") != want:
            checkpoint("from " & $here{"attributes"} & " to " &
                       $after{"attributes"} & ", wanted " & want)
            ck false
            break
          inc stepped
          # Shift+F10 returns it to the instruction it left.
          let back = windowPlan(ops & ",key:f10:shift", rec.tracePath).executingRow
          ck not back.isNil and back.attr("data-ct-offset") == here.attr("data-ct-offset")
          break
        here = after
      ck stepped == 1

suite "native GPUI suite self-check":
  test "native_gpui_assertion_count_is_measured":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
