## M10 snapshot compaction tests.
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_snapshot_compaction.nim

import std/[json, unittest]

import ../../collab/[codec, snapshot, types]

proc op(kind: ViewOpKind;
        opId: string;
        lamport: uint64;
        targetPath: string;
        payload: JsonNode): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: "m10-snapshot",
    principalId: "principal-owner",
    actorId: "actor-owner",
    replicaId: "replica-owner",
    actorSeq: lamport,
    opId: opId,
    lamport: lamport,
    capabilityIds: @[],
    targetPath: targetPath,
    kind: kind,
    payload: payload,
    unknownFields: newJObject(),
  )

proc canonical(doc: SharedSessionDocument): string =
  $(doc.state.toJson)

suite "collaborative ViewModel M10 snapshot compaction":

  test "test_collab_snapshot_compaction_preserves_replay_result":
    let base = initSharedSessionDocument(
      sessionId = "m10-snapshot",
      traceIdentity = "trace-fixture",
      authorityPrincipalId = "principal-owner",
      backendOwnerId = "principal-owner",
    )
    let ops = @[
      op(vokSetCalltraceSelection, "owner:1", 1, "calltrace.selectedEntry",
        %*{"entryId": "10"}),
      op(vokToggleCalltraceExpansion, "owner:2", 2, "calltrace.expandedNodes",
        %*{"id": "call-10", "expanded": true}),
      op(vokSetStateTab, "owner:3", 3, "statePane.activeTab",
        %*{"tab": "stWatches"}),
      op(vokAddWatch, "owner:4", 4, "statePane.watchExpressions",
        %*{"watchId": "watch-1", "expression": "counter", "orderKey": "a"}),
      op(vokEditWatch, "owner:5", 5, "statePane.watchExpressions",
        %*{"watchId": "watch-1", "expression": "counter + 1"}),
      op(vokToggleStatePath, "owner:6", 6, "statePane.expandedPaths",
        %*{"path": "frame.locals.counter", "expanded": true}),
    ]

    let fullReplay = replayFromBase(base, ops)
    let compacted = compactOperationLog(
      base,
      ops,
      SnapshotRetentionPolicy(
        compactAfterOps: 4,
        maxRetainedOps: 2,
        retainRejectedOps: false,
      ),
    )
    let replayedCompacted = replaySnapshotTail(
      compacted.snapshot,
      compacted.retainedTail,
    )

    check compacted.snapshot.documentRevision == fullReplay.state.revision
    check compacted.retainedTail.len == 2
    check compacted.droppedOperationCount == 4
    check compacted.retentionReason == "compactAfterOps"
    check replayedCompacted.canonical == fullReplay.canonical
    check replayedCompacted.canonical == $(compacted.snapshot.state.toJson)
