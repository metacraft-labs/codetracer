import
  std / [ async, jsffi, json, strutils, strformat, os, tables ],
  electron_vars, server_config, base_handlers, config, lsp_bridge,
  visual_replay_player, window_routing,
  ../lib/[ jslib, electron_lib ],
  ../[ types, config as frontend_config ],
  ../../common/[ paths, ct_logging, window_policy ]

var
  backendManagerProcess*: NodeSubProcess = nil
  backendManagerCleanedUp = false

proc stopProcess(process: NodeSubProcess) =
  process.toJs.kill()

proc stopBackendManager* =
  # Ensure we only attempt cleanup once and guard against nil.
  if backendManagerCleanedUp:
    return
  backendManagerCleanedUp = true
  if not backendManagerProcess.isNil:
    backendManagerProcess.stopProcess()
    backendManagerProcess = nil
  stopAllVisualReplayPlayers()
  stopAllLspBridges()

proc duration*(name: string) =
  infoPrint fmt"index: TIME for {name}: {now() - data.start}ms"

proc onOpenDevTools* =
  electronDebug.devTools(requestingBrowserWindow())

var closeAnnounced: seq[int] = @[]
  ## The windows already told `CODETRACER::close`.

proc onWindowClose(win: js; e: js) =
  if not data.config.isNil and data.config.test and openWindowCount() <= 1:
    # In test mode, prevent closing the LAST window so the application stays
    # alive for the full test duration; the test fixture tears down by
    # killing the process. Another window may close: the others keep the
    # application alive.
    e.preventDefault()
  else:
    let id = win.id.to(int)
    if id notin closeAnnounced:
      closeAnnounced.add id
      win.webContents.send "CODETRACER::close", js{}

proc windowLaunchOf*(config: Config): WindowLaunch =
  ## PLAT-69 (C5): how the window opens, from the user's `window:` entry —
  ## the policy the GPUI front-end applies too (`common/window_policy`).
  ##
  ## The entry is read as UNTYPED JavaScript: js-yaml hands back whatever the
  ## file holds, so a field is taken only when it has the type the setting
  ## needs, and anything else counts as "not given" and is reported. A config
  ## file from before the entry existed has none, and opens maximized as the
  ## desktop always did.
  var initial = ""
  var width, height = 0
  var problems: seq[string]
  if not config.isNil:
    let entry = config.toJs[cstring"window"]
    if not entry.isUndefined and not entry.isNull:
      if jsTypeOf(entry[cstring"initial"]) == cstring"string":
        initial = $entry[cstring"initial"].to(cstring)
      elif not entry[cstring"initial"].isUndefined:
        problems.add "window.initial is not a string"
      proc extent(key: string; problems: var seq[string]): int =
        let value = entry[cstring(key)]
        if jsTypeOf(value) == cstring"number":
          result = value.to(int)
          if result == 0:
            problems.add "window." & key & ": 0 is not a window size"
        elif not value.isUndefined:
          problems.add "window." & key & " is not a number"
      width = extent("width", problems)
      height = extent("height", problems)
  let parsed = parseWindowSetting(initial, width, height)
  for p in problems & parsed.problems:
    warnPrint "config: ", p
  resolveWindowLaunch(parsed.setting)

