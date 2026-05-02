## viewmodels/calltrace_editor_vm.nim
##
## CalltraceEditorVM — ViewModel for the Calltrace Editor placeholder panel.
##
## The Calltrace Editor is a GoldenLayout panel opened by
## ``frontend/renderer.nim::openCallViewer`` to host nested editor
## instances spawned from inside the Calltrace panel.  In the legacy
## Karax world the panel hosted per-call ``EditorViewComponent``
## children, but in the current runtime it ships as a placeholder: the
## ``method render`` on ``CalltraceEditorComponent`` emits an empty
## ``<div class="component-container calltrace-editor">`` and the
## per-call helpers (``openNewCall`` / ``callView``) are not invoked
## from anywhere — they were dead-or-rarely-used helpers preserved
## across earlier refactors (the legacy ``method render`` did not call
## them either).  See section 5.4 of the IsoNim migration handoff for
## context (``calltrace_editor: inline editor inside calltrace``).
##
## To keep parity with the legacy behaviour the IsoNim view renders
## the same empty container.  The VM therefore exposes a stable
## ``mounted`` signal (set true after the view materialises so headless
## tests can assert lifecycle) and reserves space for future per-call
## editor state without committing to a particular shape now.
##
## The VM intentionally has a small surface — adding signals or
## actions later (e.g. when nested editors are revived) is an additive
## change that does not break the current view.
##
## Usage::
##
##   let vm = createCalltraceEditorVM(store)
##   vm.markMounted()
##   echo vm.mounted.val
##
## The store reference is kept so future actions can dispatch via
## ``store.backend.send`` without re-wiring the constructor.

import isonim/core/[signals, owner]
import isonim/viewmodel

import ../store/replay_data_store

type
  CalltraceEditorVM* = ref object of ViewModel
    ## Reactive state for the Calltrace Editor placeholder panel.
    ##
    ## Mutable signals:
    ##   mounted              — flips to true once the IsoNim view has
    ##                          materialised the container.  Headless
    ##                          tests use it as a lifecycle assertion;
    ##                          the production view sets it inside the
    ##                          mount helper so reactive consumers (none
    ##                          today, but reserved for future
    ##                          features) can react.
    ##
    ## The store reference is retained so future actions (e.g. opening
    ## a nested editor when the panel revives the legacy ``openNewCall``
    ## flow) can reach the backend via ``store.backend.send`` without
    ## changing the VM constructor signature.
    store*: ReplayDataStore

    # -- Mutable state --
    mounted*: Signal[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc markMounted*(vm: CalltraceEditorVM) =
  ## Flip ``mounted`` to true.  The view's mount helper calls this
  ## once the panel container has been appended to the live DOM so
  ## downstream effects (none today, future-proofing) can react.
  vm.mounted.val = true

proc markUnmounted*(vm: CalltraceEditorVM) =
  ## Flip ``mounted`` back to false.  Used when the panel is torn
  ## down and re-mounted (e.g. after a session swap that re-creates
  ## the underlying ``ReplayDataStore``).
  vm.mounted.val = false

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createCalltraceEditorVM*(store: ReplayDataStore): CalltraceEditorVM =
  ## Create a CalltraceEditorVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its inert default so the
  ## view renders the bare placeholder shell on first paint.
  withViewModel proc(dispose: proc()): CalltraceEditorVM =
    CalltraceEditorVM(
      store: store,
      mounted: createSignal(false),
      disposeProc: dispose,
    )
