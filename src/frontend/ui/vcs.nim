## VCS (Version Control System) panel component.
##
## A lazygit-style integrated version control panel shown as a Golden Layout
## component. Displays: branch picker, commit history, and changed files for
## the selected commit.
##
## In DeepReview mode (``data.deepReviewActive``), the panel switches to
## showing the review's changed files from ``data.deepReviewData.files``
## instead of git data.  Clicking a file opens that file's review
## representation in the editor and records the choice in
## ``data.deepReviewSelectedFileIndex``, which the Agent Activity panel's
## per-file coverage table follows (DeepReview-GUI.md §2.1).
##
## Git data is fetched with structured `git` argv calls via Node.js
## `child_process` (available in Electron's renderer process with
## nodeIntegration enabled) — see ``ui/git_cli.nim``.
##
## The panel is never itself a diff.  Clicking a changed file resolves through
## ``VCSVM.openActionFor`` to either a source tab or a unified-diff editor tab
## (``ui/unified_diff.nim``), which is a Monaco document of its own —
## VCS-Panel.md, "Unified Diff View (Editor Integration)".

import
  ui_imports

import git_cli
import agent_activity
# A MOUNT LATCH THAT DIES WITH ITS CONTAINER.
import isonim_panel_mount
import ../viewmodel/viewmodels/vcs_vm
import ../viewmodel/viewmodels/review_entry
from ../viewmodel/viewmodels/review_session import
  ReviewSession, reviewSessionFrom

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

  # Rows appended by THIS call, so the caller can tell a full page from the
  # last, short one. `commitOffset` used to advance by a flat `commitPageSize`
  # whether or not any commit came back, which left the infinite-scroll
  # sentinel with no way to know it had reached the end — see
  # `allCommitsLoaded` in `VCSComponent`.
  var appended = 0

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
      appended += 1

  self.commitOffset = skip + appended
  self.allCommitsLoaded = appended < commitPageSize

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
  gitWorkingDirectory(self.data)

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
  ##
  ## The caller is an IntersectionObserver on a sentinel at the bottom of the
  ## commit list, which fires again every time the list is rebuilt.  It is
  ## therefore this proc's job — not the observer's — to be a no-op once the
  ## history is exhausted; see ``allCommitsLoaded``.
  if self.loadingMore:
    return
  if self.allCommitsLoaded:
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
  # Paired with `commitOffset`: a fresh paging window must be allowed to fetch
  # again, otherwise a repo that grew since the last load can never show its
  # new commits.
  self.allCommitsLoaded = false
  self.refreshVCSData()
  self.syncLegacyVCSIntoVM()

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

# The hunk editor's selection model and its patch builder used to live here,
# over the raw ``DeepReviewData`` of a DOM-rendered diff panel.  DR-R4 moved
# them into ``VCSVM`` (``viewmodel/viewmodels/vcs_vm.nim``) so that one model
# serves the Monaco diff tab and is testable without a browser; the docked
# panel is not a diff surface and holds no hunk state at all.

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

proc reviewDataset(self: VCSComponent): ReviewDataset =
  ## The review this panel is showing, as the ViewModel layer's dataset.
  ##
  ## The projection itself lives in ``viewmodel/viewmodels/review_entry`` —
  ## one generic routine instantiated here over the renderer's
  ## ``DeepReviewData`` and in the headless tests over the native copy of the
  ## same type — so the session title, the changed-file rows, the trace
  ## contexts, the per-file coverage and the traced-function count are derived
  ## by exactly the same code whichever launch path filled
  ## ``data.deepReviewData`` (DeepReview-GUI.md §7).
  reviewDatasetFrom(self.data.deepReviewData)

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

