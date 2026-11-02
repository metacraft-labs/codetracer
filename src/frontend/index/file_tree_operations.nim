## index/file_tree_operations.nim — the Files pane's Create, Rename and Delete,
## carried out on the disk by the index process.
##
## Governing spec: codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md`
## § "Context menu". In edit mode the pane's Create, Rename and Delete "act on
## the disk through the index process", and:
##
## - **The index process never overwrites.** It refuses a target that exists
##   when it acts, "even one that appeared after the field opened". Create
##   opens the new file with the `wx` flag, so the existence check and the
##   creation are one system call (`O_CREAT | O_EXCL`). Node has no rename
##   that refuses to replace its target (`renameat2(RENAME_NOREPLACE)` is not
##   exposed), so Rename (`moveEntryNoReplace`) does this instead:
##   - a FILE gets a hard link at the new name (`link` fails with `EEXIST`
##     when the name is taken, atomically), and then its old name is removed:
##     an existing file is never replaced. On a filesystem without hard links
##     (`link` fails with `EPERM`, `ENOTSUP`/`EOPNOTSUPP`, `ENOSYS` or
##     `EXDEV`) it falls back to the folder procedure, and a file created in
##     its interval can be replaced;
##   - a FOLDER is checked with `lstat` immediately before `rename`. POSIX
##     `rename` fails onto a non-empty folder and onto a file, so in that
##     interval only an empty folder created there can be replaced
##     (https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
##     A SYMBOLIC LINK is renamed the same way, as itself: whether `link`
##     follows a symbolic link is left to the system
##     (https://pubs.opengroup.org/onlinepubs/9799919799/functions/link.html),
##     and a hard link to its target is not a rename of the link.
## - **A deletion is never permanent.** Delete moves the path to the trash
##   with Electron's `shell.trashItem`
##   (https://www.electronjs.org/docs/latest/api/shell#shelltrashitempath).
##   Where there is no Electron shell — `ct host` and every `-d:server` build,
##   whose `electron` is a stand-in object — there is no trash, and Delete is
##   refused with `NoTrashReason` instead of falling back to `unlink`.
## - **Each operation is answered** on `CODETRACER::file-tree-operation-done`
##   with the path it changed, or with the reason it failed. The pane reloads
##   the folder named in the answer, or shows the reason as a notification
##   (`ui/filesystem.onFileTreeOperationDone`).
##
## Two checks repeat the pane's, because this is the process that touches the
## disk and its messages can come from any client a `ct host` admits, not
## only from the pane's validated field (the pane already disables what they
## refuse; these are the second line of defence):
##
## - the name rule is checked again (`fileEntryNameRefusal`, the predicate the
##   pane uses), so a name with a separator cannot turn into a path;
## - the path must lie inside the folder opened in edit mode
##   (`data.workspaceFolder`), after `..` segments are resolved. The opened
##   folder itself may receive a new file, but is not renamed or deleted
##   through the tree (the pane disables both on its row);
## - the folder the operation writes in — Create's target folder, the
##   renamed or deleted entry's parent — must still be inside the opened
##   folder once symbolic links are resolved (`realpath`). Otherwise a link
##   inside the folder that points elsewhere (`proj/out -> /etc`) would let
##   `proj/out/passwd` past the first check. The pane never sends such a
##   path: the tree reads entries with `lstat` (`index/files.loadFile`), so
##   a linked folder is a leaf and nothing is listed below it. A link ITSELF
##   is an entry of its parent, and is renamed or deleted as itself.
##
## The operation procs take the opened folder as a parameter and return their
## answer, so the main-process suite (`tests/file_tree_operations_test.nim`)
## drives them over a real temporary directory; the `on…` IPC handlers read
## `data.workspaceFolder` and send the answer.

import
  std / [ async, jsffi, strutils ],
  electron_vars, config,
  ../../common/[ ct_logging, trace_source_paths, file_entry_names ]

