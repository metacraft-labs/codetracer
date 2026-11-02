## test_files_node_menu.nim — the Files pane's right-click menu (K19) as the
## native front-ends read it from the shared Files model
## (`headless_app/file_tree_menu`, `FilesystemVM`).
##
## codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu":
## a row opens Create, Rename, Delete and Edit, always all four and in that
## order, a disabled entry keeping its reason. This suite holds:
##
##   * the conversion to a native menu (`fileTreeContextMenuOf`): the four
##     labels, their actions, a disabled entry's reason as its reason AND its
##     hint (the column a native menu draws: the spec's sublabel), the menu
##     kept as the model's last one;
##   * a replay's tree: Create, Rename and Delete read-only, Edit opens the
##     file through the model;
##   * a native Edit mode's tree (`projectTreeOf`, the opened folder from a
##     project walk): the opened folder's row, its folders and files with
##     absolute paths; Create on a file goes to its folder, the opened
##     folder's row takes a new file but is not renamed or deleted;
##   * choosing an entry re-asks the model (`runFileTreeAction`): an enabled
##     entry runs, a disabled one answers its reason and runs nothing;
##   * Delete that asks first (`confirmsDelete`, the native front-ends):
##     nothing is sent until `confirmDelete`, nothing at all after
##     `cancelDelete`; the desktop's (`confirmsDelete` false) is sent at once;
##   * the prompts a front-end without an inline field shows, and the
##     project-relative spelling of a tree path;
##   * the inline name field and Delete's question typed into
##     (`applyFilesFieldKey`, GPUI's): characters and Backspace edit the
##     name, Enter sends it or keeps the field open with its reason, Escape
##     closes it; the question takes only Enter and Escape;
##   * a tree with no replay behind it (`createFilesystemVM(nil)`) works.
##
## The requests a menu entry sends are caught by closures assigned to the
## model's request hooks (`onCreateFile`, `onRenamePath`, `onDeletePath`,
## `onOpenFile`) — the one stand-in, and it is not a mock: those hooks ARE
## the seam the front-ends assign (the desktop's to the index process, the
## native ones to `host/native_file_tree`), and recording what they were
## handed is the observation. The disk half is `test_native_file_tree_
## operations.nim`, over a real temporary directory. Pure values otherwise;
## both backends (vm-unit and vm-unit-js).

import std/unittest

import isonim/core/[signals, computation, owner]
import headless_app/file_tree_menu
import viewmodels/filesystem_vm
import store/types
import headless_app/layout_model

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 129

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type Calls = ref object
  created: seq[(string, string)]
  renamed: seq[(string, string)]
  deleted: seq[string]
  opened: seq[string]

proc hooked(vm: FilesystemVM): Calls =
  let calls = Calls()
  vm.onCreateFile = proc(folder, name: string) = calls.created.add (folder, name)
  vm.onRenamePath = proc(path, name: string) = calls.renamed.add (path, name)
  vm.onDeletePath = proc(path: string) = calls.deleted.add path
  vm.onOpenFile = proc(path: string) = calls.opened.add path
  calls

proc replayTree(): FilesystemEntryNode =
  ## A recording's sources: the synthetic container, a folder, two files.
  FilesystemEntryNode(text: "source folders", path: "", isFolder: true,
    children: @[FilesystemEntryNode(text: "app", path: "/rec/app",
      isFolder: true, children: @[
        FilesystemEntryNode(text: "main.py", path: "/rec/app/main.py"),
        FilesystemEntryNode(text: "util.py", path: "/rec/app/util.py")])])

proc editVM(confirms = true): (FilesystemVM, Calls) =
  ## The opened folder `/proj` in a native Edit mode: its walk as a tree, the
  ## facts a native host gives (an opened folder, operations carried out, a
  ## trash), Delete asking first.
  let vm = createFilesystemVM(nil)
  vm.setRoot(projectTreeOf("/proj/", ["README.md", "src/main.py",
                                      "src/lib/util.py"]))
  vm.hostFacts = proc(): FileTreeHostFacts =
    FileTreeHostFacts(layout: ToolbarMode.EditMode, openedFolder: "/proj/",
                      hasIndexProcess: true, canTrash: true)
  vm.confirmsDelete = confirms
  (vm, vm.hooked)