proc syncLegacyVCSIntoVM*(self: VCSComponent) =
  if self.isNil:
    return
  vcsComponentRefs[self.id] = self
  let vm = ensureVCSVM(self)
  if vm.isNil:
    return
  if self.isDeepReviewMode():
    # The view-mode toggle is live in review mode too (VCS-Panel.md, "View
    # mode toggle"), so the VM must carry the component's current position:
    # without this the toggle rendered but changed nothing, because the click
    # resolver reads `VCSVM.viewMode`.
    vm.setViewMode(if self.openFileMode: vmOpenFile else: vmUnifiedDiff)
    # One routine applies the dataset, whichever launch path produced it, and
    # it is the same routine `startReviewNavigation` enters the review with.
    # It also decides the selection: a re-sync keeps the file the reviewer is
    # looking at rather than resetting to the first one.
    let selectedIndex = applyReviewDataset(
      vm, self.reviewDataset(), self.data.deepReviewSelectedTraceContextId)
    # The legacy carriers follow the ViewModel rather than driving it.  Both
    # are review-wide (a review has one selected file and one selected trace
    # context however many VCS panels exist), which is why they live on
    # `Data`.
    if selectedIndex >= 0:
      self.data.deepReviewSelectedFileIndex = selectedIndex
    self.data.deepReviewSelectedTraceContextId = vm.currentTraceContextId()
    return

  self.ensureVCSDataLoaded()
  vm.setDeepReviewMode(false)
  vm.setViewMode(if self.openFileMode: vmOpenFile else: vmUnifiedDiff)
  # `setHeader` clears the review stats and the reviewed commit; the trace
  # contexts are cleared explicitly.  None of the three belongs to a live
  # working tree, and a panel can move out of review mode (VCS-Panel.md,
  # "Data Sources and Instantiation Modes").
  vm.setHeader(safeStr(self.currentBranch))
  vm.setTraceContexts(@[])
  vm.setSelectedTraceContextId(0)
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
  # The docked panel is never a diff (#561): a unified diff is its own editor
  # tab.  Both are cleared explicitly so a panel that once hosted one — the
  # agentic session launcher used to push its review diff in here — cannot
  # leave a stale diff behind.
  vm.setUnifiedDiff(false, @[])
  vm.setHunkState(@[], false, false)

proc openUnifiedDiffTab*(self: VCSComponent; target: string) =
  ## Open (or focus) a dedicated editor-area tab showing the unified diff for
  ## ``target`` — ``file:<path>``, ``commit:<hash>``, ``commit:<hash>:<path>``
  ## or ``Working Tree``.  The tab is keyed by the target, so clicking the same
  ## file twice focuses the tab that is already showing it (#611).
  ##
  ## The tab is a ``Content.UnifiedDiff`` document — a Monaco editor over the
  ## assembled diff (``ui/unified_diff.nim``) — not a second instance of this
  ## panel.  VCS-Panel.md, "Unified Diff View (Editor Integration)": "Uses the
  ## standard CodeTracer Monaco editor".
  let newId = self.data.generateId(Content.UnifiedDiff)
  self.data.openLayoutTab(Content.UnifiedDiff, newId, isEditor = true,
                          path = cstring("diff:" & target))

proc repositoryRoot(self: VCSComponent): cstring =
  ## Absolute path of the git work tree root.
  ##
  ## Every path git reports (``diff-tree --numstat``, ``status --porcelain``,
  ## …) is relative to this directory, while the editor addresses files by
  ## absolute path.  The working directory is only a fallback: it is not
  ## necessarily the repository root, so joining against it would break for
  ## projects opened at a subdirectory.
  let cwd = self.getWorkingDirectory()
  let top = gitExec(@[cstring"rev-parse", cstring"--show-toplevel"], cwd)
  if top.isNil or top.len == 0: cwd else: top

proc absoluteRepoPath(self: VCSComponent; path: string): cstring =
  if path.len == 0 or utils.isAbsolutePath(path):
    cstring(path)
  else:
    cstring($self.repositoryRoot() & "/" & path)

proc dispatchOpenAction(self: VCSComponent; action: VCSOpenAction) =
  ## Perform the side effect a resolved ``VCSOpenAction`` names.
  ##
  ## Both branches focus an already-open document rather than opening a second
  ## one: ``openLayoutTab`` matches a diff tab by ``independentTabPath`` and
  ## ``openTab`` matches a source tab by its editor tab path.
  case action.kind
  of voaNone:
    discard
  of voaDiffTab:
    self.openUnifiedDiffTab(action.target)
  of voaSourceFile:
    # VCS-005: open the file itself.  git hands us a repository-relative path
    # and the editor needs an absolute one, otherwise the tab load is issued
    # for a path that does not exist unless some already-open tab happens to
    # end with it.
    #
    # A REVIEW OPENED FROM A DATASET is the exception, and deliberately so.
    # Its files are addressed by their path in the *reviewed* repository, which
    # is the only name the dataset knows and the only one that means anything
    # on a machine that is not the one the dataset was collected on.  Resolving
    # it here would join it onto `git rev-parse --show-toplevel` of whatever
    # repository the terminal happened to be in — for a dataset from a ticket,
    # an unrelated tree — and produce a path that exists nowhere.  The index
    # serves such a tab from the dataset's own `sourceContent`
    # (`index/config.reviewSourceLookup`), so no absolute path is needed and
    # fabricating one would only mislabel the tab.
    #
    # The test is `isReviewDatasetSession`, not "is a review active".  A review
    # started over a *live trace diff* (DeepReview-GUI.md §1, launch method 2:
    # a trace recorded with `--with-diff`) has the real working tree in front
    # of it and its index process was never handed a dataset, so its tabs are
    # still read from disk and still need the absolute path — the repository is
    # right there, and `ct` may well have been run from a subdirectory of it.
    # Those tabs are matched to their dataset entry by the component-suffix
    # rule in `common/review_source_paths`, which exists for exactly this case.
    if self.data.isReviewDatasetSession():
      self.data.openTab(cstring(action.path), ViewSource)
    else:
      self.data.openTab(self.absoluteRepoPath(action.path), ViewSource)

