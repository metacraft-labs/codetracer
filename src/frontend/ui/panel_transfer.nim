## M21/M22: Cross-window panel transfer via context menu.
##
## Provides "Send to Window" functionality on Golden Layout tab context menus.
## When a user right-clicks a GL tab, they can choose a target window from a
## submenu. The panel's config is serialised, removed from the source window,
## and recreated in the target window via Electron IPC.
##
## A pane belongs to a tab, and the tab shows a replay. Tab ids are per
## window, so between windows a pane's session is named by its REPLAY: a pane
## can go to another window that has a tab showing the same replay, and the
## main process puts it in that tab (`index/window.onPanelDetach`). "Send to
## New Window" opens a window that shows the tab's session with only the pane
## in its layout (`index/window.openSessionWindow`).

when defined(ctWeb):
  {.error: "ui/panel_transfer.nim moves a pane BETWEEN APPLICATION WINDOWS over " &
           "Electron's inter-process channel. It is absent from a web build " &
           "because the capability is absent — `capMultiWindow` is not in " &
           "`capabilities.webCapabilities` — and not because its seven IPC call " &
           "sites are awaiting migration. There is no second window to send a " &
           "pane to, so a facade " &
           "arm would be an action that can only ever refuse. The web's answer to " &
           "'open this elsewhere' is a second tab on the same session, which is " &
           "what the web profile's `capMultiWindow` degradation already says." .}

import
  std / [ jsffi, jsconsole, asyncjs ],
  kdom,
  ../types,
  ../lib/[ jslib, logging ]

# ---------------------------------------------------------------------------
# Electron IPC access (renderer side)
# ---------------------------------------------------------------------------

var electron* {.importc.}: JsObject

# The tab a window opened for a session shows it in (its first, 0), and the
# replay, as `CODETRACER::init-session` said (`registerInitSessionHandler`).
var currentSessionId*: int = 0
var currentReplayId*: int = -1

proc noOtherWindows(): JsObject {.importjs: "({windows: []})".}
var knownOtherWindows* = noOtherWindows()
  ## The other open windows, as the main process last said
  ## (`CODETRACER::windows-changed` when a window opens, closes or is
  ## retitled; `CODETRACER::list-windows-reply`): `{ windows: [{ id, title,
  ## replayIds }] }`.

proc ipcRenderer(): JsObject =
  ## Lazily obtain the ipcRenderer; returns nil/undefined when not in Electron.
  if not electron.isNil and not electron.isUndefined:
    return electron.ipcRenderer
  return nil

# ---------------------------------------------------------------------------
# Panel config serialisation
# ---------------------------------------------------------------------------

proc serializePanelConfig*(contentItem: GoldenContentItem): JsObject =
  ## Serialise a GL component for cross-window transfer: an UNRESOLVED
  ## component item config (type, component type, state, title), what
  ## `addItem` and a layout's `root` take on the receiving side. Not
  ## `toConfig()`'s resolved one, whose numeric sizes GoldenLayout refuses in
  ## an unresolved layout.
  let resolved = contentItem.toConfig().toJs
  js{
    "type": cstring"component",
    "componentType": resolved[cstring"componentType"],
    "componentState": resolved[cstring"componentState"],
    "title": resolved[cstring"title"]
  }

# ---------------------------------------------------------------------------
# Receiving side: attach a panel that arrived from another window
# ---------------------------------------------------------------------------

proc handlePanelAttach*(layout: GoldenLayout, config: JsObject) =
  ## Receive a panel config from another window and add it to the local
  ## Golden Layout instance.  The config is added to the first available
  ## stack, or as a new stack at the root if the layout is empty.
  if layout.isNil:
    cerror "panel_transfer: cannot attach - layout is nil"
    return

  # Try to add to the ground item's first content item (typically a stack/row/column).
  let ground = layout.groundItem
  if not ground.isNil and ground.contentItems.len > 0:
    let target = ground.contentItems[0]
    discard target.addItem(config)
  else:
    console.warn cstring"panel_transfer: no existing container — adding to root"
    discard ground.addItem(config)

# ---------------------------------------------------------------------------
# Sending side: detach a panel and send it to another window
# ---------------------------------------------------------------------------

proc detachAndSendPanel*(
  contentItem: GoldenContentItem,
  targetWindowId: int,
  sessionId: int
) =
  ## Serialise the panel, remove it from the local GL instance, and send
  ## it to the target window via the main process. `sessionId` is the id of
  ## the tab the pane belongs to.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    cerror "panel_transfer: ipcRenderer not available"
    return

  let config = serializePanelConfig(contentItem)
  let payload = js{
    "targetWindowId": targetWindowId,
    "panelConfig": config,
    "sessionId": sessionId
  }

  # Remove the panel from the local GL instance.
  if not contentItem.parent.isNil:
    contentItem.parent.removeChild(contentItem)

  ipc.send(cstring"CODETRACER::panel-detach", payload)

# ---------------------------------------------------------------------------
# Context menu: "Send to Window" submenu
# ---------------------------------------------------------------------------

