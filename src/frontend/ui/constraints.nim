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
  ../[ types, communication ]

# `markStale` WAS in this list and was never applied — an import that read,
# for the whole life of the pane, exactly like the caller it was standing in
# for. `noteSourceEdited` replaces it because that is the proc this module
# actually calls; `markStale` is reached through it, inside the viewmodel,
# where the rule about which edits count can be driven by a headless lane.
from ../viewmodel/viewmodels/constraints_vm import
  ConstraintsVM, createConstraintsVM, setReport, setAbsence, noteSourceEdited
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_constraints_view import
    mountIsoNimConstraintsPanel

var constraintsVMInstance*: ConstraintsVM
var constraintsComponentRef: ConstraintsComponent
var isoNimConstraintsMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimConstraintsPanel*()

proc initConstraintsVM*() =
  ## The VM needs no store: a constraint report comes from `nargo info`, or
  ## from the counts the bundle carries, and from nowhere else. That is why
  ## there is no `initConstraintsVMWithStore` twin — a `ReplayDataStore`
  ## parameter would be a promise this pane does not keep.
  if constraintsVMInstance != nil:
    return
  constraintsVMInstance = createConstraintsVM()
  clog "ConstraintsVM: instance created"
  tryMountIsoNimConstraintsPanel()

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

when defined(js):
  proc tryMountIsoNimConstraintsPanel*() =
    ## Mount into `constraintsComponent-{id}`, retrying until GoldenLayout has
    ## created the host. Same shape and same 200-attempt cap as
    ## `trace_log.tryMountIsoNimTraceLogPanel`; see its comment for why the
    ## retry is needed at all.
    if constraintsVMInstance.isNil:
      return
    if constraintsComponentRef.isNil:
      return
    let componentId = constraintsComponentRef.id
    if isoNimConstraintsMountedIds.hasKey(componentId):
      return

    let key = cstring("constraintsComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimConstraintsMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimConstraintsPanel: not ready after 200 retries"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimConstraintsMountedIds[componentId] = true
      try:
        mountIsoNimConstraintsPanel(container, constraintsVMInstance)
      except:
        cerror "tryMountIsoNimConstraintsPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

    doMount()
else:
  proc tryMountIsoNimConstraintsPanel*() =
    discard

method register*(self: ConstraintsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initConstraintsVM()
  if constraintsComponentRef.isNil:
    constraintsComponentRef = self
    tryMountIsoNimConstraintsPanel()

method unregister*(self: ConstraintsComponent) =
  ## Release the module-global slot and the mounted marker before the base
  ## implementation drops the event-bus subscriptions.
  ##
  ## WITHOUT THIS THE PANE COMES BACK BLANK, PERMANENTLY. Both globals above
  ## are write-once — `register` assigns the ref only `if isNil`, and
  ## `tryMountIsoNimConstraintsPanel` returns early at its
  ## `isoNimConstraintsMountedIds.hasKey` guard. Neither is ever cleared, so
  ## after a teardown:
  ##
  ##   * `constraintsComponentRef` still points at a component whose DOM
  ##     container no longer exists, and
  ##   * the mounted marker for its id survives into the next component that
  ##     is given the same id, whose mount then returns at the guard and draws
  ##     nothing.
  ##
  ## `ui/session_switch.nim` unregisters EVERY component of the closing
  ## session, and `ui/layout.nim` unregisters a closed panel, so this is an
  ## ordinary transition rather than an exotic one — and the failure is silent,
  ## because a pane that returns early at a guard looks exactly like a pane
  ## with nothing to show.
  ##
  ## The VM is deliberately NOT reset. `constraintsVMInstance` is a singleton
  ## by design (`initConstraintsVM` returns early when it exists), and the
  ## report it holds describes a project, not a panel — dropping it would make
  ## closing and reopening the pane lose counts that are still true.
  ##
  ## Modelled on `ui/scratchpad.nim`, which is the only pane that had this.
  if constraintsComponentRef == self:
    constraintsComponentRef = nil
  discard jsDelete(isoNimConstraintsMountedIds[self.id])
  procCall unregister(Component(self))

proc registerConstraintsComponent*(component: ConstraintsComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
