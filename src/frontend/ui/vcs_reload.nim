## The VCS panel's reload: what it reads from git, how it reads it without
## waiting, and how the answers become the panel's state.
##
## VCS-Panel.md, "An auto-refresh never stalls the window": the reload after
## a check found a change — and the panel's first load, its refresh control
## and the reload after a branch checkout, which are the same reload — issues
## every read without the UI thread waiting for it, and applies the new state
## at once when all of them have answered. Until then the panel shows what it
## showed. It used to read through `gitExec`, one `execFileSync` per read on
## the renderer's main thread (codetracer-pm issue
## `2026-10-23-vcs-reload-after-a-detected-change-runs-git-synchronously`).
##
## Three layers, kept apart so each can be tested without the next:
##
##   * THE READS. One argv per question (`insideWorkTreeArgs` …
##     `commitNameStatusArgs`), shared by the reload and by the synchronous
##     readers that remain (`commitPageNow`, `commitFilesNow`), so the two
##     cannot ask git different questions. `readPanelReload` issues them
##     through `git_cli.gitReadAllLater` and answers with the raw outputs.
##   * THE STATE. `panelStateOf` turns raw outputs into the panel's values
##     with the parsers below — the ones the synchronous `load*` procs of
##     `ui/vcs.nim` used, moved here unchanged — and `applyPanelState` writes
##     them into a `VCSComponent` in one step.
##   * ONE AT A TIME. `requestPanelReload` holds a panel to one reload in
##     flight, turns requests during it into exactly one more (applying the
##     one in flight first, so a stream of requests cannot starve the panel),
##     discards an answer read for something the panel no longer shows, and
##     runs no git for a session with no project folder.
##
## Host-free, like `git_cli`: git is reached only through the platform
## facade.

import ui_imports

import git_cli
from ../viewmodel/platform/vcs import parsePorcelainV2
from ../viewmodel/viewmodels/vcs_vm import workingTreeRowsOf

const
  CommitPageSize* = 50
    ## Number of commits fetched per page for the infinite-scroll commit
    ## graph — the first page by a reload, each later one by
    ## `ui/vcs.loadMoreCommits`.
  NotAGitRepositoryText* = "Not a git repository"
    ## What the panel says when its working directory is in no work tree.

# ---------------------------------------------------------------------------
# The reads
# ---------------------------------------------------------------------------

proc insideWorkTreeArgs*(): seq[cstring] =
  ## "true" inside a work tree; anything else (or a failure) means none.
  @[cstring"rev-parse", cstring"--is-inside-work-tree"]

proc currentBranchArgs*(): seq[cstring] =
  ## The checked-out branch; empty on a detached HEAD.
  @[cstring"branch", cstring"--show-current"]

proc shortHeadArgs*(): seq[cstring] =
  ## HEAD's abbreviated id: what the panel names a detached HEAD by.
  @[cstring"rev-parse", cstring"--short", cstring"HEAD"]

proc workingTreeArgs*(): seq[cstring] =
  ## The working tree's changes, in the format `parsePorcelainV2` reads.
  @[cstring"status", cstring"--porcelain=v2", cstring"--branch"]

proc branchListArgs*(): seq[cstring] =
  @[cstring"branch", cstring"--format=%(refname:short)"]

const CommitFieldSeparator = "\x1e"
  ## Between a commit's fields: a byte that cannot occur in a hash, a subject
  ## line, a date or a name.

proc commitPageArgs*(skip: int): seq[cstring] =
  ## ``CommitPageSize`` commits starting at ``skip``, parent hashes included so
  ## the commit-graph algorithm can assign branch lanes.
  ##
  ## Format: ``<fullHash> <parent1> [<parent2> …>]\x1e<shortHash>\x1e<subject>\x1e<relDate>\x1e<absDate>\x1e<author>``
  ## The ``%P`` token is a space-separated list of full parent hashes;
  ## it is empty for root commits.  ``%cs`` produces the committer date in
  ## short YYYY-MM-DD format (requires git ≥ 2.29).
  const sep = CommitFieldSeparator
  let prettyFmt = "%H %P" & sep & "%h" & sep & "%s" & sep & "%cr" & sep & "%cs" & sep & "%an"
  @[cstring"log",
    cstring("--pretty=format:" & prettyFmt),
    cstring("--skip=" & $skip),
    cstring("-" & $CommitPageSize)]

proc commitNumstatArgs*(commitHash: cstring): seq[cstring] =
  ## The files changed in one commit, with line counts. `git diff-tree` works
  ## for any commit without a parent check (a root commit included).
  @[cstring"diff-tree", cstring"--no-commit-id", cstring"-r", cstring"--numstat", commitHash]

