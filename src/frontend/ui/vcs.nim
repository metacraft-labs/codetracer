## VCS (Version Control System) panel component.
##
## A lazygit-style integrated version control panel shown as a Golden Layout
## component. Displays: branch picker, commit history, and changed files for
## the selected commit.
##
## In DeepReview mode (``data.deepReviewActive``), the panel switches to
## showing the review's changed files from ``data.deepReviewData.files``
## instead of git data.  Clicking a file updates
## ``data.deepReviewSelectedFileIndex`` which the DeepReview component reads
## to decide which file's diff to render.
##
## Git data is fetched with structured `git` argv calls via Node.js
## `child_process` (available in Electron's renderer process with
## nodeIntegration enabled).

import
  ui_imports

import deepreview
import ../viewmodel/viewmodels/vcs_vm

when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_vcs_view import
    mountIsoNimVCSPanel, VCSCallbacks

var vcsVMInstances*: JsAssoc[int, VCSVM] = JsAssoc[int, VCSVM]{}
var vcsComponentRefs: JsAssoc[int, VCSComponent] = JsAssoc[int, VCSComponent]{}
var isoNimVCSMountedIds {.used.}: JsAssoc[int, bool] = JsAssoc[int, bool]{}

proc syncLegacyVCSIntoVM*(self: VCSComponent)
proc tryMountIsoNimVCSPanel*(componentId: int)

# ---------------------------------------------------------------------------
# Node.js child_process bindings (renderer process, nodeIntegration=true)
# ---------------------------------------------------------------------------

type
  ExecSyncOptions = ref object
    cwd*: cstring
    encoding*: cstring
    timeout*: int

proc execFileSyncRaw(program: cstring, args: seq[cstring], opts: ExecSyncOptions): cstring
  {.importjs: "require('child_process').execFileSync(#, #, #).toString()".}
proc fsWriteFileSync(path, content: cstring) {.importjs: "require('fs').writeFileSync(#, #)".}
proc fsUnlinkSync(path: cstring) {.importjs: "require('fs').unlinkSync(#)".}
proc osTmpdir(): cstring {.importjs: "require('os').tmpdir()".}
proc pathJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc dateNow(): int {.importjs: "Date.now()".}

proc gitExec(args: seq[cstring], cwd: cstring): cstring =
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

proc applyPatchToIndex(patch, cwd: cstring) =
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

proc isGitRepository(cwd: cstring): bool =
  ## Check whether `cwd` is inside a git working tree.
  let result_str = gitExec(@[cstring"rev-parse", cstring"--is-inside-work-tree"], cwd)
  return result_str == cstring"true"

# ---------------------------------------------------------------------------
# File watching constants (Task #68)
# ---------------------------------------------------------------------------

const
  refreshIntervalMs = 5000
    ## Periodic auto-refresh interval in milliseconds.
  debounceMs = 1000
    ## Minimum interval between successive refreshes.

# ---------------------------------------------------------------------------
# Data loading helpers
# ---------------------------------------------------------------------------

proc loadCurrentBranch(self: VCSComponent, cwd: cstring) =
  self.currentBranch = gitExec(@[cstring"branch", cstring"--show-current"], cwd)
  if self.currentBranch.len == 0:
    # Detached HEAD -- show abbreviated hash instead.
    self.currentBranch = gitExec(@[cstring"rev-parse", cstring"--short", cstring"HEAD"], cwd)

proc loadBranches(self: VCSComponent, cwd: cstring) =
  let raw = gitExec(@[cstring"branch", cstring"--format=%(refname:short)"], cwd)
  self.branches = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len > 0:
        self.branches.add(cstring(trimmed))

# ---------------------------------------------------------------------------
# Commit graph lane-tracking algorithm
# ---------------------------------------------------------------------------

const commitPageSize = 50
  ## Number of commits fetched per page for the infinite-scroll commit graph.

const branchPalette = [
  "#818CF8", "#FB923C", "#4ADE80",
  "#F472B6", "#38BDF8", "#A78BFA",
]
  ## Colour palette cycled across branch lanes.
  ## Mirrors ``branchColors`` in ``isonim_vcs_view.nim``.

type GraphLane = object
  waitingFor: string ## full hash this lane is tracking towards
  colorIdx: int      ## index into branchPalette

type GraphRow = object
  ## Per-commit graph data: lane cells, dot position, and merge connectors.
  cells: seq[VCSGraphCell]
  dotLane: int                       ## column of the commit dot (-1 = none)
  connectors: seq[VCSGraphConnector] ## bezier connectors for this row

