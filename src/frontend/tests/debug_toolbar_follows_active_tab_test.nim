## debug_toolbar_follows_active_tab_test.nim
##
## THE DEBUGGER TOOLBAR DRIVES THE TAB ON SCREEN — whichever tab that is now,
## not the one that was on screen when the toolbar's routes were built.
##
## ## The defect this pins
##
## The window has one toolbar and every replay tab has its own views mediator
## and `DapApi` (`event_helpers.attachSessionApis`). The toolbar's routes
## (`debug_toolbar.desktopDebugCommands`) are built once per window, when the
## first session's ViewModels are (`ui_js.configureMiddleware`), and they used
## to capture a mediator onto `data.viewsApi` at that moment: the FIRST tab's.
## With a second tab open and on screen, a click on Step Over moved the first
## tab's replay, out of sight, while F10 (`renderer.step`, which sends on
## `data.dapApi`) moved the tab on screen. Before the toolbar became a
## ViewModel, `session_switch.switchSession` re-pointed it at the target
## tab's own mediator on every switch
## (`rewireDebugControlsBridgeForActiveSession`, deleted with `ui/debug.nim`),
## and `session-chrome/new_trace_caption_chrome_test.nim` asserted that
## re-pointing; the refactor dropped it and left the assertion reading a file
## that no longer exists.
##
## ## What is asserted
##
## Two tabs; the toolbar's routes are built while the first is on screen, as
## `configureMiddleware` builds them. Then, for each of the routes that reach
## a replay — a step, Run to Entry, and a jump to a history entry:
##
##   * with the second tab on screen, the request reaches the second tab's
##     views mediator and not the first's;
##   * switched back to the first tab, it reaches the first tab's and not the
##     second's.
##
## And once the second tab is closed and another opened in its place, a step
## reaches the new tab's views mediator, not the closed tab's.
##
## ## What is real, and the stand-ins
##
## REAL: `types`' window `Data` and its first session; the second tab's views
## mediator and `DapApi`, built by `event_helpers.attachSessionApis` — the call
## `session_switch.createNewSession` makes for them; the toolbar's routes,
## built by `debug_toolbar.desktopDebugCommands` exactly as `ui_js` builds
## them; the local-view mediators and transports of `communication` / `types`
## that carry an emitted request to a tab's views mediator.
##
## THE STAND-INS, and why:
##
##   * A tab switch is `switchSession`'s step that the toolbar reads — the
##     target becomes `data.activeSessionIndex`. `switchSession` itself is not
##     called because `session_switch` reaches the editor through its menu,
##     and the editor creates a Monaco model when its module loads (the same
##     reason `later_session_launch_failure_test.nim` gives).
##   * Each tab's views mediator gets a recording handler for the three
##     request kinds, in place of `middleware.setupMiddlewareApis`' handlers,
##     which would forward them to a `DapApi` and on to an Electron main
##     process this suite does not have. What is under test is which tab's
##     mediator a toolbar action reaches, and the recording handler sits
##     exactly where middleware's does.
##   * The `ipc` object's `send` records outgoing frames; the session code
##     copies the window's IPC bridge into each tab's `DapApi`.
##
## Lane: `renderer-dom`, compiled as the renderer is (`nim js -d:ctRenderer`,
## browser target) and run by `jsdom-run.mjs`. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it and
## prints unittest's `[OK]` / `[FAILED]` lines for the lane runner to count.

import ./legacy_loop_dom_bootstrap
import std/[unittest, jsffi]

import ../types
import ../communication
import ../event_helpers
# `debug_toolbar` is in an import cycle with `menu` (through `chord_display`)
# and `session_switch`, which compiles only when entered where the renderer
# enters it: at `renderer`, then `ui/layout` (as `loop_built_handlers_test`
# does). Entered at `debug_toolbar`, `menu` sees it half-declared.
import ../renderer
import ../ui/layout
import ../ui/debug_toolbar
import ../dap_backend
import ../viewmodel/store/replay_data_store
import ../viewmodel/store/types as store_types
import ../viewmodel/viewmodels/debug_controls_vm
import ../../common/ct_event

const ExpectedChecks = 15
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  ## One named case: `[OK]` when none of its checks failed.
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

# ---------------------------------------------------------------------------
# The window: two tabs
# ---------------------------------------------------------------------------

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) = discard
  ipc

type Received = object
  ## The replay requests one tab's views mediator was handed.
  steps: seq[CtEventKind]
  runToEntry: int
  historyJumps: seq[int]

