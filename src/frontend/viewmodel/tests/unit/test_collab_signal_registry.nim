## Unit tests for the M0 collaborative ViewModel signal registry.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_signal_registry.nim

import std/[sequtils, unittest]

import ../../collab/signal_registry
import ../../collab/runtime_role

suite "collaborative signal registry":

  test "test_collab_signal_registry_covers_session_vm":
    let inventory = discoverViewModelFields()
    let registry = collabSignalRegistry()
    let validation = validateRegistry(inventory, registry)

    check inventory.anyIt(it.fieldPath == "ReplayDataStore.session")
    check inventory.anyIt(it.fieldPath == "CalltraceStore.lines")
    check inventory.anyIt(it.fieldPath == "CalltraceVM.selectedEntry")
    check inventory.anyIt(it.fieldPath == "StateVM.watchExpressions")
    check inventory.anyIt(it.fieldPath == "EditorVM.activeTabIndex")

    check registry.anyIt(it.fieldPath == "CalltraceVM.selectedEntry" and
      it.syncClass == vscSharedSessionViewState and it.requiresStableId)
    check registry.anyIt(it.fieldPath == "ReplayDataStore.debugger" and
      it.syncClass == vscBackendAuthoritative)
    check registry.anyIt(it.fieldPath == "CalltraceVM.viewportHeight" and
      it.syncClass == vscRendererLocal)
    check registry.anyIt(it.fieldPath == "FlowVM.hoveredStep" and
      it.syncClass == vscPresenceAwareness)
    check registry.anyIt(it.fieldPath == "CalltraceVM.visibleLines" and
      it.syncClass == vscDerivedNonSignal)

    if not validation.isValid:
      checkpoint validation.formatValidation
    check validation.isValid()

    let stableIdBlocked = stableIdBlockedFields(registry)
    check stableIdBlocked.anyIt(it.fieldPath == "CalltraceVM.selectedEntry")
    check stableIdBlocked.anyIt(it.fieldPath == "EventLogVM.selectedRow")
    check stableIdBlocked.anyIt(it.fieldPath == "EditorVM.activeTabIndex")

    check ownsBackend(vrrStandalone)
    check ownsBackend(vrrBackendOwner)
    check not ownsBackend(vrrCollaborator)

  test "test_collab_signal_registry_rejects_unclassified_signal":
    var inventory = discoverViewModelFields()
    inventory.add ViewModelField(
      owner: "InjectedVM",
      field: "newMutableSignal",
      kind: vfkSignal,
      typeExpr: "Signal[int]",
      sourceFile: "test-only",
      line: 1,
    )

    let validation = validateRegistry(inventory, collabSignalRegistry())
    check not validation.isValid()
    check validation.missing.anyIt(it.fieldPath == "InjectedVM.newMutableSignal")

  test "test_collab_renderer_local_fields_are_not_published":
    let registry = collabSignalRegistry()
    let rendererLocal = registry.filterIt(it.syncClass == vscRendererLocal)
    check rendererLocal.len > 0
    check rendererLocal.anyIt(it.fieldPath == "CalltraceVM.viewportHeight")
    check rendererLocal.anyIt(it.fieldPath == "EditorVM.scrollTop")
    check rendererLocal.allIt(not it.canPublishAsViewStateOperation)

    let shared = registry.filterIt(it.syncClass == vscSharedSessionViewState)
    check shared.len > 0
    check shared.allIt(it.canPublishAsViewStateOperation)