proc createMainWindow*(config: Config = nil): js =
  when not defined(server):

    let
      bundledIconPath = codetracerPrefix / "resources" / "Icon.iconset" / "icon_256x256.png"
      sourceIconPath = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
        "resources" / "Icon.iconset" / "icon_256x256.png"
      iconPath =
        if fs.existsSync(cstring(bundledIconPath)):
          bundledIconPath
        else:
          sourceIconPath

    # PLAT-69: the size and state the user configured (`window:`), clamped to
    # the screen's work area — a configured size larger than this screen
    # would open a window whose edges cannot be reached.
    let launch = windowLaunchOf(config)
    let workArea = electron.screen.getPrimaryDisplay().workAreaSize
    let screenW = if workArea.isNil: 0 else: workArea.width.to(int)
    let screenH = if workArea.isNil: 0 else: workArea.height.to(int)
    let width = if screenW > 0: min(launch.width, screenW) else: launch.width
    let height = if screenH > 0: min(launch.height, screenH) else: launch.height

    var initInfo = newJsObject()
    initInfo = js{
      "title": cstring"CodeTracer",
      "icon": iconPath,
      "width": width,
      "height": height,
      "minWidth": min(launch.minWidth, width),
      "minHeight": min(launch.minHeight, height),
      "webPreferences": js{
        "nodeIntegration": true,
        "contextIsolation": false,
        "spellcheck": false
      },
    }

    when defined(ctmacos):
      initInfo["titleBarStyle"] = cstring"hidden"
      initInfo["trafficLightPosition"] = js{
        "x": 10,
        "y": 12
      }
      initInfo["titleBarOverlay"] = js{
        "height": 70
      }
    elif defined(windows):
      # On Windows, frame:false can cause BrowserWindow to hang indefinitely
      # during creation (Electron compositor issue).  Use frame:true so the
      # window creates successfully; the menu bar is hidden separately via
      # setMenuBarVisibility(false).
      initInfo["frame"] = true
    else:
      initInfo["frame"] = false
      initInfo["transparent"] = true

    let win = jsnew electron.BrowserWindow(initInfo)
    win.on("maximize", proc() =
      win.webContents.executeJavaScript("document.body.style.backgroundColor = 'black';"))
    win.on("unmaximize", proc() =
      win.webContents.executeJavaScript("document.body.style.backgroundColor = 'transparent';"))
    # PLAT-69: maximized only when the setting says so (its default does).
    # Said in the log, because a compositor that ignores the request (sway,
    # for a floating window) leaves the request itself unobservable.
    infoPrint "index: window opens ",
              (if launch.maximized: "maximized" else: "windowed"), " ",
              $width, "x", $height
    if launch.maximized:
      win.maximize()
    let url = "file://" & $codetracerExeDir & "/index.html"

    win.loadURL(cstring(url))

    win.on("close", proc(e: js) = onWindowClose(win, e))

    when defined(ctmacos):
      # macOS hides the traffic-light buttons in native fullscreen, so the
      # caption bar must stop reserving space for them (and drop the divider
      # that separated them from its own controls).  Nothing in the renderer can
      # observe this — it is a window-level OS state — so push it over IPC.
      # `ui/menu.nim`'s `setCaptionBarFullscreen` consumes it.
      proc sendFullscreenState(fullscreen: bool) =
        win.webContents.send(
          cstring"CODETRACER::window-fullscreen-changed",
          js{"fullscreen": fullscreen})

      win.on("enter-full-screen", proc() = sendFullscreenState(true))
      win.on("leave-full-screen", proc() = sendFullscreenState(false))
      # The window can already be fullscreen when the renderer first paints
      # (a restored macOS space, or `--start-fullscreen`), and the renderer
      # defaults to windowed, so state the truth once the contents are live.
      win.webContents.on("did-finish-load", proc() =
        sendFullscreenState(cast[bool](win.isFullScreen())))
    # TODO: eventually add a shortcut and ipc message that lets us
    # open the dev tools directly from the interface, as in browsers
    let inDevEnv = nodeProcess.env[cstring"CODETRACER_DEV_TOOLS"] == cstring"1"
    if inDevEnv:
      ## Wait for the window to finish initial painting before attaching DevTools
      win.once("ready-to-show", proc() =
        win.webContents.openDevTools(js{"mode": cstring"detach"})
      )
    duration("opening the browser window from index")
    return win
  else:
    # we make a test-only placeholder instance of it
    let win = initFrontendIPC()
    return win.toJs


proc onCloseApp*(sender: js, response: js) {.async.} =
  stopBackendManager()
  for w in allWindows():
    if not w.closed:
      w.window.close()

proc onRestart*(sender: js, response: js) {.async.} =
  quit(RESTART_EXIT_CODE)

proc onMinimizeWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.minimize()

proc onRestoreWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.restore()

proc onMaximizeWindow*(sender: js, response: JsObject) {.async.} =
  if cast[bool](mainWindow.isMaximized()):
    mainWindow.unmaximize()
  else:
    mainWindow.maximize()

proc onCloseWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.close()

const DesktopLayoutFiles* = [
  "default_layout.json", "default_layout.json.broken",
  "default_edit_layout.json", "default_edit_layout.json.broken",
  "auto_hide_state.json"]
  ## PLAT-45: every file the DESKTOP keeps its arrangement in, under
  ## `userLayoutDir` — what `onResetLayout` deletes, and the same set
  ## `just reset-layout` clears.

