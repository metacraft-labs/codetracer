## index/window_routing.nim — which desktop window hears what the main
## process says.
##
## The desktop opens more than one window: a session tab's "Open in New
## Window" and a pane tab's "Send to New Window"
## (`GUI/Multi-Window-Tab-Management.md` §"Multi-Window Behavior", §"Panel
## Transfer"). Each window is its own renderer with its own tabs, numbered
## from 0 in every window (§Tab Behavior rule 8), so a tab id names a tab
## only together with its window. The main process answers through one send
## path (`mainWindow.webContents.send`), long after a request and across
## awaits, and it used to send everything to the first window: a second
## window was sent no startup, no trace and no answer, and stayed blank.
##
## The rules, which mirror `ct host`'s clients (`host_clients`):
##
## * **An answer goes to the window that asked.** Every IPC handler runs inside
##   the context of the window whose renderer sent the request
##   (`runForSender`, Node's `AsyncLocalStorage` through `served_client`), and
##   the context follows the promises, timers and I/O the handler starts. The
##   send path (`routeSend`) sends to that window alone; if it has closed, the
##   message is dropped.
## * **What no window asked for** — startup, a watch of a file every window
##   reads — goes to every window, except a message that names a tab
##   (`tab`): tab ids are per window, and the startup's tabs are the first
##   window's, so such a message goes to the primary window (the first one
##   still open).
## * **A replay's answers and events go to the windows that show it.** Each
##   window records which replay each of its tabs shows (`tabReplays`, from
##   the replay selections it is sent and the replay its requests name). The
##   DAP router (`ipc_subsystems/dap`) sends an answer to the window and tab
##   that asked, and an event to every tab of every window showing the
##   replay, each under its own tab id — so stepping in one window moves the
##   other (§"Cross-Window Synchronization").
## * **A window that opens after startup is sent its session.** Each window
##   keeps, per tab, the latest of the messages that describe the tab's
##   session (`SessionChannels`: the trace, its files and symbols, its replay
##   selection). A new window for a tab gets the startup handshake, an `init`
##   and those messages re-addressed to its own first tab, and the replay's
##   latest stop (`latestEvents`): the bootstrap `ct host` gives a reloaded
##   page (`bootstrap_cache`).
##
## JS only. Desktop routing; `ct host` installs its own (`host_clients`), and
## this module's tables stay empty there.

when not defined(js):
  {.error: "index/window_routing runs in the index process (JS).".}

import std/[jsffi, tables]
import served_client

type
  WindowSend* = proc(channel: cstring; payload: JsObject)
    ## Send to one window, and to it only.

  SessionMessage = object
    channel: cstring
    payload: JsObject

  AppWindow* = ref object
    ## One desktop window.
    id*: int
      ## Its `BrowserWindow.id`: what the renderer names it by
      ## (`list-windows`, `panel-detach`).
    contentsId*: int
      ## Its `webContents.id`: what identifies the window an IPC request came
      ## from (`IpcMainEvent.sender`).
    window*: JsObject
      ## The `BrowserWindow`; a stand-in in the tests.
    rawSend*: WindowSend
    closed*: bool
    tabReplays*: Table[int, int]
      ## This window's tabs, each with the replay it shows.
    tabSession: Table[int, seq[SessionMessage]]
      ## Per tab, the latest message of each `SessionChannels` channel, in
      ## the order they were first sent.
    startup: seq[SessionMessage]
      ## The last of each `StartupChannels` message it was sent: what it
      ## shows when no tab has a session (the welcome screen).
    handshakeDone*: bool
      ## Whether its renderer answered `CODETRACER::started`.
    onHandshake*: proc()
      ## Run once when it does (a window opened after startup: its bootstrap).
    clientStore: JsObject
      ## The context store every request of this window runs in
      ## (`runAsWindow`). ONE object for the window's life: it is the client
      ## `served_client.currentClientKey` names, so the ids a page chooses
      ## itself (the Agent Activity pane's `agent-session-0`) keep their state
      ## from one request of the window to the next.

