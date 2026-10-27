## sync/sync_host.nim
##
## `SyncHost` — the primary side of mirroring: the sessions a host owns (the
## VS Code extension host, a `ct host` server) and the mirrors attached to it
## (webviews, pages), each over its own `SyncChannel`.
##
## A host may hold several primary sessions at once — one per active edit or
## replay session — and every mirror follows one of them. Which one is the
## host's decision, in one of two ways:
##
## * SHARED: the host has an active session (`activate`: in VS Code, the
##   active debug session), and a switch re-points every mirror; the session
##   left keeps its position and its panes, because it is an independent
##   graph that simply has no one watching.
## * PINNED: a mirror attached with `attach(channel, follow = id)` follows
##   `id` and only `id`, whatever the active session is (a `ct host` client:
##   each has a session of its own, `CLI/ct/host.md` "Sessions are
##   isolated"). It is told to follow `id` once `id` is hosted, and it can
##   neither subscribe to nor act on another session.
##
## Messages a mirror sends:
##
##   {"type": "hello"}                      → `activate` for the session it follows
##   {"type": "subscribe", "session": id}   → a snapshot of `id`, then its batches
##   {"type": "action", "session": id, …}   → run on that primary (`action_relay`)
##
## Messages a host sends besides the publisher's batches and snapshots:
##
##   {"type": "activate", "session": id}       — follow `id` from now on
##   {"type": "session-unknown", "session": id} — no such primary here, or
##                                               none this mirror may follow
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
    pinned: string
      ## The one session this mirror may follow; "" when it follows the
      ## host's active session.
    actorTag: string
      ## This attachment's own name for the view operations it relays
      ## (`namespacedViewOp`), unique among every attachment this host has
      ## served.

  SyncHost* = ref object
    sessions: OrderedTable[string, HostedSession]
    attached: seq[Attached]
    active*: string
      ## The session mirrors are told to follow; "" when none is.
    schedule: Scheduler
    actionsApplied*: int
      ## Actions that ran on a primary, for tests and diagnostics.
    attachments: int
      ## How many mirrors have attached, ever: the source of `actorTag`.

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

proc namespacedViewOp(a: Attached; msg: JsonNode): JsonNode =
  ## A mirror's `collab` / `viewop` action, its operation renamed into this
  ## attachment's namespace: `<tag>/<actor>` and `<tag>/<actor>:<seq>`.
  ##
  ## A COLLABORATION CORE'S NAMES ARE ONLY UNIQUE IN ITS OWN PROCESS. An
  ## operation is `<actor>:<sequence>`, and a session's actor is
  ## `local-actor-<storeId>`, a counter of the process: a `ct host` page's
  ## first session and the server's are both `local-actor-1`, both counting
  ## from 1, and so are a reloaded page and the page before it, and two
  ## webviews of one extension host. The primary's document refuses an
  ## operation whose name it has applied (`reducer.applyViewOp`, "duplicate"),
  ## so the page's click on the Watches tab, the same `local-actor-1:1` as the
  ## server's own call-trace selection, was dropped without a trace
  ## (codetracer-pm issues/2026-10-22-a-watch-typed-in-the-browser-never-
  ## produces-a-row.md). The host knows which attachment sent an operation, so
  ## it is the host that makes the name unique. A mirror's resent operation
  ## keeps its name in its namespace, so it is still recognised as applied.
  result = msg.copy
  let args = result{"args"}
  if args.isNil or args.kind != JObject:
    return
  for field in ["actorId", "opId"]:
    let node = args{field}
    if not node.isNil and node.kind == JString and node.getStr.len > 0:
      args[field] = %(a.actorTag & "/" & node.getStr)

proc mayFollow(a: Attached; id: string): bool =
  a.pinned.len == 0 or a.pinned == id

