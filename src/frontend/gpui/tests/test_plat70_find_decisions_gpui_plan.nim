## test_plat70_find_decisions_gpui_plan.nim — the user's three find decisions
## of 2026-11-20 (Find-And-Incremental-Search.md §7, OQ-F5 – OQ-F7) in the GPUI
## windows, read off the SHIPPED binary's window plan
## (`codetracer-gpui --report-window-plan --window-ops=…`: the window's own key
## handlers and element focus):
##
##   * OQ-F5 — in the replay window over a real recording of `calc` against a
##     real `replay-server`: `Alt+R` reads the field as a regular expression
##     (the widget's `.*` toggle on, the bands exactly `matchesOf`'s with
##     `regex`), an expression that does not compile says why in the count,
##     and `Alt+L` confines the search to the selected lines;
##   * OQ-F6 — the bands are painted with the design system's find tokens
##     (`editor-theme/findMatchHighlight`, the current one
##     `editor-theme/findMatch`);
##   * OQ-F7 — in the FOLDER window (`--edit`) under Vim, `/` opens the widget,
##     typing highlights, `Enter` commits and `n` walks on; `?` searches
##     backward; under Kakoune `/` opens it too; and CUA's `Ctrl+F` does.
##
## No mocks: the binary, the engine, the recording and the folder on disk are
## the product's.

import replay_prerequisite
import ../../tui/tests/fixtures/fixture_provider
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unicode,
            unittest]

import codetracer_embed
import ./gpui_child_env

import ../app/leaves   # the widget's and the bands' attribute names, colours
import ../../styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 40

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1440
  H = 1400
  FolderText = "def area(width, height):\n" &
               "    return width * height\n" &
               "\n" &
               "def perimeter(width, height):\n" &
               "    return 2 * (width + height)\n" &
               "\n" &
               "print(area(3, 4), perimeter(3, 4))\n"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calcLines = readFile(repo / "test-programs/calc/main.py").splitLines

let calc = requireFixture(fixtureSpec("calc"))

proc windowPlan(ops: string; trace: var string; keymap = "cua";
                project = ""): JsonNode =
  ## The window's plan after `ops`: over the calc recording, or — `project`
  ## given — a folder window (`--edit`) over that folder.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat70-find-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  let args = (if project.len > 0: @["--edit"] else: @[]) &
             @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--keymap=" & keymap, "--window-ops=" & ops,
               (if project.len > 0: project else: calc)]
  let errFile = genTempPath("plat70-find-gpui-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", gpuiRunScript("2>" & quoteShell(errFile)),
             bin] & args, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui " & gpuiExitText(rc) & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc folder(): string =
  ## A one-file folder for the folder window.
  result = createTempDir("plat70-find-folder-", "")
  writeFile(result / "shapes.py", FolderText)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc values(plan: JsonNode; attribute: string): seq[string] =
  for n in plan.nodesWith(attribute): result.add n.attr(attribute)

proc lastFind(trace: string): string =
  ## The window's last `find …` trace line.
  for line in trace.splitLines:
    if line.startsWith("gesture find open="): result = line["gesture ".len .. ^1]

proc field(line, name: string): string =
  let at = line.find(name & "=")
  if at < 0: return ""
  let rest = line[at + name.len + 1 .. ^1]
  let stop = rest.find(" ")
  if stop < 0: rest else: rest[0 ..< stop]

proc drawnLines(plan: JsonNode): seq[int] =
  for v in plan.values("data-ct-row"):
    try: result.add parseInt(v)
    except ValueError: discard

proc marksOf(lines: seq[string]; drawn: seq[int]; query: string;
             opts: MatchOptions; only: seq[int] = @[]): seq[string] =
  ## `matchesOf` over every drawn line (or only the lines `only` names), as
  ## the bands' `line:from-to`.
  for line in drawn:
    if line < 1 or line > lines.len: continue
    if only.len > 0 and line notin only: continue
    let l = lines[line - 1]
    for m in matchesOf(l, query, opts):
      result.add $line & ":" & $(l[0 ..< m.a].runeLen + 1) & "-" &
                 $(l[0 ..< m.b].runeLen + 1)

proc widget(plan: JsonNode): JsonNode =
  let w = plan.nodesWith(FindWidgetAttribute)
  if w.len == 1: w[0] else: newJObject()

suite "OQ-F5: regular expressions and Find in Selection (replay window)":

  test "Alt+R reads the field as a regular expression":
    let rx = MatchOptions(caseSensitive: false, regex: true)
    var t: string
    let plan = windowPlan("click:code:31@13,key:f:control,type:r[a-z]+t," &
                          "key:r:alt", t)
    ck plan.widget.attr("data-ct-find-regex") == "on"
    ck t.lastFind.field("regex") == "true"
    let got = plan.values(FindMatchAttribute)
    let want = calcLines.marksOf(plan.drawnLines, "r[a-z]+t", rx)
    checkpoint($got.len & " bands, " & $want.len & " expected")
    ck want.len > 0
    ck got == want
    ck plan.values(FindCurrentAttribute).len == 1
    # Off again: the same text is a literal, which occurs nowhere.
    var t2: string
    let off = windowPlan("click:code:31@13,key:f:control,type:r[a-z]+t," &
                         "key:r:alt,key:r:alt", t2)
    ck off.widget.attr("data-ct-find-regex") == "off"
    ck off.values(FindMatchAttribute).len == 0

  test "an expression that does not compile says why":
    var t: string
    let plan = windowPlan("click:code:31@13,key:f:control,key:r:alt,type:(left",
                          t)
    ck plan.widget.attr("data-ct-find-count").startsWith(
         "invalid regular expression")
    ck plan.values(FindMatchAttribute).len == 0

  test "Alt+L confines the search to the selected lines":
    # Lines 10 – 12 selected (from line 10's start to line 13's), then the
    # widget opened over them, Alt+L, and the query.
    var t: string
    let plan = windowPlan("click:code:10@1,key:down:shift,key:down:shift," &
                          "key:down:shift,key:f:control,key:l:alt,type:e", t)
    ck plan.widget.attr("data-ct-find-in-selection") == "on"
    ck t.lastFind.field("scope") == "1"
    let opts = MatchOptions(caseSensitive: false)
    let got = plan.values(FindMatchAttribute)
    let want = calcLines.marksOf(plan.drawnLines, "e", opts, only = @[10, 11, 12])
    checkpoint($got.len & " bands, " & $want.len & " expected")
    ck want.len > 0
    ck got == want
    # Toggled off, the whole drawn text matches again.
    var t2: string
    let off = windowPlan("click:code:10@1,key:down:shift,key:down:shift," &
                         "key:down:shift,key:f:control,key:l:alt,type:e," &
                         "key:l:alt", t2)
    ck off.widget.attr("data-ct-find-in-selection") == "off"
    ck off.values(FindMatchAttribute).len > got.len

