## sync/hosted_primary.nim — sessions a server owns for the pages it serves.
##
## In the server-managed deployment (`ct host`, the container) the server, not
## the page, holds the primary `DebuggerSession` (Shared-DOM-Front-Ends D2),
## and publishes its panel ViewModels to the pages connected to it over each
## page's socket (`socket_transport`). Each page renders a mirror
## (`mirror_session`).
##
## ONE SESSION PER REPLAY TAB OF EACH CLIENT. `ct host` gives every client its
## own replay and its own session for each of its page's replay tabs
## (`CLI/ct/host.md`, "Sessions are isolated"; Shared-DOM-Front-Ends D2;
## `index/host_clients`), all on one `SyncHost` (`HostedSessions`). A page's
## tab is attached PINNED to its own session (`sync_host.attach(…, follow)`),
## over that tab's event on the page's socket
## (`socket_transport.sessionSyncEventFor`): it is told to follow that
## session only and cannot subscribe to or act on another tab's or another
## client's.
##
## THE SERVER NEVER LAUNCHES THE REPLAY. The page still performs its replay's
## DAP handshake and still drives the components that are not ViewModels yet
## (the editor, the toolbar's step), so the server's session is a second
## client of THAT replay: it attaches on the first stop the replay reports and
## takes every later move from the replay's events (`followBackendMoves`). A
## replay of its own would leave the panels at one position and the editor at
## another.
##
## THE SESSION OUTLIVES CONNECTIONS. A reloaded page continues its replay
## where it was, so a session is kept when its page goes away, and a page that
## connects receives its current state as a snapshot.
##
## Backend-agnostic: the server passes the `BackendService` over its own
## connection to the replay (`index/hosted_session`); a test passes a mock.
## JS only, because a page is reached over a socket.

when not defined(js):
  {.error: "sync/hosted_primary serves pages over sockets (JS only).".}

import std/[json, jsffi]

import isonim/core/signals   # `Signal.val`, the session's phase

import ../backend/backend_service
import ../sdk/[debugger_session, trace_source]
import ../store/replay_data_store
import socket_transport, sync_host, transport

const
  HostedSessionId* = "ct-host"
    ## The primary's id in a host made for one session
    ## (`openHostedPrimary(backend, traceFolder)`).

type
  HostedSessions* = ref object
    ## The sessions one server owns, on one `SyncHost`.
    host*: SyncHost

  HostedPrimary* = ref object
    ## One session the server owns and the pages mirroring it.
    id*: string
      ## Its id on the host; the id the pages are told to follow.
    debugger*: DebuggerSession
    host*: SyncHost
    ownsHost: bool
      ## Made for this session alone, so closing it disposes the host too.
    closed: bool
    pages: seq[tuple[socket: JsObject; channel: SyncChannel; event: string]]

proc newHostedSessions*(): HostedSessions =
  HostedSessions(host: newSyncHost())

proc open(host: SyncHost; id: string; backend: BackendService;
          traceFolder: string; sourceLanguageOf: proc(file: string): string
         ): HostedPrimary =
  let debugger = newDebuggerSession(backend)
  debugger.store.sourceLanguageOf = sourceLanguageOf
  let trace = localFolderTrace(traceFolder)
  let h = HostedPrimary(id: id, debugger: debugger, host: host)
  # REGISTERED BEFORE `followBackendMoves`, so the session is attached — its
  # panels and its stop loader exist — before the first move is applied.
  # The first stop's position is taken BEFORE attaching, so the history's
  # first entry ("launch") is where the replay stopped, not the empty
  # position the store started with.
  backend.onEvent proc(event: JsonNode) =
    if not h.closed and debugger.phase.val != dspReady and not event.isNil and
       event.kind == JObject and
       event{"kind"}.getStr("") in CompleteMoveEventNames:
      debugger.store.applyCompleteMove(
        if event.hasKey("data"): event["data"] else: event)
      debugger.attach(trace)
      # PUBLISHED ONLY ONCE ATTACHED. The publisher mirrors the signals of
      # the panel ViewModels the session has when it is created, and
      # `attach` is what builds them: registered earlier, it mirrored the
      # store alone and a page never received what the state pane derives.
      # Registering activates the session for the pages pinned to it.
      host.addPrimary(id, debugger.session)
  debugger.followBackendMoves()
  h

proc openHostedPrimary*(sessions: HostedSessions; id: string;
                        backend: BackendService; traceFolder: string;
                        sourceLanguageOf: proc(file: string): string = nil
                       ): HostedPrimary =
  ## Session `id` among `sessions`, over `backend`, for the trace in
  ## `traceFolder`. `sourceLanguageOf` names a file's language for
  ## `ct/load-locals`, as the page names it.
  open(sessions.host, id, backend, traceFolder, sourceLanguageOf)

proc openHostedPrimary*(backend: BackendService; traceFolder: string;
                        sourceLanguageOf: proc(file: string): string = nil
                       ): HostedPrimary =
  ## A session on a host of its own (`HostedSessionId`).
  result = open(newSyncHost(), HostedSessionId, backend, traceFolder,
                sourceLanguageOf)
  result.ownsHost = true

proc connectPage*(h: HostedPrimary; socket: JsObject; tab = 0) =
  ## Serve the page at the other end of `socket`, whose tab `tab` (its tab id)
  ## mirrors this session: that tab is told to follow THIS session, and only
  ## this one, and receives its state as a snapshot.
  let event = sessionSyncEventFor(tab)
  let channel = newSocketSyncChannel(socket, event)
  h.pages.add (socket, channel, event)
  h.host.attach(channel, follow = h.id)

proc disconnectPage*(h: HostedPrimary; socket: JsObject) =
  ## Stop serving the page on `socket` (it closed, or another tab of the same
  ## client took over). The session is kept for the next page.
  for i in countdown(h.pages.high, 0):
    if h.pages[i].socket == socket:
      h.host.detach(h.pages[i].channel)
      closeSocketSyncChannel(h.pages[i].channel, socket, h.pages[i].event)
      h.pages.delete(i)

proc close*(h: HostedPrimary) =
  ## End the session: its tab was closed, its client is gone, or the server
  ## is shutting down.
  if h.closed:
    return
  h.closed = true
  for page in h.pages:
    h.host.detach(page.channel)
    closeSocketSyncChannel(page.channel, page.socket, page.event)
  h.pages = @[]
  h.host.removePrimary(h.id)
  if h.ownsHost:
    h.host.dispose()
  h.debugger.dispose()
