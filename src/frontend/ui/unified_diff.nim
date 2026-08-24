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
## - ``viewmodel/viewmodels/vcs_vm.nim`` — the hunk editor's selection model
##   and its patch builder, shared with the docked panel's state rather than
##   duplicated here.
## - this module — the data source (review dataset or git), the Monaco
##   instance, and the click-to-hunk dispatch.
##
## Data source, per VCS-Panel.md "Data Sources and Instantiation Modes": a
## review's diff comes from ``deepReviewData`` — "NOT from live git", because a
## review describes commits that need not exist in whatever repository the
## process happens to be started in — and live git serves everything else.

import
  ui_imports

import std/strformat
import isonim/core/signals
import git_cli
import flow_line_styles
import flow_loop_slider
import flow_value_dom
import ../lib/isonim_styles
import review_flow_adapter
import review_flow_selection
import ../viewmodel/viewmodels/vcs_vm
import ../viewmodel/viewmodels/diff_document
import ../viewmodel/viewmodels/context_expansion
import ../viewmodel/viewmodels/review_flow_overlay
import diff_expansion

when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_unified_diff_view import
    mountIsoNimUnifiedDiffTab, UnifiedDiffCallbacks

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
var isoNimUnifiedDiffMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

# ---------------------------------------------------------------------------
# Monaco FFI
# ---------------------------------------------------------------------------

proc udCreateDiffEditor(divId: cstring, options: JsObject): js
  {.importjs: "monaco.editor.createDiffEditor(document.getElementById(#), #)".}
  ## UD-1: the unified diff is Monaco's own diff editor in inline mode.
  ##
  ## The binding already existed (`lib/monaco_lib.nim`'s `createDiffEditor`,
  ## used by `ui/agent_activity.nim`); this is the same call reached the same
  ## way the rest of this module reaches Monaco, by element id rather than by
  ## the `MonacoEditorOptions` object, because the option set a diff editor
  ## takes (`renderSideBySide`, `hideUnchangedRegions`, `diffAlgorithm`,
  ## `experimental.useTrueInlineView`) is wider than that record describes.

proc udCreateModel(value: cstring, language: cstring): js
  {.importjs: "monaco.editor.createModel(#, #)".}
  ## A real model with a real language, which is the whole point of UD-1: a
  ## tokenizer runs over it.

proc udDisposeModel(model: js)
  {.importjs: "(function(m) { if (m) { m.dispose(); } })(#)".}

proc udSetDiffModel(editor: js, original: js, modified: js)
  {.importjs: "#.setModel({ original: #, modified: # })".}

proc udDiffModifiedEditor(editor: js): MonacoEditor
  {.importjs: "#.getModifiedEditor()".}

proc udDiffOriginalEditor(editor: js): MonacoEditor
  {.importjs: "#.getOriginalEditor()".}

proc udDisposeDiffEditor(editor: js)
  {.importjs: "(function(e) { if (e) { e.dispose(); } })(#)".}

proc udCreateDecorationsCollection(editor: MonacoEditor, decorations: js): js
  {.importjs: "#.createDecorationsCollection(#)".}

proc udCollectionSet(collection: js, decorations: js)
  {.importjs: "#.set(#)".}

proc udSetValue(editor: MonacoEditor, value: cstring)
  {.importjs: """
  (function(editor, value) {
    var model = editor.getModel();
    // `setValue` on an unchanged value still resets the undo stack and
    // re-runs the tokenizer over the whole document; on a diff editor it also
    // forces a full re-diff of both sides. Expansion re-publishes both models
    // on every click, and only one of them usually changes.
    if (model && model.getValue() !== value) { model.setValue(value); }
  })(#, #)"""}

proc udUpdateOptions(editor: MonacoEditor, options: JsObject)
  {.importjs: "#.updateOptions(#)".}

proc udUpdateDiffOptions(diffEditor: js, options: JsObject)
  {.importjs: "(function(e, o) { if (e) { e.updateOptions(o); } })(#, #)".}
  ## Options on the DIFF editor rather than on one of its two code editors —
  ## `hideUnchangedRegions` is the diff's, not a code editor's.

proc udOnMouseDown(editor: MonacoEditor, handler: proc(e: js))
  {.importjs: "#.onMouseDown(#)".}

proc udScrollTop(editor: MonacoEditor): int
  {.importjs: "#.getScrollTop()".}

proc udSetScrollTop(editor: MonacoEditor, top: int)
  {.importjs: "#.setScrollTop(#)".}

# Monaco's mouse event carries `target.position` only when the pointer is over
# content (it is absent over the scrollbar, the overview ruler and past the
# last line), so every read below is guarded on the JS side rather than
# through Nim's `isNil`, which does not describe `undefined`.
proc udMouseLine(e: js): int
  {.importjs: """(function(e) {
    return (e && e.target && e.target.position) ? e.target.position.lineNumber : 0;
  })(#)""".}
proc udMouseShift(e: js): bool
  {.importjs: "(function(e) { return !!(e && e.event && e.event.shiftKey); })(#)".}
proc udMouseCtrl(e: js): bool
  {.importjs: """(function(e) {
    return !!(e && e.event && (e.event.ctrlKey || e.event.metaKey));
  })(#)""".}

proc udAddViewZone(editor: MonacoEditor, zone: js): int {.importjs: """
  (function(editor, zone) {
    var id = null;
    editor.changeViewZones(function(accessor) { id = accessor.addZone(zone); });
    return id;
  })(#, #)""".}
  ## Monaco's view zones can only be mutated inside a `changeViewZones`
  ## transaction, which is why this is a wrapper rather than a direct call.
  ## Identical in shape to `ui/flow.nim`'s `addMonacoViewZone`, which is what
  ## renders the loop iteration slider — §7 asks for the same mechanism, so it
  ## is the same call.

proc udRemoveViewZone(editor: MonacoEditor, zoneId: int) {.importjs: """
  (function(editor, id) {
    editor.changeViewZones(function(accessor) { accessor.removeZone(id); });
  })(#, #)""".}

