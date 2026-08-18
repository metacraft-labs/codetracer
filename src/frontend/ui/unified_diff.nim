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
## What lives where
## ----------------
## - ``viewmodel/viewmodels/diff_document.nim`` — pure: rows in, model text and
##   one decoration per line out.  It never sees a mode, which is
##   VCS-Panel.md's "the diff rendering code does NOT check which mode is
##   active" made structural.
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
import ../viewmodel/viewmodels/vcs_vm
import ../viewmodel/viewmodels/diff_document
import ../viewmodel/viewmodels/context_expansion

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

proc udCreateMonacoEditor(divId: cstring, options: JsObject): MonacoEditor
  {.importjs: "monaco.editor.create(document.getElementById(#), #)".}

proc udCreateDecorationsCollection(editor: MonacoEditor, decorations: js): js
  {.importjs: "#.createDecorationsCollection(#)".}

proc udCollectionSet(collection: js, decorations: js)
  {.importjs: "#.set(#)".}

proc udSetValue(editor: MonacoEditor, value: cstring)
  {.importjs: "#.getModel().setValue(#)".}

proc udUpdateOptions(editor: MonacoEditor, options: JsObject)
  {.importjs: "#.updateOptions(#)".}

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
  ## does not leak between files."  The ViewModel holds that state, so the
  ## reset IS dropping it — a re-opened tab gets a fresh `VCSVM` with no
  ## expansion, no hunk selection and an empty source cache, rather than
  ## inheriting the previous tab's revealed windows for hunk indices that may
  ## now name entirely different hunks.
  if unifiedDiffVMInstances.hasKey(componentId):
    let vm = unifiedDiffVMInstances[componentId]
    if not vm.isNil:
      vm.resetContextExpansion()
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
        linesDecorationsClassName: cstring(decoration.gutterClassName)
      }
    })

proc rebuildLineLabels(self: UnifiedDiffComponent; doc: DiffDocument) =
  ## Recompute the dual old/new gutter labels for the document.
  ##
  ## Monaco's ``lineNumbers`` callback closes over this sequence, so it must be
  ## refilled — not replaced — whenever the model's content changes, or the
  ## gutter keeps describing the previous document.
  self.lineLabels.setLen(0)
  for label in lineNumberLabels(doc, lineNumberWidth(doc)):
    self.lineLabels.add(cstring(label))

proc applyDecorations(self: UnifiedDiffComponent) =
  if not self.editorInitialized or self.editor.isNil:
    return
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffDocumentFor(vm)
  let decorations = monacoDecorations(doc, vm.selectedHunks.val)
  if self.decorationCollection.isNil:
    self.decorationCollection =
      self.editor.udCreateDecorationsCollection(decorations.toJs)
  else:
    self.decorationCollection.udCollectionSet(decorations.toJs)

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
  let doc = diffDocumentFor(vm)
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

proc refreshModel(self: UnifiedDiffComponent) =
  ## Re-publish the document into the live Monaco model.
  ##
  ## Content, gutter labels, gutter width and decorations move together: a
  ## model whose text changed under stale labels would number the wrong lines.
  if not self.editorInitialized or self.editor.isNil:
    return
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return
  let doc = diffDocumentFor(vm)
  # `setValue` scrolls the viewport back to the top, which would throw the
  # reader out of the region they just expanded.  Expansion is the operation
  # that made this matter: it re-publishes the model on every click.
  let scrollTop = self.editor.udScrollTop()
  self.editor.udSetValue(cstring(documentText(doc)))
  self.rebuildLineLabels(doc)
  self.editor.udUpdateOptions(js{
    lineNumbers: udLineNumberFn(self.lineLabels),
    lineNumbersMinChars: 2 * lineNumberWidth(doc) + 2
  })
  self.editor.udSetScrollTop(scrollTop)
  self.applyDecorations()

proc handleExpandClick(self: UnifiedDiffComponent; modelLine: int): bool =
  ## DeepReview-GUI.md §4.2: "Expand surrounding context above a visible
  ## region / Expand surrounding context below a visible region".
  ##
  ## Returns true when the line WAS an expand control, so the caller stops
  ## rather than also treating the click as a hunk-selection gesture.
  ##
  ## The counters live on the ViewModel, so a click is state plus a re-publish
  ## of the document: `diffDocumentFor` re-derives the whole window from
  ## `(diffFiles, hunkExpansion)` and the model grows by exactly the lines the
  ## new counters reveal.  Repeated clicks therefore load *further* content
  ## rather than re-revealing what is already shown — §4.2's third required
  ## control — because the counters accumulate.
  let vm = self.ensureUnifiedDiffVM()
  if vm.isNil:
    return false
  let doc = diffDocumentFor(vm)
  let target = expandTargetAtLine(doc, modelLine)
  if not target.present:
    return false
  if target.above:
    vm.expandContextAbove(target.fileIndex, target.hunkIndex)
  else:
    vm.expandContextBelow(target.fileIndex, target.hunkIndex)
  self.refreshModel()
  true

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
  # indices the selection and the expansion counters are keyed on no longer
  # name the same hunks, and the cached working-tree text may no longer be
  # what the diff describes.  All three are dropped together.
  self.initialized = false
  self.ensureSourceCache().invalidate()
  vm.clearHunkSelection()
  vm.resetContextExpansion()
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

  let doc = diffDocumentFor(vm)
  let content = cstring(documentText(doc))
  self.rebuildLineLabels(doc)
  let theme = if self.data.config.theme == cstring"default_white":
    cstring"codetracerWhite"
  else:
    cstring"codetracerDark"

  self.editor = udCreateMonacoEditor(hostId, js{
    value: content,
    # The document interleaves several revisions of the file with `@@`
    # dividers, so no language's tokenizer describes it; syntax colouring here
    # would fight the diff's own added/removed colouring.
    language: cstring"plaintext",
    # DeepReview-GUI.md §5.1, "Keep the review representation read-only by
    # default" — and an editable diff buffer has nowhere to write back to.
    readOnly: true,
    domReadOnly: true,
    theme: theme,
    automaticLayout: true,
    folding: false,
    fontSize: self.data.ui.fontSize,
    # The affordances a DOM diff could not offer, and the reason DR-R4 exists.
    minimap: js{ enabled: true },
    contextmenu: true,
    renderLineHighlight: cstring"none",
    lineNumbers: udLineNumberFn(self.lineLabels),
    lineNumbersMinChars: 2 * lineNumberWidth(doc) + 2,
    lineDecorationsWidth: monacoLineDecorationsWidth(self.data.ui.fontSize),
    scrollBeyondLastLine: false,
    glyphMargin: false
  })
  self.editorInitialized = true

  let component = self
  self.editor.udOnMouseDown(proc(e: js) =
    let line = udMouseLine(e)
    if line <= 0:
      return
    # The expand controls are checked first and swallow the click: a control
    # line is not a hunk header, so the two gestures cannot both fire, but
    # ordering them makes that explicit rather than incidental.
    if component.handleExpandClick(line):
      return
    component.handleHunkClick(line, udMouseShift(e), udMouseCtrl(e)))

  self.applyDecorations()

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
      component.editor = nil
      component.decorationCollection = nil

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
