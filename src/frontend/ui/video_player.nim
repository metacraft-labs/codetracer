## UI glue for the Visual Replay Video Player pane.
##
## Mirrors `ui/frame_viewer.nim` (which it eventually replaces in M3) but
## wraps the existing FrameViewerVM with a VideoPlayerVM that owns the
## playback chrome and the pixel-picker state. The two panes can coexist
## during the M1/M2 transition window.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
## Milestones: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org

import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[frame_viewer_vm, video_player_vm, visual_replay_client],
  ../viewmodel/views/isonim_video_player_view,
  pixel_history,
  shader_debug,
  visual_replay_client_factory

import std/options
import isonim/core/signals
import isonim/web/dom_api as dom_api

var videoPlayerFrameVMInstance: FrameViewerVM
var videoPlayerVMInstance: VideoPlayerVM
var videoPlayerComponentRef: VideoPlayerComponent
var isoNimVideoPlayerMounted*: bool = false

## Initial draw index used when the session first connects to a player. Matches
## the value used by frame_viewer.nim so the two panes start on the same frame.
const initialVisualReplayIndexingDraw = 999

proc syncVisualReplaySessionIntoPlayerVM*() =
  if videoPlayerFrameVMInstance.isNil:
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  let playerError =
    if session.visualReplayPlayerError.isNil: ""
    else: $session.visualReplayPlayerError
  ## Rebuild the HTTP client whenever the player URL changes so the new
  ## endpoints are picked up.
  if videoPlayerFrameVMInstance.client.isNil or
      videoPlayerFrameVMInstance.client.playerUrl != normalizedPlayerUrl(playerUrl):
    videoPlayerFrameVMInstance.client =
      if playerUrl.len > 0:
        createHttpVisualReplayClient(playerUrl)
      else:
        createInactiveVisualReplayClient(playerUrl)
  videoPlayerFrameVMInstance.setVisualReplayConnection(
    session.visualReplayAvailable,
    playerUrl,
    playerError)
  if session.visualReplayAvailable and playerUrl.len > 0 and
      videoPlayerFrameVMInstance.frameImageSrc.val.len == 0 and
      not videoPlayerFrameVMInstance.loading.val:
    videoPlayerFrameVMInstance.loadFrameForDraw(
      initialVisualReplayIndexingDraw, seekSource = false)
    videoPlayerFrameVMInstance.loadInfo()

proc initVideoPlayerVM(store: ReplayDataStore = nil) =
  if not videoPlayerVMInstance.isNil:
    if not store.isNil:
      videoPlayerFrameVMInstance.bindReplayStore(store)
    syncVisualReplaySessionIntoPlayerVM()
    return
  let session = data.activeSession
  let playerUrl =
    if session.visualReplayPlayerUrl.isNil: ""
    else: $session.visualReplayPlayerUrl
  videoPlayerFrameVMInstance = createFrameViewerVM(
    createInactiveVisualReplayClient(playerUrl),
    store)
  ## Picker commits and conventional clicks route to the same downstream
  ## panes — pixel history and shader debug — so the StateView tabs populate
  ## regardless of how the pixel was selected.
  videoPlayerFrameVMInstance.onPixelSelected =
    proc(x, y, frame: int; geid: Option[uint64]) =
      pixel_history.loadPixelHistoryFromFrameViewer(x, y, frame)
      shader_debug.loadShaderDebugFromFrameViewer(x, y, frame, geid)
  videoPlayerVMInstance = createVideoPlayerVM(videoPlayerFrameVMInstance)
  syncVisualReplaySessionIntoPlayerVM()

proc initVideoPlayerVMWithStore*(store: ReplayDataStore) =
  initVideoPlayerVM(store)
  pixel_history.initPixelHistoryVMWithStore(store)
  shader_debug.initShaderDebugVMWithStore(store)

proc tryMountIsoNimVideoPlayerPanel*(
    component: VideoPlayerComponent = nil) =
  if not component.isNil and videoPlayerComponentRef.isNil:
    videoPlayerComponentRef = component
  if videoPlayerVMInstance.isNil:
    initVideoPlayerVM()
  if isoNimVideoPlayerMounted or videoPlayerVMInstance.isNil:
    return
  if videoPlayerComponentRef.isNil:
    return

  let key = cstring("videoPlayerComponent-" & $videoPlayerComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimVideoPlayerMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimVideoPlayerPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimVideoPlayerMounted = true
    try:
      mountIsoNimVideoPlayer(container, videoPlayerVMInstance)
    except:
      cerror "tryMountIsoNimVideoPlayerPanel: mount EXCEPTION: " &
        getCurrentExceptionMsg()

  doMount()

method register*(self: VideoPlayerComponent, api: MediatorWithSubscribers) =
  self.api = api
  initVideoPlayerVM()
  tryMountIsoNimVideoPlayerPanel(self)