proc udLineNumberFn(labels: seq[cstring]): js
  {.importjs: """(function(labels) {
    return function(n) {
      return (n >= 1 && n <= labels.length) ? labels[n - 1] : '';
    };
  })(#)""".}
  ## Monaco's ``lineNumbers`` option accepts a callback returning the label for
  ## a model line.  That is how one gutter carries the two columns the DOM
  ## renderer drew side by side (``deepreview-unified-gutter-old`` / ``-new``);
  ## the labels themselves are built by ``diff_document.lineNumberLabels``.

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

proc ensureUnifiedDiffVM*(self: UnifiedDiffComponent): VCSVM =
  ## One ``VCSVM`` per diff tab.
  ##
  ## The tab reuses ``VCSVM`` rather than inventing a diff-tab ViewModel
  ## because the hunk editor's state — ``selectedHunks`` /
  ## ``hunkToolbarVisible`` / ``hunkCopyFeedback`` — already lives there, and
  ## DR-R4's constraint is one model, not a second one that happens to agree.
  if self.isNil:
    return nil
  if unifiedDiffVMInstances.hasKey(self.id):
    return unifiedDiffVMInstances[self.id]
  result = createVCSVM()
  unifiedDiffVMInstances[self.id] = result

proc ensureSourceCache(self: UnifiedDiffComponent): SourceTextCache =
  if self.isNil:
    return nil
  if unifiedDiffSourceCaches.hasKey(self.id):
    return unifiedDiffSourceCaches[self.id]
  result = newSourceTextCache()
  unifiedDiffSourceCaches[self.id] = result

proc forgetUnifiedDiffTab*(componentId: int) =
  ## Drop everything a closed diff tab owned.
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
  if isoNimUnifiedDiffMountedIds.hasKey(componentId):
    discard jsDelete(isoNimUnifiedDiffMountedIds[componentId])

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

proc loadFromGit(self: UnifiedDiffComponent) =
  ## Fill the tab by asking git for the target's diff.
  let cwd = gitWorkingDirectory(self.data)
  var args: seq[cstring] = @[]
  var sessionTitle = cstring"Working Tree Changes"
  let target = self.rawTarget()

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
      args = @[cstring"diff-tree", cstring"-p", cstring"--no-commit-id",
               cstring"--root", cstring(hash), cstring"--", cstring(filepath)]
      sessionTitle = cstring("Diff: " & filepath & " (" &
                             hash[0 ..< min(12, hash.len)] & ")")
    else:
      args = @[cstring"diff-tree", cstring"-p", cstring"--no-commit-id",
               cstring"--root", cstring(commitPart)]
      sessionTitle = cstring("Commit Diff: " &
                             commitPart[0 ..< min(12, commitPart.len)])
  else:
    args = @[cstring"diff", cstring"HEAD", cstring"--", cstring(target)]
    sessionTitle = cstring("Diff: " & target)

  let raw = gitExec(args, cwd)
  self.diffData = DeepReviewData(
    commitSha: cstring"HEAD",
    baseCommitSha: cstring"",
    collectionTimeMs: 0,
    recordingCount: 0,
    sessionTitle: sessionTitle,
    files: parseGitDiffHunks($raw))
  self.reviewBacked = false

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
  let target = self.rawTarget()
  if target.startsWith("commit:"):
    let commitPart = target[7 .. ^1]
    let colonIdx = commitPart.find(':')
    return if colonIdx >= 0: commitPart[0 ..< colonIdx] else: commitPart
  ""

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
    var hunks: seq[VCSHunkRow] = @[]
    for hunk in file.diff.hunks:
      var lines: seq[VCSDiffLineRow] = @[]
      for line in hunk.lines:
        lines.add(VCSDiffLineRow(
          lineType: safeStr(line.`type`),
          content: safeStr(line.content),
          oldLine: line.oldLine,
          newLine: line.newLine))
      hunks.add(VCSHunkRow(
        oldStart: hunk.oldStart,
        oldCount: hunk.oldCount,
        newStart: hunk.newStart,
        newCount: hunk.newCount,
        lines: lines))
    let path = safeStr(file.path)
    result.add(VCSDiffFileRow(
      fileIndex: fileIdx,
      status: safeStr(file.diff.status),
      path: path,
      additions: file.diff.linesAdded,
      deletions: file.diff.linesRemoved,
      hunks: hunks,
      sourceLines: self.sourceLinesFor(file, path)))

proc ensureLoaded(self: UnifiedDiffComponent) =
  if self.initialized:
    return
  self.initialized = true
  if not self.loadFromReview():
    self.loadFromGit()

# ---------------------------------------------------------------------------
# Monaco
# ---------------------------------------------------------------------------

proc editorHostId*(componentId: int): string =
  fmt"unifiedDiffEditor-{componentId}"

proc monacoDecorations(doc: DiffDocument;
                       selected: openArray[(int, int)]): seq[JsObject] =
  ## Turn the pure decorations into Monaco descriptors.  One per line, whole
  ## line, with the `+` / `-` marker in the line-decorations lane.
  result = @[]
  for decoration in decorationsFor(doc, selected):
    result.add(js{
      range: js{
        startLineNumber: decoration.line,
        startColumn: 1,
        endLineNumber: decoration.line,
        endColumn: 1
      },
      options: js{
        isWholeLine: true,
        className: cstring(decoration.className),
        linesDecorationsClassName: cstring(decoration.gutterClassName),
        # Colours the `+` / `-` the gutter LABEL carries since UD-1.
        lineNumberClassName: cstring(decoration.lineNumberClassName)
      }
    })

proc rebuildLineLabels(self: UnifiedDiffComponent; pair: DiffPair) =
  ## Recompute the dual old/new gutter labels for both models.
  ##
  ## Monaco's ``lineNumbers`` callback closes over these sequences, so they
  ## must be refilled — not replaced — whenever a model's content changes, or
  ## the gutter keeps describing the previous document.
  # The NUMBER column's width; `lineNumberColumnWidth` adds the marker's
  # character on top of it for the option Monaco is given.
  let width = max(lineNumberWidth(pair.original), lineNumberWidth(pair.modified))
  self.lineLabels.setLen(0)
  for label in lineNumberLabels(pair.modified, dsModified, width):
    self.lineLabels.add(cstring(label))
  self.originalLineLabels.setLen(0)
  for label in lineNumberLabels(pair.original, dsOriginal, width):
    self.originalLineLabels.add(cstring(label))

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

