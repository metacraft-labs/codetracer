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

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import gpui/chrome                # `contrastRatio`
import styles/contrast_floors     # `TabGroundContrastFloor`

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 97

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
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
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

suite "GPUI call trace: routed list keys and keyboard focus":

  const ListRows = """[
    {"key":"f6","command":"list.focus-first","when":"listFocus"},
    {"key":"f7","command":"list.focus-next","when":"listFocus"},
    {"key":"f8","command":"list.activate","when":"listFocus"}
  ]"""

  proc selectedCall(plan: JsonNode): string =
    for n in plan.nodesWith("data-call-selected"):
      if n.attr("data-call-selected") == "true":
        return n.attr("data-call-index")

  test "rebound list keys select the first and next calls, then activate":
    var t0, t1, t2: string
    # The second call begins at the initial source line. Step away first,
    # so activating it must visibly navigate back rather than be a no-op.
    let first = windowPlan("key:f10,click:tab:calltrace,key:f6", ListRows, t0)
    let next = windowPlan("key:f10,click:tab:calltrace,key:f6,key:f7", ListRows, t1)
    let activated = windowPlan("key:f10,click:tab:calltrace,key:f6,key:f7,key:f8",
                               ListRows, t2)
    let calls = first.values("data-call-index")
    ck calls.len >= 2
    ck t0.lines("operation ") == @["operation debugger.step-over",
                                   "operation list.focus-first"]
    ck first.selectedCall == calls[0]
    ck t1.lines("operation ") == @["operation debugger.step-over",
                                   "operation list.focus-first",
                                   "operation list.focus-next"]
    ck next.selectedCall == calls[1]
    ck t2.lines("operation ") == @["operation debugger.step-over",
      "operation list.focus-first",
      "operation list.focus-next", "operation list.activate"]
    ck "not available in this window" notin t2
    ck activated.executionLine != first.executionLine

  test "Alt+C transfers the element focus to the call trace":
    var t: string
    discard windowPlan("key:c:alt,key:f6", ListRows, t)
    ck t.lines("operation ")[0].startsWith("operation layout.focus-pane")
    ck t.lines("key F6 at ") ==
      @["key F6 at window:window / tab:tab:1 / pane:calltrace"]
    ck t.lines("operation ")[^1] == "operation list.focus-first"
    ck "not available in this window" notin t

  test "revealing a docked call trace leaves the keyboard with the editor":
    # The hover overlay is dismissed by Esc and the pane goes off screen, so
    # a key must not keep resolving in a pane nobody can see.
    var t: string
    discard windowPlan("dock:calltrace,key:c:alt,key:escape,key:f6", ListRows, t)
    let at = t.lines("key F6 at ")
    ck at.len == 1 and at[0].startsWith("key F6 at window:window / tab:tab:1 / pane:editor")
    ck "operation list.focus-first" notin t

  test "pressing an inactive tab transfers focus to its newly active pane":
    var t: string
    let plan = windowPlan("click:tab:agentActivity,click:tab:calltrace,key:f6", ListRows, t)
    ck t.lines("key F6 at ") ==
      @["key F6 at window:window / tab:tab:1 / pane:calltrace"]
    ck t.lines("operation ") == @["operation list.focus-first"]
    ck "not available in this window" notin t
    ck plan.selectedCall == plan.values("data-call-index")[0]

  test "list boundaries clamp and pages keep the selected call visible":
    var t0, t1, t2, t3, t4: string
    let first = windowPlan("click:tab:calltrace,key:home", trace = t0)
    let down = windowPlan("click:tab:calltrace,key:home,key:pagedown", trace = t1)
    let last = windowPlan("click:tab:calltrace,key:end,key:down", trace = t2)
    let up = windowPlan("click:tab:calltrace,key:end,key:pageup", trace = t3)
    let clamped = windowPlan("click:tab:calltrace,key:home,key:up", trace = t4)
    let firstRows = first.values("data-call-index")
    ck firstRows.len > 1
    ck down.selectedCall == $(firstRows.len - 1)
    ck last.selectedCall == last.values("data-call-index")[^1]
    ck parseInt(up.selectedCall) < parseInt(last.selectedCall)
    ck up.selectedCall in up.values("data-call-index")
    ck clamped.selectedCall == "0"

  test "the rest of the list table runs on the call trace":
    const TreeRows = """[
      {"key":"f6","command":"list.focus-first","when":"listFocus"},
      {"key":"f7","command":"list.focus-next","when":"listFocus"},
      {"key":"f2","command":"list.clear-selection","when":"listFocus"},
      {"key":"f3","command":"list.toggle-expand","when":"listFocus"},
      {"key":"f4","command":"list.expand","when":"listFocus"},
      {"key":"f8","command":"list.collapse","when":"listFocus"},
      {"key":"f9","command":"list.activate-redirected","when":"listFocus"}
    ]"""
    var t0, t1, t2, t3, t4, t5, t6: string
    let base = windowPlan("click:tab:calltrace,key:f6", TreeRows, t0)
    let cleared = windowPlan("click:tab:calltrace,key:f6,key:f2", TreeRows, t1)
    let toggled = windowPlan("click:tab:calltrace,key:f6,key:f3", TreeRows, t2)
    let expanded = windowPlan("click:tab:calltrace,key:f6,key:f3,key:f4", TreeRows, t3)
    let child = windowPlan("click:tab:calltrace,key:f6,key:f4", TreeRows, t4)
    let parent = windowPlan("click:tab:calltrace,key:f6,key:f4,key:f8", TreeRows, t5)
    let redirected = windowPlan("key:f10,click:tab:calltrace,key:f6,key:f7,key:f9",
                                TreeRows, t6)
    let rows = base.values("data-call-index")
    ck rows.len >= 2
    ck cleared.selectedCall == ""
    # The first call holds the rest of the trace: toggling it hides its
    # children, and expanding brings them back.
    ck toggled.values("data-call-index").len < rows.len
    ck expanded.values("data-call-index").len == rows.len
    ck child.selectedCall == rows[1]
    ck parent.selectedCall == rows[0]
    var t7: string
    let stepped = windowPlan("key:f10,click:tab:calltrace,key:f6", TreeRows, t7)
    ck redirected.executionLine != stepped.executionLine
    for t in [t1, t2, t3, t4, t5, t6]:
      ck "not available in this window" notin t
    # The default chord reaches the same arm, and another focused pane's press
    # leaves the call trace's selection alone and says it is not available.
    var t8, t9: string
    let escaped = windowPlan("click:tab:calltrace,key:home,key:escape", trace = t8)
    ck escaped.selectedCall == ""
    ck "operation list.clear-selection" in t8
    let elsewhere = windowPlan(
      "click:tab:calltrace,key:f6,click:tab:agentActivity,key:f2,click:tab:calltrace",
      TreeRows, t9)
    ck elsewhere.selectedCall == rows[0]
    ck "not available in this window" in t9

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
      # THE FLOOR AS `contrast_floors` DEFINES IT: the selected tab's ground
      # against the OTHER TABS' grounds on the same strip. Until 2026-10-17
      # the others were transparent over the strip's (focus) ground; since
      # the desktop-parity redesign every tab is an opaque chip of its own,
      # so each other tab's ground is read from the tab itself, and the
      # strip's only where the tab has none.
      var own = ""
      var others: seq[string] = @[]
      for tab in strip{"children"}.getElems:
        if tab.attr("data-ct-tab-active") == "true":
          own = tab{"styles"}{"bg"}.getStr
        elif tab.attr("data-ct-tab-active") == "false":
          let bg = tab{"styles"}{"bg"}.getStr
          others.add(if bg.len > 0: bg else: ground)
      checkpoint("focused strip " & ground & ", its active tab " & own &
                 ", the others " & $others)
      ck own.len > 0 and others.len > 0
      for other in others:
        ck contrastRatio(own, other) >= TabGroundContrastFloor
    ck focusedStrips == 1

