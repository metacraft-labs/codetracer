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

import std/[json, options]
import isonim/core/signals
import isonim/web/dom_api as dom_api

var videoPlayerFrameVMInstance: FrameViewerVM
var videoPlayerVMInstance: VideoPlayerVM
var videoPlayerComponentRef: VideoPlayerComponent
var isoNimVideoPlayerMounted*: bool = false

proc currentVideoPlayerVM*(): VideoPlayerVM =
  ## Accessor used by the global ClientAction dispatcher in ``ui_js.nim`` to
  ## route Visual Replay shortcuts onto the live VM.  Returns ``nil`` when the
  ## Video Player panel has not been mounted yet (no visual recording loaded,
  ## or the user closed the pane); callers must treat ``nil`` as "no-op,
  ## let the key fall through".
  videoPlayerVMInstance

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

when defined(js):
  ## Focus / hover marker for keyboard-shortcut scoping (M4).
  ##
  ## Spec (Visual-Replay.md §Keyboard Shortcuts):
  ##   "All shortcuts are scoped to the Video Player component when it has
  ##    focus; the player must be focused (or the cursor must be over the
  ##    frame canvas) for them to fire — this prevents collisions with the
  ##    global step shortcuts (F10/F11) used by the Debugger Controls."
  ##
  ## We attach a tiny per-panel tracker that the global ClientAction handlers
  ## in ``ui_js.nim`` consult via ``videoPlayerHasFocus()`` before delegating
  ## the key to the VM.  Mouse hover is the OR side of the scope — the panel
  ## itself rarely receives the platform "focus" event because it has no
  ## tabindex, so a cursor over the frame canvas is the user's primary signal
  ## of intent.
  proc installVideoPlayerFocusTracker(panel: cstring) {.importjs: """
    (function(panelSelector) {
      window.__codetracer__ = window.__codetracer__ || {};
      var state = window.__codetracer__.videoPlayerFocusState =
        window.__codetracer__.videoPlayerFocusState ||
        { hovering: false, panels: [] };

      function findPanel() {
        return document.querySelector(panelSelector);
      }

      var panel = findPanel();
      if (!panel) return;
      if (state.panels.indexOf(panel) !== -1) return;
      state.panels.push(panel);

      function onEnter() { state.hovering = true; }
      function onLeave() { state.hovering = false; }
      panel.addEventListener("mouseenter", onEnter);
      panel.addEventListener("mouseleave", onLeave);

      // Establish the focus query.  Re-installs are idempotent — the first
      // tracker wins; later panels just add their listeners and contribute
      // their nodes to the live containment check below.
      if (typeof window.__codetracer__.videoPlayerHasFocus !== "function") {
        window.__codetracer__.videoPlayerHasFocus = function() {
          if (state.hovering) return true;
          var active = document.activeElement;
          if (!active) return false;
          for (var i = 0; i < state.panels.length; i++) {
            var p = state.panels[i];
            if (p === active) return true;
            if (typeof p.contains === "function" && p.contains(active)) {
              return true;
            }
          }
          return false;
        };
      }
    })(#);
  """.}

  proc videoPlayerHasFocus*(): bool {.importjs: """
    (function() {
      try {
        if (typeof window.__codetracer__ === "undefined") return false;
        if (typeof window.__codetracer__.videoPlayerHasFocus !== "function") {
          return false;
        }
        return !!window.__codetracer__.videoPlayerHasFocus();
      } catch (_err) {
        return false;
      }
    })()
  """.}

  ## Playwright hook — bypasses focus scoping so specs can dispatch every
  ## ClientAction without coordinating a real focused-and-hovered Video
  ## Player.  Mirrors the existing ``__CODETRACER_TEST__.fakeMcrStepGeid``
  ## pattern in ``ui/frame_viewer.nim``.  Returns ``true``/``false`` matching
  ## the dispatcher's consumption signal so tests can also exercise the
  ## fall-through contract on Escape.
  proc installVideoPlayerTestHooks(
      dispatch: proc(name: cstring): bool) {.importjs: """
    (function(dispatch) {
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      window.__CODETRACER_TEST__.videoPlayerAction = function(name) {
        return !!dispatch(String(name || ""));
      };
    })(#);
  """.}

  ## M5 hook: deterministic state setter for the storybook Playwright
  ## spec.  Accepts a JSON-encoded scenario descriptor that lists which
  ## VM signals to overwrite so each story renders a known pixel-stable
  ## state without needing to drive the underlying HTTP fixture
  ## through the same exact sequence on every run.
  ##
  ## Allowed keys (all optional):
  ##   - ``playState``: "playing" | "paused"
  ##   - ``rate``: 1 | 2 | 4 | 8
  ##   - ``direction``: "forward" | "reverse"
  ##   - ``buffering``: true | false
  ##   - ``picker``: true | false
  ##   - ``currentFrame``: int
  ##   - ``frameCount``: int
  ##   - ``error``: string (sets frameVm.error)
  ##   - ``imageSrc``: data URL forced as the frame image source
  ##   - ``visualReplayAvailable``: bool
  ##   - ``playerUrl``: string
  proc installVideoPlayerStateHook(
      apply: proc(scenarioJson: cstring)) {.importjs: """
    (function(apply) {
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      window.__CODETRACER_TEST__.videoPlayerSetState = function(scenario) {
        var encoded = (typeof scenario === "string")
          ? scenario
          : JSON.stringify(scenario || {});
        apply(encoded);
      };
    })(#);
  """.}

