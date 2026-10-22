import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[shader_debug_vm, visual_replay_client],
  ../viewmodel/views/isonim_shader_debug_view,
  visual_replay_client_factory

import std/options
import isonim/web/dom_api as dom_api
when not defined(ctInExtension):
  import isonim/web/web_renderer
  import ./panel_host
  from ../viewmodel/session_vm import SessionViewModel

var shaderDebugVMInstance: ShaderDebugVM

proc initShaderDebugVM(store: ReplayDataStore = nil) =
  if not shaderDebugVMInstance.isNil:
    shaderDebugVMInstance.bindReplayStore(store)
    return
  shaderDebugVMInstance = createShaderDebugVM(
    createInactiveVisualReplayClient(""),
    store)

proc initShaderDebugVMWithStore*(store: ReplayDataStore) =
  initShaderDebugVM(store)

proc setShaderDebugVisualReplayClient*(client: VisualReplayClient) =
  initShaderDebugVM()
  if not shaderDebugVMInstance.isNil:
    shaderDebugVMInstance.client = client

proc loadShaderDebugFromFrameViewer*(x, y, frame: int; geid: Option[uint64]) =
  initShaderDebugVM()
  if not shaderDebugVMInstance.isNil:
    shaderDebugVMInstance.loadFromPixel(x, y, frame, geid)

proc loadShaderDebugFromPixelHistoryEntry*(x, y, frame: int;
                                           entry: VisualReplayPixelHistoryEntry) =
  initShaderDebugVM()
  if not shaderDebugVMInstance.isNil:
    shaderDebugVMInstance.loadFromPixelHistoryEntry(x, y, frame, entry)

when not defined(ctInExtension):
  # The panel host mounts the pane into the container GoldenLayout creates
  # (`ui/panel_host`); its view follows the ViewModel reactively, so nothing
  # here re-mounts it when a trace loads or the step changes.
  setPanelRenderer(Content.ShaderDebug,
    proc(r: WebRenderer; session: SessionViewModel): dom_api.Element =
      initShaderDebugVM()
      renderShaderDebugPanel[WebRenderer, dom_api.Element](
        r, shaderDebugVMInstance))

method register*(self: ShaderDebugComponent, api: MediatorWithSubscribers) =
  self.api = api
  initShaderDebugVM()
