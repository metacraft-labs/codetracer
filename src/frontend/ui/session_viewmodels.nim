## ui/session_viewmodels.nim — each window tab owns its ViewModels.
##
## A desktop window holds one `ReplaySession` per tab, and each tab is an
## independent session (`GUI/Multi-Window-Tab-Management.md` §Tab Behavior
## rule 1): clicking a tab switches every panel to THAT session's data (rule
## 2), and what a tab shows is kept while another is shown (rule 6). The
## ViewModel layer states the same thing from its side
## (`Refactoring-Plans/Shared-DOM-Front-Ends.md` D7): the panel ViewModels are
## "created by `initializePanelViewModels`, once per session".
##
## Before this module the renderer built ONE `SessionViewModel` per window —
## `ui_js.configureMiddleware` ran once (`middlewareConfigured`) over the DAP
## API of whichever tab was active first — and every later tab's panes
## rendered that one set: a second recording's Call Trace listed the first
## recording's functions, and the toolbar stepped the first tab's replay
## whichever tab was on screen (codetracer-pm issue
## `2026-10-21-a-second-replay-tab-shows-the-first-tabs-data-because-the-window-builds-one-session-viewmodel.md`).
##
## Now each `ReplaySession` carries a `SessionViewModels` record
## (`ReplaySession.viewModels`) holding:
##
## * the session's `SessionViewModel` and what built it — a page-owned
##   `DebuggerSession` over that tab's own `DapApi`, or, under `ct host`, the
##   mirror of the server's session (only ever the window's first session: the
##   server owns one session and the page mirrors it over its one socket);
## * the collaboration adapter projecting that session's collaboration core;
## * the ViewModels of the per-tab panes the session layer does not hold —
##   Test Results and Constraints, whose inputs come from the host rather than
##   from the replay store (`ui/test_results.nim`, `ui/constraints.nim`).
##
## Readers ask this module for a session's ViewModels and never keep their
## own copy: the active tab's (`activeSessionVM`), the one a tab's container
## holds (`sessionVMOfTab`), or a session's own (`sessionVMOf`, for the
## session an event arrived on, `Data.sessionOwning`, or the tab holding a
## legacy component, `sessionOfComponent`). Events from a hidden tab therefore
## update that tab's ViewModels, not the visible one's.
##
## No DOM and no `ui_js` here, so a headless renderer suite can drive it
## (`src/frontend/tests/session_viewmodels_test.nim`).

import ../types
from ../dap import DapApi
import std/jsffi  # `JsAssoc` iteration (`componentMapping`)
from ../lib/jslib import hasKey
import ../viewmodel/session_vm
import ../viewmodel/sdk/debugger_session
import ../viewmodel/sync/mirror_session
import ../viewmodel/collab/front_end_adapter
from ../viewmodel/viewmodels/test_results_vm import TestResultsVM,
  createTestResultsVM
from ../viewmodel/viewmodels/constraints_vm import ConstraintsVM,
  createConstraintsVM
import isonim/viewmodel as isovm
from isonim/web/dom_api import nil
from ./pane_host_lookup import tabOfPaneHost


type
  SessionViewModels* = ref object of RootObj
    ## What one window tab's session owns of the ViewModel layer.
    vm*: SessionViewModel
      ## The session's ViewModels, nil until the session first gets a trace
      ## or an edit session (`ui_js.configureSessionMiddleware`).
    debuggerSession*: DebuggerSession
      ## The page-owned session that built `vm`; nil for a mirror.
    mirror*: MirrorSession
      ## The `ct host` server's session this page mirrors; nil when the page
      ## owns `vm`.
    collabAdapter*: FrontEndAdapter
      ## The web UI's collaboration adapter over `vm.collabCore`.
    supportsStepBack*: bool
      ## The backend's DAP `initialize` capability, kept for a response that
      ## arrives before `vm` exists and applied when it is built.
    testResultsVM*: TestResultsVM
    constraintsVM*: ConstraintsVM
      ## The Test Results and Constraints panes' ViewModels for this tab,
      ## created on first use (`testResultsVMOf`, `constraintsVMOf`).
    wired*: bool
      ## Whether the session's middleware and subscriptions are installed —
      ## each session's are, exactly once.
    debuggerSurface*: bool
      ## Whether the session has a replay to step, so the window binds the
      ## stepping toolbar to it: false for a dataset review until it opens a
      ## recording (`ui_js.configureSessionMiddleware`, `onTraceLoaded`).

proc viewModelsOf*(session: ReplaySession): SessionViewModels =
  ## `session`'s record, or nil when it has none yet.
  if session.isNil or session.viewModels.isNil:
    return nil
  SessionViewModels(session.viewModels)

