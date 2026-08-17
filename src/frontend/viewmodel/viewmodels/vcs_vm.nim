## ViewModel for the VCS / DeepReview changed-files panel.
##
## The legacy ``VCSComponent`` still owns git subprocess calls, file watching,
## hunk patch actions, and cross-panel DeepReview selection.  This VM carries
## the flat render snapshot consumed by the IsoNim VCS view.
##
## Commit graph:
##   Each ``VCSCommitRow`` carries a ``graphCells`` sequence — one
##   ``VCSGraphCell`` per visible branch lane.  The view renders them as a
##   small grid of coloured vertical lines and dots to the left of the commit
##   message, matching the VSCode Git Graph style.
##
## Accordion:
##   ``selectedCommitIndex`` doubles as the accordion open/close state:
##   clicking an already-selected commit sets ``selectedCommitIndex`` to -1
##   (collapsed); clicking a different one selects + expands it, and the view
##   renders ``changedFiles`` inline under that row.
##
## Infinite scroll:
##   ``loadingMore`` is set to true by the legacy component while a background
##   git-log page fetch is in progress.  The view shows a subtle loading row
##   at the bottom of the commit list until it flips back to false.

import std/strutils

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

const
  ContextExpandStep* = 10
    ## Lines one click of an expand control reveals — VCS-Panel.md, "Unified
    ## Diff View (Editor Integration)": "Context expansion controls (Expand N
    ## lines above/below)".
    ##
    ## Carried over unchanged from ``ui/deepreview.nim``'s ``EXPAND_STEP`` so
    ## the migrated control behaves exactly as the standalone panel's did.  It
    ## lives here, next to the state it advances, because both the counters
    ## below and the control's own label are derived from it and the two must
    ## not drift apart; ``viewmodels/context_expansion.nim`` re-exports it.

