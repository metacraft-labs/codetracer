## test_plat70g_gpui_plan.nim — multi-click selection, the gutter's lanes and
## zones, Alt+click and Shift+F9 in the GPUI window (Editor-Pane.md MC.1 – MC.7).
##
## Driven through `--report-window-plan` and `--window-ops`: the press reaches the
## window as the shim delivers it, and what it did is read from the gesture trace
## and the render plan. The platform's click count travels as the shim sends it
## (the key's third field, `count=N` in the op), so GPUI's own count can be stricter
## than the application's.
##
## No mocks: the shipped binary, a real recording, a real `replay-server`.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env
import ../../tui/tests/fixtures/fixture_provider
import viewmodels/editor_gutter_lanes
import gpui/app/leaves
import gpui/chrome

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 47
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
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

proc windowPlan(ops: string; keymap = ""): tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat70g-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("plat70g-gpui-plan-", ".err")
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops]
  if keymap.len > 0: args.add "--keymap=" & keymap
  args.add trace
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
  n{"attributes"}{name}.getStr

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind == JObject and n{"attributes"} != nil and n.has(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc lastLine(trace, prefix: string): string =
  for l in trace.splitLines:
    if prefix in l: result = l

proc countOf(trace, needle: string): int =
  for l in trace.splitLines:
    if needle in l: inc result

proc code(line, column: int; button = "left"; mods = ""; count = 0): string =
  result = "click:code:" & $line & "@" & $column & ":" & button & ":" & mods
  if count > 0: result.add ":count=" & $count

proc gutter(line: int; px = -1; button = "left"; mods = ""): string =
  "click:gutter:" & $line & (if px >= 0: "@" & $px else: "") & ":" & button & ":" & mods

# Line 31 of `calc`'s main.py, `    return left + right`, is on screen at the first
# stop; column 7 is inside `return`.
const
  Line = 31

suite "counts (MC.1, MC.2)":
  test "the platform's count reaches the counter, and the stricter one wins":
    let two = windowPlan(code(Line, 7) & "," & code(Line, 7)).trace
    ck two.contains("press count 2 editor.select-word-at")
    let three = windowPlan(code(Line, 7) & "," & code(Line, 7) & "," &
                           code(Line, 7)).trace
    ck three.contains("press count 3 editor.select-line-at")
    let four = windowPlan(code(Line, 7) & "," & code(Line, 7) & "," &
                          code(Line, 7) & "," & code(Line, 7)).trace
    ck four.contains("press count 4 editor.select-all")
    # GPUI said 1 twice, as an OS with a shorter interval would.
    let strict = windowPlan(code(Line, 7, count = 1) & "," &
                            code(Line, 7, count = 1)).trace
    ck strict.contains("press count 1 editor.move-caret-to")
    ck not strict.contains("press count 2")

  test "Shift, Shift+double and Shift+triple extend by character, word and line":
    let c = windowPlan(code(Line, 7) & "," & code(Line, 12, mods = "shift")).trace
    ck c.contains("press count 1 editor.extend-by-unit-to")
    ck not c.lastLine("selection ").contains("none")
    let w = windowPlan(code(Line, 7) & "," & code(Line, 12, mods = "shift") & "," &
                       code(Line, 12, mods = "shift")).trace
    ck w.contains("press count 2 editor.extend-by-unit-to")
    let l = windowPlan(code(Line, 7) & "," & code(Line, 12, mods = "shift") & "," &
                       code(Line, 12, mods = "shift") & "," &
                       code(Line, 12, mods = "shift")).trace
    ck l.contains("press count 3 editor.extend-by-unit-to")

  test "Shift+Alt selects a column; Alt adds a cursor and no breakpoint":
    # Lines 4-7 of the docstring at the top of main.py: four lines of text.
    let column = windowPlan(code(4, 5) & "," & code(7, 30, mods = "shift+alt")).trace
    ck column.contains("press count 1 editor.column-select-to")
    ck column.lastLine("selection ").contains("ranges 4")
    let (plan, tr) = windowPlan(code(Line, 7) & "," & code(Line + 2, 9, mods = "alt"))
    ck tr.contains("press count 1 editor.add-cursor-at-point")
    ck tr.lastLine("selection ").contains("ranges 2")
    ck not tr.contains("column breakpoint")
    ck plan.nodesWith("data-ct-mark-glyph").len == 0

  test "pixel halves of a separator select the word on that side":
    # `left + right`: the `+` at column 17, a separator with a space either side.
    let at = 17
    let leftHalf = windowPlan("click:code:" & $Line & "@" & $at & "l:left:" & "," &
                              "click:code:" & $Line & "@" & $at & "l:left:").trace
    let rightHalf = windowPlan("click:code:" & $Line & "@" & $at & "r:left:" & "," &
                               "click:code:" & $Line & "@" & $at & "r:left:").trace
    ck leftHalf.lastLine("selection ") != rightHalf.lastLine("selection ")

suite "the modal bases (MC.7)":
  test "the mode effects equal the terminal's":
    let vimWord = windowPlan(code(Line, 7) & "," & code(Line, 7), "vim").trace
    ck vimWord.lastLine("selection ").contains("mode visual")
    let vimLine = windowPlan(code(Line, 7) & "," & code(Line, 7) & "," & code(Line, 7),
                             "vim").trace
    ck vimLine.lastLine("selection ").contains("mode visual-line")
    let kak = windowPlan(code(Line, 7) & "," & code(Line, 7), "kakoune").trace
    ck kak.lastLine("selection ").contains("mode normal")
    let emacs = windowPlan(code(Line, 7) & "," & code(Line, 7), "emacs").trace
    ck emacs.lastLine("selection ").contains("mode visual")

suite "the gutter (MC.5)":
  test "the lanes, read from the plan, are the shared map's":
    let (plan, _) = windowPlan("wait:1")
    let bands = plan.nodesWith("data-ct-gutter-band")
    ck bands.len > 0
    ck bands[0].attr("data-ct-gutter-band") == $gbGlyph
    ck bands[1].attr("data-ct-gutter-band") == $gbPointer
    ck bands[2].attr("data-ct-gutter-band") == $gbLineNumber
    # At this front-end's font, the desktop's glyph margin: one line height.
    let resolved = resolveBands(CodeFontPx, EditorGutterPx)
    ck resolved[0].band == gbGlyph
    ck resolved[0].rightPx - resolved[0].leftPx == gbGlyph.widthPx(CodeFontPx)

  test "a glyph press toggles, uncounted, and selects nothing":
    let (once, _) = windowPlan(gutter(Line))
    ck once.nodesWith("data-ct-mark-glyph").len == 1
    let (twice, tr) = windowPlan(gutter(Line) & "," & gutter(Line))
    ck twice.nodesWith("data-ct-mark-glyph").len == 0
    ck not tr.contains("selection ")

  test "a glyph right press disables and a second enables; on no mark, nothing":
    let (off, _) = windowPlan(gutter(Line) & "," & gutter(Line, button = "right"))
    ck off.nodesWith("data-ct-mark-glyph")[0].attr("data-ct-mark-glyph") == BreakpointDisabledGlyph
    let (on, _) = windowPlan(gutter(Line) & "," & gutter(Line, button = "right") &
                             "," & gutter(Line, button = "right"))
    ck on.nodesWith("data-ct-mark-glyph")[0].attr("data-ct-mark-glyph") == BreakpointGlyph
    let (none, _) = windowPlan(gutter(Line, button = "right"))
    ck none.nodesWith("data-ct-mark-glyph").len == 0

  test "a number selects the line; Shift extends by lines; Alt adds a line cursor":
    # 40 px into the gutter: the line number band, past the glyph and pointer.
    let (plan, tr) = windowPlan(gutter(Line, 45))
    ck tr.contains("press count 1 editor.select-line-at")
    ck plan.nodesWith("data-ct-mark-glyph").len == 0
    let s = windowPlan(gutter(Line, 45) & "," & gutter(Line + 2, 45, mods = "shift")).trace
    ck s.contains("editor.extend-by-unit-to")
    ck s.lastLine("selection ").contains($Line & ":1-" & $(Line + 2))
    let a = windowPlan(code(Line, 7) & "," & gutter(Line + 2, 45, mods = "alt")).trace
    ck a.contains("editor.add-cursor-at-point(line)")
    ck a.lastLine("selection ").contains("ranges 2")

  test "the zone boundary is the glyph lane's right edge":
    let edge = gbGlyph.widthPx(CodeFontPx)
    let inside = windowPlan(gutter(Line, edge - 1)).trace
    ck not inside.contains("select-line-at")
    let outside = windowPlan(gutter(Line, edge)).trace
    ck outside.contains("select-line-at")

suite "the source gate":
  test "the source gate: GPUI's lanes are the shared map's":
    let leavesText = readFile(repo / "src/frontend/gpui/app/leaves.nim")
    ck "GutterBreakpointX" notin leavesText
    ck "resolveBands(CodeFontPx, EditorGutterPx)" in leavesText

suite "Shift+F9 and the menu":
  test "Shift+F9 at a caret and the menu entry set a column breakpoint":
    let tr = windowPlan("click:code:" & $Line & "@7l:left:,key:f9:shift").trace
    ck tr.contains("inline breakpoint " & $Line & ":7")
    let col1 = windowPlan("click:code:" & $Line & "@1l:left:,key:f9:shift").plan
    ck col1.nodesWith("data-ct-mark-glyph").len == 1
    let (menu, _) = windowPlan(code(Line, 7, button = "right"))
    let text = $menu
    ck text.contains("Add Inline Breakpoint")
    ck text.contains("Shift+F9")
    ck text.contains("<click left of the line number>")

  test "the assertion count":
    check CHECKS == ExpectedAssertions
