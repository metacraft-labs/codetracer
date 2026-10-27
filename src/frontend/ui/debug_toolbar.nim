## ui/debug_toolbar.nim — the desktop's part of the debugger toolbar.
##
## The toolbar's state and actions are `DebugControlsVM`'s, for every
## front-end alike: the jump history and its lists, a pending test run, which
## surface the topbar shows (Shared-DOM-Front-Ends D7.1). What is left here is
## what only this renderer can do:
##
## - `desktopDebugCommands`: the actions' desktop routes — a step through the
##   DAP mediator of the tab on screen (`toolbarApiFor`) with the operation
##   status the status bar shows, the replay server's restart, leaving the
##   session, the test run in a new window — handed to the session before it
##   builds the VM (D6);
## - `bindDebugToolbar` / `ensureDebugToolbar`: the topbar rendered into the
##   menu shell's host (`renderTopbar`), in a reactive root this module
##   disposes when the host's session changes;
## - the chord labels the tooltips read, the layout mode the surface follows,
##   and the debug shell's command-palette chrome.
##
## There is no component and no mount poll: the menu shell creates the host,
## and `ensureDebugToolbar` fills it the moment it exists.

import std/strformat

import results

import ui_imports, chord_display, command
import ./panel_host
import ../[renderer, communication, event_helpers]
import ../../common/ct_event
from shortcut_labels import toolbarChord
from menu_render_gate import shouldFillToolbarHost

import isonim/core/[signals, owner]
import isonim/web/web_renderer
from isonim/web/dom_api import nil

import ../viewmodel/store/replay_data_store
import ../viewmodel/store/types as store_types
import ../viewmodel/viewmodels/[debug_controls_vm, edit_mode_toolbar]
import ../viewmodel/views/isonim_debug_controls_view
from ../viewmodel/views/isonim_debug_shell_view import
  DebugShellId, commandPaletteHostId, renderDebugChromeInto
from ../viewmodel/views/isonim_menu_shell_view import DebugControlsHostId

export debug_controls_vm

var toolbarVM: DebugControlsVM
  ## The shown session's toolbar ViewModel; nil before a session exists.
var toolbarHost: dom_api.Element
  ## The host the topbar was last rendered into.
var toolbarRootDispose: proc()
  ## Disposes the topbar's reactive root.
var pendingEditToolbar: tuple[model: EditToolbarModel, invoke: proc(id: string),
                              installed: bool]
  ## An edit-mode toolbar a platform installed before a session existed.
var pendingTestRun: proc(succeeded: bool)
  ## The toolbar's test run's completion, until the index settles the run.
var debugShellMountedCommandPaletteId = -2

# ---------------------------------------------------------------------------
# The desktop's routes for the toolbar's actions
# ---------------------------------------------------------------------------

func toDapStepActionEnum(action: string): Result[CtEventKind, string] =
  case action
  of "step-in": result.ok(DapStepIn)
  of "step-out": result.ok(DapStepOut)
  of "next": result.ok(DapNext)
  of "continue": result.ok(DapContinue)
  of "reverse-step-in": result.ok(CtReverseStepIn)
  of "reverse-step-out": result.ok(CtReverseStepOut)
  of "reverse-next": result.ok(DapStepBack)
  of "reverse-continue": result.ok(DapReverseContinue)
  else: result.err(fmt"no DAP step for {action}")

proc recordDapStep(action: cstring) {.importjs: """
  (function(action) {
    if (typeof window === "undefined") return;
    window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
    var arr = window.__CODETRACER_TEST__.vmBackendRequests || [];
    arr.push({ command: String(action || ""), args: {}, source: "dapStep" });
    window.__CODETRACER_TEST__.vmBackendRequests = arr;
  })(#);
""".}

