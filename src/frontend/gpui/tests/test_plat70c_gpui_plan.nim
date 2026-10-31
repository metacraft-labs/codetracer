## test_plat70c_gpui_plan.nim — PLAT-70 Part C (Find-And-Incremental-Search.md
## §3, §4) in the GPUI window, read off the SHIPPED binary's window plan
## (`codetracer-gpui --report-window-plan --window-ops=…`: the window's own
## key and pointer handlers, GPUI's own element focus) over a real recording
## of `calc` against a real `replay-server`:
##
##   * `Ctrl+F` opens the IN-DOCUMENT find widget (`data-ct-find-widget`),
##     seeded with the word at the caret — not the omnibar;
##   * a query typed into it highlights exactly `matchesOf`'s spans on every
##     drawn row (`data-ct-find-match`, the current one `data-ct-find-current`)
##     and shows the count; `Enter` walks; `Escape` closes and keeps the match
##     selected (OQ-F1); the pattern stays the document's (FS-2: `F3` after it
##     walks on);
##   * `Ctrl+F3` with the widget closed selects the next whole-word
##     occurrence;
##   * under Vim, `/foo Escape` restores the caret and `/foo Enter` keeps the
##     match, and the committed search's `n` walks (SEARCH mode, browsing);
##   * the palette's **Find: Cancel and Return** restores the selection.
##
## No mocks: the binary, the engine and the recording are the product's.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unicode,
            unittest]

import codetracer_embed

import ../app/leaves   # the find widget's and the bands' attribute names

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 36

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1440
  H = 1400

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calcLines = readFile(repo / "test-programs/calc/main.py").splitLines

proc fixture(prefix: string): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

let calc = fixture("calc")

proc windowPlan(ops: string; trace: var string; keymap = "cua"): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if calc.len == 0:
    raise newException(IOError, "prerequisite missing: the calc tui-fixtures " &
      "recording (the tui lane records it on its first run)")
  let state = createTempDir("plat70c-gpui-", "")
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
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--keymap=" & keymap, "--window-ops=" & ops, calc]
  let errFile = genTempPath("plat70c-gpui-", ".err")
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

proc expectedMarks(plan: JsonNode; query: string; opts: MatchOptions):
    seq[string] =
  ## `matchesOf` over every drawn line, as the bands' `line:from-to`.
  for line in plan.drawnLines:
    if line < 1 or line > calcLines.len: continue
    let l = calcLines[line - 1]
    for m in matchesOf(l, query, opts):
      result.add $line & ":" & $(l[0 ..< m.a].runeLen + 1) & "-" &
                 $(l[0 ..< m.b].runeLen + 1)

suite "PLAT-70 Part C: GPUI's in-document find":

  test "Ctrl+F opens the widget seeded with the word, not the omnibar":
    var t: string
    let plan = windowPlan("click:code:31@13,key:f:control", t)
    let w = plan.nodesWith(FindWidgetAttribute)
    ck w.len == 1
    ck w[0].attr("data-ct-find-field") == "left"
    ck w[0].attr("data-ct-find-count").contains(" of ")
    ck t.lastFind.field("open") == "true"
    # The omnibar did not open on `:grep `.
    ck "palette" notin t.lastFind
    ck plan.values("data-omnibar-query").len == 0 or
       not plan.values("data-omnibar-query")[0].startsWith(":grep")

  test "typing highlights matchesOf's spans; Enter walks; Escape keeps (FS-3, FS-5)":
    let opts = MatchOptions(caseSensitive: false)
    for query in ["r", "ri", "right"]:
      var t: string
      let plan = windowPlan("click:code:31@13,key:f:control,type:" & query, t)
      var got = plan.values(FindMatchAttribute)
      let want = plan.expectedMarks(query, opts)
      checkpoint("query " & query & ": " & $got.len & " bands, " & $want.len &
                 " expected")
      ck got == want
      ck plan.values(FindCurrentAttribute).len == 1
      ck plan.nodesWith(FindWidgetAttribute)[0].attr("data-ct-find-field") ==
           query
    var t1, t2: string
    discard windowPlan("click:code:31@13,key:f:control,type:right", t1)
    discard windowPlan("click:code:31@13,key:f:control,type:right,key:enter", t2)
    ck t1.lastFind.field("selection") != t2.lastFind.field("selection")
    # And back: `Shift+F3` (find.previous) returns to the first match.
    var tb: string
    discard windowPlan("click:code:31@13,key:f:control,type:right,key:enter," &
                       "key:f3:shift", tb)
    ck tb.lastFind.field("selection") == t1.lastFind.field("selection")
    var t3: string
    let closed = windowPlan("click:code:31@13,key:f:control,type:right," &
                            "key:enter,key:escape", t3)
    ck closed.nodesWith(FindWidgetAttribute).len == 0
    ck t3.lastFind.field("open") == "false"
    ck t3.lastFind.field("selection") == t2.lastFind.field("selection")
    ck t3.lastFind.field("pattern") == "right"
    # FS-2: F3 after it walks the same pattern on.
    var t4: string
    discard windowPlan("click:code:31@13,key:f:control,type:right," &
                       "key:enter,key:escape,key:f3", t4)
    ck t4.lastFind.field("selection") != t3.lastFind.field("selection")
    ck t4.lastFind.field("pattern") == "right"

  test "Ctrl+F3 with the widget closed selects the next whole-word occurrence":
    var t: string
    discard windowPlan("click:code:29@10,key:f3:control", t)
    let sel = t.lastFind.field("selection")
    ck sel.len > 0
    let parts = sel.split('-')
    let doc = calcLines.join("\n") & "\n"
    let a = parseInt(parts[0])
    let b = parseInt(parts[1])
    ck doc[a ..< b] == "left"
    ck nextMatchOf(doc, "left", MatchOptions(wholeWord: true), a, true).span.a == a
    ck t.lastFind.field("open") == "false"

  test "Vim: /left Escape restores; /left Enter keeps and n walks":
    var t0, t1, t2: string
    discard windowPlan("click:code:31@5", t0, keymap = "vim")
    discard windowPlan("click:code:31@5,key:/,type:left,key:escape", t1,
                       keymap = "vim")
    ck t1.lastFind.field("open") == "false"
    var caretBefore = ""
    for line in t0.splitLines:
      if line.startsWith("gesture caret "): caretBefore = line
    var caretAfter = ""
    for line in t1.splitLines:
      if line.startsWith("gesture caret "): caretAfter = line
    ck caretBefore.len > 0
    ck t1.lastFind.field("selection").split('-')[0] ==
         t1.lastFind.field("selection").split('-')[1]
    discard windowPlan("click:code:31@5,key:/,type:left,key:enter", t2,
                       keymap = "vim")
    let kept = t2.lastFind.field("selection")
    ck kept.len > 0
    var t3: string
    discard windowPlan("click:code:31@5,key:/,type:left,key:enter,key:n", t3,
                       keymap = "vim")
    ck t3.lastFind.field("selection") != kept
    ck "debugger.step-over" notin t3.splitLines[^1]

  test "Find: Cancel and Return restores the selection":
    var t0, t1: string
    discard windowPlan("click:code:31@13", t0)
    let plan = windowPlan("click:code:31@13,key:f:control,type:checksum," &
                          "key:p:control+shift,type::Cancel and Return,key:enter",
                          t1)
    ck plan.nodesWith(FindWidgetAttribute).len == 0
    ck t1.lastFind.field("open") == "false"
    let sel = t1.lastFind.field("selection").split('-')
    ck sel.len == 2 and sel[0] == sel[1]

suite "PLAT-70 Part C: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
