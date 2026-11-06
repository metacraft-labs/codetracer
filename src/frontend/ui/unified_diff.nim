## The unified diff as a real Monaco editor tab (DR-R4).
##
##   "When the VCS panel's 'Unified Diff' mode is active, clicking a file in
##    the Changed Files list opens a special editor tab that shows the file's
##    diff: *Uses the standard CodeTracer Monaco editor*"
##   — GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Editor Integration)"
##
##   "In *Unified Diff mode*: the file's diff opens in a standard Monaco editor
##    tab with hunk decorations (green added, red removed, context)."
##   — DeepReview/DeepReview-GUI.md §7
##
## Before DR-R4 the tab was a second ``VCSComponent`` instance drawing nested
## ``tdiv`` elements: no find, no selection across the document, no minimap, no
## keyboard navigation, and no surface on which the Omniscience decorations of
## DR-R6 could be drawn at all.
##
## UD-1 changed what the tab *is*, again: it is Monaco's own **diff editor** in
## inline mode (``renderSideBySide: false``) over two real models, rather than
## one editor over an assembled diff document created with
## ``language: "plaintext"``.  The three weaknesses that followed from that one
## constant — no syntax highlighting, no word-level intra-line marking, and an
## expand control that could only be a *line of the document* — are answered by
## the editor owning both revisions and the models carrying the reviewed file's
## real language.  See
## ``codetracer-specs/DeepReview/Unified-Diff-Design.milestones.org``.
##
## What lives where
## ----------------
## - ``viewmodel/viewmodels/diff_document.nim`` — pure: rows in, the two model
##   texts (``DiffPair``) and one decoration per line out, plus the language the
##   models are created with.  It never sees a mode, which is VCS-Panel.md's
##   "the diff rendering code does NOT check which mode is active" made
##   structural.
## - ``viewmodel/viewmodels/diff_target.nim`` — pure: which git command a
##   target (and the active review's commit) asks for, when the diff comes
##   from git.
## - ``viewmodel/viewmodels/vcs_vm.nim`` — the hunk editor's selection model
##   and its patch builder, shared with the docked panel's state rather than
##   duplicated here.
## - ``ui/review_diff_editor.nim`` — the part of the tab that needs no
##   ``Data``: the Monaco bindings, the diff editor's options and gutter, the
##   decorations, which invocation each function shows and the parallel value
##   bands.  The StoryBook bundle draws a review's file through it too.
## - this module — the data source (review dataset or git), the Monaco
##   instance, and the click-to-hunk dispatch.
##
## Data source, per VCS-Panel.md "Data Sources and Instantiation Modes": a
## review's diff comes from ``deepReviewData`` — "NOT from live git", because a
## review describes commits that need not exist in whatever repository the
## process happens to be started in — and live git serves everything else.

import
  ui_imports, session_viewmodels

import std/strformat
import isonim/core/signals
import git_cli
import flow_line_styles
import flow_loop_slider
import review_flow_adapter
import review_flow_selection
import ../viewmodel/viewmodels/vcs_vm
import ../viewmodel/viewmodels/diff_document
import ../viewmodel/viewmodels/diff_target
import ../viewmodel/viewmodels/context_expansion
import ../viewmodel/viewmodels/review_flow_overlay
import ./review_diff_editor
import diff_expansion

from isonim/web/dom_api as isonim_dom_api import nil
import isonim/web/web_renderer
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel
import ../viewmodel/views/isonim_unified_diff_view

var unifiedDiffVMInstances*: JsAssoc[int, VCSVM] = JsAssoc[int, VCSVM]{}
var unifiedDiffComponentRefs: JsAssoc[int, UnifiedDiffComponent] =
  JsAssoc[int, UnifiedDiffComponent]{}
var unifiedDiffSourceCaches: JsAssoc[int, SourceTextCache] =
  JsAssoc[int, SourceTextCache]{}
  ## One source-text cache per diff tab, holding the file text context
  ## expansion reveals from in normal version-control mode (DeepReview-GUI.md
  ## §4.2).  Per tab rather than global because a tab's lifetime is exactly the
  ## lifetime the cached blobs are wanted for, and `forgetUnifiedDiffTab`
  ## drops both this and the tab's ViewModel when the tab closes.

# The Monaco bindings, the editor's options, its decorations and the value
# bands are `review_diff_editor`'s: the half of this tab that needs no `Data`,
# shared with the StoryBook bundle's review story.
# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  if s.isNil: "" else: $s

proc rawTarget*(self: UnifiedDiffComponent): string =
  ## The diff target without the ``diff:`` layout-path prefix.
  if self.diffTarget.isNil:
    return ""
  let text = $self.diffTarget
  if text.startsWith("diff:"): text[5 .. ^1] else: text

proc scopedKey(self: UnifiedDiffComponent): int =
  ## The key this tab's ViewModel, source cache and component ref are filed
  ## under: `tabScopedId`, which makes it unique across the window's tabs. A
  ## section of a whole-commit document is in no tab's component mapping, so
  ## it is keyed in its document's tab rather than in whichever tab is on
  ## screen when it is looked up.
  if self.isNil:
    return -1
  if self.sectionOf.isNil:
    return data.tabScopedId(self)
  var session = data.sessionOfComponent(self.sectionOf)
  if session.isNil and data.sessions.len > 0:
    session = data.activeSession
  tabScopedKey(session, self.id)

proc ensureUnifiedDiffVM*(self: UnifiedDiffComponent): VCSVM =
  ## One ``VCSVM`` per diff tab.
  ##
  ## The tab reuses ``VCSVM`` rather than inventing a diff-tab ViewModel
  ## because the hunk editor's state — ``selectedHunks`` /
  ## ``hunkToolbarVisible`` / ``hunkCopyFeedback`` — already lives there, and
  ## DR-R4's constraint is one model, not a second one that happens to agree.
  if self.isNil:
    return nil
  if unifiedDiffVMInstances.hasKey(self.scopedKey()):
    return unifiedDiffVMInstances[self.scopedKey()]
  result = createVCSVM()
  unifiedDiffVMInstances[self.scopedKey()] = result

proc ensureSourceCache(self: UnifiedDiffComponent): SourceTextCache =
  if self.isNil:
    return nil
  if unifiedDiffSourceCaches.hasKey(self.scopedKey()):
    return unifiedDiffSourceCaches[self.scopedKey()]
  result = newSourceTextCache()
  unifiedDiffSourceCaches[self.scopedKey()] = result

proc forgetUnifiedDiffTab*(componentId: int) =
  ## Drop everything a closed diff tab owned. `componentId` is the tab-scoped
  ## key (`session_viewmodels.tabScopedKey`) the tables are keyed by.
  ##
  ## DR-R5's deliverable: "Expansion state resets when the tab is closed and
  ## does not leak between files."  Since UD-2 the expansion lives in the
  ## *editor* — Monaco's unchanged regions — and the editor goes with the tab's
  ## DOM, so dropping the ViewModel, the source cache and the component
  ## reference is the whole reset: a re-opened tab builds a fresh diff editor
  ## with every region collapsed again, rather than inheriting regions keyed on
  ## lines that may now belong to a different file.
  if unifiedDiffVMInstances.hasKey(componentId):
    discard jsDelete(unifiedDiffVMInstances[componentId])
  if unifiedDiffSourceCaches.hasKey(componentId):
    let cache = unifiedDiffSourceCaches[componentId]
    cache.invalidate()
    discard jsDelete(unifiedDiffSourceCaches[componentId])
  if unifiedDiffComponentRefs.hasKey(componentId):
    discard jsDelete(unifiedDiffComponentRefs[componentId])

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

