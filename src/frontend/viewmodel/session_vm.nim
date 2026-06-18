## viewmodel/session_vm.nim
##
## SessionViewModel — top-level container that owns the shared
## ReplayDataStore and all panel ViewModels for a single replay session.
##
## The factory `createSessionVM` takes a BackendService (which may be
## backed by a real DapApi or a mock) and constructs the shared
## ReplayDataStore wired to that backend.
##
## This ensures that every panel sees the same reactive data and that
## commands sent through the store reach the real backend.
##
## The session_vm does NOT own or replace the legacy event-bus code.
## The existing UI still reads from legacy data structures.  The
## default `createSessionVM` constructor stays passive during startup:
## constructing it must not emit backend requests or mount any panel DOM.
##
## App-level owners that need a complete ViewModel graph call
## `initializePanelViewModels` explicitly after their backend and
## lifecycle wiring is ready.
##
## M29 §5.3 extends this module with multi-process state:
##  - `ProcessTreeEntry` / `ProcessTreeVM` mirror the
##    `ct/listProcesses` wire shape (per-recording row metadata).
##  - `SessionViewModel.activeProcessRecordingId` + `stateVMs`
##    scope per-recording `StateVM` instances so each recording
##    maintains its own per-step variable / watch / expansion
##    state (the per-process scoping test).
##  - `crossProcessSpans` is a derived `Memo` over
##    `OriginChainVM.activeChain.crossProcessSpans` so the Origin
##    Chain side panel renders per-process breadcrumb chips without
##    extra round-trips.
##  - `onSwitchProcess` rotates the active recording (and the
##    `stateVM` alias) and invokes the optional `onSwitchProcessProc`
##    host bridge that owns the actual `ct/goto-ticks` dispatch.

import std/[json, options, tables]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel  # for ViewModel.dispose
import backend/backend_service
import collab/[projection, runtime_role, session_core]
import store/replay_data_store
import viewmodels/[
  state_vm,
  calltrace_vm,
  event_log_vm,
  flow_vm,
  editor_vm,
  timeline_vm,
  debug_controls_vm,
  search_vm,
  point_list_vm,
  scratchpad_vm,
  shell_vm,
  origin_chain_vm,
  origin_chain_types,
]

type
  ProcessTreeEntry* = object
    ## M29 §5.3 — one row in the multi-process session sidebar.
    ## Mirrors the wire shape produced by `ct/listProcesses`
    ## (`src/db-backend/src/dap_server.rs::build_ct_list_processes_response`).
    ## `recordingId` is the stable per-recording handle the rest of
    ## the ViewModel uses to scope state.
    recordingId*: string
    role*: string
    displayName*: string
    defaultThreadPrefix*: string
    threadCount*: uint32

  ProcessTreeVM* = ref object of ViewModel
    ## Reactive holder for the multi-process tree (M29 §5.3). Owns
    ## the list of recordings; the active selection lives directly
    ## on `SessionViewModel.activeProcessRecordingId` so panes can
    ## subscribe to either independently.
    entries*: Signal[seq[ProcessTreeEntry]]

  SessionViewModel* = ref object
    ## Holds all ViewModel layer objects for a single replay session.
    ## Created once per session and shared across all panels.
    store*: ReplayDataStore
    backend*: BackendService
    collabCore*: CollaborativeSessionCore
    runtimeRole*: ViewModelRuntimeRole
    stateVM*: StateVM
      ## Single-process compatibility alias — points at the
      ## currently-active recording's per-recording StateVM. Pre-M29
      ## call sites that read `session.stateVM` continue to work; the
      ## alias is rotated by `onSwitchProcess`.
    calltraceVM*: CalltraceVM
    eventLogVM*: EventLogVM
    flowVM*: FlowVM
    editorVM*: EditorVM
    timelineVM*: TimelineVM
    debugControlsVM*: DebugControlsVM
    searchVM*: SearchVM
    pointListVM*: PointListVM
    scratchpadVM*: ScratchpadVM
    shellVM*: ShellVM
    originChainVM*: OriginChainVM
      ## Optional Value Origin Tracking VM. The host attaches it via
      ## `attachOriginChainVM` so the derived `crossProcessSpans`
      ## memo (M29 §5.3) sees the chain. Left nil in tests that
      ## don't exercise the cross-process surface.

    # -- M29 multi-process state (§5.3) ----------------------------------
    processTree*: ProcessTreeVM
      ## Sidebar list of recordings + thread metadata.
    activeProcessRecordingId*: Signal[string]
      ## Currently-active recording id. Empty string until the first
      ## `ct/listProcesses` reply lands or `setProcessTree` is called
      ## explicitly (tests).
    stateVMs*: Table[string, StateVM]
      ## Per-recording StateVM table — each entry owns independent
      ## `activeTab` / `expandedPaths` / `watchExpressions` /
      ## `selectedPath` signals so switching the active process does
      ## not corrupt the inactive recording's per-step view.
    crossProcessSpans*: Memo[seq[CrossProcessSpan]]
      ## Derived view of
      ## `originChainVM.activeChain.crossProcessSpans` (§5.3). Empty
      ## seq when no chain is active or the chain is single-process.
    onSwitchProcessProc*: proc(recordingId: string)
      ## Optional host bridge. The renderer installs this to wire
      ## the `ct/goto-ticks` switch into the existing replay-session
      ## pipeline (mirrors `EventLogVM.jumpToCounterpart`).

