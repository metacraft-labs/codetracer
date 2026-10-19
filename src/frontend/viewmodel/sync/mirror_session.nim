## sync/mirror_session.nim
##
## `MirrorSession` — the mirror half: a `SessionViewModel` whose signals are
## written by a primary somewhere else (`sync_host`), over a `SyncChannel`.
##
## A mirror's panel ViewModels are the same ViewModels a primary has, built by
## the same `initializePanelViewModels`, so the views a webview or a page
## renders are unchanged; only where their data comes from differs. Two things
## keep the mirror from acting on its own:
##
## - its backend is INERT: every request it would send stays pending forever.
##   A panel ViewModel's effect may still ask (they ask when the position
##   changes), but nothing answers, so nothing it does locally overwrites the
##   loading state, the rows or the errors the primary's batches carry;
## - its runtime role is a collaborator's (`vrrCollaborator`), the role the
##   ViewModels already read as "render, do not issue backend commands".
##
## Actions go the other way: `relay` sends a ViewModel action to the primary,
## which runs it, and the outcome arrives as the primary's next batch. The
## measured viewport is one such action (`setViewport`).
##
## Works on both the C and JS backends.

import std/json

import isonim/core/[async_compat, owner]

import ../backend/backend_service
import ../collab/runtime_role
import ../collab/[codec, session_core, types as collab_types]
import ../session_vm
import action_relay, sync_subscriber, transport

when defined(js):
  import std/asyncjs

type
  MirrorSession* = ref object
    session*: SessionViewModel
      ## The mirrored ViewModels a view renders.
    subscriber*: SyncSubscriber
    channel*: SyncChannel
    following*: string
      ## The primary session mirrored; "" before the host names one.
    unknownSession*: string
      ## The last session the host said it does not have.
    disposeRoot: proc()

proc inertBackend*(): BackendService =
  ## A backend that never answers and emits nothing: what a mirror's
  ## ViewModels talk to. A request that never settles leaves the state the
  ## primary published in place, where an immediate failure would overwrite
  ## it with a local error.
  BackendService(
    sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
      when defined(js):
        newPromise(proc(resolve: proc(response: JsonNode)) = discard)
      else:
        newFuture[JsonNode]("mirror inert backend"),
    onEventProc: proc(handler: EventHandler) = discard,
    disconnectProc: proc() = discard)

proc switchTo*(m: MirrorSession; sessionId: string) =
  ## Follow the primary session `sessionId`: ask for its snapshot, and apply
  ## its batches from then on. Messages about the session left are refused
  ## from this moment, so a late batch cannot show it again.
  m.following = sessionId
  m.subscriber.follow(sessionId)
  m.channel.send(%*{"type": "subscribe", "session": sessionId})

proc onHostMessage(m: MirrorSession; msg: JsonNode) =
  if msg.isNil or msg.kind != JObject:
    return
  case msg{"type"}.getStr("")
  of "activate":
    let id = msg{"session"}.getStr("")
    if id.len > 0 and id != m.following:
      m.switchTo(id)
  of "session-unknown":
    m.unknownSession = msg{"session"}.getStr("")
  of "signal-batch", "signal-snapshot":
    let wasInStep = m.subscriber.inStep
    discard m.subscriber.onMessage(msg)
    # A lost revision: the mirror is out of step, and a new snapshot is the
    # only way back. Asked once per loss, not once per later batch.
    if wasInStep and not m.subscriber.inStep:
      m.channel.send(%*{"type": "subscribe", "session": m.following})
  else:
    discard

proc createMirrorSession*(channel: SyncChannel): MirrorSession =
  ## A mirror over `channel`. It follows the session the host activates, or
  ## the one `switchTo` names.
  let m = MirrorSession(channel: channel)
  createRoot proc(dispose: proc()) =
    m.disposeRoot = dispose
    m.session = createSessionVM(inertBackend(), vrrCollaborator)
    m.session.initializePanelViewModels()
  m.subscriber = createSyncSubscriber(m.session)
  channel.setHandler(proc(msg: JsonNode) = m.onHostMessage(msg))
  # THE VIEW STATE IS THE PRIMARY'S. A tab chosen, a row expanded or a watch
  # added in a mirror's pane goes through the session's collaboration core
  # (`dispatchLocalViewOp`), which applies it locally at once; publishing it
  # here sends it on to the primary (`action_relay`'s `collab` arm), whose
  # next batch confirms it for every mirror. Without it the primary's next
  # batch would undo the user's click.
  let core = m.session.collabCore
  if not core.isNil:
    core.collaborationEnabled = true
    core.publishLocalViewOp = proc(op: ViewOpEnvelope): bool =
      if m.following.len == 0:
        return false
      m.channel.send(serializeAction("collab", "viewop", op.toJson,
                                     m.following))
      true
  # Ask which session to follow: the host's `activate` at attach may have
  # been sent before this mirror existed to hear it.
  channel.send(%*{"type": "hello"})
  m

proc relay*(m: MirrorSession; vm, action: string;
            args: JsonNode = newJObject()) =
  ## Run `vm`.`action` on the primary this mirror follows. Encode typed
  ## arguments with `action_relay.actionArg`.
  m.channel.send(serializeAction(vm, action, args, m.following))

proc setViewport*(m: MirrorSession; pane: string; rows: int; depth = 0;
                  firstRow = -1) =
  ## Report the viewport this mirror measured for `pane` to the primary,
  ## which decides what to load for it.
  m.channel.send(viewportAction(pane, rows, depth, firstRow, m.following))

proc dispose*(m: MirrorSession) =
  if m.isNil:
    return
  m.channel.close()
  if not m.disposeRoot.isNil:
    m.disposeRoot()
    m.disposeRoot = nil