const
  WindowKeyField = cstring"ctDesktopWindow"
    ## The field of the context store that names the window being served.
  ReplaySelectionChannels = [cstring"CODETRACER::dap-replay-selected",
                             cstring"CODETRACER::dap-live-session-selected"]
  SessionChannels* = [
    cstring"CODETRACER::no-trace",
    cstring"CODETRACER::filenames-loaded",
    cstring"CODETRACER::filesystem-loaded",
    cstring"CODETRACER::symbols-loaded",
    cstring"CODETRACER::trace-loaded",
    cstring"CODETRACER::trace-load-error",
    cstring"CODETRACER::dap-replay-selected",
    cstring"CODETRACER::dap-live-session-selected"]
    ## The messages that describe a tab's session: what a window opened for
    ## the tab is sent (the per-tab half of `bootstrap_cache.bootstrapEvents`).
  StartupChannels* = [
    cstring"CODETRACER::welcome-screen",
    cstring"CODETRACER::recent-items"]
    ## The startup messages that name no tab: a window started on the welcome
    ## screen has no tab session, and a reload sends it these again
    ## (`bootstrapReloadedWindow`).
  LatestEventNames* = [cstring"ct/complete-move"]
    ## A replay's events whose latest is a window's starting state: the stop
    ## the replay is at (`bootstrap_cache.bootstrapDapEvents`).

var windows*: seq[AppWindow] = @[]
  ## Every open window, the first opened first.
iterator allWindows*(): AppWindow =
  ## Every registered window, by value: a `for` over `windows` itself yields
  ## `lent` refs, which a closure in the loop body may not capture. Iterates
  ## over a snapshot, so the body may open or close windows.
  let snapshot = windows
  for i in 0 ..< snapshot.len:
    yield snapshot[i]

var latestEvents: Table[int, Table[cstring, JsObject]] =
    initTable[int, Table[cstring, JsObject]]()
  ## Per replay, the latest event of each `LatestEventNames` kind.

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs:
  "(function (o, k) { return o != null && Object.prototype.hasOwnProperty.call(o, k); })(#, #)".}
proc jsAssign(target, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}

proc hasField(obj: JsObject; key: cstring): bool =
  jsHasKey(obj, key)

proc copyOf*(payload: JsObject): JsObject =
  ## A shallow copy, so one window's re-addressing does not reach another's.
  jsAssign(newJsObject(), payload)

proc tabOf*(payload: JsObject): int =
  ## The tab a message names (`tab_answers`), or -1 when it names none.
  if payload.isNil or payload.isUndefined or not payload.hasField(cstring"tab"):
    return -1
  let tab = payload[cstring"tab"]
  if tab.isNull or tab.isUndefined: -1 else: tab.to(int)

# ---------------------------------------------------------------------------
# The windows
# ---------------------------------------------------------------------------

proc registerAppWindow*(id, contentsId: int; window: JsObject;
                        rawSend: WindowSend): AppWindow =
  ## Add a window. The first registered is the primary one until it closes.
  result = AppWindow(id: id, contentsId: contentsId, window: window,
                     rawSend: rawSend, tabReplays: initTable[int, int](),
                     tabSession: initTable[int, seq[SessionMessage]](),
                     clientStore: newJsObject())
  result.clientStore[WindowKeyField] = id
  windows.add result

proc closeAppWindow*(w: AppWindow): seq[int] =
  ## `w` closed: forget it. Returns the replays it showed that no other
  ## window shows, which the caller stops.
  if w.isNil or w.closed:
    return
  w.closed = true
  let i = windows.find(w)
  if i >= 0:
    windows.delete(i)
  for replay in w.tabReplays.values:
    var shownElsewhere = false
    for other in allWindows():
      for r in other.tabReplays.values:
        if r == replay:
          shownElsewhere = true
    if not shownElsewhere and replay notin result:
      result.add replay
  w.tabReplays.clear()

proc primaryWindow*(): AppWindow =
  ## The first window still open, or nil.
  for w in allWindows():
    if not w.closed:
      return w
  nil

proc windowWithId*(id: int): AppWindow =
  for w in allWindows():
    if w.id == id and not w.closed:
      return w
  nil

proc windowWithContentsId*(contentsId: int): AppWindow =
  for w in allWindows():
    if w.contentsId == contentsId and not w.closed:
      return w
  nil

proc openWindowCount*(): int =
  for w in allWindows():
    if not w.closed:
      inc result

# ---------------------------------------------------------------------------
# Which window is being served
# ---------------------------------------------------------------------------

