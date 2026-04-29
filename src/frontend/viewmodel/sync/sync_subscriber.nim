## sync/sync_subscriber.nim
##
## SyncSubscriber — receives JSON messages from a SyncPublisher and
## applies them to a mirror SessionViewModel's store.
##
## Incoming messages can be either single signal updates or batches.
## Batch updates are applied inside an IsoNim `batch` block so that
## all signal writes are committed atomically — downstream effects and
## memos only recompute once after the entire batch is applied.
##
## The subscriber is OPTIONAL: in same-process mode it is never created.
## Only the multi-process (primary + view) architecture uses it.
##
## Usage:
##   let subscriber = createSyncSubscriber(session)
##   # On each received message from the transport:
##   subscriber.onMessage(parsedJson)

import std/json

import isonim/core/batch as batchModule

import signal_serializer

type
  SyncSubscriber* = ref object
    ## Receives serialized signal updates and applies them to a mirror
    ## SessionViewModel.
    ##
    ## Fields:
    ##   session — the mirror SessionViewModel whose signals are written
    session*: SessionViewModel

proc createSyncSubscriber*(session: SessionViewModel): SyncSubscriber =
  ## Create a SyncSubscriber for the given mirror session.
  ## No reactive effects are created here; the subscriber is purely
  ## imperative — call `onMessage` when data arrives from the transport.
  SyncSubscriber(session: session)

proc onMessage*(sub: SyncSubscriber, msg: JsonNode) =
  ## Apply a message from the primary process to the mirror session.
  ##
  ## Supports two message formats:
  ##
  ## 1. Single signal update:
  ##    ```json
  ##    {"type": "signal-update", "vm": "...", "field": "...", "value": ...}
  ##    ```
  ##
  ## 2. Batch of signal updates:
  ##    ```json
  ##    {"type": "signal-batch", "batch": [
  ##      {"vm": "...", "field": "...", "value": ...},
  ##      ...
  ##    ]}
  ##    ```
  ##
  ## Batch updates are wrapped in `batch()` so that all signal writes
  ## happen atomically — downstream reactive computations execute once
  ## after the entire batch is applied.
  ##
  ## Unknown message types are silently ignored for forward compatibility.
  let msgType = msg{"type"}.getStr
  case msgType
  of "signal-update":
    # Single update — apply directly.
    applySignalUpdate(sub.session, msg)

  of "signal-batch":
    # Batch of updates — apply atomically.
    let updates = msg["batch"]
    batchModule.batch proc() =
      for update in updates:
        applySignalUpdate(sub.session, update)

  else:
    # Unknown message type — ignore for forward compatibility.
    discard
