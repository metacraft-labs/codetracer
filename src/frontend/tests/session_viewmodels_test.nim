## session_viewmodels_test.nim
##
## EACH WINDOW TAB OWNS ITS VIEWMODELS, AND EACH TAB'S PANES SHOW THEM.
##
## ## The defect this pins
##
## codetracer-pm issue `2026-10-21-a-second-replay-tab-shows-the-first-tabs-data-because-the-window-builds-one-session-viewmodel.md`:
## the renderer built ONE `SessionViewModel` per window (`ui_js.configureMiddleware`
## ran once, `middlewareConfigured`) over the DAP API of the tab active first,
## and the panel host rendered every tab's panes over that one window-global
## session (`panel_host.hostSession`). A second recording opened in a "+" tab
## showed the first recording's Call Trace and State. The rule is
## `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rules 1, 2 and 6 and
## `Refactoring-Plans/Shared-DOM-Front-Ends.md` D7 ("created by
## `initializePanelViewModels`, once per session").
##
## ## What is asserted
##
## Two tabs, each with its own session built the way
## `ui_js.configureSessionMiddleware` builds it (a `DebuggerSession` over
## `newDapBackendService` of THAT tab's `DapApi`, its panel ViewModels):
##
## * the two ViewModel sets and stores are distinct, and each tab's record
##   answers for its tab, its `DapApi` and its components, and a component
##   still being registered is keyed by the tab it goes into, not by tab 0's
##   key (`ui/session_viewmodels.nim`);
## * the panel host renders a host inside `#session-container-<n>` over tab
##   <n>'s session, whichever tab is shown; a host of a tab with no session
##   waits, and is rendered when that tab's session exists; a host outside
##   every tab follows the shown tab; a tab switch does not re-render a tab's
##   own panes (`ui/panel_host.nim`, the resolver `ui_js` installs);
## * a move of the hidden tab updates the hidden tab's store only
##   (`state.syncStoreDebuggerPositionInto`, what each tab's `CtCompleteMove`
##   subscription calls);
## * each tab has its own Test Results and Constraints ViewModels, and what a
##   host installs reaches every tab's (`ui/test_results.nim`) — the
##   replacement for the copy-and-restore `shared_pane_state` did;
## * an answer from the main process reaches the tab whose request it
##   answers: at once when that tab is shown or the answer names none, queued
##   in order for a hidden tab and delivered when it is shown, dropped for a
##   tab that has closed (`tab_answer_routing.deliverTabAnswer`), and the main
##   process echoes the request's tab (`index/tab_answers`);
## * closing one tab disposes its ViewModels and leaves the other's alive,
##   and the window lets go of its Test Results ViewModel (`forgetTestResultsVM`);
## * a disposed pane leaves nothing running: the Call Trace scrubber's
##   refresh interval stops with its root (`list_scrubber_dom.everyMs`) —
##   asserted by the suite exiting at all, since a leaked interval keeps node
##   alive until the lane's timeout.
##
## CONTROL: against the pre-fix panel host — one window-global session —
## the second scenario fails: both tabs' hosts render the session last
## installed. (The module and the resolver this suite drives do not exist
## before the fix, so the control is the Playwright run recorded in the fix's
## report rather than a define here.)
##
## ## What is real, and the one stand-in
##
## REAL: `types`' window `Data` and its first session; the second tab's
## `DapApi` and views mediator from `event_helpers.attachSessionApis` (what
## `session_switch.createNewSession` calls); `DebuggerSession`,
## `newDapBackendService`, `initializePanelViewModels`; the panel host,
## rendering the real Call Trace view into jsdom's DOM; `session_viewmodels`;
## `state`'s position sync; `test_results`' per-tab binding.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records frames instead
## of writing them to the main process — as in
## `later_session_launch_failure_test.nim`; there is no main process here and
## nothing under test is replaced or observed through it.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this suite
## sets it.

import std/[unittest, jsffi, dom, importutils]

