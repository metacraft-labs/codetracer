## origin_chain_wiring_test.nim
##
## THE RENDERER WIRES THE ORIGIN BADGE AND "PIN TO SCRATCHPAD" — through
## `ui/state.nim` and `ui/scratchpad.nim` themselves, over the session
## `ui_js.configureSessionMiddleware` builds (codetracer#856).
##
## ## The defects this pins
##
## `OriginChainVM.onPinChain` forwards a pinned chain through
## `onPinChainProc`, and no renderer code assigned it: the side panel's
## "Pin to scratchpad" (Value-Origin-Tracking.md §3.3, §3.5) recorded the pin
## on the OriginChainVM and never reached `ScratchpadVM.addChain`. And the
## State pane's origin badge, clicked on a row whose summary arrived eagerly,
## expanded the row without asking for its chain (§3.2.1 "expands the row in
## place to show the full hop chain"), so the row stayed empty until the
## context menu had fetched one. The headless suite
## (`viewmodel/tests/unit/test_origin_chain_vm.nim`, "M86") holds the
## ViewModel half; this suite holds the half only the renderer has: that
## `ui/state.nim` installs those bridges, and that the pin lands in the
## Scratchpad pane's own ViewModel, which `ui/scratchpad.nim` owns and
## `ui/state.nim` cannot import.
##
## ## What is real, and the one stand-in
##
## REAL: `DapApi` and `middleware.setupMiddlewareApis`, the `DebuggerSession`
## over `newDapBackendService` and its panel ViewModels, `state
## .initStateVMFromSession` and `scratchpad.initScratchpadVMFromSession` (the
## calls `ui_js.configureSessionMiddleware` makes, in its order), and the bridges
## they install.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records the request
## frame instead of writing it to the Backend Manager, as in
## `locals_answer_identity_test.nim`. Nothing under test is replaced.
##
## Lane: `renderer-dom` — the browser target (`nim js -d:ctRenderer`, no
## `-d:nodejs`), run by `jsdom-run.mjs` over a real DOM. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it.

import std/[unittest, jsffi, asyncjs, options]

import ../types
import ../dap
import ../dap_backend
import ../middleware
import ../ui/state
import ../ui/scratchpad
import ../viewmodel/session_vm
import ../viewmodel/sdk/debugger_session
from ../viewmodel/store/types as store_types import nil
import ../viewmodel/viewmodels/[origin_chain_types, origin_chain_vm,
                                 scratchpad_vm]
from ../viewmodel/viewmodels/state_vm import StateVM
import isonim/core/signals

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

var sentPackets: seq[JsObject] = @[]

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add(packet)
  ipc

proc originChainRequests(): seq[JsObject] =
  for p in sentPackets:
    if p["command"].to(cstring) == cstring"ct/originChain":
      result.add p

# ---------------------------------------------------------------------------
# The renderer, wired as `ui_js.configureSessionMiddleware` wires it
# ---------------------------------------------------------------------------

let dapApi = DapApi(ipc: recordingIpc(), seq: 0, sessionId: 0)
let viewsApi = setupSinglePageViewsApi(cstring"test-views")
setupMiddlewareApis(dapApi, viewsApi)

let session = newDebuggerSession(newDapBackendService(dapApi))
session.session.initializePanelViewModels()
initStateVMFromSession(session.session.stateVM)
initScratchpadVMFromSession(session.session.scratchpadVM)

let chain = OriginChain(queryVariable: "total", queryStepId: 3,
  hops: @[OriginHop(kind: okTrivialCopy, targetExpr: "total",
                    sourceExpr: "a", stepId: 3,
                    location: OriginLocation(path: "fixture.py", line: 3))],
  terminator: Terminator(kind: tkwLiteral, expression: "10"))

