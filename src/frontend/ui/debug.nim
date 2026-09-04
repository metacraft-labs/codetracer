import
  results,
  ui_imports,
  command,
  ../[ renderer, communication, event_helpers ],
  ../../common/ct_event
from menu_render_gate import shouldRemountDebugControls
from shortcut_labels import toolbarChord
# WHICH WAY IS BACK. `history_cursor` holds the whole answer — the direction
# enum, the two action ids and the cursor arithmetic — because it is the only
# part of this that a unit lane can compile. Its header records the two
# cancelling inversions the enum replaced.
import history_cursor
export history_cursor
from isonim/core/signals import Signal, val, `val=`

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The DebugControlsVM reads debugger state from the store but does not
# affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/viewmodels/debug_controls_vm import
  DebugControlsVM, createDebugControlsVM, invokeToolbarStep
# `shortcutFor` / `shortcutsRevision` are FIELDS of `DebugControlsVM`, not
# procs, so they arrive with the type and must not be named here.
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_debug_controls_view import
  mountIsoNimDebugControls
# THE EDIT-MODE TOPBAR. `viewmodels/edit_mode_toolbar` shipped complete and
# reached nobody; this import and the branch in `doMount` are what make it
# reachable. The model is composed by the platform (it needs the profile, the
# wasm registry and the project's file listing, none of which this module
# knows) and handed here through `setEditModeToolbar`.
from ../viewmodel/viewmodels/edit_mode_toolbar import
  EditToolbarModel, ToolbarMode, TopbarSurface, topbarSurface,
  tsEditCommands, tsDebuggerControls
from ../viewmodel/views/isonim_edit_mode_toolbar_view import
  mountIsoNimEditModeToolbar
from ../viewmodel/views/isonim_debug_shell_view import
  DebugShellId, commandPaletteHostId, renderDebugChromeInto
from ../viewmodel/views/isonim_menu_shell_view import DebugControlsHostId
from isonim/web/web_renderer import WebRenderer

# Module-level DebugControlsVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy data
# so behaviour is unchanged.
var debugControlsVMInstance: DebugControlsVM
var debugControlsVMStore: ReplayDataStore
var isoNimDebugMounted: bool = false
var debugShellMountedCommandPaletteId: int = -2

# ---------------------------------------------------------------------------
# WHICH SURFACE THE TOPBAR HOST IS CARRYING
# ---------------------------------------------------------------------------
#
# `#isonim-debug-controls` holds ONE of two panels, never both, and which one
# is a function of the layout mode. Recording the surface that is actually
# mounted — rather than deriving it again when asked — is what lets a mode
# transition be detected: `isoNimDebugMounted` is true and the host has
# children in BOTH modes, so `shouldRemountDebugControls` correctly declines,
# and a switch would otherwise leave the previous mode's panel on screen.
# That predicate answers "was my host emptied underneath me"; this variable
# answers "is my host showing the wrong thing", and they are different
# questions.
var mountedTopbarSurface: TopbarSurface = tsDebuggerControls

var editToolbarModel: EditToolbarModel
var editToolbarInvoke: proc(id: string)
var editToolbarAvailable: bool = false
  ## Whether a platform has handed us a model. FALSE is a working state, not a
  ## failure: `topbarSurface` then answers `tsDebuggerControls` for every mode,
  ## which is exactly what shipped before this feature. A platform that never
  ## installs a model is unchanged rather than blank, and an empty topbar would
  ## be a worse defect than the one this fixes.

proc refreshTopbarSurface*()

proc currentTopbarSurface(): TopbarSurface =
  ## `LayoutMode` and `ToolbarMode` are ordinal-for-ordinal mirrors, and
  ## `edit_mode_toolbar.nim` carries a `static` assertion that fails the build
  ## if they ever drift — so this conversion cannot silently mean the wrong
  ## mode.
  topbarSurface(ToolbarMode(data.ui.mode.ord), editToolbarAvailable)

proc setEditModeToolbar*(model: EditToolbarModel; invoke: proc(id: string)) =
  ## Install (or replace) the composed edit-mode toolbar.
  ##
  ## Replacing is the common case, not the rare one: the model is a value, so
  ## every change a user makes that could alter it — saving a file that adds a
  ## `Nargo.toml`, a build finishing — arrives as a NEW model rather than as a
  ## signal the panel is watching. Re-mounting on install is therefore how the
  ## toolbar stays true, and it is cheap: four buttons.
  editToolbarModel = model
  editToolbarInvoke = invoke
  editToolbarAvailable = true
  refreshTopbarSurface()