proc reviewInvocationZonesFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewInvocationZone] =
  let (file, fileIndex) = self.reviewFlowFile()
  if file.isNil:
    return @[]
  let path = safeStr(file.path)
  var ordinals: seq[(string, int)] = @[]
  let functions = reviewFunctionInvocations(file)
  for fn in functions:
    ordinals.add((fn.functionKey, reviewInvocationOrdinal(path, fn.functionKey)))
  reviewInvocationZones(doc, fileIndex, functions, ordinals)

proc reviewLoopIterationsFor(self: UnifiedDiffComponent;
                             plan: ReviewFlowPlan): seq[(int, int)] =
  ## The reader's chosen pass through every loop of `plan`, as
  ## `review_flow_overlay` wants it.
  ##
  ## Read for every loop the plan carries rather than only the ones with a
  ## control, so a loop that ran once (no control) still resolves to iteration
  ## 0 by the same path as one that ran six times.
  result = @[]
  for loopIndex in 1 ..< plan.loops.len:
    result.add((loopIndex,
                reviewLoopIteration(plan.path, plan.functionKey, loopIndex)))

proc reviewDisplayedPlans(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewFlowPlan] =
  ## The invocation each on-screen function is currently showing.
  ##
  ## One invocation *per function*, chosen by the invocation zones, so the
  ## annotations a reader sees always describe the calls the controls above them
  ## name.
  result = @[]
  let (file, _) = self.reviewFlowFile()
  if file.isNil:
    return
  for zone in self.reviewInvocationZonesFor(doc):
    if zone.invocationIndex == NoInvocation:
      continue
    let plan = reviewFlowPlan(file, zone.invocationIndex)
    if plan.found:
      result.add(plan)

proc reviewFlowDecorationsFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewFlowDecoration] =
  ## Every displayed invocation's per-line flow, mapped onto this document.
  result = @[]
  let (file, fileIndex) = self.reviewFlowFile()
  if fileIndex < 0:
    return
  for plan in self.reviewDisplayedPlans(doc):
    var update = FlowUpdate()
    # The overload that takes the file: it fills the structured values the
    # materialized collector now writes (UD-3) on top of everything the plan
    # decides, so a review's `FlowStep.beforeValues` hold the recorder's own
    # `Value`s wherever the dataset has them.
    fillFlowUpdate(file, plan, update, ViewSource)
    result.add(reviewFlowDecorations(
      doc, fileIndex,
      flowStyledLines(update.viewUpdates[ViewSource], update.finished)))

proc reviewValueAnnotationsFor(self: UnifiedDiffComponent; doc: DiffDocument;
                               maxColumns: int = 1):
    seq[ReviewValueAnnotation] =
  ## Every displayed invocation's inline values (§4.4), mapped onto this
  ## document — the values the *selected* call recorded, and (UD-3) a column
  ## per recorded pass through any loop containing the line, starting at the
  ## pass the loop control names.
  result = @[]
  let (_, fileIndex) = self.reviewFlowFile()
  if fileIndex < 0:
    return
  for plan in self.reviewDisplayedPlans(doc):
    result.add(reviewValueAnnotations(
      doc, fileIndex, plan, self.reviewLoopIterationsFor(plan), maxColumns))

proc reviewLoopZonesFor(self: UnifiedDiffComponent; doc: DiffDocument):
    seq[ReviewLoopZone] =
  result = @[]
  let (_, fileIndex) = self.reviewFlowFile()
  if fileIndex < 0:
    return
  for plan in self.reviewDisplayedPlans(doc):
    result.add(reviewLoopZones(
      doc, fileIndex, plan, self.reviewLoopIterationsFor(plan)))

proc monacoFlowDecorations(decorations: seq[ReviewFlowDecoration]):
    seq[JsObject] =
  ## The standard Omniscience appearance: an *inline* class over the line's
  ## text, exactly as `editor.nim`'s `toDeltaDecorations` applies
  ## `MonacoLineStyle.inlineClass`.
  result = @[]
  for decoration in decorations:
    result.add(js{
      range: js{
        startLineNumber: decoration.modelLine,
        startColumn: 1,
        endLineNumber: decoration.modelLine,
        endColumn: 100000
      },
      options: js{
        isWholeLine: false,
        inlineClassName: cstring(decoration.inlineClassName)
      }
    })

# ---------------------------------------------------------------------------
# The parallel value band (UD-3)
# ---------------------------------------------------------------------------
#
#   "Keep the standard CodeTracer Omniscience appearance, produced by the same
#    code path as normal debugging […] Inline variable values MUST NOT be
#    rendered as text comments."  — DeepReview-GUI.md §4.4
#
# RV-5 met the "not a comment" half with Monaco *injected text* carrying the
# debugger's class names. UD-3 replaces it, because injected text cannot be the
# debugger's surface in the two ways that matter:
#
#   * it starts where the code line happens to END, so the values are a ragged
#     trailing strip rather than the aligned columns the flow view draws — and
#     a strip that starts further right is a strip that is cut off sooner,
#     which is the clipping every UD-1 and UD-2 reviewer reported;
#   * it is a flat run of spans, so a loop's several passes cannot be laid out
#     side by side at all. RV-5 therefore showed ONE pass and made the loop
#     control the only way to see the others.
#
# What replaces it is the debugger's own arrangement: one Monaco **content
# widget** per annotated line, holding the `.flow-parallel` row that
# `ui/flow.renderFlow` builds out of `ui/flow_value_dom.nim` — the same module,
# the same elements — anchored at ONE `left` offset for every line, past the
# longest line of the document, with one `.flow-parallel-values` column per
# recorded pass.

proc udAddContentWidget(editor: MonacoEditor, widget: js)
  {.importjs: "#.addContentWidget(#)".}

proc udRemoveContentWidget(editor: MonacoEditor, widget: js)
  {.importjs: "#.removeContentWidget(#)".}