proc createProcessTreeVM*(): ProcessTreeVM =
  ## Construct an empty ProcessTreeVM owned by its own reactive root
  ## so the host can dispose it via `vm.dispose()`. Per M29 §5.3 the
  ## tree starts empty; rows arrive from the first
  ## `ct/listProcesses` reply.
  withViewModel proc(dispose: proc()): ProcessTreeVM =
    ProcessTreeVM(
      entries: createSignal(newSeq[ProcessTreeEntry]()),
      disposeProc: dispose,
    )

proc createSessionVM*(backend: BackendService;
                      runtimeRole = vrrStandalone): SessionViewModel =
  ## Create the shared ViewModel store for a replay session.
  ##
  ## The BackendService is typically created via `newRealBackendService`
  ## (from real_backend.nim) with adapter procs that bridge to DapApi.
  ## In tests, a MockBackendService can be passed instead.
  ##
  ## All panel VMs created later share the same ReplayDataStore, so a
  ## debugger position change propagates to every panel's reactive
  ## pipeline without running panel effects before middleware wiring is
  ## complete.
  let store = createReplayDataStore(backend)
  let core = createCollaborativeSessionCore(
    sessionId = "local-session-" & $store.storeId,
    localPrincipalId = "local-user",
    localActorId = "local-actor-" & $store.storeId,
    localReplicaId = "local-replica-" & $store.storeId,
    backendOwnerId = "local-user",
  )

  # M29 §5.3 — pre-build the empty multi-process containers so
  # callers that never extend to multi-process still see well-typed
  # signals. The reactive primitives live in their own VM root so
  # disposal is centralised in `SessionViewModel.dispose`.
  let tree = createProcessTreeVM()
  let activeRecording = createSignal("")
  let session = SessionViewModel(
    store: store,
    backend: backend,
    collabCore: core,
    runtimeRole: runtimeRole,
    processTree: tree,
    activeProcessRecordingId: activeRecording,
    stateVMs: initTable[string, StateVM](),
  )
  # `crossProcessSpans` reads through `session.originChainVM` at
  # compute time. Wiring the OriginChainVM later is a one-line
  # `attachOriginChainVM` assignment.
  session.crossProcessSpans =
    createMemo[seq[CrossProcessSpan]] proc(): seq[CrossProcessSpan] =
      if session.originChainVM.isNil:
        return newSeq[CrossProcessSpan]()
      let chain = session.originChainVM.activeChain.val
      if chain.isNone:
        return newSeq[CrossProcessSpan]()
      chain.get.crossProcessSpans
  session