proc handleVCSFileSelection(self: VCSComponent; index: int;
                            path, target, status: string) =
  ## Dispatcher over ``VCSVM.openActionFor`` — the decision itself lives in
  ## the ViewModel so it is testable without a browser
  ## (``src/tests/gui/tests/vcs/vcs_vm_test.nim``).
  ##
  ## DeepReview-GUI.md §3: "Clicking a file **opens it in the editor** ...
  ## Clicking must not merely change a selection index — clicking is the
  ## navigation gesture, and it works identically in normal VCS mode and in
  ## DeepReview mode."  Review mode used to return here after updating the
  ## selection index, so a reviewer could click every changed file and never
  ## open one.
  let vm = self.ensureVCSVM()
  if vm.isNil:
    return
  if self.isDeepReviewMode():
    # The VM is the selection's home — a re-sync carries it across by path —
    # so the click is recorded there first and the legacy index follows.
    discard selectReviewRow(vm, index)
    self.data.deepReviewSelectedFileIndex = index
    self.syncLegacyVCSIntoVM()
  else:
    vm.setViewMode(if self.openFileMode: vmOpenFile else: vmUnifiedDiff)
  self.dispatchOpenAction(vm.openActionFor(index, path, target, status))

proc handleTraceContextSelection(self: VCSComponent; id: int) =
  ## The reviewer picked a trace context in this panel's header
  ## (DeepReview-GUI.md §6: "The selected trace context can be changed without
  ## leaving the review").
  ##
  ## The selection is review-wide, so it is stored on ``Data`` alongside the
  ## dataset it indexes rather than inside one panel.
  ##
  ## NOTE (M42b): the review's recordings are not loaded — `--deepreview`
  ## forces an empty recording id — so switching context cannot yet change
  ## the *data* any panel shows.  What this milestone delivers is the control
  ## and its state; re-driving the overlay from the newly selected recording
  ## is DR-R6, which is blocked on that gap.
  if not self.isDeepReviewMode():
    return
  let vm = self.ensureVCSVM()
  if not vm.isNil:
    vm.setSelectedTraceContextId(id)
  self.data.deepReviewSelectedTraceContextId = id
  self.syncLegacyVCSIntoVM()

proc focusDockedPanel(data: Data; content: Content) =
  ## Make ``content``'s panel the visible tab of whichever stack hosts it.
  ##
  ## Layout-System.md, "DeepReview and the Layout", obligation 2 — "Focus, not
  ## relocation": "the three review panels stay wherever the user put them,
  ## but the stack hosting each is retargeted at it ... No panel is moved
  ## between stacks and no stack is created for one."  A layout with no such
  ## panel is left alone rather than having one grafted in.
  ##
  ## The startup path performs the same retarget on the layout *config* before
  ## GoldenLayout is built (``deepreview_layout.focusReviewFileList`` /
  ## ``focusReviewActivityPane``); this is the same rule for the launch paths
  ## whose layout is already live.
  if data.isNil or data.ui.layout.isNil:
    return
  for _, component in data.ui.componentMapping[content]:
    if component.isNil or component.layoutItem.isNil or
        component.layoutItem.parent.isNil:
      continue
    component.layoutItem.parent.setActiveContentItem(component.layoutItem)
    return

