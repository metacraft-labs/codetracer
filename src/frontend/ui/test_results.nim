## NOT-A-TEST-LANE-FILE: this is the Test Results PANE (`Content.TestResults`)
## — production frontend code named after the test results it displays, which
## is why its basename matches the guard's `test_*` name arm. It imports no
## `unittest` and declares no `suite`/`test` block. It is not dark: it is
## imported by `src/frontend/ui_js.nim`, so the `renderer-web` and
## `renderer-electron` lanes compile-check it on both targets, and the VM it
## owns is asserted by
## `src/frontend/viewmodel/tests/unit/test_ns9_panes_vm.nim` (the `vm-unit` /
## `vm-unit-js` lanes).

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

from isonim/web/dom_api import nil
import isonim/web/web_renderer
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel
from ../viewmodel/viewmodels/test_results_vm import
  TestResultsVM, createTestResultsVM, setCatalog, setRunAbsence, clearRun,
  ingestEvent, applyRunText
import ../viewmodel/views/isonim_test_results_view

var testResultsVMInstance*: TestResultsVM
  ## The pane's ViewModel: one per window, made on first use.

proc initTestResultsVM*() =
  if testResultsVMInstance != nil:
    return
  testResultsVMInstance = createTestResultsVM()
  clog "TestResultsVM: instance created"

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.TestResults,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    initTestResultsVM()
    renderTestResultsPanel[WebRenderer, dom_api.Element](r,
      testResultsVMInstance))

method register*(self: TestResultsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initTestResultsVM()