proc computeGraphRows(commits: seq[VCSCommit]): seq[GraphRow] =
  ## Assign branch-graph columns to each commit, computing merge/fork connectors.
  ##
  ## Algorithm (newest → oldest):
  ##
  ##  1. Collect ALL lanes waiting for this commit's hash.  The first match is
  ##     the "primary" lane that becomes the dot position.  Any additional
  ##     matches are lanes whose branches **converge** here (fork in forward
  ##     time) — they get a connector drawn back to the dot lane and are then
  ##     cleared.
  ##  2. If no lane claims the commit, open a fresh lane (branch tip).
  ##  3. Build the row cells: gckDot at the primary lane, gckLine at every other
  ##     active lane, gckEmpty otherwise.
  ##  4. Advance the primary lane to the first parent, or clear it for roots.
  ##  5. For each additional merge parent open a new lane and record a connector
  ##     so the view can draw a right-angle curve to it.
  ##  6. **Lane compaction**: remove lanes whose ``waitingFor`` is empty so that
  ##     the graph doesn't grow unboundedly wide.  Each row's cells are built
  ##     using the pre-compaction indices so the visual stays correct.
  result = newSeq[GraphRow](commits.len)
  var lanes: seq[GraphLane] = @[]
  var nextColor = 0

  for i, commit in commits:
    let myHash = $commit.fullHash
    if myHash.len == 0:
      result[i] = GraphRow(dotLane: -1)
      continue

    # Collect all lanes that converge on this commit.
    var myLane = -1
    var convergeLanes: seq[int] = @[]   ## additional lanes that end here
    for j in 0 ..< lanes.len:
      if lanes[j].waitingFor == myHash:
        if myLane < 0:
          myLane = j           ## primary dot lane
        else:
          convergeLanes.add(j) ## branch that merges back here

    # No lane claimed us → new branch tip.
    # Reuse the first freed (empty) slot before appending a new column so
    # that lane positions stay stable and the graph doesn't grow unboundedly.
    if myLane < 0:
      for k in 0 ..< lanes.len:
        if lanes[k].waitingFor.len == 0:
          myLane = k
          lanes[myLane] = GraphLane(
            waitingFor: myHash,
            colorIdx: nextColor mod branchPalette.len,
          )
          inc nextColor
          break
      if myLane < 0:
        myLane = lanes.len
        lanes.add(GraphLane(
          waitingFor: myHash,
          colorIdx: nextColor mod branchPalette.len,
        ))
        inc nextColor

    # Build row cells (sized to current lane count).
    # Converging lanes use gckEmpty: the top-half connector (vcs-gc-conn-tl /
    # vcs-gc-conn-tr) provides the top-half vertical line and curve, so the
    # slot only needs to exist for width reservation — no extra line is drawn.
    var row = newSeq[VCSGraphCell](lanes.len)
    for j in 0 ..< lanes.len:
      if j == myLane:
        row[j] = VCSGraphCell(kind: gckDot, colorIdx: lanes[j].colorIdx)
      elif j in convergeLanes:
        row[j] = VCSGraphCell(kind: gckEmpty)  # connector draws the visual
      elif lanes[j].waitingFor.len > 0:
        row[j] = VCSGraphCell(kind: gckLine, colorIdx: lanes[j].colorIdx)
      # else gckEmpty (zero-value default)

    # Connectors: start with converging lanes (branches that forked from here
    # in forward time), then merge-parent lanes (extra parents of this commit).
    var connectors: seq[VCSGraphConnector] = @[]

    # Convergence connectors: curve from side lane back to dot lane.
    # ``isTop = true`` tells the view to draw the top-half of the connector
    # (from row top → row centre), matching the merge-in visual in the designer
    # reference where a feature branch curves back into the main lane.
    for cl in convergeLanes:
      connectors.add(VCSGraphConnector(
        fromLane: cl,
        toLane:   myLane,
        colorIdx: lanes[cl].colorIdx,
        isTop:    true,
      ))
      lanes[cl].waitingFor = ""  # this lane is done after convergence

    # Advance primary lane to first parent (or clear for root commits).
    if commit.parents.len > 0:
      lanes[myLane].waitingFor = $commit.parents[0]
    else:
      lanes[myLane].waitingFor = ""

    # Merge-parent connectors: each extra parent opens a new lane.
    # Reuse a freed slot before appending a new column; if no free slot
    # exists, append.  The slot uses gckEmpty — the branch-out connector
    # draws the bottom-half visual via its border-right / border-left.
    for pIdx in 1 ..< commit.parents.len:
      let extraColor = nextColor mod branchPalette.len
      inc nextColor
      var newLane = -1
      for k in 0 ..< lanes.len:
        if lanes[k].waitingFor.len == 0:
          newLane = k
          lanes[newLane] = GraphLane(
            waitingFor: $commit.parents[pIdx],
            colorIdx: extraColor,
          )
          break
      if newLane < 0:
        newLane = lanes.len
        row.add(VCSGraphCell(kind: gckEmpty))  # slot for width; connector draws the visual
        lanes.add(GraphLane(
          waitingFor: $commit.parents[pIdx],
          colorIdx: extraColor,
        ))
      connectors.add(VCSGraphConnector(
        fromLane: myLane,
        toLane:   newLane,
        colorIdx: extraColor,
      ))

    result[i] = GraphRow(cells: row, dotLane: myLane, connectors: connectors)

    # Trailing compaction: trim empty slots from the END of the lane array
    # only.  Interior empty slots are kept in place so that active lanes to
    # their right don't shift left (which would cause visual position jumps
    # across rows).  New branches reuse interior empty slots before appending.
    while lanes.len > 0 and lanes[^1].waitingFor.len == 0:
      lanes.setLen(lanes.len - 1)