proc startReviewNavigation*(self: VCSComponent) =
  ## Enter a review on this panel — the host half of the one review-entry
  ## routine (``review_entry.enterReview``).
  ##
  ## DeepReview-GUI.md §7, "Transition into a Review", is performed in full by
  ## a single call: the VCS panel populates with the changeset (step 1), the
  ## Agent Activity panel's DeepReview section populates (step 4 — §2.1: "It
  ## must not require a live agent session"), the three panels are focused,
  ## and the first modified file opens in the editor (step 2).  There is no
  ## path that can reach a review with one of those left undone, because there
  ## is only one path.
  ##
  ## This proc supplies what the ViewModel layer cannot: the review dataset
  ## behind ``data.deepReviewData`` and the GoldenLayout side effects.  All
  ## three launch paths (``ct review``, a trace with an associated diff,
  ## the agentic handoff) arrive here through ``startDeepReviewNavigation``.
  if self.isNil or not self.isDeepReviewMode():
    return
  let vm = self.ensureVCSVM()
  if vm.isNil:
    return
  let dataset = self.reviewDataset()
  # RV-6 — the agent session the dataset named, already resolved by `ct`
  # (`src/ct/review_session.nim`) and forwarded through `StartOptions`.
  #
  # Nil is the ordinary case and projects to the "absent" state, which
  # `enterReview` treats as "this review has no session" and leaves the
  # conversation alone.  A reference that would *not* resolve is not nil: it
  # arrives with an explicit state and the backend's message, so the panel
  # can say why (DeepReview-GUI.md §2.1).
  let session = reviewSessionFrom(self.data.startOptions.reviewSession)
  # Latched before entry so an Agent Activity panel that finishes mounting
  # after this call — the mount retries asynchronously — lands in the same
  # state, and so the legacy conversation sync cannot wipe it.
  rememberReviewSessionForAgentActivity(session)
  discard enterReview(
    vm,
    dataset,
    proc(action: VCSOpenAction) = self.dispatchOpenAction(action),
    proc() =
      focusDockedPanel(self.data, Content.VCS)
      focusDockedPanel(self.data, Content.AgentActivity),
    self.data.deepReviewSelectedTraceContextId,
    conversation = agentActivityConversationVM(),
    session = session)
  # The legacy carriers follow the ViewModel (see `syncLegacyVCSIntoVM`).
  self.data.deepReviewSelectedFileIndex =
    max(vm.reviewRowIndexForPath(selectedReviewPath(vm)), 0)
  self.data.deepReviewSelectedTraceContextId = vm.currentTraceContextId()

proc startDeepReviewNavigation*(data: Data) =
  ## The single host entry point for a review, whichever launch path started
  ## it: find the docked VCS panel of the current layout and enter the review
  ## on it.
  ##
  ## Requires a mounted GoldenLayout — `openLayoutTab` walks `data.ui.layout`
  ## — so callers must not invoke it before `initLayout` has run.  It is
  ## deliberately safe to call repeatedly: `enterReview` refreshes the review's
  ## data every time and performs the *entry* (focus, open the first file)
  ## exactly once per panel, which is Layout-System.md's obligation 3.  DR-R1
  ## enforced that with a module-level `var` here; the flag now lives on the
  ## panel's own ViewModel, where a headless test can observe it and where two
  ## panels cannot share one answer.
  ##
  ## The review-mode check comes first: a call that arrives with no review
  ## data must not count as an entry, or the real review that starts a moment
  ## later would find the one-shot already spent (which is exactly what the
  ## old ordering did).
  if data.isNil or not data.deepReviewActive or data.deepReviewData.isNil:
    return
  if data.ui.layout.isNil:
    return
  for _, component in data.ui.componentMapping[Content.VCS]:
    let vcsComponent = cast[VCSComponent](component)
    if vcsComponent.isNil:
      continue
    vcsComponent.startReviewNavigation()
    return
  cerror "vcs: startDeepReviewNavigation: no docked VCS panel in the layout; " &
    "the review starts with no file open"

