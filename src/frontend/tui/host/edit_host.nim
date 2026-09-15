## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the rule and what it buys.
##
## host/edit_host.nim — PLAT-16. THE FILESYSTEM SIDE OF EDIT MODE.
##
## `app/edit_binding.nim` owns buffers, carets and undo and does no I/O at all;
## this module is the only thing in the terminal front-end that reads or writes
## a file the user is editing. That split is the same one CTUI-3 made between
## `app/layout/profile.nim` and `app/layout/project.nim`, and it is what lets
## every editing behaviour be asserted at Tier 1 with no temporary directory.
##
## ## WHY A LISTING IS BOUNDED AND SORTED
##
## `listProjectFiles` walks the project once, skips the directories a source
## tree is mostly made of by weight (`.git`, `node_modules`, build output),
## sorts the result and STOPS at `MaxProjectFiles`. A file tree that walked an
## unbounded tree on startup would make `ct edit --ui=tui` on a monorepo look
## like a hang, and the alternate screen would already be claimed when it did —
## which is exactly the failure mode CTUI-14 recorded for the DAP handshake and
## `main.nim`'s "before the terminal is claimed" ordering exists to prevent.
##
## The cap is REPORTED (`ProjectListing.truncated`) rather than silent, because
## a file tree that is missing files without saying so is a file tree a user
## will conclude does not contain them.

import std/[algorithm, os, strutils]

import ./native_host

export TuiHostError

const
  MaxProjectFiles* = 2000
    ## The listing's ceiling. Large enough that no ordinary project reaches it,
    ## small enough that a stray checkout of a monorepo does not stall the
    ## first frame.

  SkippedDirectories* = [
    ".git", ".hg", ".svn", ".jj",
    "node_modules", "target", "build", "dist", "__pycache__",
    ".direnv", ".venv", "nimcache", ".nimcache"]
    ## Directories whose contents are not a user's source.
    ##
    ## A DENY LIST AND NOT AN ALLOW LIST, deliberately: an allow list of
    ## extensions would hide the file a user came to edit the moment their
    ## project uses a suffix nobody thought of, and "my file is not in the
    ## tree" is a worse failure than "the tree has a build directory in it".

  MaxEditFileBytes* = 8 * 1024 * 1024
    ## The largest file this editor opens.
    ##
    ## `EditBuffer` holds the whole file and `TextAreaWidget` splits it into one
    ## string per line, so opening a 2 GB core dump is not slow — it is a
    ## terminal that stops responding with the alternate screen claimed. Refused
    ## by name instead, which is a thing the user can act on.

proc editProjectProblem*(path: string): string =
  ## Why `path` cannot be opened in Edit mode, or "" when it can.
  ##
  ## SHAPED LIKE `native_host.traceFolderProblem` AND CALLED IN THE SAME PLACE
  ## — before the terminal is claimed — for the reason `main.nim` records about
  ## that one: a diagnosis printed onto a claimed alternate screen is a
  ## diagnosis nobody reads.
  ##
  ## A FILE IS REFUSED, and that is CodeTracer-TUI-Edit-Mode.md §8 open decision
  ## 1 applied: *"require a project, and refuse a bare file with a message — an
  ## editor that cannot build is not this product."* The message names the
  ## remedy rather than only the rule.
  if path.len == 0:
    return "no project folder was given"
  if fileExists(path):
    return "is a file; edit mode opens a PROJECT, so name its folder" &
      " (an editor that cannot build is not this product)"
  if not dirExists(path):
    return "no such folder"
  result = ""

type
  ProjectListing* = object
    ## What `listProjectFiles` found.
    files*: seq[string]
      ## Project-relative paths, sorted, at most `MaxProjectFiles` of them.
    truncated*: bool
      ## Whether the walk hit the cap. Reported so the file tree can say so;
      ## see the module header.
    scanned*: int
      ## How many files the walk saw before the cap, INCLUDING the ones it
      ## kept. A non-vacuity floor for a test: a listing of zero over a
      ## directory that has files is a defect, and `scanned` is what tells the
      ## two apart.

proc listProjectFiles*(root: string): ProjectListing =
  ## Every source file under `root`, project-relative and sorted.
  result = ProjectListing(files: @[], truncated: false, scanned: 0)
  if not dirExists(root):
    return
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    var entries: seq[(PathComponent, string)] = @[]
    try:
      for kind, entry in walkDir(dir):
        entries.add (kind, entry)
    except OSError:
      # An unreadable directory is skipped rather than fatal: a project with
      # one root-owned subdirectory in it is still a project, and refusing the
      # whole listing would make the editor unopenable for a reason the user
      # did not ask about.
      continue
    for (kind, entry) in entries:
      let name = extractFilename(entry)
      case kind
      of pcDir, pcLinkToDir:
        if name.startsWith(".") and name notin [".config", ".github"]:
          continue
        if name in SkippedDirectories:
          continue
        stack.add entry
      of pcFile, pcLinkToFile:
        inc result.scanned
        if result.files.len >= MaxProjectFiles:
          result.truncated = true
          continue
        var rel = entry
        if rel.startsWith(root):
          rel = rel[root.len .. ^1]
          while rel.len > 0 and (rel[0] == '/' or rel[0] == '\\'):
            rel = rel[1 .. ^1]
        result.files.add rel
  result.files.sort()

proc readProjectFile*(root, relative: string): string =
  ## The bytes of one file, refusing anything outside `root` or too large.
  ##
  ## THE CONTAINMENT CHECK IS ON THE RESOLVED PATH, not on the spelling: a
  ## `relative` of `../../etc/passwd` normalises to somewhere outside the
  ## project, and a check against the string before resolution would pass it.
  ## The same rule `src/ct/launch/project_definitions*` applies to a checkout,
  ## for the same reason.
  let resolvedRoot = absolutePath(root).normalizedPath
  let full = absolutePath(resolvedRoot / relative).normalizedPath
  if not (full == resolvedRoot or full.startsWith(resolvedRoot & DirSep)):
    raise newException(TuiHostError,
      relative & ": is outside the project folder")
  if not fileExists(full):
    raise newException(TuiHostError, relative & ": no such file")
  let info = getFileInfo(full)
  if info.size > MaxEditFileBytes:
    raise newException(TuiHostError,
      relative & ": is " & $(info.size div 1024) & " KiB and this editor" &
      " holds a whole file in memory; the ceiling is " &
      $(MaxEditFileBytes div (1024 * 1024)) & " MiB")
  try:
    readFile(full)
  except IOError as e:
    raise newException(TuiHostError, relative & ": " & e.msg)

proc writeProjectFile*(root, relative, text: string) =
  ## Write one buffer back, under the same containment rule as the read.
  let resolvedRoot = absolutePath(root).normalizedPath
  let full = absolutePath(resolvedRoot / relative).normalizedPath
  if not (full == resolvedRoot or full.startsWith(resolvedRoot & DirSep)):
    raise newException(TuiHostError,
      relative & ": is outside the project folder")
  try:
    writeFile(full, text)
  except IOError as e:
    raise newException(TuiHostError, relative & ": " & e.msg)
