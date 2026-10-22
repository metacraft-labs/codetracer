import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[pixel_history_vm, visual_replay_client],
  ../viewmodel/views/isonim_pixel_history_view,
  shader_debug,
  visual_replay_client_factory

import std/options
import isonim/core/signals
import isonim/web/dom_api as dom_api
when not defined(ctInExtension):
  import isonim/web/web_renderer
  import ./panel_host
  from ../viewmodel/session_vm import SessionViewModel

var pixelHistoryVMInstance: PixelHistoryVM

proc initPixelHistoryVM(store: ReplayDataStore = nil) =
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.bindReplayStore(store)
    return
  pixelHistoryVMInstance = createPixelHistoryVM(
    createInactiveVisualReplayClient(""),
    store)
  pixelHistoryVMInstance.onEntrySelected =
    proc(entry: VisualReplayPixelHistoryEntry) =
      if pixelHistoryVMInstance.selectedPixel.val.isSome:
        let pixel = pixelHistoryVMInstance.selectedPixel.val.get
        shader_debug.loadShaderDebugFromPixelHistoryEntry(
          pixel.x, pixel.y, pixel.frame, entry)

proc initPixelHistoryVMWithStore*(store: ReplayDataStore) =
  initPixelHistoryVM(store)

proc setPixelHistoryVisualReplayClient*(client: VisualReplayClient) =
  initPixelHistoryVM()
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.client = client
  shader_debug.setShaderDebugVisualReplayClient(client)

proc loadPixelHistoryFromFrameViewer*(x, y, frame: int) =
  initPixelHistoryVM()
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.loadPixelHistory(x, y, frame)

when not defined(ctInExtension):
  # The panel host mounts the pane into the container GoldenLayout creates
  # (`ui/panel_host`); its view follows the ViewModel reactively, so nothing
  # here re-mounts it when a history loads.
  setPanelRenderer(Content.PixelHistory,
    proc(r: WebRenderer; host: dom_api.Element;
         session: SessionViewModel): dom_api.Element =
      initPixelHistoryVM()
      renderPixelHistoryPanel[WebRenderer, dom_api.Element](
        r, pixelHistoryVMInstance))

method register*(self: PixelHistoryComponent, api: MediatorWithSubscribers) =
  self.api = api
  initPixelHistoryVM()
