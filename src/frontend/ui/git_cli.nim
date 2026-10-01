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

# NS1 (Noir-Studio.milestones.org, the platform facade). Every host call this
# module used to make inline — `require('child_process')`, `require('fs')`,
# `require('os')`, `require('path')` — now goes through the facade, which is
# what makes `ui/vcs.nim` and `ui/unified_diff.nim` host-free too: they reach
# the host only through this file.
from ../platform_host import
  ctPlatform, ctAwaitSync, can, canAll, capFilesystemRead, capProcessSpawn,
  capProcessArbitraryPrograms, capVcsWrite, ProcessSpec, Platform,
  PlatformOutcome, PlatformFutureT, ProcessRunResult, Nothing, process, fs, vcs,
  succeededExit, onComplete, pkTimeout, `$`

import std/tables

const gitTimeoutMs = 5000

# ---------------------------------------------------------------------------
# THE ONE-TICK-LATE CACHE, and why a renderer needs one at all.
#
# Every proc in this file is synchronous: `gitExec` returns a `cstring` into a
# render path, and `ui/vcs.nim` alone calls it from about twenty places. That
# was fine while the only instantiation that could run git was Electron's,
# whose process facade is synchronous underneath — `ctAwaitSync` drains once
# and the answer is there.
#
# The container instantiation's answer arrives on a socket. `ctAwaitSync`
# therefore returns `pkTimeout` naming itself, which is exactly what it is for
# (`platform/outcome.nim`: "the day one of these call sites runs against the
# container instantiation, it reports 'this call site still needs
# converting'"). Left at that, WD1b would deliver an honest capability profile
# and a VCS panel that is still blank — the capability would be advertised and
# the panel would show nothing, which is the same user-visible outcome as
# before with a better excuse.
#
# So the bridge is here, ONCE, instead of at twenty call sites: a call that
# cannot be answered synchronously answers with what was learned last time and
# re-asks. When the reply arrives the memo is updated and the redraw hook
# fires, so the panel that rendered empty renders again with the answer.
#
# Three properties this shape has to have, and each is a defect if missing:
#
#   * **The desktop is untouched.** `ctAwaitSync` settles there, the memo is
#     never read and never written, and the path is the one it was before.
#     This is not an optimisation: a memo in front of a synchronous git would
#     make the panel show stale data after a commit.
#   * **Re-render must not re-ask.** A redraw calls `gitExec` again, so an
#     in-flight key is recorded and a second call for it issues nothing. A
#     renderer that spawned one process per frame would never converge, and
#     the hook makes the redraw happen, so this is a live loop rather than a
#     theoretical one.
#   * **The hook fires only on CHANGE.** Re-asking after the answer is in the
#     memo would produce the same bytes, redraw, re-ask, redraw for ever. The
#     redraw happens when the value is new.
# ---------------------------------------------------------------------------

var gitMemo: Table[string, tuple[output: string, ok: bool]]
var gitInFlight: Table[string, bool]
var gitRedraw: proc() = nil

proc setGitRefreshHook*(hook: proc()) =
  ## What to call when a git answer arrives after the render that asked for it.
  ##
  ## Registered by the renderer entry point. Nil is a valid state and is the
  ## one every headless suite is in: the memo still fills, nothing redraws, and
  ## the next call reads the answer.
  gitRedraw = hook

proc memoKey(verb: string; args: seq[cstring]; cwd: cstring): string =
  # `\x1f` because it cannot occur in a path or a git argument, so two
  # different calls cannot collide by concatenation — the mistake a space or a
  # comma would make the moment a branch name contains one.
  result = verb & "\x1f" & (if cwd.isNil: "" else: $cwd)
  for a in args:
    result.add "\x1f"
    result.add $a

proc remember(key: string; value: tuple[output: string, ok: bool]) =
  let changed = not gitMemo.hasKey(key) or gitMemo[key] != value
  gitMemo[key] = value
  gitInFlight.del(key)
  if changed and gitRedraw != nil:
    gitRedraw()


