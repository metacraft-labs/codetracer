## sync/sync_host.nim
##
## `SyncHost` — the primary side of mirroring: the sessions a host owns (the
## VS Code extension host, a `ct host` server) and the mirrors attached to it
## (webviews, pages), each over its own `SyncChannel`.
##
## A host may hold several primary sessions at once — one per active edit or
## replay session — and every mirror follows one of them. Which one is the
## host's decision (`activate`: in VS Code, the active debug session), and a
## switch re-points every mirror; the session left keeps its position and its
## panes, because it is an independent graph that simply has no one watching.
##
## Messages a mirror sends:
##
##   {"type": "hello"}                      → `activate` for the active session
##   {"type": "subscribe", "session": id}   → a snapshot of `id`, then its batches
##   {"type": "action", "session": id, …}   → run on that primary (`action_relay`)
##
## Messages a host sends besides the publisher's batches and snapshots:
##
##   {"type": "activate", "session": id}       — follow `id` from now on
##   {"type": "session-unknown", "session": id} — no such primary here
##
## Works on both the C and JS backends.

import std/[json, tables]

import ../session_vm
import action_relay, sync_publisher, transport

type
  HostedSession = ref object
    session: SessionViewModel
    publisher: SyncPublisher

  Attached = ref object
    channel: SyncChannel
    following: string

  SyncHost* = ref object
    sessions: OrderedTable[string, HostedSession]
    attached: seq[Attached]
    active*: string
      ## The session mirrors are told to follow; "" when none is.
    schedule: Scheduler
    actionsApplied*: int
      ## Actions that ran on a primary, for tests and diagnostics.

proc newSyncHost*(schedule: Scheduler = nil): SyncHost =
  ## A host with no sessions. `schedule` decides when each session's batches
  ## are cut (`sync_publisher.defaultScheduler` when nil).
  SyncHost(sessions: initOrderedTable[string, HostedSession](),
           schedule: schedule)

proc primary*(host: SyncHost; id: string): SessionViewModel =
  ## The primary session `id`, or nil.
  if host.sessions.hasKey(id): host.sessions[id].session else: nil

proc publisher*(host: SyncHost; id: string): SyncPublisher =
  if host.sessions.hasKey(id): host.sessions[id].publisher else: nil

proc subscribe(host: SyncHost; a: Attached; id: string) =
  a.following = id
  if not host.sessions.hasKey(id):
    a.channel.send(%*{"type": "session-unknown", "session": id})
    return
  a.channel.send(host.sessions[id].publisher.snapshot())

proc onMirrorMessage(host: SyncHost; a: Attached; msg: JsonNode) =
  if msg.isNil or msg.kind != JObject:
    return
  case msg{"type"}.getStr("")
  of "hello":
    # A mirror created after its channel was attached — a page builds its
    # mirror well after its socket connected — missed the `activate` sent at
    # attach. It asks, and is told again.
    if host.active.len > 0:
      a.channel.send(%*{"type": "activate", "session": host.active})
  of "subscribe":
    host.subscribe(a, msg{"session"}.getStr(""))
  of "action":
    var id = msg{"session"}.getStr("")
    if id.len == 0:
      id = a.following
    if host.sessions.hasKey(id) and
       host.sessions[id].session.applyAction(msg):
      inc host.actionsApplied
  else:
    discard

proc attach*(host: SyncHost; channel: SyncChannel) =
  ## Serve the mirror at the other end of `channel`. If a session is active
  ## the mirror is told to follow it.
  let a = Attached(channel: channel)
  host.attached.add a
  channel.setHandler(proc(msg: JsonNode) = host.onMirrorMessage(a, msg))
  if host.active.len > 0:
    channel.send(%*{"type": "activate", "session": host.active})

proc detach*(host: SyncHost; channel: SyncChannel) =
  ## Stop serving `channel` (its webview or page went away).
  for i in countdown(host.attached.high, 0):
    if host.attached[i].channel == channel:
      host.attached.delete(i)

proc activate*(host: SyncHost; id: string) =
  ## Make `id` the session every mirror follows.
  host.active = id
  for a in host.attached:
    a.channel.send(%*{"type": "activate", "session": id})

proc addPrimary*(host: SyncHost; id: string; session: SessionViewModel) =
  ## Host `session` as primary `id`. Its batches go to every mirror
  ## following it. The first session added becomes the active one.
  doAssert not host.sessions.hasKey(id), "a primary session '" & id &
    "' is already hosted"
  let h = host
  let publisher = createSyncPublisher(session, id,
    proc(msg: JsonNode) =
      for a in h.attached:
        if a.following == id:
          a.channel.send(msg),
    host.schedule)
  host.sessions[id] = HostedSession(session: session, publisher: publisher)
  if host.active.len == 0:
    host.activate(id)

proc dispose*(host: SyncHost) =
  for h in host.sessions.values:
    h.publisher.dispose()
  host.sessions.clear()
  host.attached.setLen(0)
