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
import ../viewmodels/[debug_controls_vm, action_sink, calltrace_vm, state_vm,
                      event_log_vm, terminal_output_vm, scratchpad_vm,
                      trace_log_vm, flow_vm, point_list_vm,
                      filesystem_vm]
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
    viewports: JsonNode
      ## The last viewport this mirror reported for each pane, by pane name
      ## (the `args` of a `viewport` / `set` action): sent again to every
      ## primary the mirror starts to follow (`switchTo`).
    unsentViewOps: seq[ViewOpEnvelope]
      ## View operations made in this mirror's panes before it followed any
      ## session — a `ct host` page is usable before the server's session
      ## exists, which is made at the replay's first stop. Sent to the first
      ## session it follows (`switchTo`), after its subscription: the snapshot
      ## answering that subscription replaces this mirror's document, and these
      ## are what the session's next batch brings back (codetracer-pm
      ## issues/2026-10-22-a-watch-typed-in-the-browser-never-produces-a-row.md).
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
  ##
  ## THE PANES THE MIRROR MEASURED ARE REPORTED AGAIN, to the session it now
  ## follows. A pane reports its size when it is mounted and when it is
  ## resized or scrolled (Viewport-Driven-Loading V3), not when the primary
  ## changes: a report sent before this primary was hosted was dropped by the
  ## host (a `ct host` page measures its panes before the replay's first stop
  ## creates its session), and one sent to the session left was that
  ## session's. Without its viewport the primary's pane is unmeasured and
  ## loads nothing, so the mirror would show an empty pane until the user
  ## happened to resize it.
  m.following = sessionId
  m.subscriber.follow(sessionId)
  m.channel.send(%*{"type": "subscribe", "session": sessionId})
  if not m.viewports.isNil:
    for _, args in m.viewports.pairs:
      m.channel.send(serializeAction("viewport", "set", args, sessionId))
  for op in m.unsentViewOps:
    m.channel.send(serializeAction("collab", "viewop", op.toJson, sessionId))
  m.unsentViewOps = @[]

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

proc relay*(m: MirrorSession; vm, action: string;
            args: JsonNode = newJObject())

type
  RelayFilter* = proc(vm, action: string): bool {.closure.}
    ## Whether the mirror relays `vm`.`action` to the primary (`true`) or
    ## leaves it to its own ViewModel (`false`).

proc relayActions(m: MirrorSession; relays: RelayFilter) =
  ## Hand the panel ViewModels' user actions that `relays` accepts (every
  ## one when it is nil) to the primary (`viewmodels/action_sink`): the views
  ## call the ViewModels as anywhere, and those actions run where the session
  ## is.
  let sink: ActionSink = proc(vm, action: string; args: JsonNode): bool =
    if not relays.isNil and not relays(vm, action):
      return false
    m.relay(vm, action, args)
    true
  let s = m.session
  if not s.calltraceVM.isNil: s.calltraceVM.actionSink = sink
  if not s.stateVM.isNil: s.stateVM.actionSink = sink
  if not s.eventLogVM.isNil: s.eventLogVM.actionSink = sink
  if not s.terminalOutputVM.isNil: s.terminalOutputVM.actionSink = sink
  if not s.scratchpadVM.isNil: s.scratchpadVM.actionSink = sink
  if not s.traceLogVM.isNil: s.traceLogVM.actionSink = sink
  if not s.flowVM.isNil: s.flowVM.actionSink = sink
  if not s.pointListVM.isNil: s.pointListVM.actionSink = sink
  if not s.fileTreeVM.isNil: s.fileTreeVM.actionSink = sink
  if not s.requestPanelVM.isNil: s.requestPanelVM.actionSink = sink