proc commitNameStatusArgs*(commitHash: cstring): seq[cstring] =
  ## The same files by name and status: the fallback when `--numstat` names
  ## none.
  @[cstring"diff-tree", cstring"--no-commit-id", cstring"-r", cstring"--name-status", commitHash]

# ---------------------------------------------------------------------------
# The parsers: raw output in, the panel's values out
# ---------------------------------------------------------------------------

proc currentBranchOf*(showCurrent, shortHead: cstring): cstring =
  ## The branch the panel names: the checked-out branch, or — on a detached
  ## HEAD, where `branch --show-current` answers nothing — HEAD's short id.
  if showCurrent.isNil or showCurrent.len == 0:
    (if shortHead.isNil: cstring"" else: shortHead)
  else:
    showCurrent

proc workingTreeChangesOf*(raw: cstring): seq[VCSChangedFile] =
  ## The working tree's changed files, read by the SAME `parsePorcelainV2`
  ## the native front-ends' VCS facade reads with, so the three VCS panes
  ## cannot disagree about a file's state (PLAT-47 deliverable 4).
  for row in workingTreeRowsOf(parsePorcelainV2(if raw.isNil: "" else: $raw)):
    result.add VCSChangedFile(
      status: cstring(row.status), filename: cstring(row.path))

proc branchesOf*(raw: cstring): seq[cstring] =
  ## One branch per non-blank line of `branchListArgs`' output.
  if raw.isNil or raw.len == 0:
    return
  for line in ($raw).splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(cstring(trimmed))

proc commitPageOf*(raw: cstring): seq[VCSCommit] =
  ## The commits of one `commitPageArgs` answer, newest first.
  if raw.isNil or raw.len == 0:
    return
  for line in ($raw).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.split(CommitFieldSeparator)
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
    result.add(VCSCommit(
      hash: cstring(shortH),
      message: cstring(subject),
      relativeTime: cstring(relDate),
      date: cstring(absDate),
      fullHash: cstring(fullH),
      author: cstring(authorStr),
      parents: parents,
    ))

proc numstatFilesOf*(raw: cstring): seq[VCSChangedFile] =
  ## `commitNumstatArgs`' answer: ``<added>\t<deleted>\t<filename>`` per line,
  ## the status inferred from the counts.
  if raw.isNil or raw.len == 0:
    return
  for line in ($raw).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
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
      result.add(VCSChangedFile(
        status: status,
        filename: cstring(parts[2]),
        additions: added,
        deletions: deleted))

proc nameStatusFilesOf*(raw: cstring): seq[VCSChangedFile] =
  ## `commitNameStatusArgs`' answer: ``<status>\t<filename>`` per line.
  if raw.isNil or raw.len == 0:
    return
  for line in ($raw).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.split("\t")
    if parts.len >= 2:
      result.add(VCSChangedFile(
        status: cstring(parts[0]),
        filename: cstring(parts[1]),
        additions: 0,
        deletions: 0))

proc commitFilesOf*(numstat, nameStatus: cstring): seq[VCSChangedFile] =
  ## A commit's changed files: the `--numstat` answer, or — when it names no
  ## file — the `--name-status` one.
  result = numstatFilesOf(numstat)
  if result.len == 0:
    result = nameStatusFilesOf(nameStatus)

# ---------------------------------------------------------------------------
# The synchronous readers that remain
#
# A user's own gesture — scrolling to the end of the commit list, expanding a
# commit — still reads synchronously: those reads answer the gesture, the
# result is shown in the same frame, and neither runs on a timer. They read
# with the argv and parsers above, so the reload and they agree.
# ---------------------------------------------------------------------------

proc commitPageNow*(cwd: cstring; skip: int): seq[VCSCommit] =
  commitPageOf(gitExec(commitPageArgs(skip), cwd))

proc commitFilesNow*(cwd, commitHash: cstring): seq[VCSChangedFile] =
  ## Only when `--numstat` names nothing is `--name-status` run at all.
  result = numstatFilesOf(gitExec(commitNumstatArgs(commitHash), cwd))
  if result.len == 0:
    result = nameStatusFilesOf(gitExec(commitNameStatusArgs(commitHash), cwd))

proc applyCommitPage*(component: VCSComponent; page: seq[VCSCommit]; skip: int) =
  ## Put a page of commits read at ``skip`` into the panel: the first page
  ## replaces the list, a later one extends it.
  ##
  ## ``commitOffset`` advances by the rows that came back, so the
  ## infinite-scroll sentinel can tell a full page from the last, short one —
  ## see ``allCommitsLoaded`` in ``VCSComponent``.
  if skip == 0:
    component.commits = @[]
  for commit in page:
    component.commits.add commit
  component.commitOffset = skip + page.len
  component.allCommitsLoaded = page.len < CommitPageSize

# ---------------------------------------------------------------------------
# Gathering a reload's reads without waiting
# ---------------------------------------------------------------------------

