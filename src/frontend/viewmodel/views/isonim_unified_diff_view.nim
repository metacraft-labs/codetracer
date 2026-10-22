## IsoNim DOM view for a unified-diff editor tab.
##
## The tab itself is a Monaco editor: its model holds the assembled diff text
## and its decorations carry the added / removed / context classification
## (``viewmodel/viewmodels/diff_document.nim``).  This view is only the chrome
## around it — the hunk editor's toolbar, and the host element Monaco mounts
## into — so that the toolbar stays reactive and headlessly renderable while
## the diff body is a real editor.
##
##   "When the VCS panel's 'Unified Diff' mode is active, clicking a file in
##    the Changed Files list opens a special editor tab that shows the file's
##    diff: Uses the standard CodeTracer Monaco editor"
##   — GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Editor Integration)"
##
## The editor host is created once, outside the render effect, because a
## reactive rebuild calls ``clearChildren`` on the subtree it owns and that
## would destroy the element Monaco is attached to.  Only the toolbar host is
## rebuilt reactively.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The browser instantiation needs the WebRenderer procs in scope.
  import isonim/web/web_renderer

import ../viewmodels/vcs_vm
import ../viewmodels/diff_document

export signals, computation, components

const
  UnifiedDiffContainerClass* = "component-container unified-diff-container"
  UnifiedDiffEditorClass* = "unified-diff-editor"
  UnifiedDiffEmptyClass* = "empty-overlay unified-diff-empty"
    ## Shown instead of the editor when the diff has no files.  The message used
    ## to be the Monaco model's own text, which meant it rendered as a line of
    ## code — mono, left aligned, with a line number beside it.  As a DOM node it
    ## picks up the shared empty-state treatment (`components/empty_states.styl`)
    ## like every other panel's "nothing here" message.
  UnifiedDiffEmptyText* = "No changes to show."
  UnifiedDiffToolbarHostClass* = "unified-diff-toolbar-host"
  UnifiedDiffFileHeaderHostClass* = "unified-diff-file-header-host"
  UnifiedDiffFileHeaderClass* = "unified-diff-file-header"
  UnifiedDiffFileHeaderStatusClass* = "unified-diff-file-header-status"
  UnifiedDiffFileHeaderPathClass* = "unified-diff-file-header-path"
  UnifiedDiffFileHeaderStatsClass* = "unified-diff-file-header-stats"

type
  UnifiedDiffCallbacks* = object
    ## Host effects the toolbar dispatches.  All optional: with none of them
    ## registered the view still renders, which is what the MockRenderer tests
    ## rely on.
    onCopySelectedHunks*: proc()
    onStageSelectedHunks*: proc()
    onClearSelectedHunks*: proc()

proc hunkToolbarText*(count: int): string =
  $count & " hunk" & (if count == 1: "" else: "s") & " selected"

proc copyButtonText*(copied: bool): string =
  ## VCS-Panel.md, "Hunk Operations": "Copy — copy selected hunks to clipboard
  ## (as patch format)".  The transient "Copied!" is the only feedback the
  ## clipboard gives.
  if copied: "Copied!" else: "Copy as patch"

proc renderHunkToolbar[R, N](r: R; vm: VCSVM;
                             callbacks: UnifiedDiffCallbacks): N =
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild
  var actions: N
  let bar = ui(r):
    tdiv(class = "hunk-toolbar"):
      span(class = "hunk-toolbar-count"):
        text hunkToolbarText(vm.selectedHunkCount.val)
      tdiv(ref = actions, class = "hunk-toolbar-actions"):
        tdiv(class = "hunk-toolbar-button",
             onclick = proc() =
               if callbacks.onCopySelectedHunks != nil:
                 callbacks.onCopySelectedHunks()):
          text copyButtonText(vm.hunkCopyFeedback.val)
  # VCS-Panel.md, "DeepReview Mode": "Commit operations: Disabled (read-only
  # view)".  Staging is offered only where there is a working tree to stage
  # into; selection and copy-as-patch stay available in both modes.
  if vm.mutatingHunkOpsEnabled():
    let stage = ui(r):
      tdiv(class = "hunk-toolbar-button",
           onclick = proc() =
             if callbacks.onStageSelectedHunks != nil:
               callbacks.onStageSelectedHunks()):
        text "Stage hunks"
    r.appendChild(actions, stage)
  let clear = ui(r):
    tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
         onclick = proc() =
           if callbacks.onClearSelectedHunks != nil:
             callbacks.onClearSelectedHunks()):
      text "Clear"
  r.appendChild(actions, clear)
  bar

