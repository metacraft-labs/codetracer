import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[frame_viewer_vm, visual_replay_client],
  ../viewmodel/views/isonim_frame_viewer_view,
  pixel_history,
  shader_debug,
  visual_replay_client_factory

import std/options
import isonim/core/signals
import isonim/web/dom_api as dom_api

when defined(js):
  proc installFrameViewerTestHooks(applyGeid: proc(geid: int)) {.importjs: """
    (function(applyGeid) {
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      window.__CODETRACER_TEST__.fakeMcrStepGeid = function(geid) {
        applyGeid(Number(geid || 0));
      };
    })(#);
  """.}

var frameViewerVMInstance: FrameViewerVM
var frameViewerComponentRef: FrameViewerComponent
var isoNimFrameViewerMounted*: bool = false

proc syncVisualReplaySessionIntoVM*() =
  if frameViewerVMInstance.isNil:
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  let playerError =
    if session.visualReplayPlayerError.isNil: ""
    else: $session.visualReplayPlayerError
  if frameViewerVMInstance.client.isNil or
      frameViewerVMInstance.client.playerUrl != normalizedPlayerUrl(playerUrl):
    frameViewerVMInstance.client =
      if playerUrl.len > 0:
        createHttpVisualReplayClient(playerUrl)
      else:
        createInactiveVisualReplayClient(playerUrl)
    pixel_history.setPixelHistoryVisualReplayClient(frameViewerVMInstance.client)
    shader_debug.setShaderDebugVisualReplayClient(frameViewerVMInstance.client)
  frameViewerVMInstance.setVisualReplayConnection(
    session.visualReplayAvailable,
    playerUrl,
    playerError)
  if session.visualReplayAvailable and playerUrl.len > 0 and
      not frameViewerVMInstance.store.isNil and
      frameViewerVMInstance.store.currentGeid.val.isSome and
      frameViewerVMInstance.frameImageSrc.val.len == 0 and
      not frameViewerVMInstance.loading.val:
    frameViewerVMInstance.loadFrameForGeid(
      frameViewerVMInstance.store.currentGeid.val.get)

proc initFrameViewerVM(store: ReplayDataStore = nil) =
  if not frameViewerVMInstance.isNil:
    frameViewerVMInstance.bindReplayStore(store)
    syncVisualReplaySessionIntoVM()
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  frameViewerVMInstance = createFrameViewerVM(
    createInactiveVisualReplayClient(playerUrl),
    store)
  frameViewerVMInstance.onPixelSelected =
    proc(x, y, frame: int; geid: Option[uint64]) =
      pixel_history.loadPixelHistoryFromFrameViewer(x, y, frame)
      shader_debug.loadShaderDebugFromFrameViewer(x, y, frame, geid)
  syncVisualReplaySessionIntoVM()

proc initFrameViewerVMWithStore*(store: ReplayDataStore) =
  initFrameViewerVM(store)
  pixel_history.initPixelHistoryVMWithStore(store)
  shader_debug.initShaderDebugVMWithStore(store)
  when defined(js):
    if data.startOptions.inTest:
      installFrameViewerTestHooks(proc(geid: int) =
        if geid > 0:
          store.updateCurrentGeid(some(uint64(geid))))

proc tryMountIsoNimFrameViewerPanel*(component: FrameViewerComponent = nil) =
  if not component.isNil and frameViewerComponentRef.isNil:
    frameViewerComponentRef = component
  if frameViewerVMInstance.isNil:
    initFrameViewerVM()
  if isoNimFrameViewerMounted or frameViewerVMInstance.isNil:
    return
  if frameViewerComponentRef.isNil:
    return

  let key = cstring("frameViewerComponent-" & $frameViewerComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimFrameViewerMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimFrameViewerPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimFrameViewerMounted = true
    try:
      mountIsoNimFrameViewer(container, frameViewerVMInstance)
    except:
      cerror "tryMountIsoNimFrameViewerPanel: mount EXCEPTION: " &
        getCurrentExceptionMsg()

  doMount()

method register*(self: FrameViewerComponent, api: MediatorWithSubscribers) =
  self.api = api
  initFrameViewerVM()
  tryMountIsoNimFrameViewerPanel(self)