proc loadFromReview(self: UnifiedDiffComponent): bool =
  ## Fill the tab from the review dataset.
  ##
  ## VCS-Panel.md, "DeepReview Mode": "Data source: The changeset from
  ## `deepReviewData` (files, hunks, diff metadata) — NOT from live git."
  ##
  ## Returns false when this is not a review, or the review carries no diff for
  ## this tab's target, so the caller can fall back to git.
  if not self.data.deepReviewActive:
    return false
  let drData = self.data.deepReviewData
  if drData.isNil:
    return false
  let target = self.rawTarget()
  if not target.startsWith("file:"):
    return false
  let wanted = target[5 .. ^1]

  var files: seq[DeepReviewFileData] = @[]
  for file in drData.files:
    if safeStr(file.path) == wanted and not file.diff.isNil:
      files.add(file)
  if files.len == 0:
    return false

  self.diffData = DeepReviewData(
    commitSha: drData.commitSha,
    baseCommitSha: drData.baseCommitSha,
    collectionTimeMs: 0,
    recordingCount: 0,
    sessionTitle: cstring("Diff: " & wanted),
    files: files)
  self.reviewBacked = true
  true

proc gitPlan(self: UnifiedDiffComponent): DiffGitPlan =
  ## The git command this tab's target resolves to, in the context of the
  ## active review (if any).
  ##
  ## The review's ``commitSha`` / ``baseCommitSha`` are passed only while a
  ## review is active: VCS-Panel.md, "Which two revisions a file row
  ## compares", scopes a review's ``file:<path>`` fallback to the commit under
  ## review, and outside a review the same target means the working tree.
  var reviewCommit = ""
  var reviewBase = ""
  if self.data.deepReviewActive and not self.data.deepReviewData.isNil:
    reviewCommit = safeStr(self.data.deepReviewData.commitSha)
    reviewBase = safeStr(self.data.deepReviewData.baseCommitSha)
  diffGitPlan(self.rawTarget(), reviewCommit, reviewBase)

proc loadFromGit(self: UnifiedDiffComponent) =
  ## Fill the tab by asking git for the target's diff.
  ##
  ## The REPOSITORY ROOT, not the opened project folder: three of the four
  ## targets below carry a `--` pathspec, and git resolves those against the
  ## current directory while the paths themselves come from
  ## `git diff-tree --numstat`, which is relative to the root.  Opening a
  ## project at a subdirectory made the two disagree, and every per-file and
  ## per-commit diff came back empty — silently, since git treats "no path
  ## matched" as an empty diff rather than an error.  Only the two targets with
  ## no pathspec (Working Tree, whole-commit) ever worked.
  ##
  ## Which command each target asks for is decided by the pure
  ## ``diff_target.diffGitPlan``, together with the active review's commit
  ## context (``gitPlan`` above); this proc only runs it and parses the result.
  let cwd = gitRepositoryRoot(self.data)
  let plan = self.gitPlan()
  var args: seq[cstring] = @[]
  for arg in plan.args:
    args.add(cstring(arg))

  let raw = gitExec(args, cwd)
  # Record the revisions actually compared: a review-scoped `file:` fallback
  # diffs the review's commit (against its base, when it names one), not
  # `HEAD` — VCS-Panel.md, "Which two revisions a file row compares".
  let comparedCommit =
    if plan.reviewScoped: self.data.deepReviewData.commitSha
    else: cstring"HEAD"
  let comparedBase =
    if plan.reviewScoped: self.data.deepReviewData.baseCommitSha
    else: cstring""
  self.diffData = DeepReviewData(
    commitSha: comparedCommit,
    baseCommitSha: comparedBase,
    collectionTimeMs: 0,
    recordingCount: 0,
    sessionTitle: cstring(plan.sessionTitle),
    files: parseGitDiffHunks($raw))
  self.reviewBacked = false
  self.gitNewRevision = cstring(plan.newRevision)
  self.gitReviewScoped = plan.reviewScoped

proc expansionRevision(self: UnifiedDiffComponent): string =
  ## The revision whose text the *new* side of this tab's diff shows.
  ##
  ## It is what context expansion must read from, and it is not always a
  ## revision: `git diff HEAD` compares against the tree on disk, so for a
  ## working-tree or `file:` target the new side is the working tree and no
  ## commit holds it.  That is spelled as the empty revision, which
  ## `gitFileText` reads as "the file itself".  A `commit:<hash>[:<path>]`
  ## target is the case §4.2 names: the lines are neither in the diff nor in
  ## the working tree, and only `git show <hash>:<path>` has them.
  ##
  ## So is a `file:` target during a review of a commit: VCS-Panel.md, "Which
  ## two revisions a file row compares", diffs that commit, so its new side is
  ## the commit and not the working tree.
  ##
  ## Recorded by ``loadFromGit`` from the plan it ran rather than resolved
  ## again here, so the revision the diff was taken against and the one
  ## expansion reads cannot disagree, not even after the review has ended.
  safeStr(self.gitNewRevision)

proc sourceLinesFor(self: UnifiedDiffComponent; file: DeepReviewFileData;
                    path: string): seq[string] =
  ## One file's full text, as the lines context expansion reveals from.
  ##
  ## This is the *only* place in the diff tab where the two instantiation
  ## modes differ, which is exactly what DeepReview-GUI.md §4.2 allows: "The
  ## two instantiation modes of the diff tab differ in where the extra lines
  ## come from, and only there ... The control, the decorations and the
  ## overlay behavior are identical in both cases."  Downstream of this proc
  ## the text is just ``VCSDiffFileRow.sourceLines`` and nothing can tell
  ## where it came from.
  if self.reviewBacked:
    # The review export carries the text — DeepReviewFileData.sourceContent,
    # "Full source text of the file ... Used to expand context around diff
    # hunks".  Expansion is a local slice; no I/O at all.
    if file.isNil or file.sourceContent.isNil:
      return @[]
    return sourceTextLines($file.sourceContent)
  if path.len == 0:
    return @[]
  let cwd = gitWorkingDirectory(self.data)
  let revision = self.expansionRevision()
  self.ensureSourceCache().linesFor(revision, path,
    proc(rev, blobPath: string): string =
      $gitFileText(cstring(rev), cstring(blobPath), cwd))

proc diffRows(self: UnifiedDiffComponent): seq[VCSDiffFileRow] =
  ## Project the parsed hunks into the ViewModel's row shape.
  ##
  ## ``fileIndex`` stays the index into ``diffData.files`` even though files
  ## with no hunks are skipped, because that index is the file identity a hunk
  ## selection pair names.
  result = @[]
  if self.diffData.isNil:
    return
  for fileIdx, file in self.diffData.files:
    if file.diff.isNil or file.diff.hunks.len == 0:
      continue
    result.add(reviewDiffFileRow(
      file, fileIdx, self.sourceLinesFor(file, safeStr(file.path))))

# ---------------------------------------------------------------------------
# Agent diff registry — raw original/modified content from agent activity
# ---------------------------------------------------------------------------

var agentDiffRegistry: JsAssoc[cstring, js] = JsAssoc[cstring, js]{}

proc registerAgentDiffEntry*(key: string; paths, originals, modifieds: seq[string]) =
  ## Store diff content for a ``Content.UnifiedDiff`` tab opened from agent
  ## activity.  ``paths[i]``, ``originals[i]``, ``modifieds[i]`` describe one
  ## file each.  ``key`` is used as the registry lookup key and must match the
  ## target string embedded in the tab's ``diffTarget``.
  var arr: seq[js] = @[]
  for i in 0 ..< paths.len:
    arr.add(js{
      path: cstring(paths[i]),
      original: cstring(originals[i]),
      modified: cstring(modifieds[i])
    })
  agentDiffRegistry[cstring(key)] = arr.toJs