proc openReviewDataset*(data: Data; dataset: DeepReviewData) =
  ## AA-3 — enter a review over a dataset that arrived while this window was
  ## already open, because the reviewer selected an evidence tool call in the
  ## Agent Activity session feed (DeepReview-GUI.md §2.1.1).
  ##
  ## It is deliberately *not* a fourth way to open a review.  It publishes the
  ## dataset exactly where the other three launch paths publish theirs and
  ## then calls the one host entry point, so from `startDeepReviewNavigation`
  ## downwards — `enterReview`, the VCS panel, the diff tabs, the flow overlay
  ## — nothing can tell which path it was.  The only thing this adds is the
  ## re-arming, which is what makes a *second* dataset behave like a first.
  ##
  ## The new review **replaces** the one the window is showing rather than
  ## opening beside it, which is what `ct review <PATH>` does: a review has no
  ## workspace and no panel of its own (§2), so two concurrent reviews would
  ## need two VCS panels, two changed-files selections and two answers to
  ## "which review is this editor tab from".
  ##
  ## `startOptions.reviewSession` is deliberately left alone: the reviewer is
  ## still reading the same agent session, and it is that session's own feed
  ## they clicked in.  Only which of its datasets is under review changed.
  if data.isNil or dataset.isNil:
    return
  data.deepReviewData = dataset
  # Kept in step with the renderer's copy for the same reason
  # `startReviewForTraceDiff` does it: `syncLegacyVCSIntoVM` re-reads the
  # review from `data.deepReviewData` on every render, and other surfaces
  # read `startOptions.deepReview`.
  data.startOptions.deepReview = dataset
  data.startOptions.withDeepReview = true
  data.deepReviewActive = true
  data.deepReviewSelectedFileIndex = 0
  # Zero is the contract's "not chosen yet", which the VCS panel resolves to
  # the new dataset's first declared context.  Carrying the previous review's
  # id over would select a context this dataset may not declare.
  data.deepReviewSelectedTraceContextId = 0
  if not data.ui.isNil:
    for _, component in data.ui.componentMapping[Content.VCS]:
      let vcsComponent = cast[VCSComponent](component)
      if vcsComponent.isNil:
        continue
      resetReviewEntry(vcsComponent.ensureVCSVM())
  startDeepReviewNavigation(data)

proc startReviewForTraceDiff*(data: Data; diff: Diff; title: string;
                              traceLabel: string; recordingId: string) =
  ## Launch method 2 of DeepReview-GUI.md §1: the opened trace is associated
  ## with a diff, so the session *is* a review of that diff.
  ##
  ## It publishes the assembled dataset exactly where the other two paths
  ## publish theirs and then calls the one entry routine, so nothing
  ## downstream — the VCS panel, the diff tabs, the Agent Activity section —
  ## can tell which launch path it was.
  ##
  ## A review that is already active is left alone: a trace opened *into* a
  ## running review (`ct review` loads no trace today, but a session can
  ## gain one) must not have its exported dataset replaced by the bare diff.
  if data.isNil or diff.isNil or diff.files.len == 0:
    return
  if data.deepReviewActive and not data.deepReviewData.isNil:
    return
  data.deepReviewData = reviewDataForTraceDiff(
    diff, title, traceLabel, recordingId)
  if data.deepReviewData.files.len == 0:
    data.deepReviewData = nil
    return
  data.deepReviewActive = true
  data.startOptions.deepReview = data.deepReviewData
  startDeepReviewNavigation(data)

proc tryMountIsoNimVCSPanel*(componentId: int) =
  when defined(js):
    # THE LATCH IS ASKED OF THE CONTAINER, NOT OF THE ID, and so it is asked
    # further down, once `container` has been resolved.
    #
    # This pane was the airtight case: `isoNimVCSMountedIds` was written in one
    # place and deleted in NO place in the whole tree — `VCSComponent` has
    # neither a `register` nor an `unregister` method — so once VCS had mounted,
    # every later `tryMount` for that id returned immediately, for the life of
    # the page. A mode swap destroys the host and builds an empty one with the
    # same id, and the pane never came back. See `ui/isonim_panel_mount.nim`.
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
    if not isoNimPanelNeedsMount(
        idLatchSaysMounted = isoNimVCSMountedIds.hasKey(componentId) and
                             isoNimVCSMountedIds[componentId],
        containerCarriesMark = isoNimPanelContainerIsMounted(
          cast[isonim_dom_api.Element](container))):
      return
    component.syncLegacyVCSIntoVM()
    let callbacks = VCSCallbacks(
      onToggleBranchDropdown: proc() =
        component.branchDropdownOpen = not component.branchDropdownOpen
        component.syncLegacyVCSIntoVM(),
      onCheckoutBranch: proc(branch: string) =
        component.branchDropdownOpen = false
        component.commitOffset = 0
        component.allCommitsLoaded = false
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
      onSelectFile: proc(index: int; path, target, status: string) =
        component.handleVCSFileSelection(index, path, target, status),
      onToggleUnifiedDiff: proc() =
        component.openFileMode = not component.openFileMode
        component.syncLegacyVCSIntoVM(),
      onSetTraceContext: proc(id: int) =
        component.handleTraceContextSelection(id),
      onRefresh: proc() =
        component.refreshVCSData()
        component.syncLegacyVCSIntoVM(),
      onOpenFileDiff: proc(target: string) =
        component.openUnifiedDiffTab(target),
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
    markIsoNimPanelContainerMounted(cast[isonim_dom_api.Element](container))
    isoNimVCSMountedIds[componentId] = true
  else:
    discard
