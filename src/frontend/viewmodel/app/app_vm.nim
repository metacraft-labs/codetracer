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

proc createAppViewModel*(backend: BackendService): AppViewModel =
  ## Create the full app-level ViewModel graph over `backend`.
  let session = createSessionVM(backend)
  session.initializePanelViewModels()
  AppViewModel(session: session)

proc dispose*(app: AppViewModel) =
  ## Dispose the owned session graph and disconnect its backend.
  if app.isNil:
    return
  if not app.session.isNil:
    app.session.dispose()