proc renderFileHeader[R, N](r: R; entry: DiffFileEntry): N =
  ## DeepReview-GUI.md §4.1: "A file header with path and diff metadata".
  ##
  ## It used to be line 1 of the Monaco model.  UD-2 made the model the file
  ## itself and turned Monaco's ``hideUnchangedRegions`` on, and line 1 is
  ## exactly what a collapsed run at the top of a file hides — so a header that
  ## stayed in the model would be visible only on files whose first change is
  ## near the top.  Here it is chrome the reader cannot scroll away from, which
  ## is what a file header should have been all along.
  ui(r):
    tdiv(class = UnifiedDiffFileHeaderClass):
      span(class = UnifiedDiffFileHeaderStatusClass):
        text entry.status
      span(class = UnifiedDiffFileHeaderPathClass):
        text entry.path
      span(class = UnifiedDiffFileHeaderStatsClass):
        text fileStatsText(entry.additions, entry.deletions)

proc renderUnifiedDiffTab*[R, N](r: R; vm: VCSVM;
                                  editorHostId = "unifiedDiffEditor-0";
                                  callbacks = UnifiedDiffCallbacks()): N =
  ## The tab's chrome and the element Monaco mounts into, for every renderer
  ## (Shared-DOM-Front-Ends D6). The browser host creates the editor after
  ## the tab is in the document (`ui/unified_diff`).
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild, setAttribute
  var toolbarHost: N
  var fileHeaderHost: N
  var editorHost: N
  var emptyHost: N

  let panel = ui(r):
    tdiv(class = UnifiedDiffContainerClass):
      tdiv(ref = fileHeaderHost, class = UnifiedDiffFileHeaderHostClass)
      tdiv(ref = toolbarHost, class = UnifiedDiffToolbarHostClass)
      tdiv(ref = editorHost, id = editorHostId, class = UnifiedDiffEditorClass)
      tdiv(ref = emptyHost, class = UnifiedDiffEmptyClass):
        text UnifiedDiffEmptyText

  createRenderEffect proc() =
    r.clearChildren(fileHeaderHost)
    # One row per file the document actually renders, in document order.  A
    # review's tab always names exactly one file (§4.1, "Each diff tab shows a
    # single file"); a git target can name several, and each keeps its own row.
    for entry in diffPairFor(vm).files:
      r.appendChild(fileHeaderHost, renderFileHeader[R, N](r, entry))

  createRenderEffect proc() =
    r.clearChildren(toolbarHost)
    if vm.hunkToolbarVisible.val and vm.selectedHunkCount.val > 0:
      r.appendChild(toolbarHost, renderHunkToolbar[R, N](r, vm, callbacks))

  # Swap the editor for the empty-state message when there is nothing to diff.
  # Toggled by class rather than by inserting/removing the node, because the
  # editor host next to it must survive untouched — Monaco is attached to it.
  createRenderEffect proc() =
    let isEmpty = vm.diffFiles.val.len == 0
    r.setAttribute(emptyHost, "class",
      if isEmpty: UnifiedDiffEmptyClass
      else: UnifiedDiffEmptyClass & " hidden")
    r.setAttribute(editorHost, "class",
      if isEmpty: UnifiedDiffEditorClass & " hidden"
      else: UnifiedDiffEditorClass)

  panel
