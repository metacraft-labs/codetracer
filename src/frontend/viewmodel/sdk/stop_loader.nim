## sdk/stop_loader.nim
##
## `StopLoader` — what a front-end loads when the debugger stops, decided once,
## in the SDK (Shared-DOM-Front-Ends.md D1; Headless-SDK-Front-Ends HSF-S1).
##
## Before it, each front-end decided for itself. The web's per-stop
## `ct/load-locals` came from `StateVM`'s effect and its answer was read by the
## legacy `StateComponent`, outside the ViewModel layer; the terminal and GPUI
## switched that effect off (`localsLoadedByHost`) and sent their own blocking
## request from `native_host.loadStopPanes`, with a second decoder. This module
## is the one sender and the one place an answer is applied, over the injected
## `BackendService`, so it runs unchanged on every transport.
##
## WHAT IS LOADED PER STOP, BY PANE (`StopPane`):
##
## | Pane                  | Request                          | Applied by |
## | --------------------- | -------------------------------- | ---------- |
## | `spLocals`            | `ct/load-locals`, the GUI's budgets (`localsLoadArgs`) and the state pane's watch list | `ReplayDataStore.applyLocalsResponse`, against the stop it was SENT at (PLAT-29), and `StateVM.updateOriginSummaries` |
## | `spCallStackFallback` | `stackTrace`, only when the recording has no call trace | `CalltraceVM.fallbackStack` (PLAT-47) |
## | `spDiffFlow`          | `ct/load-flow` with `flowMode: diff`, ONCE per session, when the session has a diff (`FlowVM.diffSession`) | `FlowVM.applyDiffFlowUpdate` |
##
## The locals are the Electron GUI's behaviour, which is the reference
## (SDF-AREQ7): one request per stop identity and watch list, at 3000/50/7.
## The call-stack fallback has NO GUI counterpart — the GUI sends no
## `stackTrace` — and is a native-front-end feature (PLAT-47); a host that does
## not show it simply does not open that pane. The other per-stop loads
## (call-trace window, flow) are still issued by their ViewModels' own effects;
## the call trace's moves here with the viewport contract (HSF-V1).
##
## A pane that is not open is not loaded (`setPaneOpen`). A load is issued once
## per stop: a second `loadStop` at the same stop and watch list sends nothing,
## unless the previous attempt failed (UI-Data-Loading-Guidelines Pattern 5).
##
## TWO WAYS TO DRIVE IT. `follow` installs an effect that loads on every stop
## and watch-list change — what a reactive host wants (the SDK default, see
## `DebuggerSession`). A host with its own refresh loop (the terminal and GPUI,
## whose loop decides when a stop has settled) calls `loadStop` instead, and on
## a native transport drains the platform callbacks after it; see
## `native_host.loadStopPanes`.
##
## Works on both the C and JS backends.

import std/[json, strutils]

