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
## The IsoNim view's job is to create and maintain the container
## element so that `createMonacoEditor(selector, options)` can find it
## and attach the editor instance.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderEditorContainer(r, editorVM, 0, "/foo/bar.nim", false, 0)
##   check findByAttr(panel, "id", "editorComponent-0") != nil
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let container = renderEditorContainer(r, editorVM, 0, "/foo/bar.nim", false, 0)
##   # container is a dom_api.Element — append to a real DOM parent

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/editor_vm

# ---------------------------------------------------------------------------
# Container renderer
# ---------------------------------------------------------------------------

proc renderEditorContainer*[R, N](r: R;
                                   vm: EditorVM;
                                   index: int;
                                   path: string;
                                   isExpansion: bool;
                                   expansionDepth: int): N =
  ## Create the editor container div that Monaco attaches to.
  ##
  ## Produces the same DOM structure as the legacy Karax `editorView()`:
  ##   div#editorComponent-{index}.editor.code-editor.tab
  ##     [Monaco creates its own children here]
  ##
  ## The `data-label` attribute is set to `path` so that GoldenLayout
  ## tab rendering and Playwright tests can locate the editor.
  let expansionClass = if isExpansion: " expansion expansion-" & $expansionDepth else: ""
  let panel = r.createElement("div")
  r.setAttribute(panel, "id", "editorComponent-" & $index)
  r.setAttribute(panel, "class", "editor code-editor tab" & expansionClass)
  r.setAttribute(panel, "data-label", path)
  r.setAttribute(panel, "tabindex", "2")

  panel

# ---------------------------------------------------------------------------
# MockRenderer overload
# ---------------------------------------------------------------------------

proc renderEditorPanel*(r: MockRenderer;
                         vm: EditorVM;
                         index: int;
                         path: string;
                         isExpansion: bool;
                         expansionDepth: int): MockNode =
  ## Render the editor container for tests.
  renderEditorContainer[MockRenderer, MockNode](
    r, vm, index, path, isExpansion, expansionDepth)

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderEditorPanel*(r: WebRenderer;
                           vm: EditorVM;
                           index: int;
                           path: string;
                           isExpansion: bool;
                           expansionDepth: int): isonim_dom.Element =
    ## Render the editor container using real DOM elements.
    renderEditorContainer[WebRenderer, isonim_dom.Element](
      r, vm, index, path, isExpansion, expansionDepth)

  proc mountIsoNimEditor*(container: isonim_dom.Element;
                           vm: EditorVM;
                           index: int;
                           path: string;
                           isExpansion: bool;
                           expansionDepth: int): isonim_dom.Element =
    ## Mount the IsoNim editor container into a real DOM container.
    ##
    ## Creates the editor container div and appends it as a child of
    ## `container`. Returns the created element so the caller can pass
    ## its selector to `createMonacoEditor`.
    ##
    ## Unlike other panel mounts, this returns the element reference
    ## because the editor needs it for Monaco initialization.
    let r = WebRenderer()
    let panel = renderEditorPanel(r, vm, index, path, isExpansion, expansionDepth)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    panel