# Reference to the live `DebugComponent` (and its mediator API) that
# was wired with `register()`. Captured by `register()` and consulted
# by every code path that creates a fresh `DebugControlsVM` so the new
# instance gets the `onDapStep` / `onAction` bridge re-applied.
#
# Without this, replacing the stub-backed VM with the shared-store VM
# in `initDebugControlsVMWithStore` leaves the new instance's bridge
# callbacks nil — the IsoNim toolbar's click handlers then call
# `vm.onDapStep` (which is nil) and silently drop the step request.
# That is the root cause of TODO 5.2(i): wasm DB-trace `next` clicks
# never reach the backend.
var debugComponentForBridge: DebugComponent
var debugApiForBridge: MediatorWithSubscribers

proc wireDebugToolbarShortcuts() =
  ## Give the toolbar's tooltips a way to read the chords that are actually
  ## bound, and tell them the answer may have changed.
  ##
  ## Called from every site that (re)wires `onDapStep` / `onAction`, because
  ## those are exactly the moments a new `DebugControlsVM` exists or a new
  ## `Config` has landed — `data.config` arrives as one field of the
  ## `CODETRACER::no-trace` payload, so it is genuinely not constant.
  ##
  ## THE BUMP IS NOT OPTIONAL. `shortcutFor` is an opaque closure as far as the
  ## reactive graph is concerned; nothing in it is a signal, so a tooltip's
  ## render effect cannot discover on its own that the config underneath
  ## changed. Without the bump the toolbar would paint the chords that were
  ## bound at mount time and keep painting them forever, which is the same
  ## stale-label failure as the hardcoded strings this replaced.
  if debugControlsVMInstance.isNil:
    return
  debugControlsVMInstance.shortcutFor = proc(actionId: string): string =
    # Read `data.config` at CALL time, not capture time: `configureShortcuts`
    # runs again from `onNoTrace` and `onWelcomeScreen`, and the config object
    # is replaced rather than mutated.
    toolbarChord(data.config, actionId)
  debugControlsVMInstance.shortcutsRevision.val =
    debugControlsVMInstance.shortcutsRevision.val + 1

# Forward declarations: `initDebugControlsVMWithStore` (defined below)
# needs to call `dapStep` and `action` (both also below) when
# re-applying the bridge after replacing the VM instance.
proc dapStep*(api: MediatorWithSubscribers, action: cstring)
proc action(self: DebugComponent, id: string)

proc invokeDebugStepAction*(action: cstring): bool =
  ## Route keyboard/menu debug step actions through the same bridge used by the
  ## IsoNim toolbar buttons.  The older ``data.step`` path bypasses this bridge
  ## and can diverge from the button behaviour after the ViewModel migration.
  if not debugControlsVMInstance.isNil:
    debugControlsVMInstance.invokeToolbarStep($action)
    return true
  if not debugApiForBridge.isNil:
    dapStep(debugApiForBridge, action)
    return true
  false

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc tryMountIsoNimDebugControls() =
  ## Mount the IsoNim debug controls view into the dedicated
  ## `#isonim-debug-controls` container div.
  ##
  ## That div is NOT a static element of `index.html` — it is emitted by
  ## `viewmodel/views/isonim_menu_shell_view.nim` as part of the menu shell,
  ## so a full menu-shell rebuild replaces it with a fresh, empty node and
  ## takes the mounted toolbar with it.  (An older comment here claimed the
  ## div came from `index.html`, which sent a previous investigation of
  ## issue #555 down the wrong path; there is no such element in any HTML
  ## file in the repo.)
  ##
  ## The div lives outside Karax's VDOM tree, so direct DOM manipulation
  ## is safe and won't be overwritten by Karax redraw cycles.
  ## Safe to call multiple times — mounts only once per `isoNimDebugMounted`
  ## cycle.
  cdebug "tryMountIsoNimDebugControls: called, isoNimDebugMounted=" & $isoNimDebugMounted & " vmIsNil=" & $debugControlsVMInstance.isNil
  if isoNimDebugMounted or debugControlsVMInstance.isNil:
    cdebug "tryMountIsoNimDebugControls: skipping (already mounted or VM nil)"
    return

  # Try to mount synchronously. If the container doesn't exist yet,
  # retry on the next event loop tick instead of using a fixed delay.
  # Gives up after 100 retries to avoid infinite spinning.
  var debugRetryCount = 0
  proc doMount() =
    if isoNimDebugMounted:
      return
    debugRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, cstring DebugControlsHostId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if debugRetryCount > 100:
        cerror "tryMountIsoNimDebugControls: container not found after 100 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 0)
      return
    # Clear any existing children from a previous mount cycle (e.g. when
    # initDebugControlsVMWithStore replaces the stub VM with the real one).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    cdebug "tryMountIsoNimDebugControls: container found, mounting now"
    isoNimDebugMounted = true
    # THE BRANCH THIS WHOLE FEATURE IS. Everything above is the host-finding
    # retry loop and is unchanged; the only new question is which panel goes
    # into the host it found.
    let surface = currentTopbarSurface()
    mountedTopbarSurface = surface
    case surface
    of tsEditCommands:
      mountIsoNimEditModeToolbar(container, editToolbarModel,
                                 editToolbarInvoke)
    of tsDebuggerControls:
      mountIsoNimDebugControls(container, debugControlsVMInstance)
    cdebug "tryMountIsoNimDebugControls: mount COMPLETE surface=" & $surface
    # The legacy Karax `#debug` div is hidden on next Karax redraw
    # cycle — see the `isoNimDebugMounted` check at the top of
    # `DebugComponent.render`.

  doMount()

