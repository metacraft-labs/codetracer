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
import isonim/web/web_renderer
import ./panel_host
import ../viewmodel/input/[dom_pointer, dom_pane_presses, pane_presses]
from ../viewmodel/session_vm import SessionViewModel
from ../context_menu_item import ContextMenuItem
from kdom import nil
# The Origin Chain model the side panel draws (`ui/state.nim` installs it).
import ./origin_chain_runtime

var pixelHistoryVMInstance: PixelHistoryVM
var pixelHistoryVMProvider*: proc(): PixelHistoryVM
  ## The Visual Replay panes' model's Pixel History (`ui/video_player`): a
  ## row's click there shows the draw call in the Video Player and loads its
  ## shader (`VisualReplayPanesVM`).

proc initPixelHistoryVM(store: ReplayDataStore = nil) =
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.bindReplayStore(store)
    return
  if not pixelHistoryVMProvider.isNil:
    pixelHistoryVMInstance = pixelHistoryVMProvider()
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

# A press on an entry goes to the draw call's source (K73): the pointer row
# `pixel-history.activate`, performed on the entry the key router's hit test
# found (`input/dom_pointer`).
registerElementOperation("pixel-history.activate", proc(p: ElementPress): bool =
  pressPixelHistory(pixelHistoryVMInstance, "pixel-history.activate",
                    readerOf(p.element)))

proc entryMenuItems(vm: PixelHistoryVM; index: int): seq[ContextMenuItem] =
  ## An entry's right-click menu: "Show value origin", which opens the
  ## Origin Chain side panel on the colour that draw wrote to the pixel
  ## (`PixelHistoryVM.showValueOriginForEntry`; it refuses by name while no
  ## back end answers a pixel's origin). Empty for an index outside the
  ## history, so the press is left alone.
  if vm.isNil or vm.pixelOriginQueryFor(index).isNone:
    return @[]
  let theVm = vm
  @[ContextMenuItem(
    name: cstring(ShowValueOriginLabel), hint: cstring"",
    handler: proc(ev: kdom.Event) =
      discard theVm.showValueOriginForEntry(
        index, originChainVM()))]

# A right press on an entry opens its menu: the pointer row
# `context-menu.open`, performed for this pane on the entry the key router's
# hit test found (`input/dom_pointer`), as the Constraints pane does.
registerPaneOperation("context-menu.open", "pixelHistory", proc(p: ElementPress): bool =
  let index = intAttributeOf(p.element, "data-pixel-history-index")
  initPixelHistoryVM()
  p.showMenuAt(entryMenuItems(pixelHistoryVMInstance, index)))
