## Legacy Video-Replay glue around the standalone Frame Viewer pane.
##
## M3 retired the dedicated ``Content.FrameViewer`` pane: the Video Player
## (``ui/video_player.nim``) is now the user-facing surface for visual replay
## and embeds the rendered frame canvas directly.  What survives in this file
## is the bootstrap for the singleton ``FrameViewerVM`` instance — the same
## VM the Video Player wraps — together with the JS test hooks the Playwright
## suite uses to drive synthetic GEID transitions through that VM.  Pane
## registration (``register*``, ``tryMountIsoNimFrameViewerPanel``) lived here
## historically and is intentionally absent now.

import
  ui_imports,
  ../communication,
  ../viewmodel/store/replay_data_store,
  ../viewmodel/viewmodels/[frame_viewer_vm, visual_replay_client],
  pixel_history,
  shader_debug,
  visual_replay_client_factory

import std/options
import isonim/core/signals

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

const initialVisualReplayIndexingDraw = 999

proc syncVisualReplaySessionIntoVM*() =
  ## Refresh the shared FrameViewerVM with the latest visual-replay session
  ## state.  Safe to call whenever the active session changes — early-returns
  ## if the VM has not been constructed yet.
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
      frameViewerVMInstance.frameImageSrc.val.len == 0 and
      not frameViewerVMInstance.loading.val:
    frameViewerVMInstance.loadFrameForDraw(
      initialVisualReplayIndexingDraw, seekSource = false)

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
  ## Initialises the shared VM and the downstream Pixel History / Shader Debug
  ## VMs that consume its selection callbacks.  ``ui_js.nim`` invokes this
  ## once the active session VM is ready so the data plane is online before
  ## the panes mount.
  initFrameViewerVM(store)
  pixel_history.initPixelHistoryVMWithStore(store)
  shader_debug.initShaderDebugVMWithStore(store)
  when defined(js):
    if data.startOptions.inTest:
      installFrameViewerTestHooks(proc(geid: int) =
        if geid > 0:
          store.updateCurrentGeid(some(uint64(geid))))
