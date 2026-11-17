## viewmodels/visual_replay_panes_vm.nim — the Visual Replay panes, as ONE
## model every front-end reads (Visual-Replay.md; CodeTracer-TUI-Graphics.md
## §4–§6).
##
## The desktop's three panes — Video Player, Pixel History, Shader Debug —
## are four ViewModels over one player (`FrameViewerVM` the frame,
## `VideoPlayerVM` its transport and scrubbers, `PixelHistoryVM`,
## `ShaderDebugVM`). What joins them is the same on every front-end, so it
## lives here and not in a view:
##
##   * **one client.** Every request of the four goes to the same player. A
##     front-end that hands the frame a client and leaves the other three
##     with their inactive one gets a picked pixel whose history is always
##     empty (`setClient` sets all four at once);
##   * **a picked pixel loads its history and its shader**
##     (Visual-Replay.md § Selection Result: "the Pixel History and Shader
##     Debug tabs receive the selection");
##   * **a history row navigates** (§ Pixel History Tab: "Click an entry to
##     seek the Video Player to that draw call"; M6: the recording moves to
##     the draw call's event) and loads that fragment's shader;
##   * **the panes appear with the player** (§ Activation): a front-end asks
##     `connect` with what the recording carries and adds the panes when
##     `available`.

import std/options

import isonim/core/signals
import isonim/viewmodel

import ../store/replay_data_store
import visual_replay_client
import frame_viewer_vm
import video_player_vm
import pixel_history_vm
import shader_debug_vm

export visual_replay_client, frame_viewer_vm, video_player_vm,
       pixel_history_vm, shader_debug_vm

type
  VisualReplayPanesVM* = ref object of ViewModel
    client*: VisualReplayClient
    frame*: FrameViewerVM
    player*: VideoPlayerVM
    history*: PixelHistoryVM
    shader*: ShaderDebugVM
    available*: Signal[bool]
      ## The recording carries graphics: the panes belong in the layout.
    playerError*: Signal[string]
      ## Why the player could not be started or answered (Visual-Replay.md
      ## § Status Indicators, "Player error"); "" when it is connected.

func sessionRefusedWords*(refusal: string): string =
  ## What the native front-ends say when the engine refused a recording whose
  ## graphics they still show: the engine's own sentence, after the fact the
  ## user sees (the debugger's panes are empty), not a second wording of why.
  "No debugging session for this recording: " & refusal

proc setClient*(vm: VisualReplayPanesVM; client: VisualReplayClient) =
  ## ONE player for the four ViewModels.
  vm.client = client
  vm.frame.client = client
  vm.history.client = client
  vm.shader.client = client

proc pickedPixel*(vm: VisualReplayPanesVM): Option[PixelHistoryPixel] =
  ## The pixel the history and the shader are about.
  vm.history.selectedPixel.val

proc selectHistoryEntry*(vm: VisualReplayPanesVM; index: int) =
  ## Select row `index` of the pixel history without navigating (a cursor
  ## moving over the rows).
  vm.history.selectEntry(index, seekSource = false)

proc activateHistoryEntry*(vm: VisualReplayPanesVM; index: int): bool =
  ## A history row's click (Visual-Replay.md § Pixel History Tab): the row
  ## is selected, the recording goes to the draw call's event (M6:
  ## `jumpToSourceForEntry`), the Video Player shows the framebuffer after
  ## that draw call (`onEntryActivated`), and the Shader Debug pane loads its
  ## fragment (`onEntrySelected`) — the desktop's click (`selectEntry`) and
  ## the native panes' alike. False for a row that is not there.
  if index < 0 or index >= vm.history.entries.val.len:
    return false
  vm.history.selectEntry(index, seekSource = true)
  true

proc connect*(vm: VisualReplayPanesVM; available: bool; playerUrl: string;
              error = "") =
  ## The recording's graphics: whether it carries any, the player's URL
  ## ("" when none is running) and why not. A connected player is asked its
  ## extent (`/info`: the frames, the scene marks) and the first frame — or,
  ## with a store that already knows the position, the frame there.
  vm.available.val = available
  vm.playerError.val = error
  vm.frame.setVisualReplayConnection(available, playerUrl, error)
  if not available or playerUrl.len == 0 or error.len > 0:
    return
  vm.frame.loadInfo()
  let geid =
    if vm.frame.store.isNil: none(uint64)
    else: vm.frame.store.currentGeid.val
  if geid.isSome:
    vm.frame.loadFrameForGeid(geid.get)
  else:
    vm.frame.loadFrameByIndex(0)

proc createVisualReplayPanesVM*(client: VisualReplayClient;
                                store: ReplayDataStore = nil):
    VisualReplayPanesVM =
  ## The four ViewModels over `client`, joined as the desktop joins them.
  let frame = createFrameViewerVM(client, store)
  let history = createPixelHistoryVM(client, store)
  let shader = createShaderDebugVM(client, store)
  let player = createVideoPlayerVM(frame)
  result = withViewModel proc(dispose: proc()): VisualReplayPanesVM =
    let vm = VisualReplayPanesVM(
      client: client, frame: frame, player: player, history: history,
      shader: shader,
      available: createSignal(false),
      playerError: createSignal(""),
      disposeProc: dispose)
    frame.onPixelSelected =
      proc(x, y, f: int; geid: Option[uint64]) =
        history.loadPixelHistory(x, y, f)
        shader.loadFromPixel(x, y, f, geid)
    history.onEntryActivated =
      proc(entry: VisualReplayPixelHistoryEntry) =
        player.pause()
        frame.loadFrameForDraw(entry.drawCallIndex, seekSource = false,
                               sourceGeid = some(entry.geid))
    history.onEntrySelected =
      proc(entry: VisualReplayPixelHistoryEntry) =
        let pixel = history.selectedPixel.val
        if pixel.isSome:
          shader.loadFromPixelHistoryEntry(pixel.get.x, pixel.get.y,
                                           pixel.get.frame, entry)
    vm
  # The four ViewModels own roots of their own: disposing the panes
  # disposes them too.
  let own = result.disposeProc
  result.disposeProc = proc() =
    player.dispose()
    frame.dispose()
    history.dispose()
    shader.dispose()
    if not own.isNil: own()