proc requestDebugShellRender*(self: DebugComponent) =
  ## Ensure the direct IsoNim debug shell exists.
  ##
  ## The shell is hosted by the direct ``#menu`` renderer. Menu redraws replace
  ## that host, so the cache must also verify that the expected DOM node still
  ## exists before skipping a render.
  let commandPaletteId =
    if not data.ui.commandPalette.isNil: data.ui.commandPalette.id else: -1
  let expectedHost = commandPaletteHostId(commandPaletteId)
  if debugShellMountedCommandPaletteId == commandPaletteId:
    let host = dom_api.getElementById(dom_api.document, cstring expectedHost)
    if not dom_api.isNodeNil(dom_api.Node(host)):
      return

  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugShellId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return

  let r = WebRenderer()
  renderDebugChromeInto(r, container, commandPaletteId)
  debugShellMountedCommandPaletteId = commandPaletteId
  if not data.ui.commandPalette.isNil:
    data.ui.commandPalette.requestCommandPalettePanelRefresh()

proc requestDebugControlsRender*(self: DebugComponent) =
  if self.isNil:
    return
  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugControlsHostId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return
  # Issue #555 — why this path used to fire on essentially every redraw.
  #
  # A previous investigation measured `tryMountIsoNimDebugControls` being
  # entered 46 times and mounting 45 of them on one clean trace open, with the
  # "already mounted" branch firing ZERO times, and concluded the guard below
  # was somehow not working.  It was working; the situation it guards against
  # simply held every single time, for a structural reason:
  #
  #   * `#isonim-debug-controls` is created by `renderMenuShell`
  #     (viewmodel/views/isonim_menu_shell_view.nim), and
  #     `renderMenuShellInto` begins with `clearChildren(container)`.
  #   * So every full menu-shell rebuild hands us a brand-new EMPTY host:
  #     `container.firstChild` is nil, the guard correctly declines to skip,
  #     and we re-mount.
  #   * `ui/menu.nim`'s `requestMenuRender` is called from
  #     `renderer.sharedDirectRedraw`, i.e. from every `data.redraw()`, and it
  #     rebuilt the shell unconditionally.  Dozens of redraws per trace open
  #     therefore meant dozens of toolbar teardowns — the flicker in the bug
  #     report.
  #
  # (The zero "already mounted" hits inside `tryMountIsoNimDebugControls`
  # are additionally explained by this proc clearing `isoNimDebugMounted`
  # immediately before calling it; that inner check only ever guards the
  # asynchronous container-retry loop, never this path.)
  #
  # The fix is on the menu side: `ui/menu_render_gate.nim` now stops
  # `requestMenuRender` from rebuilding a shell whose content has not changed,
  # so the host survives, `firstChild` stays non-nil, and this repair becomes
  # the no-op it was always meant to be.  The predicate lives in that module
  # so both halves of the story can be exercised headlessly — see
  # `src/tests/gui/tests/session-chrome/menu_redraw_storm_test.nim`.
  if not shouldRemountDebugControls(
      isoNimDebugMounted,
      not dom_api.isNodeNil(dom_api.Node(container).firstChild)):
    return
  isoNimDebugMounted = false
  tryMountIsoNimDebugControls()