proc layoutIsSaved(): bool =
  ## Whether the asking window's arrangement is the one kept for the next
  ## start: the startup's window's is; a window opened later for a session
  ## (`openSessionWindow`) has its own layout, often one pane, which must not
  ## replace the user's (`GUI/Multi-Window-Tab-Management.md` §"Cross-Window
  ## Synchronization" rule 4).
  let w = currentWindow()
  w.isNil or w.onHandshake.isNil

proc onSaveConfig*(sender: js, response: jsobject(name=cstring, layout=cstring, isEditMode=bool)) {.async.} =
  if not layoutIsSaved():
    return
  # Determine which layout file to save to based on mode
  let layoutFileName = if response.isEditMode:
      "default_edit_layout.json"
    else:
      "default_layout.json"

  let layoutFilePath = frontend_config.userLayoutDir / layoutFileName

  # Strip per-trace editor tabs from BOTH the edit-mode and replay-mode
  # default layouts before persisting.  Concrete editor tabs are
  # trace-specific (they reference absolute source paths from whatever
  # program was being debugged when the layout was saved), so resurrecting
  # them in the next session — which may be a completely different trace
  # — leaves the editor in a broken state: it tries to open files that
  # don't apply to the current trace, races with the active source
  # request, and the Monaco editor for the actually-relevant file may
  # never mount.  Surfaced by GUI test flakiness: a clean
  # `~/.config/codetracer/default_layout.json` made `static-block-stepping`
  # pass in 5s; an inherited layout from a previous test session stalled
  # Monaco for the full 30s `waitForNimEditorReady` timeout.
  #
  # Edit-mode additionally drops the hidden replay-only panels via the
  # editModeHiddenContentIds list.  Replay-mode keeps every panel
  # (state/calltrace/event-log/...) since those are panel arrangements
  # the user explicitly placed and they survive across traces.
  let layoutToSave =
    if response.isEditMode:
      sanitizeEditLayoutJson(response.layout)
    else:
      sanitizeDefaultLayoutJson(response.layout)

  # Save layout to file (directory should already exist from app startup)
  let errWrite = await fsWriteFileWithErr(cstring(layoutFilePath), layoutToSave)
  if not errWrite.isNil:
    errorPrint "save layout config error: ", errWrite
  else:
    infoPrint fmt"Layout saved to {layoutFilePath} (editMode={response.isEditMode})"

proc readFileSyncOrEmpty(path: cstring): cstring {.importjs:
  """(function(path) {
    try {
      return require('fs').readFileSync(path, 'utf8');
    } catch (error) {
      return '';
    }
  })(#)""".}
  ## Synchronous read used only by `onRequestAutoHideState`; see there for
  ## why the auto-hide handshake cannot be asynchronous.

proc setIpcReturnValue(event: js, value: cstring) {.importjs:
  """(function(event, value) {
    if (event && typeof event === 'object') { event.returnValue = value; }
  })(#, #)""".}
  ## Reply to an `ipcRenderer.sendSync` call.  Guarded because in server
  ## builds the IPC shim invokes handlers with an undefined sender.

proc onSaveAutoHideState*(sender: js,
                          response: jsobject(state=cstring)) {.async.} =
  ## Persist the set of panels the user pinned to a screen edge.
  ##
  ## Pinning REMOVES the component from the GoldenLayout tree, so this state
  ## cannot live inside `default_layout.json`: it is exactly the panels that
  ## are *not* in it.  It gets its own sibling file.
  ##
  ## Before this handler existed the renderer sent
  ## `CODETRACER::save-auto-hide-state` into the void — the channel name
  ## occurred at exactly one site in the whole repository, the send — so a
  ## pinned panel was gone on the next launch and, when the pinned panel was
  ## FILES, the layout validator declared the saved layout incompatible and
  ## deleted it (issue #608).
  if not layoutIsSaved():
    return
  let statePath = frontend_config.userLayoutDir / "auto_hide_state.json"
  let payload = if response.state.isNil: cstring"{}" else: response.state
  let errWrite = await fsWriteFileWithErr(cstring(statePath), payload)
  if not errWrite.isNil:
    errorPrint "save auto-hide state error: ", errWrite
  else:
    debugPrint "index: auto-hide state saved to ", statePath

