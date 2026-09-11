## plugin_host/handles.nim — PLAT-8 deliverable 7: handle accounting per
## plugin, reclaimable without restarting.
##
## Extensibility-Model.md §8.1.1 keeps four things on the host's side of the
## boundary, and the last two are this file:
##
##   "**Ownership of handles.** Processes and sockets are host-owned resources
##    the plugin holds by handle. Deactivation closes them — §4.2's rule, and
##    the reason a plugin cannot leak a daemon past its own lifetime."
##
##   "**Accounting.** Every handle is attributable to a plugin, so a
##    misbehaving one is nameable and its resources are reclaimable without
##    restarting CodeTracer."
##
## ## THE TABLE HOLDS A CLOSER, NOT A RESOURCE
##
## This module opens nothing and closes nothing itself. A caller that opened a
## real thing registers it with the `proc()` that releases it, and the table's
## whole job is to remember WHOSE it is, WHAT it is, and to run every closer
## exactly once when the plugin goes away.
##
## That is what lets the accounting be pure: it compiles on every backend the
## facade serves, it runs in a lane that links no dispatcher, and its
## release-exactly-once property is asserted with counters rather than with a
## process table. The claim that the OS agrees — no surviving child, no leaked
## socket — is a different claim, and `test_plugin_io_sdk.nim` makes it against
## `/proc`, because a counter that reached zero is also what a table that
## forgot a handle looks like.
##
## ## RELEASE IS IDEMPOTENT AND ORDER IS REVERSE-OPEN
##
## A closer runs at most once: `close` clears it before calling it, so a closer
## that itself closes a sibling handle cannot re-enter. `closeAll` walks in
## reverse open order, because a stream over a process's stdin must be closed
## before the process is waited on — the same reason `deactivateAll` walks the
## activation log backwards.
##
## ## A FAILING CLOSER DOES NOT STOP THE SWEEP
##
## `closeAll` is the deactivation path, and a deactivation that abandoned the
## remaining handles because the third one raised would leak exactly the
## resources this file exists to reclaim. Every closer runs; the failures are
## collected and reported, and the sweep still reports how many it released.

import std/[strutils, tables]

type
  HandleKind* = enum
    ## What a handle IS, which is the axis the accounting is reported along:
    ## "this plugin holds two processes and a listener" is the sentence §8.1.1
    ## asks to be possible.
    hkProcess = "process"
    hkProcessStream = "process-stream"
    hkSocket = "socket"
    hkListener = "listener"

  HandleId* = int

  PluginHandle* = ref object
    id*: HandleId
    kind*: HandleKind
    description*: string
      ## What a user is shown. The executable name, the socket path, the
      ## host:port — never an fd number on its own, which names nothing.
    closed*: bool
    closer: proc() {.closure.}

  HandleTable* = ref object
    ## Per plugin. Reached from `PluginRunState`, so every handle is
    ## attributable by construction rather than by a registry keyed on a
    ## resource the plugin also holds.
    owner*: string
      ## The plugin id. Present so a report line can name it without the
      ## caller having to thread the id through.
    nextId: HandleId
    live: Table[HandleId, PluginHandle]
    order: seq[HandleId]
    opened*: int
      ## Cumulative, never decremented. `opened - closed` is not the live
      ## count — `liveCount` is — but a table that opened nothing is a
      ## different fact from one that opened and closed, and a test asserting
      ## "nothing leaked" needs to tell them apart.
    closedCount*: int

  HandleCloseFailure* = object
    handle*: HandleId
    kind*: HandleKind
    description*: string
    message*: string

func newHandleTable*(owner: string): HandleTable =
  HandleTable(owner: owner, nextId: 1,
              live: initTable[HandleId, PluginHandle]())

