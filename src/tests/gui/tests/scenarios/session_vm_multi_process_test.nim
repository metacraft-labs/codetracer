## session_vm_multi_process_test.nim
##
## M29 §5.3 — Nim ViewModel coverage for the multi-process SessionVM
## extension. The full cross-process E2E live in the Rust wire-shape
## tests (`src/db-backend/tests/cross_process_viewmodel_wire_test.rs`)
## and the deferred Playwright suite; this file pins the Nim-side
## reactive transitions the M29 spec deliverable §5.3 calls out:
##
##   1. `test_session_vm_switches_active_process` — three-recording
##      session, switching the active recording rotates the StateVM
##      alias and asserts state isolation (the M29 spec
##      "test_state_vm_per_process_scoping" companion).
##   2. `test_session_vm_processTree_populated_from_listprocesses` —
##      decoding a `ct/listProcesses` JSON body populates
##      `processTree.entries` with the wire shape the Rust wire-shape
##      test pins on the db-backend side.
##   3. `test_session_vm_origin_chain_vm_crossProcessSpans_derived` —
##      `crossProcessSpans` is a *derived* view of
##      `OriginChainVM.activeChain.crossProcessSpans` and updates
##      reactively when the chain changes.
##   4. `test_session_vm_onSwitchProcess_invokes_host_bridge` — the
##      optional `onSwitchProcessProc` bridge fires exactly once per
##      genuine switch (idempotent on no-op self-switches).
##
## Compile + run:
##   nim c -r src/tests/gui/tests/scenarios/session_vm_multi_process_test.nim

import std/[json, options, sets, unittest, tables]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import session_vm
import viewmodels/[state_vm, origin_chain_vm, origin_chain_types]

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc threeProcessEntries(): seq[ProcessTreeEntry] =
  ## Three-recording session mirroring the M29 fixture B/C shape:
  ## frontend, backend, plus a third (worker) so the test exercises
  ## the per-recording StateVM table beyond the trivial two-entry
  ## case.
  @[
    ProcessTreeEntry(
      recordingId: "rec-fe",
      role: "frontend",
      displayName: "frontend.ct",
      defaultThreadPrefix: "fe",
      threadCount: 1,
    ),
    ProcessTreeEntry(
      recordingId: "rec-be",
      role: "backend",
      displayName: "backend.ct",
      defaultThreadPrefix: "be",
      threadCount: 2,
    ),
    ProcessTreeEntry(
      recordingId: "rec-wk",
      role: "worker",
      displayName: "worker.ct",
      defaultThreadPrefix: "wk",
      threadCount: 1,
    ),
  ]

proc makeSession(): tuple[session: SessionViewModel,
                         mock: MockBackendService] =
  ## Build a SessionViewModel over a MockBackendService — same
  ## pattern the `integration_test.nim` `createAppViewModel` helper
  ## uses, but without `initializePanelViewModels` because the
  ## per-recording StateVM table is what we are testing here.
  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService())
  (session, mock)

# ---------------------------------------------------------------------------
# M29 §5.3 verification #1 — three-recording switch + state isolation.
# ---------------------------------------------------------------------------

