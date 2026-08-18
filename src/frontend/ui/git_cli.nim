## Git command-line access and unified-diff parsing, shared by the VCS panel
## and the unified-diff editor tabs it opens.
##
## Git data is fetched with structured `git` argv calls via Node.js
## `child_process` (available in Electron's renderer process with
## nodeIntegration enabled).
##
## The module exists because DR-R4 split the diff *tab* out of the VCS panel:
## both need to shell out to git, and the tab must not import the panel (the
## panel imports the tab, to open it).  Nothing here knows about either
## surface.

import ui_imports

type
  ExecSyncOptions* = ref object
    cwd*: cstring
    encoding*: cstring
    timeout*: int

proc execFileSyncRaw*(program: cstring, args: seq[cstring],
                      opts: ExecSyncOptions): cstring
  {.importjs: "require('child_process').execFileSync(#, #, #).toString()".}
proc fsWriteFileSync*(path, content: cstring)
  {.importjs: "require('fs').writeFileSync(#, #)".}
proc fsUnlinkSync*(path: cstring) {.importjs: "require('fs').unlinkSync(#)".}
proc osTmpdir*(): cstring {.importjs: "require('os').tmpdir()".}
proc pathJoin*(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc dateNow*(): int {.importjs: "Date.now()".}

proc gitExec*(args: seq[cstring], cwd: cstring): cstring =
  ## Run a git command in the given working directory.
  ## Returns the trimmed stdout output, or an empty string on error.
  try:
    let opts = ExecSyncOptions(cwd: cwd, encoding: cstring"utf8", timeout: 5000)
    let raw = execFileSyncRaw(cstring"git", args, opts)
    if raw.isNil:
      return cstring""
    # Trim trailing whitespace / newlines.
    return ($raw).strip().cstring
  except:
    return cstring""

proc fsReadTextFile*(path: cstring): cstring
  {.importjs: """(function(p) {
    try { return require('fs').readFileSync(p, 'utf8'); } catch (e) { return ''; }
  })(#)""".}
  ## A file's text, or "" when it cannot be read.  The guard is on the JS side
  ## because a missing file is an ordinary outcome here — the working tree of a
  ## diff can legitimately no longer contain the path — and must not surface as
  ## an exception in the middle of a render.

proc stripTrailingNewline(text: string): string =
  ## Drop the one line terminator a file ends with.
  ##
  ## Without this, splitting the text into lines yields a phantom final empty
  ## line, and context expansion would offer to reveal it as if it were content
  ## of the file.
  result = text
  if result.len > 0 and result[^1] == '\n':
    result.setLen(result.len - 1)
  if result.len > 0 and result[^1] == '\r':
    result.setLen(result.len - 1)

proc gitFileText*(revision, path, cwd: cstring): cstring =
  ## The full text of ``path`` on the *new* side of a diff.
  ##
  ## DeepReview-GUI.md §4.2: "In normal version-control mode the surrounding
  ## lines are not part of the diff and must be fetched from the repository
  ## (e.g. `git show <rev>:<path>`) before they can be revealed."
  ##
  ## An empty ``revision`` means the working tree — the new side of `git diff
  ## HEAD` is the tree on disk, and no revision of the repository holds it — so
  ## that case reads the file rather than asking git for a blob.
  ##
  ## Deliberately NOT routed through ``gitExec``: that one strips the output at
  ## both ends, which would eat the indentation of the file's first line and
  ## silently shift the revealed text left.  Only the trailing terminator is
  ## removed here.
  ##
  ## Returns "" on any failure, which callers read as "nothing can be
  ## revealed" rather than as an empty file — the two are indistinguishable and
  ## both mean the same thing for an expand control.
  if revision.isNil or ($revision).len == 0:
    let full = if cwd.isNil or ($cwd).len == 0: $path
               else: $pathJoin(cwd, path)
    return cstring(stripTrailingNewline($fsReadTextFile(cstring(full))))
  try:
    let opts = ExecSyncOptions(cwd: cwd, encoding: cstring"utf8", timeout: 5000)
    let raw = execFileSyncRaw(cstring"git",
      @[cstring"show", cstring($revision & ":" & $path)], opts)
    if raw.isNil:
      return cstring""
    return cstring(stripTrailingNewline($raw))
  except:
    return cstring""

proc applyPatchToIndex*(patch, cwd: cstring) =
  ## Stage a patch with ``git apply --cached``, through a temporary file
  ## because git reads the patch from a path rather than from argv.
  let tmpFile = pathJoin(osTmpdir(), cstring("ct-hunk-stage-" & $dateNow() & ".patch"))
  fsWriteFileSync(tmpFile, patch)
  try:
    let opts = ExecSyncOptions(cwd: cwd, encoding: cstring"utf8", timeout: 5000)
    discard execFileSyncRaw(cstring"git", @[cstring"apply", cstring"--cached", tmpFile], opts)
  except:
    cerror "Failed to stage hunks: " & getCurrentExceptionMsg()
  finally:
    try:
      fsUnlinkSync(tmpFile)
    except:
      discard

proc isGitRepository*(cwd: cstring): bool =
  ## Check whether `cwd` is inside a git working tree.
  let result_str = gitExec(@[cstring"rev-parse", cstring"--is-inside-work-tree"], cwd)
  return result_str == cstring"true"

proc gitWorkingDirectory*(data: Data): cstring =
  ## Working directory for git commands: the opened project folder, falling
  ## back to the process's own.
  let folder = data.startOptions.folder
  if not folder.isNil and folder.len > 0:
    return folder
  electronProcess.cwd()

proc parseGitDiffHunks*(diffOutput: string): seq[DeepReviewFileData] =
  ## Parse the output of ``git diff`` into ``DeepReviewFileData`` values.
  ##
  ## The same shape a DeepReview export carries, so one renderer serves both
  ## data sources — VCS-Panel.md, "Unified Diff View (Shared)": "The diff
  ## rendering code does NOT check which mode is active — it simply renders
  ## whatever data is provided."
  ##
  ## The parser handles the standard unified diff format:
  ##   diff --git a/<path> b/<path>
  ##   --- a/<path>
  ##   +++ b/<path>
  ##   @@ -oldStart,oldCount +newStart,newCount @@ optional header
  ##    context line
  ##   -removed line
  ##   +added line
  result = @[]
  if diffOutput.len == 0:
    return

  var currentFile: DeepReviewFileData = nil
  var currentHunk: DeepReviewHunk = nil
  var oldLineNum = 0
  var newLineNum = 0

  for rawLine in diffOutput.splitLines():
    # New file header.
    if rawLine.startsWith("diff --git "):
      # Flush previous file.
      if not currentHunk.isNil and not currentFile.isNil:
        currentFile.diff.hunks.add(currentHunk)
        currentHunk = nil
      if not currentFile.isNil:
        result.add(currentFile)

      # Extract path from "diff --git a/<path> b/<path>".
      let bIdx = rawLine.find(" b/")
      let filePath = if bIdx >= 0: rawLine[bIdx + 3 .. ^1] else: ""

      currentFile = DeepReviewFileData(
        path: cstring(filePath),
        diff: DeepReviewFileDiff(
          status: cstring"M",
          linesAdded: 0,
          linesRemoved: 0,
          hunks: @[]),
        symbols: @[],
        coverage: @[],
        functions: @[],
        loops: @[],
        flow: @[])
      continue

    if currentFile.isNil:
      continue

    # Detect new / deleted file markers.
    if rawLine.startsWith("new file mode"):
      currentFile.diff.status = cstring"A"
      continue
    if rawLine.startsWith("deleted file mode"):
      currentFile.diff.status = cstring"D"
      continue

    # Skip index, --- and +++ lines.
    if rawLine.startsWith("index ") or rawLine.startsWith("--- ") or
       rawLine.startsWith("+++ "):
      continue

    # Hunk header: @@ -oldStart,oldCount +newStart,newCount @@
    if rawLine.startsWith("@@ "):
      if not currentHunk.isNil:
        currentFile.diff.hunks.add(currentHunk)

      var hunkOldStart = 0
      var hunkOldCount = 0
      var hunkNewStart = 0
      var hunkNewCount = 0

      # Parse the @@ line. Format: @@ -A,B +C,D @@
      let atEnd = rawLine.find(" @@", 3)
      if atEnd > 0:
        let hunkRange = rawLine[3 ..< atEnd]  # e.g. "-10,5 +10,8"
        let parts = hunkRange.split(" ")
        if parts.len >= 2:
          # Parse old range (-A,B or -A).
          var oldPart = parts[0]
          if oldPart.startsWith("-"):
            oldPart = oldPart[1 .. ^1]
          let oldParts = oldPart.split(",")
          try: hunkOldStart = parseInt(oldParts[0])
          except ValueError: discard
          if oldParts.len > 1:
            try: hunkOldCount = parseInt(oldParts[1])
            except ValueError: discard
          else:
            hunkOldCount = 1

          # Parse new range (+C,D or +C).
          var newPart = parts[1]
          if newPart.startsWith("+"):
            newPart = newPart[1 .. ^1]
          let newParts = newPart.split(",")
          try: hunkNewStart = parseInt(newParts[0])
          except ValueError: discard
          if newParts.len > 1:
            try: hunkNewCount = parseInt(newParts[1])
            except ValueError: discard
          else:
            hunkNewCount = 1

      currentHunk = DeepReviewHunk(
        oldStart: hunkOldStart,
        oldCount: hunkOldCount,
        newStart: hunkNewStart,
        newCount: hunkNewCount,
        lines: @[])
      oldLineNum = hunkOldStart
      newLineNum = hunkNewStart
      continue

    # Diff content lines (within a hunk).
    if currentHunk.isNil:
      continue

    if rawLine.startsWith("+"):
      let content = rawLine[1 .. ^1]
      currentHunk.lines.add(DeepReviewHunkLine(
        `type`: cstring"added",
        content: cstring(content),
        oldLine: 0,
        newLine: newLineNum))
      currentFile.diff.linesAdded += 1
      newLineNum += 1
    elif rawLine.startsWith("-"):
      let content = rawLine[1 .. ^1]
      currentHunk.lines.add(DeepReviewHunkLine(
        `type`: cstring"removed",
        content: cstring(content),
        oldLine: oldLineNum,
        newLine: 0))
      currentFile.diff.linesRemoved += 1
      oldLineNum += 1
    elif rawLine.startsWith(" ") or rawLine.len == 0:
      # Context line (starts with space) or empty line within a hunk.
      let content = if rawLine.len > 0: rawLine[1 .. ^1] else: ""
      currentHunk.lines.add(DeepReviewHunkLine(
        `type`: cstring"context",
        content: cstring(content),
        oldLine: oldLineNum,
        newLine: newLineNum))
      oldLineNum += 1
      newLineNum += 1

  # Flush the last hunk and file.
  if not currentHunk.isNil and not currentFile.isNil:
    currentFile.diff.hunks.add(currentHunk)
  if not currentFile.isNil:
    result.add(currentFile)
