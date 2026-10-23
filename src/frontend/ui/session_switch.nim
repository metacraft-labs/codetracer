## Session switching for multi-replay sessions (M11).
##
## Implements the hide/show approach: each session keeps its own GL
## container alive in the DOM.  Switching sessions toggles CSS visibility
## on the per-session container divs instead of destroying and recreating
## the GoldenLayout instance.  This preserves Monaco editors and all
## GL-managed component state across tab switches.
##
## Each session owns its ViewModels (`session_viewmodels.nim`), so a switch
## does not copy any pane state between tabs: it shows the target's container
## and points the window's pane bridges at the target's ViewModels
## (`setSessionBindProc`, installed by `ui_js` — rule 2 of
## `GUI/Multi-Window-Tab-Management.md` §Tab Behavior: clicking a tab switches
## all panels to that session's data). What the tab being left showed stays in
## its own ViewModels (rule 6).
##
## To avoid circular imports (layout -> session_tabs -> session_switch ->
## layout), the actual ``initLayout`` call is wired in at runtime via
## ``setInitLayoutProc``.

import
  std/[strformat, jsffi, asyncjs],
  ../types,
  ../dap,
  ../event_helpers,
  ../renderer,
  menu,
  debug_toolbar,
  welcome_screen,
  search_results,
  session_viewmodels,
  panel_host,
  ../utils,
  ../lib/[logging, jslib]

from isonim/web/dom_api import nil
from ./tab_answer_routing import deliverPendingTabAnswers
from ./test_results import forgetTestResultsVM

import kdom except Location

# ---------------------------------------------------------------------------
# Deferred dependency on initLayout (avoids circular import)
# ---------------------------------------------------------------------------

type
  InitLayoutProc = proc(config: GoldenLayoutResolvedConfig,
                        containerElement: kdom.Element = nil) {.nimcall.}
  EnsureTabBarRendererProc = proc() {.nimcall.}
  SessionBindProc* = proc(session: ReplaySession)
    ## Point the window's pane bridges at `session`'s ViewModels.

var initLayoutImpl: InitLayoutProc = nil
var ensureTabBarRendererImpl: EnsureTabBarRendererProc = nil
var sessionBindImpl: SessionBindProc = nil

proc setInitLayoutProc*(p: InitLayoutProc) =
  ## Called once from layout.nim to wire in the real ``initLayout``.
  initLayoutImpl = p

proc setEnsureTabBarRendererProc*(p: EnsureTabBarRendererProc) =
  ## Called once from layout.nim to wire in the tab-bar renderer setup.
  ## This allows session creation to ensure the session-tab-bar
  ## direct mount exists even when ``initLayout`` is not called.
  ensureTabBarRendererImpl = p

proc setSessionBindProc*(p: SessionBindProc) =
  ## Called once by `ui_js` to wire in `bindWindowToSession`, which knows
  ## every pane module the window's bridges reach and which this module
  ## cannot import.
  sessionBindImpl = p

proc bindWindowTo(session: ReplaySession) =
  if not sessionBindImpl.isNil:
    try:
      sessionBindImpl(session)
    except CatchableError as e:
      cerror "session_switch: binding the window to the shown tab failed: " &
        e.msg

proc refreshSessionTabBar() =
  if not ensureTabBarRendererImpl.isNil:
    ensureTabBarRendererImpl()

# ---------------------------------------------------------------------------
# Session container helpers
# ---------------------------------------------------------------------------

proc sessionContainerId(index: int): cstring =
  ## DOM id for the session's GL container element.
  cstring("session-container-" & $index)

proc getSessionContainer(index: int): kdom.Element =
  ## Look up an existing session container by index.  May return nil.
  document.getElementById(sessionContainerId(index))