proc requestDebugActionRefresh(self: DebugComponent) =
  ## Refresh the Debug-owned direct IsoNim surfaces after local action state
  ## changes. The run-tests loading flag no longer belongs to a broad app
  ## redraw path, but keeping this request local preserves the mounted Debug
  ## shell/control contract if the action fires before either host exists.
  self.requestDebugShellRender()
  self.requestDebugControlsRender()

proc initDebugControlsVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel DebugControlsVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initDebugControlsVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  ##
  ## After the replacement, re-apply the `onDapStep` / `onAction` bridge
  ## callbacks if `register()` has already wired the `DebugComponent` to
  ## the middleware API. Without this, IsoNim toolbar clicks call a nil
  ## `onDapStep` on the new instance and the DAP step request is silently
  ## dropped — TODO 5.2(i).
  if debugControlsVMInstance != nil:
    clog "DebugControlsVM: replacing existing instance with shared-store version"
    isoNimDebugMounted = false
  debugControlsVMStore = store
  debugControlsVMInstance = createDebugControlsVM(store)
  clog "DebugControlsVM: parallel ViewModel instance created (shared store)"
  if not debugComponentForBridge.isNil and not debugApiForBridge.isNil:
    let component = debugComponentForBridge
    let api = debugApiForBridge
    debugControlsVMInstance.onDapStep = proc(action: cstring) =
      dapStep(api, action)
    debugControlsVMInstance.onAction = proc(id: string) =
      component.action(id)
    wireDebugToolbarShortcuts()
    clog "DebugControlsVM: re-wired onDapStep/onAction bridge after replacement"
  tryMountIsoNimDebugControls()

proc remountDebugControls*() =
  ## Re-attempt the toolbar mount after the surface has changed under it.
  ##
  ## THE MOUNT GIVES UP, AND NOTHING RETRIES IT. `initDebugControlsVMWithStore`
  ## ends by calling `tryMountIsoNimDebugControls`, whose `doMount` polls for
  ## `#isonim-debug-controls` on `setTimeout(0)` and abandons the attempt after
  ## 100 ticks. On the web that call happens inside `onNoTrace`, which runs
  ## while `enterTemplateEditMode` is still delivering — before GoldenLayout
  ## and the menu shell have drawn — so the host does not exist yet and the
  ## hundred ticks expire against an empty document. The sibling panels log the
  ## same shape out loud — `ui/state.nim`, `ui/calltrace.nim` and `ui/trace.nim`
  ## each `cwarn` a "container absent after … retries" line — while this one
  ## gives up quietly.
  ##
  ## AND THE SIMILARITY STOPS AT THE LOG LINE, WHICH IS WHY THIS PROC EXISTS.
  ## Those three are recoverable and their warnings say so: `ui/layout.nim`'s
  ## component factory calls each mount again once it has built the container,
  ## and each call re-enters with a fresh retry counter, so a give-up there ends
  ## one poll and not the pane. This one has no such later caller —
  ## `isoNimDebugMounted` stays `false` and no event re-fires the mount — so for
  ## the toolbar the exhausted budget really is the end, and the repair has to
  ## be asked for explicitly. That asymmetry is the whole reason this proc is
  ## here and the other three panes need nothing equivalent.
  ##
  ## So a caller that has just CHANGED the surface asks for the mount again.
  ##
  ## THROUGH THE REPAIR PREDICATE, NOT PAST IT. The first version of this proc
  ## called `tryMountIsoNimDebugControls` directly and did nothing at all,
  ## because the toolbar HAD mounted — at boot, into the menu shell's host —
  ## and `isoNimDebugMounted` was still `true`. What the layout swap does is
  ## rebuild the menu shell, and `renderMenuShellInto` begins with
  ## `clearChildren(container)`: the flag stays true over a host that is now
  ## empty, which is exactly the state `shouldRemountDebugControls` exists to
  ## name. Measured: `mount COMPLETE` at boot, then `skipping (already
  ## mounted)` after the transition, with no toolbar on screen.
  ##
  ## So this asks the predicate the same question `requestDebugControlsRender`
  ## asks, and clears the flag before re-mounting when the host has been
  ## emptied underneath it. A no-op when the toolbar is genuinely up.
  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugControlsHostId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return
  if not shouldRemountDebugControls(
      isoNimDebugMounted,
      not dom_api.isNodeNil(dom_api.Node(container).firstChild)):
    return
  isoNimDebugMounted = false
  tryMountIsoNimDebugControls()