proc currentWindowKey*(): int =
  ## The id of the window whose request the running code serves, or -1
  ## outside every window's context (startup, a shared watch, the tests).
  let store = currentClient()
  if store.isNil or not store.hasField(WindowKeyField):
    return -1
  store[WindowKeyField].to(int)

proc currentWindow*(): AppWindow =
  ## The window being served, if it is still open; nil otherwise.
  let key = currentWindowKey()
  if key < 0: nil else: windowWithId(key)

proc requestingWindow*(): AppWindow =
  ## The window an action is for: the one being served, else the primary.
  ## Nil while no window is open, or when the asking window has closed.
  let key = currentWindowKey()
  if key >= 0: windowWithId(key) else: primaryWindow()

proc requestingBrowserWindow*(): JsObject =
  ## The `BrowserWindow` of `requestingWindow`, or nil: for the Electron APIs
  ## that take a real window (a dialog's parent), which the desktop's
  ## `mainWindow` proxy is not.
  let w = requestingWindow()
  if w.isNil: nil else: w.window

proc runAsWindow*(w: AppWindow; fn: proc()) =
  ## Run `fn`, and what it starts, as serving `w`.
  ## Every call for one window runs in that window's own store: a fresh
  ## store per call made each request a new client, and state a page keyed
  ## by its own ids (an agent session started by one request, prompted by
  ## the next) was lost between them.
  if w.isNil:
    fn()
  else:
    runAsClient(w.clientStore, fn)

proc runForSender*(event: JsObject; fn: proc()) =
  ## Run an IPC handler as serving the window whose renderer sent `event`
  ## (an `IpcMainEvent`; its `sender` is that window's `webContents`).
  ## Outside every window's context when the sender is no registered window
  ## (the install dialog's subwindow).
  var w: AppWindow = nil
  if not event.isNil and not event.isUndefined and
      event.hasField(cstring"sender"):
    let contents = event[cstring"sender"]
    if not contents.isNil and not contents.isUndefined:
      let id = contents[cstring"id"]
      if not id.isUndefined:
        w = windowWithContentsId(id.to(int))
  runAsWindow(w, fn)

# ---------------------------------------------------------------------------
# What a window keeps of its tabs' sessions
# ---------------------------------------------------------------------------

proc noteTabReplay*(w: AppWindow; tab, replayId: int) =
  ## `w`'s tab `tab` shows replay `replayId`.
  if w.isNil or tab < 0 or replayId < 0:
    return
  w.tabReplays[tab] = replayId

proc forgetReplay*(replayId: int) =
  ## `replayId` stopped: no tab shows it any more.
  for w in allWindows():
    var tabs: seq[int] = @[]
    for tab, replay in w.tabReplays:
      if replay == replayId:
        tabs.add tab
    for tab in tabs:
      w.tabReplays.del tab
  latestEvents.del replayId

proc releaseReplay*(w: AppWindow; replayId: int): bool =
  ## `w` (nil: the primary window) is done with `replayId` — its tab closed,
  ## or Stop was pressed in it. Whether the replay may stop: no other window
  ## shows it.
  let asker = if w.isNil: primaryWindow() else: w
  result = true
  for other in allWindows():
    if other.closed:
      continue
    if other == asker:
      var tabs: seq[int] = @[]
      for tab, replay in other.tabReplays:
        if replay == replayId:
          tabs.add tab
      for tab in tabs:
        other.tabReplays.del tab
    else:
      for replay in other.tabReplays.values:
        if replay == replayId:
          result = false

proc remember(w: AppWindow; tab: int; channel: cstring; payload: JsObject) =
  var messages = w.tabSession.getOrDefault(tab)
  # A load that succeeded replaces the failure before it, and the other way
  # round: the tab's session is what was said last.
  let drop =
    if channel == cstring"CODETRACER::trace-loaded": cstring"CODETRACER::trace-load-error"
    elif channel == cstring"CODETRACER::trace-load-error": cstring"CODETRACER::trace-loaded"
    else: cstring""
  var kept: seq[SessionMessage] = @[]
  var replaced = false
  for m in messages:
    if m.channel == drop:
      continue
    if m.channel == channel:
      kept.add SessionMessage(channel: channel, payload: payload)
      replaced = true
    else:
      kept.add m
  if not replaced:
    kept.add SessionMessage(channel: channel, payload: payload)
  w.tabSession[tab] = kept