proc loadFromAgentRegistry(self: UnifiedDiffComponent): bool =
  ## Fill the tab from the in-memory agent diff registry.  Returns true when
  ## the target is an ``agent-diff:`` one and the registry entry exists.
  let target = self.rawTarget()
  if not target.startsWith("agent-diff:"):
    return false
  let key = target[11 .. ^1]
  let ckey = cstring(key)
  if not agentDiffRegistry.hasKey(ckey):
    return false
  let entries = agentDiffRegistry[ckey]
  let count = entries.length.to(int)
  var files: seq[DeepReviewFileData] = @[]
  for i in 0 ..< count:
    let e = entries[i]
    let path = $(e.path.to(cstring))
    let original = $(e.original.to(cstring))
    let modified = $(e.modified.to(cstring))
    let origLines = original.splitLines()
    let modLines = modified.splitLines()
    var hunkLines: seq[DeepReviewHunkLine] = @[]
    var oldNum = 1
    for line in origLines:
      hunkLines.add(DeepReviewHunkLine(
        `type`: cstring"removed", content: cstring(line),
        oldLine: oldNum, newLine: 0))
      inc oldNum
    var newNum = 1
    for line in modLines:
      hunkLines.add(DeepReviewHunkLine(
        `type`: cstring"added", content: cstring(line),
        oldLine: 0, newLine: newNum))
      inc newNum
    files.add(DeepReviewFileData(
      path: cstring(path),
      sourceContent: cstring(modified),
      symbols: @[], coverage: @[], functions: @[], loops: @[], flow: @[],
      diff: DeepReviewFileDiff(
        status: cstring"M",
        linesAdded: modLines.len,
        linesRemoved: origLines.len,
        hunks: @[DeepReviewHunk(
          oldStart: 1, oldCount: origLines.len,
          newStart: 1, newCount: modLines.len,
          lines: hunkLines)])))
  let title =
    if count == 1: cstring("Agent Diff: " & $files[0].path)
    else: cstring"Agent Unified Diff"
  self.diffData = DeepReviewData(
    commitSha: cstring"", baseCommitSha: cstring"",
    collectionTimeMs: 0, recordingCount: 0,
    sessionTitle: title, files: files)
  self.reviewBacked = true
  true

proc ensureLoaded(self: UnifiedDiffComponent) =
  if self.initialized:
    return
  self.initialized = true
  # Only `loadFromGit` sets these; a reload served from elsewhere must not
  # inherit them from an earlier git load.
  self.gitNewRevision = cstring""
  self.gitReviewScoped = false
  if not self.loadFromReview():
    if not self.loadFromAgentRegistry():
      self.loadFromGit()
  # A section of a whole-commit document whose target has no per-file form
  # loaded the whole target; it shows only its own file
  # (`diff_target.diffSectionTarget`).
  let onlyPath = safeStr(self.sectionPath)
  if onlyPath.len > 0 and not self.diffData.isNil:
    var kept: seq[DeepReviewFileData] = @[]
    for file in self.diffData.files:
      if safeStr(file.path) == onlyPath:
        kept.add(file)
    self.diffData.files = kept

# ---------------------------------------------------------------------------
# Monaco
# ---------------------------------------------------------------------------

proc editorHostId*(componentId: int): string =
  fmt"unifiedDiffEditor-{componentId}"


proc rebuildLineLabels(self: UnifiedDiffComponent; pair: DiffPair) =
  ## Recompute the dual old/new gutter labels for both models
  ## (`review_diff_editor.reviewDiffLineLabels`).
  ##
  ## Monaco's ``lineNumbers`` callback closes over these sequences, so they
  ## must be refilled — not replaced — whenever a model's content changes, or
  ## the gutter keeps describing the previous document.
  let (labels, originalLabels) = reviewDiffLineLabels(pair)
  self.lineLabels.setLen(0)
  for label in labels:
    self.lineLabels.add(label)
  self.originalLineLabels.setLen(0)
  for label in originalLabels:
    self.originalLineLabels.add(label)

proc applyDecorations(self: UnifiedDiffComponent) =
  ## Publish each side's per-line decorations onto its own editor.
  if not self.editorInitialized or self.editor.isNil:
    return
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let pair = diffPairFor(vm)
  let selected = vm.selectedHunks.val
  let decorations = monacoDecorations(pair.modified, selected)
  if self.decorationCollection.isNil:
    self.decorationCollection =
      self.editor.udCreateDecorationsCollection(decorations.toJs)
  else:
    self.decorationCollection.udCollectionSet(decorations.toJs)
  if self.originalEditor.isNil:
    return
  let originalDecorations = monacoDecorations(pair.original, selected)
  if self.originalDecorationCollection.isNil:
    self.originalDecorationCollection =
      self.originalEditor.udCreateDecorationsCollection(originalDecorations.toJs)
  else:
    self.originalDecorationCollection.udCollectionSet(originalDecorations.toJs)

# ---------------------------------------------------------------------------
# The review's Omniscience overlay (RV-5)
# ---------------------------------------------------------------------------
#
#   "Flow data from the associated trace is rendered using the same
#    visualization system as normal debugging (`flowStyleLines`,
#    `applyEventualStylesLines`). […] The overlay is driven by the dataset, not
#    by a live recording."  — DeepReview-GUI.md §7
#
# The dataset is adapted into a real `FlowUpdate` (`ui/review_flow_adapter.nim`)
# and the per-line classes come from `ui/flow_line_styles.flowStyledLines` — the
# same proc `ui/editor.nim`'s `flowStyleLines` calls, so a review's annotations
# and a debugging session's are one implementation. Only the *mapping* onto this
# tab's synthetic document is review-specific, and that lives in the pure
# `viewmodel/viewmodels/review_flow_overlay.nim`.

proc reviewFlowFile(self: UnifiedDiffComponent):
    tuple[file: DeepReviewFileData, fileIndex: int] =
  ## The reviewed file this tab shows, and its index in `diffData.files` —
  ## which is the `fileIndex` the diff document's lines carry.
  ##
  ## A git-backed tab has no reviewed file: its `diffData` was parsed from
  ## `git diff` and carries no flow, no functions and no loops.
  result = (nil, -1)
  if not self.reviewBacked or self.diffData.isNil:
    return
  for index, file in self.diffData.files:
    if not file.diff.isNil and file.diff.hunks.len > 0:
      return (file, index)

# Which invocation each function shows, and what it recorded on each line, is
# `review_diff_editor`'s (`reviewDisplayedPlansOf` and its neighbours): the tab
# only says which file of its review that is.
proc reviewInvocationZonesFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewInvocationZone] =
  let (file, fileIndex) = self.reviewFlowFile()
  reviewInvocationZonesOf(file, fileIndex, doc)

proc reviewLoopIterationsFor(self: UnifiedDiffComponent;
                             plan: ReviewFlowPlan): seq[(int, int)] =
  reviewLoopIterationsOf(plan)

proc reviewFlowDecorationsFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewFlowDecoration] =
  let (file, fileIndex) = self.reviewFlowFile()
  reviewFlowDecorationsOf(file, fileIndex, doc, FlowUpdate, ViewSource)

proc reviewValueAnnotationsFor(self: UnifiedDiffComponent; doc: DiffDocument;
                               maxColumns: int = 1):
    seq[ReviewValueAnnotation] =
  let (file, fileIndex) = self.reviewFlowFile()
  reviewValueAnnotationsOf(file, fileIndex, doc, maxColumns)

