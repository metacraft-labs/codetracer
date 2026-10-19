## test_plat47_gpui_editor.nim — PLAT-47 B1, below the window. **GPUI's
## editor classifies its rows with the terminal's tokenizer and paints every
## run from the one editor theme — and a window that starts inside a
## multi-line string colours it as a string, as the desktop does.**
##
## The subject is `leaves.renderEditor` over a real `EditorSurface` of
## `calc`'s own source (`test-programs/calc/main.py`, the recording's
## program), read back out of the Rust side's render plan. The window opens
## at line 5, inside the module docstring (lines 2-26), carrying the entry
## state the host computes from the whole file (`lexical.lexerContexts`, as
## `gpui_host.serveWindow` does); the twin — the same window with no entry
## state — shows what the state is for: its docstring lines are read as code.
##
## The colours: every run is painted `editor_theme.tokenClassToken` of its
## class (Dark); that the classes and colours are the DESKTOP's is
## `test_plat47_gpui_parity.nim` (the plan against the Electron capture) and
## `test_plat47_gpui_window.nim` (the window's pixels).
##
## No mocks: the real surface, leaves, tokenizer and shim plan.

import std/[json, os, strutils, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings
import gpui/app/leaves
import view_vocabulary/pane_views
import tui/app/syntax/lexical

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Calc = "test-programs/calc/main.py"
  First = 5
  Last = 40
  DocstringEnd = 26
  ExpectedAssertions = 9

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc runsByLine(entry: string): seq[(int, seq[(string, string, string)])] =
  ## Render lines `First .. Last` of calc with `entry` as the first row's
  ## state; answer, per row, its runs as (class, colour, text) off the plan.
  let text = readFile(repo / Calc)
  var surface = editorSurfaceForProject("main.py", text, GpuiMedium, false,
                                        viewportTop = First,
                                        viewportHeight = Last - First + 1)
  surface.entryContext = entry
  gpui_reset_tree()
  var r: GpuiRenderer
  let parent = r.createElement("div")
  discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, surface)
  let plan = parseJson(renderPlanJson(r, parent))
  proc textOf(n: JsonNode): string =
    if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
    for c in n{"children"}.getElems: result.add textOf(c)
  var acc: seq[(int, seq[(string, string, string)])] = @[]
  proc walk(n: JsonNode) =
    let a = n{"attributes"}
    if not a.isNil and a{"data-ct-row"}.getStr.len > 0:
      var runs: seq[(string, string, string)] = @[]
      proc collect(m: JsonNode) =
        let b = m{"attributes"}
        if not b.isNil and b{"data-ct-token-class"}.getStr.len > 0:
          runs.add (b["data-ct-token-class"].getStr,
                    m["styles"]{"text_color"}.getStr, textOf(m))
        for c in m{"children"}.getElems: collect(c)
      collect(n)
      acc.add (parseInt(a["data-ct-row"].getStr), runs)
      return
    for c in n{"children"}.getElems: walk(c)
  walk(plan)
  acc

suite "PLAT-47 B1: GPUI's editor rows, classified and painted":

  let lines = readFile(repo / Calc).splitLines()
  let entry = lexerContexts("main.py", lines, First, First)

  test "a window opening inside the docstring colours it as a string":
    ck entry.len == 1
    let rows = runsByLine(entry[0])
    ck rows.len == Last - First + 1
    ck rows[0][0] == First
    var docLines = 0
    var allString = true
    var sawCode = false
    for (line, runs) in rows:
      if line <= DocstringEnd:
        for (cls, colour, text) in runs:
          if text.strip.len > 0 and cls != "tcString":
            checkpoint("line " & $line & ": '" & text & "' is " & cls)
            allString = false
        if lines[line - 1].strip.len > 0: inc docLines
      else:
        for (cls, _, _) in runs:
          if cls == "tcKeyword": sawCode = true
    ck docLines > 10
    ck allString
    # Past the docstring the code is code again (`def`, `return`).
    ck sawCode

  test "every run is painted its class's editor-theme colour":
    var mismatched = 0
    var runs = 0
    for (line, rs) in runsByLine(entry[0]):
      for (cls, colour, text) in rs:
        inc runs
        var want = ""
        for c in TokenClass:
          if $c == cls: want = tokenColour(c)
        if colour != want:
          inc mismatched
          checkpoint("line " & $line & " " & cls & " '" & text & "': " &
                     colour & " want " & want)
    ck runs > 50
    ck mismatched == 0

  test "the twin: the same window with no entry state reads the docstring as code":
    var nonString = 0
    for (line, runs) in runsByLine(""):
      if line <= DocstringEnd:
        for (cls, _, text) in runs:
          if text.strip.len > 0 and cls != "tcString":
            inc nonString
    ck nonString > 0

  test "assertion count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
