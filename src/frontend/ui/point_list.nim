## The desktop's Point List pane (`Content.PointList`): breakpoints and
## tracepoints, drawn by the IsoNim view every front-end shares
## (`viewmodel/views/isonim_point_list_view`) over the ViewModel session's
## `PointListVM` — the SAME `store.pointList.rows` the native front-ends
## read, fed by one decoder (`ReplayDataStore.applyVerifiedBreakpoints` for
## breakpoints the engine verified, `applyTracepointResults` for sweeps,
## `point_collection_source` for project definitions).
##
## PLAT-40. Until 2026-09-23 `utils.makeComponent`'s arm for this pane was
## commented out and its `else` raised, so the pane could not be constructed
## at all, and its menu entry was commented out so nothing reached the raise.
## The component is stateless, like `ConstraintsComponent`: everything it
## draws lives in the ViewModel. It exists so the pane is constructed,
## registered and mounted the way every other pane is.

import
  ui_imports,
  ../[ types, communication ]

from ../viewmodel/viewmodels/point_list_vm import PointListVM
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_point_list_view import mountIsoNimPointList

var pointListVMInstance*: PointListVM
  ## The ViewModel session's `PointListVM`, set by the renderer when the
  ## session exists (`setPointListVM`). Nil before that; the mount waits.
var pointListComponentRef: PointListComponent
var isoNimPointListMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimPointListPanel*()

proc setPointListVM*(vm: PointListVM) =
  ## Hand the pane the session's point list, and mount if the pane is open.
  pointListVMInstance = vm
  tryMountIsoNimPointListPanel()

when defined(js):
  proc tryMountIsoNimPointListPanel*() =
    ## Mount into `pointListComponent-{id}` once both the VM and the
    ## GoldenLayout container exist — `ui/layout.nim`'s direct-mount dispatch
    ## calls this when it has just built the container.
    if pointListVMInstance.isNil or pointListComponentRef.isNil:
      return
    let componentId = pointListComponentRef.id
    if isoNimPointListMountedIds.hasKey(componentId):
      return
    let key = cstring("pointListComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimPointListMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cwarn "tryMountIsoNimPointListPanel: container not ready after 200 " &
            "retries; this poll is abandoned and the layout's mount retries"
          return
        discard setTimeout(proc() = doMount(), 10)
        return
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)
      isoNimPointListMountedIds[componentId] = true
      try:
        mountIsoNimPointList(container, pointListVMInstance)
      except:
        cerror "tryMountIsoNimPointListPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()
    doMount()
else:
  proc tryMountIsoNimPointListPanel*() =
    discard

method register*(self: PointListComponent, api: MediatorWithSubscribers) =
  self.api = api
  if pointListComponentRef.isNil:
    pointListComponentRef = self
    tryMountIsoNimPointListPanel()

method unregister*(self: PointListComponent) =
  ## Release the module slot and the mounted marker, for `ui/constraints`'
  ## reason: both are write-once, and a pane reopened after a teardown would
  ## otherwise return early at the guard and draw nothing. The VM is the
  ## session's and is not reset.
  if pointListComponentRef == self:
    pointListComponentRef = nil
  discard jsDelete(isoNimPointListMountedIds[self.id])
  procCall unregister(Component(self))

proc registerPointListComponent*(component: PointListComponent,
                                 api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