type
  VCSGraphCellKind* = enum
    gckEmpty  ## no branch passes through this column for this row
    gckLine   ## a branch passes through (vertical line only)
    gckDot    ## this commit lives in this column (circle + line)

  VCSGraphCell* = object
    ## One cell of the commit-graph grid rendered to the left of each commit.
    kind*: VCSGraphCellKind
    colorIdx*: int ## index into the branch colour palette (0-5, cycled)

  VCSGraphConnector* = object
    ## A right-angle connector drawn between two lane columns in one commit row.
    ##
    ## Two kinds exist:
    ##   ``isTop = false`` (bottom connector):
    ##     Drawn from row centre → bottom.  Used at merge commits when a new
    ##     merge-parent lane opens below the dot.  Visual: dot lane at 50%
    ##     curves RIGHT (or LEFT) and runs down to the new lane at 100%.
    ##   ``isTop = true`` (top connector):
    ##     Drawn from row top → centre.  Used when a branch converges back
    ##     onto the dot lane (i.e. it is the common ancestor in the forward
    ##     direction).  Visual: feature lane at 0% curves into the dot lane
    ##     at 50%.
    fromLane*: int   ## source column
    toLane*:   int   ## destination column
    colorIdx*: int   ## branch colour palette index
    isTop*:    bool  ## true → top-half connector; false → bottom-half

  VCSCommitRow* = object
    hash*: string          ## abbreviated SHA-1 for display
    message*: string       ## commit subject
    relativeTime*: string  ## e.g. "3 hours ago"
    date*: string          ## absolute date in YYYY-MM-DD format (git %cs token)
    author*: string        ## author name, shown when the accordion is open
    fullHash*: string      ## full SHA-1, shown in the accordion header
    graphCells*: seq[VCSGraphCell] ## branch-graph columns for this row
    dotLane*: int                        ## column of the commit dot (-1 = none)
    connectors*: seq[VCSGraphConnector]  ## merge/fork connectors for this row

  VCSFileRow* = object
    status*: string
    path*: string
    baseName*: string
    additions*: int
    deletions*: int
    coverageText*: string
    selected*: bool

  VCSDiffLineRow* = object
    lineType*: string
    content*: string
    oldLine*: int
    newLine*: int

  VCSHunkRow* = object
    oldStart*: int
    oldCount*: int
    newStart*: int
    newCount*: int
    selected*: bool
    lines*: seq[VCSDiffLineRow]

  VCSDiffFileRow* = object
    fileIndex*: int
    status*: string
    path*: string
    additions*: int
    deletions*: int
    hunks*: seq[VCSHunkRow]
    sourceLines*: seq[string]
      ## The file's full text on the *new* side of the diff, one element per
      ## 1-based source line, or empty when it could not be obtained.
      ##
      ## This is what context expansion reveals from (DeepReview-GUI.md §4.2:
      ## "Context expansion is incremental loading").  It is a plain field
      ## rather than a fetch callback because the two instantiation modes
      ## "differ in where the extra lines come from, and only there": the
      ## review export carries the text in ``DeepReviewFileData.sourceContent``
      ## and normal version-control mode obtains it with ``git show
      ## <rev>:<path>``.  Both answer that question at the data-source edge
      ## (``ui/unified_diff.nim``) and hand the result here, so nothing
      ## downstream — the document builder, the decorations, the overlay —
      ## can tell the modes apart.

  VCSHunkExpansion* = object
    ## How far one hunk has been expanded, in lines, in each direction.
    ##
    ## Totals rather than deltas, so a hunk's whole expansion state is these
    ## two numbers and re-deriving its revealed window is idempotent.  Keyed by
    ## ``(fileIndex, hunkIndex)`` — the same pair the hunk selection uses — so
    ## expanding one hunk cannot disturb its siblings or another file's.
    fileIndex*: int
    hunkIndex*: int
    above*: int
    below*: int

  VCSTraceContextRow* = object
    ## One selectable trace context of a review session — the control
    ## DeepReview-GUI.md §2 houses in the VCS panel header ("Trace context
    ## selector → The VCS panel header, populated only in DeepReview mode").
    ##
    ## It mirrors ``DeepReviewTraceContext`` (``common_types/
    ## codetracer_features/deepreview.nim``) reduced to what the header
    ## renders: the id the selection is expressed in, and the label shown in
    ## the dropdown.  It is deliberately a local row type rather than the
    ## store's ``DeepReviewTraceContextEntry`` so that this VM keeps depending
    ## on nothing but IsoNim — the standalone panel that owns that entry type
    ## is deleted in DR-R8.
    id*: int
    label*: string

  VCSViewMode* = enum
    ## What clicking a file row in the docked panel does — the "View mode
    ## toggle" of `codetracer-specs/GUI/Core-Panes/VCS-Panel.md`.
    vmUnifiedDiff  ## open a unified diff tab for the file (spec default,
                   ## `vcs.defaultView: "unified-diff"`)
    vmOpenFile     ## open the file itself in the editor

  VCSOpenActionKind* = enum
    ## What a click on a changed-file row resolves to.
    voaNone        ## nothing to open (no such row, or a row with no path)
    voaDiffTab     ## open/focus the unified diff tab for `target`
    voaSourceFile  ## open/focus the file itself in the editor

  VCSOpenAction* = object
    ## The decision a file-row click makes, as data.
    ##
    ## It is data rather than an effect so the decision is testable without a
    ## browser: the host (`ui/vcs.nim`) is a dispatcher over this value and
    ## owns only the GoldenLayout/Monaco side effects.
    kind*: VCSOpenActionKind
    index*: int     ## row index the click came from
    path*: string   ## file path as the row reports it
    target*: string ## diff target (`file:<path>`, `commit:<hash>:<path>`, …)
    status*: string ## diff status letter of the row ("M", "A", "D", "R", …)

  VCSVM* = ref object of ViewModel
    deepReviewMode*: Signal[bool]
    headerTitle*: Signal[string]
    headerIcon*: Signal[string]
    ## Summary line for the review the header describes — file count and the
    ## changeset's total +/-.  Empty in normal version-control mode, where the
    ## header describes a live working tree rather than a fixed changeset.
    statsText*: Signal[string]
    ## The review's selectable trace contexts, in export order.  Empty in
    ## normal version-control mode: a working tree has no recordings behind
    ## it.  DeepReview-GUI.md §6: "The selected trace context can be changed
    ## without leaving the review, from the selector in the VCS panel header".
    traceContexts*: Signal[seq[VCSTraceContextRow]]
    ## Id of the currently selected entry of ``traceContexts``.
    selectedTraceContextId*: Signal[int]
    isGitRepo*: Signal[bool]
    errorMessage*: Signal[string]
    currentBranch*: Signal[string]
    branches*: Signal[seq[string]]
    branchDropdownOpen*: Signal[bool]
    commits*: Signal[seq[VCSCommitRow]]
    ## Indices of all currently expanded commits (supports multi-select via
    ## ctrl+click / shift+click).  Empty seq means the accordion is collapsed.
    selectedCommitIndices*: Signal[seq[int]]
    ## Anchor for shift-click range selection; -1 when no anchor is set.
    lastClickedIndex*: Signal[int]
    ## Files per expanded commit: seq of (commitIndex, fileRows) pairs.
    ## Each expanded commit has its own entry so multiple accordions can show
    ## different file lists simultaneously.
    commitFilesMap*: Signal[seq[(int, seq[VCSFileRow])]]
    changedFiles*: Signal[seq[VCSFileRow]]  ## DeepReview mode file list
    ## What a file click does in the docked panel.  Distinct from
    ## `unifiedDiffActive`: this one never changes what the panel *renders*.
    viewMode*: Signal[VCSViewMode]
    ## True when this panel instance IS a unified diff — a dedicated diff tab,
    ## or the inline diff of an agentic-session review.  The docked panel keeps
    ## it false so toggling the view mode never replaces its commit history.
    unifiedDiffActive*: Signal[bool]
    diffFiles*: Signal[seq[VCSDiffFileRow]]
    ## Per-hunk context expansion, one entry per hunk the user has expanded
    ## (DeepReview-GUI.md §4.2).  Absent means "not expanded", so the empty
    ## seq is the initial state and ``resetContextExpansion`` is the whole
    ## reset.
    ##
    ## It lives on the ViewModel rather than in a JS-side ``JsAssoc`` on the
    ## host component — where ``ui/deepreview.nim`` kept it — so that it is
    ## assertable headlessly and survives a re-render: a GoldenLayout tab drag
    ## re-creates the component's DOM, and expansion held there would collapse
    ## every time the user moved the tab.
    hunkExpansion*: Signal[seq[VCSHunkExpansion]]
    selectedHunks*: Signal[seq[(int, int)]]
    hunkToolbarVisible*: Signal[bool]
    hunkCopyFeedback*: Signal[bool]
    ## Flat ordinal of the last singly-clicked hunk header — the anchor a
    ## shift-click range extends from (VCS-Panel.md, "Hunk Selection":
    ## "Shift-click to select a range of hunks").  -1 means "no anchor yet".
    ##
    ## It lives here rather than on the host component because DR-R4 moved the
    ## whole selection model into this ViewModel: the Monaco diff tab is a
    ## dispatcher over `selectHunk` and owns no selection state of its own.
    lastHunkClickOrdinal*: Signal[int]
    ## True once this panel has *entered* a review — that is, once the
    ## review-entry routine has focused the review's panels and opened its
    ## first modified file for it.
    ##
    ## `codetracer-specs/GUI/Layout-And-Navigation/Layout-System.md`,
    ## "DeepReview and the Layout", obligation 3: "re-entering a review on a
    ## layout persisted from an earlier review session must not accumulate
    ## duplicate tabs or re-focus over a selection the user has since changed
    ## within the same session."  Every launch path re-runs review entry
    ## whenever its data is re-synced (the agentic launcher re-syncs on every
    ## product-panel sync; `tryInitLayout` re-runs on every layout mount), so
    ## the "do this once" half of the routine needs a memory.
    ##
    ## It lives on the ViewModel rather than as a module-level `var` in the
    ## host (where DR-R1 first put it) for two reasons: a global cannot be
    ## reset between headless tests and cannot distinguish two panels, and the
    ## idempotence obligation is only assertable at all if the flag is
    ## reachable from a headless test.
    reviewEntered*: Signal[bool]
    loadingMore*: Signal[bool]  ## true while next commit page is being fetched

    fileCount*: Memo[int]
    selectedHunkCount*: Memo[int]