proc reviewLoopZonesFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewLoopZone] =
  let (file, fileIndex) = self.reviewFlowFile()
  reviewLoopZonesOf(file, fileIndex, doc)

proc clearFlowValueWidgets(self: UnifiedDiffComponent) =
  ## Drop every band. Wholesale, and before anything is added: Monaco keys a
  ## content widget by `getId()`, so a band left behind for a line the repaint
  ## no longer annotates would keep showing the previous invocation's values —
  ## the "stale value from a previous pass" failure, one level up from the one
  ## the column rule prevents.
  if self.editor.isNil:
    self.flowValueWidgets = @[]
    self.flowValueZoneIds = @[]
    return
  for widget in self.flowValueWidgets:
    self.editor.udRemoveContentWidget(widget)
  self.flowValueWidgets = @[]
  for zoneId in self.flowValueZoneIds:
    self.editor.udRemoveViewZone(zoneId)
  self.flowValueZoneIds = @[]

proc applyFlowValueBands(self: UnifiedDiffComponent; doc: DiffDocument) =
  ## Draw the parallel value band for every annotated line of the document
  ## (`review_diff_editor.placeReviewValueBands`, which says how a band is
  ## placed beside the code or on its own row).
  if not self.editorInitialized or self.editor.isNil:
    return
  self.clearFlowValueWidgets()
  # Every recorded pass is asked for; how many are DRAWN is decided per line,
  # from the room that line's band has. A cap here would be a cap on what the
  # loop control can ever scroll to.
  let annotations = reviewValueAnnotationsFor(self, doc, high(int16).int)
  let fontSize =
    if self.data.isNil or self.data.ui.isNil: 14 else: self.data.ui.fontSize
  # Recorded on `self` as each is added, so `clearFlowValueWidgets` can
  # remove every band even when the placement raises half-way.
  placeReviewValueBands(self.editor, doc, annotations, self.id, fontSize,
    ReviewValueBandSink(
      bandLeft: proc(px: int) = self.flowValueWidgetMax = px,
      widget: proc(widget: js) = self.flowValueWidgets.add(widget),
      zone: proc(zoneId: int) = self.flowValueZoneIds.add(zoneId)))

proc applyFlowDecorations(self: UnifiedDiffComponent; doc: DiffDocument) =
  ## Repaint the whole overlay: the per-line classes and the value bands.
  ##
  ## The two are repainted together, because they answer the same question —
  ## "what did the selected invocation do here?" — and so always change
  ## together. Letting them drift apart would leave a stale band beside the
  ## classes that say which lines ran.
  if not self.editorInitialized or self.editor.isNil:
    return
  let decorations = monacoFlowDecorations(self.reviewFlowDecorationsFor(doc))
  if self.flowDecorationCollection.isNil:
    self.flowDecorationCollection =
      self.editor.udCreateDecorationsCollection(decorations.toJs)
  else:
    self.flowDecorationCollection.udCollectionSet(decorations.toJs)
  self.applyFlowValueBands(doc)

proc rebuildInvocationZones(self: UnifiedDiffComponent; doc: DiffDocument)
proc scheduleLoopSliders(self: UnifiedDiffComponent; doc: DiffDocument;
                         attempt: int)

proc stepInvocation(self: UnifiedDiffComponent; functionKey: string;
                    delta: int) =
  ## Move one invocation forward or back, and repaint.
  ##
  ## Clamped by `nextOrdinal`, so the ends of the range are stable — the
  ## behaviour the loop iteration slider has.
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffPairFor(vm).modified
  let (file, _) = self.reviewFlowFile()
  if file.isNil:
    return
  for zone in self.reviewInvocationZonesFor(doc):
    if zone.functionKey != functionKey:
      continue
    setReviewInvocationOrdinal(
      safeStr(file.path), functionKey, zone.nextOrdinal(delta))
    self.rebuildInvocationZones(doc)
    self.applyFlowDecorations(doc)
    return

proc setLoopIterationTo(self: UnifiedDiffComponent; functionKey: string;
                        loopIndex, iteration: int) =
  ## Select a pass through a loop outright, rather than by stepping.
  ##
  ## What the dragged slider calls. It shares `stepLoopIteration`'s clamping
  ## through `ReviewLoopZone.nextIteration`, expressed as a delta from where
  ## the zone currently is, so a drag and a click cannot disagree about what
  ## the ends of the range are.
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffPairFor(vm).modified
  let (file, _) = self.reviewFlowFile()
  if file.isNil:
    return
  for zone in self.reviewLoopZonesFor(doc):
    if zone.functionKey != functionKey or zone.loopIndex != loopIndex:
      continue
    let wanted = zone.nextIteration(iteration - zone.iteration)
    if wanted == zone.iteration:
      # A drag that landed back where it started must not repaint: the repaint
      # rebuilds the view zones, and rebuilding the zone under the pointer
      # cancels the drag in progress.
      return
    setReviewLoopIteration(safeStr(file.path), functionKey, loopIndex, wanted)
    self.rebuildInvocationZones(doc)
    self.applyFlowDecorations(doc)
    return

proc stepLoopIteration(self: UnifiedDiffComponent; functionKey: string;
                       loopIndex, delta: int) =
  ## Move one loop iteration forward or back, and repaint.
  ##
  ## The values are what change: the classes say which lines the *call* ran, and
  ## a different pass through a loop runs the same lines with different values.
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffPairFor(vm).modified
  let (file, _) = self.reviewFlowFile()
  if file.isNil:
    return
  for zone in self.reviewLoopZonesFor(doc):
    if zone.functionKey != functionKey or zone.loopIndex != loopIndex:
      continue
    setReviewLoopIteration(
      safeStr(file.path), functionKey, loopIndex, zone.nextIteration(delta))
    self.rebuildInvocationZones(doc)
    self.applyFlowDecorations(doc)
    return

proc reviewStepButton(label: cstring; klass: string; enabled: bool;
                      onStep: proc()): Node =
  ## One step button of a review's in-editor controls.
  ##
  ## `mousedown` rather than `click`: Monaco's own mouse handling on the editor
  ## can swallow a click that starts inside a view zone, and `mousedown` is what
  ## `ui/flow.nim`'s value spans listen for as well.
  result = document.createElement(cstring"button")
  result.setAttribute(cstring"class", cstring("review-flow-step " & klass))
  result.appendChild(document.createTextNode(label))
  if not enabled:
    result.setAttribute(cstring"disabled", cstring"disabled")
  else:
    result.addEventListener(cstring"mousedown", proc(e: Event) =
      e.stopPropagation()
      onStep())

proc invocationZoneDom(self: UnifiedDiffComponent;
                       zone: ReviewInvocationZone): Node =
  ## The control itself: a previous/next pair around a counter, in the register
  ## of the loop iteration slider (`.flow-loop-slider` / the flow panel's
  ## `.flow-iteration-slider`), rendered into a Monaco view zone above the
  ## function it governs.
  result = document.createElement(cstring"div")
  result.setAttribute(
    cstring"class",
    cstring"flow-view-zone review-flow-selector review-invocation-selector")
  result.setAttribute(
    cstring"id",
    cstring(fmt"review-invocation-selector-{self.id}-{zone.functionKey}"))
  result.setAttribute(cstring"data-function", cstring(zone.functionKey))
  result.setAttribute(cstring"data-ordinal", cstring($zone.ordinal))
  result.setAttribute(cstring"data-total", cstring($zone.total))

  let component = self
  let functionKey = zone.functionKey

  result.appendChild(reviewStepButton(
    cstring"‹", "review-invocation-prev", zone.canStepBack(),
    proc() = component.stepInvocation(functionKey, -1)))
  let label = document.createElement(cstring"span")
  label.setAttribute(cstring"class",
                     cstring"review-flow-label review-invocation-label")
  label.appendChild(document.createTextNode(
    cstring(invocationSelectorLabel(zone))))
  result.appendChild(label)
  result.appendChild(reviewStepButton(
    cstring"›", "review-invocation-next", zone.canStepForward(),
    proc() = component.stepInvocation(functionKey, 1)))

