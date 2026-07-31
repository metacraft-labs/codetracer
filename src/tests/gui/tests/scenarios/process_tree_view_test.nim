## process_tree_view_test.nim
##
## M42 §14.8 — coverage for the multi-process session sidebar: the
## production consumer of the `ct/listProcesses` payload, the
## SessionViewModel → view projection, the DOM renderer, and the
## multi-process affordances the Origin Chain Panel gained alongside it
## (cross-process hop badge, hop seek into the owning recording,
## placeholder-span honesty, "Switch process" context-menu entry).
##
## What is NOT mocked: everything under test is real production code —
## `SessionViewModel`, `ui/process_tree`, the IsoNim view rendered
## through IsoNim's own `MockRenderer` (the framework's headless
## renderer, not a hand-written stand-in), and the real
## `isonim_origin_chain` helpers. The only substitute is
## `MockBackendService`, which stands in for the DAP socket because a
## SessionViewModel cannot be constructed without a backend and this
## file asserts nothing about wire traffic. The `ct/listProcesses`
## payloads below are verbatim copies of what
## `db-backend/src/dap_server.rs::build_ct_list_processes_response`
## emits, pinned by
## `db-backend/tests/dap_server_list_processes_event_test.rs`.
##
## Compile + run:
##   nim c -r src/tests/gui/tests/scenarios/process_tree_view_test.nim
## (also runs as part of `just test-vm`, which globs
##  `src/tests/gui/tests/**/*_test.nim`.)

