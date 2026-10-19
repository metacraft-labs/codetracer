## test_plat68_gpui_keys_plan.nim — PLAT-68 Phase B in the GPUI window: the
## window's keys resolve through the ONE router every front-end runs, read
## off the SHIPPED binary's window plan (`codetracer-gpui --report-window-plan
## --window-ops=…`: the window's own key and pointer handlers, GPUI's own
## element focus) over a real recording and a real `replay-server`.
##
##   * Debug mode's F-keys step (`F10` is `debugger.step-over`), and so do the
##     LETTERS while the read-only editor or a list pane has the focus;
##   * the scope path is read off GPUI's focus chain (`data-scope-kind` /
##     `data-scope-id` on the window, the tab container and the panes);
##   * the read-only editor's document: Shift+motions SELECT, the selection is
##     drawn (`data-ct-selection`), `Ctrl+C` copies it to GPUI's clipboard,
##     a pointer DRAG selects, Home is smart (first non-blank, then column
##     1, then back), edits are refused until `Ctrl+E`;
##   * `Enter` in the read-only editor opens the tracepoint editor on the
##     caret's line (the desktop's `Editor.TracepointCreation`);
##   * the palette and the right-click menu are pushed layers: their keys
##     resolve there while they are open;
##   * the user's `keybindings.json` (`CODETRACER_KEYBINDINGS`) is laid over
##     the base: a user row beats a base row (KL-11), a `-` row removes one.
##
## No mocks: the binary, the engine and the recording are the product's; the
## user keymap is a real file the binary reads.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import gpui/chrome                # `contrastRatio`
import styles/contrast_floors     # `TabGroundContrastFloor`

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 57

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

proc fixture(prefix: string): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

let calc = fixture("calc")

proc windowPlan(ops: string; keybindings = ""; trace: var string): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if calc.len == 0:
    raise newException(IOError, "prerequisite missing: the calc tui-fixtures " &
      "recording (the tui lane records it on its first run)")
  let state = createTempDir("plat68-gpui-keys-", "")
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
  # The user keymap: this case's own file (absent unless the case wrote one).
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  if keybindings.len > 0:
    writeFile(state / "keybindings.json", keybindings)
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, calc]
  let errFile = genTempPath("plat68-gpui-keys-", ".err")
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

suite "PLAT-68 GPUI: Debug-mode stepping through the router":

  test "F10 is debugger.step-over, and the execution line moves":
    var t0, t1: string
    let before = windowPlan("wait:1", trace = t0)
    let after = windowPlan("key:f10", trace = t1)
    ck t1.lines("operation ") == @["operation debugger.step-over"]
    ck t1.lines("control next").len == 1
    ck after.executionLine != before.executionLine

  test "a letter steps while the read-only editor has the focus":
    var t: string
    discard windowPlan("key:n", trace = t)
    # The key arrived with the editor's document on the scope path.
    ck t.lines("key n at ").len == 1
    ck t.lines("key n at ")[0].startsWith(
      "key n at window:window / tab:tab:1 / pane:editor / editor:editor:")
    ck t.lines("key n at ")[0].endsWith("/calc/main.py")
    ck t.lines("operation ") == @["operation debugger.step-over"]

  test "a letter steps while a list pane has the focus (the focus chain says so)":
    var t: string
    discard windowPlan("click:tab:calltrace,key:s", trace = t)
    let at = t.lines("key s at ")
    ck at.len == 1
    ck at[0].endsWith("pane:calltrace")
    ck at[0] == "key s at window:window / tab:tab:1 / pane:calltrace"
    ck t.lines("operation ") == @["operation debugger.step-into"]

