## Unit tests for the M25b correlation-marker Event-Log surface in
## `EventLogVM`.
##
## Spec:
##   codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md §5.
## Milestone catalogue:
##   codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org
##   M25b §Verification (Layer 2 — Headless ViewModel tests).
##
## These tests cover the six Layer-2 verification entries listed in
## the milestone:
##
## 4. `test_event_log_vm_populates_marker_row_metadata_from_dap_response`
## 5. `test_event_log_vm_counterpart_set_resolves_against_cached_pair_index`
## 6. `test_event_log_vm_counterpart_set_refreshes_on_incremental_reload`
## 7. `test_event_log_vm_loading_banner_signal_tracks_marker_load_progress`
## 8. `test_event_log_vm_filter_bar_recognises_boundary_and_unmatched_shorthands`
## 9. `test_event_log_vm_empty_state_and_one_time_toast_signals`
##
## The Layer-1 DAP wire tests live in
## `src/db-backend/tests/m25b_event_log_test.rs`; this file exercises
## the reactive transitions on top of the DAP wire shape via a
## MockBackendService.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_event_log_marker_vm.nim

import std/[asyncdispatch, json, options, strutils, tables, unittest]

import isonim/core/[signals, computation]

import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../viewmodels/event_log_vm

proc drain() =
  try:
    poll(0)
  except ValueError:
    discard

