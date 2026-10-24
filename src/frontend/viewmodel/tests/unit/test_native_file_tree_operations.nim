## test_native_file_tree_operations.nim — the Files pane's Create, Rename and
## Delete carried out on the disk by a native front-end
## (`host/native_file_tree`), over a REAL temporary directory.
##
## codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu":
##
##   * Create makes an empty file exclusively: an existing one is refused,
##     never truncated; a bad name, a folder outside the opened one and a
##     folder reached through a symbolic link that leads outside are refused;
##   * Rename never replaces: a file onto an existing file, a folder onto an
##     existing folder are refused and both entries keep their contents; a
##     symbolic link is renamed as the link; the opened folder itself is not
##     renamed;
##   * Delete moves the entry — a folder with its contents — into the
##     freedesktop.org trash (`files/` and an `info/*.trashinfo` naming the
##     original path), takes a new name there when the old one is taken,
##     and where there is no trash refuses and deletes nothing;
##   * end to end through the shared Files model with the host's wiring
##     (`wireNativeFileOperations`): the menu's Create, Rename and Delete
##     (asked first) change the disk, and each answer reaches the host once.
##
## No mocks. The trash is a directory inside this suite's temporary
## directory, named through `trashFileTreeEntry`'s parameter and, for the end
## to end case, through `XDG_DATA_HOME` — never the user's own trash. The
## answer callback handed to `wireNativeFileOperations` records what it is
## given: the one stand-in, and it is not a mock — it is the host's own seam,
## and the disk is read back for every claim. Native only: the JS backend has
## no filesystem (rejected from vm-unit-js and vm-unit-wasm).

import std/[os, strutils, tempfiles, unittest]

import isonim/core/[signals, computation, owner]
import host/native_file_tree
import headless_app/file_tree_menu

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 70

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc project(): string =
  ## A fresh opened folder: `README.md`, `src/main.py`, `src/lib/util.py`,
  ## and an empty `docs/`.
  result = createTempDir("ct-native-file-tree-", "")
  createDir(result / "src" / "lib")
  createDir(result / "docs")
  writeFile(result / "README.md", "readme\n")
  writeFile(result / "src" / "main.py", "print('main')\n")
  writeFile(result / "src" / "lib" / "util.py", "x = 1\n")

suite "native Files operations: Create":

  test "an empty file, exclusively; refusals change nothing":
    let p = project()
    let made = createFileInFolder(p / "src", "new.py", p)
    ck made.error == ""
    ck made.path == p / "src" / "new.py" and made.folder == p / "src"
    ck fileExists(p / "src" / "new.py") and readFile(p / "src" / "new.py") == ""
    # Never over an existing file.
    let again = createFileInFolder(p / "src", "main.py", p)
    ck again.error == alreadyExistsRefusal("main.py")
    ck readFile(p / "src" / "main.py") == "print('main')\n"
    # The opened folder itself takes a new file.
    ck createFileInFolder(p, "TOP.md", p).error == ""
    ck fileExists(p / "TOP.md")
    # Not a name; outside the folder, also by `..`.
    ck createFileInFolder(p / "src", "a/b", p).error ==
      fileEntryNameRefusal("a/b")
    ck createFileInFolder(p / "src", "..", p).error != ""
    let outside = createFileInFolder(p / ".." , "escape.txt", p)
    ck outside.error.contains("is outside the opened folder")
    ck not fileExists(p.parentDir / "escape.txt")
    removeDir(p)

  test "a symbolic link inside the folder cannot carry Create outside it":
    let p = project()
    let elsewhere = createTempDir("ct-native-file-tree-out-", "")
    createSymlink(elsewhere, p / "out")
    let r = createFileInFolder(p / "out", "x.txt", p)
    ck r.error.contains("through a symbolic link")
    ck not fileExists(elsewhere / "x.txt")
    removeDir(p)
    removeDir(elsewhere)

suite "native Files operations: Rename":

  test "a file and a folder are renamed; nothing is ever replaced":
    let p = project()
    let r = renameFileTreeEntry(p / "src" / "main.py", "app.py", p)
    ck r.error == ""
    ck r.path == p / "src" / "app.py" and r.folder == p / "src"
    ck not fileExists(p / "src" / "main.py")
    ck readFile(p / "src" / "app.py") == "print('main')\n"
    # Onto an existing file: refused, both keep their contents.
    writeFile(p / "src" / "other.py", "other\n")
    let onto = renameFileTreeEntry(p / "src" / "app.py", "other.py", p)
    ck onto.error == alreadyExistsRefusal("other.py")
    ck readFile(p / "src" / "app.py") == "print('main')\n"
    ck readFile(p / "src" / "other.py") == "other\n"
    # A folder, and a folder onto an existing one.
    ck renameFileTreeEntry(p / "src" / "lib", "pkg", p).error == ""
    ck fileExists(p / "src" / "pkg" / "util.py")
    ck not dirExists(p / "src" / "lib")
    let ontoDir = renameFileTreeEntry(p / "src" / "pkg", "docs", p)
    ck ontoDir.error == ""   # `src/docs` is free: siblings are per folder
    ck renameFileTreeEntry(p / "docs", "src", p).error ==
      alreadyExistsRefusal("src")
    ck dirExists(p / "docs") and dirExists(p / "src")
    # The opened folder itself, and a vanished entry.
    ck renameFileTreeEntry(p, "renamed", p).error.contains(
      "opened folder itself")
    ck renameFileTreeEntry(p / "nope.txt", "x", p).error.contains(
      "no longer exists")
    removeDir(p)

  test "a symbolic link is renamed as the link":
    let p = project()
    createSymlink(p / "README.md", p / "link.md")
    ck renameFileTreeEntry(p / "link.md", "alias.md", p).error == ""
    ck symlinkExists(p / "alias.md") and not symlinkExists(p / "link.md")
    ck expandSymlink(p / "alias.md") == p / "README.md"
    ck readFile(p / "README.md") == "readme\n"
    removeDir(p)