proc subscribe(host: SyncHost; a: Attached; id: string) =
  if not a.mayFollow(id):
    # Another client's session: not unknown, but not this mirror's to see,
    # and the reply must not tell the two apart.
    a.channel.send(%*{"type": "session-unknown", "session": id})
    return
  a.following = id
  if not host.sessions.hasKey(id):
    a.channel.send(%*{"type": "session-unknown", "session": id})
    return
  a.channel.send(host.sessions[id].publisher.snapshot())

proc sessionFor(host: SyncHost; a: Attached): string =
  ## The session `a` is told to follow now: its own when pinned and hosted,
  ## else the active one when it is not pinned; "" when there is none yet.
  if a.pinned.len > 0:
    (if host.sessions.hasKey(a.pinned): a.pinned else: "")
  else:
    host.active

proc onMirrorMessage(host: SyncHost; a: Attached; msg: JsonNode) =
  if msg.isNil or msg.kind != JObject:
    return
  case msg{"type"}.getStr("")
  of "hello":
    # A mirror created after its channel was attached — a page builds its
    # mirror well after its socket connected — missed the `activate` sent at
    # attach. It asks, and is told again.
    let id = host.sessionFor(a)
    if id.len > 0:
      a.channel.send(%*{"type": "activate", "session": id})
  of "subscribe":
    host.subscribe(a, msg{"session"}.getStr(""))
  of "action":
    var id = msg{"session"}.getStr("")
    if id.len == 0:
      id = a.following
    let relayed =
      if msg{"vm"}.getStr("") == "collab": a.namespacedViewOp(msg) else: msg
    if a.mayFollow(id) and host.sessions.hasKey(id) and
       host.sessions[id].session.applyAction(relayed):
      inc host.actionsApplied
  else:
    discard

proc attach*(host: SyncHost; channel: SyncChannel; follow = "") =
  ## Serve the mirror at the other end of `channel`. With `follow` it follows
  ## that session only (PINNED); without, the host's active one. It is told
  ## which, when that session is hosted.
  inc host.attachments
  let a = Attached(channel: channel, pinned: follow,
                   actorTag: "mirror-" & $host.attachments)
  host.attached.add a
  channel.setHandler(proc(msg: JsonNode) = host.onMirrorMessage(a, msg))
  let id = host.sessionFor(a)
  if id.len > 0:
    channel.send(%*{"type": "activate", "session": id})

proc detach*(host: SyncHost; channel: SyncChannel) =
  ## Stop serving `channel` (its webview or page went away).
  for i in countdown(host.attached.high, 0):
    if host.attached[i].channel == channel:
      host.attached.delete(i)

proc activate*(host: SyncHost; id: string) =
  ## Make `id` the session every mirror that is not pinned follows.
  host.active = id
  for a in host.attached:
    if a.pinned.len == 0:
      a.channel.send(%*{"type": "activate", "session": id})

proc addPrimary*(host: SyncHost; id: string; session: SessionViewModel) =
  ## Host `session` as primary `id`. Its batches go to every mirror
  ## following it, and the mirrors pinned to it are told to follow it. The
  ## first session added becomes the active one.
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
  for a in host.attached:
    if a.pinned == id:
      a.channel.send(%*{"type": "activate", "session": id})
  if host.active.len == 0:
    host.activate(id)

proc removePrimary*(host: SyncHost; id: string) =
  ## Stop hosting primary `id` (its debug session ended). The session is the
  ## caller's to dispose. When it was the active one, the next session hosted
  ## becomes active; with none left, mirrors keep what they show. Mirrors
  ## pinned to it keep what they show too: nothing publishes to them.
  if not host.sessions.hasKey(id):
    return
  host.sessions[id].publisher.dispose()
  host.sessions.del(id)
  if host.active == id:
    host.active = ""
    for next in host.sessions.keys:
      host.activate(next)
      break

proc dispose*(host: SyncHost) =
  for h in host.sessions.values:
    h.publisher.dispose()
  host.sessions.clear()
  host.attached.setLen(0)
