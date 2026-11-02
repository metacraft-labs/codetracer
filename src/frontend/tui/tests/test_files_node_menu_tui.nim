## test_files_node_menu_tui.nim — K19, Tier 1: the terminal's Files pane
## opens the Files pane's menu (codetracer-pm
## `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu"), from the shared
## Files model, by the mouse and from the keyboard, and in Edit mode its
## entries change a REAL project directory.
##
##   * a replay's tree: a right-click on a row opens Create, Rename, Delete
##     and Edit; the first three disabled with the recording's reason (drawn
##     beside them), choosing one does nothing but say why and keeps the menu
##     open; Edit opens the file (the same request a click on the row makes);
##   * Edit mode over a real temporary project: Down moves the selected row,
##     `context-menu.open` (CUA's `Shift+F10`) opens that row's menu, every
##     entry enabled; Create opens the command line with `create ` typed, a
##     taken name is refused and the line comes back with the reason, a free
##     one creates the empty file on disk, lists it and opens it; Rename
##     renames the file on disk; Delete asks first — Escape keeps the file,
##     Enter moves it into the trash (a directory of this suite's, through
##     `XDG_DATA_HOME`); Enter on a row opens it in the editor.
##
## No mocks. The product's runtime and its own host wiring for the disk
## (`native_file_tree.wireNativeFileOperations`, the closure `main.nim`
## installs); the project walk handed to `EditServices.listFiles` is a real
## walk of the real directory, and `readFile` reads it — the HOST's two seams,
## spelled here (the same category as `app/tests/test_edit_mode_source.nim`'s
## closures). This suite lives beside the host-side suites rather than under
## `app/tests/` because it links the disk half, which a declared SDK consumer
## may not import. Every claim about a file is read back from the disk.

import std/[algorithm, os, strutils, tempfiles, unittest]

import codetracer_embed
import headless_app/file_tree_menu
import host/native_file_tree

import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../app/views/file_tree
import ../app/views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 78

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 40

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc sgr(button, row, col: int; pressed: bool): string =
  ## SGR 1006, one-based, as a terminal writes it.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc walk(root: string): EditListResult =
  ## The project's files, project-relative and sorted.
  for f in walkDirRec(root, relative = true):
    result.files.add f
  result.files.sort()

proc project(): string =
  result = createTempDir("ct-files-menu-tui-", "")
  createDir(result / "src")
  writeFile(result / "a.txt", "alpha\n")
  writeFile(result / "src" / "main.py", "print(1)\n")

proc editRuntime(root: string): TuiRuntime =
  ## A runtime in Edit mode over `root`, wired as `main.nim` wires one.
  let app = newTuiApp()
  app.projectRoot = root
  app.modes = initModeRegister(pmEdit)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.enableLayoutBinding()
  result.editServices.listFiles = proc(): EditListResult = walk(root)
  result.editServices.readFile = proc(relative: string): EditReadResult =
    if fileExists(root / relative):
      EditReadResult(ok: true, text: readFile(root / relative))
    else:
      EditReadResult(ok: false, message: "no such file " & relative)
  result.editServices.wireFileTree = proc(vm: FilesystemVM;
                                          openedFolder: proc(): string;
                                          done: proc(r: FileTreeOperationResult)) =
    wireNativeFileOperations(vm, openedFolder, done)
  discard result.ensureEditWorkspace()

proc statusRow(rt: TuiRuntime): string =
  rt.shellScreenOf().rows[^1]

proc screenText(rt: TuiRuntime): string =
  rt.shellScreenOf().rows.join("\n")

proc rowOf(rt: TuiRuntime; needle: string; maxCol = high(int)): (int, int) =
  ## The (row, col) where `needle` is drawn (left of `maxCol`), or (-1, -1).
  let rows = rt.shellScreenOf().rows
  for r, line in rows:
    let c = line.find(needle)
    if c >= 0 and c < maxCol:
      return (r, c)
  (-1, -1)

proc filesRowOf(rt: TuiRuntime; needle: string): (int, int) =
  ## `needle`'s row in the Files pane: a row of the pane starts at its left
  ## edge (the open marker, then the path), while the editor's tab names the
  ## open file too, further right.
  rt.rowOf(needle, maxCol = 4)

proc typeText(rt: TuiRuntime; text: string) =
  for ch in text:
    discard rt.handleToken($ch, 0)

proc clearPrompt(rt: TuiRuntime) =
  while rt.prompt.buffer.len > 0:
    discard rt.handleToken("\x7f", 0)

