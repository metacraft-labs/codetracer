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
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/calltrace_editor_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

const
  CalltraceEditorContainerClass* = "component-container calltrace-editor"
    ## CSS class string mirroring the legacy
    ## ``componentContainerClass("calltrace-editor")`` template (see
    ## ``frontend/renderer.nim::componentContainerClass``).  Exposed as
    ## a constant so headless tests can assert against the exact class
    ## list without depending on the template.

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderCalltraceEditorPanel*[R, N](r: R; vm: CalltraceEditorVM): N =
  ## The calltrace-editor placeholder, under any renderer
  ## (Shared-DOM-Front-Ends D3), mounted on the desktop by `ui/panel_host`.
  ##
  ## Deliberately childless — matches the legacy Karax shell. The effect
  ## reads `vm.mounted` so a future reader has the subscription edge; in a
  ## browser the render marks the ViewModel mounted, as the pane's mount did.
  let panel = ui(r):
    tdiv(class = CalltraceEditorContainerClass):
      discard

  createRenderEffect proc() =
    discard vm.mounted.val

  when defined(js):
    when N is isonim_dom.Element:
      vm.markMounted()

  panel