proc initializePanelViewModels*(session: SessionViewModel) =
  ## Create the standard panel ViewModels for a SessionViewModel.
  ##
  ## This is intentionally separate from `createSessionVM`: several panel
  ## VMs own reactive effects that may issue backend requests, so the
  ## production startup sequence must opt in only after middleware and bridge
  ## callbacks are ready. Headless app tests use this proc to instantiate the
  ## same app-level ViewModel graph without involving DOM or legacy modules.
  if session.isNil or session.store.isNil:
    return

  if session.stateVM.isNil:
    session.stateVM = createStateVM(
      session.store, session.collabCore, session.runtimeRole)
    installStateProjection(session.collabCore, session.stateVM)
  if session.calltraceVM.isNil:
    session.calltraceVM = createCalltraceVM(
      session.store, session.collabCore, session.runtimeRole)
    installCalltraceProjection(session.collabCore, session.calltraceVM)
  if session.eventLogVM.isNil:
    session.eventLogVM = createEventLogVM(session.store)
  if session.flowVM.isNil:
    session.flowVM = createFlowVM(session.store)
  if session.editorVM.isNil:
    session.editorVM = createEditorVM(session.store)
  if session.timelineVM.isNil:
    session.timelineVM = createTimelineVM(session.store)
  if session.debugControlsVM.isNil:
    session.debugControlsVM = createDebugControlsVM(session.store)
  if session.searchVM.isNil:
    session.searchVM = createSearchVM(session.store)
  if session.pointListVM.isNil:
    session.pointListVM = createPointListVM(session.store)
  if session.scratchpadVM.isNil:
    session.scratchpadVM = createScratchpadVM(session.store)
  if session.shellVM.isNil:
    session.shellVM = createShellVM(session.store)

# ---------------------------------------------------------------------------
# M29 §5.3 — multi-process session management
# ---------------------------------------------------------------------------

proc ensureStateVM*(session: SessionViewModel;
                    recordingId: string): StateVM =
  ## Return the per-recording StateVM, creating it lazily on first
  ## access. Each recording owns an independent set of signals so
  ## switching the active process does not corrupt the inactive
  ## recording's per-step view.
  ##
  ## Note: per-recording StateVMs are built WITHOUT a CollaborativeSessionCore
  ## reference — `selectTab` / `toggleExpand` / `addWatch` go through
  ## `collabCore.dispatchLocalViewOp` (a single shared CRDT document
  ## state) which would otherwise mirror every mutation across every
  ## recording's VM via the same `statePane.*` slot. Local signal
  ## writes give the per-recording isolation guarantee the spec §5.3
  ## demands. The active-recording's StateVM (rotated by
  ## `onSwitchProcess`) is the one the collab projection bridge
  ## targets via the legacy single-VM path — out of scope for M29's
  ## ship-core deliverable, in scope for the collab follow-on.
  if session.stateVMs.hasKey(recordingId):
    return session.stateVMs[recordingId]
  let vm = createStateVM(session.store, nil, session.runtimeRole)
  session.stateVMs[recordingId] = vm
  vm

proc setProcessTree*(session: SessionViewModel;
                     entries: openArray[ProcessTreeEntry]) =
  ## Replace the process tree wholesale. Eagerly materialises a
  ## per-recording StateVM for every entry so a subsequent
  ## `onSwitchProcess` finds the VM ready (no race with the first
  ## panel render). When the active recording is empty (first reply)
  ## the first entry is selected automatically.
  var seqEntries = newSeq[ProcessTreeEntry](entries.len)
  for i, e in entries:
    seqEntries[i] = e
    discard session.ensureStateVM(e.recordingId)
  session.processTree.entries.val = seqEntries
  if session.activeProcessRecordingId.val.len == 0 and seqEntries.len > 0:
    let first = seqEntries[0].recordingId
    session.activeProcessRecordingId.val = first
    if session.stateVMs.hasKey(first):
      session.stateVM = session.stateVMs[first]

proc applyListProcessesResponse*(session: SessionViewModel;
                                 body: JsonNode) =
  ## Decode a `ct/listProcesses` response body (the JSON shape
  ## emitted by `build_ct_list_processes_response` on the db-backend)
  ## and populate the process tree. Tolerates wire drift by skipping
  ## entries with a missing `recordingId`.
  if body.isNil or body.kind != JObject:
    return
  let processes = body{"processes"}
  if processes.isNil or processes.kind != JArray:
    return
  var entries = newSeq[ProcessTreeEntry]()
  for n in processes:
    if n.kind != JObject:
      continue
    let recordingId = n{"recordingId"}.getStr("")
    if recordingId.len == 0:
      continue
    entries.add(ProcessTreeEntry(
      recordingId: recordingId,
      role: n{"role"}.getStr(""),
      displayName: n{"displayName"}.getStr(""),
      defaultThreadPrefix: n{"defaultThreadPrefix"}.getStr(""),
      threadCount: uint32(n{"threadCount"}.getInt(0)),
    ))
  session.setProcessTree(entries)

