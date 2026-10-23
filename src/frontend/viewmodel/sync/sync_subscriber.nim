## sync/sync_subscriber.nim
##
## `SyncSubscriber` — applies a primary's revisioned batches
## (`sync_publisher`) to a mirror session.
##
## A subscriber follows ONE primary session at a time (`follow`). It is in
## step once it has applied that session's snapshot; from then on it applies
## exactly the next revision, each batch inside one IsoNim `batch` so the
## mirror's memos and effects recompute once per primary batch, as they did on
## the primary.
##
## What it refuses, and why:
## - a message about another session: it arrived after a switch, and writing
##   it would show the session the user just left;
## - a batch at or below the revision it holds: a duplicate or a late one;
## - a batch that skips a revision: something was lost, so applying it would
##   leave the mirror wrong in the lost fields without any sign of it. The
##   subscriber marks itself out of step (`inStep = false`) and the mirror
##   asks for a new snapshot (`mirror_session`).
##
## Works on both the C and JS backends.

import std/[json, options]

import isonim/core/batch as batchModule

import ../session_vm
import ../collab/[codec, session_core]
import synced_signals

type
  SyncSubscriber* = ref object
    registry*: SyncRegistry
    collabCore: CollaborativeSessionCore
      ## The mirror's shared view state, replaced by a snapshot's.
    sessionId*: string
      ## The primary session followed; "" before `follow`.
    revision*: int
      ## The revision the mirror holds.
    inStep*: bool
      ## A snapshot of `sessionId` has been applied and no revision was lost
      ## since.
    applied*: int
    refused*: int
      ## Messages applied and refused, for tests and diagnostics.

proc createSyncSubscriber*(session: SessionViewModel): SyncSubscriber =
  ## A subscriber that writes `session`'s mirrored signals. Purely
  ## imperative: it creates no effect.
  SyncSubscriber(registry: syncedSignalsOf(session),
                 collabCore: session.collabCore)

proc follow*(sub: SyncSubscriber; sessionId: string) =
  ## Follow `sessionId` from its next snapshot on. Until that snapshot
  ## arrives the subscriber is out of step and applies nothing.
  sub.sessionId = sessionId
  sub.revision = 0
  sub.inStep = false

proc applyEntries(sub: SyncSubscriber; entries: JsonNode) =
  ## Write the entries in one batch, then once more where the mirror's own
  ## effects changed them.
  ##
  ## THE PRIMARY'S VALUES WIN. The mirror's panel ViewModels are the shipped
  ## ones, and their effects react to the store values a batch writes: the
  ## state pane diffs the new locals against the previous ones
  ## (`valueChanges`), the flow pane marks itself loading while it asks its
  ## (inert) backend. Those effects run when the batch ends and would leave
  ## the mirror showing ITS derivation where the primary published its own —
  ## measured on a session switch, where the "previous locals" were another
  ## session's. The second pass writes back exactly the entries that now
  ## differ; it changes no store value, so it wakes no effect that would
  ## derive them again.
  var found: seq[(SyncedSignal, JsonNode)]
  for entry in entries:
    let s = sub.registry.find(entry{"key"}.getStr(""))
    if s.isSome:
      found.add (s.get, entry{"value"})
  batchModule.batch proc() =
    for (s, value) in found:
      s.write(value)
  for (s, value) in found:
    if s.read() != value:
      s.write(value)

proc loadViewDocument(sub: SyncSubscriber; msg: JsonNode) =
  ## Replace the mirror's shared view document with the primary's, when
  ## `msg` carries one.
  ##
  ## THE MIRROR'S DOCUMENT FOLLOWS THE PRIMARY'S, not only its view signals.
  ## The mirror projects its own document into its panes on its next view
  ## operation, and reads it to remove or reorder a watch; one that only a
  ## snapshot updated put the panes back to the snapshot's view (codetracer-pm
  ## issues/2026-10-22-a-watch-typed-in-the-browser-never-produces-a-row.md).
  let collab = msg{"collab"}
  if collab.isNil or collab.kind != JObject or sub.collabCore.isNil:
    return
  try:
    sub.collabCore.loadJoinSnapshot(parseSharedSessionSnapshot(collab))
  except CatchableError:
    discard

proc onMessage*(sub: SyncSubscriber; msg: JsonNode): bool =
  ## Apply `msg` if it is the next thing this mirror needs. `true` when it
  ## was applied. Message types it does not know are ignored, so an older
  ## mirror keeps working against a newer primary.
  if msg.isNil or msg.kind != JObject:
    return false
  let kind = msg{"type"}.getStr("")
  if kind notin ["signal-batch", "signal-snapshot"]:
    return false
  if msg{"session"}.getStr("") != sub.sessionId or sub.sessionId.len == 0:
    inc sub.refused
    return false
  let revision = msg{"revision"}.getInt(-1)
  let entries = msg{"batch"}
  if entries.isNil or entries.kind != JArray:
    inc sub.refused
    return false
  if kind == "signal-snapshot":
    # The view state first: loading it projects the chosen tab, the expanded
    # rows and the watches into the panes, and the signal entries written
    # after it are then the primary's, whatever the projection set.
    sub.loadViewDocument(msg)
    sub.applyEntries(entries)
    sub.revision = revision
    sub.inStep = true
    inc sub.applied
    return true
  # A batch.
  if not sub.inStep or revision <= sub.revision:
    inc sub.refused
    return false
  if revision != sub.revision + 1:
    sub.inStep = false
    inc sub.refused
    return false
  # A batch carries the view document when it changed (`sync_publisher`
  # `collabPending`), loaded first for the same reason as a snapshot's.
  sub.loadViewDocument(msg)
  sub.applyEntries(entries)
  sub.revision = revision
  inc sub.applied
  true