proc `==`*(a, b: VCSGraphCell): bool {.noSideEffect.} =
  a.kind == b.kind and a.colorIdx == b.colorIdx

proc `==`*(a, b: VCSGraphConnector): bool {.noSideEffect.} =
  a.fromLane == b.fromLane and a.toLane == b.toLane and a.colorIdx == b.colorIdx and
    a.isTop == b.isTop

proc `==`*(a, b: VCSCommitRow): bool {.noSideEffect.} =
  a.hash == b.hash and a.message == b.message and
    a.relativeTime == b.relativeTime and a.date == b.date and
    a.author == b.author and a.fullHash == b.fullHash and
    a.graphCells == b.graphCells and
    a.dotLane == b.dotLane and a.connectors == b.connectors

proc `==`*(a, b: VCSFileRow): bool {.noSideEffect.} =
  a.status == b.status and a.path == b.path and
    a.baseName == b.baseName and a.additions == b.additions and
    a.deletions == b.deletions and a.coverageText == b.coverageText and
    a.selected == b.selected

proc `==`*(a, b: VCSDiffLineRow): bool {.noSideEffect.} =
  a.lineType == b.lineType and a.content == b.content and
    a.oldLine == b.oldLine and a.newLine == b.newLine

proc `==`*(a, b: VCSHunkRow): bool {.noSideEffect.} =
  a.oldStart == b.oldStart and a.oldCount == b.oldCount and
    a.newStart == b.newStart and a.newCount == b.newCount and
    a.selected == b.selected and a.lines == b.lines

proc `==`*(a, b: VCSDiffFileRow): bool {.noSideEffect.} =
  a.fileIndex == b.fileIndex and a.status == b.status and
    a.path == b.path and a.additions == b.additions and
    a.deletions == b.deletions and a.hunks == b.hunks and
    a.sourceLines == b.sourceLines

proc `==`*(a, b: VCSHunkExpansion): bool {.noSideEffect.} =
  a.fileIndex == b.fileIndex and a.hunkIndex == b.hunkIndex and
    a.above == b.above and a.below == b.below

