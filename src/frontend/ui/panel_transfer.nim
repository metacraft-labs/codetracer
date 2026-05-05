## M21/M22: Cross-window panel transfer via context menu.
##
## Provides "Send to Window" functionality on Golden Layout tab context menus.
## When a user right-clicks a GL tab, they can choose a target window from a
## submenu. The panel's config is serialised, removed from the source window,
## and recreated in the target window via Electron IPC.
##
## The panel carries its `sessionId` so that mixed-session windows (M22) route
## DAP events through the correct ReplaySession.

import
  std / [ jsffi, jsconsole, strformat, asyncjs ],
  kdom,
  ../types,
  ../lib/[ jslib, logging ]

# ---------------------------------------------------------------------------
# Electron IPC access (renderer side)
# ---------------------------------------------------------------------------

var electron* {.importc.}: JsObject

# The session ID that this renderer window is bound to.  Defaults to 0
# (main window).  For secondary windows, this is set by
# registerInitSessionHandler / CODETRACER::init-session IPC.
var currentSessionId*: int = 0

proc ipcRenderer(): JsObject =
  ## Lazily obtain the ipcRenderer; returns nil/undefined when not in Electron.
  if not electron.isNil and not electron.isUndefined:
    return electron.ipcRenderer
  return nil

# ---------------------------------------------------------------------------
# Panel config serialisation
# ---------------------------------------------------------------------------

proc serializePanelConfig*(contentItem: GoldenContentItem): JsObject =
  ## Serialise a GL component's config + state for cross-window transfer.
  ## The returned JsObject is a plain JSON-compatible config that can be
  ## sent over IPC and used with `layout.addItem` on the receiving side.
  contentItem.toConfig().toJs

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
  ## it to the target window via the main process.
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

proc buildSendToWindowMenuItems*(
  contentItem: GoldenContentItem,
  sessionId: int,
  windows: JsObject
): seq[ContextMenuItem] =
  ## Build context menu items for each available target window.
  ## Only windows that belong to the same session are shown as active
  ## transfer targets — cross-session transfer is blocked because the
  ## target window's GL instance is bound to a different trace.
  var items: seq[ContextMenuItem] = @[]
  let winArray = windows["windows"]
  let winLen = cast[int](winArray.length)

  for i in 0 ..< winLen:
    let win = winArray[i]
    let windowId = win["id"].to(int)
    let windowTitle = win["title"].to(cstring)
    let winSessionId = win["sessionId"].to(int)
    # Capture for closure.
    let capturedWindowId = windowId
    let capturedSessionId = sessionId
    let capturedItem = contentItem

    if winSessionId == sessionId:
      # Compatible window — same session/trace.
      let label = cstring(fmt"Send to: {windowTitle}")
      items.add(ContextMenuItem(
        name: label,
        hint: cstring"",
        handler: proc(ev: kdom.Event) =
          detachAndSendPanel(capturedItem, capturedWindowId, capturedSessionId)
      ))
    # Incompatible windows (different session) are silently omitted.

  # Always offer "Send to New Window" which creates a secondary window
  # bound to this panel's session.
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

proc registerPanelAttachHandler*(layout: GoldenLayout) =
  ## Register the IPC handler that listens for incoming panel configs
  ## from other windows.  Call this once after the GL layout is initialised.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return

  ipc.on(cstring"CODETRACER::panel-attach", proc(event: JsObject, payload: JsObject) =
    let config = payload["panelConfig"]
    let sid = payload["sessionId"].to(int)
    # M22: Validate that the incoming panel belongs to the session this
    # window is displaying.  The main process already enforces this, but
    # we double-check on the renderer side for defence in depth.
    # ``currentSessionId`` is set by the ``CODETRACER::init-session`` IPC
    # handler when a secondary window is created, or defaults to 0 for
    # the main window.
    if sid != currentSessionId:
      cerror "panel_transfer: rejecting panel from session " & $sid &
        " - this window serves session " & $currentSessionId
      return
    console.log cstring"panel_transfer: attaching panel from session ", sid
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
    console.log cstring"panel_transfer: bound to session ", currentSessionId)