proc emptyWindowList(): JsObject {.importjs: "({windows: []})".}

proc requestWindowList*(): Future[JsObject] =
  ## Ask the main process for the list of open windows.
  ## Returns a promise that resolves with `{ windows: [{ id, title }] }`.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return newPromise(proc(resolve: proc(v: JsObject)) =
      resolve(emptyWindowList()))

  return newPromise(proc(resolve: proc(v: JsObject)) =
    # Use ipcRenderer.once so the handler is automatically cleaned up.
    ipc.once(cstring"CODETRACER::list-windows-reply", proc(event: JsObject, response: JsObject) =
      resolve(response))
    ipc.send(cstring"CODETRACER::list-windows", js{}))

proc showsReplay(win: JsObject; replayId: int): bool =
  ## Whether a window of a `windows-changed` / `list-windows-reply` list has
  ## a tab showing `replayId`.
  let replays = win["replayIds"]
  if replayId < 0 or replays.isNil or replays.isUndefined:
    return false
  for i in 0 ..< cast[int](replays.length):
    if replays[i].to(int) == replayId:
      return true
  false

proc buildSendToWindowMenuItems*(
  contentItem: GoldenContentItem,
  sessionId: int,
  replayId: int,
  windows: JsObject
): seq[ContextMenuItem] =
  ## The pane tab menu's transfer entries for a pane of the tab `sessionId`,
  ## whose replay is `replayId`: "Send to: <title>" for each other window
  ## showing that replay, and "Send to New Window". A window of another
  ## replay is not offered: the pane would show trace A in a window of
  ## trace B.
  var items: seq[ContextMenuItem] = @[]
  let winArray = windows["windows"]
  let winLen = cast[int](winArray.length)

  for i in 0 ..< winLen:
    closureScope:
      let win = winArray[i]
      let windowId = win["id"].to(int)
      let windowTitle = win["title"].to(cstring)
      # Capture for closure.
      let capturedWindowId = windowId
      let capturedSessionId = sessionId
      let capturedItem = contentItem

      if win.showsReplay(replayId):
        # Compatible window — same session/trace.
        # Joined as JS strings: through a Nim `string` a title's non-ASCII
        # characters (the "—" of "main.py — CodeTracer") would be cut to
        # their low byte.
        let label = cstring"Send to: " & windowTitle
        items.add(ContextMenuItem(
          name: label,
          hint: cstring"",
          handler: proc(ev: kdom.Event) =
            detachAndSendPanel(capturedItem, capturedWindowId, capturedSessionId)
        ))
      # Incompatible windows (different session) are silently omitted.

  # Always offer "Send to New Window", which opens a window showing this
  # pane's session with the pane alone.
  let capturedNewSessionId = sessionId
  let capturedNewItem = contentItem
  items.add(ContextMenuItem(
    name: cstring"Send to New Window",
    hint: cstring"",
    handler: proc(ev: kdom.Event) =
      # targetWindowId -1 signals the main process to auto-create a window.
      detachAndSendPanel(capturedNewItem, -1, capturedNewSessionId)
  ))

  return items

# ---------------------------------------------------------------------------
# IPC listener for the receiving side (renderer process)
# ---------------------------------------------------------------------------

var panelAttachRegistered = false

proc registerPanelAttachHandler*(layout: GoldenLayout;
                                 hasTab: proc(sessionId: int): bool) =
  ## Register the IPC handler that listens for incoming panel configs
  ## from other windows.  Call this once after the GL layout is initialised.
  ## The main process names the tab of this window that shows the pane's
  ## replay (`sessionId`); a pane for a tab this window does not have is
  ## refused.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined or panelAttachRegistered:
    return
  panelAttachRegistered = true

  ipc.on(cstring"CODETRACER::panel-attach", proc(event: JsObject, payload: JsObject) =
    let config = payload["panelConfig"]
    let sid = payload["sessionId"].to(int)
    if not hasTab.isNil and not hasTab(sid):
      cerror "panel_transfer: rejecting a pane for tab " & $sid &
        ", which this window does not have"
      return
    console.log cstring"panel_transfer: attaching a pane of tab ", sid
    handlePanelAttach(layout, config))

proc registerInitSessionHandler*() =
  ## Listen for the ``CODETRACER::init-session`` message sent by the main
  ## process when a secondary window is created.  Sets ``currentSessionId``
  ## so that panel attach validation works correctly.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return

  ipc.on(cstring"CODETRACER::init-session", proc(event: JsObject, payload: JsObject) =
    currentSessionId = payload["sessionId"].to(int)
    if not payload["replayId"].isUndefined:
      currentReplayId = payload["replayId"].to(int)
    console.log cstring"panel_transfer: bound to session ", currentSessionId)

proc registerWindowListHandler*() =
  ## Keep `knownOtherWindows` current: the main process says when a window
  ## opens, closes or is retitled (`CODETRACER::windows-changed`), so the
  ## pane tab menu lists the windows open now.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return
  ipc.on(cstring"CODETRACER::windows-changed", proc(event: JsObject, payload: JsObject) =
    knownOtherWindows = payload)