suite "PLAT-68 GPUI: the read-only editor's document":

  test "Shift+Down selects, the selection is drawn, Ctrl+C copies it":
    var t: string
    let plan = windowPlan("key:down:shift,key:down:shift,key:c:control",
                          trace = t)
    ck plan.values("data-ct-selection") == @["1:1-24", "2:1-84"]
    ck plan.values("data-ct-caret") == @["3:1"]
    ck t.lines("operation clipboard-copy").len == 1
    let copied = t.lines("copied ")
    ck copied.len == 1 and copied[0].startsWith("copied 3 line(s): #!/usr/bin")

  test "a pointer drag over the text selects, and the selection copies":
    var t: string
    let plan = windowPlan("select:31@5:31@12,key:c:control", trace = t)
    ck plan.values("data-ct-selection") == @["31:5-12"]
    let copied = t.lines("copied ")
    ck copied.len == 1 and copied[0].endsWith(": return")

  test "Home is smart: the first non-blank, then column 1, then back":
    var t: string
    discard windowPlan("click:code:31@10,key:home,key:home,key:home", trace = t)
    ck t.lines("caret ") == @["caret 31:10", "caret 31:5", "caret 31:1",
                              "caret 31:5"]

  test "an edit is refused while read-only; Ctrl+E makes the document writable":
    var t0, t1: string
    discard windowPlan("click:code:31@5,key:x", trace = t0)
    # Unbound in a read-only editor: no character, no caret move.
    ck t0.lines("caret ") == @["caret 31:5"]
    let plan = windowPlan("click:code:31@5,key:e:control,key:x", trace = t1)
    ck t1.lines("the editor is writable").len == 1
    ck t1.lines("caret ")[^1] == "caret 31:6"
    # The writable document is what the editor draws: the typed `x` is on
    # line 31.
    var shown = ""
    for n in plan.nodesWith("data-ct-row"):
      if n.attr("data-ct-row") == "31": shown = n.textOf
    ck "xreturn left + right" in shown

  test "Enter opens the tracepoint editor on the caret's line":
    var t: string
    let plan = windowPlan("click:code:31@5,key:enter", trace = t)
    ck t.lines("operation ") == @["operation editor.toggle-tracepoint"]
    ck t.lines("tracepoint editor at ") == @["tracepoint editor at 31"]
    ck plan.values("data-ct-omnibar").len > 0 and
       plan.values("data-ct-omnibar")[0] == "true"

suite "PLAT-68 GPUI: the overlays are pushed layers":

  test "the palette: Ctrl+P opens it, characters are its, Esc closes it":
    var t: string
    discard windowPlan("key:p:control,key:a,key:b", trace = t)
    ck t.lines("operation ") == @["operation palette.quick-open-file"]
    ck t.lines("key a at ")[0].endsWith("overlay:palette / input:palette-query")
    ck "omnibar=true query=ab" in t
    var t2: string
    let closed = windowPlan("key:p:control,key:a,key:escape", trace = t2)
    ck t2.lines("operation ")[^1] == "operation palette.close"
    ck closed.values("data-ct-omnibar") == @["false"]

  test "the right-click menu: its keys while open, Esc closes it":
    var t: string
    let plan = windowPlan("click:code:31@5:right,key:down,key:escape",
                          trace = t)
    ck "operation context-menu.focus-next" in t.lines("operation ")
    ck "operation context-menu.close" in t.lines("operation ")
    ck plan.nodesWith("data-ct-context-entry").len == 0

