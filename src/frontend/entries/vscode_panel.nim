## entries/vscode_panel.nim — one CodeTracer panel in a VS Code webview.
##
## Shared-DOM-Front-Ends D5: the webview side of the extension. The webview's
## HTML names the panel (`<body data-ct-panel="state">`) and loads this
## module and the design-system CSS — nothing else. The module builds a
## MIRROR of the session the extension host owns (`sync/mirror_session`,
## over `sync/webview_transport`) and renders that panel's one view over the
## mirror's ViewModel. A user action in the view runs on the host's primary
## ViewModel (`relayActions`), and its outcome arrives as the primary's next
## batch, so every panel shows the same revision of the session (D2).
##
## It imports none of `ui_js.nim`, `types.Data`, `renderer.nim`, Monaco or
## jQuery; codetracer's `renderer-extension-build` lane asserts that of the
## bundle.
##
## The panels: `state`, `calltrace`, `eventLog`, `terminalOutput`,
## `scratchpad`, `traceLog`, `flow`, `pointList` and `fileTree`.

when not defined(js):
  {.error: "entries/vscode_panel runs in a VS Code webview (JS).".}

import isonim/core/owner
import isonim/web/web_renderer
from isonim/web/dom_api import nil

import ../viewmodel/session_vm
from ../viewmodel/store/types import ScratchpadValueEntry
from ../viewmodel/viewmodels/scratchpad_vm import addValue
import ../viewmodel/viewport
import ../viewmodel/sync/[mirror_session, webview_transport]
import ../viewmodel/views/[isonim_state_view, isonim_calltrace_view,
                           isonim_event_log_view, isonim_terminal_output_view,
                           isonim_scratchpad_view, isonim_trace_log_view,
                           isonim_flow_view, isonim_point_list_view,
                           isonim_filesystem_view]

const PanelKinds* = ["state", "calltrace", "eventLog", "terminalOutput",
                     "scratchpad", "traceLog", "flow", "pointList",
                     "fileTree"]
  ## The panels a webview can show, as its HTML names them.

proc panelKindOfPage(): cstring {.importjs:
  "((document.body && document.body.dataset.ctPanel) || '')".}
proc panelRootOfPage(): dom_api.Element {.importjs:
  "(document.getElementById('ct-panel-root') || document.body)".}
proc reportMounted(kind: cstring) {.importjs:
  "(function(k){ document.body.setAttribute('data-ct-mounted', k); })(#)".}

proc renderPanel(kind: string; s: SessionViewModel): dom_api.Element =
  ## The view of panel `kind` over the mirrored ViewModels; nil for a kind
  ## this module does not know.
  let r = WebRenderer()
  case kind
  of "state":
    renderStatePanel[WebRenderer, dom_api.Element](r, s.stateVM)
  of "calltrace":
    renderCalltracePanel[WebRenderer, dom_api.Element](r, s.calltraceVM)
  of "eventLog": renderEventLogPanel(r, s.eventLogVM)
  of "terminalOutput":
    let panel = renderTerminalOutputPanel[WebRenderer, dom_api.Element](
      r, s.terminalOutputVM)
    decorateTerminalOutput(panel, s.terminalOutputVM)
    panel
  of "scratchpad":
    renderScratchpadPanel[WebRenderer, dom_api.Element](r, s.scratchpadVM)
  of "traceLog":
    renderTraceLogPanel[WebRenderer, dom_api.Element](r, s.traceLogVM)
  of "flow": renderFlowPanel(r, s.flowVM)
  of "pointList":
    renderPointListPanel[WebRenderer, dom_api.Element](r, s.pointListVM)
  of "fileTree":
    renderFilesystemPanel[WebRenderer, dom_api.Element](r, s.fileTreeVM)
  else: nil

var activeMirror: MirrorSession
  ## This webview's mirror; one per page.

proc mountVsCodePanel*(kind: string; root: dom_api.Element): MirrorSession =
  ## Mirror the host's session over this webview's channel and mount panel
  ## `kind` into `root`.
  let mirror = createMirrorSession(newWebviewSyncChannel(),
                                   relayActions = true)
  # The DOM reports a pane's size on every resize and scroll; the reports
  # are debounced on the browser's timer (Viewport-Driven-Loading V2,
  # Pattern 6) before they travel to the host.
  mirror.session.store.viewportScheduler = timeoutScheduler()
  # "Add value to scratchpad" from a call-trace argument: the mirror's
  # scratchpad forwards the value to the primary's.
  let scratchpad = mirror.session.scratchpadVM
  addToScratchpadHook = proc(name, text: string) =
    scratchpad.addValue(ScratchpadValueEntry(expression: name,
                                             valueText: text))
  createRoot proc(dispose: proc()) =
    let panel = renderPanel(kind, mirror.session)
    if not dom_api.isNodeNil(dom_api.Node(panel)):
      discard dom_api.appendChild(dom_api.Node(root), dom_api.Node(panel))
  mirror

when isMainModule:
  let kind = $panelKindOfPage()
  if kind in PanelKinds:
    activeMirror = mountVsCodePanel(kind, panelRootOfPage())
    reportMounted(cstring(kind))
