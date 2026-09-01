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

from ../viewmodel/viewmodels/constraints_vm import
  ConstraintsVM, createConstraintsVM, setReport, setAbsence, markStale
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

proc registerConstraintsComponent*(component: ConstraintsComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
