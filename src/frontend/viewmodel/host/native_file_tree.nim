## host/native_file_tree.nim — the Files pane's Create, Rename and Delete on
## the disk, for a NATIVE front-end (the terminal and the GPUI window).
##
## Governing spec: codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md`
## § "Context menu". The desktop carries these operations out in its index
## process (`index/file_tree_operations.nim`, node's `fs` and Electron's
## `shell.trashItem`). A native front-end has no index process: it acts on
## the disk itself, in-process, with the SAME rules, and this module is where
## they are spelled for the C backend:
##
## - **Nothing is ever overwritten.** Create opens the new file with
##   `O_CREAT | O_EXCL`, so the existence check and the creation are one
##   system call. Rename of a FILE makes a hard link at the new name (`link`
##   fails with `EEXIST` when the name is taken) and then removes the old
##   name; on a filesystem without hard links (`EPERM`, `ENOTSUP`,
##   `EOPNOTSUPP`, `ENOSYS`, `EXDEV`) it falls back to the folder procedure.
##   A FOLDER, and a SYMBOLIC LINK (renamed as itself), is checked with
##   `lstat` immediately before `rename`; POSIX `rename` fails onto a
##   non-empty folder and onto a file, so in that interval only an empty
##   folder created there can be replaced.
## - **A deletion is never permanent.** Delete moves the entry to the trash:
##   on Linux and the BSDs the freedesktop.org trash
##   (https://specifications.freedesktop.org/trash-spec/latest/) of the home
##   volume — `$XDG_DATA_HOME/Trash`, by default `~/.local/share/Trash`, an
##   `info/<name>.trashinfo` reserved exclusively first and the entry then
##   moved into `files/<name>` with `rename`; on macOS `~/.Trash`. An entry
##   that `rename` cannot move there (another filesystem: `EXDEV`) is
##   REFUSED, never copied and deleted. Where there is no trash (Windows, a
##   process with no home), Delete is refused with `NoTrashReason`, and
##   `nativeTrashAvailable` answers false so the menu disables it first.
## - **The opened folder is the boundary.** A path is resolved (`..`) before
##   it is checked against the folder Edit mode opened, and the folder an
##   operation writes in — Create's target, the entry's parent — is checked
##   again after symbolic links are resolved (`realpath`), so a link inside
##   the folder cannot carry an operation outside it. The opened folder
##   itself takes a new file but is not renamed or deleted.
## - **Every operation is answered**, with the path it changed or the reason
##   it failed (`FileTreeOperationResult`).
##
## The checks repeat the menu's (`FilesystemVM.fileTreeMenu`) because this is
## the code that touches the disk. The name rule is the shared predicate
## (`file_entry_names.fileEntryNameRefusal`), the refusals the index
## process's words.

when defined(js):
  {.error: "native_file_tree is the native front-ends' disk half; " &
           "the desktop's is index/file_tree_operations".}

import std/[os, posix, strutils, times]

import ../viewmodels/filesystem_vm
import ../../../common/[file_entry_names, trace_source_paths]

export filesystem_vm

# ---------------------------------------------------------------------------
# Small POSIX helpers
# ---------------------------------------------------------------------------

proc c_rename(source, target: cstring): cint {.importc: "rename",
                                               header: "<stdio.h>".}
  ## C's `rename` (std/posix does not declare it): replaces `target` when it
  ## is a file or an empty folder, which is why every caller checks first.

proc entryExists(path: string): bool =
  ## `lstat`, not `stat`: a dangling symbolic link is an existing entry, and
  ## renaming over it would replace it.
  var st: Stat
  lstat(path.cstring, st) == 0

proc isRealFolder(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode)