proc makeEventLogVM(): tuple[vm: EventLogVM, store: ReplayDataStore,
                             mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createEventLogVM(store)
  drain()
  mock.clearReceivedCommands()
  (vm, store, mock)

# ---------------------------------------------------------------------------
# Sample DAP wire shapes used across multiple tests.
# ---------------------------------------------------------------------------

const SAMPLE_EVENT_LOAD_RESPONSE = """
{
  "events": [
    { "kind": "TraceLogEvent", "content": "marker send" },
    { "kind": "TraceLogEvent", "content": "marker recv" }
  ],
  "content": "marker send\nmarker recv",
  "markers": [
    {
      "eventIndex": 0,
      "markerId": 0,
      "boundaryId": "order-processing",
      "direction": "send",
      "keyText": "msg.id",
      "keyValue": "K1",
      "showText": "msg.body",
      "showValue": "outbound",
      "format": "text",
      "sourcePath": "src/sender.py",
      "sourceLine": 7,
      "stepId": 10
    },
    {
      "eventIndex": 1,
      "markerId": 1,
      "boundaryId": "order-processing",
      "direction": "recv",
      "keyText": "env.id",
      "keyValue": "K1",
      "showText": "env.body",
      "showValue": "inbound",
      "format": "json",
      "sourcePath": "src/receiver.py",
      "sourceLine": 12,
      "stepId": 22
    },
    {
      "eventIndex": 2,
      "markerId": 2,
      "boundaryId": "order-processing",
      "direction": "send",
      "keyText": "msg.id",
      "keyValue": "K-unpaired",
      "showText": null,
      "showValue": null,
      "format": "text",
      "sourcePath": "src/sender.py",
      "sourceLine": 7,
      "stepId": 30
    }
  ]
}
"""

# ---------------------------------------------------------------------------
# Layer-2 Test 4 — populates marker row metadata from DAP response.
# ---------------------------------------------------------------------------

suite "M25b — EventLogVM populates marker row metadata":

  test "test_event_log_vm_populates_marker_row_metadata_from_dap_response":
    let (vm, _, _) = makeEventLogVM()
    check vm.markerRows.val.len == 0
    vm.applyMarkerRowsResponse(parseJson(SAMPLE_EVENT_LOAD_RESPONSE))
    let rows = vm.markerRows.val
    check rows.len == 3

    # §5.1 metadata: direction icon, boundary chip, show value.
    check rows[0].direction == mdSend
    check directionDisplayIcon(rows[0].direction) == "↑"
    check rows[0].boundaryId == "order-processing"
    check rows[0].keyValue == "K1"
    check rows[0].showValue == "outbound"
    check rows[0].sourcePath == "src/sender.py"
    check rows[0].sourceLine == 7
    check rows[0].stepId == 10

    check rows[1].direction == mdRecv
    check directionDisplayIcon(rows[1].direction) == "↓"
    check rows[1].format == "json"

    # §5.2 format hints: `text` (default), `json` pretty-print,
    # `summary:N` truncation. We pin each format here so a future
    # change to the formatter trips the assertion immediately.
    check formatShowValue(rows[0]) == "outbound"

    let jsonRow = MarkerEventRow(
      keyValue: "k",
      showValue: "{\"a\":1,\"b\":[1,2]}",
      format: "json",
    )
    let pretty = formatShowValue(jsonRow)
    check pretty.contains("\"a\"")
    check pretty.contains("\n")

    let summaryRow = MarkerEventRow(
      keyValue: "k",
      showValue: "the quick brown fox jumps over the lazy dog",
      format: "summary:10",
    )
    let truncated = formatShowValue(summaryRow)
    check truncated.contains("…")
    check truncated.len < summaryRow.showValue.len

    let hexRow = MarkerEventRow(
      keyValue: "k",
      showValue: "abc",
      format: "hex",
    )
    check formatShowValue(hexRow) == "616263"

  test "test_event_log_vm_auto_load_applies_event_load_marker_response":
    let (vm, store, mock) = makeEventLogVM()
    mock.expect("ct/event-load", parseJson(SAMPLE_EVENT_LOAD_RESPONSE))

    var debuggerState = store.debugger.val
    debuggerState.rrTicks = 0'u64
    debuggerState.location.file = "fixtures/account-balance-with-wasm/frontend.js"
    debuggerState.location.line = 1
    store.debugger.val = debuggerState
    drain()

    check mock.findCommand("ct/event-load").isSome
    check vm.markerRows.val.len == 3
    check vm.markerRows.val[0].boundaryId == "order-processing"
    check vm.markerRows.val[0].keyValue == "K1"
    check vm.markerRows.val[0].stepId == 10

# ---------------------------------------------------------------------------
# Layer-2 Test 5 — counterpart set resolves against cached pair index.
# ---------------------------------------------------------------------------

suite "M25b — counterpart set caching":

  test "test_event_log_vm_counterpart_set_resolves_against_cached_pair_index":
    let (vm, _, mock) = makeEventLogVM()
    vm.applyMarkerRowsResponse(parseJson(SAMPLE_EVENT_LOAD_RESPONSE))

    # Pre-seed the cached `ct/pairIndexLookup` response so the
    # request resolves synchronously through the mock backend.
    let counterpartsResponse = %*{
      "counterparts": [
        {
          "recordingId": "trace-B",
          "stepId": 22,
          "sourcePath": "src/receiver.py",
          "sourceLine": 12,
          "markerId": 1,
          "boundaryId": "order-processing",
          "direction": "recv",
          "keyText": "env.id",
          "keyValue": "K1",
          "showText": "env.body",
          "showValue": "inbound",
          "format": "json"
        }
      ]
    }
    mock.expect("ct/pairIndexLookup", counterpartsResponse)

    # Request counterparts for the Send row — issues exactly one
    # `ct/pairIndexLookup` and populates the cache.
    let sendRow = vm.markerRows.val[0]
    vm.requestCounterparts(sendRow)
    drain()
    let cps = vm.counterpartsFor(sendRow)
    check cps.len == 1
    check cps[0].recordingId == "trace-B"
    check cps[0].stepId == 22
    check mock.findCommand("ct/pairIndexLookup").isSome

    # Second request for a sibling row sharing the same
    # `(boundary, direction, key_value)` triple serves from cache —
    # no second DAP request.
    mock.clearReceivedCommands()
    vm.requestCounterparts(sendRow)
    drain()
    check mock.findCommand("ct/pairIndexLookup").isNone

  test "test_event_log_vm_counterpart_set_refreshes_on_incremental_reload":
    let (vm, _, mock) = makeEventLogVM()
    vm.applyMarkerRowsResponse(parseJson(SAMPLE_EVENT_LOAD_RESPONSE))

    # First load — cache populated.
    let firstResponse = %*{
      "counterparts": [
        {
          "recordingId": "trace-B",
          "stepId": 22,
          "boundaryId": "order-processing",
          "direction": "recv",
          "keyValue": "K1"
        }
      ]
    }
    mock.expect("ct/pairIndexLookup", firstResponse)
    let sendRow = vm.markerRows.val[0]
    vm.requestCounterparts(sendRow)
    drain()
    check vm.counterpartsFor(sendRow).len == 1

    # An incremental reload (workspace file change, new sibling
    # trace) drops the cached entry for the affected boundary; the
    # next `requestCounterparts` re-issues the DAP request rather
    # than serving the stale entry. Unaffected boundaries persist.
    var cache = vm.counterpartCache.val
    cache.del(counterpartKey(sendRow))
    vm.counterpartCache.val = cache

    let secondResponse = %*{
      "counterparts": [
        {
          "recordingId": "trace-B",
          "stepId": 22,
          "boundaryId": "order-processing",
          "direction": "recv",
          "keyValue": "K1"
        },
        {
          "recordingId": "trace-C",
          "stepId": 99,
          "boundaryId": "order-processing",
          "direction": "recv",
          "keyValue": "K1"
        }
      ]
    }
    mock.expect("ct/pairIndexLookup", secondResponse)
    mock.clearReceivedCommands()
    vm.requestCounterparts(sendRow)
    drain()
    check mock.findCommand("ct/pairIndexLookup").isSome
    check vm.counterpartsFor(sendRow).len == 2

# ---------------------------------------------------------------------------
# Layer-2 Test 7 — loading banner tracks marker load progress.
# ---------------------------------------------------------------------------

suite "M25b — loading banner signal":

  test "test_event_log_vm_loading_banner_signal_tracks_marker_load_progress":
    let (vm, _, _) = makeEventLogVM()
    check vm.loadingBanner.val.phase == mlbIdle

    # Track every transition reactively — the view layer subscribes to
    # this exact signal to update the §5.4.1 banner DOM.
    var observedPhases: seq[MarkerLoadingPhase] = @[]
    createEffect proc() =
      observedPhases.add(vm.loadingBanner.val.phase)

    vm.applyMarkerLoadEvent(%*{"event": "ct/markerLoadStarted",
                              "body": {"totalDeclared": 120}})
    check vm.loadingBanner.val.phase == mlbLoading
    check vm.loadingBanner.val.total == 120
    check vm.loadingBanner.val.loaded == 0

    vm.applyMarkerLoadEvent(%*{"event": "ct/markerLoadProgress",
                              "body": {"loaded": 47, "total": 120}})
    check vm.loadingBanner.val.loaded == 47

    vm.applyMarkerLoadEvent(%*{"event": "ct/markerLoadCompleted",
                              "body": {"finalLoaded": 120}})
    check vm.loadingBanner.val.phase == mlbDone
    check vm.loadingBanner.val.loaded == 120

    # The reactive subscriber observed the three transitions
    # (mlbIdle initial → mlbLoading → mlbLoading (progress) → mlbDone).
    check observedPhases.len >= 4
    check observedPhases[0] == mlbIdle
    check observedPhases[^1] == mlbDone

# ---------------------------------------------------------------------------
# Layer-2 Test 8 — filter-bar shorthands.
# ---------------------------------------------------------------------------

suite "M25b — filter-bar shorthands":

  test "test_event_log_vm_filter_bar_recognises_boundary_and_unmatched_shorthands":
    let (vm, _, _) = makeEventLogVM()
    vm.applyMarkerRowsResponse(parseJson(SAMPLE_EVENT_LOAD_RESPONSE))

    # Seed counterpart sets for the K1 Send + K1 Recv rows so the
    # `unmatched` shorthand can discriminate K1 (matched) from
    # K-unpaired (unmatched). Each direction uses its own cache key
    # — the Send row queries `(boundary, recv, key)` and the Recv row
    # queries `(boundary, send, key)`, matching the
    # `counterpartKey` rule.
    let k1Send = vm.markerRows.val[0]
    let k1Recv = vm.markerRows.val[1]
    var cache = vm.counterpartCache.val
    cache[counterpartKey(k1Send)] = @[k1Recv]
    cache[counterpartKey(k1Recv)] = @[k1Send]
    vm.counterpartCache.val = cache

    # The K-unpaired Send row's counterpart key (`(boundary, recv,
    # K-unpaired)`) has *no* cache entry → treated as unmatched.

    # No filter — all three rows visible.
    check vm.visibleMarkerRows.val.len == 3

    # `boundary:order-processing` keeps everything; `boundary:other`
    # filters everything out.
    vm.setFilterInput("boundary:order-processing")
    check vm.filterBar.val.boundaryFilter == "order-processing"
    check vm.visibleMarkerRows.val.len == 3

    vm.setFilterInput("boundary:other")
    check vm.visibleMarkerRows.val.len == 0

    # `unmatched` shows only rows whose counterpart set is empty.
    # In the fixture: rows 0 (K1) and 1 (K1) have one counterpart
    # each via the cache entry above; row 2 (K-unpaired) has no
    # cache entry → unmatched.
    vm.setFilterInput("unmatched")
    let unmatched = vm.visibleMarkerRows.val
    check unmatched.len == 1
    check unmatched[0].keyValue == "K-unpaired"

    # Compose `boundary:` + `unmatched` + free text.
    vm.setFilterInput("boundary:order-processing unmatched")
    let composed = vm.visibleMarkerRows.val
    check composed.len == 1
    check composed[0].keyValue == "K-unpaired"

    vm.setFilterInput("boundary:order-processing K-unpaired")
    let combo = vm.visibleMarkerRows.val
    check combo.len == 1
    check combo[0].keyValue == "K-unpaired"

# ---------------------------------------------------------------------------
# Layer-2 Test 9 — empty-state + one-time toast.
# ---------------------------------------------------------------------------

suite "M25b — empty state and one-time toast":

  test "test_event_log_vm_empty_state_and_one_time_toast_signals":
    let (vm, _, _) = makeEventLogVM()

    # Case 1: 3 markers declared, 0 fired → empty-state banner.
    vm.applyDiscoveredMarkers(declaredCount = 3, firedCount = 0,
                              workspaceId = "ws-1")
    check vm.emptyState.val.kind == mesDeclaredNoneFired
    check vm.emptyState.val.declaredCount == 3
    check vm.toastState.val.kind == mtVisible
    check vm.toastState.val.discoveredCount == 3

    # Dismiss the toast — flips state + records workspace dismissal.
    vm.dismissToast("ws-1")
    check vm.toastState.val.kind == mtHidden
    check "ws-1" in vm.dismissedWorkspaces.val

    # Case 2: re-discover markers in the same workspace → toast
    # does NOT re-trigger.
    vm.applyDiscoveredMarkers(declaredCount = 5, firedCount = 5,
                              workspaceId = "ws-1")
    check vm.toastState.val.kind == mtHidden
    check vm.emptyState.val.kind == mesHidden

    # Case 3: a different workspace re-triggers the toast.
    vm.applyDiscoveredMarkers(declaredCount = 2, firedCount = 1,
                              workspaceId = "ws-2")
    check vm.toastState.val.kind == mtVisible
    check vm.toastState.val.discoveredCount == 2

when isMainModule:
  discard