proc runGit(args: seq[cstring]; cwd: cstring): tuple[output: string, ok: bool] =
  ## One git invocation, through the platform facade.
  ##
  ## NS1: this used to be `require('child_process').execFileSync` inline, which
  ## works on exactly one of the three platforms the facade serves. It is now a
  ## `ProcessSpec` — argv, never a shell string, so no caller needs `quoteShell`
  ## and no platform needs a shell.
  ##
  ## ## What is still to do here, stated rather than hidden
  ##
  ## This routes git through the PROCESS facade, not the VCS facade. That
  ## removes the direct host call and is what makes `ui/vcs.nim` and
  ## `ui/unified_diff.nim` host-free for free — they only ever reached the host
  ## through this function. It does not yet make the web instantiation work:
  ## a tab has no git binary, so every call below degrades to "". The
  ## remaining work is mapping `ui/vcs.nim`'s fifteen git invocations onto
  ## `VcsFacade`'s operations, which is what lets the browser serve them from a
  ## real object store (Noir-Studio.md §6.2a). `viewmodel/platform/vcs.nim`
  ## already defines every operation that mapping needs.
  ##
  ## ## Why the guard names TWO capabilities
  ##
  ## It used to be `capProcessSpawn` alone, with "a tab has no git binary" as
  ## its stated meaning. NS3 made that stop being true without changing a type:
  ## §3.1's web column is "wasm modules in the tab", so a web platform with a
  ## populated module registry genuinely HAS `capProcessSpawn` — and this guard
  ## would have opened, sent `git` to a registry that has no such module, and
  ## turned a capability check into a per-call refusal. The sentence in the
  ## comment would have been false while every signature still lined up.
  ##
  ## `capProcessArbitraryPrograms` is the one that carries the old meaning:
  ## can this platform run a program it was not built knowing about? Both are
  ## named rather than only the second, because "spawn at all" and "spawn
  ## anything" are the two separate questions this call needs answered yes.
  if not ctPlatform().canAll({capProcessSpawn, capProcessArbitraryPrograms}):
    return ("", false)
  var argv: seq[string] = @[]
  for arg in args:
    argv.add $arg
  let key = memoKey("run", args, cwd)
  if gitInFlight.hasKey(key):
    # A call for this exact question is already out. Issuing a second one here
    # is the live loop the header names: the redraw hook brings every caller
    # back, and a render that spawned a git process per frame would never
    # settle. On the desktop this map is never populated, so this branch is
    # unreachable there.
    return (if gitMemo.hasKey(key): gitMemo[key] else: ("", false))
  let future = ctPlatform().process.run(ProcessSpec(
    command: "git",
    args: argv,
    workingDir: (if cwd.isNil: "" else: $cwd),
    timeoutMs: gitTimeoutMs))
  let outcome = ctAwaitSync(future)
  if outcome.ok:
    return (outcome.value.stdout, outcome.value.exit.succeededExit)
  if outcome.error.kind != pkTimeout:
    # A real failure — no git, a bad revision, a non-repository. Answering ""
    # is this module's contract and always has been; caching it would pin the
    # failure past the condition that caused it.
    return ("", false)

  # The instantiation is remote. Subscribe, answer from the memo, and let the
  # redraw hook bring the caller back.
  gitInFlight[key] = true
  future.onComplete(
    proc(settled: PlatformOutcome[ProcessRunResult]) =
      if settled.ok:
        remember(key, (settled.value.stdout, settled.value.exit.succeededExit))
      else:
        remember(key, ("", false)),
    proc(message: string) = remember(key, ("", false)))
  if gitMemo.hasKey(key): gitMemo[key] else: ("", false)

proc gitExec*(args: seq[cstring], cwd: cstring): cstring =
  ## Run a git command in the given working directory.
  ## Returns the trimmed stdout output, or an empty string on error.
  let (output, ok) = runGit(args, cwd)
  if not ok:
    return cstring""
  output.strip().cstring

proc fsReadTextFile*(path: cstring): cstring =
  ## A file's text, or "" when it cannot be read.
  ##
  ## The empty-on-missing behaviour is deliberate and predates NS1: the working
  ## tree of a diff can legitimately no longer contain the path, so a missing
  ## file is an ordinary outcome here and must not surface as an exception in
  ## the middle of a render. What changed is where the guard lives — it was an
  ## inline `try/catch` in the JS binding, and it is now the facade's outcome,
  ## which distinguishes `pkNotFound` from `pkAccessDenied` for any caller that
  ## later wants to.
  if not ctPlatform().can(capFilesystemRead):
    return cstring""
  let key = memoKey("readText", @[path], nil)
  if gitInFlight.hasKey(key):
    return (if gitMemo.hasKey(key): gitMemo[key].output.cstring else: cstring"")
  let future = ctPlatform().fs.readText($path)
  let outcome = ctAwaitSync(future)
  if outcome.ok:
    return outcome.value.cstring
  if outcome.error.kind != pkTimeout:
    return cstring""
  # Remote, exactly as `runGit` above: see the note beside `gitMemo`.
  gitInFlight[key] = true
  future.onComplete(
    proc(settled: PlatformOutcome[string]) =
      let text = if settled.ok: settled.value else: ""
      remember(key, (text, settled.ok)),
    proc(message: string) = remember(key, ("", false)))
  if gitMemo.hasKey(key): gitMemo[key].output.cstring else: cstring""

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
               else: ($cwd) / ($path)
    return cstring(stripTrailingNewline($fsReadTextFile(cstring(full))))
  # Deliberately not `gitExec`: that one strips ALL trailing whitespace, and a
  # file's content is not a command's output — a blob whose last line is blank
  # must come back with it.
  let (output, ok) = runGit(
    @[cstring"show", cstring($revision & ":" & $path)], cwd)
  if not ok:
    return cstring""
  cstring(stripTrailingNewline(output))

