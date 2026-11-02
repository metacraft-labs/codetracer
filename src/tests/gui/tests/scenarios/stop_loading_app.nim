## stop_loading_app.nim — an AppViewModel wired the way a product session is.
##
## The per-stop loads (the locals, the flow window, the low-level code) are
## issued by the SDK's `StopLoader`, which `DebuggerSession.markReady`
## attaches to every real session: it claims the locals before the panels
## exist, builds them, and follows the stop. A bare `createAppViewModel` has
## no loader, so a scenario built on it never sees a `ct/load-flow` and
## asserts a session no front-end runs.
##
## This helper performs `markReady`'s steps on an app over the caller's
## backend, so the scenario suites drive the same per-stop senders the
## desktop, the terminal and GPUI do. The loaders are held here for the
## process's life: a scenario's reactive root owns the effects, and the
## loader object must outlive the test body's locals.

import backend/backend_service
import app/app_vm
import session_vm
import store/replay_data_store
import sdk/stop_loader

var heldLoaders: seq[StopLoader]

proc createStopLoadingApp*(backend: BackendService): AppViewModel =
  ## An app whose session loads per stop, as `DebuggerSession.markReady`
  ## sets one up.
  result = createAppViewModel(backend, initializePanels = false)
  result.session.store.claimLocalsLoading()
  result.session.initializePanelViewModels()
  let loader = createStopLoader(result.session)
  loader.follow()
  heldLoaders.add loader
