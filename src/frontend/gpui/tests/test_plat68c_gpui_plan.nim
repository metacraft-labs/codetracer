## test_plat68c_gpui_plan.nim — PLAT-68's real-stack boxes in the GPUI
## window, read off the SHIPPED binary's window plan (`codetracer-gpui
## --report-window-plan --window-ops=…`: the window's own key and pointer
## handlers, GPUI's own element focus) over a real recording and a real
## `replay-server`. The terminal's half is `test_plat68c_pty.nim`; both assert
## the same execution lines for the same keys, so the two front-ends are held
## to one answer.
##
##   * DEBUG MODE'S F-KEYS are the desktop's (CUA-Keymap.md §4): `F10` step
##     over, `Shift+F10` back, `F11` step into, `F12` step out — and `F12` in
##     Edit mode steps nothing and SAYS SO on the status bar (Mode-Transitions
##     §8.1: a key inert in this product mode says what it does and where);
##   * THE LETTERS (OQ-1, Base-Keymaps §10.1): `n` steps and `p` steps back
##     while the read-only editor has the focus; `n` steps in the call trace;
##     once `Ctrl+E` makes the document writable `n` is typed and the pointer
##     stays, and after a second `Ctrl+E` `n` steps again; in the find field
##     (`Ctrl+F` — GPUI's find is the omnibar's) `n` is typed into the query;
##   * VS CODE'S PRECEDENCE (KL-11): two user rows for one chord in one scope —
##     the later fires, and swapping them in the file swaps the result;
##   * THE SHORTCUT REFERENCE (§5.4, §5.6): `Ctrl+K Ctrl+S` shows every binding
##     live where the focus is, layer by layer; a user row with no `when` that
##     takes `Enter` from the call trace's base row is listed as shadowing it.
##
## The editor's find widget as a pushed layer owned by the editor is the
## terminal's (`test_plat68c_pty.nim`): GPUI's find is the omnibar, a
## window-owned layer, so "Escape in another pane leaves it open" has nothing
## to say here.
##
## No mocks: the binary, the engine and the recording are the product's; the
## user keymap is a real file the binary reads.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 35

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1440
  H = 1400
  StartLine = 1
  OverLine = 2
    ## calc's execution line at the recording's start and after one step
    ## over — the same lines `test_plat68c_pty.nim` reads off the terminal
    ## for the same keys.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc fixture(prefix: string): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

let calc = fixture("calc")

proc windowPlan(ops: string; keybindings = ""; trace: var string;
                project = ""): JsonNode =
  ## The window's plan after `ops`: over the calc recording, or — `project`
  ## given — an Edit window (`--edit`) over that folder.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if calc.len == 0:
    raise newException(IOError, "prerequisite missing: the calc tui-fixtures " &
      "recording (the tui lane records it on its first run)")
  let state = createTempDir("plat68c-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  if keybindings.len > 0:
    writeFile(state / "keybindings.json", keybindings)
  let args = (if project.len > 0: @["--edit"] else: @[]) &
             @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, (if project.len > 0: project else: calc)]
  let errFile = genTempPath("plat68c-gpui-", ".err")
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

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc lines(trace, prefix: string): seq[string] =
  ## The gesture trace's lines that start with `prefix` (after `gesture `).
  for line in trace.splitLines:
    if line.startsWith("gesture " & prefix):
      result.add line["gesture ".len .. ^1]

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith("data-ct-pointer"):
    if n.attr("data-ct-pointer") == "eptExecution":
      return parseInt(n.attr("data-ct-row"))
  -1

proc shownLine(plan: JsonNode; line: int): string =
  for n in plan.nodesWith("data-ct-row"):
    if n.attr("data-ct-row") == $line: return n.textOf
  ""

proc lineAfter(ops: string): int =
  var t: string
  windowPlan(ops, trace = t).executionLine

suite "PLAT-68 GPUI: Debug mode's F-keys are the desktop's (CUA-Keymap.md §4)":

  test "F10, Shift+F10, F11 and F12 step over, back, into and out":
    var t: string
    discard windowPlan("key:f10,key:f10:shift,key:f11,key:f12", trace = t)
    ck t.lines("operation ") == @["operation debugger.step-over",
                                  "operation debugger.reverse-step-over",
                                  "operation debugger.step-into",
                                  "operation debugger.step-out"]
    let start = lineAfter("wait:1")
    let over = lineAfter("key:f10")
    ck start == StartLine
    ck over == OverLine
    ck lineAfter("key:f10,key:f10:shift") == start

  test "F12 in Edit mode steps nothing, and the window says why":
    # An Edit window over a copy of calc's program folder.
    let project = createTempDir("plat68c-edit-", "")
    defer: removeDir(project)
    copyFile(repo / "test-programs/calc/main.py", project / "main.py")
    var t: string
    let plan = windowPlan("key:f12", trace = t, project = project)
    ck t.lines("operation ").len == 0
    let inert = t.lines("inert ")
    ck inert.len == 1
    if inert.len == 1:
      ck "debugger.step-out" in inert[0] and "replay session" in inert[0]
      # The Edit window's status surface is its editor's notice.
      let notes = plan.values("data-ct-editor-notice")
      ck notes == @[inert[0]["inert ".len .. ^1]]
    # The document took nothing.
    ck readFile(project / "main.py") == readFile(repo / "test-programs/calc/main.py")

  test "Ctrl+S in a replay saves nothing, and the status bar says why":
    var t: string
    let plan = windowPlan("key:s:control", trace = t)
    ck t.lines("operation ").len == 0
    let inert = t.lines("inert ")
    ck inert.len == 1
    if inert.len == 1:
      ck "`save`" in inert[0] and "editing session" in inert[0]
      ck plan.values("data-ct-footer-note") == @[inert[0]["inert ".len .. ^1]]

