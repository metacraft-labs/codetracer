## sync/sync_publisher.nim
##
## SyncPublisher — observes primary ViewModel signals and publishes
## changes as JSON messages for transmission to mirror processes.
##
## Creates reactive effects that watch every observable signal in the
## ReplayDataStore. When a signal changes, the effect serializes the
## new value and calls the user-provided `publishProc`.
##
## The publisher is OPTIONAL: in same-process mode it is never created.
## Only the multi-process (primary + view) architecture uses it.
##
## Usage:
##   let publisher = createSyncPublisher(session, proc(msg: JsonNode) =
##     websocket.send($msg)
##   )

import std/json

import isonim/core/[signals, computation, owner]

import signal_serializer
import ../store/[replay_data_store, types]

type
  SyncPublisher* = ref object
    ## Watches primary ViewModel signals and publishes changes.
    ##
    ## Fields:
    ##   session     — the primary SessionViewModel whose signals are watched
    ##   publishProc — callback invoked with each serialized signal update
    session*: SessionViewModel
    publishProc*: proc(msg: JsonNode)

proc createSyncPublisher*(session: SessionViewModel,
                          publish: proc(msg: JsonNode)): SyncPublisher =
  ## Create a SyncPublisher that observes all ViewModel signals on `session`
  ## and calls `publish` whenever any of them change.
  ##
  ## Must be called inside a reactive root (e.g. createRoot or withViewModel)
  ## so that the created effects are properly owned and disposed.
  ##
  ## Each effect reads one signal (or a small group of related signals),
  ## serializes the value, and calls publish. The publish callback is
  ## responsible for batching and transport (e.g. WebSocket, IPC pipe).
  result = SyncPublisher(session: session, publishProc: publish)

  let store = session.store
  let pub = publish  # capture for closures

  # -- Session state --
  createEffect proc() =
    let state = store.session.val
    pub(serializeSignalUpdate("session", "state", state.toJson))

  # -- Debugger state --
  createEffect proc() =
    let state = store.debugger.val
    pub(serializeSignalUpdate("debugger", "state", state.toJson))

  # -- Timeline state --
  createEffect proc() =
    let state = store.timeline.val
    pub(serializeSignalUpdate("timeline", "state", state.toJson))

  # -- Calltrace signals --
  createEffect proc() =
    let lines = store.calltrace.lines.val
    pub(serializeSignalUpdate("calltrace", "lines", lines.toJson))

  createEffect proc() =
    let idx = store.calltrace.startLineIndex.val
    pub(serializeSignalUpdate("calltrace", "startLineIndex", %idx))

  createEffect proc() =
    let count = store.calltrace.totalCallsCount.val
    pub(serializeSignalUpdate("calltrace", "totalCallsCount", %count))

  createEffect proc() =
    let finished = store.calltrace.finished.val
    pub(serializeSignalUpdate("calltrace", "finished", %finished))

  # -- Locals signals --
  createEffect proc() =
    let locals = store.locals.locals.val
    pub(serializeSignalUpdate("locals", "locals", locals.toJson))

  createEffect proc() =
    let globals = store.locals.globals.val
    pub(serializeSignalUpdate("locals", "globals", globals.toJson))