proc createMirrorSession*(
    channel: SyncChannel;
    debugCommandsFor: proc(session: SessionViewModel): DebugCommands = nil;
    relayActions = false;
    relays: RelayFilter = nil
): MirrorSession =
  ## A mirror over `channel`. It follows the session the host activates, or
  ## the one `switchTo` names.
  ##
  ## `debugCommandsFor` gives the toolbar the host's own commands, for a host
  ## that drives the replay itself while another process owns the session
  ## (the page under `ct host`). It is called before the panel ViewModels are
  ## built, because `DebugControlsVM` takes its commands when it is created
  ## and the synced-signal registry walks the ViewModels that exist then.
  ## Without it the toolbar has the defaults over the inert backend, and
  ## its steps go nowhere.
  ##
  ## `relayActions`: the panels' user actions run on the primary
  ## (Shared-DOM-Front-Ends D6) — a VS Code webview, and a `ct host` page
  ## (`createHostedPageMirror`). Off for a mirror that only shows a session.
  ## `relays` narrows them to the actions it accepts; nil relays every one.
  let m = MirrorSession(channel: channel, viewports: newJObject())
  createRoot proc(dispose: proc()) =
    m.disposeRoot = dispose
    m.session = createSessionVM(inertBackend(), vrrCollaborator)
    if not debugCommandsFor.isNil:
      m.session.debugCommands = debugCommandsFor(m.session)
    m.session.initializePanelViewModels()
    if relayActions:
      m.relayActions(relays)
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
        # Held for the first session followed (`unsentViewOps`), not dropped.
        m.unsentViewOps.add op
        return true
      m.channel.send(serializeAction("collab", "viewop", op.toJson,
                                     m.following))
      true
  # Ask which session to follow: the host's `activate` at attach may have
  # been sent before this mirror existed to hear it.
  channel.send(%*{"type": "hello"})
  m

proc hostedPageRelays*(vm, action: string): bool =
  ## The actions a `ct host` page relays to the server's session
  ## (`createHostedPageMirror`): the panes' viewports, the call trace's
  ## actions, and the request panel's selection, filters and detail tab. The
  ## call trace's ViewModel takes no callback from the page, so all its
  ## actions run the same on either side. The request panel's window is
  ## loaded by the server's session, from the viewport the page relays, so
  ## its filters and selection must be the server's too: a filter set on the
  ## page alone would filter rows the page does not load. Its row activation
  ## (`jumpToHandler`) stays on the page, which installs the hook that opens
  ## a request recorded in another container (`openExternalTrace`).
  vm == "viewport" or vm == "calltrace" or
    (vm == "requestPanel" and action != "jumpToHandler")

proc createHostedPageMirror*(
    channel: SyncChannel;
    debugCommandsFor: proc(session: SessionViewModel): DebugCommands = nil
): MirrorSession =
  ## The mirror a `ct host` page renders (Shared-DOM-Front-Ends D2): the
  ## server owns the client's session, and the page relays to it, with
  ## `action_relay`, the panel actions whose effect lives entirely in that
  ## session (`hostedPageRelays`):
  ##
  ## * every pane's measured viewport: the server's session has no screen,
  ##   so a pane loads nothing until the page's measurement reaches it
  ##   (Viewport-Driven-Loading V3);
  ## * the call trace's actions: a click on a call jumps over the server's
  ##   connection to the replay, not the mirror's inert backend.
  ## * the request panel's filters, selection and detail tab: its window is
  ##   loaded on the server's session, so they must be that session's.
  ##
  ## The other panels' actions stay on the page, as before: several reach
  ## callbacks only the page installs — the file tree opens a file in the
  ## page's editor and loads a folder through it, the event log and the state
  ## pane switch the page's process, the terminal output saves the view the
  ## page chose — and the server's session has none of them. The toolbar
  ## stays the page's too, through `debugCommandsFor`: the page drives the
  ## replay it launched, and the server's session follows the moves it makes
  ## (`hosted_primary`).
  createMirrorSession(channel, debugCommandsFor, relayActions = true,
                      relays = hostedPageRelays)

proc rememberViewport(m: MirrorSession; args: JsonNode) =
  ## Keep `args` as the pane's last report, for the next primary `switchTo`
  ## follows. A report that names no pane is not one the primary can apply.
  let pane = args{"pane"}.getStr("")
  if pane.len > 0:
    m.viewports[pane] = args.copy

proc relay*(m: MirrorSession; vm, action: string;
            args: JsonNode = newJObject()) =
  ## Run `vm`.`action` on the primary this mirror follows. `args` is decoded
  ## by `action_relay` on the primary, enums by name.
  if vm == "viewport" and action == "set" and not args.isNil:
    m.rememberViewport(args)
  m.channel.send(serializeAction(vm, action, args, m.following))

proc setViewport*(m: MirrorSession; pane: string; rows: int; depth = 0;
                  firstRow = -1) =
  ## Report the viewport this mirror measured for `pane` to the primary,
  ## which decides what to load for it.
  let msg = viewportAction(pane, rows, depth, firstRow, m.following)
  m.rememberViewport(msg["args"])
  m.channel.send(msg)

proc dispose*(m: MirrorSession) =
  if m.isNil:
    return
  m.channel.close()
  if not m.disposeRoot.isNil:
    m.disposeRoot()
    m.disposeRoot = nil