proc dapStep*(api: MediatorWithSubscribers; action: string) =
  ## A DAP step (`next`, `stepIn`, … and the reverse ones) through the
  ## mediator, with the operation status the status bar shows.
  ##
  ## SERIALIZED (FU-E): the middleware sets `data.status.stableBusy` for every
  ## step and clears it when the next `CtCompleteMove` arrives, and a step
  ## asked for while one is in flight is dropped — two crossing requests
  ## could land the UI on a stale position or be dropped by the backend.
  if not data.isNil and not data.status.isNil and data.status.stableBusy:
    clog "dapStep: prior step in flight, dropping rapid duplicate " & action
    return
  if not data.isNil and data.startOptions.inTest:
    recordDapStep(cstring(action))
  let kind = toDapStepActionEnum(action)
  if kind.isErr:
    cerror kind.error
    return
  if not api.isNil:
    api.emit(kind.value, DapStepArguments(threadId: 1))
    api.emit(InternalNewOperation,
             NewOperation(name: cstring(action), stableBusy: true))

var toolbarApis: seq[tuple[viewsApi, api: MediatorWithSubscribers]]
  ## The toolbar's mediator onto each tab's views mediator, made the first
  ## time the toolbar dispatches into that tab and reused after it.

proc toolbarApiFor*(data: Data): MediatorWithSubscribers =
  ## The mediator the toolbar's replay actions are emitted on: one onto the
  ## views mediator of the tab ON SCREEN, looked up when the action is
  ## dispatched; nil while there is no tab.
  ##
  ## LOOKED UP PER DISPATCH, NEVER CAPTURED. The window has one toolbar and
  ## every replay tab has its own `viewsApi` and `DapApi`
  ## (`event_helpers.attachSessionApis`), so a mediator captured when the
  ## toolbar's routes are built belongs to whichever tab was on screen then:
  ## a step clicked in a later tab moved the first tab's replay, out of
  ## sight, while the step's chord (`renderer.step`, which sends on
  ## `data.dapApi`) moved the tab on screen. Before the toolbar was a
  ## ViewModel, `switchSession` re-pointed it at the target tab's own
  ## mediator on every switch; reading the active tab here keeps that
  ## contract with no re-pointing step to forget.
  ##
  ## What this guarantees is the TAB: the request goes to the views mediator
  ## of the tab on screen and never to another tab's. That mediator hands it
  ## to its tab's own replay through the handlers
  ## `middleware.setupMiddlewareApis` subscribes on it, installed for every
  ## tab's session (`ui_js.configureSessionMiddleware`).
  if data.isNil or data.activeSessionIndex < 0 or
      data.activeSessionIndex >= data.sessions.len:
    return nil
  let session = data.activeSession
  if session.isNil or session.viewsApi.isNil:
    return nil
  for entry in toolbarApis:
    if entry.viewsApi == session.viewsApi:
      return entry.api
  # A miss is a tab the toolbar has not dispatched into yet: drop the entries
  # of tabs closed since, so a closed tab's mediators are not kept alive.
  var live: seq[tuple[viewsApi, api: MediatorWithSubscribers]]
  for entry in toolbarApis:
    for tab in data.sessions:
      if not tab.isNil and tab.viewsApi == entry.viewsApi:
        live.add(entry)
        break
  toolbarApis = live
  result = setupLocalViewToMiddlewareApi(cstring"debug toolbar api",
                                         session.viewsApi)
  toolbarApis.add((session.viewsApi, result))

proc desktopDebugCommands*(data: Data; store: ReplayDataStore): DebugCommands =
  ## The desktop's routes, for `SessionViewModel.debugCommands`. The ones that
  ## reach a replay go to the tab on screen (`toolbarApiFor`).
  result = defaultDebugCommands(store)
  result.step = proc(actionId: string) =
    # No tab, no step: `dapStep` reads the active tab's status first.
    let api = toolbarApiFor(data)
    if api.isNil:
      return
    dapStep(api, actionId)
  result.runToEntry = proc() =
    let api = toolbarApiFor(data)
    if api.isNil:
      return
    api.emit(CtRunToEntry, EmptyArg())
    api.emit(InternalNewOperation,
             NewOperation(name: "run to entry", stableBusy: true))
  result.reset = proc() =
    clog "reset-operation: restarting replay-server"
    data.restartSubsystem(name = "replay-server")
  result.stop = proc() = stopAction()
  result.runTests = proc(done: proc(succeeded: bool)) =
    pendingTestRun = done
    data.runTests(RunTestOptions(
      newWindow: true, path: data.services.debugger.location.path,
      testName: ""))
  result.historyJump = proc(entry: JumpEntry) =
    let api = toolbarApiFor(data)
    if api.isNil:
      return
    api.historyJump(types.Location(
      path: cstring(entry.location.file), line: entry.location.line,
      rrTicks: int(entry.rrTicks),
      sourceGeneration: entry.location.sourceGeneration,
      sourceDigest: cstring(entry.location.sourceDigest)))