proc loadCommits(self: VCSComponent; cwd: cstring; skip = 0) =
  ## Fetch ``commitPageSize`` commits starting at ``skip``, parsing parent
  ## hashes so the commit-graph algorithm can assign branch lanes.
  ##
  ## Format: ``<fullHash> <parent1> [<parent2> …>]\x1e<shortHash>\x1e<subject>\x1e<relDate>\x1e<absDate>\x1e<author>``
  ## The ``%P`` token is a space-separated list of full parent hashes;
  ## it is empty for root commits.  ``%cs`` produces the committer date in
  ## short YYYY-MM-DD format (requires git ≥ 2.29).
  const sep = "\x1e"
  let prettyFmt = "%H %P" & sep & "%h" & sep & "%s" & sep & "%cr" & sep & "%cs" & sep & "%an"
  let skipStr = "--skip=" & $skip
  let countStr = "-" & $commitPageSize
  let raw = gitExec(
    @[cstring"log",
      cstring("--pretty=format:" & prettyFmt),
      cstring(skipStr),
      cstring(countStr)],
    cwd)

  if skip == 0:
    self.commits = @[]

  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      let parts = trimmed.split(sep)
      if parts.len < 1:
        continue
      # First field: "<fullHash> [<parent1> <parent2> …]"
      let hashAndParents = parts[0].strip().split(" ")
      let fullH = if hashAndParents.len > 0: hashAndParents[0] else: ""
      var parents: seq[cstring] = @[]
      for pIdx in 1 ..< hashAndParents.len:
        let p = hashAndParents[pIdx].strip()
        if p.len > 0:
          parents.add(cstring(p))
      let shortH    = if parts.len > 1: parts[1].strip() else: fullH[0..min(6, fullH.high)]
      let subject   = if parts.len > 2: parts[2] else: ""
      let relDate   = if parts.len > 3: parts[3] else: ""
      let absDate   = if parts.len > 4: parts[4] else: ""
      let authorStr = if parts.len > 5: parts[5] else: ""
      self.commits.add(VCSCommit(
        hash: cstring(shortH),
        message: cstring(subject),
        relativeTime: cstring(relDate),
        date: cstring(absDate),
        fullHash: cstring(fullH),
        author: cstring(authorStr),
        parents: parents,
      ))

  self.commitOffset = skip + commitPageSize

proc loadChangedFiles(self: VCSComponent, cwd: cstring, commitHash: cstring) =
  ## Load the files changed in a specific commit with diff --stat style info.
  ## Uses `git diff-tree` which works for any commit without needing a parent
  ## check (root commits are handled with --root).
  let raw = gitExec(
    @[cstring"diff-tree", cstring"--no-commit-id", cstring"-r", cstring"--numstat", commitHash], cwd)
  self.changedFiles = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      # Format: <added>\t<deleted>\t<filename>
      let parts = trimmed.split("\t")
      if parts.len >= 3:
        var added = 0
        var deleted = 0
        try:
          added = parseInt(parts[0].strip())
        except ValueError:
          discard
        try:
          deleted = parseInt(parts[1].strip())
        except ValueError:
          discard
        # Determine status from the change pattern.
        let status = if added > 0 and deleted == 0: cstring"A"
                     elif added == 0 and deleted > 0: cstring"D"
                     else: cstring"M"
        self.changedFiles.add(VCSChangedFile(
          status: status,
          filename: cstring(parts[2]),
          additions: added,
          deletions: deleted))

  # If no numstat output, fall back to --name-status.
  if self.changedFiles.len == 0:
    let raw2 = gitExec(
      @[cstring"diff-tree", cstring"--no-commit-id", cstring"-r", cstring"--name-status", commitHash], cwd)
    if raw2.len > 0:
      for line in ($raw2).splitLines():
        let trimmed = line.strip()
        if trimmed.len == 0:
          continue
        let parts = trimmed.split("\t")
        if parts.len >= 2:
          self.changedFiles.add(VCSChangedFile(
            status: cstring(parts[0]),
            filename: cstring(parts[1]),
            additions: 0,
            deletions: 0))

proc loadChangedFilesForIndex*(self: VCSComponent; cwd: cstring;
                               commitIndex: int) =
  ## Load changed files for the commit at ``commitIndex`` and store the result
  ## in ``commitFilesCache``.  A no-op if the index is out of range.
  if commitIndex < 0 or commitIndex >= self.commits.len:
    return
  if self.commitFilesCache.isNil:
    self.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
  let hash = self.commits[commitIndex].hash
  self.loadChangedFiles(cwd, hash)
  self.commitFilesCache[commitIndex] = self.changedFiles

proc getWorkingDirectory(self: VCSComponent): cstring =
  ## Determine the working directory for git commands.
  ## Prefers `startOptions.folder`, falling back to `process.cwd()`.
  let folder = self.data.startOptions.folder
  if not folder.isNil and folder.len > 0:
    return folder
  return electronProcess.cwd()

proc refreshVCSData*(self: VCSComponent) =
  ## Reload all VCS data from git.
  let cwd = self.getWorkingDirectory()
  if not isGitRepository(cwd):
    self.isGitRepo = false
    self.errorMessage = cstring"Not a git repository"
    return

  self.isGitRepo = true
  self.errorMessage = cstring""
  self.loadCurrentBranch(cwd)
  self.loadBranches(cwd)
  self.loadCommits(cwd)

  # Reload files for all currently expanded commits after a refresh.
  # Indices that are now out-of-range are silently skipped.
  self.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
  for idx in self.selectedCommitIndices:
    self.loadChangedFilesForIndex(cwd, idx)

