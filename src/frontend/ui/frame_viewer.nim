import
  ui_imports,
  ../communication,
  ../viewmodel/viewmodels/[frame_viewer_vm, visual_replay_client],
  ../viewmodel/views/isonim_frame_viewer_view

import std/options
import isonim/web/dom_api as dom_api

when not defined(js):
  import std/asyncdispatch

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
    playerUrl: playerUrl,
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
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      completedVisualFuture(newSeq[VisualReplayDrawCall]()),
  )

proc syncVisualReplaySessionIntoVM*() =
  if frameViewerVMInstance.isNil:
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  frameViewerVMInstance.setVisualReplayConnection(
    session.visualReplayAvailable,
    playerUrl)

proc initFrameViewerVM() =
  if not frameViewerVMInstance.isNil:
    syncVisualReplaySessionIntoVM()
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  frameViewerVMInstance = createFrameViewerVM(
    createInactiveVisualReplayClient(playerUrl))
  syncVisualReplaySessionIntoVM()

proc tryMountIsoNimFrameViewerPanel*() =
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
  if frameViewerComponentRef.isNil:
    frameViewerComponentRef = self
    tryMountIsoNimFrameViewerPanel()