proc createSessionContainer(index: int): kdom.Element =
  ## Create a new session container div inside ``#ROOT`` and return it.
  ## The container starts hidden (CSS class ``hidden``) — the caller is
  ## responsible for showing it when it becomes the active session.
  ## GoldenLayout will create its own DOM structure inside the container
  ## when ``loadLayout`` is called, so no inner elements are needed.
  let container = document.createElement("div")
  container.id = sessionContainerId(index)
  container.class = cstring"session-container hidden"

  let root = document.getElementById(cstring"ROOT")
  if not root.isNil:
    root.appendChild(container)

  return container

proc destroySessionContainer(index: int) =
  ## Remove a session's GL container from the DOM and destroy its GL
  ## instance.  Used when closing a session tab.
  let container = getSessionContainer(index)
  if container.isNil:
    return
  container.parentNode.removeChild(container)

proc callInitLayoutUnchecked(config: GoldenLayoutResolvedConfig,
                              container: kdom.Element) =
  ## Thin wrapper that calls ``initLayoutImpl`` as a normal Nim call.
  ## Exists so that ``callInitLayoutSafe`` can reference the call site
  ## inside a JS-level try/catch without emit-level variable resolution
  ## issues.
  initLayoutImpl(config, container)

proc callInitLayoutSafe(config: GoldenLayoutResolvedConfig,
                        container: kdom.Element): bool =
  ## Call initLayoutImpl wrapped in a JS-level try/catch to handle both
  ## Nim exceptions and native JS errors (e.g. from GoldenLayout).
  ## Returns true on success, false if an error was caught.
  if initLayoutImpl.isNil:
    return false
  # We use raw JS emit because Nim's ``except Exception:`` does not catch
  # native JS errors (TypeError, RangeError, etc.) — only Nim-derived
  # Exception objects.  The ``initLayout`` proc can throw native JS errors
  # from GoldenLayout's ``loadLayout`` call.
  {.emit: """
    try {
      `callInitLayoutUnchecked`(`config`, `container`);
      `result` = true;
    } catch (e) {
      console.warn("session_switch: initLayout failed:", e?.message || String(e));
      `result` = false;
    }
  """.}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc switchSession*(data: Data, targetIndex: int)
  ## Forward declaration — defined below, called by createNewSession.

