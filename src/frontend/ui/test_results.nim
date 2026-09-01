## Test Results panel (`Content.TestResults`) — the legacy-side bridge.
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

from ../viewmodel/viewmodels/test_results_vm import
  TestResultsVM, createTestResultsVM, setCatalog, setRunAbsence, clearRun,
  ingestEvent, applyRunText
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_test_results_view import
    mountIsoNimTestResultsPanel

var testResultsVMInstance*: TestResultsVM
var testResultsComponentRef: TestResultsComponent
var isoNimTestResultsMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimTestResultsPanel*()

proc initTestResultsVM*() =
  ## The VM needs no store: its inputs arrive from a host as a catalog and a
  ## run, never from the replay data store. That is why there is no
  ## `initTestResultsVMWithStore` twin — a `ReplayDataStore` parameter would
  ## be a promise this pane does not keep.
  if testResultsVMInstance != nil:
    return
  testResultsVMInstance = createTestResultsVM()
  clog "TestResultsVM: instance created"
  tryMountIsoNimTestResultsPanel()

when defined(js):
  proc tryMountIsoNimTestResultsPanel*() =
    ## Mount into `testResultsComponent-{id}`, retrying until GoldenLayout has
    ## created the host. Same shape and same 200-attempt cap as
    ## `trace_log.tryMountIsoNimTraceLogPanel`; see its comment for why the
    ## retry is needed at all.
    if testResultsVMInstance.isNil:
      return
    if testResultsComponentRef.isNil:
      return
    let componentId = testResultsComponentRef.id
    if isoNimTestResultsMountedIds.hasKey(componentId):
      return

    let key = cstring("testResultsComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimTestResultsMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimTestResultsPanel: not ready after 200 retries"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimTestResultsMountedIds[componentId] = true
      try:
        mountIsoNimTestResultsPanel(container, testResultsVMInstance)
      except:
        cerror "tryMountIsoNimTestResultsPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

    doMount()
else:
  proc tryMountIsoNimTestResultsPanel*() =
    discard

method register*(self: TestResultsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initTestResultsVM()
  if testResultsComponentRef.isNil:
    testResultsComponentRef = self
    tryMountIsoNimTestResultsPanel()

proc registerTestResultsComponent*(component: TestResultsComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
