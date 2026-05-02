## views/isonim_calltrace_editor_view.nim
##
## IsoNim DOM-rendering view for the Calltrace Editor placeholder panel.
##
## Renders the same empty ``<div class="component-container
## calltrace-editor">`` shell the legacy Karax ``method render`` in
## ``frontend/ui/calltrace_editor.nim`` produced.  The panel hosts no
## children today — historically it framed nested per-call editor
## instances opened from the Calltrace panel, but the live render path
## emitted only the empty container.  Keeping the IsoNim view parity-
## faithful (no children) avoids changing the visible behaviour while
## moving the rendering path off Karax (mission goal #3).
##
## Both renderer overloads (Mock and Web) emit::
##
##   div.component-container.calltrace-editor
##
## The mount helper sets ``vm.mounted`` to true so headless tests can
## assert end-to-end lifecycle wiring (the panel today exposes no other
## reactive surface).  When future work revives the nested-editor
## tree this file is the single place to declare the new structure.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/calltrace_editor_vm

const
  CalltraceEditorContainerClass* = "component-container calltrace-editor"
    ## CSS class string mirroring the legacy
    ## ``componentContainerClass("calltrace-editor")`` template (see
    ## ``frontend/renderer.nim::componentContainerClass``).  Exposed as
    ## a constant so headless tests can assert against the exact class
    ## list without depending on the template.

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderCalltraceEditorPanel*(r: MockRenderer;
                                 vm: CalltraceEditorVM): MockNode =
  ## Render the calltrace-editor placeholder for the Mock renderer.
  ##
  ## Deliberately childless — matches the legacy Karax shell.  An
  ## outer ``createRenderEffect`` is reserved for future use (e.g.
  ## conditionally rendering nested editors when ``vm.mounted`` flips)
  ## but currently emits no DOM mutations.
  let panel = ui(r):
    tdiv(class = CalltraceEditorContainerClass):
      discard

  # Touch the ``mounted`` signal so future readers establish the
  # subscription edge.  No DOM work needed today; the legacy Karax
  # render produced no children either.
  createRenderEffect proc() =
    discard vm.mounted.val

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderCalltraceEditorPanel*(r: WebRenderer;
                                   vm: CalltraceEditorVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  Mirrors the Mock-renderer
    ## shape so the resulting structure is identical across backends.
    let panel = ui(r):
      tdiv(class = CalltraceEditorContainerClass):
        discard

    createRenderEffect proc() =
      discard vm.mounted.val

    panel

  proc mountIsoNimCalltraceEditor*(container: isonim_dom.Element;
                                   vm: CalltraceEditorVM) =
    ## Mount the IsoNim calltrace-editor placeholder as a child of
    ## ``container``.  Sets ``vm.mounted`` to true so any headless
    ## lifecycle assertions and future reactive consumers can react.
    let r = WebRenderer()
    let panel = renderCalltraceEditorPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    vm.markMounted()
