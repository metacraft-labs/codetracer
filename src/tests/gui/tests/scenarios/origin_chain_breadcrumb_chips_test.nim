## origin_chain_breadcrumb_chips_test.nim
##
## M29 §14.8 — Nim ViewModel coverage for the chain-panel breadcrumb
## chip renderer. The TCT-M5 Playwright spec at
## `src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts`
## asserts the chain panel renders three breadcrumb chips when the
## active chain crosses three processes — one per `CrossProcessSpan`.
## This file pins the renderer-side derivation + the click dispatch
## contract so the GUI spec, the headless DAP composer test, and the
## ViewModel layer remain in sync.
##
## Compile + run:
##   nim c -r src/tests/gui/tests/scenarios/origin_chain_breadcrumb_chips_test.nim

import std/unittest
import vm_test_helpers
import isonim/core/[signals, owner]
import isonim/viewmodel
import backend/mock_backend
import store/replay_data_store
import store/types as store_types
import session_vm
import viewmodels/[origin_chain_vm, origin_chain_types]
# The renderer's chip derivation helper is published from
# `src/frontend/ui/isonim_origin_chain.nim` and is import-safe on the
# native backend (the DOM emit path is gated by `when defined(js)`).
import ../../../../frontend/ui/isonim_origin_chain

# ---------------------------------------------------------------------------
# Fixtures — a three-recording chain mirroring the §14.8 contract.
# Hop layout (0-indexed):
#   hops[0..1] — backend  (span #1)
#   hops[2..3] — frontend-wasm (span #2)
#   hops[4]   — frontend-js (span #3; terminator carrier)
# Matches the canonical `account-balance-with-wasm` fixture ANSWERS.md.
# ---------------------------------------------------------------------------

proc threeRecordingChain(): OriginChain =
  ## Build a chain whose hops cross three recordings. The hops carry
  ## minimum metadata required for `onSeekToHop` to dispatch — the
  ## renderer test only inspects `crossProcessSpans` + `hops.len`.
  var hops: seq[OriginHop] = @[]
  for i in 0 ..< 5:
    hops.add(OriginHop(
      kind: okTrivialCopy,
      targetExpr: "v" & $i,
      sourceExpr: "v" & $(i + 1),
      stepId: int64(100 + i),
      location: OriginLocation(path: "src" & $i & ".py", line: i + 1),
    ))
  OriginChain(
    queryVariable: "balance",
    queryStepId: 100,
    hops: hops,
    terminator: Terminator(kind: tkwLiteral, expression: "42"),
    crossProcessSpans: @[
      CrossProcessSpan(recordingId: "rec-be",
                       role: "backend",
                       firstHopIndex: 0.uint32,
                       lastHopIndex: 1.uint32),
      CrossProcessSpan(recordingId: "rec-fwasm",
                       role: "frontend-wasm",
                       firstHopIndex: 2.uint32,
                       lastHopIndex: 3.uint32),
      CrossProcessSpan(recordingId: "rec-fjs",
                       role: "frontend-js",
                       firstHopIndex: 4.uint32,
                       lastHopIndex: 4.uint32),
    ],
  )

proc singleProcessChain(): OriginChain =
  ## Same hops but no `crossProcessSpans` — the renderer must fall
  ## back to the legacy `breadcrumbStack` strip in this case.
  OriginChain(
    queryVariable: "x",
    queryStepId: 7,
    hops: @[
      OriginHop(kind: okTrivialCopy, targetExpr: "x",
                sourceExpr: "y", stepId: 7,
                location: OriginLocation(path: "a.py", line: 1)),
    ],
    terminator: Terminator(kind: tkwLiteral, expression: "1"),
  )