proc refreshTopbarSurface*() =
  ## Re-mount when the host is showing the WRONG surface.
  ##
  ## WHY THIS CANNOT GO THROUGH `shouldRemountDebugControls`. That predicate is
  ## `not (mounted and hostHasChildren)` — it exists to notice a host that a
  ## menu-shell rebuild emptied underneath a still-`true` flag. After a mode
  ## switch neither term helps: the flag is true and the host is full, because
  ## the PREVIOUS mode's panel is sitting in it. Asking that question here
  ## would return false every time and the debugger controls would stay on
  ## screen in Edit mode — which is the bug report, reintroduced one layer up.
  ##
  ## So the question this asks is the other one: is what is mounted what the
  ## mode calls for. A no-op when they already agree, which is what makes it
  ## safe to call from every transition rather than from a chosen few.
  if not isoNimDebugMounted:
    # Nothing is up yet; the pending mount will read the mode itself.
    tryMountIsoNimDebugControls()
    return
  if currentTopbarSurface() == mountedTopbarSurface:
    return
  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugControlsHostId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return
  cdebug "refreshTopbarSurface: " & $mountedTopbarSurface & " -> " &
    $currentTopbarSurface()
  isoNimDebugMounted = false
  tryMountIsoNimDebugControls()

proc initDebugControlsVM() =
  ## Lazily create the parallel DebugControlsVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initDebugControlsVMWithStore`.
  if debugControlsVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  debugControlsVMStore = createReplayDataStore(stubBackend)
  debugControlsVMInstance = createDebugControlsVM(debugControlsVMStore)
  clog "DebugControlsVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimDebugControls()