proc `==`*(a, b: VCSTraceContextRow): bool {.noSideEffect.} =
  a.id == b.id and a.label == b.label

proc `==`*(a, b: VCSOpenAction): bool {.noSideEffect.} =
  a.kind == b.kind and a.index == b.index and a.path == b.path and
    a.target == b.target and a.status == b.status

proc isDeletedStatus*(status: string): bool {.noSideEffect.} =
  ## True for the diff statuses that mean "this path is gone from the new
  ## tree".  Git reports the letter; the DeepReview export and some of the
  ## panel's own helpers use the spelled-out word, so both are accepted.
  status == "D" or status == "deleted"

proc documentKey*(action: VCSOpenAction): string {.noSideEffect.} =
  ## The identity of the editor document this action asks for.
  ##
  ## It is what makes "opening a file that is already open focuses the
  ## existing tab" work: the host keys diff tabs by `diff:<target>`
  ## (`Component.independentTabPath`, matched in `utils.openLayoutTab`) and
  ## source tabs by the editor tab path (matched in `utils.openTab`), so two
  ## clicks on one row must produce one key.
  case action.kind
  of voaNone: ""
  of voaDiffTab: "diff:" & action.target
  of voaSourceFile: action.path

proc openActionFor*(vm: VCSVM; index: int; path, target, status: string):
    VCSOpenAction =
  ## Resolve what clicking a changed-file row does.  Pure: no signals are
  ## written, nothing is opened.
  ##
  ## This is the single decision point for both normal version control and
  ## DeepReview mode — DeepReview-GUI.md §3: "clicking a file opens it in the
  ## editor, in the representation the view mode toggle currently selects …
  ## it works identically in normal VCS mode and in DeepReview mode".
  ##
  ## Deleted files are the one case the two specs are silent about, and
  ## DR-R1 decides it here: a file with status `D` has no content in the new
  ## tree, so it always resolves to the diff tab that shows the removal,
  ## never to an "open file" for a path that no longer exists.
  if path.len == 0 and target.len == 0:
    return VCSOpenAction(kind: voaNone, index: index)
  let diffTarget = if target.len > 0: target else: "file:" & path
  let wantsSource = vm.viewMode.val == vmOpenFile and not isDeletedStatus(status)
  VCSOpenAction(
    kind: if wantsSource: voaSourceFile else: voaDiffTab,
    index: index,
    path: path,
    target: diffTarget,
    status: status)

proc openActionForRow*(vm: VCSVM; index: int): VCSOpenAction =
  ## `openActionFor` for a row of the panel's own changed-files list — the
  ## list DeepReview mode renders, and the one the review-entry step walks.
  let rows = vm.changedFiles.val
  if index < 0 or index >= rows.len:
    return VCSOpenAction(kind: voaNone, index: index)
  let row = rows[index]
  vm.openActionFor(index, row.path, "file:" & row.path, row.status)

proc reviewStatsText*(files: openArray[VCSFileRow]): string {.noSideEffect.} =
  ## The review summary the VCS panel header shows next to the session title
  ## — DeepReview-GUI.md §2, "Session title / stats → The VCS panel header".
  ##
  ## Only what a review dataset actually carries is summarised: the number of
  ## changed files and the changeset's total added/removed line counts, both
  ## of which come from ``DeepReviewData.files[].diff``.  Coverage and test
  ## results deliberately do NOT appear here: they belong to the Agent
  ## Activity panel (§2.1, DR-R3), and ``DeepReviewData`` carries no
  ## test-results field at all, so a "tests 0/0" stat would be invented
  ## rather than reported.
  if files.len == 0:
    return ""
  var additions = 0
  var deletions = 0
  for file in files:
    additions += file.additions
    deletions += file.deletions
  result = $files.len & (if files.len == 1: " file" else: " files")
  if additions > 0 or deletions > 0:
    result.add(" +" & $additions & " -" & $deletions)

proc resolveTraceContextId*(contexts: openArray[VCSTraceContextRow];
                            wanted: int): int {.noSideEffect.} =
  ## The trace context that should be selected given a caller's preference.
  ##
  ## ``wanted`` is honoured when it names one of ``contexts``; otherwise the
  ## first context wins, because "the first entry is selected by default"
  ## (``DeepReviewTraceContext``'s own contract).  A review with no contexts
  ## resolves to 0, which no option carries, so nothing renders as selected.
  for ctx in contexts:
    if ctx.id == wanted:
      return wanted
  if contexts.len > 0: contexts[0].id else: 0

proc setDeepReviewMode*(vm: VCSVM; active: bool) =
  vm.deepReviewMode.val = active

