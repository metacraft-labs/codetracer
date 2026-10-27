## file_tree_operations_test.nim
##
## The Files pane's Create, Rename and Delete as the index process carries
## them out (`index/file_tree_operations.nim`), run against a real temporary
## directory.
##
## Governing spec: codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md`
## § "Context menu" (issue `2026-10-21-isonim-files-pane-has-no-context-menu`).
## In edit mode the entries "act on the disk through the index process",
## which "never overwrites: it refuses a target that exists when it acts", and
## answers "each operation with the path it changed, or with the reason it
## failed". Where it "cannot move a path to the trash, Delete is disabled ...
## A deletion is never permanent."
##
## The cases:
##
## 1. Create makes an EMPTY file in the folder and answers with its path and
##    the folder to reload.
## 2. Create refuses a name that exists — the existing file keeps its content
##    — including one that appeared after the field opened (the pane never
##    sees it; only the disk does).
## 3. Create and Rename refuse what is not a name: empty, `.`, `..`, a `/` or
##    a `\`. Nothing is created or renamed.
## 4. Rename renames a file and a folder (with its contents) and answers the
##    new path and the parent folder.
## 5. Rename refuses an existing target; both entries are unchanged.
## 6. Delete on a host with no trash is refused with "This host has no
##    trash", and the file is still there. This lane runs under node with
##    `-d:server`, where `electron` is the stand-in object and has no
##    `shell` — exactly `ct host`'s situation. (The trash itself needs the
##    Electron main process, which this lane does not start.)
## 7. A path outside the opened folder is refused, `..` included, and the
##    opened folder itself is not renamed or deleted through the tree.
## 8. The IPC handlers answer on `CODETRACER::file-tree-operation-done`,
##    once per request, success or failure.
## 9. Rename never replaces: the no-replace step (`moveEntryNoReplace`),
##    called with the target already in place — the spec's "target that
##    appeared after the field opened", made deterministic — refuses a file
##    onto a file (the hard-link path) and a folder onto a non-empty folder,
##    and both entries keep their contents.
## 10. A symbolic link inside the opened folder that points outside it does
##    not carry Create, Rename or Delete out of the folder: the folder each
##    one writes in is checked again after links are resolved. The link
##    itself is renamed as a link, and its target is untouched.
##
## No fakes but one: the Electron window the handlers answer through is an
## object that records what it was sent (as in `file_tree_root_load_test`).
## The operations, `fs` and the directory tree are real.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node. Writes only under one `mkdtemp` directory, which it removes.

import std/[asyncjs, jsffi, strutils]

import lib/src_relative_require
import ../index/config
import ../index/electron_vars
import ../index/file_tree_operations

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

proc makeTempDir(): cstring {.importjs: """(function () {
  var os = require('os'), path = require('path'), fs = require('fs');
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ct-file-tree-ops-'));
})()""".}

proc removeDir(dir: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}

proc writeText(path: cstring; text: cstring) {.importjs: """(function (p, t) {
  var path = require('path'), fs = require('fs');
  fs.mkdirSync(path.dirname(p), {recursive: true});
  fs.writeFileSync(p, t);
})(#, #)""".}

proc readText(path: cstring): cstring {.importjs:
  "(function (p) { try { return require('fs').readFileSync(p, 'utf8'); } catch (e) { return '<missing>'; } })(#)".}
  ## A file's text, or `<missing>`: a check on a file the code under test
  ## failed to produce must fail as a check, not end the suite.

proc exists(path: cstring): bool {.importjs:
  "(function (p) { try { require('fs').lstatSync(p); return true; } catch (e) { return false; } })(#)".}

proc makeSymlink(target, path: cstring) {.importjs:
  "require('fs').symlinkSync(#, #)".}

proc isSymlink(path: cstring): bool {.importjs:
  "(function (p) { try { return require('fs').lstatSync(p).isSymbolicLink(); } catch (e) { return false; } })(#)".}

proc entryCount(dir: cstring): int {.importjs:
  "require('fs').readdirSync(#).length".}

proc joinPath(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}

proc recordingWindow(): JsObject {.importjs: """(function () {
  var sent = [];
  return { sent: sent,
           webContents: { send: function (channel, payload) {
             sent.push({ channel: channel, payload: payload }); } } };
})()""".}

proc str(text: cstring): string =
  ## `$` of a cstring, reading a nil (an absent answer field) as "": a
  ## missing field must fail its check, not crash the suite.
  if text.isNil: "" else: $text