proc onResetLayout*(sender: js, response: js) {.async.} =
  ## PLAT-45 deliverable 8, the desktop's `reset-layout`: delete the DESKTOP'S
  ## OWN saved arrangement — the debug and edit layouts, the quarantined
  ## `.broken` copies a failed repair leaves, and the pinned-panel state — then
  ## re-read the default through the SAME loader the first run uses, and hand
  ## it to the renderer, which installs it in place
  ## (`ui_js.applySharedDefaultLayout`).
  ##
  ## Re-read rather than reload: `init` sends the renderer its
  ## `CODETRACER::init` once, so a reloaded window would wait forever. And
  ## re-read through `loadLayoutConfig` / `loadEditLayoutConfig` rather than a
  ## second reading of `config/default_layout.json`: with the user's file gone
  ## they copy the bundled default into place exactly as a first run does, so
  ## there is one place the default comes from.
  ##
  ## ONLY these files. The terminal's `tui-layout.json` and the GPUI window's
  ## `gpui-layout.json` live under the native state root
  ## (`$XDG_STATE_HOME/codetracer`), not under `userLayoutDir`, and each
  ## product's reset deletes its own file and nobody else's.
  ##
  ## An absent file is the ordinary case (a user who never rearranged), not an
  ## error: the unlink's answer is logged, never fatal.
  for name in DesktopLayoutFiles:
    let path = frontend_config.userLayoutDir / name
    let err = await fsUnlinkWithErr(cstring(path))
    if err.isNil:
      infoPrint "reset-layout: removed ", path
  let edit = not response.isNil and not response.isUndefined and
    cast[bool](response[cstring"edit"])
  let layout =
    if edit:
      await mainWindow.loadEditLayoutConfig(
        string(frontend_config.userLayoutDir / "default_edit_layout.json"))
    else:
      await mainWindow.loadLayoutConfig(
        string(frontend_config.userLayoutDir / "default_layout.json"))
  mainWindow.webContents.send "CODETRACER::reset-layout-done", js{layout: layout}

proc onRequestAutoHideState*(sender: js, response: js) =
  ## Hand the persisted auto-hide state back to the renderer, synchronously.
  ##
  ## Deliberately NOT `{.async.}` and deliberately a synchronous read: the
  ## renderer asks for this with `ipcRenderer.sendSync` from inside
  ## `initLayout`, because the restore has to have completed before the
  ## standalone auto-hide panels are registered (`ui/layout.nim`) — otherwise
  ## a restored panel and a freshly-created standalone one race for the same
  ## content.  `event.returnValue` is only read while this handler is on the
  ## stack, so an `await` here would return `undefined` to the renderer.
  ##
  ## The payload is a few hundred bytes and is read once per window start.
  ## A missing file is the normal first-run case and yields an empty string,
  ## which the renderer treats as "nothing pinned".
  let statePath = frontend_config.userLayoutDir / "auto_hide_state.json"
  setIpcReturnValue(sender, readFileSyncOrEmpty(cstring(statePath)))

proc onExitError*(sender: js, response: cstring) {.async.} =
  # we call this on fatal errors
  errorPrint fmt"exit: {response}"
  if true: # workaround for unreachable statement and async
    quit(1)


# ── Desktop windows (`window_routing`) ──────────────────────────────────

var replayOrphaned*: proc(replayId: int) = nil
  ## Stops a replay no open window shows any more (a closed window's), set
  ## by `ipc_utils` (`traces.stopReplayProcess`).

proc jsArray(): JsObject {.importjs: "([])".}
proc push(arr: JsObject, item: JsObject) {.importjs: "#.push(#)".}

proc windowListFor(asker: AppWindow): JsObject =
  ## The open windows other than `asker`, as the pane tab menu lists them:
  ## each with its title and the replays its tabs show, which tell the
  ## renderer whether a pane of one of its replays can go there.
  result = jsArray()
  for w in allWindows():
    if w.closed or w == asker:
      continue
    var replays = jsArray()
    for replay in w.tabReplays.values:
      replays.push(replay.toJs)
    result.push(js{
      "id": w.id,
      "title": w.window.getTitle(),
      "replayIds": replays
    })

proc pushWindowList*() =
  ## Tell every window the windows it could send a pane to, after a window
  ## opened, closed or was retitled (the pane tab menu's list,
  ## `panel_transfer.knownOtherWindows`).
  for w in allWindows():
    if not w.closed:
      w.rawSend(cstring"CODETRACER::windows-changed",
                js{"windows": windowListFor(w)})