suite "K19 in the terminal: a replay's tree":

  test "a right-click opens the four entries; three read-only, Edit opens":
    let app = newTuiApp()
    let vm = createFilesystemVM(nil)
    vm.setRoot(FilesystemEntryNode(text: "app", path: "/rec/app",
      isFolder: true, children: @[
        FilesystemEntryNode(text: "main.py", path: "/rec/app/main.py"),
        FilesystemEntryNode(text: "util.py", path: "/rec/app/util.py")]))
    app.filesVM = vm
    app.fileTree = initFileTreeModel(@[
      FileTreeEntry(text: "app", depth: 0, isFolder: true, path: "/rec/app",
                    expanded: true),
      FileTreeEntry(text: "main.py", depth: 1, path: "/rec/app/main.py"),
      FileTreeEntry(text: "util.py", depth: 1, path: "/rec/app/util.py")])
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    discard rt.enableLayoutBinding()
    let (r, c) = rt.rowOf("util.py")
    ck r > 0
    discard rt.handleToken(sgr(2, r, c, true), 0)
    discard rt.handleToken(sgr(2, r, c, false), 0)
    ck rt.app.contextMenu.open
    let m = rt.app.contextMenu.menu
    ck m.kind == cmkFileTreeNode
    ck m.labels == @FileTreeMenuLabels
    ck m.target.path == "/rec/app/util.py"
    for i in 0 .. 2:
      ck not m.entries[i].enabled
      ck m.entries[i].reason == ReadOnlySourcesReason
    ck m.entries[3].enabled
    # The keyboard starts on the one entry that acts.
    ck rt.app.contextMenu.selected == 3
    # The reason is drawn beside the disabled entries.
    ck rt.screenText.contains(ReadOnlySourcesReason)
    # Choosing a disabled entry keeps the menu open and says why.
    let (cr, cc) = rt.rowOf(" Create")
    ck cr > 0
    discard rt.handleToken(sgr(0, cr, cc + 2, true), 0)
    ck rt.app.contextMenu.open
    ck rt.statusRow.contains(ReadOnlySourcesReason)
    # Edit: the file opens, as a click on its row asks the host.
    let opened = rt.runNamedOperation("context-menu.accept", "", 0)
    ck not rt.app.contextMenu.open
    ck opened.paneClick.kind == pcOpenFile
    ck opened.paneClick.path == "/rec/app/util.py"
    ck vm.nameEdit.val.kind == fneNone and vm.pendingDelete == ""