suite "M29 — SessionVM multi-process state":

  test "test_session_vm_switches_active_process":
    createRoot proc(disposeRoot: proc()) =
      let (session, _) = makeSession()

      # Seed the three-recording tree. `setProcessTree` should
      # auto-select the first entry and materialise a StateVM per
      # recording so a subsequent switch finds the VM ready.
      session.setProcessTree(threeProcessEntries())

      check session.processTree.entries.val.len == 3
      check session.activeProcessRecordingId.val == "rec-fe"
      check session.stateVMs.len == 3
      check session.stateVMs.hasKey("rec-fe")
      check session.stateVMs.hasKey("rec-be")
      check session.stateVMs.hasKey("rec-wk")
      # Alias points at the first entry's VM.
      check session.stateVM == session.stateVMs["rec-fe"]
      check session.activeStateVM() == session.stateVMs["rec-fe"]

      # Mutate the frontend StateVM so the test can later prove the
      # backend / worker VMs are *not* observing the same signal.
      let feVM = session.stateVMs["rec-fe"]
      feVM.selectTab(stWatches)
      feVM.addWatch("frontend_balance")
      feVM.toggleExpand("locals.req")

      check feVM.activeTab.val == stWatches
      check feVM.watchExpressions.val == @["frontend_balance"]
      check "locals.req" in feVM.expandedPaths.val

      # Now switch to the backend. The alias must rotate and the
      # backend VM's signals must be untouched (default state).
      session.onSwitchProcess("rec-be")
      check session.activeProcessRecordingId.val == "rec-be"
      let beVM = session.stateVMs["rec-be"]
      check session.stateVM == beVM
      check beVM.activeTab.val == stLocals
      check beVM.watchExpressions.val.len == 0
      check beVM.expandedPaths.val.len == 0
      # The frontend VM's mutations are preserved across the switch.
      check feVM.activeTab.val == stWatches
      check feVM.watchExpressions.val == @["frontend_balance"]
      check "locals.req" in feVM.expandedPaths.val

      # Mutate the backend VM and verify the worker stays isolated.
      beVM.selectTab(stGlobals)
      beVM.addWatch("backend_payload")
      session.onSwitchProcess("rec-wk")
      let wkVM = session.stateVMs["rec-wk"]
      check session.stateVM == wkVM
      check wkVM.activeTab.val == stLocals
      check wkVM.watchExpressions.val.len == 0
      check beVM.activeTab.val == stGlobals
      check beVM.watchExpressions.val == @["backend_payload"]

      # No-op self-switch must not flip the alias nor reset signals.
      session.onSwitchProcess("rec-wk")
      check session.activeProcessRecordingId.val == "rec-wk"
      check session.stateVM == wkVM

      # Switching back to the frontend restores its original
      # mutations (this is the load-bearing isolation guarantee).
      session.onSwitchProcess("rec-fe")
      check session.stateVM == feVM
      check feVM.activeTab.val == stWatches
      check feVM.watchExpressions.val == @["frontend_balance"]

      session.dispose()
      disposeRoot()

  # -------------------------------------------------------------------------
  # M29 §5.3 verification #2 — `ct/listProcesses` JSON decode path.
  # -------------------------------------------------------------------------

  test "test_session_vm_processTree_populated_from_listprocesses":
    createRoot proc(disposeRoot: proc()) =
      let (session, _) = makeSession()
      # Wire shape matches `build_ct_list_processes_response` on the
      # db-backend side. The Nim decoder must tolerate the extra
      # `threadIds` field (we only consume the M29 §5.3 contract).
      let body = %*{
        "processes": [
          {
            "recordingId": "rec-fe",
            "role": "frontend",
            "displayName": "frontend.ct",
            "defaultThreadPrefix": "fe",
            "threadCount": 1,
            "threadIds": [1],
          },
          {
            "recordingId": "rec-be",
            "role": "backend",
            "displayName": "backend.ct",
            "defaultThreadPrefix": "be",
            "threadCount": 2,
            "threadIds": [11, 12],
          },
        ],
      }
      session.applyListProcessesResponse(body)

      check session.processTree.entries.val.len == 2
      check session.processTree.entries.val[0].recordingId == "rec-fe"
      check session.processTree.entries.val[0].role == "frontend"
      check session.processTree.entries.val[0].displayName == "frontend.ct"
      check session.processTree.entries.val[0].defaultThreadPrefix == "fe"
      check session.processTree.entries.val[0].threadCount == 1.uint32
      check session.processTree.entries.val[1].recordingId == "rec-be"
      check session.processTree.entries.val[1].threadCount == 2.uint32
      # Active recording auto-selected to the first entry.
      check session.activeProcessRecordingId.val == "rec-fe"

      session.dispose()
      disposeRoot()

  # -------------------------------------------------------------------------
  # M29 §5.3 verification #3 — derived `crossProcessSpans` memo.
  # -------------------------------------------------------------------------

  test "test_session_vm_origin_chain_vm_crossProcessSpans_derived":
    createRoot proc(disposeRoot: proc()) =
      let (session, mock) = makeSession()
      discard mock

      # Wire an OriginChainVM into the session. Before the chain is
      # populated, the derived memo returns an empty seq.
      let originVM = createOriginChainVM(session.store)
      session.attachOriginChainVM(originVM)
      check session.crossProcessSpans.val.len == 0

      # Apply a chain carrying two CrossProcessSpan entries. The
      # derived memo must reflect them on the next read.
      let chain = OriginChain(
        queryVariable: "balance",
        queryStepId: 14,
        crossProcessSpans: @[
          CrossProcessSpan(
            recordingId: "rec-fe",
            role: "frontend",
            firstHopIndex: 0.uint32,
            lastHopIndex: 1.uint32,
          ),
          CrossProcessSpan(
            recordingId: "rec-be",
            role: "backend",
            firstHopIndex: 2.uint32,
            lastHopIndex: 2.uint32,
          ),
        ],
      )
      originVM.applyChainResponse(chain)
      let spans = session.crossProcessSpans.val
      check spans.len == 2
      check spans[0].recordingId == "rec-fe"
      check spans[0].role == "frontend"
      check spans[1].recordingId == "rec-be"
      check spans[1].firstHopIndex == 2.uint32

      originVM.dispose()
      session.dispose()
      disposeRoot()

  # -------------------------------------------------------------------------
  # M29 §5.3 verification #4 — host-bridge dispatch on switch.
  # -------------------------------------------------------------------------

  test "test_session_vm_onSwitchProcess_invokes_host_bridge":
    createRoot proc(disposeRoot: proc()) =
      let (session, _) = makeSession()
      session.setProcessTree(threeProcessEntries())

      var observed = newSeq[string]()
      session.onSwitchProcessProc = proc(recordingId: string) =
        observed.add(recordingId)

      # First switch fires the bridge.
      session.onSwitchProcess("rec-be")
      check observed == @["rec-be"]

      # No-op self-switch does NOT fire the bridge a second time.
      session.onSwitchProcess("rec-be")
      check observed == @["rec-be"]

      # A genuine subsequent switch fires once more.
      session.onSwitchProcess("rec-wk")
      check observed == @["rec-be", "rec-wk"]

      # Empty-recordingId switch is a no-op and the bridge stays
      # silent (defensive against future render-loop wiring bugs).
      session.onSwitchProcess("")
      check observed == @["rec-be", "rec-wk"]

      session.dispose()
      disposeRoot()
