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

proc loadCommits(self: VCSComponent, cwd: cstring) =
  ## Load the 30 most recent commits with hash, subject and relative date.
  ## Uses ASCII record separator (0x1e) as delimiter to avoid conflicts with
  ## pipe characters that may appear in commit messages.
  const sep = "\x1e"
  let raw = gitExec(
    @[cstring("log"), cstring("--pretty=format:%h" & sep & "%s" & sep & "%cr"), cstring"-30"], cwd)
  self.commits = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      let parts = trimmed.split(sep)
      if parts.len >= 3:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring(parts[1]),
          relativeTime: cstring(parts[2])))
      elif parts.len == 2:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring(parts[1]),
          relativeTime: cstring""))
      elif parts.len == 1:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring"",
          relativeTime: cstring""))

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

  # If we have commits and a selection, load changed files.
  if self.commits.len > 0:
    if self.selectedCommitIndex < 0 or
       self.selectedCommitIndex >= self.commits.len:
      self.selectedCommitIndex = 0
    self.loadChangedFiles(cwd, self.commits[self.selectedCommitIndex].hash)

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
  ## Run ``git diff HEAD`` and parse the output into ``self.gitDiffData``
  ## so the DeepReview unified diff renderer can display it.
  let cwd = self.getWorkingDirectory()
  let raw = gitExec(@[cstring"diff", cstring"HEAD"], cwd)
  let files = parseGitDiffHunks($raw)

  self.gitDiffData = DeepReviewData(
    commitSha: cstring"HEAD",
    baseCommitSha: cstring"",
    collectionTimeMs: 0,
    recordingCount: 0,
    sessionTitle: cstring"Working Tree Changes",
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

# ---------------------------------------------------------------------------
# DeepReview mode helpers
# ---------------------------------------------------------------------------

proc isDeepReviewMode(self: VCSComponent): bool =
  ## Return true when the VCS panel should show DeepReview changeset data
  ## instead of normal git data.
  self.data.deepReviewActive and not self.data.deepReviewData.isNil

proc renderDeepReviewHeader(self: VCSComponent): VNode =
  ## Render a header bar showing the review title or commit SHA in place of
  ## the branch picker.
  let drData = self.data.deepReviewData
  let hasTitle = not drData.sessionTitle.isNil and ($drData.sessionTitle).len > 0
  let commitDisplay = if drData.commitSha.len > 12:
    cstring(($drData.commitSha)[0 ..< 12] & "...")
  else:
    drData.commitSha

  buildHtml(tdiv(class = "vcs-branch-picker")):
    tdiv(class = "vcs-branch-current"):
      span(class = "vcs-branch-icon"):
        text "\xEF\x84\xA6" # git branch icon
      span(class = "vcs-branch-name"):
        if hasTitle:
          text drData.sessionTitle
        else:
          text cstring("Review: " & $commitDisplay)

proc makeDeepReviewFileClickHandler(self: VCSComponent, idx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for a file in the DeepReview file list.
  ## Uses a separate proc to avoid Nim JS backend closure-in-loop capture bug.
  let selfCapture = self
  result = proc(ev: Event, n: VNode) =
    selfCapture.data.deepReviewSelectedFileIndex = idx
    # Use redrawAll so the DeepReview component in the center panel also
    # picks up the new file index and re-renders its diff view.
    redrawAll()

proc renderDeepReviewChangedFiles(self: VCSComponent): VNode =
  ## Render the changed files list populated from DeepReview data.
  ## Each entry shows the diff status badge, file basename, full path,
  ## and line addition/removal counts.  Clicking a file updates
  ## ``data.deepReviewSelectedFileIndex`` so the DeepReview component
  ## shows that file's diff.
  let drData = self.data.deepReviewData
  buildHtml(tdiv(class = "vcs-changed-files")):
    tdiv(class = "vcs-section-header"):
      text "Changed Files"
      span(class = "vcs-changed-files-commit"):
        text cstring(" (" & $drData.files.len & " files)")

    tdiv(class = "vcs-file-list"):
      if drData.files.len == 0:
        tdiv(class = "vcs-no-files"):
          text "No changed files"
      else:
        for i, file in drData.files:
          let isSelected = (i == self.data.deepReviewSelectedFileIndex)
          let selectedClass = if isSelected: " vcs-file-selected" else: ""

          # Determine status from diff data.
          let status = if not file.diff.isNil and ($file.diff.status).len > 0:
            file.diff.status
          else:
            cstring"M"
          let statusClass = case $status
            of "A": "vcs-status-added"
            of "D": "vcs-status-deleted"
            of "M": "vcs-status-modified"
            else: "vcs-status-other"

          tdiv(class = cstring("vcs-file-item" & selectedClass),
               onclick = self.makeDeepReviewFileClickHandler(i)):
            span(class = cstring("vcs-file-status " & statusClass)):
              text status
            span(class = "vcs-file-name"):
              # Show just the basename for compact display.
              let pathStr = $file.path
              let slashIdx = pathStr.rfind('/')
              let baseName = if slashIdx >= 0: pathStr[slashIdx + 1 .. ^1] else: pathStr
              text cstring(baseName)
            if not file.diff.isNil and (file.diff.linesAdded > 0 or file.diff.linesRemoved > 0):
              span(class = "vcs-file-stats"):
                if file.diff.linesAdded > 0:
                  span(class = "vcs-stat-added"):
                    text cstring("+" & $file.diff.linesAdded)
                if file.diff.linesRemoved > 0:
                  span(class = "vcs-stat-deleted"):
                    text cstring("-" & $file.diff.linesRemoved)
            # Coverage badge: show executed/total line count.
            if file.coverage.len > 0:
              var executed = 0
              for cov in file.coverage:
                if cov.executed:
                  executed += 1
              span(class = "vcs-file-coverage"):
                text cstring(fmt"{executed}/{file.coverage.len}")

# ---------------------------------------------------------------------------
# Normal git mode render helpers
# ---------------------------------------------------------------------------

proc renderBranchPicker(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-branch-picker")):
    tdiv(class = "vcs-branch-current",
         onclick = proc(ev: Event, tg: VNode) =
           self.branchDropdownOpen = not self.branchDropdownOpen
           data.redraw()):
      span(class = "vcs-branch-icon"):
        text "\xEF\x84\xA6" # git branch unicode icon fallback
      span(class = "vcs-branch-name"):
        text self.currentBranch
      span(class = "vcs-branch-arrow"):
        if self.branchDropdownOpen:
          text "\xE2\x96\xB2" # up triangle
        else:
          text "\xE2\x96\xBC" # down triangle

    if self.branchDropdownOpen:
      tdiv(class = "vcs-branch-dropdown"):
        for branch in self.branches:
          let branchCopy = branch
          tdiv(class = "vcs-branch-option",
               onclick = proc(ev: Event, tg: VNode) =
                 self.branchDropdownOpen = false
                 # Checkout branch via git.
                 let cwd = self.getWorkingDirectory()
                 discard gitExec(@[cstring"checkout", branchCopy], cwd)
                 self.refreshVCSData()
                 data.redraw()):
            let isActive = branch == self.currentBranch
            if isActive:
              span(class = "vcs-branch-active-marker"):
                text "* "
            text branch

proc renderCommitHistory(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-commit-history")):
    tdiv(class = "vcs-section-header"):
      text "Commits"
    tdiv(class = "vcs-commit-list"):
      for i, commit in self.commits:
        let index = i
        let isSelected = index == self.selectedCommitIndex
        let selectedClass = if isSelected: " vcs-commit-selected" else: ""
        tdiv(class = cstring("vcs-commit-item" & selectedClass),
             onclick = proc(ev: Event, tg: VNode) =
               self.selectedCommitIndex = index
               let cwd = self.getWorkingDirectory()
               self.loadChangedFiles(cwd, self.commits[index].hash)
               data.redraw()):
          span(class = "vcs-commit-hash"):
            text commit.hash
          span(class = "vcs-commit-message"):
            text commit.message
          span(class = "vcs-commit-time"):
            text commit.relativeTime

proc renderChangedFiles(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-changed-files")):
    tdiv(class = "vcs-section-header"):
      text "Changed Files"
      if self.selectedCommitIndex >= 0 and
         self.selectedCommitIndex < self.commits.len:
        span(class = "vcs-changed-files-commit"):
          text " (" & self.commits[self.selectedCommitIndex].hash & ")"

    tdiv(class = "vcs-file-list"):
      if self.changedFiles.len == 0:
        tdiv(class = "vcs-no-files"):
          text "No changed files"
      else:
        for file in self.changedFiles:
          let filePath = file.filename
          let statusClass = case $file.status
            of "A": "vcs-status-added"
            of "D": "vcs-status-deleted"
            of "M": "vcs-status-modified"
            else: "vcs-status-other"
          tdiv(class = "vcs-file-item",
               onclick = proc(ev: Event, tg: VNode) =
                 # When unified diff toggle is active, switch to
                 # diff view instead of opening the source file.
                 if self.unifiedDiffActive:
                   self.loadGitDiffForUnifiedView()
                   data.redraw()
                 else:
                   data.openTab(filePath, ViewSource)):
            span(class = cstring("vcs-file-status " & statusClass)):
              text file.status
            span(class = "vcs-file-name"):
              # Show just the basename for compact display.
              let pathStr = $filePath
              let slashIdx = pathStr.rfind('/')
              let baseName = if slashIdx >= 0: pathStr[slashIdx + 1 .. ^1] else: pathStr
              text cstring(baseName)
            if file.additions > 0 or file.deletions > 0:
              span(class = "vcs-file-stats"):
                if file.additions > 0:
                  span(class = "vcs-stat-added"):
                    text cstring("+" & $file.additions)
                if file.deletions > 0:
                  span(class = "vcs-stat-deleted"):
                    text cstring("-" & $file.deletions)

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
  # Write patch to a temporary file and apply it to the index.
  # Use Node.js fs and os modules (available in Electron renderer).
  {.emit: """
  var fs = require('fs');
  var os = require('os');
  var path = require('path');
  var tmpDir = os.tmpdir();
  var tmpFile = path.join(tmpDir, 'ct-hunk-stage-' + Date.now() + '.patch');
  fs.writeFileSync(tmpFile, `patch`);
  try {
    require('child_process').execSync('git apply --cached ' + tmpFile, {
      cwd: `cwd`,
      encoding: 'utf8',
      timeout: 5000
    });
  } catch(e) {
    console.error('Failed to stage hunks:', e.message);
  } finally {
    try { fs.unlinkSync(tmpFile); } catch(e2) {}
  }
  """.}
  # Refresh data after staging.
  self.refreshVCSData()
  self.loadGitDiffForUnifiedView()
  self.clearHunkSelection()

proc makeHunkHeaderClickHandler(self: VCSComponent, fileIdx, hunkIdx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for a hunk header that supports:
  ## - Plain click: toggle single hunk selection
  ## - Ctrl/Cmd-click: toggle without clearing others
  ## - Shift-click: range select from last clicked hunk
  let selfCapture = self
  let drData = self.gitDiffData
  result = proc(ev: Event, n: VNode) =
    let jsEv = cast[JsObject](ev)
    let shiftKey = jsEv.shiftKey.to(bool)
    let ctrlKey = jsEv.ctrlKey.to(bool) or jsEv.metaKey.to(bool)

    if shiftKey and selfCapture.lastHunkClickIndex >= 0 and not drData.isNil:
      # Range select from last click to current.
      let currentOrd = flatHunkOrdinal(drData, fileIdx, hunkIdx)
      selfCapture.selectHunkRange(selfCapture.lastHunkClickIndex, currentOrd)
    elif ctrlKey:
      # Toggle this hunk without clearing others.
      selfCapture.toggleHunkSelection(fileIdx, hunkIdx)
    else:
      # Plain click: if this hunk is the only selected one, deselect it;
      # otherwise clear all and select only this one.
      if selfCapture.selectedHunks.len == 1 and
         selfCapture.isHunkSelected(fileIdx, hunkIdx):
        selfCapture.clearHunkSelection()
      else:
        selfCapture.clearHunkSelection()
        selfCapture.selectedHunks.add((fileIdx, hunkIdx))
        selfCapture.hunkToolbarVisible = true

    # Track last click ordinal for Shift-click ranges.
    if not drData.isNil:
      selfCapture.lastHunkClickIndex = flatHunkOrdinal(drData, fileIdx, hunkIdx)

    ev.preventDefault()
    data.redraw()

proc renderHunkToolbar(self: VCSComponent): VNode =
  ## Render the floating action toolbar for selected hunks.
  if not self.hunkToolbarVisible or self.selectedHunks.len == 0:
    return buildHtml(tdiv())

  buildHtml(tdiv(class = "hunk-toolbar")):
    span(class = "hunk-toolbar-count"):
      text cstring($self.selectedHunks.len & " hunk" &
        (if self.selectedHunks.len > 1: "s" else: "") & " selected")

    tdiv(class = "hunk-toolbar-actions"):
      tdiv(class = "hunk-toolbar-button",
           onclick = proc(ev: Event, tg: VNode) =
             self.copySelectedHunksAsPatch()
             data.redraw()):
        if self.hunkCopyFeedback:
          text "Copied!"
        else:
          text "Copy as patch"

      tdiv(class = "hunk-toolbar-button",
           onclick = proc(ev: Event, tg: VNode) =
             self.stageSelectedHunks()
             data.redraw()):
        text "Stage hunks"

      tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
           onclick = proc(ev: Event, tg: VNode) =
             self.clearHunkSelection()
             data.redraw()):
        text "Clear"

# ---------------------------------------------------------------------------
# Git unified diff rendering (Task #69)
# ---------------------------------------------------------------------------

proc renderGitUnifiedDiff(self: VCSComponent): VNode =
  ## Render the parsed ``git diff HEAD`` output as a unified diff view.
  ## Reuses the DeepReview CSS classes so the styling is consistent.
  let drData = self.gitDiffData
  if drData.isNil or drData.files.len == 0:
    return buildHtml(tdiv(class = "deepreview-unified-diff")):
      tdiv(class = "deepreview-unified-empty"):
        text "No working tree changes."

  buildHtml(tdiv(class = "deepreview-unified-diff")):
    # Floating hunk action toolbar (shown when hunks are selected).
    renderHunkToolbar(self)

    for fileIdx, file in drData.files:
      if file.diff.isNil or file.diff.hunks.len == 0:
        continue

      tdiv(class = "deepreview-unified-file"):
        # File header with path, status badge, and line counts.
        tdiv(class = "deepreview-unified-file-header"):
          let statusStr = $file.diff.status
          let statusCss = case statusStr
            of "A": " deepreview-diff-status-added"
            of "D": " deepreview-diff-status-deleted"
            else: " deepreview-diff-status-modified"
          if statusStr.len > 0:
            span(class = cstring("deepreview-diff-status" & statusCss)):
              text file.diff.status
          span(class = "deepreview-unified-file-path"):
            text file.path
          if file.diff.linesAdded > 0 or file.diff.linesRemoved > 0:
            span(class = "deepreview-unified-file-stats"):
              span(class = "deepreview-unified-additions"):
                text cstring(fmt"+{file.diff.linesAdded}")
              span(class = "deepreview-unified-deletions"):
                text cstring(fmt"-{file.diff.linesRemoved}")

        # Render each hunk.
        for hunkIdx, hunk in file.diff.hunks:
          let isSelected = self.isHunkSelected(fileIdx, hunkIdx)
          let hunkClass = if isSelected:
            "deepreview-unified-hunk hunk-selected"
          else:
            "deepreview-unified-hunk"

          tdiv(class = cstring(hunkClass)):
            tdiv(class = "deepreview-unified-hunk-header hunk-header-selectable",
                 onclick = self.makeHunkHeaderClickHandler(fileIdx, hunkIdx)):
              if isSelected:
                span(class = "hunk-selection-indicator"):
                  text "\xE2\x9C\x93" # checkmark
              text cstring(fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@")

            for lineItem in hunk.lines:
              let lineType = $lineItem.`type`
              let lineCssClass = case lineType
                of "added": "deepreview-unified-line deepreview-line-added"
                of "removed": "deepreview-unified-line deepreview-line-removed"
                else: "deepreview-unified-line deepreview-line-context"

              tdiv(class = cstring(lineCssClass)):
                # Line number gutters.
                span(class = "deepreview-unified-line-old"):
                  if lineItem.oldLine > 0:
                    text cstring($lineItem.oldLine)
                span(class = "deepreview-unified-line-new"):
                  if lineItem.newLine > 0:
                    text cstring($lineItem.newLine)
                # Line prefix (+/-/space).
                span(class = "deepreview-unified-line-prefix"):
                  case lineType
                  of "added": text "+"
                  of "removed": text "-"
                  else: text " "
                span(class = "deepreview-unified-line-content"):
                  text lineItem.content

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
  result = @[]
  for commit in self.commits:
    result.add(VCSCommitRow(
      hash: safeStr(commit.hash),
      message: safeStr(commit.message),
      relativeTime: safeStr(commit.relativeTime),
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
    vm.setCommits(@[], -1)
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
  vm.setCommits(self.commitRows(), self.selectedCommitIndex)
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
    self.syncLegacyVCSIntoVM()
  else:
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
    let container = document.getElementById(
      cstring(fmt"vcsComponent-{componentId}"))
    if container.isNil:
      return
    component.syncLegacyVCSIntoVM()
    let callbacks = VCSCallbacks(
      onToggleBranchDropdown: proc() =
        component.branchDropdownOpen = not component.branchDropdownOpen
        component.syncLegacyVCSIntoVM(),
      onCheckoutBranch: proc(branch: string) =
        component.branchDropdownOpen = false
        discard gitExec(@[cstring"checkout", cstring(branch)],
                        component.getWorkingDirectory())
        component.refreshVCSData()
        component.syncLegacyVCSIntoVM(),
      onSelectCommit: proc(index: int) =
        component.selectedCommitIndex = index
        if index >= 0 and index < component.commits.len:
          component.loadChangedFiles(component.getWorkingDirectory(),
                                     component.commits[index].hash)
        component.syncLegacyVCSIntoVM(),
      onSelectFile: proc(index: int; path: string) =
        component.handleVCSFileSelection(index, path),
      onToggleUnifiedDiff: proc() =
        component.unifiedDiffActive = not component.unifiedDiffActive
        if component.unifiedDiffActive:
          component.loadGitDiffForUnifiedView()
        component.syncLegacyVCSIntoVM(),
      onRefresh: proc() =
        component.refreshVCSData()
        if component.unifiedDiffActive:
          component.loadGitDiffForUnifiedView()
        component.syncLegacyVCSIntoVM(),
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
    )
    mountIsoNimVCSPanel(cast[isonim_dom_api.Element](container), vm,
                        callbacks)
    isoNimVCSMountedIds[componentId] = true
  else:
    discard