proc ensureViewModels*(session: ReplaySession): SessionViewModels =
  ## `session`'s record, created empty on first use.
  doAssert not session.isNil, "ensureViewModels: no session"
  result = viewModelsOf(session)
  if result.isNil:
    result = SessionViewModels()
    session.viewModels = result

proc sessionVMOf*(session: ReplaySession): SessionViewModel =
  ## `session`'s `SessionViewModel`, or nil before it has one.
  let vms = viewModelsOf(session)
  if vms.isNil: nil else: vms.vm

proc anySessionViewModels*(data: Data): bool =
  ## Whether any tab of the window has its `SessionViewModel` yet.
  if data.isNil:
    return false
  for session in data.sessions:
    if not sessionVMOf(session).isNil:
      return true
  false

proc activeSessionVM*(data: Data): SessionViewModel =
  ## The ViewModels of the tab on screen — what the window-level pane
  ## bridges (the toolbar, the footer panes, key handlers) act on.
  if data.isNil or data.sessions.len == 0 or
     data.activeSessionIndex < 0 or
     data.activeSessionIndex >= data.sessions.len:
    return nil
  sessionVMOf(data.sessions[data.activeSessionIndex])

proc sessionVMOfTab*(data: Data; tab: int): SessionViewModel =
  ## The ViewModels of the tab at position `tab` (the `<n>` of its
  ## `session-container-<n>`), or nil when that tab has none yet. A negative
  ## `tab` is a host outside every tab container — the auto-hide overlay, a
  ## page with no tab containers — which shows the tab on screen.
  if data.isNil:
    return nil
  if tab < 0:
    return data.activeSessionVM()
  if tab >= data.sessions.len:
    return nil
  sessionVMOf(data.sessions[tab])

proc sessionWithDapSessionId*(data: Data; sessionId: int): ReplaySession =
  ## The session whose `DapApi` carries `sessionId` (the id its requests are
  ## stamped with and `dap.ctRequestId` names them by), or nil when no open
  ## tab has it.
  if data.isNil:
    return nil
  for session in data.sessions:
    if not session.isNil and not session.dapApi.isNil and
       session.dapApi.sessionId == sessionId:
      return session
  nil

proc sessionOfComponent*(data: Data; component: Component): ReplaySession =
  ## The session whose component registry holds `component`. A legacy
  ## component is built and registered per tab (`types.registerComponent`
  ## puts it in that tab's `componentMapping`), so this is the tab whose
  ## events it receives. Nil for a component no tab holds (the VS Code
  ## webview's).
  if data.isNil or component.isNil:
    return nil
  for session in data.sessions:
    if session.isNil or session.ui.isNil:
      continue
    let mapping = session.ui.componentMapping[component.content]
    if mapping.isNil:
      continue
    for _, held in mapping:
      if held == component:
        return session
  nil

proc shownTabComponent*(data: Data; content: Content): Component =
  ## The first `content` component of the tab on screen, or nil — the one a
  ## pane bridge syncs its legacy record from when the shown tab's ViewModel
  ## is handed to it, rather than a module's write-once reference to whichever
  ## tab's component registered first.
  if data.isNil or data.sessions.len == 0 or data.ui.isNil:
    return nil
  let mapping = data.ui.componentMapping[content]
  if mapping.isNil:
    return nil
  for _, component in mapping:
    if not component.isNil:
      return component
  nil

const TabScopeStride = 1_000_000
  ## Component ids stay below this within one tab.

proc tabScopedKey*(session: ReplaySession; componentId: int): int =
  ## A key for `componentId` that is unique across the window's tabs. The
  ## singleton panes keep component id 0 IN EVERY TAB (`data.buildComponent(0)`
  ## and friends look them up by it), so a module table keyed by the bare id
  ## gave tab 0's and tab 1's panes ONE ViewModel between them. Keyed by the
  ## tab's id as well, each tab's pane has its own. `session` nil (a page with
  ## no tab registry) keeps the bare id.
  if session.isNil: componentId
  else: int(session.id) * TabScopeStride + componentId

proc tabScopedId*(data: Data; component: Component): int =
  ## `tabScopedKey` of `component` in the tab that holds it — or, for a
  ## component no tab holds YET, in the tab on screen. That case is not rare:
  ## `types.registerComponent` calls the component's `register` (which
  ## records it in its module's tables under this key) before it puts the
  ## component in the active tab's `componentMapping`, and the active tab is
  ## where it is about to go. Keying it by the bare id instead filed a later
  ## tab's pane under tab 0's key, over tab 0's own.
  if component.isNil:
    return -1
  var session = data.sessionOfComponent(component)
  if session.isNil and not data.isNil and data.sessions.len > 0:
    session = data.activeSession
  tabScopedKey(session, component.id)