suite "OQ-F6: the find tokens":

  test "the bands are painted with the find tokens":
    ck FindMatchColour ==
         DesignTokenHex[dtEditorThemeFindMatchHighlight][dmDark]
    ck FindMatchCurrentColour == DesignTokenHex[dtEditorThemeFindMatch][dmDark]
    var t: string
    let plan = windowPlan("click:code:31@13,key:f:control,type:left", t)
    var current, other = 0
    var wrong: seq[string] = @[]
    for n in plan.nodesWith(FindMatchAttribute):
      let bg = n{"styles"}{"bg"}.getStr
      if n{"attributes"}.hasKey(FindCurrentAttribute):
        inc current
        if bg != FindMatchCurrentColour: wrong.add "current " & bg
      else:
        inc other
        if bg != FindMatchColour: wrong.add "match " & bg
    checkpoint($wrong)
    ck wrong.len == 0
    ck current == 1
    ck other > 0

suite "OQ-F7: `/` in the folder window":

  test "Vim: / opens the widget, typing highlights, Enter keeps, n walks":
    let dir = folder()
    defer: removeDir(dir)
    let lines = FolderText.splitLines
    let opts = MatchOptions(caseSensitive: true)
    var t1: string
    let plan = windowPlan("key:/,type:width", t1, keymap = "vim", project = dir)
    ck plan.widget.attr("data-ct-find-field") == "width"
    ck t1.lastFind.field("open") == "true"
    let got = plan.values(FindMatchAttribute)
    let want = lines.marksOf(plan.drawnLines, "width", opts)
    checkpoint($got.len & " bands, " & $want.len & " expected")
    ck want.len == 4
    ck got == want
    var t2, t3: string
    discard windowPlan("key:/,type:width,key:enter", t2, keymap = "vim",
                       project = dir)
    ck t2.lastFind.field("open") == "false"
    let kept = t2.lastFind.field("selection")
    ck kept.len > 0
    # `n` there is the editor's own `search-next` (Edit mode, OQ-F7), which
    # traces nothing; the `/` after it opens a session whose trace reads the
    # caret `n` left.
    discard windowPlan("key:/,type:width,key:enter,key:n,key:/", t3,
                       keymap = "vim", project = dir)
    ck t3.lastFind.field("selection") != kept
    ck parseInt(t3.lastFind.field("selection").split('-')[0]) ==
         FolderText.find("width", parseInt(kept.split('-')[0]) + 1)

  test "Vim: ? searches backward; Escape cancels to the caret":
    let dir = folder()
    defer: removeDir(dir)
    var t1, t2: string
    discard windowPlan("key:?,type:height,key:enter", t1, keymap = "vim",
                       project = dir)
    # Backward from the top wraps to the LAST `height`.
    let sel = t1.lastFind.field("selection").split('-')
    ck sel.len == 2
    ck parseInt(sel[0]) == FolderText.rfind("height")
    discard windowPlan("key:/,type:height,key:escape", t2, keymap = "vim",
                       project = dir)
    ck t2.lastFind.field("open") == "false"
    ck t2.lastFind.field("selection") == "0-0"

  test "Kakoune's / and CUA's Ctrl+F open it too":
    let dir = folder()
    defer: removeDir(dir)
    var tk, tc: string
    let k = windowPlan("key:/,type:area", tk, keymap = "kakoune", project = dir)
    ck k.widget.attr("data-ct-find-field") == "area"
    ck k.values(FindMatchAttribute).len == 2
    let c = windowPlan("key:f:control,type:perimeter", tc, keymap = "cua",
                       project = dir)
    ck c.widget.attr("data-ct-find-field") == "perimeter"
    ck c.values(FindMatchAttribute).len == 2
    ck c.values(FindCurrentAttribute).len == 1

  test "folder window highlights follow the open session in selection":
    # The open session's marks, not the closed session's: with lines 1 – 2
    # selected and Alt+L, only their `width`s are drawn — a closed session
    # would draw all four.
    let dir = folder()
    defer: removeDir(dir)
    let lines = FolderText.splitLines
    var t: string
    let plan = windowPlan("key:down:shift,key:down:shift,key:f:control," &
                          "key:l:alt,type:width", t, keymap = "cua",
                          project = dir)
    ck plan.widget.attr("data-ct-find-in-selection") == "on"
    let got = plan.values(FindMatchAttribute)
    let want = lines.marksOf(plan.drawnLines, "width",
                             MatchOptions(caseSensitive: false), only = @[1, 2])
    checkpoint($got & " vs " & $want)
    ck want.len == 2
    ck got == want

suite "OQ-F5 – OQ-F7 in GPUI: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