proc isSymlink(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISLNK(st.st_mode)

proc realPathOf(path: string): string =
  ## The path with every symbolic link resolved, or `""` when it does not
  ## exist.
  var buf = newString(4096)
  let p = realpath(path.cstring, buf.cstring)
  if p.isNil:
    return ""
  $p

proc errnoText(): string = $strerror(errno)

proc resolved(path: string): string =
  ## `..` resolved, the path made absolute (lexically: no link followed).
  absolutePath(path).normalizedPath

proc failed(op: FileTreeAction; source, reason: string): FileTreeOperationResult =
  FileTreeOperationResult(operation: op, source: source, error: reason)

proc scopeRefusal(path, workspace: string; allowWorkspaceItself: bool): string =
  ## Why `path` may not be changed from the tree of `workspace`, or `""`.
  if workspace.len == 0:
    return "No folder is open"
  if path.len == 0:
    return "No path was given"
  let p = resolved(path)
  let root = resolved(workspace)
  if isAncestorPathOf(root, p):
    return ""
  if allowWorkspaceItself and isPathWithinRoot(root, p):
    return ""
  if isPathWithinRoot(root, p):
    return "The opened folder itself cannot be renamed or deleted from the tree"
  "\"" & p & "\" is outside the opened folder"

proc linkedScopeRefusal(folder, workspace: string): string =
  ## Why `folder`, where an operation writes, is not inside `workspace` once
  ## symbolic links are resolved, or `""`.
  let realRoot = realPathOf(workspace)
  if realRoot.len == 0:
    return "The opened folder \"" & workspace & "\" no longer exists"
  let realFolder = realPathOf(folder)
  if realFolder.len == 0:
    return "\"" & folder & "\" no longer exists"
  if isPathWithinRoot(realRoot, realFolder):
    return ""
  "\"" & folder & "\" leads outside the opened folder through a symbolic link"

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

proc createFileInFolder*(folder, name, workspace: string): FileTreeOperationResult =
  ## Create the empty file `name` in `folder`. Refused when the name is not a
  ## name, when `folder` is not inside `workspace`, or when the file exists.
  let nameRefusal = fileEntryNameRefusal(name)
  if nameRefusal.len > 0:
    return failed(ftaCreate, folder, nameRefusal)
  let scope = scopeRefusal(folder, workspace, allowWorkspaceItself = true)
  if scope.len > 0:
    return failed(ftaCreate, folder, scope)
  let dir = resolved(folder)
  let linked = linkedScopeRefusal(dir, workspace)
  if linked.len > 0:
    return failed(ftaCreate, folder, linked)
  let target = dir / name
  let fd = posix.open(target.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o644)
  if fd < 0:
    if errno == EEXIST:
      return failed(ftaCreate, folder, alreadyExistsRefusal(name))
    return failed(ftaCreate, folder,
                  "Could not create \"" & target & "\": " & errnoText())
  discard posix.close(fd)
  FileTreeOperationResult(operation: ftaCreate, source: folder, path: target,
                          folder: dir)

# ---------------------------------------------------------------------------
# Rename
# ---------------------------------------------------------------------------

proc moveEntryNoReplace*(source, target: string): string =
  ## Move the entry at `source` to `target` without ever replacing an entry
  ## at `target` (the module header says how). Answers `""` when it moved,
  ## `"EEXIST"` when `target` is taken, otherwise the system's reason.
  proc checkThenRename(): string =
    if entryExists(target):
      return "EEXIST"
    if c_rename(source.cstring, target.cstring) == 0:
      return ""
    if errno in [EEXIST, ENOTEMPTY, ENOTDIR, EISDIR]:
      return "EEXIST"
    errnoText()
  if not entryExists(source):
    return "\"" & source & "\" no longer exists"
  if isRealFolder(source) or isSymlink(source):
    return checkThenRename()
  if link(source.cstring, target.cstring) != 0:
    let e = errno
    if e == EEXIST:
      return "EEXIST"
    if e in [EPERM, ENOTSUP, EOPNOTSUPP, ENOSYS, EXDEV]:
      return checkThenRename()
    return errnoText()
  if unlink(source.cstring) != 0:
    let why = errnoText()
    # Both names now exist; take the new one back so the rename did not
    # half happen.
    discard unlink(target.cstring)
    return why
  ""

proc renameFileTreeEntry*(path, newName, workspace: string): FileTreeOperationResult =
  ## Rename the entry at `path` to `newName`, in the same folder. Refused
  ## when the name is not a name, when `path` is not strictly inside
  ## `workspace`, or when an entry named `newName` exists when it acts.
  let nameRefusal = fileEntryNameRefusal(newName)
  if nameRefusal.len > 0:
    return failed(ftaRename, path, nameRefusal)
  let scope = scopeRefusal(path, workspace, allowWorkspaceItself = false)
  if scope.len > 0:
    return failed(ftaRename, path, scope)
  let source = resolved(path)
  let folder = source.parentDir
  let target = folder / newName
  let linked = linkedScopeRefusal(folder, workspace)
  if linked.len > 0:
    return failed(ftaRename, path, linked)
  if not entryExists(source):
    return failed(ftaRename, path, "\"" & source & "\" no longer exists")
  if target == source:
    return FileTreeOperationResult(operation: ftaRename, source: path,
                                   path: target, folder: folder)
  let outcome = moveEntryNoReplace(source, target)
  if outcome == "EEXIST":
    return failed(ftaRename, path, alreadyExistsRefusal(newName))
  if outcome.len > 0:
    return failed(ftaRename, path, "Could not rename \"" &
                  source.extractFilename & "\": " & outcome)
  FileTreeOperationResult(operation: ftaRename, source: path, path: target,
                          folder: folder)

# ---------------------------------------------------------------------------
# Delete: the trash
# ---------------------------------------------------------------------------

proc homeTrashDir*(): string =
  ## The trash a deleted entry is moved to, or `""` where this host has none.
  when defined(windows):
    ""
  elif defined(macosx):
    let home = getEnv("HOME")
    if home.len == 0: "" else: home / ".Trash"
  else:
    let data = getEnv("XDG_DATA_HOME")
    if data.len > 0 and data.isAbsolute:
      data / "Trash"
    else:
      let home = getEnv("HOME")
      if home.len == 0: "" else: home / ".local" / "share" / "Trash"

proc nativeTrashAvailable*(): bool =
  ## Whether Delete can move an entry to a trash here (the menu's
  ## `FileTreeHostFacts.canTrash`).
  homeTrashDir().len > 0

proc percentEncodePath(path: string): string =
  ## The trash spec's `Path=` value: the path URL-encoded, `/` kept.
  const keep = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~', '/'}
  for c in path:
    if c in keep: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc trashEntry*(source, trash: string): tuple[path, error: string] =
  ## Move `source` into `trash` without overwriting anything there. Answers
  ## the path it now has, or why it was not moved.
  when defined(macosx):
    if not dirExists(trash):
      return ("", NoTrashReason)
    var name = source.extractFilename
    var i = 1
    while entryExists(trash / name):
      inc i
      name = source.extractFilename & " " & $i
    let target = trash / name
    if c_rename(source.cstring, target.cstring) != 0:
      return ("", errnoText())
    (target, "")
  else:
    let files = trash / "files"
    let info = trash / "info"
    try:
      createDir(files)
      createDir(info)
    except OSError as e:
      return ("", "the trash \"" & trash & "\" cannot be used: " & e.msg)
    let base = source.extractFilename
    var name = base
    var i = 1
    while true:
      let infoPath = info / (name & ".trashinfo")
      # Reserve the name: the info file is created exclusively, so two
      # processes trashing entries of one name never take the same slot.
      let fd = posix.open(infoPath.cstring, O_WRONLY or O_CREAT or O_EXCL,
                          0o600)
      if fd >= 0:
        let body = "[Trash Info]\nPath=" & percentEncodePath(source) &
          "\nDeletionDate=" & now().format("yyyy-MM-dd'T'HH:mm:ss") & "\n"
        discard posix.write(fd, body.cstring, body.len)
        discard posix.close(fd)
        if entryExists(files / name):
          discard unlink(infoPath.cstring)
        else:
          let target = files / name
          if c_rename(source.cstring, target.cstring) == 0:
            return (target, "")
          let e = errno
          let why = errnoText()
          discard unlink(infoPath.cstring)
          if e == EXDEV:
            return ("", "it is on another filesystem than the trash \"" &
                        trash & "\"")
          return ("", why)
      elif errno != EEXIST:
        return ("", "the trash \"" & trash & "\" cannot be used: " &
                    errnoText())
      inc i
      name = base & "." & $i

proc trashFileTreeEntry*(path, workspace: string; trash = homeTrashDir()):
    FileTreeOperationResult =
  ## Move the entry at `path` — a folder with its contents — to the trash.
  ## Refused, deleting nothing, where this host has no trash.
  let scope = scopeRefusal(path, workspace, allowWorkspaceItself = false)
  if scope.len > 0:
    return failed(ftaDelete, path, scope)
  let source = resolved(path)
  let linked = linkedScopeRefusal(source.parentDir, workspace)
  if linked.len > 0:
    return failed(ftaDelete, path, linked)
  if trash.len == 0:
    return failed(ftaDelete, path, NoTrashReason)
  if not entryExists(source):
    return failed(ftaDelete, path, "\"" & source & "\" no longer exists")
  let (moved, error) = trashEntry(source, trash)
  if error.len > 0:
    return failed(ftaDelete, path, "Could not move \"" &
                  source.extractFilename & "\" to the trash: " & error)
  FileTreeOperationResult(operation: ftaDelete, source: path, path: moved,
                          folder: source.parentDir)

# ---------------------------------------------------------------------------
# The Files model, carried out here
# ---------------------------------------------------------------------------

proc wireNativeFileOperations*(vm: FilesystemVM; openedFolder: proc(): string;
                               done: proc(r: FileTreeOperationResult)) =
  ## Make `vm` — the tree of the folder a native front-end's Edit mode opened
  ## (`projectTreeOf`) — an opened-folder tree whose Create, Rename and
  ## Delete act on the disk here, and hand each answer to `done`. Delete
  ## asks first (`FilesystemVM.confirmsDelete`): a native front-end shows no
  ## trash to take an entry back from.
  if vm.isNil:
    return
  vm.confirmsDelete = true
  vm.hostFacts = proc(): FileTreeHostFacts =
    FileTreeHostFacts(layout: ToolbarMode.EditMode,
                      openedFolder: openedFolder(),
                      hasIndexProcess: true,
                      canTrash: nativeTrashAvailable())
  vm.onCreateFile = proc(folder, name: string) =
    done(createFileInFolder(folder, name, openedFolder()))
  vm.onRenamePath = proc(path, newName: string) =
    done(renameFileTreeEntry(path, newName, openedFolder()))
  vm.onDeletePath = proc(path: string) =
    done(trashFileTreeEntry(path, openedFolder()))
