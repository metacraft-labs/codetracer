## Constraints panel (`Content.Constraints`) — the legacy-side bridge.
##
## There is no legacy Karax half to bridge FROM: this pane is new, and it was
## built the way the migrated ones ended up rather than the way they started.
## What this module is, then, is the GoldenLayout mount and the VM's owner —
## the same two jobs `ui/trace_log.nim` does after its Karax `method render`
## was dropped, minus the translation layer neither of us needs.
##
## The component exists at all because `Content` members are constructed
## through `utils.makeComponent`, registered in `data.ui.componentMapping`, and
## found by `ui/layout.nim`'s `genericUiComponent` registration by id. A pane
## that skipped that would not be a CodeTracer pane; it would be a div in a
## GoldenLayout container, which is what the web build had before NS9 and
## exactly what §3 says not to build.

import
  ui_imports,
  session_viewmodels,
  ../[ types, communication ]

# `markStale` WAS in this list and was never applied — an import that read,
# for the whole life of the pane, exactly like the caller it was standing in
# for. `noteSourceEdited` replaces it because that is the proc this module
# actually calls; `markStale` is reached through it, inside the viewmodel,
# where the rule about which edits count can be driven by a headless lane.
from ../viewmodel/viewmodels/constraints_vm import
  ConstraintsVM, createConstraintsVM, setReport, setAbsence, noteSourceEdited
from isonim/web/dom_api import nil
from ./pane_host_lookup import tabOfPaneHost
import isonim/web/web_renderer
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel
import ../viewmodel/views/isonim_constraints_view

var constraintsVMInstance*: ConstraintsVM
  ## The SHOWN tab's Constraints ViewModel. Each tab has its own
  ## (`session_viewmodels.constraintsVMOf`, as `ui/test_results.nim`'s); this
  ## names the one the window's hosts write into now, moved by
  ## `bindConstraintsVM` on every tab switch. Each tab's pane renders its own
  ## tab's (`constraintsVMForHost`).

proc bindConstraintsVM*(vm: ConstraintsVM) =
  ## Make `vm` — the shown tab's — the one the window's hosts write into.
  if not vm.isNil:
    constraintsVMInstance = vm

proc initConstraintsVM*() =
  ## Bind the shown tab's ViewModel, created on first use.
  ##
  ## The VM needs no store: a constraint report comes from `nargo info`, or
  ## from the counts the bundle carries, and from nowhere else. That is why
  ## there is no `initConstraintsVMWithStore` twin — a `ReplayDataStore`
  ## parameter would be a promise this pane does not keep.
  ##
  ## A page with no tab yet keeps one window-wide instance.
  if data.sessions.len == 0:
    if constraintsVMInstance.isNil:
      constraintsVMInstance = createConstraintsVM()
      clog "ConstraintsVM: instance created"
    return
  bindConstraintsVM(constraintsVMOf(data.activeSession))

proc constraintsVMForHost(host: dom_api.Element): ConstraintsVM =
  ## The ViewModel of the tab whose container holds `host`; a host outside
  ## every tab shows the shown tab's.
  let tab = tabOfPaneHost(host)
  if tab >= 0 and tab < data.sessions.len:
    constraintsVMOf(data.sessions[tab])
  else:
    initConstraintsVM()
    constraintsVMInstance

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.Constraints,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    renderConstraintsPanel[WebRenderer, dom_api.Element](r,
      constraintsVMForHost(host)))

proc noteEditorSourceChanged*(path: cstring) =
  ## A visitor edited `path`, so the counts on screen may no longer describe
  ## the program on screen.
  ##
  ## Installed into `ui/editor.editorSourceChangedHook` by `ui_js`, which is
  ## where every other cross-module editor hook is installed. Kept as a named
  ## proc here rather than written as a closure at the install site so that the
  ## call from the editor to this pane is a thing a reader (and the
  ## reachability guard) can SEE — an anonymous `proc` in a 400-line install
  ## block is how the previous version of this wiring managed to not exist for
  ## as long as it did.
  ##
  ## Silent when there is no VM. The pane is created lazily by
  ## `initConstraintsVM`, and it is not this hook's business to force it into
  ## existence: a project with no constraint report has no count to invalidate.
  if constraintsVMInstance.isNil:
    return
  constraintsVMInstance.noteSourceEdited($path)

method register*(self: ConstraintsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initConstraintsVM()