proc setHeader*(vm: VCSVM; title: string; icon = "\239\132\166";
                statsText = "") =
  ## ``statsText`` mirrors ``DeepReviewVM.setHeader``'s third argument.  It
  ## defaults to empty so the normal version-control callers clear it: the
  ## review summary must not survive into a live working-tree session.
  vm.headerTitle.val = title
  vm.headerIcon.val = icon
  vm.statsText.val = statsText

proc setTraceContexts*(vm: VCSVM;
                       contexts: openArray[VCSTraceContextRow]) =
  vm.traceContexts.val = @contexts

proc setSelectedTraceContextId*(vm: VCSVM; id: int) =
  vm.selectedTraceContextId.val = id

proc currentTraceContextId*(vm: VCSVM): int =
  ## Reader for `selectedTraceContextId`, so hosts that do not import IsoNim's
  ## signal accessors (`ui/vcs.nim` is one) can mirror the review-wide
  ## selection onto `Data` without reaching into the signal.
  vm.selectedTraceContextId.val

proc hasTraceContextChoice*(vm: VCSVM): bool =
  ## Whether the header should offer the trace-context selector at all.
  ##
  ## Review mode only — the control has no meaning for a working tree — and
  ## only when there is something to choose between: a review that declares a
  ## single context would render a dropdown whose every option is the current
  ## one.
  vm.deepReviewMode.val and vm.traceContexts.val.len >= 2

proc setGitRepoState*(vm: VCSVM; isRepo: bool; errorMessage = "") =
  vm.isGitRepo.val = isRepo
  vm.errorMessage.val = errorMessage

proc setBranchState*(vm: VCSVM; current: string; branches: openArray[string];
                     dropdownOpen: bool) =
  vm.currentBranch.val = current
  vm.branches.val = @branches
  vm.branchDropdownOpen.val = dropdownOpen

proc setCommits*(vm: VCSVM; commits: openArray[VCSCommitRow];
                 selectedIndices: openArray[int];
                 lastClicked: int = -1) =
  ## Update the commit list and multi-select state.
  ## ``selectedIndices`` is the set of expanded commit indices; out-of-range
  ## values are silently dropped so callers don't need to clamp manually.
  vm.commits.val = @commits
  var clamped: seq[int] = @[]
  for idx in selectedIndices:
    if idx >= 0 and idx < commits.len:
      clamped.add(idx)
  vm.selectedCommitIndices.val = clamped
  vm.lastClickedIndex.val = lastClicked

proc setCommitFiles*(vm: VCSVM; commitIndex: int;
                     files: openArray[VCSFileRow]) =
  ## Insert or update the file list for a single expanded commit in the map.
  var newMap = vm.commitFilesMap.val
  for i, pair in newMap:
    if pair[0] == commitIndex:
      newMap[i] = (commitIndex, @files)
      vm.commitFilesMap.val = newMap
      return
  newMap.add((commitIndex, @files))
  vm.commitFilesMap.val = newMap

proc removeCommitFiles*(vm: VCSVM; commitIndex: int) =
  ## Remove the file list for a commit that is no longer expanded.
  var newMap: seq[(int, seq[VCSFileRow])] = @[]
  for pair in vm.commitFilesMap.val:
    if pair[0] != commitIndex:
      newMap.add(pair)
  vm.commitFilesMap.val = newMap

proc syncCommitFilesMap*(vm: VCSVM;
                         entries: openArray[(int, seq[VCSFileRow])]) =
  ## Replace the entire commitFilesMap with the provided entries.
  ## Called by syncLegacyVCSIntoVM to push the full per-commit file cache.
  vm.commitFilesMap.val = @entries

proc setChangedFiles*(vm: VCSVM; files: openArray[VCSFileRow]) =
  vm.changedFiles.val = @files

proc setViewMode*(vm: VCSVM; mode: VCSViewMode) =
  vm.viewMode.val = mode

proc setUnifiedDiff*(vm: VCSVM; active: bool;
                     files: openArray[VCSDiffFileRow]) =
  vm.unifiedDiffActive.val = active
  vm.diffFiles.val = @files

proc setHunkState*(vm: VCSVM; selected: openArray[(int, int)];
                   toolbarVisible: bool; copyFeedback: bool) =
  vm.selectedHunks.val = @selected
  vm.hunkToolbarVisible.val = toolbarVisible
  vm.hunkCopyFeedback.val = copyFeedback

proc setLoadingMore*(vm: VCSVM; loading: bool) =
  vm.loadingMore.val = loading