proc createNewSession*(data: Data) =
  ## Create a new, empty ReplaySession and switch to it.
  ##
  ## The new session is a blank slate: it has default services, an empty
  ## editor, and inherits the current session's GL layout config so that
  ## the panel arrangement is preserved.  The actual trace loading into
  ## this session is handled separately (e.g. via the trace selector or
  ## IPC).
  ##
  ## This implements the core of M12: clicking "+" in the tab bar creates
  ## a new tab backed by its own ReplaySession.
  # THE TAB'S POSITION AND ITS ID ARE TWO NUMBERS. The position (`index`) is
  # where it sits in `data.sessions` and which `session-container-<n>` holds
  # it, and shifts when a tab before it closes. The id names it to the main
  # process: its DAP requests carry it and its events come back tagged with it
  # (`event_helpers.deliverDapEvent`), so it must never be an id another open
  # tab holds — which `data.sessions.len` was, once a tab had closed: close
  # the middle of three tabs and the next new tab took the third's id, and
  # their events reached whichever matched first. One past the largest id in
  # use: equal to the position until a tab closes.
  let index = data.sessions.len
  var sessionId = index
  for open in data.sessions:
    if not open.isNil:
      sessionId = max(sessionId, int(open.id) + 1)
      if not open.dapApi.isNil:
        sessionId = max(sessionId, open.dapApi.sessionId + 1)
  var session = newReplaySession(ReplaySessionId(sessionId))
  # The tab's own DAP API and views mediator, wired so its backend notices
  # reach its own status bar: see `event_helpers.attachSessionApis`.
  attachSessionApis(session, sessionId, data.ipc)
  session.services = Services(
    eventLog: EventLogService(),
    debugger: DebuggerService(
      locals: @[],
      registerState: JsAssoc[cstring, cstring]{},
      valueHistory: JsAssoc[cstring, ValueHistory()]{},
      paths: @[],
      skipInternal: true,
      skipNoSource: false,
      historyIndex: 1),
    editor: EditorService(
      open: JsAssoc[cstring, TabInfo]{},
      loading: @[],
      completeMoveResponses: JsAssoc[cstring, MoveState]{},
      closedTabs: @[],
      saveHistoryTimeoutId: -1,
      switchTabHistoryLimit: 2000,
      expandedOpen: JsAssoc[cstring, TabInfo]{},
      cachedFiles: JsAssoc[cstring, TabInfo]{},
      sourceRevisionCache: JsAssoc[cstring, cstring]{},
      pendingDiskSourceByPath: JsAssoc[cstring, cstring]{},
      addedDiffId: @[],
      changedDiffId: @[],
      deletedDiffId: @[],
      index: 1),
    calltrace: CalltraceService(
      callstackCollapse: (name: cstring"", level: -1),
      callstackLimit: CALLSTACK_DEFAULT_LIMIT,
      calltraceJumps: @[cstring""],
      nonLocalJump: true,
      isCalltrace: true,
      loadingArgs: initJsSet[cstring]()),
    history: HistoryService(),
    flow: FlowService(),
    trace: TraceService(),
    search: SearchService(
      paths: JsAssoc[cstring, bool]{},
      pluginCommands: JsAssoc[cstring, SearchSource]{},
      activeCommandName: cstring"",
      selected: 0),
    shell: ShellService())
  # The back-references the first tab's services get when `utils` loads: a
  # service method reaches the window through `self.data` (the debugger
  # service's move handler reads `self.data.testRunner`, the editor service's
  # opens tabs through `self.data`), so a later tab's services need them as
  # soon as they follow that tab's moves (`wireSessionServiceMoves` below).
  for service in [Service(session.services.eventLog),
                  Service(session.services.debugger),
                  Service(session.services.editor),
                  Service(session.services.calltrace),
                  Service(session.services.history),
                  Service(session.services.flow),
                  Service(session.services.search)]:
    service.data = data
  session.services.eventLog.debugger = session.services.debugger
  # And the request cache `utils` gives the first tab's (`asyncSend`, which the
  # editor service reaches when it opens the file a move lands in).
  session.asyncSendCache = JsAssoc[cstring, JsAssoc[cstring, Future[JsObject]]]{}
  session.ui = Components(
    editors: JsAssoc[cstring, EditorViewComponent]{},
    idMap: JsAssoc[cstring, int]{value: 0, chart: 0},
    layoutSizes: LayoutSizes(startSize: true),
    monacoEditors: @[],
    traceMonacoEditors: @[],
    focusHistory: @[],
    editModeHiddenPanels: @[],
    editModeLayout: nil,
  )
  session.ui.menuNode = data.ui.menuNode
  session.ui.launchConfigs = data.ui.launchConfigs
  session.ui.mode = data.ui.mode
  session.ui.readOnly = data.ui.readOnly
  session.ui.fontSize = data.ui.fontSize
  # Initialize component mapping arrays — required by ``createUIComponents``
  # and ``generateId`` which access ``componentMapping[content]`` and expect
  # initialised JsAssoc objects, not nil/undefined.  Without this, the
  # first ``registerComponent`` call on the new session crashes with a
  # null-reference error.
  for content in Content:
    session.ui.componentMapping[content] = JsAssoc[int, Component]{}
    session.ui.openComponentIds[content] = @[]

  # Inherit page-readiness flags from the current session so that
  # initLayout's condition check is met.
  session.ui.pageLoaded = data.ui.pageLoaded
  session.ui.initEventReceived = data.ui.initEventReceived
  session.connection = ConnectionState(
    connected: true,
    reason: ConnectionLossNone,
    detail: cstring""
  )
  session.network = Network(
    futures: JsAssoc[cstring, JsAssoc[cstring, JsObject]]{})
  session.pointList = PointListData(
    tracepoints: JsAssoc[int, Tracepoint]{})
  session.status = StatusState(
    lastDirection: DebForward,
    currentOperation: cstring"",
    currentHistoryOperation: cstring"",
    finished: false,
    stableBusy: false,
    historyBusy: false,
    traceBusy: false,
    hasStarted: false,
    lastAction: cstring"",
    operationCount: 0,
  )
  session.startOptions = StartOptions(
    loading: false,
    screen: true,
    welcomeScreen: true,
    inTest: false,
    record: false,
    edit: false,
    name: cstring"",
    frontendSocket: SocketAddressInfo(),
    backendSocket: SocketAddressInfo(),
    idleTimeoutMs: 10 * 60 * 1_000)
  session.maxRRTicks = 100_000

  # Inherit the current session's layout config so the new tab has the
  # same panel arrangement.
  if not data.ui.layout.isNil and not data.ui.layoutConfig.isNil:
    try:
      let resolved = data.ui.layout.saveLayout()
      session.savedLayoutConfig = cast[GoldenLayoutResolvedConfig](
        data.ui.layoutConfig.fromResolved(resolved))
    except:
      cwarn "session_switch: saveLayout for new session failed: " &
        getCurrentExceptionMsg()
  if session.savedLayoutConfig.isNil:
    session.savedLayoutConfig = data.ui.resolvedConfig

  data.sessions.add(session)
  # Its legacy services follow ITS moves, as the first tab's do — the
  # callbacks copied from the tab it was opened from.
  wireSessionServiceMoves(data, session, data.activeSession.services)

  # Empty tabs still need the shared chrome and welcome screen components.
  # Component factory helpers write through Data's active-session forwarding,
  # so initialise the new session while it is temporarily active.
  let previousActiveSessionIndex = data.activeSessionIndex
  data.activeSessionIndex = index
  discard data.makeMenuComponent()
  discard data.makeBuildComponent()
  discard data.makeErrorsComponent()
  discard data.makeSearchResultsComponent()
  discard data.makeRequestPanelComponent(0)
  discard data.makeStatusComponent(
    data.buildComponent(0), data.errorsComponent(0), data.ui.searchResults)
  discard data.makeCommandPaletteComponent()
  discard data.makeWelcomeScreenComponent()
  data.activeSessionIndex = previousActiveSessionIndex

  clog "session_switch: created new session " & $sessionId &
    " at position " & $index & " (total: " & $data.sessions.len & ")"

  # Switch to the newly created session.
  switchSession(data, index)

