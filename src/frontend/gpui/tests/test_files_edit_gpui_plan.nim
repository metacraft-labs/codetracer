## test_files_edit_gpui_plan.nim — the Files pane in GPUI's Edit mode: the
## opened folder's tree, and its right-click menu acting on the disk, read
## from the SHIPPED `codetracer-gpui --edit`'s window plan
## (`--report-window-plan --window-ops=…`: the window's own root builder, its
## own pointer and key handlers) over a real temporary folder.
##
## codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "In the terminal
## and GPUI": GPUI's Edit mode draws the opened folder as a tree from the
## shared Files model (`projectTreeOf` over the project walk), its menu is the
## model's, Create, Rename and Delete act on the disk by the index process's
## rules (`native_file_tree`), the name is typed into an inline field, and
## Delete asks first. Each case is one or more runs of the binary; the folder
## on disk is what the runs share, so a case reads the disk after a run as
## well as the plan:
##
##   * the leaf plan (`--report-plan`) and the window list the folder's row,
##     its folder and its files, and no pane is "a DEBUG-mode pane";
##   * Find in Files, which Edit mode docks, searches the opened folder;
##   * a click on a file opens it in the editor, and the first file's unsaved
##     buffer is still there when it is opened again;
##   * a file's menu: the four entries, all enabled; the folder's own row:
##     Rename and Delete disabled with the reason drawn;
##   * Create: the field under the folder, a taken name refused with the
##     reason and nothing overwritten, a free one created empty, listed and
##     opened, the outcome as the editor's notice;
##   * Rename: the field holds the current name; the file is renamed on disk;
##   * Delete: the question drawn; Escape keeps the file; Enter moves it into
##     a freedesktop.org trash in a temporary directory (`XDG_DATA_HOME`),
##     with its info file;
##   * a press elsewhere (the editor) cancels an open field;
##   * a folder tab opened from a replay window's Welcome screen lists the
##     same tree, and its menu acts on the disk too.
##
## No mocks: the binary, the folder, the trash and (for the folder tab) the
## engine and the recording are real. `XDG_DATA_HOME` points the trash at a
## temporary directory so a run never touches the user's.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
            unittest]
import ./gpui_child_env

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 64

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1440
  H = 1000
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  OpenedFolderRowReason = "The opened folder cannot be renamed or deleted " &
                          "from the tree"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc run(args: seq[string]; dataHome: string; trace: var string): JsonNode =
  ## The shipped binary's plan for `args`, its gesture trace in `trace`.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("files-edit-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["XDG_DATA_HOME"] = dataHome
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("files-edit-gpui-", ".err")
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
    raise newException(IOError, "the plan run failed: " & args.join(" "))
  result = parseJson(output)
  proc sweep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and fileExists(src):
        try: removeDir(src.parentDir)
        except OSError: discard
    for c in n{"children"}.getElems: sweep(c)
  sweep(result)