proc loopZoneDom(self: UnifiedDiffComponent; zone: ReviewLoopZone): Node =
  ## The loop iteration control — §4.4's "loop sliders", in the same stepper
  ## register as the invocation selector directly above it.
  ##
  ## Stepper AND slider (UD-3, closing RV-10). The two directions and the
  ## counter are the stepper's; the drag is `ui/flow_loop_slider.nim`'s
  ## `ensureFlowLoopSlider`, which is the same proc `ui/flow.ensureLoopSlider`
  ## builds the debugger's `noUiSlider` with — the same options, the same
  ## zero-width refusal, the same #562 lessons.
  ##
  ## RV-10 recorded the blocker as layout state a review has no
  ## `FlowComponent` to hold. What removed it is not a `FlowComponent` but the
  ## observation that the measurement was never the hard part: the control is a
  ## flex row, so the slider is the flex child that takes the space left over,
  ## and the layout answers "how wide" without any component's fields. The
  ## slider is still not CONSTRUCTED until that width is real — see
  ## `scheduleLoopSliders` — because that half of #562 is about when, not about
  ## where the number came from.
  result = document.createElement(cstring"div")
  result.setAttribute(
    cstring"class",
    cstring"flow-view-zone review-flow-selector review-loop-selector")
  result.setAttribute(
    cstring"id",
    cstring(fmt"review-loop-selector-{self.id}-{zone.functionKey}-{zone.loopIndex}"))
  result.setAttribute(cstring"data-function", cstring(zone.functionKey))
  result.setAttribute(cstring"data-loop", cstring($zone.loopIndex))
  result.setAttribute(cstring"data-iteration", cstring($zone.iteration))
  result.setAttribute(cstring"data-total", cstring($zone.total))

  let component = self
  let functionKey = zone.functionKey
  let loopIndex = zone.loopIndex

  result.appendChild(reviewStepButton(
    cstring"‹", "review-loop-prev", zone.canStepBack(),
    proc() = component.stepLoopIteration(functionKey, loopIndex, -1)))
  let label = document.createElement(cstring"span")
  label.setAttribute(cstring"class",
                     cstring"review-flow-label review-loop-label")
  label.appendChild(document.createTextNode(cstring(loopSelectorLabel(zone))))
  result.appendChild(label)
  result.appendChild(reviewStepButton(
    cstring"›", "review-loop-next", zone.canStepForward(),
    proc() = component.stepLoopIteration(functionKey, loopIndex, 1)))
  # The drag affordance. Appended even when there is a single pass — the
  # container is dropped again by `ensureFlowLoopSlider`'s zero-range refusal
  # rather than by a second copy of the "is there anything to choose between"
  # rule here.
  if zone.total > 1:
    result.appendChild(flowLoopSliderContainerDom(
      cstring(fmt"review-loop-slider-{self.id}-{zone.functionKey}-{zone.loopIndex}"),
      "review-loop-slider"))

proc reviewLoopSlideHandler(functionKey: string; loopIndex: int;
    onIteration: proc(functionKey: string; loopIndex, iteration: int)):
    proc(iteration: int) =
  # A widget invokes this after the zone loop has finished; its identity must
  # live in a separate factory call rather than shared loop-body locals.
  result = proc(iteration: int) = onIteration(functionKey, loopIndex, iteration)

proc bindReviewLoopSliders*(componentId: int; zones: seq[ReviewLoopZone];
    onIteration: proc(functionKey: string; loopIndex, iteration: int)): bool =
  ## Bind each rendered slider; return whether a later layout pass is needed.
  for zone in zones:
    let container = document.getElementById(cstring(
      fmt"review-loop-slider-{componentId}-{zone.functionKey}-{zone.loopIndex}"))
    if container.isNil:
      continue
    let element = cast[Node](container.querySelector(
      cstring("." & FlowLoopSliderClass)))
    if element.isNil:
      continue
    # `total - 1`: the range is over ITERATION INDICES, and the debugger's
    # `maxLoopIteration` is the same 0-based bound.
    if not ensureFlowLoopSlider(element, zone.total - 1, zone.iteration,
        reviewLoopSlideHandler(zone.functionKey, zone.loopIndex, onIteration)):
      if zone.total > 1:
        result = true

proc scheduleLoopSliders(self: UnifiedDiffComponent; doc: DiffDocument;
                         attempt: int) =
  ## Build the loop controls' sliders once their view zones have been laid out.
  ##
  ## #562's primary cause, on this surface: Monaco attaches and lays out a
  ## freshly registered view zone on a LATER frame, so during the tick in which
  ## `rebuildInvocationZones` builds one the slider's element has no box, and a
  ## noUiSlider constructed then is 0x2px and invisible. The debugger comes back
  ## through `resizeFlowSlider`, driven by its own render pass and by an editor
  ## resize observer; a review has neither, so it comes back on a timer.
  ##
  ## Bounded, and this matters: an unbounded retry against a tab that will
  ## never lay out (it was closed, or GoldenLayout destroyed its DOM) is a
  ## timer that runs forever.
  ##
  ## Twenty attempts over ~3s, not the eight over ~800ms it started at. The
  ## shorter window was enough on an idle machine and not enough under load —
  ## measured as an intermittent failure of "UD-3: the loop control carries the
  ## debugger's dragged slider", which is exactly the shape of #562 (a slider
  ## that exists sometimes) and must not be tuned by luck. The cost of the
  ## longer window is a few more no-op ticks on a tab that will never lay out;
  ## the cost of the shorter one is a control that is missing on a slow frame.
  const MaxAttempts = 20
  if attempt >= MaxAttempts:
    return
  if not self.editorInitialized or self.editor.isNil:
    return
  let pending = bindReviewLoopSliders(self.id, self.reviewLoopZonesFor(doc),
    proc(functionKey: string; loopIndex, iteration: int) =
      self.setLoopIterationTo(functionKey, loopIndex, iteration))
  if pending:
    discard windowSetTimeout(
      proc() = self.scheduleLoopSliders(doc, attempt + 1), 150)

proc rebuildInvocationZones(self: UnifiedDiffComponent; doc: DiffDocument) =
  ## Replace the whole set of in-editor controls — invocation selectors and loop
  ## iteration controls alike.
  ##
  ## Wholesale, and previous ids removed first: leaving them behind is how the
  ## loop slider ended up with a stack of dead controls (#562), and the anchors
  ## move whenever context expansion changes the document's numbering.
  if not self.editorInitialized or self.editor.isNil:
    return
  for zoneId in self.flowViewZoneIds:
    self.editor.udRemoveViewZone(zoneId)
  self.flowViewZoneIds = @[]
  # Taller than a line, and the control is laid out against the BOTTOM of it.
  #
  # Monaco's unchanged-region boundary straddles the lines either side of its
  # fold (UD-2 measured that and drew its own rule as a hairline because of
  # it), and `unified_diff.styl` lifts that widget to `z-index: 3` so its drag
  # handle can be pressed at all — above `.lines-content`, which is where a
  # view zone lives and where no `z-index` of ours can reach. A control drawn
  # in the top of a zone that shares a gap with a fold is therefore visible and
  # unpressable, which is worse than either. Measured with
  # `document.elementFromPoint` over the loop slider's handle: the hit was
  # `div.ct-diff-expand-boundary`. The clearance moves the control out from
  # under it.
  let lineHeight = self.data.ui.fontSize + 22
  # `afterLineNumber` is copied out of each `lent` zone before the descriptor
  # closes over it — see `monacoDecorations` for the lifetime rule.
  for zone in self.reviewInvocationZonesFor(doc):
    let
      dom = self.invocationZoneDom(zone)
      afterLine = zone.afterLineNumber
    self.flowViewZoneIds.add(self.editor.udAddViewZone(js{
      afterLineNumber: afterLine,
      heightInPx: lineHeight,
      domNode: dom
    }))
  for zone in self.reviewLoopZonesFor(doc):
    let
      dom = self.loopZoneDom(zone)
      afterLine = zone.afterLineNumber
    self.flowViewZoneIds.add(self.editor.udAddViewZone(js{
      afterLineNumber: afterLine,
      heightInPx: lineHeight,
      domNode: dom
    }))
  self.scheduleLoopSliders(doc, attempt = 0)