proc succeeded(answer: FileTreeAnswer): bool =
  str(answer.error).len == 0 and str(answer.path).len > 0

proc errorText(answer: FileTreeAnswer): string =
  str(answer.error)

const ExpectedChecks = 45

proc runCases(dir: cstring) {.async.} =
  # The opened folder, and a sibling of it that is outside.
  let ws = joinPath(dir, cstring"proj")
  let outside = joinPath(dir, cstring"elsewhere")
  writeText(joinPath(ws, cstring"src/main.nr"), cstring"fn main() {}")
  writeText(joinPath(ws, cstring"src/lib.nr"), cstring"lib")
  writeText(joinPath(ws, cstring"README.md"), cstring"readme")
  writeText(joinPath(outside, cstring"keep.txt"), cstring"keep")
  let src = joinPath(ws, cstring"src")

  # 1. Create.
  let created = await createFileInFolder(src, cstring"new.nr", ws)
  let newFile = joinPath(src, cstring"new.nr")
  ck created.succeeded and str(created.path) == $newFile,
    "Create answers the path of the new file (got '" & str(created.path) &
      "', error '" & created.errorText & "')"
  ck exists(newFile) and $readText(newFile) == "",
    "Create makes an empty file on disk"
  ck str(created.folder) == $src,
    "Create names the target folder as the one to reload"
  ck str(created.operation) == "create", "the answer names the operation"

  # 2. Create never overwrites.
  let clash = await createFileInFolder(src, cstring"main.nr", ws)
  ck not clash.succeeded and clash.errorText == "\"main.nr\" already exists in this folder",
    "Create refuses a name that exists (got '" & clash.errorText & "')"
  ck $readText(joinPath(src, cstring"main.nr")) == "fn main() {}",
    "the existing file keeps its content"
  # A file that appears after the field opened: only the disk knows.
  writeText(joinPath(src, cstring"late.nr"), cstring"late")
  let late = await createFileInFolder(src, cstring"late.nr", ws)
  ck not late.succeeded and $readText(joinPath(src, cstring"late.nr")) == "late",
    "Create refuses a target that appeared after the field opened"

  # 3. What is not a name.
  let before = entryCount(src)
  for bad in [cstring"", cstring".", cstring"..", cstring"a/b", cstring"a\\b"]:
    let refusedCreate = await createFileInFolder(src, bad, ws)
    ck not refusedCreate.succeeded and refusedCreate.errorText.len > 0,
      "Create refuses the name '" & $bad & "' (got '" &
        refusedCreate.errorText & "')"
  let refusedRename = await renameFileTreeEntry(
    joinPath(src, cstring"lib.nr"), cstring"../escaped.nr", ws)
  ck not refusedRename.succeeded and refusedRename.errorText.len > 0,
    "Rename refuses a name with a separator (got '" &
      refusedRename.errorText & "')"
  ck entryCount(src) == before and exists(joinPath(src, cstring"lib.nr")) and
      not exists(joinPath(ws, cstring"escaped.nr")),
    "a refused name creates and renames nothing"

  # 4. Rename a file, then a folder with its contents.
  let renamed = await renameFileTreeEntry(joinPath(src, cstring"lib.nr"),
                                          cstring"util.nr", ws)
  let utilPath = joinPath(src, cstring"util.nr")
  ck renamed.succeeded and str(renamed.path) == $utilPath,
    "Rename answers the entry's new path (got '" & str(renamed.path) &
      "', error '" & renamed.errorText & "')"
  ck exists(utilPath) and not exists(joinPath(src, cstring"lib.nr")) and
      $readText(utilPath) == "lib",
    "Rename moves the file to its new name, content and all"
  ck str(renamed.folder) == $src,
    "Rename names the entry's parent as the folder to reload"
  let folderRenamed = await renameFileTreeEntry(src, cstring"source", ws)
  let source = joinPath(ws, cstring"source")
  ck folderRenamed.succeeded and exists(joinPath(source, cstring"main.nr")) and
      not exists(src),
    "Rename renames a folder with its contents (error '" &
      folderRenamed.errorText & "')"
  ck str(folderRenamed.folder) == $ws,
    "a renamed folder's parent is the folder to reload"

  # 5. Rename never overwrites.
  let renameClash = await renameFileTreeEntry(joinPath(source, cstring"util.nr"),
                                              cstring"main.nr", ws)
  ck not renameClash.succeeded and "already exists" in renameClash.errorText,
    "Rename refuses an existing target (got '" & renameClash.errorText & "')"
  ck $readText(joinPath(source, cstring"main.nr")) == "fn main() {}" and
      $readText(joinPath(source, cstring"util.nr")) == "lib",
    "a refused rename leaves both entries as they were"

  # 6. Delete, on a host with no trash.
  let deleted = await trashFileTreeEntry(joinPath(ws, cstring"README.md"), ws)
  ck not deleted.succeeded and deleted.errorText == "This host has no trash",
    "Delete is refused where there is no trash (got '" &
      deleted.errorText & "')"
  ck exists(joinPath(ws, cstring"README.md")),
    "a refused Delete deletes nothing"
  ck str(deleted.operation) == "delete", "the refusal names the operation"

  # 7. Outside the opened folder.
  let escapeCreate = await createFileInFolder(outside, cstring"x.txt", ws)
  ck not escapeCreate.succeeded and not exists(joinPath(outside, cstring"x.txt")),
    "Create refuses a folder outside the opened one (got '" &
      escapeCreate.errorText & "')"
  let dotDot = cstring($ws & "/../elsewhere")
  let escapeDotDot = await createFileInFolder(dotDot, cstring"y.txt", ws)
  ck not escapeDotDot.succeeded and not exists(joinPath(outside, cstring"y.txt")),
    "a '..' path is resolved before the check (got '" &
      escapeDotDot.errorText & "')"
  let escapeRename = await renameFileTreeEntry(
    joinPath(outside, cstring"keep.txt"), cstring"moved.txt", ws)
  ck not escapeRename.succeeded and exists(joinPath(outside, cstring"keep.txt")),
    "Rename refuses an entry outside the opened folder"
  let renameRoot = await renameFileTreeEntry(ws, cstring"proj2", ws)
  ck not renameRoot.succeeded and exists(ws),
    "the opened folder itself is not renamed from the tree (got '" &
      renameRoot.errorText & "')"
  let createInRoot = await createFileInFolder(ws, cstring"TODO.md", ws)
  ck createInRoot.succeeded and exists(joinPath(ws, cstring"TODO.md")),
    "a new file can be created in the opened folder itself"
  let noWorkspace = await createFileInFolder(source, cstring"z.nr", cstring"")
  ck not noWorkspace.succeeded and not exists(joinPath(source, cstring"z.nr")),
    "with no folder open, nothing is created"

  # 8. The IPC handlers answer once, on the done channel.
  data.workspaceFolder = ws
  let window = recordingWindow()
  mainWindow = window
  await onFileTreeCreate(nil, js{folder: source, name: cstring"handled.nr"})
  await onFileTreeRename(nil, js{path: joinPath(source, cstring"handled.nr"),
                               newName: cstring"main.nr"})
  await onFileTreeDelete(nil, js{path: joinPath(source, cstring"main.nr")})
  let sent = window[cstring"sent"]
  ck sent[cstring"length"].to(int) == 3,
    "three requests were answered three times (got " &
      $sent[cstring"length"].to(int) & ")"
  var onChannel = true
  for i in 0 ..< min(3, sent[cstring"length"].to(int)):
    if $sent[i][cstring"channel"].to(cstring) != FileTreeOperationDoneChannel:
      onChannel = false
  ck onChannel, "every answer is on " & FileTreeOperationDoneChannel
  if sent[cstring"length"].to(int) == 3:
    let first = sent[0][cstring"payload"]
    ck $first[cstring"path"].to(cstring) == $joinPath(source, cstring"handled.nr") and
        exists(joinPath(source, cstring"handled.nr")),
      "the create handler created the file and answered its path"
    let second = sent[1][cstring"payload"]
    ck "already exists" in $second[cstring"error"].to(cstring),
      "the rename handler answered its refusal with the reason"
    let third = sent[2][cstring"payload"]
    ck $third[cstring"error"].to(cstring) == "This host has no trash",
      "the delete handler answered its refusal with the reason"
  else:
    ck false, "the create handler created the file and answered its path"
    ck false, "the rename handler answered its refusal with the reason"
    ck false, "the delete handler answered its refusal with the reason"

  # 9. Rename never replaces, even past the pre-check. `moveEntryNoReplace`
  #    is the step `renameFileTreeEntry` runs after its own checks; calling
  #    it directly with the target already in place is the race the spec
  #    names (a target that appears after the check), made deterministic.
  let race = joinPath(ws, cstring"race")
  writeText(joinPath(race, cstring"a.txt"), cstring"A")
  writeText(joinPath(race, cstring"b.txt"), cstring"B")
  let clashCode = $(await moveEntryNoReplace(joinPath(race, cstring"a.txt"),
                                            joinPath(race, cstring"b.txt")))
  ck clashCode == "EEXIST",
    "a file renamed onto an existing file is refused (got '" & clashCode & "')"
  ck $readText(joinPath(race, cstring"b.txt")) == "B" and
      $readText(joinPath(race, cstring"a.txt")) == "A",
    "the existing file is not replaced, and the renamed one keeps its name"
  let movedCode = $(await moveEntryNoReplace(joinPath(race, cstring"a.txt"),
                                            joinPath(race, cstring"c.txt")))
  ck movedCode == "" and not exists(joinPath(race, cstring"a.txt")) and
      $readText(joinPath(race, cstring"c.txt")) == "A",
    "a file renamed to a free name has only its new name (got '" &
      movedCode & "')"
  # A folder onto an existing non-empty folder: refused by the operation
  # and by the step itself, and both folders keep their contents.
  writeText(joinPath(race, cstring"d1/x.txt"), cstring"x")
  writeText(joinPath(race, cstring"d2/y.txt"), cstring"y")
  let folderClash = await renameFileTreeEntry(joinPath(race, cstring"d1"),
                                              cstring"d2", ws)
  ck not folderClash.succeeded and
      folderClash.errorText == "\"d2\" already exists in this folder",
    "a folder renamed onto an existing folder is refused (got '" &
      folderClash.errorText & "')"
  let folderCode = $(await moveEntryNoReplace(joinPath(race, cstring"d1"),
                                             joinPath(race, cstring"d2")))
  ck folderCode == "EEXIST",
    "the folder step refuses a non-empty target folder (got '" &
      folderCode & "')"
  ck $readText(joinPath(race, cstring"d1/x.txt")) == "x" and
      $readText(joinPath(race, cstring"d2/y.txt")) == "y" and
      not exists(joinPath(race, cstring"d2/x.txt")),
    "both folders survive with their contents"

  # 10. A symbolic link inside the opened folder that points outside it.
  #     `path.resolve` alone passes `proj/out/keep.txt`; the folder the
  #     operation writes in must also be inside once links are resolved.
  let link = joinPath(ws, cstring"out")
  makeSymlink(outside, link)
  let viaLinkCreate = await createFileInFolder(link, cstring"planted.txt", ws)
  ck not viaLinkCreate.succeeded and
      "symbolic link" in viaLinkCreate.errorText and
      not exists(joinPath(outside, cstring"planted.txt")),
    "Create refuses a folder reached through a link out of the opened folder (got '" &
      viaLinkCreate.errorText & "')"
  let viaLinkRename = await renameFileTreeEntry(
    joinPath(link, cstring"keep.txt"), cstring"taken.txt", ws)
  ck not viaLinkRename.succeeded and
      "symbolic link" in viaLinkRename.errorText and
      $readText(joinPath(outside, cstring"keep.txt")) == "keep" and
      not exists(joinPath(outside, cstring"taken.txt")),
    "Rename refuses an entry reached through such a link (got '" &
      viaLinkRename.errorText & "')"
  let viaLinkDelete = await trashFileTreeEntry(
    joinPath(link, cstring"keep.txt"), ws)
  ck not viaLinkDelete.succeeded and
      "symbolic link" in viaLinkDelete.errorText and
      exists(joinPath(outside, cstring"keep.txt")),
    "Delete refuses an entry reached through such a link, before the trash " &
      "question (got '" & viaLinkDelete.errorText & "')"
  # The link itself is an entry of the opened folder, and is renamed as a
  # link: its target and the target's contents are untouched.
  let linkRenamed = await renameFileTreeEntry(link, cstring"out2", ws)
  let link2 = joinPath(ws, cstring"out2")
  ck linkRenamed.succeeded and isSymlink(link2) and not exists(link) and
      $readText(joinPath(outside, cstring"keep.txt")) == "keep",
    "a link is renamed as itself (error '" & linkRenamed.errorText & "')"

proc main() {.async.} =
  let dir = makeTempDir()
  try:
    await runCases(dir)
  except:
    inc failedChecks
    echo "  [FAILED] the suite raised: ", getCurrentExceptionMsg()
  removeDir(dir)
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks, " cases"
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

discard main()