import isonim/core/[signals, computation, owner, graph, batch, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../collab/runtime_role
import ../session_vm
import ../store/[replay_data_store, types, stop_timeline, locals_answer]
import ../viewmodels/[state_vm, calltrace_vm, flow_vm]
import ../../../common/flow_mode_wire   # `FlowModeWireDiff`

type
  StopPane* = enum
    ## A consumer of per-stop data, as far as loading is concerned.
    spLocals
      ## The state pane and the editor's inline values: `ct/load-locals`.
    spCallStackFallback
      ## The call-trace pane's call STACK, shown when the recording has no
      ## call trace (PLAT-47). Native front-ends only.
    spDiffFlow
      ## The trace diff's flow, for a session started with a diff. Not a
      ## per-stop load: the diff flow covers the recording's changed lines,
      ## so it is asked for once, whatever the stop. Open on every host; it
      ## sends nothing unless `FlowVM.diffSession` is set.

  PaneLoadStatus* = enum
    plsNone       ## nothing issued for the current stop
    plsInFlight   ## issued, not answered
    plsApplied    ## answered and applied to the current stop
    plsDropped    ## answered after the debugger moved on; not applied
    plsFailed     ## the backend refused or the transport failed

  StopLoader* = ref object of ViewModel
    ## The per-stop loads of one session.
    session*: SessionViewModel
    openPanes*: Signal[set[StopPane]]
    status*: array[StopPane, Signal[PaneLoadStatus]]
      ## What happened to each pane's load for the stop it was last issued at.
    sentFor: array[StopPane, string]
      ## The key (stop identity and watch list) each pane's load was last
      ## issued for; "" when nothing is held.
    following: bool
    owner: OwnerBase
      ## The loader's reactive root, so `follow`'s effect is disposed with it.

const
  DefaultStopPanes* = {spLocals, spDiffFlow}
    ## What the Electron GUI loads: the locals on every stop, and a diff
    ## session's diff flow once.
  CallStackFallbackLevels* = 400
    ## Frames asked for by the call-stack fallback — the native hosts'
    ## `RecordingCalltraceLevels`.

proc claimLocalsLoading*(store: ReplayDataStore) =
  ## Make the stop loader the session's one `ct/load-locals` sender: `StateVM`'s
  ## own per-stop request stands down (`localsLoadedByHost`). Must run BEFORE
  ## the `StateVM` is constructed, because its effect sends on its first run.
  store.localsLoadedByHost = true

proc createStopLoader*(session: SessionViewModel;
                       panes: set[StopPane] = DefaultStopPanes): StopLoader =
  ## A loader over `session`, with `panes` open. Passive: it sends nothing
  ## until `loadStop` or `follow`.
  doAssert not session.isNil and not session.store.isNil,
    "StopLoader requires a SessionViewModel with a store"
  session.store.claimLocalsLoading()
  withViewModel proc(dispose: proc()): StopLoader =
    var status: array[StopPane, Signal[PaneLoadStatus]]
    for p in StopPane:
      status[p] = createSignal(plsNone)
    StopLoader(
      session: session,
      openPanes: createSignal(panes),
      status: status,
      owner: getOwner(),
      disposeProc: dispose,
    )

proc watchList(l: StopLoader): seq[string] =
  if l.session.stateVM.isNil: @[] else: l.session.stateVM.watchExpressions.val

proc stopKey(l: StopLoader; pane: StopPane): string =
  ## What makes two loads of `pane` the same request.
  let store = l.session.store
  result = stopIdentityOf(store.debugger.val)
  case pane
  of spLocals:
    result.add "\x02" & l.watchList().join("\x1f")
  of spCallStackFallback:
    # The fallback is a fact about the stop AND about whether the recording
    # gave a call trace: a section that arrives (or is cleared) at the same
    # stop changes what the pane must show.
    result.add "\x02" & $(store.calltrace.lines.val.len > 0)
  of spDiffFlow:
    # The same key at every stop: the diff flow is asked for once. A
    # session that is not a diff session holds no key, and asks nothing.
    let flow = l.session.flowVM
    result = if flow.isNil or not flow.diffSession.val: "" else: "diff"

proc mayLoad(l: StopLoader): bool =
  ## A collaboration follower renders the leader's answers and asks nothing.
  not l.session.isNil and not l.session.store.isNil and
    mayIssueBackendCommands(l.session.runtimeRole)

proc settle(l: StopLoader; pane: StopPane; key: string;
            outcome: PaneLoadStatus) =
  ## Record `outcome` for the load issued at `key`, unless a newer load of the
  ## same pane has been issued since — its status is the one that matters.
  if l.sentFor[pane] != key:
    return
  if outcome == plsFailed:
    l.sentFor[pane] = ""  # a later `loadStop` at this stop retries
  l.status[pane].val = outcome

proc loadLocals(l: StopLoader; key: string) =
  let store = l.session.store
  let ticks = store.debugger.val.rrTicks
  let args = store.localsLoadArgs(ticks, l.watchList())
  let requestedAt = store.stopStamp()
  let loader = l
  store.locals.loadingState.val = lsLoading
  onComplete(store.backend.send("ct/load-locals", args),
    onSuccess = proc(resp: JsonNode) =
      var answer =
        if responseSucceeded(resp): localsAnswerOf(responseBody(resp))
        else: LocalsAnswer()
      answer.requestedAt = requestedAt
      if not answer.ok:
        store.locals.loadingState.val = lsError
        loader.settle(spLocals, key, plsFailed)
        return
      store.locals.loadingState.val = lsIdle
      if not store.applyLocalsResponse(answer.rows, answer.requestedAt):
        loader.settle(spLocals, key, plsDropped)
        return
      store.locals.loadedForRRTicks.val = ticks
      if not loader.session.stateVM.isNil:
        loader.session.stateVM.updateOriginSummaries(answer.origins)
      loader.settle(spLocals, key, plsApplied),
    onError = proc(message: string) =
      store.locals.loadingState.val = lsError
      loader.settle(spLocals, key, plsFailed))

proc loadCallStackFallback(l: StopLoader; key: string) =
  let vm = l.session.calltraceVM
  if vm.isNil:
    l.settle(spCallStackFallback, key, plsApplied)
    return
  if l.session.store.calltrace.lines.val.len > 0:
    # A recording WITH a call trace pays nothing; a stale fallback is cleared.
    if vm.fallbackStack.val.len > 0:
      vm.fallbackStack.val = newSeq[string]()
    l.settle(spCallStackFallback, key, plsApplied)
    return
  let loader = l
  onComplete(l.session.store.backend.send("stackTrace", %*{
      "threadId": 1, "startFrame": 0, "levels": CallStackFallbackLevels}),
    onSuccess = proc(resp: JsonNode) =
      if not responseSucceeded(resp):
        vm.fallbackStack.val = newSeq[string]()
        loader.settle(spCallStackFallback, key, plsFailed)
        return
      var names: seq[string] = @[]
      for f in responseBody(resp){"stackFrames"}.getElems:
        names.add f{"name"}.getStr("")
      vm.fallbackStack.val = names
      loader.settle(spCallStackFallback, key, plsApplied),
    onError = proc(message: string) =
      vm.fallbackStack.val = newSeq[string]()
      loader.settle(spCallStackFallback, key, plsFailed))

proc loadDiffFlow(l: StopLoader; key: string) =
  ## The trace diff's flow: `ct/load-flow` with the `diff` query. The engine
  ## serves it from the diff index written at record time, so it names no
  ## position; `CtLoadFlowArguments` still requires a `location`, and an
  ## empty one is what the desktop's editor sent. The answer also arrives as
  ## a `ct/updated-flow` event, which `FlowVM`'s handler routes by its `mode`
  ## to the same applier.
  let vm = l.session.flowVM
  let loader = l
  vm.diffLoadingState.val = lsLoading
  onComplete(l.session.store.backend.send("ct/load-flow", %*{
      "flowMode": FlowModeWireDiff,
      "location": {"path": "", "line": 0, "rrTicks": 0, "callstackDepth": 0}}),
    onSuccess = proc(resp: JsonNode) =
      let body = responseBody(resp)
      if not responseSucceeded(resp) or not isDiffFlowUpdate(body):
        vm.diffLoadingState.val = lsError
        loader.settle(spDiffFlow, key, plsFailed)
        return
      vm.applyDiffFlowUpdate(body)
      loader.settle(spDiffFlow, key,
        if vm.diffLoadingState.val == lsIdle: plsApplied else: plsFailed),
    onError = proc(message: string) =
      vm.diffLoadingState.val = lsError
      loader.settle(spDiffFlow, key, plsFailed))

proc loadStop*(l: StopLoader) =
  ## Issue each open pane's load for the stop the store is at, once per stop.
  ## On a transport whose futures settle through the platform callback queue
  ## (std `asyncdispatch`), the answers are applied when that queue is
  ## drained (`drainPlatformCallbacks`).
  if l.isNil or not l.mayLoad():
    return
  let open = l.openPanes.val
  for pane in StopPane:
    if pane notin open:
      continue
    let key = l.stopKey(pane)
    if l.sentFor[pane] == key:
      continue
    l.sentFor[pane] = key
    l.status[pane].val = plsInFlight
    if key.len == 0:
      # Nothing to load for this pane in this session (`spDiffFlow` outside a
      # diff session).
      continue
    case pane
    of spLocals: l.loadLocals(key)
    of spCallStackFallback: l.loadCallStackFallback(key)
    of spDiffFlow: l.loadDiffFlow(key)

proc reload*(l: StopLoader; pane: StopPane) =
  ## Load `pane` for the current stop even if it was already loaded there —
  ## for a host that knows the answer may have changed without the stop
  ## changing. Does nothing for a pane that is not open.
  if l.isNil or pane notin l.openPanes.val:
    return
  l.sentFor[pane] = ""
  l.loadStop()

proc setPaneOpen*(l: StopLoader; pane: StopPane; open: bool) =
  ## Open or close `pane`. Opening it while following loads it for the
  ## current stop; closing it forgets what was loaded, so reopening at the
  ## same stop loads again.
  var panes = l.openPanes.val
  if open == (pane in panes):
    return
  if open: panes.incl pane else: panes.excl pane
  if not open:
    l.sentFor[pane] = ""
    l.status[pane].val = plsNone
  l.openPanes.val = panes

proc follow*(l: StopLoader) =
  ## Load on every stop, watch-list change and pane opening, from now on.
  ## Idempotent. The effect is owned by the loader's root, so `dispose` ends
  ## it.
  if l.isNil or l.following:
    return
  l.following = true
  let loader = l
  runWithOwner(l.owner, proc() =
    createEffect proc() =
      # The reads that subscribe: the stop, the watch list, the open panes
      # and, for the call-stack fallback, the call trace's presence.
      discard stopIdentityOf(loader.session.store.debugger.val)
      discard loader.watchList()
      if spCallStackFallback in loader.openPanes.val:
        discard loader.session.store.calltrace.lines.val.len > 0
      # A host may mark the session as a diff after it attached.
      if spDiffFlow in loader.openPanes.val and
         not loader.session.flowVM.isNil:
        discard loader.session.flowVM.diffSession.val
      untrack(proc() = loader.loadStop()))
