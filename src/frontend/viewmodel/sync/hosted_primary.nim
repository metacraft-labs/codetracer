## sync/hosted_primary.nim — a session a server owns for the pages it serves.
##
## In the server-managed deployment (`ct host`, the container) the server, not
## the page, holds the primary `DebuggerSession` (Shared-DOM-Front-Ends D2),
## and publishes its panel ViewModels to every page connected to it over the
## page's socket (`socket_transport`). Each page renders a mirror
## (`mirror_session`).
##
## THE SERVER NEVER LAUNCHES THE REPLAY. The page still performs the replay's
## DAP handshake and still drives the components that are not ViewModels yet
## (the editor, the toolbar's step), so the server's session is a second
## client of THAT replay: it attaches on the first stop the replay reports and
## takes every later move from the replay's events (`followBackendMoves`). A
## replay of its own would leave the panels at one position and the editor at
## another.
##
## THE SESSION OUTLIVES CONNECTIONS. A reloaded page continues the replay where
## it was, so the session is kept when a page goes away, and a page that
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
    ## The primary's id on the server's `SyncHost`; a server hosts one.

type
  HostedPrimary* = ref object
    ## The server's primary session and the pages mirroring it.
    debugger*: DebuggerSession
    host*: SyncHost
    pages: seq[tuple[socket: JsObject; channel: SyncChannel]]

proc openHostedPrimary*(backend: BackendService; traceFolder: string;
                        sourceLanguageOf: proc(file: string): string = nil
                       ): HostedPrimary =
  ## The server's session over `backend`, for the trace in `traceFolder`.
  ## `sourceLanguageOf` names a file's language for `ct/load-locals`, as the
  ## page names it.
  let debugger = newDebuggerSession(backend)
  debugger.store.sourceLanguageOf = sourceLanguageOf
  let trace = localFolderTrace(traceFolder)
  let host = newSyncHost()
  # REGISTERED BEFORE `followBackendMoves`, so the session is attached — its
  # panels and its stop loader exist — before the first move is applied.
  # The first stop's position is taken BEFORE attaching, so the history's
  # first entry ("launch") is where the replay stopped, not the empty
  # position the store started with.
  backend.onEvent proc(event: JsonNode) =
    if debugger.phase.val != dspReady and not event.isNil and
       event.kind == JObject and
       event{"kind"}.getStr("") in CompleteMoveEventNames:
      debugger.store.applyCompleteMove(
        if event.hasKey("data"): event["data"] else: event)
      debugger.attach(trace)
      # PUBLISHED ONLY ONCE ATTACHED. The publisher mirrors the signals of
      # the panel ViewModels the session has when it is created, and
      # `attach` is what builds them: registered earlier, it mirrored the
      # store alone and a page never received what the state pane derives.
      # Registering activates the session for every page already connected.
      host.addPrimary(HostedSessionId, debugger.session)
  debugger.followBackendMoves()
  HostedPrimary(debugger: debugger, host: host)

proc pageCount*(h: HostedPrimary): int =
  h.pages.len

proc connectPage*(h: HostedPrimary; socket: JsObject) =
  ## Serve the page at the other end of `socket`: it is told to follow the
  ## server's session and receives its state as a snapshot.
  let channel = newSocketSyncChannel(socket)
  h.pages.add (socket, channel)
  h.host.attach(channel)

proc disconnectPage*(h: HostedPrimary; socket: JsObject) =
  ## Stop serving the page on `socket` (it closed, or another tab took over).
  ## The session is kept for the next page.
  for i in countdown(h.pages.high, 0):
    if h.pages[i].socket == socket:
      h.host.detach(h.pages[i].channel)
      closeSocketSyncChannel(h.pages[i].channel, socket)
      h.pages.delete(i)

proc close*(h: HostedPrimary) =
  ## End the session: the server is shutting down.
  for page in h.pages:
    h.host.detach(page.channel)
    closeSocketSyncChannel(page.channel, page.socket)
  h.pages = @[]
  h.host.dispose()
  h.debugger.dispose()
