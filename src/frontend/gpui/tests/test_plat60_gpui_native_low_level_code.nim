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
## And View › View Generated C Source (Generated-Code-Listing §13.4):
##
##   * over the native Nim example recording (a stock compiler's C, mapped by
##     its `#line` directives);
##   * over a recording `ct record` makes of a Nim program today
##     (`nim_ct_recording`): CodeTracer's compiler writes no directives, only
##     `.nim.c.map` Source Maps, kept in `<trace>/nimcache/`, which the
##     recording's file tree serves none of — the window offers and reads
##     them from the trace folder (`gpui/host/trace_nimcache`);
##   * in an Edit window (HSF-E11), with no recording: the saved file
##     compiled to C (`native_nim_c_compiler`) while the window keeps
##     running, then its listing scrolled to the caret line's C — and a file
##     that does not compile, or a missing compiler, refused in the pane with
##     the reason.
##
## No mocks: the binary, the engine, the replay worker, the recordings and
## the compiler are the product's. Without `ct-native-replay`, `rr`, `ct`,
## `ct-mcr` or CodeTracer's Nim the cases that need one skip, each printing
## `MISSING-PREREQ SKIP:` with what is missing.

import replay_prerequisite
import ../../../common/replay_server_path
import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import headless_session
import isonim/core/signals
import gpui/app/leaves
import gpui/low_level_code_leaf
import codetracer_embed
import ../../tui/tests/fixtures/native_recording
import ./nim_ct_recording
import gpui/host/trace_nimcache
from ../../tui/tests/fixtures/fixture_provider import MissingPrereqSkipPrefix

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 46

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

proc windowPlan(ops: string; subject: string; trace: var string;
                edit = false; extraEnv: openArray[(string, string)] = []):
    JsonNode =
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
  for (k, v) in extraEnv:
    env[k] = v
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if edit:
    # An Edit window over a project folder (`ct edit`'s spelling).
    args.insert("--edit", 0)
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

proc windowPlan(ops: string; subject: string; edit = false;
                extraEnv: openArray[(string, string)] = []): JsonNode =
  var t: string
  windowPlan(ops, subject, t, edit, extraEnv)

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

proc lowLevelEmpty(plan: JsonNode): string =
  ## What an empty listing says (its own words, not an error).
  for n in plan.nodesWith("data-ct-low-level-empty"):
    return n.attr("data-ct-low-level-empty")
  ""

proc lowLevelError(plan: JsonNode): string =
  ## The pane's message line (a refusal, or "compiling…").
  for n in plan.nodesWith("data-ct-low-level-error"):
    return n.attr("data-ct-low-level-error")
  ""

proc revealedRow(trace: string): int =
  ## The listing row View Generated C Source said it brought into view (-1
  ## when the caret's line maps to none), from the gesture trace.
  const Marker = "View Generated C Source: row "
  let at = trace.rfind(Marker)
  if at < 0: return -2
  let rest = trace[at + Marker.len .. ^1]
  parseInt(rest[0 ..< rest.find(' ')])

