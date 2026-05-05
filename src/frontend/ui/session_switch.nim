## Session switching for multi-replay sessions (M11).
##
## Implements the hide/show approach: each session keeps its own GL
## container alive in the DOM.  Switching sessions toggles CSS visibility
## on the per-session container divs instead of destroying and recreating
## the GoldenLayout instance.  This preserves Monaco editors and all
## GL-managed component state across tab switches.
##
## To avoid circular imports (layout -> session_tabs -> session_switch ->
## layout), the actual ``initLayout`` call is wired in at runtime via
## ``setInitLayoutProc``.

import
  std/[strformat, jsffi, asyncjs],
  ../types,
  ../dap,
  ../renderer,
  menu,
  welcome_screen,
  search_results,
  ../utils,
  ../lib/[logging, jslib]

import kdom except Location

# ---------------------------------------------------------------------------
# Deferred dependency on initLayout (avoids circular import)
# ---------------------------------------------------------------------------

type
  InitLayoutProc = proc(config: GoldenLayoutResolvedConfig,
                        containerElement: kdom.Element = nil) {.nimcall.}
  EnsureTabBarRendererProc = proc() {.nimcall.}

var initLayoutImpl: InitLayoutProc = nil
var ensureTabBarRendererImpl: EnsureTabBarRendererProc = nil

proc setInitLayoutProc*(p: InitLayoutProc) =
  ## Called once from layout.nim to wire in the real ``initLayout``.
  initLayoutImpl = p

proc setEnsureTabBarRendererProc*(p: EnsureTabBarRendererProc) =
  ## Called once from layout.nim to wire in the tab-bar renderer setup.
  ## This allows session creation to ensure the session-tab-bar
  ## direct mount exists even when ``initLayout`` is not called.
  ensureTabBarRendererImpl = p

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
  let sessionId = data.sessions.len
  var session = newReplaySession(ReplaySessionId(sessionId))
  session.dapApi = DapApi()
  session.viewsApi = setupSinglePageViewsApi(
    cstring("single-page-frontend-to-views-" & $sessionId))
  session.services = Services(
    eventLog: EventLogService(),
    debugger: DebuggerService(
      locals: @[],
      registerState: JsAssoc[cstring, cstring]{},
      breakpointTable: JsAssoc[cstring, JsAssoc[int, UIBreakpoint]]{},
      valueHistory: JsAssoc[cstring, ValueHistory()]{},
      paths: @[],
      skipInternal: true,
      skipNoSource: false,
      historyIndex: 1,
      showInlineValues: true),
    editor: EditorService(
      open: JsAssoc[cstring, TabInfo]{},
      loading: @[],
      completeMoveResponses: JsAssoc[cstring, MoveState]{},
      closedTabs: @[],
      saveHistoryTimeoutId: -1,
      switchTabHistoryLimit: 2000,
      expandedOpen: JsAssoc[cstring, TabInfo]{},
      cachedFiles: JsAssoc[cstring, TabInfo]{},
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
  session.ui = Components(
    editors: JsAssoc[cstring, EditorViewComponent]{},
    idMap: JsAssoc[cstring, int]{value: 0, chart: 0},
    layoutSizes: LayoutSizes(startSize: true),
    monacoEditors: @[],
    traceMonacoEditors: @[],
    focusHistory: @[],
    editModeHiddenPanels: @[],
    savedLayoutBeforeEdit: nil,
    editModeLayout: nil,
    lastUsedEditLayout: nil
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

  # Empty tabs still need the shared chrome and welcome screen components.
  # Component factory helpers write through Data's active-session forwarding,
  # so initialise the new session while it is temporarily active.
  let previousActiveSessionIndex = data.activeSessionIndex
  data.activeSessionIndex = sessionId
  discard data.makeDebugComponent()
  discard data.makeMenuComponent()
  discard data.makeBuildComponent()
  discard data.makeErrorsComponent()
  discard data.makeSearchResultsComponent()
  discard data.makeStatusComponent(
    data.buildComponent(0), data.errorsComponent(0), data.ui.searchResults)
  discard data.makeCommandPaletteComponent()
  discard data.makeWelcomeScreenComponent()
  data.activeSessionIndex = previousActiveSessionIndex

  clog "session_switch: created new session " & $sessionId &
    " (total: " & $data.sessions.len & ")"

  # Switch to the newly created session.
  switchSession(data, sessionId)

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
  if not closingSession.ui.layout.isNil:
    try:
      {.emit: [closingSession.ui.layout, ".destroy();"].}
    except:
      cwarn "session_switch: GL destroy failed for session " & $targetIndex

  # Remove the DOM container for the closed session.
  destroySessionContainer(targetIndex)

  # If closing the active session, switch to an adjacent one first.
  if targetIndex == data.activeSessionIndex:
    let newActive = if targetIndex > 0: targetIndex - 1 else: targetIndex + 1
    switchSession(data, newActive)

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
  #    resolve to the target session's fields.
  data.activeSessionIndex = targetIndex

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
    discard windowSetTimeout(proc() = requestFixedSearchRender(), 0)
