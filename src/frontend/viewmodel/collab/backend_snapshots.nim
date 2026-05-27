## Authoritative backend data snapshots for collaborative sessions.

import std/[json, strutils]

import isonim/core/signals

import ./[capabilities, reducer, types]
import ../store/replay_data_store
import ../store/types as store_types

proc backendSnapshot*(sessionId: string;
                      backendOwnerId: PrincipalId;
                      emittedByPrincipalId: PrincipalId;
                      family: string;
                      backendEpoch: uint64;
                      payload: JsonNode): BackendDataSnapshotEnvelope =
  BackendDataSnapshotEnvelope(
    sessionId: sessionId,
    backendOwnerId: backendOwnerId,
    emittedByPrincipalId: emittedByPrincipalId,
    family: family,
    backendEpoch: backendEpoch,
    payload: if payload.isNil: newJObject() else: payload,
  )

proc applyAuthoritativeBackendSnapshot*(
    document: var SharedSessionDocument;
    snapshot: BackendDataSnapshotEnvelope): ApplyResult =
  if document.state.sessionId.len > 0 and snapshot.sessionId != document.state.sessionId:
    return rejected("sessionId mismatch")
  if snapshot.backendOwnerId.len == 0 or
      snapshot.backendOwnerId != document.state.authority.backendOwnerId:
    return rejected("backend owner mismatch")
  if snapshot.emittedByPrincipalId != snapshot.backendOwnerId and
      not document.state.hasLiveCapability(
        snapshot.emittedByPrincipalId, capHostBackend, "backend"):
    return rejected("principal cannot emit backend snapshot")
  if snapshot.family.len == 0:
    return rejected("missing backend snapshot family")
  if document.state.applyBackendSnapshot(
      snapshot.family,
      snapshot.backendOwnerId,
      snapshot.backendEpoch,
      snapshot.payload):
    document.state.revision.inc
    return applied("backend snapshot accepted")
  rejected("stale or cross-owner backend snapshot")

proc readUint64(payload: JsonNode; key: string; fallback = 0'u64): uint64 =
  let value = payload{key}
  if value.isNil:
    return fallback
  case value.kind
  of JInt:
    let raw = value.getBiggestInt
    if raw < 0: 0'u64 else: raw.uint64
  of JString:
    try:
      parseUInt(value.getStr).uint64
    except ValueError:
      fallback
  else:
    fallback

proc readInt(payload: JsonNode; key: string; fallback = 0): int =
  let value = payload{key}
  if value.isNil: fallback else: value.getInt(fallback)

proc parseDebuggerStatus(value: string): store_types.DebuggerStatus =
  for status in store_types.DebuggerStatus:
    if $status == value:
      return status
  store_types.dsIdle

proc projectDebuggerSnapshot(store: ReplayDataStore; payload: JsonNode) =
  let rrTicks = payload.readUint64("rrTicks", store.debugger.val.rrTicks)
  let file = payload{"file"}.getStr(store.debugger.val.location.file)
  let line = payload.readInt("line", store.debugger.val.location.line)
  let status = parseDebuggerStatus(payload{"status"}.getStr($store_types.dsIdle))
  store.updateDebuggerPosition(rrTicks, file = file, line = line)
  var debugger = store.debugger.val
  debugger.status = status
  debugger.threadId = payload.readUint64("threadId", debugger.threadId.uint64).uint32
  store.debugger.val = debugger

proc projectBackendSnapshotToStore*(store: ReplayDataStore;
                                    snapshot: BackendDataSnapshotEnvelope) =
  if store.isNil:
    return
  case snapshot.family
  of "debugger":
    store.projectDebuggerSnapshot(snapshot.payload)
  else:
    discard

proc applyAndProjectBackendSnapshot*(
    document: var SharedSessionDocument;
    store: ReplayDataStore;
    snapshot: BackendDataSnapshotEnvelope): ApplyResult =
  result = document.applyAuthoritativeBackendSnapshot(snapshot)
  if result.status == asApplied:
    store.projectBackendSnapshotToStore(snapshot)