proc udContentWidget(id: cstring, dom: Node, line: int): js {.importjs: """
  (function(id, dom, line) {
    return {
      getId: function() { return id; },
      getDomNode: function() { return dom; },
      getPosition: function() {
        // `0` is `ContentWidgetPositionPreference.EXACT`.
        return { position: { lineNumber: line, column: 1 }, preference: [0] };
      }
    };
  })(#, #, #)""".}
  ## A Monaco content widget, built in JS rather than as a Nim `js{}` literal
  ## of closures.
  ##
  ## This is not stylistic. A `js{ getId: (proc: cstring = widgetId) }` inside a
  ## LOOP closes over a variable Nim's JS backend hoists to the enclosing
  ## function, so every widget of the pass reports the LAST id. Monaco keys
  ## `_contentWidgets` by `getId()`, so adding N of them overwrote one map entry
  ## N times while appending N nodes — and `removeContentWidget` then removed
  ## exactly one of them. Measured: after stepping the invocation selector once,
  ## 9 bands on screen became 16, the previous call's values still beside the
  ## new call's. The JS-level factory gives each widget its own closure.

proc udContentWidth(editor: MonacoEditor): int {.importjs: """
  (function(e) {
    var info = e.getLayoutInfo ? e.getLayoutInfo() : null;
    return info ? (info.contentWidth | 0) : 0;
  })(#)""".}
  ## The editor's content area in pixels, minimap and rulers excluded. Read
  ## through `getLayoutInfo()` rather than the cached `config.layoutInfo` that
  ## `FlowComponent` uses, because a diff tab has no `EditorViewComponent` to
  ## refresh that cache on resize.

proc udMaxLineOffset(editor: MonacoEditor, lines: seq[int]): int {.importjs: """
  (function(e, lines) {
    var model = e.getModel();
    if (!model || !lines || lines.length === 0) { return 0; }
    var count = model.getLineCount();
    var best = 0;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line < 1 || line > count) { continue; }
      // Monaco's own measurement, so it is right for tabs, for a changed font
      // size and for a proportional font — all three of which a
      // `column * charWidth` estimate gets wrong.
      var offset = e.getOffsetForColumn(line, model.getLineMaxColumn(line));
      if (offset > best) { best = offset; }
    }
    return best | 0;
  })(#, #)""".}
  ## The pixel offset of the end of the widest of `lines`.
  ##
  ## This is `FlowComponent.maxFlowLineWidth`: `recalculateMaxFlowLineWidth`
  ## computes exactly this maximum, and over exactly this set — the lines that
  ## carry flow (`for position, _ in flow.positionStepCounts`), not every line
  ## of the file. Restated here rather than reused because that proc is a
  ## method on a component a review has none of (RV-5 judgement call 3); the
  ## arithmetic, which is the part that decides where the values appear, is
  ## identical.

proc udCharWidth(editor: MonacoEditor): float {.importjs: """
  (function(e) {
    var model = e.getModel();
    if (!model || model.getLineCount() < 1) { return 0; }
    // Column 11 rather than 2, so a single measurement is averaged over ten
    // characters and a sub-pixel advance does not round to zero.
    var column = model.getLineMaxColumn(1);
    if (column < 11) { return 0; }
    var offset = e.getOffsetForColumn(1, 11) - e.getOffsetForColumn(1, 1);
    return offset > 0 ? offset / 10 : 0;
  })(#)""".}
  ## The width of one character of the editor's font, or 0 when it cannot be
  ## measured yet.

proc reviewCharWidthPx(self: UnifiedDiffComponent): float =
  ## One character of the editor's font, in pixels.
  ##
  ## Measured off the editor when it can be — `getOffsetForColumn` on a real
  ## line is Monaco's own answer and is right for the font in force — and
  ## estimated from the configured size otherwise, which is only ever the case
  ## before the first layout.
  let fontSize =
    if self.data.isNil or self.data.ui.isNil: 14 else: self.data.ui.fontSize
  result = float(max(fontSize, 8)) * 0.62
  if self.editor.isNil:
    return
  let measured = self.editor.udCharWidth()
  if measured > 0.0:
    result = measured

proc reviewValueBandGeometry(self: UnifiedDiffComponent;
                             annotations: seq[ReviewValueAnnotation]):
    tuple[maxOffsetPx: float, charWidthPx: float, contentWidthPx: float] =
  ## The three measurements the band's placement is decided from.
  ##
  ## `maxOffsetPx` runs over the ANNOTATED lines only, which is
  ## `recalculateMaxFlowLineWidth`'s rule (`for position, _ in
  ## flow.positionStepCounts`) rather than "the widest line in the file" — a
  ## whole-file diff tab holds plenty of long lines that carry no values, and
  ## letting one of them push the band would move every value off screen for a
  ## reason a reader cannot see.
  ##
  ## The band's own offset is NOT computed here, because it depends on how wide
  ## the widest annotated line's column is as well as on where that line ends;
  ## `applyFlowValueBands` puts the two together through
  ## `reviewValueBandLeftPx`.
  let charWidth = self.reviewCharWidthPx()
  if self.editor.isNil:
    return (0.0, charWidth, 0.0)
  var lines: seq[int] = @[]
  for annotation in annotations:
    lines.add(annotation.modelLine)
  let contentWidth = float(self.editor.udContentWidth())
  let maxOffset = float(self.editor.udMaxLineOffset(lines))
  (maxOffset, charWidth, contentWidth)

