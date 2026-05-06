import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[shader_debug_vm, visual_replay_client],
  ../viewmodel/views/isonim_shader_debug_view,
  visual_replay_client_factory

import std/options
import isonim/web/dom_api as dom_api

var shaderDebugVMInstance: ShaderDebugVM
var shaderDebugComponentRef: ShaderDebugComponent
var isoNimShaderDebugMounted*: bool = false

proc refreshMountedShaderDebugPanel()

proc initShaderDebugVM(store: ReplayDataStore = nil) =
  if not shaderDebugVMInstance.isNil:
    shaderDebugVMInstance.bindReplayStore(store)
    return
  shaderDebugVMInstance = createShaderDebugVM(
    createInactiveVisualReplayClient(""),
    store)
  shaderDebugVMInstance.onDebugLoaded =
    proc(error: string; loading: bool) =
      refreshMountedShaderDebugPanel()
  shaderDebugVMInstance.onStepChanged =
    proc(stepIndex: int) =
      refreshMountedShaderDebugPanel()

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

proc tryMountIsoNimShaderDebugPanel*(component: ShaderDebugComponent = nil) =
  if not component.isNil and shaderDebugComponentRef.isNil:
    shaderDebugComponentRef = component
  if shaderDebugVMInstance.isNil:
    initShaderDebugVM()
  if isoNimShaderDebugMounted or shaderDebugVMInstance.isNil:
    return
  if shaderDebugComponentRef.isNil:
    return

  let key = cstring("shaderDebugComponent-" & $shaderDebugComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimShaderDebugMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimShaderDebugPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimShaderDebugMounted = true
    try:
      mountIsoNimShaderDebug(container, shaderDebugVMInstance)
    except:
      cerror "tryMountIsoNimShaderDebugPanel: mount EXCEPTION: " &
        getCurrentExceptionMsg()

  doMount()

proc refreshMountedShaderDebugPanel() =
  if not isoNimShaderDebugMounted or shaderDebugComponentRef.isNil or
      shaderDebugVMInstance.isNil:
    return
  let key = cstring("shaderDebugComponent-" & $shaderDebugComponentRef.id)
  let container = dom_api.getElementById(dom_api.document, key)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return

  let containerNode = dom_api.Node(container)
  while not dom_api.isNodeNil(containerNode.firstChild):
    discard dom_api.removeChild(containerNode, containerNode.firstChild)
  mountIsoNimShaderDebug(container, shaderDebugVMInstance)

method register*(self: ShaderDebugComponent, api: MediatorWithSubscribers) =
  self.api = api
  initShaderDebugVM()
  tryMountIsoNimShaderDebugPanel(self)