suite "K19 in the terminal: Edit mode acts on the disk":

  test "the keyboard opens the selected row's menu; Create makes the file":
    let root = project()
    let rt = editRuntime(root)
    ck rt.app.fileTree.files == @["a.txt", "src/main.py"]
    ck not rt.app.editFilesVM.isNil
    ck rt.focusHostedPane(paneFileTree)
    ck rt.app.fileTree.selected == 0
    discard rt.runNamedOperation("list.focus-next", "", 0)
    ck rt.app.fileTree.selected == 1
    discard rt.runNamedOperation("context-menu.open", "", 0)
    ck rt.app.contextMenu.open
    let m = rt.app.contextMenu.menu
    ck m.labels == @FileTreeMenuLabels
    ck m.target.path == root / "src" / "main.py"
    for e in m.entries:
      ck e.enabled
    ck rt.app.contextMenu.selected == 0
    # Create, beside the file: the line with its word typed.
    discard rt.runNamedOperation("context-menu.accept", "", 0)
    ck rt.prompt.open
    ck rt.prompt.buffer == "create "
    ck rt.statusRow.contains("New file in src")
    # A taken name: refused, the line comes back with the name and the reason.
    rt.typeText("main.py")
    discard rt.handleToken("\r", 0)
    ck rt.prompt.open
    ck rt.prompt.buffer == "create main.py"
    ck rt.statusRow.contains(alreadyExistsRefusal("main.py"))
    ck readFile(root / "src" / "main.py") == "print(1)\n"
    # A free one: created on disk, listed, opened.
    rt.clearPrompt()
    rt.typeText("create new.py")
    discard rt.handleToken("\r", 0)
    ck not rt.prompt.open
    ck fileExists(root / "src" / "new.py")
    ck readFile(root / "src" / "new.py") == ""
    ck "src/new.py" in rt.app.fileTree.files
    ck rt.app.fileTree.files[rt.app.fileTree.selected] == "src/new.py"
    ck rt.statusRow.contains("created src/new.py")
    ck rt.app.editSession.activeBuffer().path == "src/new.py"
    ck rt.app.editFilesVM.nameEdit.val.kind == fneNone
    removeDir(root)

  test "Escape cancels Create; Rename renames on disk":
    let root = project()
    let rt = editRuntime(root)
    discard rt.focusHostedPane(paneFileTree)
    discard rt.runNamedOperation("context-menu.open", "", 0)
    discard rt.runNamedOperation("context-menu.accept", "", 0)
    ck rt.prompt.open
    discard rt.handleToken("\x1b", 0)
    ck not rt.prompt.open
    ck rt.app.editFilesVM.nameEdit.val.kind == fneNone
    ck rt.statusRow.contains("cancelled")
    # Rename `a.txt`, from a right-click on its row.
    let (r, c) = rt.filesRowOf("a.txt")
    ck r > 0
    discard rt.handleToken(sgr(2, r, c, true), 0)
    discard rt.handleToken(sgr(2, r, c, false), 0)
    ck rt.app.contextMenu.open
    ck rt.app.contextMenu.menu.target.path == root / "a.txt"
    discard rt.runNamedOperation("context-menu.focus-next", "", 0)
    discard rt.runNamedOperation("context-menu.accept", "", 0)
    ck rt.prompt.buffer == "rename a.txt"
    rt.clearPrompt()
    rt.typeText("rename b.txt")
    discard rt.handleToken("\r", 0)
    ck not fileExists(root / "a.txt")
    ck readFile(root / "b.txt") == "alpha\n"
    ck rt.app.fileTree.files == @["b.txt", "src/main.py"]
    ck rt.statusRow.contains("renamed a.txt to b.txt")
    removeDir(root)

  test "Delete asks first: Escape keeps the file, Enter moves it to the trash":
    let root = project()
    let data = createTempDir("ct-files-menu-tui-data-", "")
    let saved = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", data)
    let rt = editRuntime(root)
    discard rt.focusHostedPane(paneFileTree)
    proc chooseDelete(rt: TuiRuntime) =
      discard rt.runNamedOperation("context-menu.open", "", 0)
      discard rt.runNamedOperation("context-menu.focus-next", "", 0)
      discard rt.runNamedOperation("context-menu.focus-next", "", 0)
      discard rt.runNamedOperation("context-menu.accept", "", 0)
    rt.chooseDelete()
    ck rt.prompt.open
    ck rt.prompt.buffer == "trash a.txt"
    ck rt.statusRow.contains("Move \"a.txt\" to the trash?")
    ck rt.app.editFilesVM.pendingDelete == root / "a.txt"
    discard rt.handleToken("\x1b", 0)
    ck fileExists(root / "a.txt")
    ck rt.app.editFilesVM.pendingDelete == ""
    ck rt.statusRow.contains("kept a.txt")
    rt.chooseDelete()
    discard rt.handleToken("\r", 0)
    ck not fileExists(root / "a.txt")
    ck readFile(data / "Trash" / "files" / "a.txt") == "alpha\n"
    ck rt.app.fileTree.files == @["src/main.py"]
    ck rt.statusRow.contains("moved a.txt to the trash")
    if saved.len > 0: putEnv("XDG_DATA_HOME", saved)
    else: delEnv("XDG_DATA_HOME")
    removeDir(root)
    removeDir(data)

  test "Enter on a row opens it; the menu's Edit opens it too":
    let root = project()
    let rt = editRuntime(root)
    discard rt.focusHostedPane(paneFileTree)
    ck rt.app.editSession.activeBuffer().path == "a.txt"
    discard rt.runNamedOperation("list.focus-last", "", 0)
    ck rt.app.fileTree.selected == 1
    discard rt.runNamedOperation("list.activate", "", 0)
    ck rt.app.editSession.activeBuffer().path == "src/main.py"
    ck rt.app.fileTree.openPath == "src/main.py"
    discard rt.runNamedOperation("list.focus-first", "", 0)
    discard rt.runNamedOperation("context-menu.open", "", 0)
    discard rt.runNamedOperation("context-menu.focus-last", "", 0)
    ck rt.app.contextMenu.menu.entries[rt.app.contextMenu.selected].label ==
      "Edit"
    discard rt.runNamedOperation("context-menu.accept", "", 0)
    ck rt.app.editSession.activeBuffer().path == "a.txt"
    removeDir(root)

suite "K19 in the terminal: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