# ---------------------------------------------------------------------------
# Hunk editor (VCS-Panel.md, "Hunk Editor")
# ---------------------------------------------------------------------------
#
# The whole selection model lives here, in pure code over ``VCSDiffFileRow``.
#
# Until DR-R4 it lived in ``ui/vcs.nim`` over the raw ``DeepReviewData`` of a
# DOM-rendered diff panel, which made it unreachable without a browser and tied
# it to one renderer.  The Monaco diff tab is a dispatcher over ``selectHunk``
# and ``buildPatchFromSelectedHunks``; it holds no selection state of its own,
# so there is exactly one model and the hunk editor survives the port
# (DeepReview-GUI.md §4.5: "the hunk editor is a *constraint on the diff tab,
# not an optional extra*").
#
# ``VCSDiffFileRow.fileIndex`` — not the row's position in ``diffFiles`` — is
# the file identity a selection pair names, because the row list omits files
# that carry no hunks.  Every lookup below goes through it.

proc fileRowByIndex*(files: openArray[VCSDiffFileRow]; fileIndex: int): int =
  ## Position in ``files`` of the row whose ``fileIndex`` is ``fileIndex``,
  ## or -1.
  for i, file in files:
    if file.fileIndex == fileIndex:
      return i
  -1

proc flatHunkOrdinal*(files: openArray[VCSDiffFileRow];
                      fileIndex, hunkIndex: int): int {.noSideEffect.} =
  ## Position of a (fileIndex, hunkIndex) pair in the flat sequence of every
  ## hunk in the document, counting files in render order.  Shift-click ranges
  ## are expressed in these ordinals because a range can span files.
  result = 0
  for file in files:
    if file.fileIndex == fileIndex:
      return result + hunkIndex
    result += file.hunks.len

proc hunkPairFromOrdinal*(files: openArray[VCSDiffFileRow]; ordinal: int):
    (int, int) {.noSideEffect.} =
  ## Inverse of ``flatHunkOrdinal``.  Returns (-1, -1) when the ordinal names
  ## no hunk, so a caller walking a range can skip rather than invent a pair;
  ## the DOM implementation returned (0, 0) there, which named a real hunk.
  if ordinal < 0:
    return (-1, -1)
  var remaining = ordinal
  for file in files:
    if remaining < file.hunks.len:
      return (file.fileIndex, remaining)
    remaining -= file.hunks.len
  (-1, -1)

proc isHunkSelected*(vm: VCSVM; fileIndex, hunkIndex: int): bool =
  for pair in vm.selectedHunks.val:
    if pair[0] == fileIndex and pair[1] == hunkIndex:
      return true
  false

proc clearHunkSelection*(vm: VCSVM) =
  vm.selectedHunks.val = @[]
  vm.hunkToolbarVisible.val = false

proc toggleHunkSelection*(vm: VCSVM; fileIndex, hunkIndex: int) =
  ## VCS-Panel.md, "Hunk Selection": "Ctrl-click to toggle individual hunk
  ## selection".
  var selected = vm.selectedHunks.val
  var found = -1
  for i in 0 ..< selected.len:
    if selected[i][0] == fileIndex and selected[i][1] == hunkIndex:
      found = i
      break
  if found >= 0:
    selected.delete(found)
  else:
    selected.add((fileIndex, hunkIndex))
  vm.selectedHunks.val = selected
  vm.hunkToolbarVisible.val = selected.len > 0

proc selectHunkRange*(vm: VCSVM; fromOrdinal, toOrdinal: int) =
  ## VCS-Panel.md, "Hunk Selection": "Shift-click to select a range of hunks".
  ## Additive, like the DOM implementation: an existing selection is extended
  ## rather than replaced.
  let files = vm.diffFiles.val
  let lo = min(fromOrdinal, toOrdinal)
  let hi = max(fromOrdinal, toOrdinal)
  var selected = vm.selectedHunks.val
  for ordinal in lo .. hi:
    let pair = hunkPairFromOrdinal(files, ordinal)
    if pair[0] < 0:
      continue
    if not vm.isHunkSelected(pair[0], pair[1]) and pair notin selected:
      selected.add(pair)
  vm.selectedHunks.val = selected
  vm.hunkToolbarVisible.val = selected.len > 0

proc selectHunk*(vm: VCSVM; fileIndex, hunkIndex: int;
                 shiftKey = false; ctrlKey = false) =
  ## The single entry point a diff surface calls when a hunk header is clicked.
  ##
  ## VCS-Panel.md, "Hunk Selection": "Click a hunk header to select it.
  ## Shift-click to select a range of hunks. Ctrl-click to toggle individual
  ## hunk selection."  A plain click on the sole selected hunk deselects it,
  ## which is what makes a click a toggle for a single-hunk selection.
  let files = vm.diffFiles.val
  let ordinal = flatHunkOrdinal(files, fileIndex, hunkIndex)
  if shiftKey and vm.lastHunkClickOrdinal.val >= 0:
    vm.selectHunkRange(vm.lastHunkClickOrdinal.val, ordinal)
  elif ctrlKey:
    vm.toggleHunkSelection(fileIndex, hunkIndex)
  else:
    if vm.selectedHunks.val.len == 1 and vm.isHunkSelected(fileIndex, hunkIndex):
      vm.clearHunkSelection()
    else:
      vm.clearHunkSelection()
      vm.selectedHunks.val = @[(fileIndex, hunkIndex)]
      vm.hunkToolbarVisible.val = true
  vm.lastHunkClickOrdinal.val = ordinal