proc note(w: AppWindow; channel: cstring; payload: JsObject) =
  ## What `w` is told about one of its tabs' sessions, and its startup.
  if channel in StartupChannels:
    var kept: seq[SessionMessage] = @[]
    for m in w.startup:
      if m.channel != channel:
        kept.add m
    kept.add SessionMessage(channel: channel, payload: payload)
    w.startup = kept
    return
  let tab = tabOf(payload)
  if tab < 0 or channel notin SessionChannels:
    return
  w.remember(tab, channel, payload)
  if channel in ReplaySelectionChannels and payload.hasField(cstring"replayId"):
    w.noteTabReplay(tab, payload[cstring"replayId"].to(int))

proc tabSessionMessages*(w: AppWindow; tab: int): seq[(cstring, JsObject)] =
  ## What `w` was last told about its tab `tab`'s session, in order.
  if w.isNil:
    return
  for m in w.tabSession.getOrDefault(tab):
    result.add (m.channel, m.payload)

proc forgetTab*(w: AppWindow; tab: int) =
  if w.isNil:
    return
  w.tabSession.del tab
  w.tabReplays.del tab

# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------

proc sendTo*(w: AppWindow; channel: cstring; payload: JsObject) =
  ## Send to `w` alone, keeping what it says about a tab's session.
  if w.isNil or w.closed:
    return
  w.note(channel, payload)
  w.rawSend(channel, payload)

proc routeSend*(channel: cstring; payload: JsObject) =
  ## The main process's send path (`mainWindow.webContents.send`): to the
  ## window being served; outside every window's context, a message naming a
  ## tab to the primary window and any other message to every window.
  let key = currentWindowKey()
  if key >= 0:
    let w = windowWithId(key)
    if w.isNil:
      # The window that asked has closed: no other window's tab is the one
      # this answers.
      return
    w.sendTo(channel, payload)
  elif tabOf(payload) >= 0:
    primaryWindow().sendTo(channel, payload)
  else:
    for w in allWindows():
      w.sendTo(channel, payload)

# ---------------------------------------------------------------------------
# A replay's messages
# ---------------------------------------------------------------------------

type
  ReplayViewer* = object
    window*: AppWindow
    tab*: int

proc viewersOf*(replayId: int): seq[ReplayViewer] =
  ## Every tab, of every window, that shows `replayId`.
  for w in allWindows():
    if w.closed:
      continue
    for tab, replay in w.tabReplays:
      if replay == replayId:
        result.add ReplayViewer(window: w, tab: tab)

proc deliverToTab*(w: AppWindow; tab: int; channel: cstring; body: JsObject) =
  ## A replay's answer or event to `w`'s tab `tab`, under that tab's id.
  if w.isNil or w.closed:
    return
  let forTab = copyOf(body)
  forTab[cstring"sessionId"] = tab
  w.rawSend(channel, forTab)

proc noteReplayEvent*(replayId: int; body: JsObject) =
  ## Keep the latest event of a `LatestEventNames` kind of `replayId`.
  if replayId < 0 or not body.hasField(cstring"event"):
    return
  let name = body[cstring"event"].to(cstring)
  if name notin LatestEventNames:
    return
  if not latestEvents.hasKey(replayId):
    latestEvents[replayId] = initTable[cstring, JsObject]()
  latestEvents[replayId][name] = body

proc latestReplayEvents*(replayId: int): seq[JsObject] =
  if latestEvents.hasKey(replayId):
    for body in latestEvents[replayId].values:
      result.add body

# ---------------------------------------------------------------------------
# A window opened after startup
# ---------------------------------------------------------------------------

const NewWindowTab* = 0
  ## The tab a window opened for a session shows it in: the window's first
  ## (`types.allocateSessionId`).

