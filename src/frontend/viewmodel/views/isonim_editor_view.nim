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
## The container shape is identical for both renderers, so the markup
## lives in a single `renderEditorContainerImpl` template that is
## materialised into one concrete proc per renderer (Mock / Web).

import isonim/dsl/ui
import isonim/core/computation  # createRenderEffect — emitted by the DSL
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/editor_vm

# ---------------------------------------------------------------------------
# Class composition
# ---------------------------------------------------------------------------

proc editorClass(isExpansion: bool; expansionDepth: int): string =
  ## Static class string for the editor container. Includes the
  ## optional `expansion expansion-{depth}` suffix when this editor
  ## instance is hosted as an expansion view inside another editor.
  result = "editor code-editor tab"
  if isExpansion:
    result.add " expansion expansion-"
    result.add $expansionDepth

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

template renderEditorContainerImpl(r, index, path,
                                    isExpansion, expansionDepth: untyped):
                                    untyped =
  ui(r):
    tdiv(id = "editorComponent-" & $index,
         class = editorClass(isExpansion, expansionDepth),
         `data-label` = path,
         tabindex = "2"):
      discard

# ---------------------------------------------------------------------------
# Renderer overloads
# ---------------------------------------------------------------------------

proc renderEditorContainer*(r: MockRenderer; vm: EditorVM;
                            index: int; path: string;
                            isExpansion: bool; expansionDepth: int): MockNode =
  ## Mock-renderer overload — used by headless tests.
  discard vm
  renderEditorContainerImpl(r, index, path, isExpansion, expansionDepth)

proc renderEditorPanel*(r: MockRenderer; vm: EditorVM;
                        index: int; path: string;
                        isExpansion: bool; expansionDepth: int): MockNode =
  ## Public name retained for symmetry with the other panel views.
  renderEditorContainer(r, vm, index, path, isExpansion, expansionDepth)

when defined(js):
  proc renderEditorContainer*(r: WebRenderer; vm: EditorVM;
                              index: int; path: string;
                              isExpansion: bool;
                              expansionDepth: int): isonim_dom.Element =
    discard vm
    renderEditorContainerImpl(r, index, path, isExpansion, expansionDepth)

  proc renderEditorPanel*(r: WebRenderer; vm: EditorVM;
                          index: int; path: string;
                          isExpansion: bool;
                          expansionDepth: int): isonim_dom.Element =
    renderEditorContainer(r, vm, index, path, isExpansion, expansionDepth)

  proc mountIsoNimEditor*(container: isonim_dom.Element;
                          vm: EditorVM;
                          index: int; path: string;
                          isExpansion: bool;
                          expansionDepth: int): isonim_dom.Element =
    ## Mount the IsoNim editor container as a child of `container` and
    ## return the element so the caller can pass its selector to
    ## `createMonacoEditor`. Unlike the other panel mounts, this view
    ## returns the element reference because Monaco needs it for
    ## initialisation.
    let r = WebRenderer()
    let panel = renderEditorPanel(r, vm, index, path, isExpansion, expansionDepth)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    panel