suite "PLAT-68 GPUI: the letters under CUA (OQ-1)":

  test "the read-only editor: n steps, p steps back":
    let start = lineAfter("wait:1")
    let n = lineAfter("key:n")
    ck start == StartLine
    ck n == OverLine
    ck lineAfter("key:n,key:p") == start

  test "the call trace: n steps":
    var t: string
    let plan = windowPlan("click:tab:calltrace,key:n", trace = t)
    ck t.lines("operation ") == @["operation debugger.step-over"]
    ck plan.executionLine == lineAfter("key:n")

  test "writable, n is typed and the pointer stays; read-only again, n steps":
    # A writable document is drawn as Edit mode draws one, with no execution
    # pointer; made read-only again, the pointer is drawn where it was — the
    # typed `n` stepped nothing — and the `n` is in the document.
    var t0, t: string
    let typed = windowPlan("click:code:31@5,key:e:control,key:n", trace = t0)
    ck "nreturn left + right" in typed.shownLine(31)
    let back = windowPlan("click:code:31@5,key:e:control,key:n,key:e:control",
                          trace = t)
    ck t.lines("operation debugger.").len == 0
    ck back.executionLine == StartLine
    var t2: string
    let again = windowPlan("click:code:31@5,key:e:control,key:n,key:e:control," &
                           "key:n", trace = t2)
    ck t2.lines("operation debugger.") == @["operation debugger.step-over"]
    ck again.executionLine == OverLine

  test "the find field: n is typed into the query":
    var t: string
    let plan = windowPlan("key:f:control,key:n", trace = t)
    ck t.lines("operation debugger.").len == 0
    ck "query=:grep n" in t
    ck plan.executionLine == lineAfter("wait:1")

suite "PLAT-68 GPUI: VS Code's precedence through input (KL-11)":

  const RowA = """{ "key": "ctrl+alt+u", "command": "debugger.step-over" }"""
  const RowB = """{ "key": "ctrl+alt+u", "command": "debugger.step-into" }"""

  test "two user rows for one chord in one scope: the later fires, in both orders":
    var t1, t2: string
    discard windowPlan("key:u:control+alt",
                       keybindings = "[" & RowA & "," & RowB & "]", trace = t1)
    discard windowPlan("key:u:control+alt",
                       keybindings = "[" & RowB & "," & RowA & "]", trace = t2)
    ck t1.lines("operation ") == @["operation debugger.step-into"]
    ck t2.lines("operation ") == @["operation debugger.step-over"]

suite "PLAT-68 GPUI: the shortcut reference (Base-Keymaps §5.4, §5.6)":

  const EnterRow = """[ { "key": "enter", "command": "debugger.continue" } ]"""

  test "a user row with no `when` takes Enter from the call trace, and the reference lists the shadow":
    var t: string
    discard windowPlan("click:tab:calltrace,key:enter", keybindings = EnterRow,
                       trace = t)
    ck t.lines("operation ") == @["operation debugger.continue"]
    var t2: string
    let plan = windowPlan("click:tab:calltrace,key:k:control,key:s:control",
                          keybindings = EnterRow, trace = t2)
    ck t2.lines("operation ") == @["operation help.keyboard-shortcuts"]
    let shown = plan.values("data-ct-event-content")
    ck shown.len == 1 and shown[0].startsWith("Keyboard shortcuts — CUA at ")
    var listed: seq[string] = @[]
    for n in plan.nodesWith("data-ct-content-line"):
      listed.add n.textOf
    checkpoint(listed.join("\n"))
    # The user's layer leads, its Enter row first; the base's list row is
    # marked with the user row that shadows it.
    ck listed.len > 0 and listed[0] == "[user:global]"
    var shadowed = false
    for l in listed:
      if l.startsWith("  Enter  list.activate") and
         l.endsWith("(shadowed by your row 1)"):
        shadowed = true
    ck shadowed

  test "the omnibox's `:keys reference` opens it too":
    var t: string
    let plan = windowPlan("key:p:control,key:colon,type:keys reference,key:enter",
                          trace = t)
    let shown = plan.values("data-ct-event-content")
    ck shown.len == 1 and shown[0].startsWith("Keyboard shortcuts — CUA at ")
    ck plan.nodesWith("data-ct-content-line").len > 0

suite "PLAT-68 GPUI: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
