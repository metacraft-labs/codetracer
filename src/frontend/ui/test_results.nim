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
  session_viewmodels,
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
  ## The SHOWN tab's Test Results ViewModel. Each tab has its own
  ## (`session_viewmodels.testResultsVMOf`: a tab is an independent session,
  ## `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rule 1, and keeps
  ## what it showed while another tab is shown, rule 6); this names the one
  ## the window's hosts write into now, and is moved by `bindTestResultsVM` on
  ## every tab switch. Each tab's pane renders its own tab's
  ## (`testResultsVMForHost`).
var hostInstallers: seq[proc(vm: TestResultsVM)]
  ## What a host installs on EVERY tab's ViewModel (`onEachTestResultsVM`).
var installedVMs: seq[TestResultsVM]
  ## The ViewModels the installers have already run on.

proc applyHostInstallers(vm: TestResultsVM) =
  if vm.isNil or vm in installedVMs:
    return
  installedVMs.add vm
  for install in hostInstallers:
    install(vm)

proc bindTestResultsVM*(vm: TestResultsVM) =
  ## Make `vm` — the shown tab's — the one the window's hosts write into.
  if vm.isNil or vm == testResultsVMInstance:
    return
  testResultsVMInstance = vm
  applyHostInstallers(vm)

proc onEachTestResultsVM*(install: proc(vm: TestResultsVM)) =
  ## Run `install` on every tab's Test Results ViewModel — those that exist
  ## and each one created from now on: what a host installs (the runner, the
  ## row actions) belongs to the window, not to one tab's project.
  hostInstallers.add install
  for vm in installedVMs:
    install(vm)
  if not testResultsVMInstance.isNil and testResultsVMInstance notin installedVMs:
    applyHostInstallers(testResultsVMInstance)

proc forgetTestResultsVM*(vm: TestResultsVM) =
  ## Drop `vm` — a closed tab's — from the ViewModels the installers have run
  ## on, so the window keeps no reference to it and a host installing later
  ## (`onEachTestResultsVM`) does not write into a disposed ViewModel.
  if vm.isNil:
    return
  var kept: seq[TestResultsVM] = @[]
  for installed in installedVMs:
    if installed != vm:
      kept.add installed
  installedVMs = kept
  if testResultsVMInstance == vm:
    testResultsVMInstance = nil

proc initTestResultsVM*() =
  ## Bind the shown tab's ViewModel, created on first use. A page with no tab
  ## yet keeps one window-wide instance, as before tabs owned theirs.
  if data.sessions.len == 0:
    if testResultsVMInstance.isNil:
      testResultsVMInstance = createTestResultsVM()
      applyHostInstallers(testResultsVMInstance)
      clog "TestResultsVM: instance created"
    return
  bindTestResultsVM(testResultsVMOf(data.activeSession))

proc testResultsVMForHost(host: dom_api.Element): TestResultsVM =
  ## The ViewModel of the tab whose container holds `host` — so tab 1's pane
  ## shows tab 1's catalog and run whichever tab is on screen. A host outside
  ## every tab shows the shown tab's.
  let tab = tabOfIsoNimPaneHost(host)
  if tab >= 0 and tab < data.sessions.len:
    result = testResultsVMOf(data.sessions[tab])
    applyHostInstallers(result)
  else:
    initTestResultsVM()
    result = testResultsVMInstance

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.TestResults,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    renderTestResultsPanel[WebRenderer, dom_api.Element](r,
      testResultsVMForHost(host)))

method register*(self: TestResultsComponent, api: MediatorWithSubscribers) =
  self.api = api
  initTestResultsVM()