proc applyPatchToIndex*(patch, cwd: cstring) =
  ## Stage a patch with ``git apply --cached``, through a temporary file
  ## because git reads the patch from a path rather than from argv.
  # NS1: `applyPatch` is a first-class VCS-facade operation precisely because
  # "write a temp file and shell out" is the desktop's implementation detail
  # rather than the intent — a browser has no temp directory to write to and no
  # git to point at it. The facade takes the patch text and lets each
  # instantiation decide how to feed it to git.
  if not ctPlatform().can(capVcsWrite):
    cerror "Failed to stage hunks: version control is not available here"
    return
  let future = ctPlatform().vcs.applyPatch(
    (if cwd.isNil: "" else: $cwd), $patch, reverse = false)
  let outcome = ctAwaitSync(future)
  if outcome.ok:
    return
  if outcome.error.kind != pkTimeout:
    cerror "Failed to stage hunks: " & $outcome.error
    return
  # NOT memoised, and the difference from the two readers above is the point:
  # this is a user's ACTION rather than a value a render wants. There is
  # nothing to answer with now and nothing to cache — what the user needs is to
  # be told if it failed, whenever that is known. So the subscription reports
  # and nothing else happens here.
  future.onComplete(
    proc(settled: PlatformOutcome[Nothing]) =
      if not settled.ok:
        cerror "Failed to stage hunks: " & $settled.error
      elif gitRedraw != nil:
        # The index changed under the panel, and nothing else will notice.
        gitMemo.clear()
        gitRedraw(),
    proc(message: string) =
      cerror "Failed to stage hunks: " & message)

proc isGitRepository*(cwd: cstring): bool =
  ## Check whether `cwd` is inside a git working tree.
  let result_str = gitExec(@[cstring"rev-parse", cstring"--is-inside-work-tree"], cwd)
  return result_str == cstring"true"

proc gitWorkingDirectory*(data: Data): cstring =
  ## Working directory for git commands: the opened project folder, or empty to
  ## mean **the platform's default**.
  ##
  ## ## This is a behaviour fix, not only a migration
  ##
  ## The fallback used to be `electronProcess.cwd()`, and `ProcessSpec.workingDir`
  ## says that is wrong on every platform rather than merely unavailable on the
  ## web: "Empty means the platform's default, which on the web is the project
  ## store root and in a container is the workspace root. **Never the front
  ## end's own cwd — a front end has no business having one.**" A renderer
  ## reading `process.cwd()` is asserting that the process's directory is the
  ## right place to run a user's git command, which is a fact about how the app
  ## was launched, not about the project.
  ##
  ## **On the desktop the observable behaviour is unchanged**, and that is
  ## checked rather than assumed: every consumer passes this value into a git
  ## command's `cwd` and none of them branches on its emptiness or displays it,
  ## `runGit` turns it into `ProcessSpec.workingDir`, and both desktop
  ## instantiations resolve an empty one to the process's own directory —
  ## `osproc.startProcess` by definition, and node's `execFileSync` through
  ## `cwd: (# || undefined)`. So the deleted line was computing by hand exactly
  ## what the platform already does. `test_empty_working_dir_is_the_platforms_default_not_the_callers_cwd`
  ## in `test_platform_desktop_native.nim` pins that, in both directions.
  ##
  ## What changes is the web, where there is no process directory to read and
  ## the store root is the right answer — and which platform decides.
  let folder = data.startOptions.folder
  if not folder.isNil and folder.len > 0:
    return folder
  cstring""

proc gitRepositoryRoot*(data: Data): cstring =
  ## Absolute path of the git work tree root.
  ##
  ## Use this, NOT `gitWorkingDirectory`, for any command carrying a `--`
  ## pathspec.  Git resolves a pathspec against the CURRENT DIRECTORY, while
  ## every path the VCS panel holds comes from `git diff-tree --numstat`, which
  ## reports relative to the repository ROOT.  When the opened project folder is
  ## a subdirectory the two disagree and git silently matches nothing — no
  ## error, just an empty diff, because an empty diff is a legitimate answer.
  ##
  ## `rev-parse --show-toplevel` returns empty outside a work tree, so the
  ## working directory stays the fallback.
  let cwd = gitWorkingDirectory(data)
  let top = gitExec(@[cstring"rev-parse", cstring"--show-toplevel"], cwd)
  if top.isNil or top.len == 0: cwd else: top

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
