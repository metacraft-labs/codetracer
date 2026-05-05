import
  std / [ async, jsffi, json, strutils, strformat, os ],
  electron_vars, server_config, base_handlers, config, lsp_bridge,
  visual_replay_player,
  ../lib/[ jslib, electron_lib ],
  ../[ types, config as frontend_config ],
  ../../common/[ paths, ct_logging ]

var
  close = false
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
  electronDebug.devTools(mainWindow)

proc onClose*(e: js) =
  if not data.config.isNil and data.config.test:
    # In test mode, prevent all window closes so the window stays alive
    # for the full test duration. The test fixture tears down by killing
    # the process directly.
    e.preventDefault()
  elif not close:
    # TODO refactor to use just `client.send`
    mainWindow.webContents.send "CODETRACER::close", js{}
    close = true

proc createMainWindow*: js =
  when not defined(server):
    # TODO load from config

    let
      bundledIconPath = codetracerPrefix / "resources" / "Icon.iconset" / "icon_256x256.png"
      sourceIconPath = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
        "resources" / "Icon.iconset" / "icon_256x256.png"
      iconPath =
        if fs.existsSync(cstring(bundledIconPath)):
          bundledIconPath
        else:
          sourceIconPath

    var initInfo = newJsObject()
    initInfo = js{
      "title": cstring"CodeTracer",
      "icon": iconPath,
      "width": 1900,
      "height": 1400,
      "minWidth": 1050,
      "minHeight": 600,
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
    win.maximize()
    let url = "file://" & $codetracerExeDir & "/index.html"

    win.loadURL(cstring(url))

    win.on("close", onClose)
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
  mainWindow.close()

proc onRestart*(sender: js, response: js) {.async.} =
  quit(RESTART_EXIT_CODE)

proc onMinimizeWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.minimize()

proc onRestoreWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.restore()

proc onMaximizeWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.maximize()

proc onCloseWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.close()

proc onSaveConfig*(sender: js, response: jsobject(name=cstring, layout=cstring, isEditMode=bool)) {.async.} =
  # TODO: fix problem with editor tabs and reopened layouts?
  when false:
    # Determine which layout file to save to based on mode
    let layoutFileName = if response.isEditMode:
        "default_edit_layout.json"
      else:
        "default_layout.json"

    let layoutFilePath = frontend_config.userLayoutDir / layoutFileName

    # Save layout to file (directory should already exist from app startup)
    let errWrite = await fsWriteFileWithErr(cstring(layoutFilePath), response.layout)
    if not errWrite.isNil:
      errorPrint "save layout config error: ", errWrite
    else:
      infoPrint fmt"Layout saved to {layoutFilePath} (editMode={response.isEditMode})"

proc onExitError*(sender: js, response: cstring) {.async.} =
  # we call this on fatal errors
  errorPrint fmt"exit: {response}"
  if true: # workaround for unreachable statement and async
    quit(1)

# ── Multi-window management (M15) ──────────────────────────────────────

proc registerMainWindow*() =
  ## Register the main window in the window table under session 0.
  ## Call this right after ``mainWindow = createMainWindow()``.
  when not defined(server):
    let windowId = mainWindow.id.to(int)
    windowTable[windowId] = mainWindow
    sessionWindows[0] = @[windowId]
    infoPrint "index: registered main window id=", $windowId, " in session 0"

proc unregisterWindow(windowId: int) =
  ## Remove a window from both the window table and all session lists.
  discard jsDelete windowTable[windowId]
  # Iterate over known session IDs to remove the window from any session.
  # We collect IDs to delete to avoid mutating during iteration.
  var emptySessionIds: seq[int] = @[]
  for sid, wins in sessionWindows:
    let idx = wins.find(windowId)
    if idx >= 0:
      # Copy the list, remove the entry, reassign.
      var updated = wins
      updated.delete(idx)
      sessionWindows[sid] = updated
      if updated.len == 0 and sid != 0:
        emptySessionIds.add(sid)
  for sid in emptySessionIds:
    discard jsDelete sessionWindows[sid]

proc createSecondaryWindow*(sessionId: int): JsObject =
  ## Create a new BrowserWindow for an existing session.
  ## The window reuses the same creation logic as the main window so it
  ## gets the same dimensions, webPreferences and URL.
  when not defined(server):
    let win = createMainWindow()
    let windowId = win.id.to(int)
    windowTable[windowId] = win

    if sessionWindows.hasKey(sessionId):
      var wins = sessionWindows[sessionId]
      wins.add(windowId)
      sessionWindows[sessionId] = wins
    else:
      sessionWindows[sessionId] = @[windowId]

    # Tell the renderer which session it belongs to once the page loads.
    win.webContents.once(cstring"did-finish-load", proc() =
      win.webContents.send(cstring"CODETRACER::init-session",
                           js{"sessionId": sessionId})
    )

    # Clean up when the secondary window is closed.
    win.on(cstring"closed", proc() =
      infoPrint "index: secondary window closed id=", $windowId
      unregisterWindow(windowId)
    )

    infoPrint "index: created secondary window id=", $windowId,
              " for session ", $sessionId
    return win

proc onOpenNewWindow*(sender: js, response: JsObject) {.async.} =
  ## M17: IPC handler for "open-new-window".
  ## The renderer sends the sessionId of the replay to open in a new window.
  let sessionId = if response.hasOwnProperty(cstring"sessionId"):
    response["sessionId"].to(int)
  else:
    0  # default session
  discard createSecondaryWindow(sessionId)

# ── Cross-window panel transfer (M21/M22) ────────────────────────────────

proc windowBelongsToSession(windowId: int, sessionId: int): bool =
  ## Check whether a window is registered under the given session.
  if sessionWindows.hasKey(sessionId):
    return sessionWindows[sessionId].find(windowId) >= 0
  return false

proc onPanelDetach*(sender: js, response: JsObject) {.async.} =
  ## M21/M22: Forward a panel config from one renderer window to another.
  ## The source renderer sends `{ targetWindowId, panelConfig, sessionId }`.
  ## We forward `{ panelConfig, sessionId }` to the target window only if
  ## the target window belongs to the same session.  If the target window
  ## belongs to a different session, the transfer is rejected (a panel
  ## from trace A cannot be dropped into a window showing trace B).
  ## When targetWindowId is -1 (sentinel), a new secondary window is
  ## created for the panel's session automatically.
  when not defined(server):
    let panelSessionId = response["sessionId"].to(int)
    var targetWindowId = response["targetWindowId"].to(int)

    # Sentinel -1: auto-create a new window for this session.
    if targetWindowId == -1:
      let newWin = createSecondaryWindow(panelSessionId)
      targetWindowId = newWin.id.to(int)
      infoPrint "index: panel-detach auto-created window ", $targetWindowId,
        " for session ", $panelSessionId

    if not windowTable.hasKey(targetWindowId):
      errorPrint "index: panel-detach target window not found: ", $targetWindowId
      return

    # Validate session binding: reject transfer to a window showing a
    # different trace/session.
    if not windowBelongsToSession(targetWindowId, panelSessionId):
      errorPrint "index: panel-detach rejected — window ", $targetWindowId,
        " does not belong to session ", $panelSessionId
      return

    let payload = js{
      "panelConfig": response["panelConfig"],
      "sessionId": response["sessionId"]
    }
    windowTable[targetWindowId].webContents.send(
      cstring"CODETRACER::panel-attach", payload)
    infoPrint "index: forwarded panel to window ", $targetWindowId,
      " (session ", $panelSessionId, ")"

proc newJsArray(): JsObject {.importjs: "(new Array())".}
proc push(arr: JsObject, item: JsObject) {.importjs: "#.push(#)".}

proc sessionIdForWindow(windowId: int): int =
  ## Look up which session a window belongs to.  Returns -1 if unknown.
  for sid, wins in sessionWindows:
    if wins.find(windowId) >= 0:
      return sid
  return -1

proc onListWindows*(sender: js, response: JsObject) {.async.} =
  ## M21/M22: Return the list of open windows to the requesting renderer.
  ## The sender's own window is excluded from the list.  Each entry
  ## includes the window's session ID so the renderer can indicate which
  ## windows are compatible for panel transfer.
  when not defined(server):
    var jsArray = newJsArray()
    # The sender parameter is the webContents of the sending window.
    # We compare window IDs to exclude the sender's own window.
    let senderWebContentsId = sender.toJs.id
    for windowId, win in windowTable:
      # Exclude the sender's own window by comparing webContents id.
      if win.webContents.id != senderWebContentsId:
        jsArray.push(js{
          "id": windowId,
          "title": win.getTitle(),
          "sessionId": sessionIdForWindow(windowId)
        })
    # Reply to the sender window.
    sender.toJs.send(cstring"CODETRACER::list-windows-reply", js{
      "windows": jsArray
    })