type
  FileTreeAnswer* = object
    ## The answer to one Create, Rename or Delete, sent to the renderer as
    ## `CODETRACER::file-tree-operation-done`.
    operation*: cstring
      ## `"create"`, `"rename"` or `"delete"`.
    source*: cstring
      ## What the request named: the target folder for a create, the entry
      ## for a rename or a delete.
    path*: cstring
      ## The path the operation changed — the new file, the entry's new path,
      ## or the path moved to the trash. `""` when it failed.
    folder*: cstring
      ## The folder whose listing changed, which the pane reloads: the target
      ## folder for a create, the entry's parent for a rename or a delete.
    error*: cstring
      ## Why it failed; `""` when it succeeded.

const FileTreeOperationDoneChannel* = "CODETRACER::file-tree-operation-done"

proc resolvePath(path: cstring): cstring {.importjs: "require('path').resolve(#)".}
proc joinPath(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc parentPath(path: cstring): cstring {.importjs: "require('path').dirname(#)".}
proc createEmptyFileExclusive(path: cstring): Future[JsObject]
  {.importjs: "require('fs').promises.writeFile(#, '', {flag: 'wx'})".}
  ## `wx`: create, and fail with `EEXIST` if the path exists — atomically
  ## (https://nodejs.org/api/fs.html#file-system-flags).
proc lstatPath(path: cstring): Future[JsObject]
  {.importjs: "require('fs').promises.lstat(#)".}
proc moveEntryNoReplace*(source, target: cstring): Future[cstring] {.importjs: """
  (async function (src, dst) {
    const fs = require('fs').promises;
    const why = (e) => (e && e.code) ? e.code : String((e && e.message) || e);
    const taken = new Set(['EEXIST', 'ENOTEMPTY', 'ENOTDIR', 'EISDIR']);
    const noHardLinks = new Set(['EPERM', 'ENOTSUP', 'EOPNOTSUPP',
                                 'ENOSYS', 'EXDEV']);
    async function checkThenRename() {
      try { await fs.lstat(dst); return 'EEXIST'; }
      catch (e) { if (e.code !== 'ENOENT') return why(e); }
      try { await fs.rename(src, dst); return ''; }
      catch (e) { return taken.has(e.code) ? 'EEXIST' : why(e); }
    }
    let st;
    try { st = await fs.lstat(src); } catch (e) { return why(e); }
    // A folder, and a symbolic link: `link` on a symbolic link may make the
    // new name a hard link to its TARGET (POSIX leaves it to the system), so
    // a link is moved as itself, by `rename`.
    if (st.isDirectory() || st.isSymbolicLink()) return checkThenRename();
    try { await fs.link(src, dst); }
    catch (e) {
      if (e.code === 'EEXIST') return 'EEXIST';
      if (noHardLinks.has(e.code)) return checkThenRename();
      return why(e);
    }
    try { await fs.unlink(src); return ''; }
    catch (e) {
      // Both names now exist; take the new one back so the rename did not
      // half happen.
      try { await fs.unlink(dst); } catch (_) {}
      return why(e);
    }
  })(#, #)""".}
  ## Move the entry at `source` to `target` without ever replacing an entry
  ## at `target` (the module header says how). Answers `""` when it moved,
  ## `"EEXIST"` when `target` is taken, otherwise the error code or message.
  ## No scope or name checks: `renameFileTreeEntry` makes them first.

proc errorCode(error: JsObject): cstring
  {.importjs: "(function (e) { return (e && e.code) || ''; })(#)".}

proc failed(operation, source: cstring; reason: string): FileTreeAnswer =
  FileTreeAnswer(operation: operation, source: source, path: cstring"",
                 folder: cstring"", error: cstring(reason))

proc scopeRefusal(path, workspace: cstring; allowWorkspaceItself: bool): string =
  ## Why `path` may not be changed from the tree of `workspace`, or `""`.
  ## `path` is resolved first, so `<workspace>/../elsewhere` is outside.
  if workspace.isNil or workspace.len == 0:
    return "No folder is open"
  if path.isNil or path.len == 0:
    return "No path was given"
  let resolved = $resolvePath(path)
  let root = $resolvePath(workspace)
  if isAncestorPathOf(root, resolved):
    return ""
  if allowWorkspaceItself and isPathWithinRoot(root, resolved):
    return ""
  if isPathWithinRoot(root, resolved):
    return "The opened folder itself cannot be renamed or deleted from the tree"
  "\"" & resolved & "\" is outside the opened folder"

proc realPathOf(path: cstring): Future[cstring]
  {.importjs: "require('fs').promises.realpath(#)".}

proc linkedScopeRefusal(folder, workspace: cstring): Future[string] {.async.} =
  ## Why the folder an operation writes in, `folder`, is not inside
  ## `workspace` once symbolic links are resolved, or `""`. Run after
  ## `scopeRefusal`, which has already resolved `..` (see the module header).
  var realRoot, realFolder: string
  try:
    realRoot = $(await realPathOf(workspace))
  except:
    return "The opened folder \"" & $workspace & "\" no longer exists"
  try:
    realFolder = $(await realPathOf(folder))
  except:
    return "\"" & $folder & "\" no longer exists"
  if isPathWithinRoot(realRoot, realFolder):
    return ""
  return "\"" & $folder & "\" leads outside the opened folder through a symbolic link"

proc pathExists(path: cstring): Future[bool] {.async.} =
  ## `lstat`, not `access`: a dangling symbolic link is an existing entry,
  ## and renaming over it would replace it.
  try:
    discard await lstatPath(path)
    return true
  except:
    return false

proc nameOf(path: cstring): string =
  let parent = $parentPath(path)
  let full = $path
  if full.len > parent.len + 1: full[parent.len + 1 .. ^1] else: full

proc createFileInFolder*(folder, name, workspace: cstring):
    Future[FileTreeAnswer] {.async.} =
  ## Create the empty file `name` in `folder`. Refused when the name is not a
  ## name, when `folder` is not inside `workspace`, or when the file exists.
  let operation = cstring"create"
  let nameRefusal = fileEntryNameRefusal($name)
  if nameRefusal.len > 0:
    return failed(operation, folder, nameRefusal)
  let scope = scopeRefusal(folder, workspace, allowWorkspaceItself = true)
  if scope.len > 0:
    return failed(operation, folder, scope)
  let linked = await linkedScopeRefusal(resolvePath(folder), workspace)
  if linked.len > 0:
    return failed(operation, folder, linked)
  let target = joinPath(resolvePath(folder), name)
  try:
    discard await createEmptyFileExclusive(target)
  except:
    # Node rejects with `code: "EEXIST"`; under Nim's JS backend the
    # rejection can arrive wrapped, with the code only in the message.
    let error = cast[JsObject](getCurrentException())
    if $errorCode(error) == "EEXIST" or "EEXIST" in getCurrentExceptionMsg():
      return failed(operation, folder, alreadyExistsRefusal($name))
    errorPrint "file-tree-create: ", getCurrentExceptionMsg()
    return failed(operation, folder,
      "Could not create \"" & $target & "\": " & getCurrentExceptionMsg())
  return FileTreeAnswer(operation: operation, source: folder, path: target,
                        folder: resolvePath(folder), error: cstring"")

proc renameFileTreeEntry*(path, newName, workspace: cstring):
    Future[FileTreeAnswer] {.async.} =
  ## Rename the entry at `path` to `newName`, in the same folder. Refused
  ## when the name is not a name, when `path` is not strictly inside
  ## `workspace`, or when an entry named `newName` exists when it acts.
  let operation = cstring"rename"
  let nameRefusal = fileEntryNameRefusal($newName)
  if nameRefusal.len > 0:
    return failed(operation, path, nameRefusal)
  let scope = scopeRefusal(path, workspace, allowWorkspaceItself = false)
  if scope.len > 0:
    return failed(operation, path, scope)
  let source = resolvePath(path)
  let folder = parentPath(source)
  let target = joinPath(folder, newName)
  let linked = await linkedScopeRefusal(folder, workspace)
  if linked.len > 0:
    return failed(operation, path, linked)
  if not await pathExists(source):
    return failed(operation, path, "\"" & $source & "\" no longer exists")
  if $target == $source:
    # Nothing to rename. Answered as a success that changed this path, so
    # the pane reloads the folder like after any other rename.
    return FileTreeAnswer(operation: operation, source: path, path: target,
                          folder: folder, error: cstring"")
  var outcome = ""
  try:
    outcome = $(await moveEntryNoReplace(source, target))
  except:
    outcome = getCurrentExceptionMsg()
  if outcome == "EEXIST":
    return failed(operation, path, alreadyExistsRefusal($newName))
  if outcome.len > 0:
    errorPrint "file-tree-rename: ", outcome
    return failed(operation, path,
      "Could not rename \"" & nameOf(source) & "\": " & outcome)
  return FileTreeAnswer(operation: operation, source: path, path: target,
                        folder: folder, error: cstring"")

proc hostTrash(): JsObject =
  ## Electron's `shell`, when this process has one with `trashItem`; nil
  ## otherwise. `electron` is `require("electron")` in the desktop main
  ## process and a stand-in object under `-d:server` (`electron_vars`), whose
  ## `shell` is undefined.
  let electronObject = electron.toJs
  if electronObject.isNil or electronObject.isUndefined:
    return nil
  let shell = electronObject[cstring"shell"]
  if shell.isNil or shell.isUndefined or
      shell[cstring"trashItem"].isUndefined:
    return nil
  shell

proc trashItem(shell: JsObject; path: cstring): Future[JsObject]
  {.importjs: "#.trashItem(#)".}

proc trashFileTreeEntry*(path, workspace: cstring):
    Future[FileTreeAnswer] {.async.} =
  ## Move the entry at `path` — a folder with its contents — to the trash.
  ## Refused, deleting nothing, where this host has no trash.
  let operation = cstring"delete"
  let scope = scopeRefusal(path, workspace, allowWorkspaceItself = false)
  if scope.len > 0:
    return failed(operation, path, scope)
  let source = resolvePath(path)
  let linked = await linkedScopeRefusal(parentPath(source), workspace)
  if linked.len > 0:
    return failed(operation, path, linked)
  let shell = hostTrash()
  if shell.isNil:
    return failed(operation, path, NoTrashReason)
  if not await pathExists(source):
    return failed(operation, path, "\"" & $source & "\" no longer exists")
  try:
    discard await shell.trashItem(source)
  except:
    errorPrint "file-tree-delete: ", getCurrentExceptionMsg()
    return failed(operation, path,
      "Could not move \"" & nameOf(source) & "\" to the trash: " &
        getCurrentExceptionMsg())
  return FileTreeAnswer(operation: operation, source: path, path: source,
                        folder: parentPath(source), error: cstring"")

# ---------------------------------------------------------------------------
# IPC handlers (`ipc_utils`: "file-tree-create", "file-tree-rename",
# "file-tree-delete"). Each one answers exactly once, whatever happens: a
# pane that sent a request and heard nothing would leave the user with no
# account of what happened to their file.
# ---------------------------------------------------------------------------


proc field(request: JsObject; name: cstring): cstring =
  ## A string field of a request, `""` when absent: a request comes from a
  ## renderer or a `ct host` client, and a missing field must be refused by
  ## the operation's own checks rather than fail inside one.
  if request.isNil or request.isUndefined:
    return cstring""
  let value = request[name]
  if value.isNil or value.isUndefined: cstring"" else: value.to(cstring)

proc sendAnswer(answer: FileTreeAnswer) =
  if mainWindow.isNil:
    errorPrint "file-tree operation answered with no window: ", answer.error
    return
  mainWindow.webContents.send FileTreeOperationDoneChannel, answer.toJs

proc onFileTreeCreate*(sender: js; request: JsObject) {.async.} =
  let folder = request.field(cstring"folder")
  var answer: FileTreeAnswer
  try:
    answer = await createFileInFolder(folder, request.field(cstring"name"),
                                      data.workspaceFolder)
  except:
    answer = failed(cstring"create", folder, getCurrentExceptionMsg())
  sendAnswer(answer)

proc onFileTreeRename*(sender: js; request: JsObject) {.async.} =
  let path = request.field(cstring"path")
  var answer: FileTreeAnswer
  try:
    answer = await renameFileTreeEntry(path, request.field(cstring"newName"),
                                       data.workspaceFolder)
  except:
    answer = failed(cstring"rename", path, getCurrentExceptionMsg())
  sendAnswer(answer)

proc onFileTreeDelete*(sender: js; request: JsObject) {.async.} =
  let path = request.field(cstring"path")
  var answer: FileTreeAnswer
  try:
    answer = await trashFileTreeEntry(path, data.workspaceFolder)
  except:
    answer = failed(cstring"delete", path, getCurrentExceptionMsg())
  sendAnswer(answer)