proc registerDesktopWindow*(win: JsObject): AppWindow =
  ## Register a `BrowserWindow` as one of the application's windows
  ## (`window_routing`): its sends are logged, it is forgotten when it
  ## closes, and the other windows learn it opened, closed or was retitled.
  when not defined(server):
    let contents = win.webContents
    let internalSend = contents.send
    let send: WindowSend = proc(channel: cstring; payload: JsObject) =
      if contents.isDestroyed().to(bool):
        return
      if channel == cstring"CODETRACER::filenames-loaded":
        debugPrint cstring"frontend ... <=== index: ", channel, "[..not shown to optimize send time..]"
      else:
        debugPrint cstring"frontend ... <=== index: ", channel
      discard internalSend.call(contents, channel, payload)
    let w = registerAppWindow(win.id.to(int), contents.id.to(int), win, send)
    win.on(cstring"closed", proc() =
      infoPrint "index: window ", $w.id, " closed"
      for replay in closeAppWindow(w):
        infoPrint "index: no window shows replay ", $replay, " any more: stopping it"
        if not replayOrphaned.isNil:
          replayOrphaned(replay)
      pushWindowList())
    win.on(cstring"page-title-updated", proc() =
      discard windowSetTimeout(proc() = pushWindowList(), 0))
    infoPrint "index: registered window ", $w.id
    pushWindowList()
    return w

proc startWindowHandshake(w: AppWindow) =
  ## Send `CODETRACER::started` until the window's renderer answers it (the
  ## first window's handshake is `startup.started`).
  if w.closed or w.handshakeDone:
    return
  w.rawSend(cstring"CODETRACER::started", js{})
  discard windowSetTimeout(proc() = startWindowHandshake(w), 100)

proc windowAnswersStarted*(): bool =
  ## The renderer of the window being served answered `CODETRACER::started`.
  ## True when that window was opened after startup and its bootstrap now
  ## runs; false for the startup's window, whose handshake is
  ## `startup.started`.
  let w = currentWindow()
  if w.isNil:
    return false
  if w.handshakeDone:
    return not w.onHandshake.isNil
  w.handshakeDone = true
  if w.onHandshake.isNil:
    return false
  let bootstrap = w.onHandshake
  bootstrap()
  true

proc panelOnlyLayout(base: JsObject; panel: JsObject): JsObject =
  ## A layout holding only `panel` (an unresolved component item config,
  ## `panel_transfer.serializePanelConfig`), with `base`'s settings: what a
  ## window opened by "Send to New Window" shows.
  let settings = if base.isNil: js{} else: base[cstring"settings"]
  let dimensions = if base.isNil: js{} else: base[cstring"dimensions"]
  var stackContent = jsArray()
  stackContent.push(panel)
  var rowContent = jsArray()
  rowContent.push(js{"type": cstring"stack", "size": cstring"100%",
                     "content": stackContent})
  js{
    "settings": settings,
    "dimensions": dimensions,
    "openPopouts": jsArray(),
    "root": js{"type": cstring"row", "size": cstring"100%",
               "isClosable": false, "content": rowContent}
  }

proc windowStartOptions(): JsObject =
  ## The startup's options, for a window that shows a session tab: neither
  ## the welcome screen, nor an edit session, nor another startup mode.
  result = copyOf(data.startOptions.toJs)
  for flag in [cstring"welcomeScreen", cstring"edit", cstring"shellUi",
               cstring"withDeepReview"]:
    result[flag] = false

proc sendWindowBootstrap(w: AppWindow; source: AppWindow; sourceTab: int;
                         panel: JsObject) =
  ## What a window opened for `source`'s tab `sourceTab` is sent once its
  ## renderer listens (`window_routing.bootstrapWindow`), with an `init`
  ## carrying the session's layout — only `panel` when a pane was sent to it —
  ## the config and the helpers.
  let panelGiven = not panel.isNil and not panel.isUndefined
  let layout =
    if panelGiven: panelOnlyLayout(data.layout, panel)
    else: data.layout
  bootstrapWindow(w, source, sourceTab, js{
      "home": paths.home.cstring,
      "config": data.config,
      "layout": layout,
      "helpers": data.helpers,
      "startOptions": windowStartOptions(),
      "bypass": true
    },
    if panelGiven: layout else: nil)
  pushWindowList()