proc reviewValueBandDom(self: UnifiedDiffComponent;
                        annotation: ReviewValueAnnotation;
                        leftPx, columnWidthPx, maxWidthPx: float;
                        visibleColumns, chipCharBudget: int;
                        morePassesMarker: bool): Node =
  ## One line's band, built out of the debugger's own elements.
  let isLoop = annotation.loop > 0
  # A wrapper, because the node handed to `addContentWidget` is Monaco's to
  # position: it writes `position: absolute` and its own `left`/`top` onto it
  # every frame. The band's own offset therefore lives one level in, exactly as
  # the debugger's does inside `makeFlowLineContainer`'s widget div.
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"review-flow-band-host")
  let band = flowValueBandDom(
    leftPx, isLoop, "review-flow-band", positioned = true,
    maxWidthPx = maxWidthPx)
  result.appendChild(band)
  let host =
    if isLoop:
      let loopValues = flowValueLoopValuesDom(annotation.loop)
      let group = flowValueGroupDom()
      loopValues.appendChild(group)
      band.appendChild(loopValues)
      group
    else:
      band
  # Trailing empty columns are dropped. An empty column between two filled
  # ones is information — "this pass did not reach the line" — and keeping the
  # passes of the loop's several lines in step depends on it. After the last
  # filled one there is nothing to keep in step, and what is left is a column
  # rule with nothing beside it, which a reviewer read as "an empty 5th slot".
  var lastFilled = -1
  for i in 0 ..< annotation.columns.len:
    if annotation.columns[i].values.len > 0:
      lastFilled = i
  var index = 0
  for column in annotation.columns:
    if index > lastFilled:
      break
    if index >= visibleColumns:
      # The passes past the pane's edge are not drawn at all rather than drawn
      # and clipped: a column sheared in half is what every UD-1 and UD-2
      # reviewer reported, and the loop control is how the rest are reached.
      break
    let columnDom = flowValueColumnDom(
      cstring(fmt"review-flow-values-{self.id}-{annotation.modelLine}-{index}"),
      columnWidthPx)
    if column.selected:
      # The debugger marks the pass the reader is on with `active-flow-step`,
      # and `flow.styl` styles the value boxes inside it; the review's band
      # marks it the same way rather than inventing a highlight.
      columnDom.setAttribute(
        cstring"class",
        cstring($columnDom.getAttribute(cstring"class") &
                " flow-loop-step-container active-flow-step"))
    columnDom.setAttribute(cstring"data-iteration", cstring($column.iteration))
    if column.values.len == 0:
      # A pass that never reached this line. `renderFlow` draws exactly this
      # span in the same slot, and keeping the empty column is what stops the
      # next pass's values sliding under this pass's heading.
      columnDom.appendChild(flowValueEmptyDom(style(), cstring""))
    # A column wider than the pane drops whole chips from its end rather than
    # squeezing them — see `reviewChipsThatFit`. The marker says it happened.
    let fitting = reviewChipsThatFit(column.values, chipCharBudget)
    var drawn = 0
    for chip in column.values:
      if drawn >= fitting:
        # Marked, not silent: a column that quietly showed three of four
        # values would be indistinguishable from a step that recorded three.
        #
        # `…+N` and not a bare `…`, because the ellipsis said the wrong
        # thing; and not a bare `+N` either, because inside a DIFF a leading
        # `+` reads as "one added line" — two later reviewers said so
        # independently ("in a diff `+1` reads as 'one added line'", "its
        # meaning is inference from the brief, not obvious from the UI"). The
        # ellipsis says "truncated" and the count says how much.
        # Two fresh reviewers of the design corpus, independently, reported the
        # SAME defect from it — /"Rows 1 and 3 end in `…`; row 2, identical
        # content, does not. Unstable per-row width computation."/ and /"the
        # trailing dim `…` on lines 7 and 9 … while the visually identical
        # line-8 row has no `…` … reads as inconsistent/possibly broken."/
        # Measured, the computation was neither unstable nor per-row wrong:
        # lines 8 and 10 of `main.nr` recorded THREE values and line 9 recorded
        # two, so the first two hide one and the third hides none. The rows look
        # identical because what differs is exactly what is not drawn. A count
        # says so; a bare ellipsis leaves the reader to infer a bug, which is
        # what both of them did.
        let hidden = column.values.len - drawn
        let more = flowValueEmptyDom(style(), cstring("…+" & $hidden))
        more.setAttribute(
          cstring"class",
          cstring($more.getAttribute(cstring"class") & " review-flow-more"))
        more.setAttribute(
          cstring"title",
          cstring(fmt"{hidden} more value(s) than the pane can hold"))
        columnDom.appendChild(more)
        break
      drawn += 1
      let chipDom = flowValueContainerDom(style())
      let nameDom = flowValueNameDom(cstring(reviewValueChipName(chip)))
      nameDom.setAttribute(
        cstring"class",
        cstring(ReviewValueNameClass))
      chipDom.appendChild(nameDom)
      chipDom.appendChild(flowValueBoxDom(
        id = cstring(fmt"review-flow-value-{self.id}-{annotation.modelLine}-{index}-{chip.name}"),
        className = cstring(ReviewValueBoxClass),
        text = cstring(chip.text),
        iteration = column.iteration,
        style = style()))
      columnDom.appendChild(chipDom)
    host.appendChild(columnDom)
    index += 1
  # A band that shows fewer passes than the loop recorded says so.
  #
  # Without this the omission is invisible and reads as missing data: a fresh
  # reviewer, unprompted — "`let contribution = …` and `total = total +
  # contribution;` each show only one group with no `…` truncation marker, even
  # though they're nested inside the same `for i in 0..4` loop whose header row
  # directly above shows four groups — reads as missing 3 of 4 passes' data."
  # It is not missing data and it is not inconsistent: those lines' columns are
  # WIDER (`<contribution> 0` against `<i> 0`), so fewer of them fit. The
  # marker is what makes that legible instead of leaving the reader to infer a
  # bug.
  #
  # `morePassesMarker` is whether the room the columns left over holds it —
  # `reviewMorePassesMarkerFits`. It is drawn out of the slack and never out of
  # a column, so a marker saying data was not shown can never itself be the
  # reason data was not shown, and it can never be the thing drawn past the
  # pane's edge.
  let dropped = (lastFilled + 1) - index
  if dropped > 0 and morePassesMarker:
    let more = flowValueEmptyDom(style(), cstring("…+" & $dropped))
    more.setAttribute(
      cstring"class",
      cstring($more.getAttribute(cstring"class") & " review-flow-more-passes"))
    more.setAttribute(
      cstring"title",
      cstring(fmt"{dropped} more pass(es) than fit — the loop control reaches them"))
    host.appendChild(more)

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
  ## Draw the parallel value band for every annotated line of the document.
  ##
  ## Two placements, and which one is used is MEASURED rather than chosen:
  ##
  ##   * **Beside the code**, in a content widget at a common left offset —
  ##     `FlowParallel`, the placement `ui/flow.renderFlow` uses and the one
  ##     §4.4 describes. Used whenever the pane is wide enough to hold a whole
  ##     column past the widest annotated line.
  ##   * **On its own row under the line**, in a Monaco view zone — the
  ##     placement the debugger's `FlowMultiline` mode uses
  ##     (`ui/flow.createFlowViewZone`). Used when it is not.
  ##
  ## The second is not a review-specific invention and it is not a compromise
  ## on the elements: the same band, the same columns, the same chips, moved to
  ## the row below. It exists because the diff tab is ONE PANE of a layout — in
  ## the design corpus at 1920x1080 its content area measures about 580px, and
  ## the file's own annotated lines run to 59 characters — so "past the longest
  ## line" is off the right edge, and beside-the-code placement would put every
  ## value out of sight. That is the same measurement that produced the clipped
  ## chips every UD-1 and UD-2 reviewer reported; RV-5's trailing strip did not
  ## fit either, and drew itself sheared rather than admitting it.
  if not self.editorInitialized or self.editor.isNil:
    return
  self.clearFlowValueWidgets()
  # Every recorded pass is asked for; how many are DRAWN is decided per line
  # below, from the room that line's band has. A cap here would be a cap on
  # what the loop control can ever scroll to.
  let annotations = reviewValueAnnotationsFor(self, doc, high(int16).int)
  let geometry = self.reviewValueBandGeometry(annotations)
  # Both decisions — where the band starts, and whether it goes beside the code
  # at all — are taken against the width the WIDEST annotated line's column
  # actually needs.
  #
  # `reviewValueBandFitsBeside` used to be asked against a 12-character floor,
  # which is a width no band's content is ever measured against, so the beside
  # branch accepted panes it then overflowed. Measured on `sample-review.json`
  # at 1920x1080: 210px of room past a band placed at 309px, against a column
  # needing 240px — the column was drawn at its full 230px from x=618 to x=848
  # with the pane ending at 829, and the chips that missed the 21-character
  # budget were replaced by an ellipsis, so `<y> 20` left the screen.
  #
  # What gives now is the GAP first (`reviewValueBandLeftPx`'s three-argument
  # form) and the placement only after that, because the gap is whitespace and
  # the placement is not: a row-below band is a view zone and adds its own
  # height to the document.
  let widestColumnPx =
    float(reviewWidestColumnChars(annotations)) * geometry.charWidthPx
  let bandLeftPx = reviewValueBandLeftPx(
    geometry.maxOffsetPx, geometry.contentWidthPx, widestColumnPx)
  self.flowValueWidgetMax = int(bandLeftPx)
  let beside = reviewValueBandFitsBeside(
    geometry.contentWidthPx, bandLeftPx, widestColumnPx)
  for annotation in annotations:
    if annotation.modelLine <= 0 or annotation.modelLine > doc.lines.len:
      continue
    if annotation.columns.len == 0:
      continue
    # ONE offset for every band, in both placements.
    #
    # `beside` was decided against the WIDEST annotated line, so a band at the
    # common offset is past every line's text by construction, and a tab where
    # it would not be does not use that placement at all.
    #
    # The row-below placement started out indented to the statement above it,
    # on the reasoning that a flush row "decouples the value from the statement
    # it belongs to" — which one reviewer said in those words. Three fresh
    # reviewers of the result said the opposite and said it unanimously: the
    # varying start was "the most damaging thing here", "an inconsistent left
    # rail", "roughly four different x positions". A column a reader can scan
    # downwards is the deliverable; attribution is answered instead by the line
    # number the row carries, which is also what `ui/flow.createFlowViewZone`
    # puts at the left of the debugger's own zones.
    let lineLeft = if beside: bandLeftPx else: 0.0
    # The row-below placement spends the head of its band on the source line
    # number, so the columns have that much less room than the pane.
    let prefix =
      if beside: 0.0
      else: ReviewValueBandLinePrefixChars * geometry.charWidthPx
    let available = geometry.contentWidthPx - lineLeft - prefix
    # The column's width is decided in CHARACTERS and turned into pixels once,
    # so the box the column is drawn in and the budget its chips are measured
    # against are the same number rather than two roundings of it. That
    # identity is the fix for the second half of the defect: the budget used to
    # be `available / charWidth div visible`, which on a 210px band against a
    # 24-character column came to 21 — three characters short of the column's
    # own width, so the last chip of `<x> 10 <y> 20` was dropped and `<y> 20`
    # left the screen. It also made the budget depend on the OTHER columns'
    # widths, which is why two rows with identical content could truncate
    # differently ("rows 1 and 3 end in `…`; row 2, identical content, does
    # not").
    let drawnColumnChars = reviewDrawnColumnChars(
      reviewColumnWidthChars(annotation), available, geometry.charWidthPx)
    let columnWidth = float(drawnColumnChars) * geometry.charWidthPx
    let visible = reviewVisibleColumnCount(
      available, columnWidth, annotation.columns.len)
    # The "more passes than fit" marker is drawn out of the room the columns
    # leave over, never out of a column — see `reviewMorePassesMarkerFits`.
    let markerFits = reviewMorePassesMarkerFits(
      available, columnWidth, visible,
      float(ReviewValueMorePassesChars) * geometry.charWidthPx)
    let dom = self.reviewValueBandDom(
      annotation, lineLeft, columnWidth, available, visible, drawnColumnChars,
      markerFits)
    # The same id in both placements, on the DOM node as well as on the
    # widget: a test that asks "does the line that shows source line N carry a
    # band" needs to name one, and `getId` is not reachable from a selector.
    dom.setAttribute(
      cstring"id",
      cstring(fmt"review-flow-band-{self.id}-{annotation.modelLine}"))
    if beside:
      # Anchored at column 1 rather than at the end of the text: the band is
      # positioned by its own `left`, so anchoring it to the line's end would
      # add that line's width to a number that is meant to be the same for
      # every line — the ragged strip, reintroduced through the back door.
      let widget = udContentWidget(
        cstring(fmt"review-flow-band-{self.id}-{annotation.modelLine}"),
        dom, annotation.modelLine)
      self.editor.udAddContentWidget(widget)
      self.flowValueWidgets.add(widget)
    else:
      # The source line the row describes, drawn where the gutter's own numbers
      # are.  `ui/flow.createFlowViewZone` prefixes the debugger's zones with a
      # `.line-numbers` element for the same reason: a row under a line is only
      # unambiguous while no two annotated lines are adjacent, and in a review
      # they usually are.  Three reviewers found the ambiguity — "it fails at
      # line 9, line 47, and wherever two annotated lines sit adjacent".
      let number = document.createElement(cstring"div")
      # NOT the editor's own `line-numbers` class. Monaco and
      # `styles/index.styl` both style that selector for the gutter's own
      # absolutely positioned column, and borrowing it inside a flex row took
      # the band out of its zone. The look is restated in
      # `.review-flow-band-line` instead — which is a handful of declarations,
      # against a layout that silently breaks.
      number.setAttribute(cstring"class", cstring"review-flow-band-line")
      number.appendChild(document.createTextNode(
        cstring($annotation.sourceLine)))
      # Into the BAND, not into the host: the host has no layout of its own, so
      # a sibling of the band there is a block above it and the band is pushed
      # out of the zone's height onto the next code line. Measured on the
      # captured surface, that is exactly what happened — two reviewers of it
      # reported chips "drawn directly on top of the code glyphs at the same
      # baseline" and "two chip groups stacked in the same pixels".
      let bandNode = dom.firstChild
      bandNode.insertBefore(number, bandNode.firstChild)
      # Tall enough for the chip, which is not a line of text: a
      # `.ct-omni-value` carries `padding: 0.25em 0.5em` and its name half
      # another 3px below, so at a 13px font the pill is around 30px against a
      # ~20px line. A zone sized for the FONT let the pill spill onto the code
      # rows either side, which two reviewers reported in the same terms —
      # "pill tops clip the `{` of `for i in 0..4 {`", "pills overlap the lines
      # above and below by 2-4px".
      self.flowValueZoneIds.add(self.editor.udAddViewZone(js{
        afterLineNumber: annotation.modelLine,
        heightInPx: self.data.ui.fontSize + 22,
        domNode: dom
      }))

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
  var pending = false
  for zone in self.reviewLoopZonesFor(doc):
    let container = document.getElementById(cstring(
      fmt"review-loop-slider-{self.id}-{zone.functionKey}-{zone.loopIndex}"))
    if container.isNil:
      continue
    let element = cast[Node](container.querySelector(
      cstring("." & FlowLoopSliderClass)))
    if element.isNil:
      continue
    let functionKey = zone.functionKey
    let loopIndex = zone.loopIndex
    let component = self
    # `total - 1`: the range is over ITERATION INDICES, and the debugger's
    # `maxLoopIteration` is the same 0-based bound.
    if not ensureFlowLoopSlider(element, zone.total - 1, zone.iteration,
        proc(iteration: int) =
          component.setLoopIterationTo(functionKey, loopIndex, iteration)):
      if zone.total > 1:
        pending = true
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
  for zone in self.reviewInvocationZonesFor(doc):
    let dom = self.invocationZoneDom(zone)
    self.flowViewZoneIds.add(self.editor.udAddViewZone(js{
      afterLineNumber: zone.afterLineNumber,
      heightInPx: lineHeight,
      domNode: dom
    }))
  for zone in self.reviewLoopZonesFor(doc):
    let dom = self.loopZoneDom(zone)
    self.flowViewZoneIds.add(self.editor.udAddViewZone(js{
      afterLineNumber: zone.afterLineNumber,
      heightInPx: lineHeight,
      domNode: dom
    }))
  self.scheduleLoopSliders(doc, attempt = 0)