proc bootstrapWindow*(w, source: AppWindow; sourceTab: int; init: JsObject;
                      layout: JsObject = nil) =
  ## Send `w`, a window opened for `source`'s tab `sourceTab`, that tab's
  ## session, once `w`'s renderer listens: `init` (the window's startup
  ## message: layout, config, helpers), the messages that told `source` about
  ## the tab's session re-addressed to `w`'s first tab, `init-session` (that
  ## tab and its replay) and the replay's latest stop. `w`'s first tab then
  ## shows the replay, and the replay's events reach it with `source`'s.
  ##
  ## An edit session (a `no-trace` and no trace) has no `init`: its
  ## `no-trace` is its startup message, as at startup (`startup.init`), and
  ## carries `layout` when one is given.
  let messages = source.tabSessionMessages(sourceTab)
  let replayId = if source.isNil: -1 else: source.tabReplays.getOrDefault(sourceTab, -1)
  var editSession = false
  var traceSession = false
  for (channel, _) in messages:
    if channel == cstring"CODETRACER::no-trace": editSession = true
    if channel == cstring"CODETRACER::trace-loaded": traceSession = true
  if traceSession or not editSession:
    let forNewTab = copyOf(init)
    forNewTab[cstring"tab"] = NewWindowTab
    w.sendTo(cstring"CODETRACER::init", forNewTab)
  for (channel, payload) in messages:
    if channel == cstring"CODETRACER::no-trace" and traceSession:
      continue
    let forNewTab = copyOf(payload)
    forNewTab[cstring"tab"] = NewWindowTab
    if channel == cstring"CODETRACER::no-trace" and not layout.isNil:
      forNewTab[cstring"layout"] = layout
    w.sendTo(channel, forNewTab)
  w.noteTabReplay(NewWindowTab, replayId)
  w.sendTo(cstring"CODETRACER::init-session",
           js{"sessionId": NewWindowTab, "replayId": replayId})
  if replayId >= 0:
    for event in latestReplayEvents(replayId):
      w.deliverToTab(NewWindowTab, cstring"CODETRACER::dap-receive-event", event)

proc bootstrapReloadedWindow*(w: AppWindow; init: JsObject) =
  ## `w`'s page reloaded (the disconnect notice's Reconnect, a forced reload):
  ## its new renderer has one tab, the first, and has been told nothing. It
  ## is sent the session of its first tab that had one, as a window opened
  ## for that tab is (`bootstrapWindow`), and its other tabs are forgotten:
  ## the page that showed them is gone. A window whose tabs had none (it was
  ## started on the welcome screen) is sent its startup messages again. Without it the main process, which
  ## sends a window its session once, left the reloaded window an empty
  ## surface (codetracer-pm issue 2026-11-17 "a reloaded edit-mode window
  ## stays blank").
  var tabs: seq[int] = @[]
  for tab in w.tabSession.keys:
    tabs.add tab
  var first = -1
  for tab in tabs:
    if first < 0 or tab < first:
      first = tab
  if first < 0:
    # No tab had a session: the window showed what its startup sent it (the
    # welcome screen and its recent items), which is sent again.
    # A copy: each send records itself in `w.startup` again.
    let startup = w.startup
    for m in startup:
      w.sendTo(m.channel, m.payload)
    return
  bootstrapWindow(w, w, first, init)
  for tab in tabs:
    if tab != NewWindowTab:
      w.forgetTab(tab)

# ---------------------------------------------------------------------------
# `mainWindow` on the desktop
# ---------------------------------------------------------------------------

proc newWindowRouter(resolve: proc(): JsObject;
                     send: proc(channel: cstring; payload: JsObject)): JsObject {.importjs: """
  (function (resolve, send) {
    function bound(target, prop) {
      if (target == null) return undefined;
      var value = target[prop];
      return typeof value === 'function' ? value.bind(target) : value;
    }
    var contents = new Proxy({}, {
      get: function (_, prop) {
        if (prop === 'send') return send;
        var w = resolve();
        return bound(w == null ? null : w.webContents, prop);
      }
    });
    return new Proxy({}, {
      get: function (_, prop) {
        if (prop === 'webContents') return contents;
        return bound(resolve(), prop);
      },
      set: function (_, prop, value) {
        var w = resolve();
        if (w != null) w[prop] = value;
        return true;
      }
    });
  })(#, #)""".}

proc windowRouter*(): JsObject =
  ## What the desktop's `mainWindow` is: the window an action is for
  ## (`requestingWindow`), whose `webContents.send` is `routeSend`. Code that
  ## minimises, closes or titles "the window" acts on the window that asked.
  newWindowRouter(
    proc(): JsObject =
      let w = requestingWindow()
      if w.isNil: nil else: w.window,
    proc(channel: cstring; payload: JsObject) =
      routeSend(channel, payload))
