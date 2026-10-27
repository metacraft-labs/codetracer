## views/isonim_editor_view.nim
##
## IsoNim DOM-rendering view for the Editor panel — primary renderer.
##
## Creates the container `div` that Monaco attaches to. The Editor is
## unique among CodeTracer panels because multiple instances exist
## (one per open file tab). Each instance gets its own IsoNim-managed
## container with the same id, class, and data attributes that the
## legacy Karax `editorView()` produced.
##
## The DOM structure is intentionally minimal — just the outer
## container div — because Monaco Editor manages its own internal DOM.
## The IsoNim view's job is to create and maintain the container so
## that `createMonacoEditor(selector, options)` can find it and attach
## the editor instance.
##
## One generic proc renders the container under every renderer.

import isonim/dsl/ui
import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic procs expand the DSL at their caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/[editor_test_controls_vm, editor_vm]
import ./isonim_editor_test_controls_view

# ---------------------------------------------------------------------------
# Class composition
# ---------------------------------------------------------------------------

proc editorClass*(isExpansion: bool; expansionDepth: int): string =
  ## Static class string for the editor container. Includes the
  ## optional `expansion expansion-{depth}` suffix when this editor
  ## instance is hosted as an expansion view inside another editor.
  result = "editor code-editor tab"
  if isExpansion:
    result.add " expansion expansion-"
    result.add $expansionDepth

proc editorHostId*(index: int; hostId: string = ""): string =
  ## DOM id for the editor container. Top-level editors keep the legacy
  ## ``editorComponent-{index}`` id, while Monaco expansion view zones reuse
  ## their ``expanded-{line}`` host id because Monaco attaches to that node.
  if hostId.len > 0:
    hostId
  else:
    "editorComponent-" & $index

# ---------------------------------------------------------------------------
# Container builder
# ---------------------------------------------------------------------------
#
# Produces the same DOM structure as the legacy Karax `editorView()`:
#
#   div#editorComponent-{index}.editor.code-editor.tab[.expansion]
#     [Monaco creates its own children here]
#
# The `data-label` attribute is set to `path` so that GoldenLayout tab
# rendering and Playwright tests can locate the editor.

proc renderEditorContainer*[R, N](r: R; vm: EditorVM;
                                  index: int; path: string;
                                  isExpansion: bool; expansionDepth: int;
                                  hostId: string = "";
                                  testControls = EditorTestControlRenderPlan(
                                    placement: etcpDisabled)): N =
  ## The editor's container, for every renderer. The execution cursor kind
  ## and the source revision follow the ViewModel; `testControls` is a value
  ## drawn once.
  # A plain name for the child call: the `ui` macro passes a call through as
  # a child only when its callee is an identifier, and `f[R, N](...)` is not.
  template testControlsNode(): N = renderEditorTestControls[R, N](r, testControls)
  ui(r):
    tdiv(id = editorHostId(index, hostId),
         class = editorClass(isExpansion, expansionDepth),
         `data-label` = path,
         `data-execution-cursor-kind` = vm.executionCursorKind.val,
         `data-source-generation` = $vm.activeSourceGeneration.val,
         `data-source-digest` = vm.activeSourceDigest.val,
         tabindex = "2"):
      if testControls.placement != etcpDisabled and testControls.controls.len > 0:
        testControlsNode()

proc renderEditorPanel*[R, N](r: R; vm: EditorVM;
                              index: int; path: string;
                              isExpansion: bool; expansionDepth: int;
                              hostId: string = "";
                              testControls = EditorTestControlRenderPlan(
                                placement: etcpDisabled)): N =
  ## Public name retained for symmetry with the other panel views.
  renderEditorContainer[R, N](r, vm, index, path, isExpansion, expansionDepth,
                              hostId, testControls)

when defined(js):
  proc mountIsoNimEditor*(container: isonim_dom.Element;
                          vm: EditorVM;
                          index: int; path: string;
                          isExpansion: bool;
                          expansionDepth: int;
                          hostId: string = "";
                          testControls = EditorTestControlRenderPlan(
                            placement: etcpDisabled)): isonim_dom.Element =
    ## Mount the IsoNim editor container as a child of `container` and
    ## return the element so the caller can pass its selector to
    ## `createMonacoEditor`. Unlike the other panel mounts, this view
    ## returns the element reference because Monaco needs it for
    ## initialisation.
    let r = WebRenderer()
    let panel = renderEditorPanel[WebRenderer, isonim_dom.Element](
      r, vm, index, path, isExpansion, expansionDepth, hostId, testControls)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    panel