suite "PLAT-68 GPUI: the program menu from the keyboard (CUA-Keymap.md §3.8)":
  # §3.8 binds the Alt tap (`menu.toggle`) and the `Alt+<mnemonic>` rows
  # (`menu.open-folder(...)`) on Linux and Windows only: "On macOS, as in VS
  # Code, there is neither — Option+<letter> types a character — and the
  # menu is the system's" (`cua_keymap.nim` declares both with
  # `platforms: {pkLinux, pkWindows}`). So each platform asserts its own
  # rule — macOS the ABSENCE of a menu operation, not a skip — and the two
  # arms make the same number of checks, so `ExpectedAssertions` holds on
  # both. `Alt+`` (`menu.open`, every platform) is asserted below for all.
  when not defined(macosx):
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
  else:
    test "on macOS an Alt tap reaches no menu operation; Alt+` still opens it":
      var t: string
      let plan = windowPlan("modifiers:alt,modifiers:", trace = t)
      # The window saw the tap, and no row turned it into an operation.
      ck t.lines("alt tapped").len == 1
      ck t.lines("operation menu.").len == 0
      ck plan.values("data-ct-menu-item").len == 0
      # The tap toggled nothing behind the scenes: `Alt+`` after it OPENS
      # the menu (were the tap a hidden `menu.toggle`, it would close it).
      var t2: string
      let opened = windowPlan("modifiers:alt,modifiers:,key:`:alt", trace = t2)
      ck t2.lines("operation ") == @["operation menu.open"]
      ck opened.values("data-ct-menu-item").len > 0

  test "after a second Alt tap the menu is closed (on macOS neither tap opens it)":
    var t: string
    let plan = windowPlan("modifiers:alt,modifiers:,modifiers:alt,modifiers:",
                          trace = t)
    ck t.lines("alt tapped").len == 2
    ck plan.values("data-ct-menu-item").len == 0

  when not defined(macosx):
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
  else:
    test "on macOS Option+D is no mnemonic: no menu folder opens":
      var t: string
      let plan = windowPlan("modifiers:alt,key:d:alt,modifiers:", trace = t)
      ck t.lines("alt tapped").len == 0
      ck t.lines("operation menu.").len == 0
      var active: seq[string] = @[]
      for n in plan.nodesWith("data-ct-menu-active"):
        if n.attr("data-ct-menu-active") == "true":
          active.add n.attr("data-ct-menu-item")
      ck active.len == 0

  test "Alt+` opens it too — the chord a terminal can send":
    var t: string
    let plan = windowPlan("key:`:alt", trace = t)
    ck t.lines("operation ") == @["operation menu.open"]
    ck plan.values("data-ct-menu-item").len > 0

suite "PLAT-68 GPUI: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