type
  VcsReloadTarget* = object
    ## What a reload reads for: the working directory (empty: the platform's
    ## default, as everywhere in `git_cli`) and the expanded commits, by their
    ## index in the commit list. Two reloads for equal targets read the same
    ## things.
    workingDirectory*: string
    expanded*: seq[int]

  VcsCommitFilesRead* = object
    ## One expanded commit's changed files, both answers.
    index*: int
    numstat*: cstring
    nameStatus*: cstring

  VcsReloadReads* = object
    ## Every raw answer a reload needs, as `gitExec` would have returned each
    ## ("" for a failure).
    target*: VcsReloadTarget
    insideWorkTree*: cstring
    currentBranch*: cstring
    shortHead*: cstring
    workingTree*: cstring
    branches*: cstring
    commitPage*: cstring
    commitFiles*: seq[VcsCommitFilesRead]
      ## One per expanded index that names a commit of the new first page,
      ## in the order of ``target.expanded``.

proc readPanelReload*(target: VcsReloadTarget; done: proc(reads: VcsReloadReads)) =
  ## Read everything a reload of the panel needs for ``target`` and call
  ## ``done`` once, with all of it.
  ##
  ## Two rounds, each issued at once and joined by `gitReadAllLater`:
  ##
  ##   1. whether this is a work tree, the branch, HEAD's short id, the
  ##      working tree, the branch list and the first page of commits — side
  ##      by side, so on the desktop six git processes run together and the
  ##      round costs about one of them;
  ##   2. inside a work tree, for each expanded commit the new page names, its
  ##      `--numstat` and `--name-status` — the commit an index names is only
  ##      known once the page has been read.
  ##
  ## Round 1 asks for HEAD's short id and round 2 for the name-status even
  ## when the answers will not be used (a branch is checked out; `--numstat`
  ## named files): asking only when needed would add a round trip, and an
  ## unused answer changes nothing in `panelStateOf`. Outside a work tree the
  ## other five reads of round 1 fail and are ignored.
  let cwd = cstring(target.workingDirectory)
  gitReadAllLater(@[insideWorkTreeArgs(), currentBranchArgs(), shortHeadArgs(),
                    workingTreeArgs(), branchListArgs(), commitPageArgs(0)], cwd,
    proc(first: seq[cstring]) =
      var reads = VcsReloadReads(
        target: target,
        insideWorkTree: first[0], currentBranch: first[1], shortHead: first[2],
        workingTree: first[3], branches: first[4], commitPage: first[5])
      if reads.insideWorkTree != cstring"true":
        done(reads)
        return
      let page = commitPageOf(reads.commitPage)
      var calls: seq[seq[cstring]] = @[]
      for index in target.expanded:
        # An index the new page does not reach is skipped, as
        # `loadChangedFilesForIndex` skipped it.
        if index >= 0 and index < page.len:
          reads.commitFiles.add VcsCommitFilesRead(index: index)
          calls.add commitNumstatArgs(page[index].hash)
          calls.add commitNameStatusArgs(page[index].hash)
      gitReadAllLater(calls, cwd, proc(second: seq[cstring]) =
        for i in 0 ..< reads.commitFiles.len:
          reads.commitFiles[i].numstat = second[2 * i]
          reads.commitFiles[i].nameStatus = second[2 * i + 1]
        done(reads)))

# ---------------------------------------------------------------------------
# From the reads to the panel
# ---------------------------------------------------------------------------

type
  VcsPanelState* = object
    ## The panel's values after a reload, computed before any is assigned so
    ## that they are assigned together (`applyPanelState`).
    isGitRepo*: bool
    errorMessage*: cstring
    currentBranch*: cstring
    workingTreeChanges*: seq[VCSChangedFile]
    branches*: seq[cstring]
    commitPage*: seq[VCSCommit]
    commitFiles*: seq[tuple[index: int; files: seq[VCSChangedFile]]]

proc panelStateOf*(reads: VcsReloadReads): VcsPanelState =
  ## The panel's state for a reload's answers.
  ##
  ## Outside a work tree only ``isGitRepo`` and ``errorMessage`` mean
  ## anything — `applyPanelState` leaves every other field as it was, as the
  ## synchronous reload did when it returned after `isGitRepository`.
  if reads.insideWorkTree != cstring"true":
    return VcsPanelState(isGitRepo: false,
                         errorMessage: cstring(NotAGitRepositoryText))
  result = VcsPanelState(
    isGitRepo: true,
    errorMessage: cstring"",
    currentBranch: currentBranchOf(reads.currentBranch, reads.shortHead),
    workingTreeChanges: workingTreeChangesOf(reads.workingTree),
    branches: branchesOf(reads.branches),
    commitPage: commitPageOf(reads.commitPage))
  for read in reads.commitFiles:
    result.commitFiles.add (read.index, commitFilesOf(read.numstat, read.nameStatus))

