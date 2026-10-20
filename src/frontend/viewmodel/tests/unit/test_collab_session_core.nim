## Unit tests for M2 collaborative ViewModel session core and projection.
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_session_core.nim

import std/[asyncdispatch, json, options, unittest]

import isonim/core/signals
import isonim/viewmodel

import ../../backend/mock_backend
import ../../collab/[reducer, runtime_role, session_core, types]
import ../../session_vm
import ../../store/[replay_data_store, types]
import ../../viewmodels/[calltrace_vm, state_vm]

proc drain() =
  try:
    poll(0)
  except ValueError:
    discard

proc makeSession(runtimeRole = vrrStandalone):
    tuple[session: SessionViewModel, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService(), runtimeRole)
  session.initializePanelViewModels()
  drain()
  mock.clearReceivedCommands()
  (session, mock)

proc makeStandaloneStore(): tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  drain()
  mock.clearReceivedCommands()
  (store, mock)

suite "collaborative ViewModel M2 session core":

  test "test_collab_calltrace_select_action_dispatches_viewop":
    let (session, mock) = makeSession()
    session.calltraceVM.selectEntry(some(42'i64))

    check session.calltraceVM.selectedEntry.val == some(42'i64)
    check session.collabCore.localOperationLog.len == 1
    let op = session.collabCore.localOperationLog[^1]
    check op.kind == vokSetCalltraceSelection
    check op.targetPath == "calltrace.selectedEntry"
    check op.payload["entryId"].getStr == "42"
    check session.collabCore.document.state.calltrace.selectedEntry.value == "42"
    check session.collabCore.document.appliedOpIds.len == 1
    check mock.receivedCommands.len == 0
    session.dispose()

  test "test_collab_state_watch_actions_project_to_signals":
    let (session, _) = makeSession()

    session.stateVM.addWatch("counter + 1")
    check session.stateVM.watchExpressions.val == @["counter + 1"]
    check session.collabCore.document.state.statePane.visibleWatches.len == 1

    session.stateVM.removeWatch("counter + 1")
    check session.stateVM.watchExpressions.val.len == 0
    check session.collabCore.document.state.statePane.visibleWatches.len == 0
    check session.collabCore.localOperationLog.len == 2
    check session.collabCore.localOperationLog[0].kind == vokAddWatch
    check session.collabCore.localOperationLog[1].kind == vokRemoveWatch
    session.dispose()

  test "test_collab_collaborator_role_does_not_send_backend_autoload":
    let (session, mock) = makeSession(vrrCollaborator)

    session.calltraceVM.setViewport(session.calltraceVM.viewport.val.withRows(25))
    session.calltraceVM.setViewport(session.calltraceVM.viewport.val.scrolledTo(10))
    var dbg = session.store.debugger.val
    dbg.rrTicks = 99'u64
    session.store.debugger.val = dbg
    session.stateVM.addWatch("x")
    drain()

    check mock.findCommand("ct/load-calltrace-section").isNone
    check mock.findCommand("ct/load-locals").isNone
    check session.calltraceVM.runtimeRole == vrrCollaborator
    check session.stateVM.runtimeRole == vrrCollaborator
    session.dispose()

  test "test_collab_standalone_mode_preserves_existing_actions":
    let (store, mock) = makeStandaloneStore()
    let calltrace = createCalltraceVM(store)
    let state = createStateVM(store)
    drain()
    mock.clearReceivedCommands()

    calltrace.selectEntry(some(7'i64))
    state.addWatch("legacyValue")
    state.selectTab(stWatches)
    drain()

    check calltrace.selectedEntry.val == some(7'i64)
    check state.watchExpressions.val == @["legacyValue"]
    check state.activeTab.val == stWatches
    check mock.findCommand("ct/load-locals").isSome
    calltrace.dispose()
    state.dispose()
    store.dispose()

  test "test_collab_local_mode_maintains_join_snapshot":
    let (session, _) = makeSession()

    session.calltraceVM.selectEntry(some(9'i64))
    session.stateVM.selectTab(stWatches)
    session.stateVM.toggleExpand("root.child")
    session.stateVM.addWatch("root.child")

    let snap = session.collabCore.joinSnapshot()
    check snap.documentRevision == 4'u64
    check snap.appliedOpIds.len == 4
    check snap.state.calltrace.selectedEntry.value == "9"
    check snap.state.statePane.activeTab.value == "stWatches"
    check "root.child" in visibleExpansionIds(snap.state.statePane.expandedPaths)
    check snap.state.statePane.visibleWatches.len == 1
    check snap.state.statePane.visibleWatches[0].expression == "root.child"
    check snap.state.layout.len == 0
    check snap.state.authority.principalId == session.collabCore.localPrincipalId
    check snap.state.authority.backendOwnerId == session.collabCore.localPrincipalId
    session.dispose()

  test "test_collab_local_mode_starts_no_peer_services":
    let (session, _) = makeSession()

    check not session.collabCore.collaborationEnabled
    check not session.collabCore.peerTransportStarted
    check not session.collabCore.remoteAwarenessStarted
    check not session.collabCore.remoteGossipStarted
    check not session.collabCore.peerServicesStarted
    session.dispose()

  test "test_collab_local_mode_action_emits_local_only_viewop":
    let (session, mock) = makeSession()

    session.stateVM.selectPath("frame.local")

    check session.stateVM.selectedPath.val == "frame.local"
    check session.collabCore.dispatchLog.len == 1
    check session.collabCore.dispatchLog[^1].op.kind == vokSetRegister
    check session.collabCore.dispatchLog[^1].op.targetPath == "statePane.selectedPath"
    check session.collabCore.dispatchLog[^1].localOnly
    check not session.collabCore.dispatchLog[^1].publishedToPeer
    check mock.receivedCommands.len == 0
    session.dispose()

  test "test_collab_peer_selection_is_not_taken_back_by_a_followed_call":
    # A front end whose selection follows a call (`selectCall`: the
    # current-call mark, a row click) re-derives the row from that call on
    # every section load. When a peer then selects another row, the local
    # call must be dropped: otherwise the next local section load (a
    # scroll, a collapse) republishes the local row and silently takes the
    # shared selection back from the peer.
    let (session, _) = makeSession()
    let vm = session.calltraceVM
    proc keyed(index: int64; key: string): CallLine =
      CallLine(index: index, callKey: key, name: "call" & key)
    let section = @[keyed(0, "0"), keyed(1, "1"), keyed(2, "2")]
    session.store.updateCalltraceSection(section, 0, 3)
    drain()

    vm.selectCall("1")
    check vm.selectedEntry.val == some(1'i64)
    check vm.selectedCallKey.val == "1"

    let core = session.collabCore
    var op = core.nextLocalViewOp(vokSetCalltraceSelection,
      "calltrace.selectedEntry", %*{"entryId": "2"})
    # Another replica of the session (the same principal, so it holds the
    # capability to select), whose op arrives as a remote one.
    op.actorId = "peer-actor"
    op.replicaId = "peer-replica"
    op.opId = "peer-actor:1"
    check core.applyRemoteViewOp(op).status != asRejected
    check vm.selectedEntry.val == some(2'i64)
    check vm.selectedCallKey.val == ""

    let publishedBefore = core.localOperationLog.len
    # A later section (here one more row loaded below) re-runs the follow.
    session.store.updateCalltraceSection(section & @[keyed(3, "3")], 0, 4)
    drain()
    check vm.selectedEntry.val == some(2'i64)
    check core.document.state.calltrace.selectedEntry.value == "2"
    check core.localOperationLog.len == publishedBefore
    session.dispose()