suite "Files node menu: the native menu is the model's":

  test "a replay's row: four entries, three read-only with their reason":
    createRoot proc(dispose: proc()) =
      let vm = createFilesystemVM(nil)
      vm.setRoot(replayTree())
      let calls = vm.hooked
      let m = vm.fileTreeContextMenuOf("/rec/app/main.py")
      ck m.kind == cmkFileTreeNode
      ck m.target.pane == paneFileTree and m.target.path == "/rec/app/main.py"
      ck m.labels == @FileTreeMenuLabels
      ck m.labels == @["Create", "Rename", "Delete", "Edit"]
      ck m.entries[0].action == caFileCreate and
        m.entries[1].action == caFileRename and
        m.entries[2].action == caFileDelete and m.entries[3].action == caFileEdit
      for i in 0 .. 2:
        ck not m.entries[i].enabled
        ck m.entries[i].reason == ReadOnlySourcesReason
        ck m.entries[i].hint == ReadOnlySourcesReason
      ck m.entries[3].enabled and m.entries[3].hint == ""
      # The model keeps it as the last menu it opened.
      ck vm.lastContextMenu.len == 4
      # Edit opens the file through the model; the others send nothing.
      ck vm.runFileTreeAction("/rec/app/main.py", caFileEdit) == ""
      ck calls.opened == @["/rec/app/main.py"]
      ck vm.runFileTreeAction("/rec/app/main.py", caFileDelete) ==
        ReadOnlySourcesReason
      ck calls.deleted.len == 0 and calls.created.len == 0
      # A folder cannot be opened in the editor; the container is not on disk.
      let folder = vm.fileTreeContextMenuOf("/rec/app")
      ck not folder.entries[3].enabled
      ck folder.entries[3].reason == OnlyFilesOpenReason
      let container = vm.fileTreeContextMenuOf("")
      ck container.labels == @FileTreeMenuLabels
      ck container.entries[0].reason == NotOnDiskReason
      ck vm.runFileTreeAction("/rec/app", caPinLeft) == "not a Files menu entry"
      dispose()

suite "Files node menu: a native Edit mode's opened folder":

  test "the tree of a project walk: the folder's row, absolute paths":
    let t = projectTreeOf("/proj/", ["README.md", "src/main.py",
                                     "src/lib/util.py"])
    ck t.path == "/proj" and t.text == "proj" and t.isFolder
    ck t.children.len == 2
    ck t.children[0].path == "/proj/README.md" and not t.children[0].isFolder
    ck t.children[1].path == "/proj/src" and t.children[1].isFolder
    ck t.children[1].children[0].path == "/proj/src/main.py"
    ck t.children[1].children[1].path == "/proj/src/lib"
    ck t.children[1].children[1].children[0].path == "/proj/src/lib/util.py"
    ck relativeToRoot("/proj/", "/proj/src/main.py") == "src/main.py"
    ck relativeToRoot("/proj", "/proj") == ""
    ck relativeToRoot("/proj", "/project/x") == ""
    ck joinTreePath("C:\\proj", "a.txt") == "C:\\proj\\a.txt"
    ck projectTreeOf("/empty", []).children.len == 0

  test "a file: every entry acts; Create goes to its folder":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM()
      let m = vm.fileTreeContextMenuOf("/proj/src/main.py")
      ck m.labels == @FileTreeMenuLabels
      for e in m.entries:
        ck e.enabled and e.hint == ""
      ck vm.runFileTreeAction("/proj/src/main.py", caFileCreate) == ""
      ck vm.nameEdit.val.kind == fneCreate
      ck vm.nameEdit.val.folder == "/proj/src"
      ck nameEditPrompt(vm.nameEdit.val) == "New file in src"
      # A taken name keeps the field open with its reason; a free one sends.
      ck not vm.commitNameEdit("main.py")
      ck vm.nameEdit.val.error == alreadyExistsRefusal("main.py")
      ck vm.commitNameEdit("new.py")
      ck calls.created == @[("/proj/src", "new.py")]
      ck vm.nameEdit.val.kind == fneNone
      # Rename opens the field on the current name.
      ck vm.runFileTreeAction("/proj/src/main.py", caFileRename) == ""
      ck vm.nameEdit.val.kind == fneRename and vm.nameEdit.val.name == "main.py"
      ck nameEditPrompt(vm.nameEdit.val) == "Rename main.py"
      ck vm.commitNameEdit("app.py")
      ck calls.renamed == @[("/proj/src/main.py", "app.py")]
      # Edit opens it.
      ck vm.runFileTreeAction("/proj/src/main.py", caFileEdit) == ""
      ck calls.opened == @["/proj/src/main.py"]
      dispose()

  test "the opened folder's row takes a new file, and is not renamed or deleted":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM()
      let m = vm.fileTreeContextMenuOf("/proj")
      ck m.entries[0].enabled
      ck not m.entries[1].enabled and m.entries[1].reason == OpenedFolderRowReason
      ck not m.entries[2].enabled and m.entries[2].reason == OpenedFolderRowReason
      ck not m.entries[3].enabled
      ck vm.runFileTreeAction("/proj", caFileDelete) == OpenedFolderRowReason
      ck vm.pendingDelete == "" and calls.deleted.len == 0
      ck vm.runFileTreeAction("/proj", caFileCreate) == ""
      ck vm.nameEdit.val.folder == "/proj"
      vm.cancelNameEdit()
      ck vm.nameEdit.val.kind == fneNone and calls.created.len == 0
      dispose()

  test "no trash: Delete is disabled with its reason":
    createRoot proc(dispose: proc()) =
      let (vm, _) = editVM()
      vm.hostFacts = proc(): FileTreeHostFacts =
        FileTreeHostFacts(layout: ToolbarMode.EditMode, openedFolder: "/proj",
                          hasIndexProcess: true, canTrash: false)
      let m = vm.fileTreeContextMenuOf("/proj/README.md")
      ck not m.entries[2].enabled and m.entries[2].reason == NoTrashReason
      ck m.entries[2].hint == NoTrashReason
      dispose()

