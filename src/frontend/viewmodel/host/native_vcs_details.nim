## viewmodel/host/native_vcs_details.nim — PLAT-50: the two VCS reads the
## desktop's VCS panel makes on a CLICK, for the native front-ends.
##
## The desktop's panel answers a click on a changed file with that file's diff
## (`isonim_vcs_view` → `openFileDiff`) and a click on a commit with the files
## that commit changed (`ui/vcs.nim`, `git diff-tree`), whose own click opens
## that file's change in the commit. The platform facade
## (`platform/vcs.VcsFacade`) carries the working tree's diff but no commit
## reads, so the commit half runs the same `git` the desktop runs; both answer
## TEXT the front-ends draw (the diff's own lines, `+` / `-` / `@@`).
##
## Native only (a subprocess), as `native_vcs` is.

import std/[os, osproc, streams, strutils]

import ../platform/outcome
import ./native_vcs

type
  CommitFile* = tuple[status, path: string]

proc runGit(repository: string; args: seq[string]): (bool, string) =
  try:
    let child = startProcess("git", workingDir = repository, args = args,
                             options = {poUsePath})
    let output = child.outputStream.readAll()
    discard child.errorStream.readAll()
    let code = child.waitForExit()
    child.close()
    (code == 0, output)
  except CatchableError as err:
    (false, err.msg)

proc commitChangedFiles*(repository, hash: string): seq[CommitFile] =
  ## The files commit `hash` changed, with their state letter — the desktop's
  ## `git diff-tree --no-commit-id -r --name-status <hash>` (`ui/vcs.nim`,
  ## its fallback form), which works for a root commit too (`--root`).
  let (ok, text) = runGit(repository, @["diff-tree", "--root", "--no-commit-id",
                                        "-r", "--name-status", hash])
  if not ok:
    return
  for line in text.splitLines():
    let parts = line.split('\t')
    if parts.len >= 2 and parts[0].len > 0:
      # A rename / copy (`R100`, `C75`) names its old and new paths; the
      # file is the new one, its letter the first.
      result.add ($parts[0][0], parts[^1])

proc commitFileDiff*(repository, hash, path: string): string =
  ## The change commit `hash` made to `path`, as a unified diff.
  let (ok, text) = runGit(repository, @["show", "--format=", "--unified=3",
                                        hash, "--", path])
  if ok: text else: ""

proc workingTreeFileDiff*(repository, path, status: string): string =
  ## The working tree's change to `path` — the facade's `diff` (`git diff`),
  ## and for a file git does not track yet (`?`) or has only staged (`A`),
  ## whose `git diff` is empty, the whole file as added lines, which is what
  ## the desktop's diff view shows for a new file.
  let facade = nativeVcs(NativeVcsProfile)
  var text = ""
  for staged in [false, true]:
    let res = awaitSync(facade.diff(repository, @[path], staged, 3))
    if res.ok and res.value.strip().len > 0:
      text = res.value
      break
  if text.len > 0 or status notin ["?", "A"]:
    return text
  try:
    let content = readFile(repository / path)
    result = "--- /dev/null\n+++ b/" & path & "\n"
    let lines = content.splitLines()
    let n = if lines.len > 0 and lines[^1].len == 0: lines.len - 1
            else: lines.len
    result.add "@@ -0,0 +1," & $n & " @@\n"
    for i in 0 ..< n:
      result.add "+" & lines[i] & "\n"
  except CatchableError:
    result = ""