import ../types
import ../dap
import ../dap_backend
import ../event_helpers
import ../ui/session_viewmodels
import ../ui/panel_host
from ../ui/tab_answer_routing import deliverTabAnswer, deliverPendingTabAnswers
from ../index/tab_answers import askingTab, answerFor, withTab
import ../ui/state
import ../ui/test_results
from ../ui/pane_host_lookup import tabOfPaneHost
import ../viewmodel/session_vm
import ../viewmodel/sdk/debugger_session
from ../viewmodel/viewmodels/test_results_vm import TestResultsVM, setRunAbsence
from ../viewmodel/store/replay_data_store import ReplayDataStore
from isonim/web/dom_api as isonim_dom import nil
import isonim/core/signals

# What the suite asks of the session records and the panel host that no
# product code asks: the panes and events reach their session through the
# routes the assertions below exercise, so these readers live here.

proc sessionVMOwning(data: Data; dapApi: DapApi): SessionViewModel =
  ## The ViewModels of the session whose `DapApi` is `dapApi`.
  if data.isNil:
    return nil
  sessionVMOf(data.sessionOwning(dapApi))

proc sessionVMOfComponent(data: Data; component: Component): SessionViewModel =
  ## The ViewModels of the tab that holds `component`, or nil.
  sessionVMOf(data.sessionOfComponent(component))

proc panelMountSession(m: PanelMount): SessionViewModel =
  ## The session `m` rendered over, or nil while it waits for one (a private
  ## field of the mount, read through std/importutils).
  privateAccess(PanelMount)
  if m.isNil: nil else: m.session

const ExpectedChecks = 49
proc jsHasOwnProperty(o: JsObject; key: cstring): bool {.importjs:
  "Object.prototype.hasOwnProperty.call(#, #)".}

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) = discard
  ipc

proc initComponentRegistry(ui: Components) =
  for content in Content:
    ui.componentMapping[content] = JsAssoc[int, Component]{}
    ui.openComponentIds[content] = @[]

# ---------------------------------------------------------------------------
# The window: two tabs, a session for each as `configureSessionMiddleware`
# builds it, and a third tab with no session yet (a "+" tab's welcome screen)
# ---------------------------------------------------------------------------

data.ipc = recordingIpc()
data.dapApi.ipc = data.ipc
data.ui.initComponentRegistry()

proc addTab(): ReplaySession =
  let sessionId = data.sessions.len
  result = newReplaySession(ReplaySessionId(sessionId))
  attachSessionApis(result, sessionId, data.ipc)
  result.services = Services(debugger: DebuggerService(),
    editor: EditorService(open: JsAssoc[cstring, TabInfo]{}))
  result.ui = Components(editors: JsAssoc[cstring, EditorViewComponent]{})
  result.ui.initComponentRegistry()
  result.startOptions = StartOptions()
  data.sessions.add(result)

proc buildSessionVMs(session: ReplaySession): SessionViewModel =
  ## What `configureSessionMiddleware` builds for a page-owned tab.
  let vms = ensureViewModels(session)
  vms.debuggerSession = newDebuggerSession(newDapBackendService(session.dapApi))
  vms.vm = vms.debuggerSession.session
  vms.vm.initializePanelViewModels()
  vms.vm

let tab0 = data.sessions[0]
let tab1 = addTab()
let tab2 = addTab()
let vm0 = buildSessionVMs(tab0)
let vm1 = buildSessionVMs(tab1)

# Each tab's DOM in its own `#session-container-<n>` under `#ROOT`, as
# `session_switch.createSessionContainer` builds it, with a Call Trace host
# carrying the id every tab's singleton pane carries.
let root = document.createElement("div")
root.id = "ROOT"
document.body.appendChild(root)
proc paneHost(tab: int): isonim_dom.Element =
  let container = document.createElement("div")
  container.id = cstring("session-container-" & $tab)
  container.class = "session-container"
  root.appendChild(container)
  let host = document.createElement("div")
  host.id = "calltraceComponent-0"
  container.appendChild(host)
  cast[isonim_dom.Element](host)

let host0 = paneHost(0)
let host1 = paneHost(1)
let host2 = paneHost(2)
let overlayHost = block:
  let h = document.createElement("div")
  document.body.appendChild(h)
  cast[isonim_dom.Element](h)