suite "PLAT-68 GPUI: the user's keybindings.json over the base":

  const UserRows = """// a user keymap, JSONC as VS Code writes it
  [
    { "key": "ctrl+alt+n", "command": "debugger.step-over" },
    { "key": "f10", "command": "-debugger.step-over" },
    { "key": "n", "command": "debugger.step-into",
      "when": "editorReadOnly && productMode == debug" },
  ]
  """

  test "a user row adds a chord; a removal row takes the base's away":
    var t: string
    discard windowPlan("key:n:control+alt,key:f10", keybindings = UserRows,
                       trace = t)
    ck t.lines("operation ") == @["operation debugger.step-over"]
    ck t.lines("control next").len == 1

  test "a user row beats the base row for the same key (KL-11)":
    var t: string
    discard windowPlan("key:n", keybindings = UserRows, trace = t)
    ck t.lines("operation ") == @["operation debugger.step-into"]

  test "the controls' tooltips show the router's chord, the user's included":
    var t: string
    let plan = windowPlan("control:next", keybindings = UserRows, trace = t)
    let labels = plan.values("data-ct-hover-label")
    ck labels.len == 1
    ck "Ctrl+Alt+N" in labels[0] or "ctrl+alt+n" in labels[0]
    ck "F10" notin labels[0]

  test "an unreadable file is said, and the base still runs":
    var t: string
    discard windowPlan("key:f10", keybindings = "[ { \"key\": ", trace = t)
    ck t.lines("keybindings: ").len >= 1
    ck t.lines("operation ") == @["operation debugger.step-over"]

suite "PLAT-68 GPUI: the focused strip's selected tab is told apart":

  test "its ground differs from the other tabs' by the contrast floor":
    var t: string
    # The editor's strip is focused at open; the State strip once pressed.
    let plan = windowPlan("click:tab:state", trace = t)
    var focusedStrips = 0
    for strip in plan.nodesWith("data-ct-strip-focused"):
      if strip.attr("data-ct-strip-focused") != "true": continue
      inc focusedStrips
      let ground = strip{"styles"}{"bg"}.getStr
      for tab in strip{"children"}.getElems:
        if tab.attr("data-ct-tab-active") == "true":
          let own = tab{"styles"}{"bg"}.getStr
          checkpoint("focused strip " & ground & ", its active tab " & own)
          ck own.len > 0 and own != ground
          ck contrastRatio(own, ground) >= TabGroundContrastFloor
        elif tab.attr("data-ct-tab-active") == "false":
          # The others sit on the strip's own (focus) ground.
          ck tab{"styles"}{"bg"}.getStr in ["", ground]
    ck focusedStrips == 1

suite "PLAT-68 GPUI: the program menu from the keyboard (CUA-Keymap.md §3.8)":

  test "Alt pressed and released alone opens the menu, its mnemonics underlined":
    var t: string
    let plan = windowPlan("modifiers:alt,modifiers:", trace = t)
    ck t.lines("alt tapped").len == 1
    ck t.lines("operation ") == @["operation menu.toggle"]
    ck plan.values("data-ct-menu-item").len > 0
    # Every shown folder's access key, as the span that underlines it — the
    # letter, and the underline itself.
    ck plan.values("data-ct-menu-mnemonic") ==
       @["F", "i", "w", "B", "R", "D", "H"]
    var underlined = 0
    for span in plan.nodesWith("data-ct-menu-mnemonic"):
      if span{"styles"}{"text_decoration"}.getStr == "underline":
        inc underlined
    ck underlined == 7

  test "a second Alt tap closes it":
    var t: string
    let plan = windowPlan("modifiers:alt,modifiers:,modifiers:alt,modifiers:",
                          trace = t)
    ck t.lines("alt tapped").len == 2
    ck plan.values("data-ct-menu-item").len == 0

  test "Alt+D opens Debug; the release that follows is not a tap":
    var t: string
    let plan = windowPlan("modifiers:alt,key:d:alt,modifiers:", trace = t)
    ck t.lines("alt tapped").len == 0
    ck t.lines("operation ") == @["operation menu.open-folder(debug)"]
    var active: seq[string] = @[]
    for n in plan.nodesWith("data-ct-menu-active"):
      if n.attr("data-ct-menu-active") == "true":
        active.add n.attr("data-ct-menu-item")
    ck "Debug" in active

  test "Alt+` opens it too — the chord a terminal can send":
    var t: string
    let plan = windowPlan("key:`:alt", trace = t)
    ck t.lines("operation ") == @["operation menu.open"]
    ck plan.values("data-ct-menu-item").len > 0

suite "PLAT-68 GPUI: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
