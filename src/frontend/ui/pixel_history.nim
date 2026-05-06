import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[pixel_history_vm, visual_replay_client],
  ../viewmodel/views/isonim_pixel_history_view,
  visual_replay_client_factory

import isonim/web/dom_api as dom_api

var pixelHistoryVMInstance: PixelHistoryVM
var pixelHistoryComponentRef: PixelHistoryComponent
var isoNimPixelHistoryMounted*: bool = false

proc refreshMountedPixelHistoryPanel()

proc initPixelHistoryVM(store: ReplayDataStore = nil) =
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.bindReplayStore(store)
    return
  pixelHistoryVMInstance = createPixelHistoryVM(
    createInactiveVisualReplayClient(""),
    store)
  pixelHistoryVMInstance.onHistoryLoaded =
    proc(entryCount: int; error: string; loading: bool) =
      refreshMountedPixelHistoryPanel()

proc initPixelHistoryVMWithStore*(store: ReplayDataStore) =
  initPixelHistoryVM(store)

proc setPixelHistoryVisualReplayClient*(client: VisualReplayClient) =
  initPixelHistoryVM()
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.client = client

proc loadPixelHistoryFromFrameViewer*(x, y, frame: int) =
  initPixelHistoryVM()
  if not pixelHistoryVMInstance.isNil:
    pixelHistoryVMInstance.loadPixelHistory(x, y, frame)

proc tryMountIsoNimPixelHistoryPanel*(component: PixelHistoryComponent = nil) =
  if not component.isNil and pixelHistoryComponentRef.isNil:
    pixelHistoryComponentRef = component
  if pixelHistoryVMInstance.isNil:
    initPixelHistoryVM()
  if isoNimPixelHistoryMounted or pixelHistoryVMInstance.isNil:
    return
  if pixelHistoryComponentRef.isNil:
    return

  let key = cstring("pixelHistoryComponent-" & $pixelHistoryComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimPixelHistoryMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimPixelHistoryPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimPixelHistoryMounted = true
    try:
      mountIsoNimPixelHistory(container, pixelHistoryVMInstance)
    except:
      cerror "tryMountIsoNimPixelHistoryPanel: mount EXCEPTION: " &
        getCurrentExceptionMsg()

  doMount()

proc refreshMountedPixelHistoryPanel() =
  if not isoNimPixelHistoryMounted or pixelHistoryComponentRef.isNil or
      pixelHistoryVMInstance.isNil:
    return
  let key = cstring("pixelHistoryComponent-" & $pixelHistoryComponentRef.id)
  let container = dom_api.getElementById(dom_api.document, key)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return

  let containerNode = dom_api.Node(container)
  while not dom_api.isNodeNil(containerNode.firstChild):
    discard dom_api.removeChild(containerNode, containerNode.firstChild)
  mountIsoNimPixelHistory(container, pixelHistoryVMInstance)

method register*(self: PixelHistoryComponent, api: MediatorWithSubscribers) =
  self.api = api
  initPixelHistoryVM()
  tryMountIsoNimPixelHistoryPanel(self)