proc syncIntoVM*(self: UnifiedDiffComponent) =
  ## Push the tab's parsed diff into its ViewModel.  The hunk selection is left
  ## alone: it is the VM's own state and survives a re-sync.
  if self.isNil:
    return
  unifiedDiffComponentRefs[self.scopedKey()] = self
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  self.ensureLoaded()
  # `deepReviewMode` gates only the *mutating* hunk operations
  # (`VCSVM.mutatingHunkOpsEnabled`); the diff itself renders identically
  # either way, which is the rule VCS-Panel.md states under "Unified Diff View
  # (Shared)".
  #
  # A git fallback scoped to the review's commit is read-only as well: its
  # hunks are that commit's change, not the working tree's, so staging or
  # discarding them would apply the wrong patch to the repository.
  vm.setDeepReviewMode(self.reviewBacked or self.gitReviewScoped)
  vm.setUnifiedDiff(true, self.diffRows())

proc handleHunkClick(self: UnifiedDiffComponent; modelLine: int;
                     shiftKey, ctrlKey: bool) =
  ## VCS-Panel.md, "Hunk Selection": "Click a hunk header to select it.
  ## Shift-click to select a range of hunks.  Ctrl-click to toggle individual
  ## hunk selection."
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffPairFor(vm).modified
  if not isHunkHeaderLine(doc, modelLine):
    return
  let pair = hunkAtLine(doc, modelLine)
  if pair[0] < 0:
    return
  vm.selectHunk(pair[0], pair[1], shiftKey, ctrlKey)
  self.applyDecorations()

proc copySelectedHunks(self: UnifiedDiffComponent) =
  ## VCS-Panel.md, "Hunk Operations": "Copy — copy selected hunks to clipboard
  ## (as patch format)".
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let patch = vm.buildPatchFromSelectedHunks()
  if patch.len == 0:
    return
  clipboardCopy(cstring(patch))
  vm.setHunkCopyFeedback(true)
  discard windowSetTimeout(
    proc() =
      vm.setHunkCopyFeedback(false),
    2000)

proc applyGutterOptions(self: UnifiedDiffComponent; pair: DiffPair) =
  ## Give each side of the diff editor its own dual old/new gutter
  ## (`review_diff_editor.applyReviewDiffGutterOptions`).
  applyReviewDiffGutterOptions(self.editor, self.originalEditor,
                               self.lineLabels, self.originalLineLabels,
                               lineNumberColumnWidth(pair))

proc refreshModel(self: UnifiedDiffComponent) =
  ## Re-publish both documents into the live Monaco models.
  ##
  ## Content, gutter labels, gutter width and decorations move together: a
  ## model whose text changed under stale labels would number the wrong lines.
  if not self.editorInitialized or self.editor.isNil:
    return
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let pair = diffPairFor(vm)
  # `setValue` scrolls the viewport back to the top, which would throw the
  # reader out of the region they just expanded.  Expansion is the operation
  # that made this matter: it re-publishes the models on every click.
  let scrollTop = self.editor.udScrollTop()
  if not self.originalEditor.isNil:
    self.originalEditor.udSetValue(cstring(documentText(pair.original)))
  self.editor.udSetValue(cstring(documentText(pair.modified)))
  # A `setValue` throws the model's tokens away, so the deleted lines would go
  # back to one flat run on the first expansion — the defect returning through
  # the one gesture most likely to be used.
  if not self.originalModel.isNil:
    self.originalModel.udForceTokenization(DiffTokenizeLineLimit)
  self.rebuildLineLabels(pair)
  self.applyGutterOptions(pair)
  # The collapse's context width is derived from the document (see
  # `initEditor`), so it moves with it: a re-published document whose hunks
  # carry more context than the last one would otherwise have its `@@`
  # dividers collapsed out of sight.
  self.diffEditor.udUpdateDiffOptions(js{
    hideUnchangedRegions: js{
      enabled: true,
      contextLineCount: diffContextLineCount(pair),
      minimumLineCount: DiffMinimumLineCount,
      revealLineCount: ContextExpandStep
    }
  })
  self.editor.udSetScrollTop(scrollTop)
  self.applyDecorations()
  # Monaco rebuilds its boundary widgets for the new document, so the
  # affordance, the accessible name and the menu have to be re-stamped onto
  # them.  The observer in `diff_expansion` catches this too; doing it here as
  # well makes the tab correct on the first paint rather than one frame later.
  refreshExpansionAffordances(self.diffEditor, editorHostId(self.id))
  # The overlay is keyed on model lines, which every re-publish renumbers —
  # context expansion inserts lines above the ones it revealed — so the flow
  # decorations and the invocation selectors move with the document rather than
  # being left pointing at whatever now occupies their old positions.  It is
  # keyed on the *modified* model: flow was recorded against the new revision.
  self.applyFlowDecorations(pair.modified)
  self.rebuildInvocationZones(pair.modified)

proc stageSelectedHunks(self: UnifiedDiffComponent) =
  ## VCS-Panel.md, "Hunk Operations": "Stage/unstage hunk".
  ##
  ## Refused for a review: "Commit operations: Disabled (read-only view)".  The
  ## button is not rendered there either — this is the second gate, because a
  ## repository must never be written to on the strength of a hidden button.
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil or not vm.mutatingHunkOpsEnabled():
    return
  let patch = vm.buildPatchFromSelectedHunks()
  if patch.len == 0:
    return
  applyPatchToIndex(cstring(patch), gitWorkingDirectory(self.data))
  # The staged hunks are no longer part of the working-tree diff, so the hunk
  # indices the selection is keyed on no longer name the same hunks, and the
  # cached working-tree text may no longer be what the diff describes.  Both
  # are dropped together.
  self.initialized = false
  self.ensureSourceCache().invalidate()
  vm.clearHunkSelection()
  self.syncIntoVM()
  self.refreshModel()

proc scheduleDeletedLineTokens*(self: UnifiedDiffComponent; attempt: int) =
  ## Repaint the deleted lines with their syntax tokens, once they have any
  ## (`review_diff_editor.scheduleReviewDeletedLineTokens`).
  ## The editor and model are read from `self` on every attempt, so a
  ## `resetEditor` + `initEditor` inside the retry window is followed: the
  ## getter below reads the two fields each time it is CALLED, and must never
  ## hand on a pair read here once. Exported so the renderer-dom suite
  ## (`tests/review_deleted_line_tokens_dom_test.nim`) drives this call site
  ## itself, not only the helper it calls.
  if self.diffEditor.isNil or self.originalModel.isNil:
    return
  scheduleReviewDeletedLineTokens(
    proc(): ReviewDiffEditorRefs = (self.diffEditor, self.originalModel),
    cstring(editorHostId(self.id)), attempt)