proc commitRows(self: VCSComponent): seq[VCSCommitRow]

proc loadMoreCommits*(self: VCSComponent) =
  ## Append the next page of commits to ``self.commits`` and push the
  ## updated list to the VM.  Guards against concurrent fetches with
  ## ``self.loadingMore``.
  if self.loadingMore:
    return
  if not self.isGitRepo:
    return
  self.loadingMore = true
  let vm = if vcsVMInstances.hasKey(self.id): vcsVMInstances[self.id] else: nil
  if not vm.isNil:
    vm.setLoadingMore(true)
  let cwd = self.getWorkingDirectory()
  self.loadCommits(cwd, skip = self.commitOffset)
  self.loadingMore = false
  if not vm.isNil:
    vm.setLoadingMore(false)
    vm.setCommits(self.commitRows(), self.selectedCommitIndices,
                  self.lastClickedCommitIndex)

proc resetAndRefreshVCS*(self: VCSComponent) =
  ## Force the panel to reload from the current workspace folder.
  if self.isNil:
    return
  self.initialized = false
  self.commitOffset = 0
  self.refreshVCSData()
  self.syncLegacyVCSIntoVM()

# ---------------------------------------------------------------------------
# Git unified diff parsing (Task #69)
# ---------------------------------------------------------------------------

proc parseGitDiffHunks(diffOutput: string): seq[DeepReviewFileData] =
  ## Parse the output of ``git diff HEAD`` into a sequence of
  ## ``DeepReviewFileData`` structures, each containing diff hunks in the
  ## same format used by the DeepReview unified diff renderer.
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

proc loadGitDiffForUnifiedView(self: VCSComponent) =
  ## Run the appropriate git diff command based on ``self.diffTarget`` and parse
  ## the output into ``self.gitDiffData`` so the unified diff renderer can display it.
  let cwd = self.getWorkingDirectory()
  var args: seq[cstring] = @[]
  var sessionTitle = cstring"Working Tree Changes"

  let target = if not self.diffTarget.isNil and ($self.diffTarget).startsWith("diff:"):
    ($self.diffTarget)[5 .. ^1]
  else:
    ""

  if target.len == 0 or target == "Working Tree":
    args = @[cstring"diff", cstring"HEAD"]
    sessionTitle = cstring"Working Tree Changes"
  elif target.startsWith("file:"):
    let filepath = target[5 .. ^1]
    args = @[cstring"diff", cstring"HEAD", cstring"--", cstring(filepath)]
    sessionTitle = cstring("Diff: " & filepath)
  elif target.startsWith("commit:"):
    let commitPart = target[7 .. ^1]
    let colonIdx = commitPart.find(':')
    if colonIdx >= 0:
      let hash = commitPart[0 ..< colonIdx]
      let filepath = commitPart[colonIdx + 1 .. ^1]
      args = @[cstring"diff-tree", cstring"-p", cstring"--no-commit-id", cstring"--root", cstring(hash), cstring"--", cstring(filepath)]
      sessionTitle = cstring("Diff: " & filepath & " (" & hash[0 ..< min(12, hash.len)] & ")")
    else:
      args = @[cstring"diff-tree", cstring"-p", cstring"--no-commit-id", cstring"--root", cstring(commitPart)]
      sessionTitle = cstring("Commit Diff: " & commitPart[0 ..< min(12, commitPart.len)])
  else:
    args = @[cstring"diff", cstring"HEAD", cstring"--", cstring(target)]
    sessionTitle = cstring("Diff: " & target)

  let raw = gitExec(args, cwd)
  let files = parseGitDiffHunks($raw)

  self.gitDiffData = DeepReviewData(
    commitSha: cstring"HEAD",
    baseCommitSha: cstring"",
    collectionTimeMs: 0,
    recordingCount: 0,
    sessionTitle: sessionTitle,
    files: files)

  # Clear hunk selection when diff data is refreshed to avoid stale
  # references to old hunk indices.
  self.selectedHunks = @[]
  self.hunkToolbarVisible = false

# ---------------------------------------------------------------------------
# File watching — auto-refresh & debounce (Task #68)
# ---------------------------------------------------------------------------

proc scheduleRefresh(self: VCSComponent)

proc debouncedRefreshGitData(self: VCSComponent) =
  ## Perform a git refresh if the debounce window is not active. After the
  ## refresh, start a 1-second debounce window during which further refresh
  ## requests are ignored.
  if self.debounceActive:
    return

  let cwd = self.getWorkingDirectory()
  # Build a lightweight snapshot of volatile git state to detect changes.
  let statusRaw = gitExec(@[cstring"status", cstring"--porcelain"], cwd)
  let logRaw = gitExec(
    @[cstring"log", cstring"--pretty=format:%H", cstring"-30"], cwd)
  let snapshot = cstring($statusRaw & "\n---\n" & $logRaw)

  if snapshot != self.lastStatusSnapshot:
    self.lastStatusSnapshot = snapshot
    self.refreshVCSData()
    # Also refresh the unified diff data if the toggle is active.
    if self.unifiedDiffActive:
      self.loadGitDiffForUnifiedView()
    data.redraw()

  # Activate debounce window.
  self.debounceActive = true
  self.debounceTimerId = windowSetTimeout(
    proc() =
      self.debounceActive = false
      self.debounceTimerId = -1,
    debounceMs)