proc hostTab*(data: Data; host: dom_api.Element): ReplaySession =
  ## The tab whose container holds the pane host `host`, or the tab on screen
  ## for a host outside every tab (`tabOfPaneHost`).
  if data.isNil or data.sessions.len == 0:
    return nil
  let tab = tabOfPaneHost(host)
  if tab >= 0 and tab < data.sessions.len: data.sessions[tab]
  else: data.activeSession

proc hostTabComponent*(data: Data; host: dom_api.Element; content: Content;
                       componentId: int): Component =
  ## The `content` component with `componentId` of the tab that holds `host`
  ## — the component a pane renderer draws, which is that tab's even when it
  ## renders while another tab is shown.
  let session = data.hostTab(host)
  if session.isNil or session.ui.isNil:
    return nil
  let mapping = session.ui.componentMapping[content]
  if mapping.isNil or not mapping.hasKey(componentId):
    return nil
  mapping[componentId]

proc jsHasBoundMark(o: RootRef): bool {.importjs: "(#.__ctWindowBound === true)".}
proc jsSetBoundMark(o: RootRef) {.importjs: "#.__ctWindowBound = true".}

proc firstBinding*(vm: RootRef): bool =
  ## True the first time `vm` is handed to the window's pane bridges, false
  ## after. A bridge replays its component's legacy record into a ViewModel
  ## once, when the ViewModel is new; doing it again on every tab switch would
  ## overwrite state the ViewModel gained since (a Scratchpad's pinned chains,
  ## which no legacy record holds). The mark lives on the object, so it goes
  ## with it.
  if vm.isNil or jsHasBoundMark(vm):
    return false
  jsSetBoundMark(vm)
  true

template ownPaneVM*(component: Component; shown, field: untyped): untyped =
  ## The `field` ViewModel of the tab that holds `component` — the tab whose
  ## events the component receives, shown or not. A legacy component's
  ## handlers write through this, never through the module's slot `shown`,
  ## which names the SHOWN tab's: a late answer a hidden tab receives (its
  ## delayed move replay, a debug output, a step-lines answer) belongs in the
  ## hidden tab's ViewModel.
  ##
  ## * a component no tab holds (a page with no tab registry) uses `shown`;
  ## * a component whose tab has no session yet gets nil — never another
  ##   tab's ViewModel. Before the window's first session exists that is
  ##   `shown` itself, the stub the module built for the components that
  ##   register before any session does, which the first session replaces.
  block:
    let ownerTab = data.sessionOfComponent(component)
    if ownerTab.isNil:
      shown
    else:
      let ownerVMs = sessionVMOf(ownerTab)
      if not ownerVMs.isNil:
        ownerVMs.field
      elif not data.anySessionViewModels():
        shown
      else:
        typeof(shown)(nil)

proc testResultsVMOf*(session: ReplaySession): TestResultsVM =
  ## The Test Results pane's ViewModel of `session`'s tab, created on first
  ## use: a tab entered for the first time shows what a fresh window shows,
  ## and a tab that is left keeps what it showed (rules 1 and 6).
  let vms = ensureViewModels(session)
  if vms.testResultsVM.isNil:
    vms.testResultsVM = createTestResultsVM()
  vms.testResultsVM

proc constraintsVMOf*(session: ReplaySession): ConstraintsVM =
  ## The Constraints pane's ViewModel of `session`'s tab, as `testResultsVMOf`.
  let vms = ensureViewModels(session)
  if vms.constraintsVM.isNil:
    vms.constraintsVM = createConstraintsVM()
  vms.constraintsVM

proc disposeViewModels*(session: ReplaySession) =
  ## Release everything `session` owns of the ViewModel layer, as its tab is
  ## closed: the debugger session (and with it the `SessionViewModel`, its
  ## store and every panel ViewModel's effects), or the mirror, and the
  ## per-tab pane ViewModels. Other tabs' records are untouched. Idempotent.
  let vms = viewModelsOf(session)
  if vms.isNil:
    return
  session.viewModels = nil
  if not vms.debuggerSession.isNil:
    # The transport is the tab's `DapApi`, which the window's IPC channel
    # carries and the main process closes with the replay
    # (`CODETRACER::close-replay-session`); there is nothing of it to close
    # here, and `RealBackendService.disconnect` is a no-op for it.
    vms.debuggerSession.dispose(disconnectBackend = false)
  elif not vms.mirror.isNil:
    # The mirror built its session inside its own reactive root, which this
    # disposes together with the channel.
    vms.mirror.dispose()
  elif not vms.vm.isNil:
    vms.vm.dispose(disconnectBackend = false)
  if not vms.testResultsVM.isNil:
    isovm.dispose(vms.testResultsVM)
  if not vms.constraintsVM.isNil:
    isovm.dispose(vms.constraintsVM)
  vms.vm = nil
  vms.debuggerSession = nil
  vms.mirror = nil
  vms.collabAdapter = nil
  vms.testResultsVM = nil
  vms.constraintsVM = nil