suite "native Files operations: Delete moves to the trash":

  test "a file and a folder with its contents, into files/ with their info":
    let p = project()
    let trash = p / ".trash-under-test"
    let r = trashFileTreeEntry(p / "src" / "main.py", p, trash)
    ck r.error == ""
    ck r.folder == p / "src" and r.path == trash / "files" / "main.py"
    ck not fileExists(p / "src" / "main.py")
    ck readFile(trash / "files" / "main.py") == "print('main')\n"
    let info = readFile(trash / "info" / "main.py.trashinfo")
    ck info.startsWith("[Trash Info]\nPath=")
    ck info.contains("Path=" & (p / "src" / "main.py"))
    ck info.contains("DeletionDate=")
    # A second entry of the same name takes another name there.
    writeFile(p / "main.py", "second\n")
    let second = trashFileTreeEntry(p / "main.py", p, trash)
    ck second.error == "" and second.path == trash / "files" / "main.py.2"
    ck readFile(trash / "files" / "main.py.2") == "second\n"
    ck fileExists(trash / "info" / "main.py.2.trashinfo")
    # A folder goes with its contents.
    ck trashFileTreeEntry(p / "src" / "lib", p, trash).error == ""
    ck not dirExists(p / "src" / "lib")
    ck readFile(trash / "files" / "lib" / "util.py") == "x = 1\n"
    removeDir(p)

  test "no trash: refused, and nothing is deleted":
    let p = project()
    let r = trashFileTreeEntry(p / "README.md", p, trash = "")
    ck r.error == NoTrashReason
    ck fileExists(p / "README.md")
    ck trashFileTreeEntry(p, p, p / ".t").error.contains("opened folder itself")
    ck dirExists(p)
    removeDir(p)

suite "native Files operations: through the shared Files model":

  test "the menu's Create, Rename and Delete change the disk, once each":
    let p = project()
    let saved = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", p / ".xdg-data")
    createRoot proc(dispose: proc()) =
      let vm = createFilesystemVM(nil)
      vm.setRoot(projectTreeOf(p, ["README.md", "src/main.py",
                                   "src/lib/util.py"]))
      var answers: seq[FileTreeOperationResult] = @[]
      wireNativeFileOperations(vm, proc(): string = p,
                               proc(r: FileTreeOperationResult) = answers.add r)
      ck vm.confirmsDelete
      let m = vm.fileTreeContextMenuOf(p / "src" / "main.py")
      for e in m.entries:
        ck e.enabled
      # Create, beside the file.
      ck vm.runFileTreeAction(p / "src" / "main.py", caFileCreate) == ""
      ck vm.commitNameEdit("made.py")
      ck answers.len == 1 and answers[0].error == ""
      ck fileExists(p / "src" / "made.py")
      ck describeFileTreeOperation(answers[0], p) == "created src/made.py"
      # Rename.
      ck vm.runFileTreeAction(p / "README.md", caFileRename) == ""
      ck vm.commitNameEdit("READ.md")
      ck answers.len == 2 and fileExists(p / "READ.md")
      ck describeFileTreeOperation(answers[1], p) ==
        "renamed README.md to READ.md"
      # Delete asks first: nothing moves until the answer is yes.
      ck vm.runFileTreeAction(p / "src" / "lib", caFileDelete) == ""
      ck answers.len == 2 and dirExists(p / "src" / "lib")
      ck vm.confirmDelete()
      ck answers.len == 3 and answers[2].error == ""
      ck not dirExists(p / "src" / "lib")
      ck fileExists(p / ".xdg-data" / "Trash" / "files" / "lib" / "util.py")
      ck describeFileTreeOperation(answers[2], p) ==
        "moved src/lib to the trash"
      dispose()
    if saved.len > 0: putEnv("XDG_DATA_HOME", saved)
    else: delEnv("XDG_DATA_HOME")
    removeDir(p)

suite "native Files operations: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