proc scheduleRefresh(self: VCSComponent) =
  ## Schedule the next periodic auto-refresh tick. Cancels any existing
  ## timer first to avoid duplicate timers.
  if self.refreshTimerId != -1:
    windowClearTimeout(self.refreshTimerId)
  self.refreshTimerId = windowSetTimeout(
    proc() =
      self.refreshTimerId = -1
      self.debouncedRefreshGitData()
      self.scheduleRefresh(),
    refreshIntervalMs)

proc startFileWatching(self: VCSComponent) =
  ## Begin periodic auto-refresh and subscribe to window focus events.
  ## Called once after the initial git data load.

  # Store initial snapshot so the first tick can detect changes.
  let cwd = self.getWorkingDirectory()
  let statusRaw = gitExec(@[cstring"status", cstring"--porcelain"], cwd)
  let logRaw = gitExec(@[cstring"log", cstring"--pretty=format:%H", cstring"-30"], cwd)
  self.lastStatusSnapshot = cstring($statusRaw & "\n---\n" & $logRaw)

  # Initialize timer IDs.
  self.refreshTimerId = -1
  self.debounceTimerId = -1
  self.debounceActive = false

  # Start the periodic refresh cycle.
  self.scheduleRefresh()

  # Subscribe to focus events so returning to the CodeTracer window
  # triggers an immediate refresh.
  let refreshOnFocus = proc() =
    self.debouncedRefreshGitData()
  {.emit: """
    window.addEventListener('focus', `refreshOnFocus`);
  """.}

proc ensureVCSVM(self: VCSComponent): VCSVM =
  if self.isNil:
    return nil
  if vcsVMInstances.hasKey(self.id):
    return vcsVMInstances[self.id]
  result = createVCSVM()
  vcsVMInstances[self.id] = result

proc isDeepReviewMode(self: VCSComponent): bool =
  ## Return true when the VCS panel should show DeepReview changeset data
  ## instead of normal git data.
  self.data.deepReviewActive and not self.data.deepReviewData.isNil

# ---------------------------------------------------------------------------
# Hunk editor helpers
# ---------------------------------------------------------------------------

proc isHunkSelected(self: VCSComponent, fileIdx, hunkIdx: int): bool =
  ## Return true if the given (fileIndex, hunkIndex) pair is in the
  ## selected hunks list.
  for pair in self.selectedHunks:
    if pair[0] == fileIdx and pair[1] == hunkIdx:
      return true
  return false

proc flatHunkOrdinal(drData: DeepReviewData, fileIdx, hunkIdx: int): int =
  ## Compute a flat ordinal for a (fileIdx, hunkIdx) pair by counting
  ## all hunks in files before ``fileIdx`` plus ``hunkIdx``. Used for
  ## Shift-click range selection.
  result = 0
  for fi in 0 ..< drData.files.len:
    if fi == fileIdx:
      result += hunkIdx
      return
    let file = drData.files[fi]
    if not file.diff.isNil:
      result += file.diff.hunks.len

proc hunkPairFromOrdinal(drData: DeepReviewData, ordinal: int): (int, int) =
  ## Reverse of ``flatHunkOrdinal``: convert a flat ordinal back to
  ## a (fileIndex, hunkIndex) pair.
  var remaining = ordinal
  for fi in 0 ..< drData.files.len:
    let file = drData.files[fi]
    let hunkCount = if file.diff.isNil: 0 else: file.diff.hunks.len
    if remaining < hunkCount:
      return (fi, remaining)
    remaining -= hunkCount
  # Fallback (should not happen with valid input).
  return (0, 0)

proc toggleHunkSelection(self: VCSComponent, fileIdx, hunkIdx: int) =
  ## Toggle a single hunk in/out of the selection.
  var found = -1
  for i in 0 ..< self.selectedHunks.len:
    if self.selectedHunks[i][0] == fileIdx and self.selectedHunks[i][1] == hunkIdx:
      found = i
      break
  if found >= 0:
    self.selectedHunks.delete(found)
  else:
    self.selectedHunks.add((fileIdx, hunkIdx))
  self.hunkToolbarVisible = self.selectedHunks.len > 0

proc selectHunkRange(self: VCSComponent, fromOrdinal, toOrdinal: int) =
  ## Select all hunks between two flat ordinals (inclusive), adding
  ## any that are not already selected.
  let lo = min(fromOrdinal, toOrdinal)
  let hi = max(fromOrdinal, toOrdinal)
  let drData = self.gitDiffData
  if drData.isNil:
    return
  for ord in lo .. hi:
    let pair = hunkPairFromOrdinal(drData, ord)
    if not self.isHunkSelected(pair[0], pair[1]):
      self.selectedHunks.add(pair)
  self.hunkToolbarVisible = self.selectedHunks.len > 0

proc clearHunkSelection(self: VCSComponent) =
  ## Clear all selected hunks.
  self.selectedHunks = @[]
  self.hunkToolbarVisible = false