proc fitSectionHost(diffEditor: js; hostId: cstring; onFirstFit: proc())
  {.importjs: """(function(de, hostId, onFirstFit) {
    var host = document.getElementById(hostId);
    var ed = de.getModifiedEditor();
    var fitted = false;
    function fit() {
      if (!host) return;
      var h = Math.max(ed.getContentHeight(), 24);
      if (host.style.height !== h + 'px') {
        host.style.height = h + 'px';
        de.layout();
      }
      if (!fitted) { fitted = true; onFirstFit(); }
    }
    ed.onDidContentSizeChange(fit);
    fit();
  })(#, #, #)""".}
  ## Size a section's editor host to the editor's content, now and whenever
  ## the content grows or shrinks (an unchanged region expanded, a zone
  ## added), so the document scrolls as one page instead of each section
  ## scrolling inside a box.

proc applyDocumentScroll(self: UnifiedDiffComponent)

proc fitSectionEditor(self: UnifiedDiffComponent) =
  ## A section of a whole-commit document (VCS-Panel.md, "Whole-Commit
  ## Document") is one of a column of editors: no minimap of its own, no
  ## scrolling of its own — the wheel scrolls the document — and as tall as
  ## its content.
  self.diffEditor.udUpdateDiffOptions(JsObject(js{
    minimap: js{enabled: false},
    scrollBeyondLastLine: false,
    scrollbar: js{
      vertical: cstring"hidden",
      alwaysConsumeMouseWheel: false,
      handleMouseWheel: false
    }
  }))
  let document = self.sectionOf
  fitSectionHost(self.diffEditor, cstring(editorHostId(self.id)),
    proc() = document.applyDocumentScroll())

proc initEditor(self: UnifiedDiffComponent) =
  ## Create the Monaco instance once its host element exists.
  if self.editorInitialized:
    return
  let hostId = cstring(editorHostId(self.id))
  if document.getElementById(hostId).isNil:
    return
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return

  let pair = diffPairFor(vm)
  self.rebuildLineLabels(pair)
  # `monacoThemeName` registers the theme documents before naming one.  A
  # review's visible tab is this one, and nothing else in the window need ever
  # create a source editor, so this tab cannot rely on somebody else having
  # defined `codetracerDark` first — that dependency is what made the review
  # window come up under Monaco's built-in light theme.
  let theme = monacoThemeName(self.data.config.theme)
  let language = cstring(pair.language)

  self.diffEditor = udCreateDiffEditor(hostId, reviewDiffEditorOptions(
    theme, diffContextLineCount(pair), self.data.ui.fontSize,
    codeFontFamily(self.data.ui)))

  # Two real models, each with the language resolved from the reviewed file.
  self.originalModel = udCreateModel(
    cstring(documentText(pair.original)), language)
  self.modifiedModel = udCreateModel(
    cstring(documentText(pair.modified)), language)
  # BEFORE the models are handed over, not after: Monaco builds each deleted
  # line's view zone out of the original model's tokens at the moment the diff
  # first renders, and never rebuilds it when tokenization catches up later.
  self.originalModel.udForceTokenization(DiffTokenizeLineLimit)
  self.diffEditor.udSetDiffModel(self.originalModel, self.modifiedModel)

  self.editor = self.diffEditor.udDiffModifiedEditor()
  self.originalEditor = self.diffEditor.udDiffOriginalEditor()
  self.editorInitialized = true
  self.applyGutterOptions(pair)

  let component = self
  self.editor.udOnMouseDown(proc(e: js) =
    let line = udMouseLine(e)
    if line <= 0:
      return
    component.handleHunkClick(line, udMouseShift(e), udMouseCtrl(e)))

  # UD-2: the expansion gesture.  The drag and the click are Monaco's own —
  # see `ui/diff_expansion.nim` — and this adds the affordance, the accessible
  # name, the keyboard path and the context menu on top of them.
  installExpansionGestures(self.diffEditor, editorHostId(self.id))

  self.applyDecorations()
  # §7 step 3, "Omniscience/flow data from the trace overlays onto diff lines",
  # for a review; a no-op for a git-backed tab, which carries no flow.
  self.applyFlowDecorations(pair.modified)
  self.rebuildInvocationZones(pair.modified)

  if not self.sectionOf.isNil:
    self.fitSectionEditor()

  self.scheduleDeletedLineTokens(attempt = 0)

proc resetEditor(self: UnifiedDiffComponent) =
  ## Drop the Monaco instance of a tab whose container GoldenLayout re-created
  ## (a tab drag, a layout restore): the previous mount's DOM, and the editor
  ## attached to it, is gone.
  self.editorInitialized = false
  # A diff editor's two models are created explicitly and therefore
  # outlive it; disposing the editor without them leaks a model pair —
  # and with it a tokenizer's state — on every tab drag or layout
  # restore.  Order matters: the editor first, so nothing is holding the
  # models when they go.
  udDisposeDiffEditor(self.diffEditor)
  udDisposeModel(self.originalModel)
  udDisposeModel(self.modifiedModel)
  self.diffEditor = nil
  self.originalModel = nil
  self.modifiedModel = nil
  self.editor = nil
  self.originalEditor = nil
  self.decorationCollection = nil
  self.originalDecorationCollection = nil
  # The review overlay's two handles belong to the destroyed Monaco
  # instance as much as `decorationCollection` does: a stale collection
  # would be written to an editor that no longer exists, and a stale zone
  # id would make the next `rebuildInvocationZones` remove a zone from it.
  self.flowDecorationCollection = nil
  self.flowViewZoneIds = @[]
  # The value bands' content widgets belong to the destroyed editor too.
  # Dropped without `removeContentWidget`, deliberately: there is nothing
  # left to remove them FROM, and calling it on a disposed editor throws.
  self.flowValueWidgets = @[]
  self.flowValueZoneIds = @[]
  self.flowValueWidgetMax = 0

proc unifiedDiffComponentFor(host: isonim_dom_api.Element): UnifiedDiffComponent =
  ## The tab `host` (`unifiedDiffComponent-<id>`) belongs to, or nil — in the
  ## window tab whose container holds `host`.
  UnifiedDiffComponent(data.hostTabComponent(host, Content.UnifiedDiff,
    panelHostComponentId(host)))

proc isCurrent(self: UnifiedDiffComponent; host: isonim_dom_api.Element): bool =
  ## Whether `self` still shows in `host`: a tab still mapped to its
  ## container, or a section still part of its document.
  if self.sectionOf.isNil:
    unifiedDiffComponentFor(host) == self
  else:
    self in self.sectionOf.sections

proc hostIsConnected(host: isonim_dom_api.Element): bool
  {.importjs: "Boolean(#.isConnected)".}

proc requestFrame(f: proc()) {.importjs: "requestAnimationFrame(#)".}

const EditorAttachFrameLimit = 120
  ## About two seconds of frames: GoldenLayout attaches a container it has
  ## built within a frame or two, so a tab still detached after this is not
  ## going to be shown.

proc initEditorWhenAttached(self: UnifiedDiffComponent;
                            host: isonim_dom_api.Element; frame = 0) =
  ## Create the tab's Monaco instance once `host` is in the document.
  ##
  ## The panel host renders the tab into the container GoldenLayout has just
  ## built, which GoldenLayout may attach to the document a frame later, and
  ## Monaco (and this module's id-based lookups of its host) needs the
  ## element in the document. This waits for THAT element — it never looks
  ## for a container — and stops when the tab is closed or remounted.
  if self.isNil or self.editorInitialized:
    return
  if not self.isCurrent(host):
    return
  if host.hostIsConnected():
    self.initEditor()
    return
  if frame >= EditorAttachFrameLimit:
    cerror "unified diff: tab " & $self.id & " was never attached; " &
      "its editor is not created"
    return
  let component = self
  requestFrame(proc() =
    component.initEditorWhenAttached(host, frame + 1))