proc editWindow(project, dataHome, ops: string; trace: var string): JsonNode =
  ## The Edit window over `project` after `ops`.
  var args = @["--edit", "--report-window-plan", "--width=" & $W,
               "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add project
  run(args, dataHome, trace)

proc editWindow(project, dataHome, ops: string): JsonNode =
  var t = ""
  editWindow(project, dataHome, ops, t)

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

proc treeRows(plan: JsonNode): seq[(string, string)] =
  ## The Files pane's rows, in order: (the row's id, its text).
  proc walk(n: JsonNode; acc: var seq[(string, string)]) =
    if n.kind != JObject: return
    if n.attr("data-view-kind") == "Tree" and
       n.attr("data-view-id").startsWith("fileTree"):
      acc.add (n.attr("data-view-id"), n.textOf)
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc rowId(plan: JsonNode; name: string): string =
  ## The id of the Files row named `name` ("" when there is none).
  for (id, text) in plan.treeRows:
    if text == name: return id
  ""

proc menuEntries(plan: JsonNode): seq[(string, string)] =
  for n in plan.nodesWith("data-ct-context-entry"):
    result.add (n.attr("data-ct-context-entry"),
                n.attr("data-ct-context-enabled"))

proc field(plan: JsonNode): tuple[kind, text: string] =
  for n in plan.nodesWith("data-ct-files-field"):
    return (n.attr("data-ct-files-field"), n.attr("data-ct-files-field-text"))

proc tabsText(plan: JsonNode): string =
  for n in plan.nodesWith("data-ct-tabs"):
    result.add n.attr("data-ct-tabs") & "|"

proc openSrc(project, dataHome: string):
    tuple[ops: string; plan: JsonNode] =
  ## The ops that open the `src` folder, and the window after them (the
  ## rows' ids are read from it).
  let src = editWindow(project, dataHome, "").rowId("src")
  result.ops = "click:file:" & src & ":left,"
  result.plan = editWindow(project, dataHome, "click:file:" & src & ":left")

proc newProject(): string =
  ## A real folder: a file at its root, one in a folder.
  result = createTempDir("files-edit-gpui-project-", "")
  writeFile(result / "README.md", "# readme\n")
  createDir(result / "src")
  writeFile(result / "src" / "main.py", "print('main')\n")
  writeFile(result / "src" / "util.py", "def util():\n    return 1\n")

suite "GPUI Edit mode: the opened folder's tree":

  test "the leaf plan and the window list the folder, its folder and files":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    var t = ""
    let leaf = run(@["--edit", "--report-plan", project], data, t)
    # The Files pane itself is live in Edit mode, and Find in Files — which
    # Edit mode docks in its footer since ecc2b02de7 — is not the DEBUG-mode
    # placeholder: it searches the opened folder (codetracer-pm issue
    # 2026-10-27). The Requests pane, docked there too since the native
    # Requests pane landed, is still that placeholder; it is a recording's
    # content and its Edit-mode answer is open (codetracer-pm issue
    # 2026-10-29, "gpui edit mode docks the requests pane as the debug mode
    # placeholder"), so it is checkpointed here rather than asserted.
    var filesStates: seq[string] = @[]
    var placeholders: seq[string] = @[]
    for n in leaf.nodesWith("data-ct-pane"):
      if n.attr("data-ct-pane") == "fileTree":
        filesStates.add n.attr("data-ct-state")
      if n.attr("data-ct-state") == "not-launched":
        placeholders.add n.attr("data-ct-pane")
    checkpoint("Edit-mode placeholders: " & $placeholders)
    ck filesStates == @["live"]
    ck "search" notin placeholders and "fileTree" notin placeholders
    ck placeholders.len == 0 or placeholders == @["requests"]
    let names = block:
      var s: seq[string] = @[]
      for (_, text) in leaf.treeRows: s.add text
      s
    # The folder's own row open, its folders closed (the desktop's tree).
    ck names == @[project.extractFilename, "README.md", "src"]
    let win = editWindow(project, data, "")
    let src = win.rowId("src")
    ck win.rowId("README.md").len > 0 and src.len > 0
    # A click on a folder opens it.
    let opened = editWindow(project, data, "click:file:" & src & ":left")
    var shown: seq[string] = @[]
    for (_, text) in opened.treeRows: shown.add text
    ck shown == @[project.extractFilename, "README.md", "src", "main.py",
                  "util.py"]
    ck not win.textOf.contains("a DEBUG-mode pane")
    removeDir(project)
    removeDir(data)

  test "a click opens a file; the first file's unsaved buffer is kept":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let (o, plan0) = openSrc(project, data)
    let util = plan0.rowId("util.py")
    let readme = plan0.rowId("README.md")
    var t = ""
    # The window opens on the first file (README.md); a typed key dirties it,
    # util.py is opened, then README.md again.
    let opened = editWindow(project, data, o & "key:x,click:file:" & util &
                            ":left", t)
    ck opened.textOf.contains("def util():")
    ck opened.tabsText.contains("util.py")
    ck t.contains("editing src/util.py")
    let back = editWindow(project, data, o & "key:x,click:file:" & util &
                          ":left,click:file:" & readme & ":left")
    ck back.tabsText.contains("README.md ●")
    # Nothing was written: the buffer is unsaved.
    ck readFile(project / "README.md") == "# readme\n"
    removeDir(project)
    removeDir(data)

suite "GPUI Edit mode: Find in Files searches the opened folder":

  test "`:grep` lists the folder's matching lines, grouped by file":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    # `Ctrl+Shift+F` opens the omnibox on `:grep ` (§5.2); the pattern is
    # on one line of one file.
    let plan = editWindow(project, data,
      "key:f:control+shift,type:print('main'),key:enter,wait:10000")
    var states: seq[string] = @[]
    for n in plan.nodesWith("data-ct-pane"):
      if n.attr("data-ct-pane") == "search":
        states.add n.attr("data-ct-state")
    ck states.len > 0 and "not-launched" notin states
    let pane = plan.nodesWith("data-ct-search")
    ck pane.len == 1 and pane[0].attr("data-ct-search") == "print('main')"
    var rows: seq[(string, string)] = @[]
    var file = ""
    proc walk(n: JsonNode) =
      if n.kind != JObject: return
      if n.has("data-ct-search-file"):
        file = n.attr("data-ct-search-file")
      elif n.has("data-ct-search-row"):
        rows.add (file, n.attr("data-ct-search-line"))
      for c in n{"children"}.getElems: walk(c)
    walk(plan)
    checkpoint("rows: " & $rows)
    ck rows.len == 1 and rows[0][0].endsWith("src/main.py") and
       rows[0][1] == "1"
    # F4 opens the result in the Edit window's editor, from the disk.
    var t = ""
    let opened = editWindow(project, data,
      "key:f:control+shift,type:print('main'),key:enter,wait:10000,key:f4", t)
    ck opened.tabsText.contains("main.py")
    ck t.contains("opened ") and t.contains("main.py:1")
    removeDir(project)
    removeDir(data)

suite "GPUI Edit mode: the Files menu acts on the disk":

  test "a file's menu: four entries, all enabled; the folder's row is not renamed":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let (o, plan0) = openSrc(project, data)
    let main = plan0.rowId("main.py")
    let root = plan0.rowId(project.extractFilename)
    ck root == "fileTree"
    let menu = editWindow(project, data, o & "click:file:" & main & ":right")
    ck menu.menuEntries == @[("Create", "true"), ("Rename", "true"),
                             ("Delete", "true"), ("Edit", "true")]
    let boxes = menu.nodesWith("data-ct-context-menu")
    ck boxes.len == 1 and boxes[0].attr("data-ct-context-menu") ==
      "file-tree-node"
    let top = editWindow(project, data, "click:file:" & root & ":right")
    ck top.menuEntries == @[("Create", "true"), ("Rename", "false"),
                            ("Delete", "false"), ("Edit", "false")]
    var drawn = 0
    for n in top.nodesWith("data-ct-context-entry"):
      if n.textOf.contains(OpenedFolderRowReason): inc drawn
    ck drawn == 2
    # A disabled entry runs nothing: the menu stays open, the reason said.
    var t = ""
    let inert = editWindow(project, data, "click:file:" & root &
                           ":right,ctx:Delete", t)
    ck inert.menuEntries.len == 4
    # Escape closes the menu (the Edit window has no top bar to route it).
    let closed = editWindow(project, data, "click:file:" & root &
                            ":right,key:escape")
    ck closed.menuEntries.len == 0
    # Edit opens the file, as a click on its row does.
    let edited = editWindow(project, data, o & "click:file:" & main &
                            ":right,ctx:Edit")
    ck edited.textOf.contains("print('main')")
    removeDir(project)
    removeDir(data)

  test "Create: a taken name is refused, a free one is created and opened":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let (o, plan0) = openSrc(project, data)
    let main = plan0.rowId("main.py")
    # The field opens as the first child of main.py's folder.
    let opened = editWindow(project, data, o & "click:file:" & main &
                            ":right,ctx:Create")
    ck opened.field == ("create", "")
    ck opened.menuEntries.len == 0
    # A taken name: refused, the reason drawn, the file untouched.
    var t = ""
    let refused = editWindow(project, data, o & "click:file:" & main &
                             ":right,ctx:Create,type:util.py,key:enter", t)
    ck refused.field == ("create", "util.py")
    var reasons: seq[string] = @[]
    for n in refused.nodesWith("data-ct-files-field-error"):
      reasons.add n.attr("data-ct-files-field-error")
    ck reasons.len == 1 and reasons[0].contains("util.py")
    ck readFile(project / "src" / "util.py") == "def util():\n    return 1\n"
    # Escape closes it and creates nothing.
    let cancelled = editWindow(project, data, o & "click:file:" & main &
                               ":right,ctx:Create,type:x.py,key:escape")
    ck cancelled.field == ("", "")
    ck not fileExists(project / "src" / "x.py")
    # A free name (Backspace edits it): created empty, listed, opened.
    let created = editWindow(project, data, o & "click:file:" & main &
      ":right,ctx:Create,type:new.pyy,key:backspace,key:enter", t)
    ck fileExists(project / "src" / "new.py")
    ck readFile(project / "src" / "new.py") == ""
    ck created.field == ("", "")
    ck created.rowId("new.py").len > 0
    ck created.tabsText.contains("new.py")
    ck created.textOf.contains("created src/new.py")
    ck t.contains("files: created src/new.py")
    removeDir(project)
    removeDir(data)

  test "Rename: the field holds the name; the file is renamed on disk":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let (o, plan0) = openSrc(project, data)
    let util = plan0.rowId("util.py")
    let opened = editWindow(project, data, o & "click:file:" & util &
                            ":right,ctx:Rename")
    ck opened.field == ("rename", "util.py")
    let renamed = editWindow(project, data, o & "click:file:" & util &
      ":right,ctx:Rename,key:backspace,key:backspace,type:txt,key:enter")
    ck fileExists(project / "src" / "util.txt")
    ck not fileExists(project / "src" / "util.py")
    ck readFile(project / "src" / "util.txt") == "def util():\n    return 1\n"
    ck renamed.rowId("util.txt").len > 0 and renamed.rowId("util.py") == ""
    ck renamed.textOf.contains("renamed src/util.py to util.txt")
    removeDir(project)
    removeDir(data)

  test "Delete asks first: Escape keeps the file, Enter moves it to the trash":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let plan0 = editWindow(project, data, "")
    let readme = plan0.rowId("README.md")
    let asked = editWindow(project, data, "click:file:" & readme &
                           ":right,ctx:Delete")
    let questions = asked.nodesWith("data-ct-files-question")
    ck questions.len == 1
    ck questions[0].textOf.contains("Move \"README.md\" to the trash?")
    # A character does not answer it; Escape keeps the file.
    let kept = editWindow(project, data, "click:file:" & readme &
                          ":right,ctx:Delete,key:y,key:escape")
    ck kept.nodesWith("data-ct-files-question").len == 0
    ck fileExists(project / "README.md")
    ck not dirExists(data / "Trash")
    let gone = editWindow(project, data, "click:file:" & readme &
                          ":right,ctx:Delete,key:enter")
    ck not fileExists(project / "README.md")
    ck readFile(data / "Trash" / "files" / "README.md") == "# readme\n"
    ck fileExists(data / "Trash" / "info" / "README.md.trashinfo")
    ck gone.rowId("README.md") == ""
    ck gone.textOf.contains("moved README.md to the trash")
    removeDir(project)
    removeDir(data)

  test "a press elsewhere cancels an open name field":
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    let (o, plan0) = openSrc(project, data)
    let main = plan0.rowId("main.py")
    let util = plan0.rowId("util.py")
    # A press on another Files row leaves the field: nothing is created and
    # the row's own click still runs.
    var t = ""
    let left = editWindow(project, data, o & "click:file:" & main &
      ":right,ctx:Create,type:other.py,click:file:" & util & ":left", t)
    ck left.field == ("", "")
    ck not fileExists(project / "src" / "other.py")
    ck t.contains("files: cancelled")
    ck left.textOf.contains("def util():")
    removeDir(project)
    removeDir(data)

suite "GPUI Edit mode: a folder tab":

  test "a folder tab lists the folder, and its menu acts on the disk":
    let calc = repo / CalcFixture
    if not dirExists(calc):
      raise newException(IOError, "prerequisite missing: " & calc &
        " (the tui lane records it on its first run)")
    let project = newProject()
    let data = createTempDir("files-edit-gpui-data-", "")
    # A new tab's Welcome screen; its focus starts on "Open folder".
    let open = "tab-add,key:enter,type:" & project & ",key:enter"
    var t = ""
    let shown = run(@["--report-window-plan", "--width=" & $W,
                      "--height=" & $H, "--window-ops=" & open, calc], data, t)
    ck t.contains("folder tab " & project)
    let readme = shown.rowId("README.md")
    ck readme.len > 0 and shown.rowId("src").len > 0
    let menu = run(@["--report-window-plan", "--width=" & $W,
                     "--height=" & $H, "--window-ops=" & open &
                     ",click:file:" & readme & ":right", calc], data, t)
    ck menu.menuEntries == @[("Create", "true"), ("Rename", "true"),
                             ("Delete", "true"), ("Edit", "true")]
    discard run(@["--report-window-plan", "--width=" & $W, "--height=" & $H,
                  "--window-ops=" & open & ",click:file:" & readme &
                  ":right,ctx:Rename,type:x,key:enter", calc], data, t)
    ck fileExists(project / "README.mdx")
    ck not fileExists(project / "README.md")
    removeDir(project)
    removeDir(data)

suite "GPUI Edit mode Files: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