proc registerHandle*(t: HandleTable; kind: HandleKind; description: string;
                     closer: proc() {.closure.}): PluginHandle =
  ## Register a resource the caller has already acquired.
  ##
  ## The caller acquires FIRST and registers SECOND, deliberately: a table that
  ## acquired on the caller's behalf would need to know about processes and
  ## sockets, and then it could not be the pure module a JS-backend facade
  ## compiles.
  ##
  ## ## IT WAS CALLED `open` UNTIL 2026-09-09, AND THE NAME WAS THE HOLE
  ##
  ## `system` re-exports `std/syncio`, so `open` is in every plugin's scope
  ## with no import and no pragma, and `open(f, "/etc/hostname", fmRead)` is
  ## half of a complete unmediated file I/O API. The obvious repair — put
  ## `open` on `PluginDeniedSyncIo` — was blocked on the claim that it CANNOT
  ## be denied, because `handles.open` is the SDK's own registration proc and
  ## denying the name would refuse the sanctioned path
  ## (Verification-Harness-Traps §4a, from the other side).
  ##
  ## That was a naming collision and not a law of nature. This proc opens
  ## nothing — it takes a resource the caller ALREADY acquired and remembers
  ## who owns it — so `open` was never the right word for it, and the argument
  ## that the word could not be given up rested entirely on it. Renamed, the
  ## five call sites in `plugin_io.nim` stop naming `open`, and the ONE
  ## remaining occurrence in the SDK is `posix.open` inside `openVerified`:
  ## the genuinely mediated open, taken after `decide`, which is what the
  ## table's `hostOnly` flag exists to mark.
  ##
  ## The lesson generalises past this one name: when a denied list cannot hold
  ## a name because OUR code has claimed it, the cheap move is to widen the
  ## exemption and the right move is to give the name back.
  result = PluginHandle(id: t.nextId, kind: kind, description: description,
                        closer: closer)
  t.live[result.id] = result
  t.order.add result.id
  t.nextId = t.nextId + 1
  t.opened = t.opened + 1

proc close*(t: HandleTable; h: PluginHandle): bool {.discardable.} =
  ## Release one handle. `false` when it was already released, which is not an
  ## error: a plugin that closes its own process and is then deactivated must
  ## not see a failure for having been tidy.
  if h.isNil or h.closed: return false
  h.closed = true
  let c = h.closer
  h.closer = nil          # before the call: a closer must not re-enter.
  t.live.del h.id
  t.closedCount = t.closedCount + 1
  if not c.isNil:
    c()
  true

func liveCount*(t: HandleTable): int =
  t.live.len

func liveHandles*(t: HandleTable): seq[PluginHandle] =
  ## In open order, so a report reads the way the plugin acquired them.
  for id in t.order:
    if t.live.hasKey(id): result.add t.live[id]

proc closeAll*(t: HandleTable; failures: var seq[HandleCloseFailure]): int
              {.discardable.} =
  ## Release everything, reverse open order, every closer attempted. Returns
  ## how many were released. See the header for why a raising closer does not
  ## stop the sweep.
  var ids: seq[HandleId] = @[]
  for i in countdown(t.order.high, 0):
    if t.live.hasKey(t.order[i]): ids.add t.order[i]
  for id in ids:
    if not t.live.hasKey(id): continue
    let h = t.live[id]
    try:
      if t.close(h): result = result + 1
    except CatchableError as e:
      failures.add HandleCloseFailure(handle: h.id, kind: h.kind,
        description: h.description, message: e.msg)
  t.order = @[]

proc closeAll*(t: HandleTable): int {.discardable.} =
  var ignored: seq[HandleCloseFailure] = @[]
  t.closeAll(ignored)

func describe*(t: HandleTable): string =
  ## §8.1.1's "a misbehaving one is nameable". One line per live handle, the
  ## plugin named first.
  if t.liveCount == 0:
    return "plugin '" & t.owner & "' holds no handles"
  var lines: seq[string] = @[]
  lines.add "plugin '" & t.owner & "' holds " & $t.liveCount & " handle(s):"
  for h in t.liveHandles():
    lines.add "  #" & $h.id & " " & $h.kind & " " & h.description
  lines.join("\n")

func countOf*(t: HandleTable; kind: HandleKind): int =
  for h in t.liveHandles():
    if h.kind == kind: result = result + 1