proc applyPanelState*(component: VCSComponent; state: VcsPanelState) =
  ## Write a reload's state into the panel, all of it in this one call, so no
  ## render can see some fields from the new state and some from the old.
  component.isGitRepo = state.isGitRepo
  component.errorMessage = state.errorMessage
  if not state.isGitRepo:
    return
  component.currentBranch = state.currentBranch
  component.workingTreeChanges = state.workingTreeChanges
  component.branches = state.branches
  component.applyCommitPage(state.commitPage, skip = 0)
  # The files of every expanded commit the new page still reaches; any other
  # index is left without an entry, as before.
  component.commitFilesCache = JsAssoc[int, seq[VCSChangedFile]]{}
  for entry in state.commitFiles:
    component.commitFilesCache[entry.index] = entry.files
    # `changedFiles` is the files of the commit loaded last, which is what
    # the synchronous reload left in it as a side effect of loading each
    # expanded commit in turn; the panel's changed-file rows read it.
    component.changedFiles = entry.files

# ---------------------------------------------------------------------------
# One reload at a time
# ---------------------------------------------------------------------------

proc requestPanelReload*(reload: VcsPanelReload;
                         target: proc(): VcsReloadTarget;
                         folderless: proc(): bool;
                         apply: proc(reads: VcsReloadReads)) =
  ## Start a reload through `readPanelReload`, or — when one is in flight —
  ## make sure exactly one more follows it. ``apply`` is called with the
  ## answers of a reload that is still current; until then the panel keeps
  ## showing what it showed.
  ##
  ## A reload superseded by another request while it read is STILL APPLIED,
  ## and the one requested after it then reads again. Its answers are newer
  ## than what the panel shows, so applying them loses nothing; discarding
  ## them would let a stream of requests that each arrive before the reload in
  ## flight answers — a change check every 5 s against a repository whose
  ## reload takes longer than that, while something keeps writing to it —
  ## keep the panel on its old state for ever. The change check holds to the
  ## same rule (`git_cli.requestRefreshCheck` answers a check that has a
  ## follow-up queued).
  ##
  ## A reload's answers are DISCARDED, never applied, when:
  ##
  ##   * ``target()`` changed while it read — the working directory moved, or
  ##     the user expanded or collapsed a commit, so they describe something
  ##     the panel no longer shows. One more reload reads for what it shows
  ##     now; without it, the change check that triggered this one would
  ##     compare equal next time and the panel would never catch up;
  ##   * ``folderless()`` became true — the session has no repository; the
  ##     panel's own folderless path shows the absence;
  ##   * ``releaseInFlight`` was called while it read — the caller wrote the
  ##     panel's state itself, and no follow-up queued before then runs.
  ##
  ## (VCS-Panel.md, "An auto-refresh never stalls the window".)
  ##
  ## A reload that would start while ``folderless()`` is true runs no git at
  ## all and calls nothing: an empty working directory would read the launch
  ## directory's repository (VCS-Panel.md, "A session with no project
  ## folder"). The caller's own guard covers the requests it makes; this one
  ## covers the follow-up, which starts from here.
  if reload.inFlight:
    reload.followUp = true
    return
  if folderless():
    return
  reload.inFlight = true
  let issuedFor = target()
  readPanelReload(issuedFor, proc(reads: VcsReloadReads) =
    reload.inFlight = false
    let released = reload.released
    reload.released = false
    try:
      if released:
        # `releaseInFlight` was called while these reads ran: the panel's
        # state now belongs to whoever wrote it, so this answer is dropped. A
        # follow-up queued before the release was cleared by it; one queued
        # after it is a new request and still runs below.
        discard
      elif folderless():
        discard
      elif target() != issuedFor:
        reload.followUp = true
      else:
        apply(reads)
    finally:
      # Even when `apply` raised: the queued request still gets its reload.
      if reload.followUp:
        reload.followUp = false
        requestPanelReload(reload, target, folderless, apply))

proc releaseInFlight*(reload: VcsPanelReload) =
  ## Give up the reload in flight, if any, because the caller has just written
  ## the panel's state itself: its answers are discarded when they arrive, and
  ## a follow-up queued before this call does not start. A reload requested
  ## after this call reads as usual, following the released one.
  ##
  ## The agentic launcher is that caller (`agentic_session_launcher.syncVcs`):
  ## it shows the agent's worktree in the panel without git. While the first
  ## load answered before it returned, the launcher's write always came last;
  ## now that the load answers later, an answer still in flight would replace
  ## the launcher's state with the repository git read.
  if reload.isNil or not reload.inFlight:
    return
  reload.released = true
  reload.followUp = false