proc watchForReload*(w: AppWindow) =
  ## When `w`'s page loads again (a reload: the disconnect notice's Reconnect
  ## calls `location.reload()`, and Windows keeps Electron's hidden menu with
  ## its Ctrl+Shift+R), its new renderer is handshaken again and sent the
  ## session it showed (`window_routing.bootstrapReloadedWindow`).
  when not defined(server):
    var loads = 0
    w.window.webContents.on(cstring"did-finish-load", proc() =
      inc loads
      if loads < 2 or w.closed:
        return
      infoPrint "index: window ", $w.id, " reloaded: sending it its session again"
      w.handshakeDone = false
      w.onHandshake = proc() =
        runAsWindow(w, proc() =
          bootstrapReloadedWindow(w, js{
            "home": paths.home.cstring,
            "config": data.config,
            "layout": data.layout,
            "helpers": data.helpers,
            "startOptions": windowStartOptions(),
            "bypass": true})
          pushWindowList())
      startWindowHandshake(w))

proc openSessionWindow*(source: AppWindow; sourceTab: int;
                        panel: JsObject = nil): AppWindow =
  ## Open a window showing `source`'s tab `sourceTab` (its session and its
  ## replay, shared with `source`): all of the session's layout, or only
  ## `panel` (a pane sent to a new window).
  when not defined(server):
    let win = createMainWindow(data.config)
    win.setMenuBarVisibility(false)
    win.setMenu(jsNull)
    let w = registerDesktopWindow(win)
    watchForReload(w)
    w.onHandshake = proc() =
      runAsWindow(w, proc() = sendWindowBootstrap(w, source, sourceTab, panel))
    win.webContents.once(cstring"did-finish-load", proc() =
      startWindowHandshake(w))
    infoPrint "index: opened window ", $w.id, " for tab ", $sourceTab,
              " of window ", (if source.isNil: "?" else: $source.id)
    return w

proc onOpenNewWindow*(sender: js, response: JsObject) {.async.} =
  ## "Open in New Window" on a session tab: `{ sessionId }` names the tab (its
  ## id in the asking window).
  let tab = if response.hasOwnProperty(cstring"sessionId"):
    response["sessionId"].to(int)
  else:
    0
  let source = requestingWindow()
  infoPrint "index: open-new-window for tab ", $tab, " of window ",
    (if source.isNil: "(none)" else: $source.id)
  if source.isNil:
    return
  discard openSessionWindow(source, tab)

proc onPanelDetach*(sender: js, response: JsObject) {.async.} =
  ## "Send to: <window>" / "Send to New Window" on a pane tab. The asking
  ## window sends `{ targetWindowId, panelConfig, sessionId }`, `sessionId`
  ## being the tab whose pane it is. `targetWindowId == -1` opens a window
  ## showing that tab's session with only the pane. Otherwise the pane goes
  ## to the target window's tab that shows the same replay, and is refused
  ## when it has none: a pane of trace A cannot show in a window of trace B.
  when not defined(server):
    let source = requestingWindow()
    if source.isNil:
      return
    let tab = response["sessionId"].to(int)
    let panel = response["panelConfig"]
    let targetWindowId = response["targetWindowId"].to(int)
    if targetWindowId == -1:
      discard openSessionWindow(source, tab, panel)
      return
    let target = windowWithId(targetWindowId)
    if target.isNil:
      errorPrint "index: panel-detach: no open window ", $targetWindowId
      return
    let replayId = source.tabReplays.getOrDefault(tab, -1)
    var targetTab = -1
    for t, replay in target.tabReplays:
      if replay == replayId and replayId >= 0:
        targetTab = t
    if targetTab < 0:
      errorPrint "index: panel-detach refused: window ", $targetWindowId,
        " shows no tab of replay ", $replayId
      return
    target.rawSend(cstring"CODETRACER::panel-attach",
                   js{"panelConfig": panel, "sessionId": targetTab})
    infoPrint "index: sent a pane to window ", $targetWindowId, " (tab ",
      $targetTab, ", replay ", $replayId, ")"

proc onListWindows*(sender: js, response: JsObject) {.async.} =
  ## The windows other than the asking one (`windowListFor`).
  mainWindow.webContents.send(cstring"CODETRACER::list-windows-reply", js{
    "windows": windowListFor(requestingWindow())
  })