proc rowTexts(plan: JsonNode): seq[string] =
  ## The drawn rows' WHOLE text (the row's own text is cut to the pane).
  for r in plan.instructions: result.add r.attr("data-ct-instruction")

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

  test "View Generated C Source: the generated C of the editor's Nim line":
    # Generated-Code-Listing §13.4: the View menu's item, as choosing it runs
    # it (`lowlevel:generated-c`), on CodeTracer's native Nim example
    # recording (rr), which opens stopped in `nim_flow_test.nim`. The pane
    # shows the module's generated C — its `#line` directives among the rows
    # — read from the recording's bundled nimcache by the shared presenter.
    let example = currentSourcePath().parentDir / ".." / ".." / ".." / ".." /
      ".." / "codetracer-example-recordings" / "nim" / "flow_test"
    if not dirExists(example) or getEnv("CODETRACER_CT_NATIVE_REPLAY_CMD").len == 0:
      echo "  MISSING-PREREQ SKIP: the native Nim example recording (", example,
           ") and the native backend ($CODETRACER_CT_NATIVE_REPLAY_CMD)"
      skipped = true
      skip()
    else:
      # The caret on the stop's line — the line asked about — then the item.
      let line = windowPlan("", example).executionLine
      checkpoint("the stop's line: " & $line)
      var trace = ""
      let plan = windowPlan("lowlevel:caret:" & $line & ",lowlevel:generated-c",
                            example, trace)
      let rows = plan.instructions
      var texts: seq[string] = @[]
      for r in rows: texts.add r.textOf
      checkpoint("rows:\n" & texts.join("\n"))
      checkpoint(trace)
      ck plan.nodesWith(LowLevelAttribute).len == 1
      ck texts.anyIt("#line" in it)

  test "View Generated C Source over a `ct record` recording: the C its maps anchor":
    # Generated-Code-Listing §13.4, "Where the C comes from": a recording
    # `ct record` made of a Nim program keeps its C and the Source Maps
    # beside them in `<trace>/nimcache/`; the recording's file tree bundles
    # the C and none of the maps. The listing is the program's own module's
    # C, anchored by its map (it has no `#line` directive), and the row the
    # stop's line compiled to is brought into view. (The recording bundles
    # no copy of the program's `.nim` source either, so the editor has no
    # document to put a caret in: the item asks about the stop's line.)
    let rec = nimCtRecording()
    if not rec.ok or getEnv("CODETRACER_CT_NATIVE_REPLAY_CMD").len == 0:
      echo "  ", MissingPrereqSkipPrefix, " ", NimCtFixtureName, " — ",
           (if rec.ok: "the native backend ($CODETRACER_CT_NATIVE_REPLAY_CMD)"
            else: rec.detail)
      skipped = true
      skip()
    else:
      var trace = ""
      let plan = windowPlan("lowlevel:generated-c", rec.tracePath, trace)
      let rows = plan.instructions
      let texts = plan.rowTexts
      checkpoint("rows:\n" & texts.join("\n"))
      checkpoint(trace)
      ck plan.nodesWith(LowLevelAttribute).len == 1
      ck rows.len > 0
      # CodeTracer's compiler: mapped by the map, there is no directive.
      ck not texts.anyIt("#line" in it)
      # The program module's own C file: its frame records name the source.
      ck texts.anyIt(NimCtProgramName & ".nim" in it)
      let revealed = trace.revealedRow
      ck revealed >= 0
      # In view, and the row the caret's line compiled to (the anchor's).
      ck rows.anyIt(parseInt(it.attr(LowLevelRowAttribute)) == revealed and
                    it.attr("data-ct-active") == "true")

  test "a `ct record` recording's nimcache: offered, and read only inside the trace":
    # `trace_nimcache` over a real folder: what the window adds to the
    # recording's file list, and which paths its fallback reads from disk
    # when the session's source provider cannot serve one.
    let t = createTempDir("plat60-gpui-nimcache-", "")
    createDir(t / NimcacheDir)
    let c = t / NimcacheDir / "@mmain.nim.c"
    writeFile(c, "int main(void) { return 0; }\n")
    writeFile(c & ".map", "{}")
    writeFile(t / NimcacheDir / "main.json", "{}")
    # A C file the tree already names (where it was recorded) is not offered
    # twice; one it lacks is offered from the trace folder.
    let named = ["/recorded/at/nimcache/@mmain.nim.c", "/src/main.nim"]
    ck nimcacheCandidates(t, named) == @named
    ck nimcacheCandidates(t, ["/src/main.nim"]) == @["/src/main.nim", c]
    # Read from the trace folder: the C or its map, by the recorded path's
    # name; nothing else, and nothing outside it.
    ck nimcacheFileFor(t, "/recorded/at/nimcache/@mmain.nim.c.map") == c & ".map"
    ck nimcacheFileFor(t, c) == c
    ck nimcacheFileFor(t, t / NimcacheDir / "main.json") == ""
    ck nimcacheFileFor(t, "/recorded/at/nimcache/@mother.nim.c") == ""
    removeDir(t)

  # HSF-E11: Edit mode. A project folder holding one Nim file, opened in an
  # Edit window — no recording, no engine: the C is compiled now.
  const CalcNim = """proc triple(n: int): int =
  result = n * 3

var acc = 0
for i in 1..5:
  acc += triple(i)
echo acc
"""
  let haveNim = getEnv("CODETRACER_NIM").len > 0 or findExe("nim").len > 0

  proc nimProject(name, text: string): string =
    result = createTempDir("plat60-gpui-edit-", "")
    writeFile(result / name, text)

  test "Edit mode: View Generated C Source compiles the saved file, then lists its C":
    if not haveNim:
      echo "  ", MissingPrereqSkipPrefix, " Edit mode's generated C — no `nim` ",
           "(set CODETRACER_NIM, or put `nim` on the PATH)"
      skipped = true
      skip()
    else:
      let project = nimProject("calc.nim", CalcNim)
      # While the compiler runs the window keeps going: the plan reported
      # right after the gesture shows the pane saying so — as the listing's
      # own words, not as an error.
      let during = windowPlan("lowlevel:caret:2,lowlevel:generated-c", project,
                              edit = true)
      checkpoint("during: " & during.lowLevelEmpty & " / " & during.lowLevelError)
      ck during.lowLevelEmpty.startsWith("compiling calc.nim to C")
      ck during.lowLevelError == ""
      # Settled: the module's C, scrolled to the caret line's row.
      var trace = ""
      let plan = windowPlan("lowlevel:caret:2,lowlevel:generated-c,wait:120000",
                            project, trace, edit = true)
      let rows = plan.instructions
      let texts = plan.rowTexts
      checkpoint("rows:\n" & texts.join("\n"))
      checkpoint(trace)
      ck plan.nodesWith(LowLevelAttribute).len == 1
      ck rows.len > 0
      ck plan.lowLevelError == ""
      ck texts.anyIt("triple" in it)
      let revealed = trace.revealedRow
      ck revealed >= 0
      # In view, and the row the caret's line compiled to (the anchor's).
      ck rows.anyIt(parseInt(it.attr(LowLevelRowAttribute)) == revealed and
                    it.attr("data-ct-active") == "true")
      removeDir(project)

  test "Edit mode: the caret's line links its C rows; a selected C row marks its line":
    # PLAT-60's cross-reference both ways (Generated-Code-Listing §0.2), in
    # an Edit window's generated-C listing as in a replay's: SOURCE -> C, the
    # rows the caret's line compiled to are the listing's linked rows;
    # C -> SOURCE, the line a selected C row came from is on the editor's
    # cross-reference ground, wherever the caret is.
    if not haveNim:
      echo "  ", MissingPrereqSkipPrefix, " Edit mode's generated C — no `nim`"
      skipped = true
      skip()
    else:
      let project = nimProject("calc.nim", CalcNim)
      let listed = "lowlevel:caret:2,lowlevel:generated-c,wait:120000"
      var trace = ""
      discard windowPlan(listed, project, trace, edit = true)
      let line2 = trace.revealedRow   # the row line 2 compiled to
      ck line2 >= 0
      # The caret moved up to line 1 (`proc triple…`) by a key in the editor:
      # its C — the function's head — is linked, line 2's row no longer is.
      let source = windowPlan(listed & ",key:up", project, edit = true)
      let linked = source.instructions.filterIt(it.attr("data-ct-linked") == "true")
      checkpoint("linked: " & $linked.mapIt(it.attr("data-ct-instruction")))
      ck linked.len > 0
      ck linked.anyIt("triple" in it.attr("data-ct-instruction"))
      ck not linked.anyIt(parseInt(it.attr(LowLevelRowAttribute)) == line2)
      # The caret on line 6, line 2's row selected (its menu's press selects
      # it without going to it): the editor marks line 2, and only it.
      let cross = windowPlan(listed & ",lowlevel:caret:6,lowlevel:menu:" & $line2,
                             project, edit = true)
      let marked = cross.nodesWith("data-ct-cross-ref")
      checkpoint("marked: " & $marked.mapIt(it.attr("data-ct-row")))
      ck marked.len == 1
      ck marked.len == 1 and marked[0].attr("data-ct-row") == "2"
      removeDir(project)

  test "Edit mode: a file that does not compile is refused with the compiler's error":
    if not haveNim:
      echo "  ", MissingPrereqSkipPrefix, " Edit mode's generated C — no `nim`"
      skipped = true
      skip()
    else:
      let project = nimProject("broken.nim", "let x: int = \"text\"\necho x\n")
      var trace = ""
      let plan = windowPlan("lowlevel:generated-c,wait:120000", project, trace,
                            edit = true)
      checkpoint(trace)
      let error = plan.lowLevelError
      checkpoint("error: " & error)
      ck plan.nodesWith(LowLevelAttribute).len == 1
      ck plan.instructions.len == 0
      ck "Error:" in error
      ck "broken.nim" in error
      removeDir(project)

  test "Edit mode: with no Nim compiler the item says so":
    let project = nimProject("calc.nim", CalcNim)
    let plan = windowPlan("lowlevel:generated-c", project, edit = true,
                          extraEnv = [("CODETRACER_NIM",
                                       project / "no-such-nim")])
    checkpoint("error: " & plan.lowLevelError)
    ck plan.nodesWith(LowLevelAttribute).len == 1
    ck "no `nim` to compile calc.nim" in plan.lowLevelError
    removeDir(project)

suite "native GPUI suite self-check":
  test "native_gpui_assertion_count_is_measured":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
