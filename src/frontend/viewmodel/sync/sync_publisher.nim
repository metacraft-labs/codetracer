## sync/sync_publisher.nim
##
## `SyncPublisher` — observes every mirrored signal of a primary session
## (`synced_signals`) and publishes what changed as REVISIONED BATCHES.
##
## One reactive change usually writes several signals (a move writes the
## debugger state, the timeline, the locals' loading state, …). The publisher
## collects the changes, latest value per signal, and cuts one batch per turn
## of the host's event loop: a mirror then applies the whole move at once and
## never shows a panel from before it beside a panel from after it
## (ViewModel-State-Mirroring.md, "Consistency Across Messages"). Each batch
## carries the session's id and a revision one higher than the last, so a
## mirror can tell a stale or out-of-order message from the next one.
##
## A newly attached mirror is brought up to date with `snapshot`, which
## carries every signal at the current revision; the batches after it follow
## from there.
##
## Wire format:
##
##   {"type": "signal-batch",    "session": id, "revision": n, "batch": [{"key", "value"}, …]}
##   {"type": "signal-snapshot", "session": id, "revision": n, "batch": [{"key", "value"}, …]}
##
## Works on both the C and JS backends.

import std/[json, tables]

import isonim/core/[computation, owner]

import ../session_vm
import ../collab/[codec, session_core]
import synced_signals

type
  Scheduler* = proc(callback: proc())
    ## Runs `callback` once the current turn of the event loop is over.

  SyncPublisher* = ref object
    sessionId*: string
    registry*: SyncRegistry
    collabCore: CollaborativeSessionCore
      ## The session's shared view state (chosen tabs, expanded rows,
      ## watches), sent whole with every snapshot: it is a document, not a
      ## set of signals, and the panes' view signals are projections of it.
    revision*: int
      ## The revision of the last batch published (0: none yet).
    publishProc: proc(msg: JsonNode)
    schedule: Scheduler
    pending: OrderedTable[string, JsonNode]
    scheduled: bool
    disposeRoot: proc()
    disposed: bool

when defined(js):
  proc queueMicrotask(callback: proc()) {.importjs: "queueMicrotask(#)".}

proc defaultScheduler*(): Scheduler =
  ## The host's own deferral: a microtask on JS, which the platform runs
  ## without being asked. On C there is no mirroring host; the batch is cut
  ## at once.
  when defined(js):
    result = proc(callback: proc()) = queueMicrotask(callback)
  else:
    result = proc(callback: proc()) = callback()

proc flush*(pub: SyncPublisher) =
  ## Publish what changed since the last batch, as one batch. Nothing is sent
  ## when nothing changed.
  pub.scheduled = false
  if pub.disposed or pub.pending.len == 0:
    return
  var batch = newJArray()
  for key, value in pub.pending:
    batch.add %*{"key": key, "value": value}
  pub.pending.clear()
  inc pub.revision
  pub.publishProc(%*{"type": "signal-batch", "session": pub.sessionId,
                     "revision": pub.revision, "batch": batch})

proc snapshot*(pub: SyncPublisher): JsonNode =
  ## Every mirrored signal at the current revision. Pending changes are
  ## published first, so the snapshot's revision is the last batch's and the
  ## next batch follows it.
  pub.flush()
  result = %*{"type": "signal-snapshot", "session": pub.sessionId,
              "revision": pub.revision, "batch": pub.registry.snapshot()}
  if not pub.collabCore.isNil:
    result["collab"] = pub.collabCore.joinSnapshot.toJson

proc observe(pub: SyncPublisher; signal: SyncedSignal) =
  ## One effect per signal. A proc of its own, not a closure built in the
  ## caller's loop: Nim closures created in a loop share the loop's
  ## variables, and every effect would observe the last signal.
  createEffect proc() =
    let value = signal.read()
    pub.pending[signal.key] = value
    if not pub.scheduled:
      pub.scheduled = true
      pub.schedule(proc() = pub.flush())

proc createSyncPublisher*(session: SessionViewModel; sessionId: string;
                          publish: proc(msg: JsonNode);
                          schedule: Scheduler = nil): SyncPublisher =
  ## Observe `session`'s mirrored signals and send each batch to `publish`.
  ## `schedule` decides when a batch is cut (`defaultScheduler` when nil).
  ##
  ## The publisher owns its effects in a reactive root of its own, so
  ## `dispose` ends them whatever root the caller is in.
  let pub = SyncPublisher(
    sessionId: sessionId,
    registry: syncedSignalsOf(session),
    collabCore: session.collabCore,
    publishProc: publish,
    schedule: (if schedule.isNil: defaultScheduler() else: schedule),
    pending: initOrderedTable[string, JsonNode](),
    # Held while the effects take their first reading, so construction
    # schedules no batch.
    scheduled: true)
  createRoot proc(dispose: proc()) =
    pub.disposeRoot = dispose
    for signal in pub.registry.signals:
      pub.observe(signal)
  # The effects' first runs recorded every signal's initial value. That is
  # the snapshot's job, not a batch's: a mirror attaches with `snapshot`.
  pub.pending.clear()
  pub.scheduled = false
  pub

proc dispose*(pub: SyncPublisher) =
  ## Stop observing. A batch already scheduled sends nothing.
  if pub.isNil or pub.disposed:
    return
  pub.disposed = true
  if not pub.disposeRoot.isNil:
    pub.disposeRoot()