proc onSwitchProcess*(session: SessionViewModel; recordingId: string) =
  ## Switch the active recording to `recordingId`. No-op when the
  ## recording is already active so a redundant click does not fire
  ## the host bridge twice.
  ##
  ## Side effects (per M29 §5.3):
  ##   1. `activeProcessRecordingId` flips (signal fan-out
  ##      re-renders dependent panes),
  ##   2. the `stateVM` alias rotates so legacy call sites that
  ##      read `session.stateVM.*` see the right per-step state,
  ##   3. the optional `onSwitchProcessProc` host bridge fires so
  ##      the renderer can dispatch `ct/goto-ticks` to actually move
  ##      the backend cursor into the new recording.
  if recordingId.len == 0:
    return
  if session.activeProcessRecordingId.val == recordingId:
    return
  let vm = session.ensureStateVM(recordingId)
  session.activeProcessRecordingId.val = recordingId
  session.stateVM = vm
  if not session.onSwitchProcessProc.isNil:
    session.onSwitchProcessProc(recordingId)

proc activeStateVM*(session: SessionViewModel): StateVM =
  ## Convenience read accessor for the StateVM bound to the
  ## currently-active recording. Falls back to the legacy `stateVM`
  ## handle when no per-recording VM has been registered yet, so
  ## single-process call sites keep working unchanged.
  let id = session.activeProcessRecordingId.val
  if id.len > 0 and session.stateVMs.hasKey(id):
    return session.stateVMs[id]
  session.stateVM

proc attachOriginChainVM*(session: SessionViewModel;
                         originVM: OriginChainVM) =
  ## Bind the OriginChainVM whose `activeChain` powers the derived
  ## `crossProcessSpans` memo. The memo is rebuilt at attach time so
  ## the underlying `Signal[Option[OriginChain]]` registers as a
  ## reactive dependency (a Memo built before the OriginChainVM
  ## existed would have observed no signals and would not recompute
  ## when `activeChain` later changed).
  session.originChainVM = originVM
  session.crossProcessSpans =
    createMemo[seq[CrossProcessSpan]] proc(): seq[CrossProcessSpan] =
      let chain = originVM.activeChain.val
      if chain.isNone:
        return newSeq[CrossProcessSpan]()
      chain.get.crossProcessSpans
  # M29 §14.8 — install the chain-panel → SessionVM breadcrumb-chip
  # bridge so clicking a chip rotates the active recording (and the
  # `stateVM` alias + the host `ct/goto-ticks` bridge) atomically.
  # Preserve any bridge a caller installed explicitly first.
  if originVM.onSwitchProcessProc.isNil:
    originVM.onSwitchProcessProc = proc(recordingId: string) =
      session.onSwitchProcess(recordingId)

proc dispose*(session: SessionViewModel) =
  ## Tear down all reactive roots.  Call this when the replay session
  ## ends to free signal graph resources.
  ##
  ## Each ViewModel's dispose proc cleans up its own reactive root.
  ## The store's dispose is called last since VMs hold references to it.
  # Dispose per-recording StateVMs first. The legacy `stateVM` alias
  # always points at one of the entries in this table once
  # `setProcessTree` / `onSwitchProcess` has run; only fall back to
  # the alias when no per-recording VM has been registered.
  var aliasDisposed = false
  for id, vm in session.stateVMs.pairs:
    if vm.isNil:
      continue
    if vm == session.stateVM:
      aliasDisposed = true
    vm.dispose()
  if not session.stateVM.isNil and not aliasDisposed:
    session.stateVM.dispose()
  if not session.calltraceVM.isNil:
    session.calltraceVM.dispose()
  if not session.eventLogVM.isNil:
    session.eventLogVM.dispose()
  if not session.flowVM.isNil:
    session.flowVM.dispose()
  if not session.editorVM.isNil:
    session.editorVM.dispose()
  if not session.timelineVM.isNil:
    session.timelineVM.dispose()
  if not session.debugControlsVM.isNil:
    session.debugControlsVM.dispose()
  if not session.searchVM.isNil:
    session.searchVM.dispose()
  if not session.pointListVM.isNil:
    session.pointListVM.dispose()
  if not session.scratchpadVM.isNil:
    session.scratchpadVM.dispose()
  if not session.shellVM.isNil:
    session.shellVM.dispose()
  if not session.processTree.isNil:
    session.processTree.dispose()
  if not session.store.isNil:
    session.store.dispose()
  if not session.backend.isNil:
    session.backend.disconnect()