proc settleToolbarTestRun*(succeeded: bool) =
  ## The index reports a test run finished (`CODETRACER::test-run-settled`):
  ## the toolbar's run is no longer pending.
  if not pendingTestRun.isNil:
    let done = pendingTestRun
    pendingTestRun = nil
    done(succeeded)

# ---------------------------------------------------------------------------
# The topbar in the menu shell's host
# ---------------------------------------------------------------------------

proc wireDebugToolbarShortcuts*() =
  ## Point the tooltips at the chords currently bound, and tell them the
  ## bindings changed (a new `Config` was installed).
  if toolbarVM.isNil:
    return
  toolbarVM.shortcutFor = proc(actionId: string): string =
    toolbarChord(proc(a: ClientAction): string = $displayedChord(a), actionId)
  toolbarVM.shortcutsRevision.val = toolbarVM.shortcutsRevision.val + 1

proc syncToolbarMode*() =
  ## The topbar's surface follows the layout mode (`ToolbarMode` mirrors
  ## `LayoutMode` ordinal for ordinal; `edit_mode_toolbar` asserts it).
  if toolbarVM.isNil or data.isNil or data.ui.isNil:
    return
  let mode = ToolbarMode(data.ui.mode.ord)
  if toolbarVM.toolbarMode.val != mode:
    toolbarVM.toolbarMode.val = mode

proc renderTopbarInto(host: dom_api.Element) =
  if not toolbarRootDispose.isNil:
    toolbarRootDispose()
    toolbarRootDispose = nil
  let node = dom_api.Node(host)
  while not dom_api.isNodeNil(node.firstChild):
    discard dom_api.removeChild(node, node.firstChild)
  toolbarHost = host
  let vm = toolbarVM
  createRoot proc(dispose: proc()) =
    toolbarRootDispose = dispose
    renderTopbar[WebRenderer, dom_api.Element](WebRenderer(), host, vm)

proc ensureDebugToolbar*() =
  ## Fill the menu shell's toolbar host if it is new. The shell keeps the
  ## host across its own re-renders, so a host already filled for this
  ## session is left alone.
  if toolbarVM.isNil:
    return
  let host = dom_api.getElementById(dom_api.document,
                                    cstring DebugControlsHostId)
  if dom_api.isNodeNil(dom_api.Node(host)):
    return
  if not shouldFillToolbarHost(
      hostIsNew = host != toolbarHost,
      hostHasChildren = not dom_api.isNodeNil(dom_api.Node(host).firstChild)):
    return
  renderTopbarInto(host)

proc bindDebugToolbar*(vm: DebugControlsVM) =
  ## Show `vm`'s toolbar: the session that is now on screen. The host is
  ## re-filled when the session changes.
  if vm.isNil or vm == toolbarVM:
    return
  toolbarVM = vm
  toolbarHost = nil
  if pendingEditToolbar.installed:
    vm.setEditToolbar(pendingEditToolbar.model, pendingEditToolbar.invoke)
  wireDebugToolbarShortcuts()
  syncToolbarMode()
  ensureDebugToolbar()

proc setEditModeToolbar*(model: EditToolbarModel; invoke: proc(id: string)) =
  ## Install (or replace) the edit-mode toolbar a platform composed. The
  ## model is a value, so every change that could alter it arrives as a new
  ## model, and the topbar's buttons follow it in place.
  pendingEditToolbar = (model, invoke, true)
  if not toolbarVM.isNil:
    toolbarVM.setEditToolbar(model, invoke)