# The resolver `ui_js.configureWindowMiddleware` installs.
setPanelSessionResolver(proc(host: isonim_dom.Element): SessionViewModel =
  data.sessionVMOfTab(tabOfPaneHost(host)))

scenario "each tab owns a distinct ViewModel set over its own DAP API":
  ck not vm0.isNil and not vm1.isNil
  ck vm0 != vm1
  ck vm0.store != vm1.store
  ck vm0.calltraceVM != vm1.calltraceVM
  # The panes #835 kept per tab by copying them in and out of one window-wide
  # ViewModel (the retired `shared_pane_state`): each tab now has its own.
  ck vm0.fileTreeVM != vm1.fileTreeVM
  ck constraintsVMOf(tab0) != constraintsVMOf(tab1)
  ck constraintsVMOf(tab1) == constraintsVMOf(tab1)
  ck sessionVMOf(tab0) == vm0 and sessionVMOf(tab1) == vm1
  ck sessionVMOf(tab2).isNil
  ck data.sessionVMOwning(tab1.dapApi) == vm1
  ck data.sessionWithDapSessionId(tab1.dapApi.sessionId) == tab1

scenario "a component answers for the tab whose registry holds it":
  let comp1 = Component(id: 0, content: Content.Calltrace)
  tab1.ui.componentMapping[Content.Calltrace][0] = comp1
  ck data.sessionOfComponent(comp1) == tab1
  ck data.sessionVMOfComponent(comp1) == vm1
  ck data.sessionOfComponent(Component(id: 0, content: Content.Calltrace)).isNil
  # A component no tab holds YET is keyed by the tab it is being registered
  # into — the shown one: `types.registerComponent` runs `register` before
  # it fills `componentMapping`. Keyed by the bare id, tab 1's pane took
  # tab 0's slot in its module's tables (the Agent Activity pane of a second
  # replay tab rendered empty, and tab 0's entry was overwritten).
  data.activeSessionIndex = 1
  let unplaced = Component(id: 0, content: Content.AgentActivity)
  ck data.tabScopedId(unplaced) == tabScopedKey(tab1, 0)
  ck data.tabScopedId(unplaced) != tabScopedKey(tab0, 0)
  data.activeSessionIndex = 0

var mounts: seq[PanelMount] = @[]

scenario "each tab's pane renders its own tab's session, whichever tab is shown":
  data.activeSessionIndex = 0
  setPanelSession(vm0)
  let m0 = mountPanel(host0, Content.Calltrace)
  let m1 = mountPanel(host1, Content.Calltrace)
  let m2 = mountPanel(host2, Content.Calltrace)
  let mo = mountPanel(overlayHost, Content.Calltrace)
  mounts = @[m0, m1, m2, mo]
  ck panelMountSession(m0) == vm0
  ck panelMountSession(m1) == vm1
  # A tab with no session yet waits; it never borrows another tab's.
  ck panelMountSession(m2).isNil
  # Outside every tab: the tab on screen.
  ck panelMountSession(mo) == vm0
  # Switching to tab 1 moves the overlay only.
  data.activeSessionIndex = 1
  setPanelSession(vm1)
  ck panelMountSession(m0) == vm0
  ck panelMountSession(m1) == vm1
  ck panelMountSession(mo) == vm1
  ck panelSession() == vm1
  # Tab 2's session is built: its waiting pane renders over it.
  let vm2 = buildSessionVMs(tab2)
  refreshPanelSessions()
  ck panelMountSession(m2) == vm2

scenario "a move of the hidden tab updates the hidden tab's store only":
  data.activeSessionIndex = 0
  let before0 = vm0.store.debugger.val.rrTicks
  syncStoreDebuggerPositionInto(vm1.store, tab1.ui.editors, 4242,
    cstring"/src/basics.py", 12)
  ck vm1.store.debugger.val.rrTicks == 4242'u64
  ck vm0.store.debugger.val.rrTicks == before0