proc syncIntoVM*(self: UnifiedDiffComponent) =
  ## Push the tab's parsed diff into its ViewModel.  The hunk selection is left
  ## alone: it is the VM's own state and survives a re-sync.
  if self.isNil:
    return
  unifiedDiffComponentRefs[self.id] = self
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  self.ensureLoaded()
  # `deepReviewMode` gates only the *mutating* hunk operations
  # (`VCSVM.mutatingHunkOpsEnabled`); the diff itself renders identically
  # either way, which is the rule VCS-Panel.md states under "Unified Diff View
  # (Shared)".
  vm.setDeepReviewMode(self.reviewBacked)
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
  ## Give each side of the diff editor its own dual old/new gutter.
  ##
  ## Per side rather than once on the diff editor, because a diff editor's
  ## options are handed to both of its code editors and the two models are
  ## renumbered independently: one callback would label the deleted lines with
  ## the *modified* model's numbers, which is how a removed line ends up
  ## claiming the line number of whatever now stands in its place.
  ##
  ## The width is shared (``lineNumberColumnWidth``) so the two columns are the
  ## same size and read as one gutter rather than two.
  ##
  ## ``lineDecorationsWidth: 0`` on both, with the `+` / `-` marker carried
  ## inside the label instead (``diff_document.lineNumberLabels``).  Monaco
  ## sizes the *original* editor of an inline diff from its
  ## ``lineNumbersMinChars`` alone — measured: 3 characters produced a 29px
  ## strip around a 65px margin — so a decorations lane beside the numbers
  ## there is not clipped gracefully, it takes the numbers off screen with it,
  ## and a reviewer reported the deleted lines as unnumbered.  The lane is
  ## zeroed on the modified side too, so the two gutters are the same shape.
  let width = lineNumberColumnWidth(pair)
  # A few pixels above line 1.  UD-2's collapsed-region boundary is drawn by
  # Monaco with `transform: translateY(-10px)`, so a region that begins at the
  # file's first line has its upper drag handle *above* the editor's clipping
  # edge and is cut in half — measured, and reported by a design reviewer as
  # "a rule below but none above".  The padding is what gives that handle
  # somewhere to be.
  let padding = js{ top: 10, bottom: 0 }
  self.editor.udUpdateOptions(js{
    lineNumbers: udLineNumberFn(self.lineLabels),
    lineNumbersMinChars: width,
    lineDecorationsWidth: 0,
    padding: padding
  })
  if not self.originalEditor.isNil:
    self.originalEditor.udUpdateOptions(js{
      lineNumbers: udLineNumberFn(self.originalLineLabels),
      lineNumbersMinChars: width,
      lineDecorationsWidth: 0,
      padding: padding
    })

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

  self.diffEditor = udCreateDiffEditor(hostId, js{
    # UD-1: the unified view is Monaco's diff editor with the side-by-side
    # layout turned off.  Everything the old synthetic document could not do
    # follows from the editor now owning both revisions:
    #   * a tokenizer runs, because each model has a real language;
    #   * the intra-line marking is computed, because there is a before and an
    #     after to compare.
    renderSideBySide: false,
    # ... and stays off.  Monaco otherwise silently switches to the two-pane
    # layout whenever the tab is wider than `renderSideBySideInlineBreakpoint`,
    # which would make the view's identity depend on the window size.
    useInlineViewWhenSpaceIsLimited: false,
    # VCS-Panel.md requires `+` / `-` gutter markers, and there must be
    # exactly one set of them.  Ours are in the gutter LABEL since UD-1
    # (`diff_document.lineNumberLabels` emits `+42` / `-41` / ` 40`, coloured
    # by the `lineNumberClassName` decoration), because the line-decorations
    # lane they used to live in does not fit in the inline diff's original
    # editor — see `applyGutterOptions`.  Monaco's own indicators are
    # therefore turned off rather than stacked on top of them, which is what
    # put a codicon and a `+` in the same 12 pixels.
    renderIndicators: false,
    # Neither side is writable: DeepReview-GUI.md §5.1, "Keep the review
    # representation read-only by default", and a diff buffer has nowhere to
    # write back to.  `originalEditable` defaults to false; it is stated
    # because the *modified* side is the one `readOnly` covers.
    readOnly: true,
    originalEditable: false,
    domReadOnly: true,
    # The gutter's revert arrows and its context menu are write gestures.
    renderMarginRevertIcon: false,
    renderGutterMenu: false,
    # `advanced` is Monaco's current diffing algorithm and the one that
    # produces the word-level marking this milestone is about; `legacy` is
    # kept only for compatibility.
    diffAlgorithm: cstring"advanced",
    # Whitespace-only changes are changes in a code review.
    ignoreTrimWhitespace: false,
    # UD-2: the models are the whole file, and this is what decides which of
    # its lines are on screen.  It is the tab's ONLY notion of that window —
    # DR-R5's per-hunk slice was removed rather than kept beside it.
    #
    #   * `contextLineCount` is computed per document rather than fixed at
    #     three, because the `@@` divider is an unchanged line and three would
    #     collapse it out of sight behind the hunk's own context lines
    #     (`diff_document.diffContextLineCount` explains the arithmetic).
    #   * `revealLineCount` is `ContextExpandStep`, the same amount §4.2's
    #     button used to reveal, so a click, a drag-less press, a keypress and
    #     the menu's first item all move by one increment.
    hideUnchangedRegions: js{
      enabled: true,
      contextLineCount: diffContextLineCount(pair),
      minimumLineCount: DiffMinimumLineCount,
      revealLineCount: ContextExpandStep
    },
    theme: theme,
    automaticLayout: true,
    folding: false,
    fontSize: self.data.ui.fontSize,
    # The affordances a DOM diff could not offer, and the reason DR-R4 exists.
    minimap: js{ enabled: true },
    contextmenu: true,
    renderLineHighlight: cstring"none",
    scrollBeyondLastLine: false,
    glyphMargin: false
  })

  # Two real models, each with the language resolved from the reviewed file.
  self.originalModel = udCreateModel(
    cstring(documentText(pair.original)), language)
  self.modifiedModel = udCreateModel(
    cstring(documentText(pair.modified)), language)
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

