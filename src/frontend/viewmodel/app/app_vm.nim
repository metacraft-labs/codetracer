## AppViewModel — native-compatible application-level ViewModel owner.
##
## `SessionViewModel` deliberately has a passive constructor so production
## startup can create the shared store before panel middleware and DOM mounts
## exist. Tests and non-DOM app hosts still need a single object that mirrors
## the real app's ViewModel ownership. This module provides that owner without
## depending on the JS-only renderer or legacy UI modules.

import ../backend/backend_service
import ../session_vm

type
  AppViewModel* = ref object
    ## Top-level headless app ViewModel.
    ##
    ## Owns one complete debugging session ViewModel graph: shared store plus
    ## the standard panel VMs. It intentionally does not mount IsoNim views;
    ## rendering tests can create views from the panel VMs they need.
    session*: SessionViewModel

proc createAppViewModel*(backend: BackendService;
                         initializePanels: bool = true): AppViewModel =
  ## Create the full app-level ViewModel graph over `backend`.
  ##
  ## `initializePanels = false` builds the graph but leaves the panel VMs
  ## inert, which is what `sdk.DebuggerSession` needs: the Embed SDK's
  ## lifecycle is "create, launch a trace, dispose"
  ## (CodeTracer-Embed-SDK.md §3.1), and *create* must send nothing — a
  ## session constructed before its trace is chosen would otherwise fire
  ## `ct/load-locals` and `ct/load-calltrace-section` at a backend that has no
  ## trace open. The session calls `initializePanelViewModels` itself once the
  ## launch succeeds.
  ##
  ## The default stays `true` so the 93 call sites that do not pass it keep
  ## the behaviour they were written against — 94 `createAppViewModel(`
  ## expressions outside this module, all but `sdk/debugger_session.nim`'s.
  ## Flipping the default would be a 93-file change to the desktop app and
  ## its scenario suites.
  let session = createSessionVM(backend)
  if initializePanels:
    session.initializePanelViewModels()
  AppViewModel(session: session)

proc dispose*(app: AppViewModel; disconnectBackend: bool = true) =
  ## Dispose the owned session graph and, unless told otherwise, disconnect
  ## its backend.
  ##
  ## The flag is forwarded rather than absorbed: `sdk.DebuggerSession.dispose`
  ## takes the same one and calls this proc, so a `false` that stopped here
  ## would leave the promise "the host owns the transport" unkept two layers
  ## down. See the note on `session_vm.dispose`.
  if app.isNil:
    return
  if not app.session.isNil:
    app.session.dispose(disconnectBackend = disconnectBackend)