scenario "each tab has its own Test Results ViewModel; host installs reach all":
  ck testResultsVMOf(tab0) != testResultsVMOf(tab1)
  ck testResultsVMOf(tab1) == testResultsVMOf(tab1)
  var installedOn: seq[TestResultsVM] = @[]
  bindTestResultsVM(testResultsVMOf(tab0))
  onEachTestResultsVM(proc(vm: TestResultsVM) = installedOn.add vm)
  bindTestResultsVM(testResultsVMOf(tab1))
  ck testResultsVMOf(tab0) in installedOn and testResultsVMOf(tab1) in installedOn
  # What one tab is told stays in that tab.
  testResultsVMInstance.setRunAbsence("No project folder is open.")
  ck testResultsVMOf(tab1).runAbsence.val == "No project folder is open."
  ck testResultsVMOf(tab0).runAbsence.val != "No project folder is open."

scenario "an answer reaches the tab that asked, whichever tab is shown":
  # The main process's half: the request's `tab` comes back on the answer.
  ck answerFor(js{tab: 7}, js{})[cstring"tab"].to(int) == 7
  ck askingTab(nil).isUndefined and askingTab(js{}).isUndefined
  ck not jsHasOwnProperty(withTab(js{}, jsUndefined), cstring"tab")
  # The renderer's half (`deliverTabAnswer`), tab 0 on screen.
  data.activeSessionIndex = 0
  var delivered: seq[string] = @[]
  deliverTabAnswer(data, cstring"m", js{}, proc() = delivered.add "untagged")
  deliverTabAnswer(data, cstring"m", js{tab: int(tab0.id)},
    proc() = delivered.add "shown")
  ck delivered == @["untagged", "shown"]
  # For the hidden tab: queued, in order, not run into the shown one.
  deliverTabAnswer(data, cstring"CODETRACER::filesystem-loaded",
    js{tab: int(tab1.id)}, proc() = delivered.add "hidden-1")
  deliverTabAnswer(data, cstring"CODETRACER::trace-loaded",
    js{tab: int(tab1.id)}, proc() = delivered.add "hidden-2")
  ck delivered.len == 2
  ck tab1.pendingTabAnswers.len == 2
  ck tab1.pendingTabAnswers[1].message == cstring"CODETRACER::trace-loaded"
  ck tab0.pendingTabAnswers.len == 0
  # For a tab that has closed: dropped, not given to the shown tab.
  deliverTabAnswer(data, cstring"m", js{tab: 9999},
    proc() = delivered.add "closed")
  ck "closed" notin delivered
  # A `tab` that is not a tab id is no tab: the shown tab's.
  deliverTabAnswer(data, cstring"m", js{tab: cstring"x"},
    proc() = delivered.add "not-a-tab")
  ck delivered[^1] == "not-a-tab"
  # Shown, the tab gets what waited for it, in arrival order, once.
  deliverPendingTabAnswers(tab1)
  ck delivered[^2 .. ^1] == @["hidden-1", "hidden-2"]
  ck tab1.pendingTabAnswers.len == 0

scenario "closing a tab disposes its ViewModels and no other tab's":
  let closingDebugger = viewModelsOf(tab1).debuggerSession
  # What `session_switch.closeSession` does first: the window lets go of the
  # closing tab's Test Results ViewModel, so a host installing later does not
  # write into it, and the other tab's still gets every install.
  let closingTests = testResultsVMOf(tab1)
  forgetTestResultsVM(closingTests)
  var reached: seq[TestResultsVM] = @[]
  onEachTestResultsVM(proc(vm: TestResultsVM) = reached.add vm)
  ck closingTests notin reached
  ck testResultsVMOf(tab0) in reached
  disposeViewModels(tab1)
  ck closingDebugger.isDisposed
  ck sessionVMOf(tab1).isNil
  ck not viewModelsOf(tab0).debuggerSession.isDisposed

# THE PANES GO, AND NOTHING OF THEM KEEPS RUNNING. Each Call Trace view's
# scrubber refreshes on an interval; disposing a mount must stop it
# (`list_scrubber_dom.everyMs`), and the overlay's was rendered twice above. A
# leaked interval keeps node alive, so this suite would never exit and the
# lane would report it timed out.
for m in mounts:
  m.dispose()

if checks != ExpectedChecks:
  echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