suite "the renderer's origin bridges (ui/state.nim, ui/scratchpad.nim)":

  test "Pin to scratchpad lands in the Scratchpad pane's ViewModel":
    let originVM = activeOriginChainVM()
    ck not originVM.isNil
    ck not originVM.onPinChainProc.isNil
    let scratch = session.session.scratchpadVM
    ck scratch.chainEntries.val.len == 0
    originVM.onPinChain(chain)
    ck originVM.pinnedChains.val.len == 1
    ck scratch.chainEntries.val.len == 1
    ck scratch.chainEntries.val.len == 1 and
      scratch.chainEntries.val[0].chain.queryVariable == "total"

  test "the badge's chain fetch is installed, sends ct/originChain and leaves the side panel shut":
    let stateVM: StateVM = activeStateVM()
    let originVM = activeOriginChainVM()
    ck not stateVM.onLoadOriginChainProc.isNil
    let before = originChainRequests().len
    stateVM.onLoadOriginChainProc("total",
      store_types.Location(file: "fixture.py", line: 3))
    let sent = originChainRequests()
    ck sent.len == before + 1
    ck sent.len == before + 1 and
      sent[^1]["arguments"]["variableName"].to(cstring) == cstring"total"
    ck not originVM.sidePanelOpen.val
    ck originVM.activeChain.val.isNone
    ck not originVM.loading.val

proc settle(): Future[void] =
  ## Yield to the event loop until pending microtasks have run: a request's
  ## future settles in a continuation, never inside the delivering call.
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

proc chainAnswer(requestSeq: int; variable: cstring): JsObject =
  ## The Backend Manager's response frame for one `ct/originChain`, in the
  ## shape `locals_answer_identity_test.nim` writes for `ct/load-locals`:
  ## `type`, `command`, `request_seq` echoing the request's `seq`,
  ## `success`, and a body in the backend's chain shape.
  let location = JsObject{path: cstring"fixture.py", line: 3, rrTicks: 3}
  let hop = JsObject{kind: cstring"trivialCopy", targetExpr: variable,
                     sourceExpr: cstring"a", stepId: 3, location: location}
  let terminator = JsObject{kind: cstring"literal", expression: cstring"10"}
  let body = newJsObject()
  body[cstring"queryVariable"] = variable
  body[cstring"queryStepId"] = 3
  body[cstring"hops"] = [hop].toJs
  body[cstring"terminator"] = terminator
  JsObject{`type`: cstring"response", request_seq: requestSeq,
           success: true, command: cstring"ct/originChain", body: body}

proc answerChecks() {.async.} =
  # THE ANSWER ON THE REAL TRANSPORT REACHES THE ROW. The badge asks for
  # `counter`; its answer, delivered as `ui_js.onDapReceiveResponse`
  # delivers it, settles the request's future, and the row's chain at this
  # stop is the one the in-row block then draws (§3.2.1).
  let stateVM: StateVM = activeStateVM()
  stateVM.onLoadOriginChainProc("counter",
    store_types.Location(file: "fixture.py", line: 3))
  let sent = originChainRequests()
  ck sent.len > 0
  if sent.len == 0:
    return
  ck sent[^1]["arguments"]["variableName"].to(cstring) == cstring"counter"
  ck stateVM.originChainLookup("counter").isNone
  deliverDapResponse(dapApi, dapApi,
    chainAnswer(sent[^1]["seq"].to(int), cstring"counter"))
  await settle()
  let held = stateVM.originChainLookup("counter")
  ck held.isSome
  ck held.isSome and held.get.hops.len == 1
  # The row's answer is the row's alone: the side panel stays shut, with no
  # chain of its own.
  let originVM = activeOriginChainVM()
  ck not originVM.sidePanelOpen.val
  ck originVM.activeChain.val.isNone
  # Asked once per row per stop: a second expand of the held row sends
  # nothing.
  let before = originChainRequests().len
  stateVM.onLoadOriginChainProc("counter",
    store_types.Location(file: "fixture.py", line: 3))
  ck originChainRequests().len == before

  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}

discard answerChecks()
