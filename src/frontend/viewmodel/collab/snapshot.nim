## Snapshot compaction and operation-log retention for collaboration sessions.

import std/[algorithm, json]

import ./[codec, reducer, types]

type
  SnapshotRetentionPolicy* = object
    compactAfterOps*: int
    maxRetainedOps*: int
    retainRejectedOps*: bool

  SnapshotCompactionResult* = object
    snapshot*: SharedSessionSnapshot
    retainedTail*: seq[ViewOpEnvelope]
    droppedOperationCount*: int
    replayedDocumentRevision*: uint64
    retentionReason*: string

proc defaultSnapshotRetentionPolicy*(): SnapshotRetentionPolicy =
  SnapshotRetentionPolicy(
    compactAfterOps: 512,
    maxRetainedOps: 256,
    retainRejectedOps: false,
  )

proc suffixOps(ops: openArray[ViewOpEnvelope]; maxRetainedOps: int): seq[ViewOpEnvelope] =
  if maxRetainedOps <= 0 or ops.len == 0:
    return @[]
  let start = max(0, ops.len - maxRetainedOps)
  for i in start ..< ops.len:
    result.add ops[i]

proc replayFromBase*(base: SharedSessionDocument;
                     ops: openArray[ViewOpEnvelope]): SharedSessionDocument =
  result = base
  for op in ops:
    discard result.applyViewOp(op)

proc documentFromSnapshot*(snapshot: SharedSessionSnapshot): SharedSessionDocument =
  SharedSessionDocument(
    state: snapshot.state,
    appliedOpIds: snapshot.appliedOpIds,
  )

proc replaySnapshotTail*(snapshot: SharedSessionSnapshot;
                         tail: openArray[ViewOpEnvelope]): SharedSessionDocument =
  result = snapshot.documentFromSnapshot
  for op in tail:
    discard result.applyViewOp(op)

proc compactOperationLog*(base: SharedSessionDocument;
                          ops: openArray[ViewOpEnvelope];
                          policy = defaultSnapshotRetentionPolicy()):
                          SnapshotCompactionResult =
  let replayed = base.replayFromBase(ops)
  let retained = suffixOps(ops, policy.maxRetainedOps)
  let dropped = max(0, ops.len - retained.len)
  let reason =
    if ops.len >= policy.compactAfterOps:
      "compactAfterOps"
    else:
      "snapshotRequested"
  SnapshotCompactionResult(
    snapshot: replayed.snapshot,
    retainedTail: retained,
    droppedOperationCount: dropped,
    replayedDocumentRevision: replayed.state.revision,
    retentionReason: reason,
  )

proc toJson*(policy: SnapshotRetentionPolicy): JsonNode =
  %*{
    "compactAfterOps": policy.compactAfterOps,
    "maxRetainedOps": policy.maxRetainedOps,
    "retainRejectedOps": policy.retainRejectedOps,
  }

proc toJson*(compaction: SnapshotCompactionResult): JsonNode =
  var tail = newJArray()
  for op in compaction.retainedTail.sorted(proc(a, b: ViewOpEnvelope): int =
      cmp(a.opId, b.opId)):
    tail.add op.toJson
  %*{
    "snapshot": compaction.snapshot.toJson,
    "retainedTail": tail,
    "droppedOperationCount": compaction.droppedOperationCount,
    "replayedDocumentRevision": %compaction.replayedDocumentRevision,
    "retentionReason": compaction.retentionReason,
  }