proc buildPatchFromSelectedHunks(self: VCSComponent): string =
  ## Build a unified diff patch string from the currently selected hunks.
  ## Groups hunks by file and emits proper ``diff --git`` / ``---`` /
  ## ``+++`` headers so the output is a valid patch.
  let drData = self.gitDiffData
  if drData.isNil or self.selectedHunks.len == 0:
    return ""

  # Group selected hunks by file index, preserving order.
  var fileHunks: seq[(int, seq[int])] = @[]
  var fileMap: seq[int] = @[]  # fileIdx values in order of first appearance
  for pair in self.selectedHunks:
    let fi = pair[0]
    let hi = pair[1]
    var found = false
    for j in 0 ..< fileMap.len:
      if fileMap[j] == fi:
        fileHunks[j][1].add(hi)
        found = true
        break
    if not found:
      fileMap.add(fi)
      fileHunks.add((fi, @[hi]))

  var parts: seq[string] = @[]
  for entry in fileHunks:
    let fi = entry[0]
    let hunkIndices = entry[1]
    if fi >= drData.files.len:
      continue
    let file = drData.files[fi]
    let path = $file.path

    parts.add("diff --git a/" & path & " b/" & path)
    parts.add("--- a/" & path)
    parts.add("+++ b/" & path)

    for hi in hunkIndices:
      if file.diff.isNil or hi >= file.diff.hunks.len:
        continue
      let hunk = file.diff.hunks[hi]
      parts.add(fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@")
      for line in hunk.lines:
        let lineType = $line.`type`
        let prefix = case lineType
          of "added": "+"
          of "removed": "-"
          else: " "
        parts.add(prefix & $line.content)

  result = parts.join("\n") & "\n"

proc copySelectedHunksAsPatch(self: VCSComponent) =
  ## Copy the selected hunks to the clipboard as a unified diff patch.
  let patch = self.buildPatchFromSelectedHunks()
  if patch.len > 0:
    clipboardCopy(cstring(patch))
    self.hunkCopyFeedback = true
    discard windowSetTimeout(
      proc() =
        self.hunkCopyFeedback = false
        data.redraw(),
      2000)

proc stageSelectedHunks(self: VCSComponent) =
  ## Stage selected hunks by writing them to a temp file and applying
  ## with ``git apply --cached``.
  let patch = self.buildPatchFromSelectedHunks()
  if patch.len == 0:
    return
  let cwd = self.getWorkingDirectory()
  applyPatchToIndex(cstring(patch), cwd)
  # Refresh data after staging.
  self.refreshVCSData()
  self.loadGitDiffForUnifiedView()
  self.clearHunkSelection()

proc basename(path: cstring): string =
  let pathStr = $path
  let slashIdx = pathStr.rfind('/')
  if slashIdx >= 0:
    pathStr[slashIdx + 1 .. ^1]
  else:
    pathStr

proc safeStr(s: cstring): string =
  if s.isNil: "" else: $s

proc ensureVCSDataLoaded(self: VCSComponent) =
  if not self.initialized:
    self.initialized = true
    if not self.diffTarget.isNil and ($self.diffTarget).startsWith("diff:"):
      self.unifiedDiffActive = true
      self.loadGitDiffForUnifiedView()
    else:
      self.refreshVCSData()
      if self.isGitRepo:
        self.startFileWatching()

proc currentReviewTitle(self: VCSComponent): string =
  let drData = self.data.deepReviewData
  if drData.isNil:
    return ""
  if not drData.sessionTitle.isNil and ($drData.sessionTitle).len > 0:
    return $drData.sessionTitle
  let commitDisplay =
    if drData.commitSha.len > 12:
      ($drData.commitSha)[0 ..< 12] & "..."
    else:
      safeStr(drData.commitSha)
  "Review: " & commitDisplay

proc deepReviewRows(self: VCSComponent): seq[VCSFileRow] =
  result = @[]
  let drData = self.data.deepReviewData
  if drData.isNil:
    return
  for i, file in drData.files:
    var coverageExecuted = 0
    for cov in file.coverage:
      if cov.executed:
        coverageExecuted += 1
    let coverageText =
      if file.coverage.len > 0:
        $coverageExecuted & "/" & $file.coverage.len
      else:
        ""
    let status =
      if not file.diff.isNil and ($file.diff.status).len > 0:
        safeStr(file.diff.status)
      else:
        "M"
    result.add(VCSFileRow(
      status: status,
      path: safeStr(file.path),
      baseName: basename(file.path),
      additions: if file.diff.isNil: 0 else: file.diff.linesAdded,
      deletions: if file.diff.isNil: 0 else: file.diff.linesRemoved,
      coverageText: coverageText,
      selected: i == self.data.deepReviewSelectedFileIndex,
    ))

proc gitChangedRows(self: VCSComponent): seq[VCSFileRow] =
  result = @[]
  for file in self.changedFiles:
    result.add(VCSFileRow(
      status: safeStr(file.status),
      path: safeStr(file.filename),
      baseName: basename(file.filename),
      additions: file.additions,
      deletions: file.deletions,
      coverageText: "",
      selected: false,
    ))

proc commitRows(self: VCSComponent): seq[VCSCommitRow] =
  ## Convert the stored ``VCSCommit`` list to ``VCSCommitRow`` values suitable
  ## for the VM, including the pre-computed graph-lane cells, dot position,
  ## and merge connectors.
  let graphRows = computeGraphRows(self.commits)
  result = @[]
  for i, commit in self.commits:
    let gr = if i < graphRows.len: graphRows[i]
             else: GraphRow(dotLane: -1)
    result.add(VCSCommitRow(
      hash: safeStr(commit.hash),
      message: safeStr(commit.message),
      relativeTime: safeStr(commit.relativeTime),
      date: safeStr(commit.date),
      author: safeStr(commit.author),
      fullHash: safeStr(commit.fullHash),
      graphCells: gr.cells,
      dotLane: gr.dotLane,
      connectors: gr.connectors,
    ))

proc diffRows(self: VCSComponent): seq[VCSDiffFileRow] =
  result = @[]
  let drData = self.gitDiffData
  if drData.isNil:
    return
  for fileIdx, file in drData.files:
    if file.diff.isNil or file.diff.hunks.len == 0:
      continue
    var hunks: seq[VCSHunkRow] = @[]
    for hunkIdx, hunk in file.diff.hunks:
      var lines: seq[VCSDiffLineRow] = @[]
      for line in hunk.lines:
        lines.add(VCSDiffLineRow(
          lineType: safeStr(line.`type`),
          content: safeStr(line.content),
          oldLine: line.oldLine,
          newLine: line.newLine,
        ))
      hunks.add(VCSHunkRow(
        oldStart: hunk.oldStart,
        oldCount: hunk.oldCount,
        newStart: hunk.newStart,
        newCount: hunk.newCount,
        selected: self.isHunkSelected(fileIdx, hunkIdx),
        lines: lines,
      ))
    result.add(VCSDiffFileRow(
      fileIndex: fileIdx,
      status: safeStr(file.diff.status),
      path: safeStr(file.path),
      additions: file.diff.linesAdded,
      deletions: file.diff.linesRemoved,
      hunks: hunks,
    ))

proc syncDeepReviewPanelSelection(self: VCSComponent) =
  let component = self.data.ui.componentMapping[Content.DeepReview][0]
  if not component.isNil:
    deepreview.syncLegacyDeepReviewIntoVM(DeepReviewComponent(component))

proc syncLegacyVCSIntoVM*(self: VCSComponent) =
  if self.isNil:
    return
  vcsComponentRefs[self.id] = self
  let vm = ensureVCSVM(self)
  if vm.isNil:
    return
  if self.isDeepReviewMode():
    vm.setDeepReviewMode(true)
    vm.setHeader(self.currentReviewTitle())
    vm.setGitRepoState(true)
    vm.setBranchState("", @[], false)
    vm.setCommits(@[], @[])
    vm.setChangedFiles(self.deepReviewRows())
    vm.setUnifiedDiff(false, @[])
    vm.setHunkState(@[], false, false)
    return

  self.ensureVCSDataLoaded()
  vm.setDeepReviewMode(false)
  vm.setHeader(safeStr(self.currentBranch))
  vm.setGitRepoState(self.isGitRepo, safeStr(self.errorMessage))
  vm.setBranchState(safeStr(self.currentBranch),
                    self.branches.mapIt(safeStr(it)),
                    self.branchDropdownOpen)
  vm.setCommits(self.commitRows(), self.selectedCommitIndices,
                self.lastClickedCommitIndex)
  # Push per-commit file lists from the cache so each expanded accordion shows
  # its own file list independently of the others.
  var fileEntries: seq[(int, seq[VCSFileRow])] = @[]
  for idx in self.selectedCommitIndices:
    if not self.commitFilesCache.isNil and self.commitFilesCache.hasKey(idx):
      var rows: seq[VCSFileRow] = @[]
      for file in self.commitFilesCache[idx]:
        rows.add(VCSFileRow(
          status: safeStr(file.status),
          path: safeStr(file.filename),
          baseName: basename(file.filename),
          additions: file.additions,
          deletions: file.deletions,
          coverageText: "",
          selected: false,
        ))
      fileEntries.add((idx, rows))
  vm.syncCommitFilesMap(fileEntries)
  vm.setChangedFiles(self.gitChangedRows())
  vm.setUnifiedDiff(self.unifiedDiffActive, self.diffRows())
  vm.setHunkState(self.selectedHunks, self.hunkToolbarVisible,
                  self.hunkCopyFeedback)

proc handleVCSFileSelection(self: VCSComponent; index: int; path: string) =
  if self.isDeepReviewMode():
    self.data.deepReviewSelectedFileIndex = index
    self.syncLegacyVCSIntoVM()
    self.syncDeepReviewPanelSelection()
    return
  if self.unifiedDiffActive:
    self.loadGitDiffForUnifiedView()
  self.data.openTab(cstring(path), ViewSource)

proc handleHunkSelection(self: VCSComponent; fileIdx, hunkIdx: int;
                         shiftKey, ctrlKey: bool) =
  let drData = self.gitDiffData
  if shiftKey and self.lastHunkClickIndex >= 0 and not drData.isNil:
    let currentOrd = flatHunkOrdinal(drData, fileIdx, hunkIdx)
    self.selectHunkRange(self.lastHunkClickIndex, currentOrd)
  elif ctrlKey:
    self.toggleHunkSelection(fileIdx, hunkIdx)
  else:
    if self.selectedHunks.len == 1 and self.isHunkSelected(fileIdx, hunkIdx):
      self.clearHunkSelection()
    else:
      self.clearHunkSelection()
      self.selectedHunks.add((fileIdx, hunkIdx))
      self.hunkToolbarVisible = true
  if not drData.isNil:
    self.lastHunkClickIndex = flatHunkOrdinal(drData, fileIdx, hunkIdx)
  self.syncLegacyVCSIntoVM()

proc tryMountIsoNimVCSPanel*(componentId: int) =
  when defined(js):
    if isoNimVCSMountedIds.hasKey(componentId) and
       isoNimVCSMountedIds[componentId]:
      return
    if not vcsComponentRefs.hasKey(componentId):
      return
    let component = vcsComponentRefs[componentId]
    let vm = ensureVCSVM(component)
    if vm.isNil:
      return
    var container = document.getElementById(
      cstring(fmt"vcsComponent-{componentId}"))
    if container.isNil:
      container = document.getElementById(cstring(fmt"vCSComponent-{componentId}"))
    if container.isNil:
      return
    component.syncLegacyVCSIntoVM()
    let callbacks = VCSCallbacks(
      onToggleBranchDropdown: proc() =
        component.branchDropdownOpen = not component.branchDropdownOpen
        component.syncLegacyVCSIntoVM(),
      onCheckoutBranch: proc(branch: string) =
        component.branchDropdownOpen = false
        component.commitOffset = 0
        component.selectedCommitIndices = @[]
        component.lastClickedCommitIndex = -1
        component.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
        discard gitExec(@[cstring"checkout", cstring(branch)],
                        component.getWorkingDirectory())
        component.refreshVCSData()
        component.syncLegacyVCSIntoVM(),
      onSelectCommit: proc(index: int) =
        component.selectedCommitIndices = @[index]
        component.lastClickedCommitIndex = index
        component.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
        component.loadChangedFilesForIndex(component.getWorkingDirectory(), index)
        component.syncLegacyVCSIntoVM(),
      onSelectFile: proc(index: int; path: string) =
        component.handleVCSFileSelection(index, path),
      onToggleUnifiedDiff: proc() =
        discard,
      onRefresh: proc() =
        if not component.diffTarget.isNil and ($component.diffTarget).startsWith("diff:"):
          component.loadGitDiffForUnifiedView()
        else:
          component.refreshVCSData()
          if component.unifiedDiffActive:
            component.loadGitDiffForUnifiedView()
        component.syncLegacyVCSIntoVM(),
      onOpenFileDiff: proc(target: string) =
        let newId = component.data.generateId(Content.VCS)
        let tabPath = "diff:" & target
        component.data.openLayoutTab(Content.VCS, newId, isEditor = true, path = cstring(tabPath)),
      onSelectHunk: proc(fileIdx, hunkIdx: int; shiftKey, ctrlKey: bool) =
        component.handleHunkSelection(fileIdx, hunkIdx, shiftKey, ctrlKey),
      onCopySelectedHunks: proc() =
        component.copySelectedHunksAsPatch()
        component.syncLegacyVCSIntoVM(),
      onStageSelectedHunks: proc() =
        component.stageSelectedHunks()
        component.syncLegacyVCSIntoVM(),
      onClearSelectedHunks: proc() =
        component.clearHunkSelection()
        component.syncLegacyVCSIntoVM(),
      onToggleCommitExpand: proc(index: int; ctrl: bool; shift: bool) =
        ## Multi-select accordion toggle.
        ## • ctrl+click  — toggle this commit in/out of the expanded set.
        ## • shift+click — expand the range from lastClickedCommitIndex to index.
        ## • plain click — exclusive expand, or collapse if already sole selection.
        let cwd = component.getWorkingDirectory()
        if ctrl:
          # Toggle individual commit without affecting others.
          var newSel = component.selectedCommitIndices
          let pos = newSel.find(index)
          if pos >= 0:
            newSel.delete(pos)
            # Cache entry is left intact; it is simply no longer visible since
            # the index is absent from selectedCommitIndices.
          else:
            newSel.add(index)
            component.loadChangedFilesForIndex(cwd, index)
          component.selectedCommitIndices = newSel
          component.lastClickedCommitIndex = index
        elif shift and component.lastClickedCommitIndex >= 0:
          # Range-select from anchor to current index (inclusive).
          let lo = min(component.lastClickedCommitIndex, index)
          let hi = max(component.lastClickedCommitIndex, index)
          var newSel = component.selectedCommitIndices
          for i in lo..hi:
            if i notin newSel:
              newSel.add(i)
              component.loadChangedFilesForIndex(cwd, i)
          component.selectedCommitIndices = newSel
          # Do not update anchor on shift+click (matches standard list behaviour).
        else:
          # Plain click: exclusive select or collapse when already sole.
          if component.selectedCommitIndices == @[index]:
            component.selectedCommitIndices = @[]
            component.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
          else:
            component.selectedCommitIndices = @[index]
            component.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
            component.loadChangedFilesForIndex(cwd, index)
          component.lastClickedCommitIndex = index
        component.syncLegacyVCSIntoVM(),
      onLoadMoreCommits: proc() =
        component.loadMoreCommits()
        component.syncLegacyVCSIntoVM(),
    )
    mountIsoNimVCSPanel(cast[isonim_dom_api.Element](container), vm,
                        callbacks)
    isoNimVCSMountedIds[componentId] = true
  else:
    discard
