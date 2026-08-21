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
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/vcs_vm

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

type
  UnifiedDiffCallbacks* = object
    ## Host effects the toolbar dispatches.  All optional: with none of them
    ## registered the view still renders, which is what the MockRenderer tests
    ## rely on.
    onCopySelectedHunks*: proc()
    onStageSelectedHunks*: proc()
    onClearSelectedHunks*: proc()

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  r.appendChild(host, child)

when defined(js):
  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    r.appendChild(host, child)

proc hunkToolbarText*(count: int): string =
  $count & " hunk" & (if count == 1: "" else: "s") & " selected"

proc copyButtonText*(copied: bool): string =
  ## VCS-Panel.md, "Hunk Operations": "Copy — copy selected hunks to clipboard
  ## (as patch format)".  The transient "Copied!" is the only feedback the
  ## clipboard gives.
  if copied: "Copied!" else: "Copy as patch"

proc renderHunkToolbar[R](r: R; vm: VCSVM;
                          callbacks: UnifiedDiffCallbacks): auto =
  var actions: typeof(r.createElement("div"))
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
    r.appendRenderedChild(actions, stage)
  let clear = ui(r):
    tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
         onclick = proc() =
           if callbacks.onClearSelectedHunks != nil:
             callbacks.onClearSelectedHunks()):
      text "Clear"
  r.appendRenderedChild(actions, clear)
  bar

proc renderUnifiedDiffTabImpl[R](r: R; vm: VCSVM; editorHostId: string;
                                 callbacks: UnifiedDiffCallbacks): auto =
  var toolbarHost: typeof(r.createElement("div"))
  var editorHost: typeof(r.createElement("div"))
  var emptyHost: typeof(r.createElement("div"))

  let panel = ui(r):
    tdiv(class = UnifiedDiffContainerClass):
      tdiv(ref = toolbarHost, class = UnifiedDiffToolbarHostClass)
      tdiv(ref = editorHost, id = editorHostId, class = UnifiedDiffEditorClass)
      tdiv(ref = emptyHost, class = UnifiedDiffEmptyClass):
        text UnifiedDiffEmptyText

  createRenderEffect proc() =
    r.clearChildren(toolbarHost)
    if vm.hunkToolbarVisible.val and vm.selectedHunkCount.val > 0:
      r.appendRenderedChild(toolbarHost, renderHunkToolbar(r, vm, callbacks))

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

proc renderUnifiedDiffTab*(r: MockRenderer; vm: VCSVM;
                           editorHostId = "unifiedDiffEditor-0";
                           callbacks = UnifiedDiffCallbacks()): MockNode =
  renderUnifiedDiffTabImpl(r, vm, editorHostId, callbacks)

when defined(js):
  proc renderUnifiedDiffTab*(r: WebRenderer; vm: VCSVM;
                             editorHostId: string;
                             callbacks = UnifiedDiffCallbacks()):
                             isonim_dom.Element =
    renderUnifiedDiffTabImpl(r, vm, editorHostId, callbacks)

  proc mountIsoNimUnifiedDiffTab*(container: isonim_dom.Element; vm: VCSVM;
                                  editorHostId: string;
                                  callbacks = UnifiedDiffCallbacks()) =
    let r = WebRenderer()
    let panel = renderUnifiedDiffTab(r, vm, editorHostId, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