proc makeOriginVM(): tuple[vm: OriginChainVM, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createOriginChainVM(store)
  drain()
  (vm, mock)

# ---------------------------------------------------------------------------
# Test #1 — chip count matches `crossProcessSpans.len`.
# ---------------------------------------------------------------------------

suite "M29 §14.8 — chain panel breadcrumb-chip renderer":

  test "test_chain_breadcrumb_chips_one_per_cross_process_span":
    ## The TCT-M5 Playwright spec asserts `breadcrumbChips() toHaveCount(3)`
    ## for a three-recording chain; this test pins the derivation
    ## that powers the rendered count so the spec passes without DOM
    ## inspection here.
    let chain = threeRecordingChain()
    let chips = chainBreadcrumbChips(chain)
    check chips.len == 3
    check chips[0].recordingId == "rec-be"
    check chips[0].role == "backend"
    check chips[0].label == "backend"
    check chips[0].hopIndex == 0
    check chips[1].recordingId == "rec-fwasm"
    check chips[1].role == "frontend-wasm"
    check chips[1].label == "frontend-wasm"
    check chips[1].hopIndex == 2
    check chips[2].recordingId == "rec-fjs"
    check chips[2].role == "frontend-js"
    check chips[2].hopIndex == 4

  # -------------------------------------------------------------------------
  # Test #2 — fallback for single-process chains.
  # -------------------------------------------------------------------------

  test "test_chain_breadcrumb_chips_empty_for_single_process_chain":
    let chain = singleProcessChain()
    check chainBreadcrumbChips(chain).len == 0

  # -------------------------------------------------------------------------
  # Test #3 — clicking chip #2 dispatches onSwitchProcess + seek.
  # -------------------------------------------------------------------------

  test "test_chain_breadcrumb_chip_click_dispatches_on_switch_process":
    createRoot proc(disposeRoot: proc()) =
      let (vm, _) = makeOriginVM()
      let chain = threeRecordingChain()
      vm.applyChainResponse(chain)

      var switched: seq[string] = @[]
      var seekedStep: int64 = -1
      var seekedPath = ""
      vm.onSwitchProcessProc = proc(recordingId: string) =
        switched.add(recordingId)
      vm.onSeekProc = proc(stepId: int64; loc: Location) =
        seekedStep = stepId
        seekedPath = loc.file

      let chips = chainBreadcrumbChips(chain)
      check chips.len == 3
      # Pick chip #2 (the WASM-side span) — same hop the Playwright
      # spec clicks to assert the active recording rotates to
      # `frontend-wasm`.
      let secondSpan = chain.crossProcessSpans[1]
      vm.onSwitchToSpan(secondSpan)

      check switched == @["rec-fwasm"]
      check seekedStep == chain.hops[2].stepId
      check seekedPath == chain.hops[2].location.path

      vm.dispose()
      disposeRoot()

  # -------------------------------------------------------------------------
  # Test #4 — attachOriginChainVM auto-installs the SessionVM bridge.
  # -------------------------------------------------------------------------

  test "test_chain_breadcrumb_chip_click_routes_through_session_vm":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.setProcessTree(@[
        ProcessTreeEntry(recordingId: "rec-be", role: "backend",
                         displayName: "backend.ct",
                         defaultThreadPrefix: "be", threadCount: 1),
        ProcessTreeEntry(recordingId: "rec-fwasm",
                         role: "frontend-wasm",
                         displayName: "frontend-wasm.ct",
                         defaultThreadPrefix: "fw", threadCount: 1),
        ProcessTreeEntry(recordingId: "rec-fjs",
                         role: "frontend-js",
                         displayName: "frontend-js.ct",
                         defaultThreadPrefix: "fj", threadCount: 1),
      ])
      check session.activeProcessRecordingId.val == "rec-be"

      let originVM = createOriginChainVM(session.store)
      session.attachOriginChainVM(originVM)

      # The session's host bridge is wired so we can verify the
      # double-dispatch (chip → onSwitchToSpan → SessionVM.onSwitchProcess
      # → onSwitchProcessProc) without manually wiring the bridge here.
      var hostObserved: seq[string] = @[]
      session.onSwitchProcessProc = proc(recordingId: string) =
        hostObserved.add(recordingId)

      let chain = threeRecordingChain()
      originVM.applyChainResponse(chain)

      # Click chip #2 → rotate active recording to `rec-fwasm`.
      originVM.onSwitchToSpan(chain.crossProcessSpans[1])
      check session.activeProcessRecordingId.val == "rec-fwasm"
      check hostObserved == @["rec-fwasm"]

      # Click chip #3 → rotate to `rec-fjs`.
      originVM.onSwitchToSpan(chain.crossProcessSpans[2])
      check session.activeProcessRecordingId.val == "rec-fjs"
      check hostObserved == @["rec-fwasm", "rec-fjs"]

      originVM.dispose()
      session.dispose()
      disposeRoot()