proc syncDebugControlsPosition(rrTicks: int, path: cstring, line: int;
                               sourceGeneration: int = 0;
                               sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the DebugControlsVM's reactive memos see the updated state.
  if debugControlsVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  debugControlsVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  clog fmt"DebugControlsVM: synced debugger rrTicks={ticks}"

proc rewireDebugControlsBridgeForActiveSession*(data: Data) =
  ## Re-bind singleton debug chrome callbacks after session switching.
  ##
  ## The caption toolbar is mounted once outside each GoldenLayout tree, while
  ## the DebugComponent/Mediator pair is owned by the active ReplaySession.
  ## After switching away to a welcome tab and back, clicks and shortcuts must
  ## emit through the restored session's mediator.
  # EVERY REFUSAL SAYS SO. This proc installs the callbacks that every
  # non-step button on the debugger toolbar dispatches through, so a silent
  # `return` here leaves a fully painted, hit-testable toolbar whose buttons
  # reach nothing — and leaves no trace of why. That shape cost this campaign
  # a wrong root cause: `not ...hasKey(0)` was proposed as the reason Stop did
  # nothing, and a browser measurement showed the opposite
  # (`debugHasKey0=true`, bridge installed, and the click never produced a
  # `click` event at all). A refusal that names itself is what makes the next
  # such guess checkable in one run instead of one rebuild.
  if data.isNil or data.ui.isNil:
    cwarn "debug-bridge: no session, so the toolbar's non-step buttons stay unwired"
    return
  if not data.ui.componentMapping[Content.Debug].hasKey(0):
    cwarn "debug-bridge: no Debug component at id 0, so the toolbar's " &
      "non-step buttons (run-to-entry, reset-operation, run-tests, Stop) " &
      "stay unwired"
    return

  let component = DebugComponent(data.ui.componentMapping[Content.Debug][0])
  # THE TWO CALLBACKS DO NOT HAVE THE SAME PREREQUISITE, and treating them as
  # if they did left the whole toolbar dead on the web.
  #
  # This guard used to read `if component.isNil or component.api.isNil: return`,
  # so a nil mediator skipped BOTH callbacks. But `onAction` calls
  # `component.action(id)` and never touches `api` — only `onDapStep`'s
  # `dapStep(api, action)` does. A platform that has a `DebugComponent` and no
  # mediator therefore lost the non-step half of the toolbar (run-to-entry,
  # reset-operation, run-tests, and Stop) for a reason that applies only to the
  # step half.
  #
  # THE EVIDENCE THIS PARAGRAPH USED TO CITE WAS NOT EVIDENCE OF THIS, and the
  # correction is left here rather than deleted because the same reading would
  # otherwise be made again.
  #
  # It read: "pressing Stop in a Noir Studio replay session did nothing —
  # measured in a browser, the button mounted, hit-tested, took a real pointer
  # click at its own centre, and the topbar stayed `debugger-controls` through
  # a 20s wait on each of three trips". Every clause is true and the conclusion
  # does not follow. `ci/test/noir-mode-roundtrip.sh` reported `clicked: true`
  # for a gesture that produced NO `click` event: its `blurEditor` pressed
  # `#menu`, `#isonim-debug-controls` is a child of `#menu`, and the resulting
  # menu-shell rebuild replaced the toolbar between the gesture's `mousedown`
  # and its `mouseup`, which is a case in which browsers fire no `click` at
  # all. The button was never pressed.
  #
  # Re-measured against the same bundle with the blur removed, the whole return
  # leg works and this bridge is why: `actionClick fired action=stop
  # onActionNil=false` -> `DebugComponent.action id=stop` ->
  # `stopReplaySession entered mode=DebugMode` -> `switchToEdit` ->
  # `refreshTopbarSurface tsDebuggerControls -> tsEditCommands`, and the panes
  # and the Run button came back. So the guard below is still correct — a nil
  # mediator must not cost the non-step half of the toolbar — but it is not
  # what that measurement showed.
  if component.isNil:
    cwarn "debug-bridge: the Debug component at id 0 is nil, so the " &
      "toolbar's non-step buttons stay unwired"
    return

  initDebugControlsVM()
  debugComponentForBridge = component
  debugApiForBridge = component.api
  if not debugControlsVMInstance.isNil:
    # Unconditional: this half needs nothing but the component.
    debugControlsVMInstance.onAction = proc(id: string) =
      component.action(id)
    # Conditional: `dapStep` sends through the mediator, so without one there
    # is nothing to send on, and a closure over a nil `api` would raise on the
    # first step rather than decline.
    if not component.api.isNil:
      debugControlsVMInstance.onDapStep = proc(action: cstring) =
        dapStep(component.api, action)
    wireDebugToolbarShortcuts()

proc jumpBeforeList*(self: DebugComponent) =
  self.after = false
  self.before = true
  self.data.redraw()

proc jumpAfterList*(self: DebugComponent) =
  self.before = false
  self.after = true
  self.data.redraw()

proc stopJump*(self: DebugComponent) =
  self.before = false
  self.after = false
  self.data.redraw()

proc resetOperation*(self: DebugComponent) =
  clog "reset-operation: for now restarting replay-server"
  self.data.restartSubsystem(name="replay-server")
  if self.jumpHistory.len != 0:
    self.jumpHistory[^1].lastOperation = cstring"reset-operation"

  # previously called like that, outdated now:
  #   this is specifically for the "full reset operation":
  #   self.service.resetOperation(full=true, resetLastLocation=true, taskId=taskId)

proc runToEntry*(self: DebugComponent) =
  self.api.emit(CtRunToEntry, EmptyArg())
  self.api.emit(InternalNewOperation, NewOperation(name: "run to entry", stableBusy: true))

proc historyJump(self: DebugComponent, location: types.Location) =
  self.api.historyJump(location)

proc handleHistoryJump*(self: DebugComponent, direction: HistoryDirection) =
  ## Move the history cursor one entry and jump to what is there.
  ##
  ## Took an `isForward: bool` whose `true` branch moved BACKWARDS; see
  ## `history_cursor`'s header for that inversion, the second one that
  ## cancelled it, and why the parameter is now an enum named for the
  ## sequence rather than for the gesture.
  let nextIndex = nextHistoryIndex(
    self.jumpHistory.len, self.historyIndex, direction)
  if nextIndex == 0:
    # Refused: the cursor is already on the oldest or the newest entry. Doing
    # nothing rather than re-jumping to the location already showing.
    return
  self.historyIndex = nextIndex
  self.historyJump(self.jumpHistory[^nextIndex].location)

proc action(self: DebugComponent, id: string) =
  case id:
  of "reset-operation": self.resetOperation()

  # TODO: a special case: or remove, as currently we
  #   directly restart replay-server anyway?
  #   or make several options for
  #     * ) again, restoring a more gradual/internal for replay-server restart
  #     * ) replay-server restart
  #     * ) session-manager (+ replay-server) restart
  # ?
  of "full-reset-operation": self.resetOperation()

  of "stop": stopAction()

  of "jump-before": self.jumpBeforeList()

  of "jump-after": self.jumpAfterList()

  of "run-to-entry": self.runToEntry()

  of "run-tests":
    # copied from alt+l shorcut handling in shortcuts.nim
    let options = RunTestOptions(newWindow: true, path: data.services.debugger.location.path, testName: "")
    self.isLoading = true
    data.runTests(options)
    # TODO: For now hardcode the animation reset
    discard setTimeout(proc() =
      self.isLoading = false
      self.requestDebugActionRefresh(),
      10000
    )

  # ONE MAPPING, in `history_cursor`, where a unit lane can state it. This
  # `case` used to map `"history-back"` to `isForward = true` — the second of
  # the two cancelling inversions.
  of HistoryBackActionId, HistoryForwardActionId:
    self.handleHistoryJump(historyDirectionOfAction(id))

  else:
    discard

proc invokeDebugToolbarAction*(id: string) =
  ## Run a debug-toolbar action by the SAME id the toolbar button dispatches.
  ##
  ## This exists so a keyboard chord and a click cannot diverge. The five
  ## toolbar controls that gained chords (`history-back`, `history-forward`,
  ## `run-to-entry`, `reset-operation`, `run-tests`) are dispatched by their
  ## buttons through `DebugControlsVM.onAction`, which every bridge site in
  ## this module wires to `component.action(id)` — the private `case` above.
  ## Routing `data.actions[...]` here rather than reimplementing the bodies
  ## means the tooltip's promise ("this chord does what this button does") is
  ## true by construction rather than by two copies agreeing.
  ##
  ## No-ops before a `DebugComponent` is registered — the same nil-guard shape
  ## the `onAction` bridge sites above already use. A chord pressed on the
  ## welcome screen does nothing, which is what the disabled button does too.
  if not debugComponentForBridge.isNil:
    debugComponentForBridge.action(id)

func toDapStepActionEnum(action: cstring): Result[CtEventKind, cstring] =
  case $action:
  of "step-in": result.ok(DapStepIn)
  of "step-out": result.ok(DapStepOut)
  of "next": result.ok(DapNext)
  of "continue": result.ok(DapContinue)
  of "reverse-step-in": result.ok(CtReverseStepIn)
  of "reverse-step-out": result.ok(CtReverseStepOut)
  of "reverse-next": result.ok(DapStepBack)
  of "reverse-continue": result.ok(DapReverseContinue)
  else: result.err(cstring(fmt"not added dap equivalent for {action} for now"))

when defined(js):
  ## Mirror DAP step actions into the Playwright-visible request log
  ## installed by ``ui_js.nim``'s ``recordVmBackendRequest`` so that
  ## M4 keyboard-focus specs can observe F10 / step shortcuts that
  ## ride the DAP bridge instead of the RealBackendService channel.
  ## Without this mirror the production code still fires the step
  ## correctly, but the test sees an empty log.
  proc recordDapStep(action: cstring) {.importjs: """
    (function(action) {
      if (typeof window === "undefined") return;
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      var arr = window.__CODETRACER_TEST__.vmBackendRequests || [];
      arr.push({ command: String(action || ""), args: {}, source: "dapStep" });
      window.__CODETRACER_TEST__.vmBackendRequests = arr;
    })(#);
  """.}

proc dapStep*(api: MediatorWithSubscribers, action: cstring) =
  ## Issue a DAP step (`next`, `stepIn`, `stepOut`, `continue` and their
  ## reverse counterparts) through the mediator API.
  ##
  ## Serialization (FU-E): rapid successive step requests — e.g. the user
  ## clicking step-over multiple times in quick succession or holding the
  ## F10 key — used to race past one another:
  ##   1. The first request was sent to the replay backend.
  ##   2. Before its `stopped` / `CtCompleteMove` notification arrived,
  ##      a second `next` was fired on top of it.
  ##   3. The UI's `data.services.debugger.location` / status counters
  ##      could land on a stale value, and occasionally two requests
  ##      crossed paths so that one was silently dropped by the backend.
  ##
  ## The middleware sets `data.status.stableBusy = true` for every step
  ## (via the `InternalNewOperation(stableBusy: true)` emit below) and
  ## resets it to `false` only after the next `CtCompleteMove` arrives
  ## (see `middleware.nim` — the `CtCompleteMove` handler). We treat
  ## that flag as the in-flight guard for the DAP step pipeline: a
  ## fresh step is accepted only when no prior step is still pending.
  ##
  ## We deliberately skip the guard during Playwright/headless tests
  ## that bypass the real status pipeline (e.g. when `data` is nil) so
  ## the existing scripted step sequences keep working unchanged.
  when defined(js):
    if not data.isNil and not data.status.isNil and data.status.stableBusy:
      clog "dapStep: prior step in flight, dropping rapid duplicate " &
        $action
      return
  echo "dap step ", action
  when defined(js):
    if not data.isNil and data.startOptions.inTest:
      recordDapStep(action)
  let dapActionRes = toDapStepActionEnum(action)
  if dapActionRes.isOk:
    let dapAction = dapActionRes.value
    # for now hardcoded threadId, eventually base on location/other
    if not api.isNil:
      api.emit(dapAction, DapStepArguments(threadId: 1))
      api.emit(InternalNewOperation, NewOperation(name: action, stableBusy: true))
  else:
    cerror cstring(fmt"dap step to action enum error: {dapActionRes.error}")

proc resetJumpHistoryFromStartIndex(self: DebugComponent) =
  let startIndex = self.jumpHistory.len - self.historyIndex + 1

  if self.jumpHistory.len > startIndex:
    self.jumpHistory.delete(startIndex ..< self.jumpHistory.len)
  self.historyIndex = 1

method resetBeforeRestart*(self: DebugComponent) =
  self.jumpHistory = @[]
  self.currentOperation = nil
  # not sure why 1, but resetJumpHistoryFromStartIndex does it
  # and that's what the onCompleteMove checks for
  self.historyIndex = 1

method onCompleteMove*(self: DebugComponent, response: MoveState) {.async.} =
  # Feed the same position into the parallel ViewModel store.
  initDebugControlsVM()
  syncDebugControlsPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line,
    response.location.sourceGeneration,
    response.location.sourceDigest)

  echo "onCompleteMove for debug "
  console.log(response.location)
  if self.jumpHistory.len() > 0:
    console.log(self.jumpHistory[^1].location)
  if self.jumpHistory == @[] or response.location != self.jumpHistory[^1].location:
    if self.currentOperation != HISTORY_JUMP_VALUE:
      echo "in if"
      if self.historyIndex != 1:
        self.resetJumpHistoryFromStartIndex()
      let action = if self.currentOperation.isNil:
          cstring""
        else:
          self.currentOperation
      echo "action ", action
      self.jumpHistory.add(
        JumpHistory(
          location: response.location,
          lastOperation: action
        )
      )
      console.log cstring"after add", self.jumpHistory

method register*(self: DebugComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )

  # Wire up the legacy bridge callbacks on the DebugControlsVM so that
  # IsoNim view button clicks route through the existing DAP event mediator.
  # We also memoise `self` and `api` so that any later
  # `initDebugControlsVMWithStore` call (which replaces the VM instance
  # with a shared-store one) can re-apply the bridge — see the
  # `debugComponentForBridge` / `debugApiForBridge` doc above for the
  # TODO 5.2(i) failure mode this fixes.
  initDebugControlsVM()
  debugComponentForBridge = self
  debugApiForBridge = api
  if not debugControlsVMInstance.isNil:
    debugControlsVMInstance.onDapStep = proc(action: cstring) =
      dapStep(api, action)
    debugControlsVMInstance.onAction = proc(id: string) =
      self.action(id)
    wireDebugToolbarShortcuts()