proc closeSession*(data: Data, targetIndex: int) =
  ## Close the session at ``targetIndex``.  Destroys its GL container and
  ## removes it from the sessions list.  When the closed session is the
  ## active one, we switch to an adjacent session first.  Refuses to close
  ## the last remaining session.
  if data.sessions.len <= 1:
    # Last tab — nothing to close.
    return
  if targetIndex < 0 or targetIndex >= data.sessions.len:
    cwarn "session_switch: closeSession index out of bounds: " &
      $targetIndex & " (have " & $data.sessions.len & " sessions)"
    return

  clog "session_switch: closing session " & $targetIndex &
    " (total before: " & $data.sessions.len & ")"

  # Destroy the GL instance for the session being closed.
  let closingSession = data.sessions[targetIndex]

  # Tell the main process to stop the replay for this session so the
  # Backend Manager can reclaim the child process.
  if not data.ipc.isNil and not data.ipc.isUndefined:
    data.ipc.send(cstring"CODETRACER::close-replay-session",
                  js{"replayId": closingSession.replayId})
  # Detach every component of the closing session from its event bus before
  # the session object is dropped.  The session owns its own `viewsApi`, so
  # this is mostly hygiene rather than a cross-session leak — but the panel
  # sinks that mirror into module-global ViewModel instances (Scratchpad,
  # Trace Log, Request Panel) are shared by all sessions, and a component
  # that is still subscribed can write into the panel of a session the user
  # has already closed (#612).
  if not closingSession.ui.isNil:
    for content, mapping in closingSession.ui.componentMapping:
      if mapping.isNil:
        continue
      for id, component in mapping:
        if component.isNil:
          continue
        try:
          component.unregister()
        except:
          cwarn "session_switch: unregister failed for component " & $id &
            " of session " & $targetIndex

  if not closingSession.ui.layout.isNil:
    try:
      {.emit: [closingSession.ui.layout, ".destroy();"].}
    except:
      cwarn "session_switch: GL destroy failed for session " & $targetIndex

  # Dispose the panes the panel host rendered in the closed tab — GoldenLayout's
  # destroy above may not have reached every host (an auto-hide pin moves a
  # pane's DOM out of its container) — before their session goes.
  let closingContainer = getSessionContainer(targetIndex)
  if not closingContainer.isNil:
    panel_host.disposePanelsIn(cast[dom_api.Element](closingContainer))

  # Remove the DOM container for the closed session.
  destroySessionContainer(targetIndex)

  # If closing the active session, switch to an adjacent one first.
  if targetIndex == data.activeSessionIndex:
    let newActive = if targetIndex > 0: targetIndex - 1 else: targetIndex + 1
    switchSession(data, newActive)

  # THE CLOSED TAB'S VIEWMODELS GO WITH IT: its debugger session, its store
  # and every effect its panel ViewModels own. No other tab holds a reference
  # to them — each tab has its own (`session_viewmodels.nim`) and the window's
  # bridges were moved to the adjacent tab just above — so nothing in another
  # tab can keep feeding or reading them. The window's list of Test Results
  # ViewModels its host installers ran on lets go of this tab's first.
  let closingVMs = viewModelsOf(closingSession)
  if not closingVMs.isNil:
    forgetTestResultsVM(closingVMs.testResultsVM)
  disposeViewModels(closingSession)

  # Remove the session from the list.
  data.sessions.delete(targetIndex)

  # Adjust activeSessionIndex after the deletion.
  if data.activeSessionIndex >= data.sessions.len:
    data.activeSessionIndex = data.sessions.len - 1
  elif data.activeSessionIndex > targetIndex:
    data.activeSessionIndex -= 1

  # Renumber remaining session container IDs to match their new indices.
  # After a deletion, containers at indices > targetIndex have stale IDs.
  let root = document.getElementById(cstring"ROOT")
  if not root.isNil:
    for i in 0 ..< data.sessions.len:
      let container = getSessionContainer(i)
      if container.isNil:
        # Try the old index (shifted by 1 for containers after the deleted one).
        let oldIdx = if i >= targetIndex: i + 1 else: i
        let oldContainer = document.getElementById(
          cstring("session-container-" & $oldIdx))
        if not oldContainer.isNil:
          oldContainer.id = sessionContainerId(i)

  # The containers' numbers moved with the sessions' positions; each pane
  # still shows the session of the tab that holds it.
  panel_host.refreshPanelSessions()
  refreshSessionTabBar()
  redrawAfterSessionSwitch()