suite "Files node menu: Delete asks first":

  test "nothing is sent until the answer is yes, and nothing after no":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM(confirms = true)
      ck vm.runFileTreeAction("/proj/src/lib", caFileDelete) == ""
      ck vm.pendingDelete == "/proj/src/lib"
      ck calls.deleted.len == 0
      ck deletePrompt(vm.pendingDelete) == "Move \"lib\" to the trash?"
      vm.cancelDelete()
      ck vm.pendingDelete == "" and calls.deleted.len == 0
      ck not vm.confirmDelete()
      ck calls.deleted.len == 0
      discard vm.runFileTreeAction("/proj/README.md", caFileDelete)
      ck vm.confirmDelete()
      ck calls.deleted == @["/proj/README.md"]
      ck vm.pendingDelete == ""
      dispose()

  test "where Delete does not ask (the desktop) it is sent at once":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM(confirms = false)
      ck vm.runFileTreeAction("/proj/README.md", caFileDelete) == ""
      ck calls.deleted == @["/proj/README.md"]
      ck vm.pendingDelete == ""
      dispose()

suite "Files node menu: the name field and the question, typed into":

  test "Create: characters, Backspace, a refused name kept open, Enter sends":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM()
      ck not vm.filesFieldOpen()
      ck vm.applyFilesFieldKey("a") == ffsNotOpen
      ck vm.runFileTreeAction("/proj/src/main.py", caFileCreate) == ""
      ck vm.filesFieldOpen() and vm.nameEditDraft == ""
      for k in ["m", "a", "i", "n", ".", "p", "y"]:
        ck vm.applyFilesFieldKey(k) == ffsTyped
      ck vm.nameEditDraft == "main.py"
      # Taken: the field stays open with its reason and the name typed.
      ck vm.applyFilesFieldKey("Enter") == ffsRefused
      ck vm.filesFieldOpen()
      ck vm.nameEdit.val.error == alreadyExistsRefusal("main.py")
      ck vm.nameEditDraft == "main.py" and calls.created.len == 0
      # A key with no meaning in the field is taken and changes nothing.
      ck vm.applyFilesFieldKey("Ctrl+S") == ffsAbsorbed
      for _ in 0 ..< 3:
        ck vm.applyFilesFieldKey("Backspace") == ffsTyped
      ck vm.applyFilesFieldKey("Space") == ffsTyped
      ck vm.applyFilesFieldKey("B") == ffsTyped
      ck vm.nameEditDraft == "main B"
      ck vm.applyFilesFieldKey("Enter") == ffsCommitted
      ck calls.created == @[("/proj/src", "main B")]
      ck not vm.filesFieldOpen()
      dispose()

  test "Rename opens on the current name; Escape sends nothing":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM()
      ck vm.runFileTreeAction("/proj/README.md", caFileRename) == ""
      ck vm.nameEditDraft == "README.md"
      ck vm.applyFilesFieldKey("Esc") == ffsCancelled
      ck not vm.filesFieldOpen() and calls.renamed.len == 0
      discard vm.runFileTreeAction("/proj/README.md", caFileRename)
      for _ in 0 ..< 3:
        discard vm.applyFilesFieldKey("Backspace")
      ck vm.nameEditDraft == "README"
      ck vm.applyFilesFieldKey("Enter") == ffsCommitted
      ck calls.renamed == @[("/proj/README.md", "README")]
      # An empty field does not shrink further.
      discard vm.runFileTreeAction("/proj/src/main.py", caFileCreate)
      ck vm.applyFilesFieldKey("Backspace") == ffsAbsorbed
      ck vm.cancelFilesField()
      ck not vm.cancelFilesField()
      dispose()

  test "Delete's question: characters do not answer it; Enter and Escape do":
    createRoot proc(dispose: proc()) =
      let (vm, calls) = editVM(confirms = true)
      discard vm.runFileTreeAction("/proj/README.md", caFileDelete)
      ck vm.filesFieldOpen()
      ck vm.applyFilesFieldKey("y") == ffsAbsorbed
      ck calls.deleted.len == 0
      ck vm.applyFilesFieldKey("Esc") == ffsCancelled
      ck calls.deleted.len == 0 and not vm.filesFieldOpen()
      discard vm.runFileTreeAction("/proj/README.md", caFileDelete)
      ck vm.applyFilesFieldKey("Enter") == ffsCommitted
      ck calls.deleted == @["/proj/README.md"]
      ck not vm.filesFieldOpen()
      dispose()

suite "Files node menu: the click inventory":

  test "K19 is the Files pane's menu on both native front-ends":
    let b = behaviour("K19")
    ck b.sharedOp == "FilesystemVM.fileTreeMenu"
    ck b.terminal == nsDone and b.gpui == nsDone
    ck cgRightClick in b.gestures

suite "Files node menu: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