proc tryMountUnifiedDiffTab*(componentId: int) =
  when defined(js):
    if not unifiedDiffComponentRefs.hasKey(componentId):
      return
    let component = unifiedDiffComponentRefs[componentId]
    if component.isNil:
      return
    let vm = component.ensureUnifiedDiffVM()
    if vm.isNil:
      return
    let container = document.getElementById(
      cstring(fmt"unifiedDiffComponent-{componentId}"))
    if container.isNil:
      return

    if isoNimUnifiedDiffMountedIds.hasKey(componentId) and
       isoNimUnifiedDiffMountedIds[componentId] and
       container.childNodes.len == 0:
      # GoldenLayout re-created the host element (a tab drag, a layout
      # restore), so the previous mount's DOM — and with it the Monaco
      # instance — is gone.  Without this the tab would come back permanently
      # blank, because the mounted flag alone said the work was already done.
      isoNimUnifiedDiffMountedIds[componentId] = false
      component.editorInitialized = false
      # A diff editor's two models are created explicitly and therefore
      # outlive it; disposing the editor without them leaks a model pair —
      # and with it a tokenizer's state — on every tab drag or layout
      # restore.  Order matters: the editor first, so nothing is holding the
      # models when they go.
      udDisposeDiffEditor(component.diffEditor)
      udDisposeModel(component.originalModel)
      udDisposeModel(component.modifiedModel)
      component.diffEditor = nil
      component.originalModel = nil
      component.modifiedModel = nil
      component.editor = nil
      component.originalEditor = nil
      component.decorationCollection = nil
      component.originalDecorationCollection = nil
      # The review overlay's two handles belong to the destroyed Monaco
      # instance as much as `decorationCollection` does: a stale collection
      # would be written to an editor that no longer exists, and a stale zone
      # id would make the next `rebuildInvocationZones` remove a zone from it.
      component.flowDecorationCollection = nil
      component.flowViewZoneIds = @[]
      # The value bands' content widgets belong to the destroyed editor too.
      # Dropped without `removeContentWidget`, deliberately: there is nothing
      # left to remove them FROM, and calling it on a disposed editor throws.
      component.flowValueWidgets = @[]
      component.flowValueZoneIds = @[]
      component.flowValueWidgetMax = 0

    if not (isoNimUnifiedDiffMountedIds.hasKey(componentId) and
            isoNimUnifiedDiffMountedIds[componentId]):
      component.syncIntoVM()
      let callbacks = UnifiedDiffCallbacks(
        onCopySelectedHunks: proc() = component.copySelectedHunks(),
        onStageSelectedHunks: proc() = component.stageSelectedHunks(),
        onClearSelectedHunks: proc() =
          vm.clearHunkSelection()
          component.applyDecorations(),
      )
      mountIsoNimUnifiedDiffTab(
        cast[isonim_dom_api.Element](container), vm,
        editorHostId(componentId), callbacks)
      isoNimUnifiedDiffMountedIds[componentId] = true

    # The editor host only exists once the view above has mounted, and the
    # GoldenLayout container can be re-created (a tab drag, a layout restore)
    # after that, so this runs on every mount attempt rather than once.
    if not component.editorInitialized:
      component.initEditor()
  else:
    discard