proc openFullFile(self: UnifiedDiffComponent; path: string) =
  ## The heading's file name was clicked: open the full file in the editor,
  ## as the VCS panel's Open File mode does (`vcs.dispatchOpenAction`) — the
  ## working tree's file, or, in a review opened from a dataset, the
  ## dataset's own copy under the reviewed repository's path.
  if path.len == 0:
    return
  if self.data.isReviewDatasetSession() or utils.isAbsolutePath(path):
    self.data.openTab(cstring(path), ViewSource)
  else:
    self.data.openTab(
      cstring($gitRepositoryRoot(self.data) & "/" & path), ViewSource)

proc tabCallbacks(self: UnifiedDiffComponent; vm: VCSVM): UnifiedDiffCallbacks =
  ## What a diff tab's (or section's) toolbar and heading do.
  let component = self
  UnifiedDiffCallbacks(
    onCopySelectedHunks: proc() = component.copySelectedHunks(),
    onStageSelectedHunks: proc() = component.stageSelectedHunks(),
    onClearSelectedHunks: proc() =
      vm.clearHunkSelection()
      component.applyDecorations(),
    onOpenFullFile: proc(path: string) = component.openFullFile(path),
  )

var documentRoots: JsAssoc[int, isonim_dom_api.Element] =
  JsAssoc[int, isonim_dom_api.Element]{}
  ## Each document tab's rendered document, by tab id: where a section that
  ## has grown re-applies the scroll. Every session tab repeats the same
  ## container ids, so the element is held rather than looked up.

var nextSectionId = -1
  ## Section ids count down from -1, so a section's VCSVM, source cache and
  ## editor host id (`unifiedDiffEditor--3`) never collide with a tab's,
  ## which GoldenLayout numbers upwards from 0.

proc sectionFor(self: UnifiedDiffComponent; index: int;
                path: string): UnifiedDiffComponent =
  ## The document's section for file `index` (`path`), made on first use and
  ## kept for the tab's lifetime, like the tab's own target.
  if index < self.sections.len and not self.sections[index].isNil and
      safeStr(self.sections[index].sectionPath) == path:
    return self.sections[index]
  let plan = diffSectionTarget(self.rawTarget(), path)
  let section = UnifiedDiffComponent(
    id: nextSectionId,
    data: self.data,
    config: self.config,
    content: Content.UnifiedDiff,
    diffTarget: cstring("diff:" & plan.target),
    sectionPath: cstring(plan.onlyPath),
    sectionOf: self)
  dec nextSectionId
  while self.sections.len <= index:
    self.sections.add(nil)
  self.sections[index] = section
  section

proc forgetSection(section: UnifiedDiffComponent) =
  ## Dispose a section's editor and drop what it owned.
  if section.isNil:
    return
  if section.editorInitialized:
    section.resetEditor()
  forgetUnifiedDiffTab(section.scopedKey())

proc forgetDocumentSections*(componentId: int) =
  ## A closed document tab disposes every section's editor and model
  ## (VCS-Panel.md, "Whole-Commit Document").
  let mapping = data.ui.componentMapping[Content.UnifiedDiff]
  if mapping.isNil or not mapping.hasKey(componentId):
    return
  let document = UnifiedDiffComponent(mapping[componentId])
  if document.isNil:
    return
  let sections = document.sections
  document.sections = @[]
  let key = document.scopedKey()
  if documentRoots.hasKey(key):
    discard jsDelete(documentRoots[key])
  for section in sections:
    section.forgetSection()

proc renderSectionInto(self: UnifiedDiffComponent; r: WebRenderer;
                       index: int; path: string;
                       host: isonim_dom_api.Element) =
  ## Fill one section of the document: that file's diff tab, whose editor is
  ## created as soon as the section is in the page.
  let section = self.sectionFor(index, path)
  let vm = section.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  if section.editorInitialized:
    section.resetEditor()
  section.syncIntoVM()
  let tab = renderUnifiedDiffTab[WebRenderer, isonim_dom_api.Element](
    r, vm, editorHostId(section.id), section.tabCallbacks(vm))
  isonim_dom_api.appendChild(isonim_dom_api.Node(host), isonim_dom_api.Node(tab))
  section.initEditorWhenAttached(host)

proc documentElement(self: UnifiedDiffComponent): isonim_dom_api.Element =
  ## The rendered document of this tab, or nil.
  let key = self.scopedKey()
  if documentRoots.hasKey(key): documentRoots[key] else: nil

proc applyDocumentScroll(self: UnifiedDiffComponent) =
  ## Re-apply the document's scroll request: a section that has just grown to
  ## its content moved every section below it.
  if self.isNil or not unifiedDiffVMInstances.hasKey(self.scopedKey()):
    return
  let request = unifiedDiffVMInstances[self.scopedKey()].documentScroll.val
  let host = self.documentElement()
  if host.isNil or request.path.len == 0:
    return
  scrollToSection(host, request.path)

proc requestDocumentScroll*(data: Data; target, path: string) =
  ## Bring `path` into view in the open diff tab for `target` (VCS-Panel.md,
  ## "Scrolling to a file"): what a click on a file under an expanded commit
  ## does after opening or focusing the commit's document. The request is
  ## kept on the tab's ViewModel, so a tab rendered after it still scrolls.
  let mapping = data.ui.componentMapping[Content.UnifiedDiff]
  if mapping.isNil:
    return
  for _, component in mapping:
    let tab = UnifiedDiffComponent(component)
    if not tab.isNil and tab.rawTarget() == target:
      let vm = tab.ensureUnifiedDiffVM()
      if not vm.isNil:
        vm.requestDocumentScroll(path)

# The panel host mounts each diff tab into the container GoldenLayout creates
# (`ui/panel_host`); the factory has created the tab's component by then.
setPanelRenderer(Content.UnifiedDiff,
  proc(r: WebRenderer; host: isonim_dom_api.Element;
       session: SessionViewModel): isonim_dom_api.Element =
    let component = unifiedDiffComponentFor(host)
    let vm = if component.isNil: nil else: component.ensureUnifiedDiffVM()
    if vm.isNil:
      return isonim_dom_api.createElement(isonim_dom_api.document, cstring"div")
    if component.editorInitialized:
      component.resetEditor()
    component.syncIntoVM()
    if vm.isDiffDocument():
      # Several files: one section per file, each its own diff editor.
      let document = component
      let root = renderUnifiedDiffDocument[WebRenderer, isonim_dom_api.Element](
        r, vm,
        proc(index: int; path: string; sectionHost: isonim_dom_api.Element) =
          document.renderSectionInto(r, index, path, sectionHost))
      documentRoots[component.scopedKey()] = root
      root
    else:
      renderUnifiedDiffTab[WebRenderer, isonim_dom_api.Element](
        r, vm, editorHostId(component.id), component.tabCallbacks(vm)))

# The editor host exists once the tab is rendered into its container. A
# document's sections create their editors themselves.
setPanelDecorator(Content.UnifiedDiff,
  proc(host: isonim_dom_api.Element; session: SessionViewModel) =
    let component = unifiedDiffComponentFor(host)
    if not component.isNil and component.sections.len == 0:
      component.initEditorWhenAttached(host))