var editToolbarComposer: proc()
  ## Recompose the edit-mode topbar from the session as it is now. Each
  ## platform composes its own model — the web studio in `ui/web_noir_build`,
  ## the Electron desktop in `ui/desktop_edit_toolbar` — so the platform
  ## installs its composer here with `installEditToolbarComposer`, and every
  ## site that changes an input reaches it through `refreshEditToolbar`
  ## without importing either module. Nil on a platform that composes no
  ## model, which then keeps the debugger controls.

proc installEditToolbarComposer*(compose: proc()) =
  ## Install (or replace) the platform's edit-mode composer.
  editToolbarComposer = compose

proc refreshEditToolbar*() =
  ## Run the installed composer, if there is one. A failure to compose is
  ## reported and contained: every caller is in the middle of something that
  ## matters more — a session starting, a mode or tab switch, a save — and a
  ## toolbar model that cannot be built must not abort it.
  if editToolbarComposer.isNil:
    return
  #
  # A bare `except`: what a composer throws in a renderer is as likely a
  # native JavaScript `TypeError` (a field missing from an IPC payload) as a
  # Nim exception.
  try:
    editToolbarComposer()
  except:
    cerror "edit toolbar: could not recompose: " & getCurrentExceptionMsg()

proc syncTopbarToMode*() =
  ## THE TOPBAR FOLLOWS THE MODE, RE-DERIVED: the toolbar is re-derived from
  ## the mode, never patched. `EditToolbarModel` is a value composed for one
  ## mode — Build and Run are in its slot set only when it was composed in an
  ## editing mode — so a model composed in Debug mode and merely re-shown in
  ## Edit mode is an edit bar with no buttons. Recompose FIRST, then move the
  ## surface, so no step in between shows a bar built for the mode being left.
  ##
  ## Called wherever `data.ui.mode` may now read differently: a mode switch,
  ## an edit session starting, and a session-tab switch, since the mode is
  ## per session and the topbar is shared by all of them. `syncToolbarMode`
  ## alone is a no-op when the mode did not change.
  refreshEditToolbar()
  syncToolbarMode()

# ---------------------------------------------------------------------------
# Routes into the toolbar from chords and mouse buttons
# ---------------------------------------------------------------------------

proc invokeDebugToolbarAction*(id: string) =
  ## Run a toolbar action by the SAME id its button dispatches, so a chord and
  ## a click cannot diverge. No-op before a session exists, as the disabled
  ## button is.
  if not toolbarVM.isNil:
    toolbarVM.invokeToolbarAction(id)

proc invokeDebugStepAction*(action: cstring): bool =
  ## A step by its toolbar id; `false` when no session can take it.
  if toolbarVM.isNil:
    return false
  toolbarVM.invokeToolbarStep($action)
  true

proc moveInDebugHistory*(direction: HistoryDirection) =
  ## The mouse's back and forward buttons.
  if not toolbarVM.isNil:
    toolbarVM.moveInHistory(direction)

# ---------------------------------------------------------------------------
# The debug shell's chrome (the command palette's host)
# ---------------------------------------------------------------------------

proc requestDebugShellRender*() =
  ## Render the debug chrome into `#debug` when its command-palette host is
  ## missing or names another palette.
  let commandPaletteId =
    if not data.ui.commandPalette.isNil: data.ui.commandPalette.id else: -1
  let expectedHost = commandPaletteHostId(commandPaletteId)
  if debugShellMountedCommandPaletteId == commandPaletteId:
    let host = dom_api.getElementById(dom_api.document, cstring expectedHost)
    if not dom_api.isNodeNil(dom_api.Node(host)):
      return
  let container = dom_api.getElementById(dom_api.document,
                                         cstring DebugShellId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return
  renderDebugChromeInto(WebRenderer(), container, commandPaletteId)
  debugShellMountedCommandPaletteId = commandPaletteId
  # The palette's host exists now: the panel host mounts the palette into it
  # (or as soon as the session exists), synchronously — no poll.
  if commandPaletteId >= 0:
    let host = dom_api.getElementById(dom_api.document, cstring expectedHost)
    if not dom_api.isNodeNil(dom_api.Node(host)):
      ensurePanelMounted(host, Content.CommandPalette)