proc switchSession*(data: Data, targetIndex: int) =
  ## Switch from the currently active replay session to ``targetIndex``.
  ##
  ## Does nothing when the target is already active or the index is out
  ## of bounds.  Instead of destroying and recreating the GL layout, this
  ## hides the current session's container and shows the target's.
  ## Each session's GL instance stays alive in the DOM.
  if targetIndex == data.activeSessionIndex:
    return
  if targetIndex < 0 or targetIndex >= data.sessions.len:
    cwarn "session_switch: target index out of bounds: " &
      $targetIndex & " (have " & $data.sessions.len & " sessions)"
    return

  clog "session_switch: switching from session " &
    $data.activeSessionIndex & " to " & $targetIndex

  # 1. Hide the current session's container.
  let currentContainer = getSessionContainer(data.activeSessionIndex)
  if not currentContainer.isNil:
    currentContainer.classList.add(cstring"hidden")

  # 2. Switch active session index — all Data forwarding templates now
  #    resolve to the target session's fields — and point the window's pane
  #    bridges at the target's ViewModels. The tab being left keeps what it
  #    showed in its own ViewModels; there is nothing to save or restore.
  data.activeSessionIndex = targetIndex
  bindWindowTo(data.activeSession)

  # 3. Show (or create) the target session's container.
  var targetContainer = getSessionContainer(targetIndex)
  if targetContainer.isNil:
    # First activation — create the container and initialise GL.
    targetContainer = createSessionContainer(targetIndex)

    let session = data.activeSession
    if session.ui.pageLoaded and session.ui.initEventReceived:
      if session.ui.layout.isNil and not session.trace.isNil:
        # Session has a trace: create UI components and initialise GL.
        if not session.savedLayoutConfig.isNil:
          session.ui.resolvedConfig = session.savedLayoutConfig
        data.createUIComponents()
        let ok = callInitLayoutSafe(data.ui.resolvedConfig, targetContainer)
        if not ok:
          cwarn "switchSession: initLayout failed for session " & $targetIndex
      elif session.ui.layout.isNil and session.startOptions.welcomeScreen:
        # Empty welcome session: mount the welcome surface and shared chrome
        # without creating GoldenLayout.
        let ok = callInitLayoutSafe(session.savedLayoutConfig, targetContainer)
        if not ok:
          cwarn "switchSession: welcome initLayout failed for session " &
            $targetIndex
      elif session.ui.layout.isNil:
        # Empty session (no trace) — ensure the tab bar renderer is alive.
        refreshSessionTabBar()

  # Show the target container.
  targetContainer.classList.remove(cstring"hidden")

  # 4. Redraw.  If the target session has UI components (layout exists),
  #    ask the renderer owner to refresh mounted UI surfaces so component
  #    reads pick up the newly active session data.
  #    Empty welcome sessions also own the singleton shared components, so
  #    redraw them even though they do not create a GoldenLayout instance.
  refreshSessionTabBar()
  # THE STATUS BAR FOLLOWS THE TARGET SESSION, whatever else is redrawn below.
  # `#status` shows only the active tab's `StatusComponent`; a notification
  # that reached the target while it was hidden — a replay that could not
  # start — has been waiting for this render, and the branch below is skipped
  # for a session that has neither a layout nor a welcome screen.
  if not data.ui.status.isNil:
    data.ui.status.redraw()
  # THE TOPBAR FOLLOWS THE TARGET SESSION'S MODE. `data.ui.mode` is per
  # session and the topbar is one bar shared by every tab, so without this a
  # Debug tab reached from an Edit tab kept the edit bar, and an Edit tab
  # reached from a Debug tab kept the stepping controls (#812). Recomposed
  # rather than re-shown, because the edit bar's listing is the target's too.
  debug_toolbar.syncTopbarToMode()
  debug_toolbar.ensureDebugToolbar()
  if not data.activeSession.ui.layout.isNil or data.activeSession.startOptions.welcomeScreen:
    if data.activeSession.startOptions.welcomeScreen:
      if not data.ui.welcomeScreen.isNil:
        data.ui.welcomeScreen.showWelcomeView()
        data.ui.welcomeScreen.requestWelcomeScreenRender()
    else:
      welcome_screen.clearIsoNimWelcomeScreen()
    redrawAfterSessionSwitch()
    if not data.ui.menu.isNil:
      discard windowSetTimeout(proc() = data.ui.menu.requestMenuRender(), 0)
      discard windowSetTimeout(proc() =
        debug_toolbar.ensureDebugToolbar(), 0)
    discard windowSetTimeout(proc() = requestFixedSearchRender(), 0)

  # 5. What reached the target while it was hidden, now that it is shown.
  deliverPendingTabAnswers(data.activeSession)