proc setHunkCopyFeedback*(vm: VCSVM; copied: bool) =
  vm.hunkCopyFeedback.val = copied

proc mutatingHunkOpsEnabled*(vm: VCSVM): bool =
  ## Whether the hunk operations that *change* the repository (stage/unstage,
  ## discard, move to commit) may be offered.
  ##
  ## VCS-Panel.md, "DeepReview Mode": "Commit operations: Disabled (read-only
  ## view)" — a review's changeset is immutable, and the repository the review
  ## describes need not even be the one the process was started in.
  ##
  ## This is deliberately NOT consulted by the diff renderer.  VCS-Panel.md,
  ## "Unified Diff View (Shared)": "The diff rendering code does NOT check
  ## which mode is active — it simply renders whatever data is provided."  The
  ## mode question belongs to the toolbar's *operations*, not to how a line is
  ## drawn.
  not vm.deepReviewMode.val

proc buildPatchFromSelectedHunks*(vm: VCSVM): string =
  ## The selected hunks as a unified diff patch — VCS-Panel.md, "Hunk
  ## Operations": "Copy — copy selected hunks to clipboard (as patch format)".
  ##
  ## Byte-for-byte the output of the pre-DR-R4 implementation in
  ## ``ui/vcs.nim``: files are grouped in order of first appearance in the
  ## selection, each group emits the three ``diff --git`` / ``---`` / ``+++``
  ## header lines, hunks follow in selection order with an ``@@`` header and
  ## one ``+`` / ``-`` / space-prefixed line each, and the whole thing is
  ## newline-joined with a trailing newline.  The golden in
  ## ``src/tests/gui/tests/vcs/vcs_vm_test.nim`` pins it.
  ##
  ## One deliberate difference, in a case the old code could only reach with a
  ## corrupt selection: when *no* selected pair names a file that is present,
  ## the old version returned a lone "\n" (an empty patch that the caller then
  ## copied to the clipboard).  This one returns "", so there is nothing to
  ## copy.
  let files = vm.diffFiles.val
  let selected = vm.selectedHunks.val
  if selected.len == 0:
    return ""

  # Group selected hunks by file index, preserving order of first appearance.
  var fileHunks: seq[(int, seq[int])] = @[]
  for pair in selected:
    let fi = pair[0]
    let hi = pair[1]
    var found = false
    for j in 0 ..< fileHunks.len:
      if fileHunks[j][0] == fi:
        fileHunks[j][1].add(hi)
        found = true
        break
    if not found:
      fileHunks.add((fi, @[hi]))

  var parts: seq[string] = @[]
  for entry in fileHunks:
    let rowIndex = fileRowByIndex(files, entry[0])
    if rowIndex < 0:
      continue
    let file = files[rowIndex]
    let path = file.path

    parts.add("diff --git a/" & path & " b/" & path)
    parts.add("--- a/" & path)
    parts.add("+++ b/" & path)

    for hi in entry[1]:
      if hi < 0 or hi >= file.hunks.len:
        continue
      let hunk = file.hunks[hi]
      parts.add("@@ -" & $hunk.oldStart & "," & $hunk.oldCount &
                " +" & $hunk.newStart & "," & $hunk.newCount & " @@")
      for line in hunk.lines:
        let prefix =
          case line.lineType
          of "added": "+"
          of "removed": "-"
          else: " "
        parts.add(prefix & line.content)

  if parts.len == 0:
    return ""
  result = parts.join("\n") & "\n"

# ---------------------------------------------------------------------------
# Context expansion (DeepReview-GUI.md §4.2, "Context Expansion")
# ---------------------------------------------------------------------------
#
# Only the bookkeeping lives here — which hunk has been expanded how far.  The
# window arithmetic (which source lines that reveals, and whether a further
# step would reveal anything) is ``viewmodels/context_expansion.nim``, which
# imports this module; the split is what keeps the arithmetic pure and this
# state reactive.

proc expansionCountsIn*(rows: openArray[VCSHunkExpansion];
                        fileIndex, hunkIndex: int): (int, int)
                        {.noSideEffect.} =
  ## ``(above, below)`` for one hunk.  A hunk with no entry is not expanded,
  ## which is also the honest answer for a hunk that does not exist.
  for row in rows:
    if row.fileIndex == fileIndex and row.hunkIndex == hunkIndex:
      return (row.above, row.below)
  (0, 0)

proc expansionCounts*(vm: VCSVM; fileIndex, hunkIndex: int): (int, int) =
  expansionCountsIn(vm.hunkExpansion.val, fileIndex, hunkIndex)