var received: array[3, Received]

proc recordRequests(viewsApi: MediatorWithSubscribers; tab: int) =
  ## Record, on a tab's views mediator, the requests the toolbar's replay
  ## routes emit — where `middleware.setupMiddlewareApis` subscribes to them.
  for kind in [DapNext, DapStepIn]:
    viewsApi.subscribe(kind, proc(kind: CtEventKind, value: DapStepArguments,
                                  sub: Subscriber) =
      received[tab].steps.add(kind))
  viewsApi.subscribe(CtRunToEntry, proc(kind: CtEventKind, value: EmptyArg,
                                        sub: Subscriber) =
    inc received[tab].runToEntry)
  viewsApi.subscribe(CtHistoryJump, proc(kind: CtEventKind,
                                         value: types.Location,
                                         sub: Subscriber) =
    received[tab].historyJumps.add(value.line))

# The first tab: the session `types` builds with the window.
data.ipc = recordingIpc()
data.dapApi.ipc = data.ipc
data.viewsApi.recordRequests(0)

proc openTab(slot: int) =
  ## A tab opened after the first, with what the toolbar's routes read of a
  ## tab; its views mediator records into `received[slot]`.
  let sessionId = data.sessions.len
  let session = newReplaySession(ReplaySessionId(sessionId))
  attachSessionApis(session, sessionId, data.ipc)
  session.status = StatusState(stableBusy: false)
  session.startOptions = StartOptions()
  data.sessions.add(session)
  session.viewsApi.recordRequests(slot)

openTab(1)

doAssert data.sessions.len == 2
doAssert data.sessions[0].viewsApi != data.sessions[1].viewsApi

# The toolbar's routes, built once while the first tab is on screen, as
# `ui_js.configureMiddleware` builds them.
data.activeSessionIndex = 0
let commands = desktopDebugCommands(data,
  createReplayDataStore(newDapBackendService(data.dapApi)))

proc showTab(index: int) =
  ## `switchSession`'s step the toolbar reads: the target is the active tab.
  ## The previous step's busy flag is cleared as its `CtCompleteMove` would.
  data.activeSessionIndex = index
  for session in data.sessions:
    if not session.status.isNil:
      session.status.stableBusy = false

proc clearReceived() =
  received = default(array[3, Received])

proc jumpEntry(line: int): JumpEntry =
  JumpEntry(location: store_types.Location(file: "main.py", line: line),
            rrTicks: 1)

# ---------------------------------------------------------------------------

scenario "a step from the toolbar moves the tab on screen":
  clearReceived()
  showTab(1)
  commands.step("next")
  ck received[1].steps == @[DapNext]
  ck received[0].steps.len == 0

  clearReceived()
  showTab(0)
  commands.step("step-in")
  ck received[0].steps == @[DapStepIn]
  ck received[1].steps.len == 0

scenario "Run to Entry from the toolbar restarts the tab on screen":
  clearReceived()
  showTab(1)
  commands.runToEntry()
  ck received[1].runToEntry == 1
  ck received[0].runToEntry == 0

  clearReceived()
  showTab(0)
  commands.runToEntry()
  ck received[0].runToEntry == 1
  ck received[1].runToEntry == 0

scenario "a history jump from the toolbar moves the tab on screen":
  clearReceived()
  showTab(1)
  commands.historyJump(jumpEntry(7))
  ck received[1].historyJumps == @[7]
  ck received[0].historyJumps.len == 0

  clearReceived()
  showTab(0)
  commands.historyJump(jumpEntry(9))
  ck received[0].historyJumps == @[9]
  ck received[1].historyJumps.len == 0

scenario "a tab opened where a closed one was takes the toolbar's requests":
  # The second tab closes (`closeSession` drops it from `data.sessions`) and a
  # new one opens at the same index, with a views mediator of its own. The
  # toolbar has already dispatched into the closed tab, so a route that
  # remembered the mediator by tab index would still send to the closed one.
  data.sessions.setLen(1)
  openTab(2)
  doAssert data.sessions.len == 2
  clearReceived()
  showTab(1)
  commands.step("next")
  ck received[2].steps == @[DapNext]
  ck received[1].steps.len == 0
  ck received[0].steps.len == 0

# Every check above ran: a scenario that stopped early is a failure, not a
# shorter pass.
if checks != ExpectedChecks:
  echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