import std/[json, options, sequtils, strutils, tables, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/testing/mock_dom
import backend/mock_backend
import session_vm
import viewmodels/[state_vm, origin_chain_vm, origin_chain_types]
from store/types import Location
import ../../../../frontend/ui/process_tree
import ../../../../frontend/ui/isonim_origin_chain
import ../../../../frontend/viewmodel/views/isonim_process_tree_view
from ../../../../frontend/viewmodel/views/isonim_state_view import
  buildVariableRowContextMenu
from ../../../../frontend/viewmodel/views/state_view import VariableViewState

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc makeSession(): SessionViewModel =
  let mock = newMockBackendService(autoRespond = true)
  createSessionVM(mock.toBackendService())

proc threeTraceListProcessesBody(): JsonNode =
  ## Verbatim shape of the `ct/listProcesses` body the backend emits at
  ## session load for the committed `account-balance-with-wasm`
  ## fixture: three `[[trace]]` rows with composed thread ids
  ## `slot << 24 | 1`.
  %*{
    "processes": [
      {
        "recordingId": "018f0000-0000-7000-8000-frontendjs01",
        "role": "frontend-js",
        "displayName": "frontend.ct",
        "defaultThreadPrefix": "fe",
        "threadCount": 1,
        "threadIds": [1],
      },
      {
        "recordingId": "018f0000-0000-7000-8000-frontendwsm1",
        "role": "frontend-wasm",
        "displayName": "frontend-wasm.ct",
        "defaultThreadPrefix": "wasm",
        "threadCount": 1,
        "threadIds": [(1 shl 24) or 1],
      },
      {
        "recordingId": "018f0000-0000-7000-8000-backendnode1",
        "role": "backend",
        "displayName": "backend.ct",
        "defaultThreadPrefix": "be",
        "threadCount": 1,
        "threadIds": [(2 shl 24) or 1],
      },
    ],
  }

proc flatten(node: MockNode): string =
  ## Serialise a MockNode tree to a markup-ish string so assertions can
  ## be written against the emitted attributes and text directly.
  if node.isNil:
    return ""
  if node.kind == mnkText:
    return node.text
  result = "<" & node.tag
  for name, value in node.attributes.pairs:
    result &= " " & name & "=\"" & value & "\""
  result &= ">"
  for child in node.children:
    result &= flatten(child)
  result &= "</" & node.tag & ">"

proc renderedTree(model: ProcessTreeModel;
                  callbacks = ProcessTreeCallbacks()): MockNode =
  ## Render through IsoNim's own headless renderer — the same view code
  ## the browser runs, minus the browser.
  let r = MockRenderer()
  r.renderProcessTree(model, callbacks)

proc renderedMarkup(model: ProcessTreeModel): string =
  flatten(renderedTree(model))

proc clickRowWithRole(root: MockNode; role: string): bool =
  ## Find the rendered row for `role` and fire its click listener,
  ## exercising the wiring the browser's `onclick` would.
  if root.isNil:
    return false
  if root.attributes.getOrDefault("data-process-role") == role:
    for handler in root.eventListeners.getOrDefault("click"):
      handler()
    return true
  for child in root.children:
    if clickRowWithRole(child, role):
      return true
  false

# ---------------------------------------------------------------------------
# 1. The production consumer of `ct/listProcesses`.
# ---------------------------------------------------------------------------

suite "M42 §14.8 — process tree is fed by the session-load payload":

  test "verify_process_tree_populates_on_session_load":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      # Precondition: an unfed session has nothing to draw.
      check session.processTree.entries.val.len == 0

      # The production path — the same call `ui/process_tree` makes from
      # the `CtListProcesses` DAP-event subscription in `ui_js.nim`. No
      # test-only entry point is involved.
      session.consumeListProcessesEvent(threeTraceListProcessesBody())

      check session.processTree.entries.val.len == 3
      let roles = session.processTree.entries.val.mapIt(it.role)
      check roles == @["frontend-js", "frontend-wasm", "backend"]
      # First entry auto-selected so panes have an active recording.
      check session.activeProcessRecordingId.val ==
        "018f0000-0000-7000-8000-frontendjs01"

      session.dispose()
      disposeRoot()

  test "list_processes_payload_carries_routing_thread_ids":
    # Switching process is *only* expressible as a `threadId` on
    # outgoing requests, so losing this field silently disables process
    # switching while leaving the tree looking correct.
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.consumeListProcessesEvent(threeTraceListProcessesBody())

      let backend = session.entryForRecording(
        "018f0000-0000-7000-8000-backendnode1")
      check backend.isSome
      check backend.get.routingThreadId() == ((2 shl 24) or 1)

      let wasm = session.entryForRecording(
        "018f0000-0000-7000-8000-frontendwsm1")
      check wasm.isSome
      check wasm.get.routingThreadId() == ((1 shl 24) or 1)

      check session.entryForRecording("no-such-recording").isNone

      session.dispose()
      disposeRoot()

  test "list_processes_consumer_tolerates_a_malformed_payload":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.consumeListProcessesEvent(newJNull())
      session.consumeListProcessesEvent(%*{"processes": "not-an-array"})
      session.consumeListProcessesEvent(%*{"processes": [{"role": "orphan"}]})
      check session.processTree.entries.val.len == 0
      session.dispose()
      disposeRoot()

  test "entry_without_thread_ids_reports_no_routing_id":
    # A backend predating the `threadIds` field must not be mistaken for
    # one advertising thread 0 — the host bridge treats 0 as "leave
    # routing alone" rather than silently routing to slot 0.
    let entry = ProcessTreeEntry(recordingId: "rec", role: "main")
    check entry.routingThreadId() == 0

# ---------------------------------------------------------------------------
# 2. Projection + click wiring.
# ---------------------------------------------------------------------------

suite "M42 §14.8 — process tree projection and click dispatch":

  test "verify_process_tree_renders_one_element_per_recording":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.consumeListProcessesEvent(threeTraceListProcessesBody())

      let markup = renderedMarkup(session.processTreeModel())
      for role in ["frontend-js", "frontend-wasm", "backend"]:
        check markup.count("data-process-role=\"" & role & "\"") == 1
      # Exactly one row per recording — no duplicates, no extras.
      check markup.count("ct-process-tree-entry") == 3
      # `data-process-role` is the settled selector; the tree must not
      # also emit `data-role`, which the Origin Chain breadcrumb chips
      # already use for the very same role tokens.
      check not markup.contains("data-role=")

      session.dispose()
      disposeRoot()

  test "process_tree_marks_the_active_recording":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.consumeListProcessesEvent(threeTraceListProcessesBody())

      var model = session.processTreeModel()
      check model.entries[0].active
      check not model.entries[2].active
      check renderedMarkup(model).count("aria-selected=\"true\"") == 1

      session.onSwitchProcess("018f0000-0000-7000-8000-backendnode1")
      model = session.processTreeModel()
      check not model.entries[0].active
      check model.entries[2].active
      check renderedMarkup(model).contains(
        "ct-process-tree-entry active")

      session.dispose()
      disposeRoot()

  test "process_tree_click_rotates_the_active_recording_and_state_vm":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.consumeListProcessesEvent(threeTraceListProcessesBody())
      var bridged: seq[string] = @[]
      session.onSwitchProcessProc = proc(recordingId: string) =
        bridged.add(recordingId)

      let firstStateVM = session.activeStateVM()
      # Drive the click through the rendered view, not the callback
      # object directly, so the view's own handler wiring is covered.
      let root = renderedTree(session.processTreeModel(),
                              session.processTreeCallbacks())
      check clickRowWithRole(root, "backend")

      check session.activeProcessRecordingId.val ==
        "018f0000-0000-7000-8000-backendnode1"
      check bridged == @["018f0000-0000-7000-8000-backendnode1"]
      # Each recording keeps its own per-step view state (§5.3).
      check session.activeStateVM() != firstStateVM

      # A redundant click on the already-active row must not re-fire the
      # host bridge (which would re-issue a backend navigation).
      session.processTreeCallbacks().onSelectProcess(
        "018f0000-0000-7000-8000-backendnode1")
      check bridged.len == 1

      session.dispose()
      disposeRoot()

  test "single_recording_sessions_draw_no_tree":
    # §14.8 describes the tree as a multi-process affordance; a
    # one-row list that can never do anything is noise, and drawing it
    # would move every single-recording layout.
    let single = ProcessTreeModel(entries: @[
      ProcessTreeEntryRecord(recordingId: "rec", role: "main",
                             displayName: "main.ct", threadCount: 1,
                             active: true)])
    check not shouldRenderTree(single)
    check shouldRenderTree(ProcessTreeModel(entries: @[
      ProcessTreeEntryRecord(recordingId: "a", role: "frontend-js"),
      ProcessTreeEntryRecord(recordingId: "b", role: "backend")]))

  test "process_tree_row_shows_role_thread_count_and_recording_id":
    # §14.8: "listing each trace's role + thread count".
    let model = ProcessTreeModel(entries: @[
      ProcessTreeEntryRecord(recordingId: "rec-a", role: "frontend-js",
                             displayName: "frontend.ct", threadCount: 1),
      ProcessTreeEntryRecord(recordingId: "rec-b", role: "backend",
                             displayName: "backend.ct", threadCount: 4)])
    let markup = renderedMarkup(model)
    check markup.contains("frontend-js")
    check markup.contains("frontend.ct")
    check markup.contains("1 thread")
    check markup.contains("4 threads")
    check markup.contains("rec-b")
    check threadCountLabel(1) == "1 thread"
    check threadCountLabel(0) == "0 threads"

# ---------------------------------------------------------------------------
# 3. Origin Chain Panel multi-process affordances.
# ---------------------------------------------------------------------------

proc chainWithPlaceholderTail(invertedRange = false): OriginChain =
  ## The chain the committed fixture actually produces (`ANSWERS.md`):
  ## backend hops 0..1, frontend-js hop 2, frontend-wasm hop 3, plus a
  ## trailing zero-hop `frontend-js` span the composer emits when it
  ## asks a recording to continue and gets nothing back (M36b).
  ##
  ## The trailing span is built in the encoding
  ## `cross_process_origin.rs::compose_cross_process_chain` step 4
  ## really emits: `first == last == chain.hops.len()`, one past the
  ## last hop. That function deliberately does *not* emit an inverted
  ## `first > last` range, because "any renderer that slices
  ## `hops[first..=last]` to draw the span would either panic or
  ## silently show the wrong hops". Pass `invertedRange = true` to get
  ## the inverted encoding instead, so both are covered.
  var hops: seq[OriginHop] = @[]
  for i in 0 ..< 4:
    hops.add(OriginHop(
      kind: okTrivialCopy,
      targetExpr: "v" & $i,
      stepId: int64(70 + i),
      location: OriginLocation(path: "f" & $i & ".js", line: i + 1),
    ))
  hops[2].correlationTransition = some(CorrelationTransition(
    direction: "recv",
    correlatedRecordingId: "rec-fe-js",
    boundaryId: "account-balance",
    matchKeyValue: "req-0001",
  ))
  OriginChain(
    queryVariable: "balance",
    queryStepId: 72,
    hops: hops,
    terminator: Terminator(kind: tkwLiteral, expression: "42"),
    crossProcessSpans: @[
      CrossProcessSpan(recordingId: "rec-be", role: "backend",
                       firstHopIndex: 0'u32, lastHopIndex: 1'u32),
      CrossProcessSpan(recordingId: "rec-fe-js", role: "frontend-js",
                       firstHopIndex: 2'u32, lastHopIndex: 2'u32),
      CrossProcessSpan(recordingId: "rec-fe-wasm", role: "frontend-wasm",
                       firstHopIndex: 3'u32, lastHopIndex: 3'u32),
      # Zero-hop trailing span. Default: the collapsed encoding the
      # db-backend emits (`first == last == hops.len`). Inverted
      # (`first > last`) only when the caller asks for it.
      CrossProcessSpan(
        recordingId: "rec-fe-js", role: "frontend-js",
        firstHopIndex: 4'u32,
        lastHopIndex: (if invertedRange: 3'u32 else: 4'u32)),
    ],
  )

suite "M42 §14.8 — chain panel multi-process affordances":

  test "placeholder_span_is_marked_and_does_not_inflate_the_real_count":
    # Both wire encodings of a zero-hop trailing span must be detected.
    # The first is what the db-backend emits today; the second is the
    # inverted range the wire format also permits.
    for chain in [chainWithPlaceholderTail(),
                  chainWithPlaceholderTail(invertedRange = true)]:
      let chips = chainBreadcrumbChips(chain)
      check chips.len == 4
      check not chips[0].isPlaceholder
      check not chips[1].isPlaceholder
      check not chips[2].isPlaceholder
      check chips[3].isPlaceholder
      # The user-visible claim "all three recordings explain this value"
      # must rest on spans that actually own hops.
      check substantiveBreadcrumbChips(chips) == 3

  test "placeholder_span_never_claims_ownership_of_a_hop":
    for chain in [chainWithPlaceholderTail(),
                  chainWithPlaceholderTail(invertedRange = true)]:
      check spanOwningHop(chain, 0).get.role == "backend"
      check spanOwningHop(chain, 2).get.role == "frontend-js"
      check spanOwningHop(chain, 3).get.role == "frontend-wasm"
      check spanOwningHop(chain, 9).isNone

  test "cross_process_hop_badge_names_the_boundary_and_peer":
    let chain = chainWithPlaceholderTail()
    check not isCrossProcessHop(chain.hops[0])
    check isCrossProcessHop(chain.hops[2])
    check crossProcessBadgeLabel(chain.hops[2]) == "account-balance"
    let title = crossProcessBadgeTitle(chain.hops[2])
    check title.contains("account-balance")
    check title.contains("rec-fe-js")
    check title.contains("req-0001")
    check crossProcessBadgeLabel(chain.hops[0]) == ""

  test "clicking_a_hop_switches_to_its_owning_recording_before_seeking":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      let originVM = createOriginChainVM(session.store)
      var switched: seq[string] = @[]
      var seeks: seq[int64] = @[]
      originVM.onSwitchProcessProc = proc(recordingId: string) =
        switched.add(recordingId)
      originVM.onSeekProc = proc(stepId: int64; location: Location) =
        seeks.add(stepId)

      let chain = chainWithPlaceholderTail()
      originVM.seekToHopInOwningProcess(chain, 3)
      check switched == @["rec-fe-wasm"]
      check seeks == @[int64(73)]

      # Out-of-range indices are inert rather than throwing.
      originVM.seekToHopInOwningProcess(chain, 42)
      check switched.len == 1
      check seeks.len == 1

      originVM.dispose()
      session.dispose()
      disposeRoot()

# ---------------------------------------------------------------------------
# 4. "Switch process" right-click entry.
# ---------------------------------------------------------------------------

suite "M42 §14.8 — State Pane 'Switch process' menu entry":

  test "switch_process_entry_absent_without_a_cross_process_correlation":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.initializePanelViewModels()
      let menu = session.stateVM.buildVariableRowContextMenu(
        VariableViewState(name: "balance", path: "balance"))
      check menu.len == 2
      check menu[1].label == "Show value origin"
      session.dispose()
      disposeRoot()

  test "switch_process_entry_offered_once_per_sibling_recording":
    createRoot proc(disposeRoot: proc()) =
      let session = makeSession()
      session.initializePanelViewModels()
      let vm = session.stateVM
      var switched: seq[string] = @[]
      vm.crossProcessSwitchTargets = proc(): seq[ProcessSwitchTarget] =
        @[ProcessSwitchTarget(recordingId: "rec-fe-js", role: "frontend-js"),
          ProcessSwitchTarget(recordingId: "rec-fe-wasm",
                              role: "frontend-wasm")]
      vm.onSwitchProcessProc = proc(recordingId: string) =
        switched.add(recordingId)

      let menu = vm.buildVariableRowContextMenu(
        VariableViewState(name: "balance", path: "balance"))
      check menu.len == 4
      check menu[2].label == "Switch process: frontend-js"
      check menu[3].label == "Switch process: frontend-wasm"

      menu[3].action()
      check switched == @["rec-fe-wasm"]

      session.dispose()
      disposeRoot()