proc bumpExpansion(vm: VCSVM; fileIndex, hunkIndex, above, below: int) =
  ## Add to one hunk's counters, creating its entry on first use.
  ##
  ## Accumulating rather than replacing is what §4.2's third required control
  ## means — "Repeated expansion loads more file content instead of merely
  ## uncovering lines that were already fetched".
  var rows = vm.hunkExpansion.val
  for i in 0 ..< rows.len:
    if rows[i].fileIndex == fileIndex and rows[i].hunkIndex == hunkIndex:
      rows[i].above += above
      rows[i].below += below
      vm.hunkExpansion.val = rows
      return
  rows.add(VCSHunkExpansion(fileIndex: fileIndex, hunkIndex: hunkIndex,
                            above: above, below: below))
  vm.hunkExpansion.val = rows

proc expandContextAbove*(vm: VCSVM; fileIndex, hunkIndex: int) =
  ## §4.2: "Expand surrounding context above a visible region".
  vm.bumpExpansion(fileIndex, hunkIndex, ContextExpandStep, 0)

proc expandContextBelow*(vm: VCSVM; fileIndex, hunkIndex: int) =
  ## §4.2: "Expand surrounding context below a visible region".
  vm.bumpExpansion(fileIndex, hunkIndex, 0, ContextExpandStep)

proc resetContextExpansion*(vm: VCSVM) =
  ## Forget every hunk's expansion.  The host calls this when the tab stops
  ## describing what it described — a closed tab, or a diff reloaded after
  ## staging, where the hunk indices the counters are keyed on no longer name
  ## the same hunks.
  vm.hunkExpansion.val = @[]

proc clearPanel*(vm: VCSVM) =
  vm.deepReviewMode.val = false
  vm.headerTitle.val = ""
  vm.headerIcon.val = "\239\132\166"
  vm.statsText.val = ""
  vm.traceContexts.val = @[]
  vm.selectedTraceContextId.val = 0
  vm.isGitRepo.val = false
  vm.errorMessage.val = ""
  vm.currentBranch.val = ""
  vm.branches.val = @[]
  vm.branchDropdownOpen.val = false
  vm.commits.val = @[]
  vm.selectedCommitIndices.val = @[]
  vm.lastClickedIndex.val = -1
  vm.commitFilesMap.val = @[]
  vm.changedFiles.val = @[]
  vm.viewMode.val = vmUnifiedDiff
  vm.unifiedDiffActive.val = false
  vm.diffFiles.val = @[]
  vm.hunkExpansion.val = @[]
  vm.selectedHunks.val = @[]
  vm.hunkToolbarVisible.val = false
  vm.hunkCopyFeedback.val = false
  vm.lastHunkClickOrdinal.val = -1
  # A cleared panel is no longer in a review, so the next review that starts
  # on it must open its first file again.
  vm.reviewEntered.val = false
  vm.loadingMore.val = false

proc createVCSVM*(): VCSVM =
  withViewModel proc(dispose: proc()): VCSVM =
    let changedFiles = createSignal(newSeq[VCSFileRow]())
    let selectedHunks = createSignal(newSeq[(int, int)]())

    let fileCount = createMemo[int] proc(): int =
      changedFiles.val.len

    let selectedHunkCount = createMemo[int] proc(): int =
      selectedHunks.val.len

    VCSVM(
      deepReviewMode: createSignal(false),
      headerTitle: createSignal(""),
      headerIcon: createSignal("\239\132\166"),
      statsText: createSignal(""),
      traceContexts: createSignal(newSeq[VCSTraceContextRow]()),
      selectedTraceContextId: createSignal(0),
      isGitRepo: createSignal(false),
      errorMessage: createSignal(""),
      currentBranch: createSignal(""),
      branches: createSignal(newSeq[string]()),
      branchDropdownOpen: createSignal(false),
      commits: createSignal(newSeq[VCSCommitRow]()),
      selectedCommitIndices: createSignal(newSeq[int]()),
      lastClickedIndex: createSignal(-1),
      commitFilesMap: createSignal(newSeq[(int, seq[VCSFileRow])]()),
      changedFiles: changedFiles,
      viewMode: createSignal(vmUnifiedDiff),
      unifiedDiffActive: createSignal(false),
      diffFiles: createSignal(newSeq[VCSDiffFileRow]()),
      hunkExpansion: createSignal(newSeq[VCSHunkExpansion]()),
      selectedHunks: selectedHunks,
      hunkToolbarVisible: createSignal(false),
      hunkCopyFeedback: createSignal(false),
      lastHunkClickOrdinal: createSignal(-1),
      reviewEntered: createSignal(false),
      loadingMore: createSignal(false),
      fileCount: fileCount,
      selectedHunkCount: selectedHunkCount,
      disposeProc: dispose,
    )
