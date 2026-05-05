import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[frame_viewer_vm, visual_replay_client],
  ../viewmodel/views/isonim_frame_viewer_view

import std/[json, options]
import isonim/core/[async_compat, signals]
import isonim/web/dom_api as dom_api

when not defined(js):
  import std/asyncdispatch

when defined(js):
  proc fetchJsonText(url: cstring): VisualReplayFuture[cstring] {.importjs: """
    ((async function(url) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error("visual replay request failed: " + response.status);
      }
      return await response.text();
    })(#))
  """.}

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

proc completedVisualFuture[T](value: T): VisualReplayFuture[T] =
  when defined(js):
    result = newPromise proc(resolve: proc(value: T)) =
      resolve(value)
  else:
    result = newFuture[T]("frame viewer inactive client")
    result.complete(value)

proc createInactiveVisualReplayClient(playerUrl: string): VisualReplayClient =
  VisualReplayClient(
    playerUrl: "",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      completedVisualFuture(VisualReplayInfo(frameCount: 0, width: 0, height: 0)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: some(geid),
        frame: none(int),
        width: 0,
        height: 0)),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: none(uint64),
        frame: some(frame),
        width: 0,
        height: 0)),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: none(uint64),
        frame: none(int),
        width: 0,
        height: 0)),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      completedVisualFuture(newSeq[VisualReplayDrawCall]()),
  )

proc createHttpVisualReplayClient(playerUrl: string): VisualReplayClient =
  when defined(js):
    createJsonVisualReplayClient(
      playerUrl,
      proc(url: string): VisualReplayFuture[JsonNode] =
        let textFuture = fetchJsonText(cstring(url))
        result = newPromise proc(resolve: proc(value: JsonNode)) =
          async_compat.onComplete(textFuture,
            onSuccess = proc(raw: cstring) =
              resolve(parseJson($raw)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)))
  else:
    createInactiveVisualReplayClient(playerUrl)

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
  syncVisualReplaySessionIntoVM()

proc initFrameViewerVMWithStore*(store: ReplayDataStore) =
  initFrameViewerVM(store)
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