else:
  proc installVideoPlayerFocusTracker(panel: cstring) = discard
  proc videoPlayerHasFocus*(): bool = false
  proc installVideoPlayerTestHooks(
      dispatch: proc(name: cstring): bool) = discard
  proc installVideoPlayerStateHook(
      apply: proc(scenarioJson: cstring)) = discard

proc initVideoPlayerVMWithStore*(store: ReplayDataStore) =
  initVideoPlayerVM(store)
  pixel_history.initPixelHistoryVMWithStore(store)
  shader_debug.initShaderDebugVMWithStore(store)
  when defined(js):
    if data.startOptions.inTest:
      ## Playwright hook: bypass focus scoping and route the named
      ## ClientAction straight onto the VM dispatcher.  Returns the
      ## dispatcher's consumption bool so the test can also assert the
      ## fall-through contract on Escape.  Mirrors the
      ## ``__CODETRACER_TEST__.fakeMcrStepGeid`` shape installed by
      ## ``ui/frame_viewer.nim``.
      installVideoPlayerTestHooks(proc(name: cstring): bool =
        let parsed = parseVideoPlayerActionName($name)
        if parsed.isNone:
          return false
        let vm = currentVideoPlayerVM()
        if vm.isNil:
          return false
        return dispatchVideoPlayerAction(vm, parsed.get))

      installVideoPlayerStateHook(proc(scenarioJson: cstring) =
        ## Apply a Playwright-supplied scenario JSON to the live VM
        ## signals so the storybook spec can render a deterministic
        ## state per visual diff entry.  Wrapped in a try/except so a
        ## malformed scenario never panics the panel under test.
        let vm = currentVideoPlayerVM()
        if vm.isNil: return
        try:
          let scenario = parseJson($scenarioJson)
          if scenario.kind != JObject: return
          if scenario.hasKey("playState"):
            case scenario["playState"].getStr("")
            of "playing": vm.playState.val = video_player_vm.Playing
            of "paused":  vm.playState.val = video_player_vm.Paused
            else: discard
          if scenario.hasKey("direction"):
            case scenario["direction"].getStr("")
            of "forward": vm.direction.val = video_player_vm.Forward
            of "reverse": vm.direction.val = video_player_vm.Reverse
            else: discard
          if scenario.hasKey("rate"):
            case scenario["rate"].getInt(1)
            of 1: vm.rate.val = video_player_vm.Rate1x
            of 2: vm.rate.val = video_player_vm.Rate2x
            of 4: vm.rate.val = video_player_vm.Rate4x
            of 8: vm.rate.val = video_player_vm.Rate8x
            else: discard
          if scenario.hasKey("buffering"):
            vm.bufferingDegraded.val = scenario["buffering"].getBool(false)
          if scenario.hasKey("picker"):
            vm.pickerState.val =
              if scenario["picker"].getBool(false): video_player_vm.PickerActive
              else: video_player_vm.PickerOff
          if scenario.hasKey("currentFrame"):
            vm.frameVm.currentFrame.val = scenario["currentFrame"].getInt(0)
          if scenario.hasKey("frameCount"):
            vm.frameVm.frameCount.val = scenario["frameCount"].getInt(0)
          if scenario.hasKey("error"):
            vm.frameVm.error.val = scenario["error"].getStr("")
          if scenario.hasKey("imageSrc"):
            vm.frameVm.frameImageSrc.val = scenario["imageSrc"].getStr("")
          if scenario.hasKey("visualReplayAvailable"):
            vm.frameVm.visualReplayAvailable.val =
              scenario["visualReplayAvailable"].getBool(false)
          if scenario.hasKey("playerUrl"):
            vm.frameVm.playerUrl.val = scenario["playerUrl"].getStr("")
        except CatchableError:
          discard)

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
    when defined(js):
      ## Install the focus / hover tracker on the just-mounted panel so the
      ## global ClientAction handlers (in ``ui_js.nim``) can gate keys on
      ## Video Player focus.  The tracker selector matches the root class
      ## the view renders (see ``renderVideoPlayerPanel``).
      installVideoPlayerFocusTracker(cstring".video-player-component")

  doMount()

method register*(self: VideoPlayerComponent, api: MediatorWithSubscribers) =
  self.api = api
  initVideoPlayerVM()
  tryMountIsoNimVideoPlayerPanel(self)
