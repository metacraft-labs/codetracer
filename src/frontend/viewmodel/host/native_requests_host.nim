## viewmodel/host/native_requests_host.nim — the Requests pane's host on the
## terminal and the GPUI window: what a native front-end does with the
## session's `RequestPanelVM` that only a host can do.
##
## Spec: `GUI/Core-Panes/Request-Panel.md` § "The terminal and the GPUI window
## (PLAT-58)", N.2 and N.4.
##
## The ViewModel decides everything a row means (`request_panel_vm`: the
## cells, the double press, the menu, the cadence of the tail). Three things
## are the host's, because they need the engine's stream or the window:
##
##   * **the move.** Going to a handler sends `ct/seek-to-geid` through the
##     session's store (`RequestPanelVM.activate`); the engine answers with the
##     `stopped` + `ct/complete-move` pair, which a native host consumes
##     (`settleAfterSeek`) so every pane reads the new position — the editor
##     the handler's entry line, the Call Trace the call it runs in. A seek the
##     engine answered WITHOUT moving (it could not restore the step) is said,
##     never waited for;
##   * **the window and the tail**, applied: the stdio transport answers at
##     once but the store's callbacks are deferred, so after a report of the
##     rows shown (`setViewport`) or a poll of the tail (`pollTail`) the
##     platform callbacks are drained before the pane is read;
##   * **another container**: a span whose execution lives in a different
##     recording is opened through the front-end's own opener (a new session
##     tab, Multi-Window-Tab-Management's default).

import std/json

import isonim/core/[async_compat, signals]

import ../headless_session
import ../viewport
import ../viewmodels/request_panel_vm
import ../../headless_app/request_menu

export request_panel_vm, request_menu

type
  RequestsHostResult* = object
    ## What one act on the pane did, for the front-end to show.
    moved*: bool
      ## The debugger moved: every pane is read again.
    note*: string
      ## The status line's words ("" for none).
    copied*: string
      ## Text for the clipboard (Copy URL).

proc wireRequests*(s: HeadlessDebugSession;
                   openExternal: proc(tracePath: string): string) =
  ## Hand the session's `RequestPanelVM` the front-end's opener for a span
  ## whose execution is in another container. Its answer (why it could not
  ## open, or "") is the navigation message.
  if s.isNil or s.session.isNil or s.session.requestPanelVM.isNil:
    return
  let vm = s.session.requestPanelVM
  vm.openExternalTrace = proc(tracePath: string; startGeid: int64) =
    let why = if openExternal.isNil: "this window cannot open " & tracePath
              else: openExternal(tracePath)
    vm.navigationMessage.val = why

proc requestsVM*(s: HeadlessDebugSession): RequestPanelVM =
  if s.isNil or s.session.isNil: nil else: s.session.requestPanelVM

proc engineMoved(s: HeadlessDebugSession): bool =
  ## Whether the seek's answer carried a move: its `stopped` is queued.
  for e in s.backend.eventQueue:
    if e{"event"}.getStr("") == "stopped":
      return true
  false

proc settle(s: HeadlessDebugSession; a: RequestActivation): RequestsHostResult =
  ## The host's half of an activation (`RequestPanelVM.activate`).
  case a.kind
  of raNone:
    result.note = "there is no such request"
  of raRefused:
    result.note = a.reason
  of raExternal:
    let vm = s.requestsVM
    result.note =
      if vm.isNil or vm.navigationMessage.val.len == 0:
        "opened " & a.tracePath
      else: vm.navigationMessage.val
  of raSeek:
    if not s.engineMoved():
      result.note = "the engine did not move to the handler of " & a.url
      return
    try:
      s.settleAfterSeek()
    except CatchableError as e:
      result.note = "could not go to the handler of " & a.url & ": " & e.msg
      return
    result.moved = true
    result.note = "the handler of " & a.url

proc goToHandler*(s: HeadlessDebugSession; index: int): RequestsHostResult =
  ## Go to held row `index`'s handler — the desktop's double click.
  let vm = s.requestsVM
  if vm.isNil:
    return RequestsHostResult(note: "this session has no requests")
  s.settle(vm.activate(index))

proc pressRequest*(s: HeadlessDebugSession; index: int;
                   nowMs: int64): RequestsHostResult =
  ## A press on held row `index` at `nowMs`: it is selected; the second press
  ## of a double press goes to its handler (`RequestPanelVM.pressRow`).
  let vm = s.requestsVM
  if vm.isNil:
    return RequestsHostResult(note: "this session has no requests")
  case vm.pressRow(index, nowMs)
  of rpNone: RequestsHostResult()
  of rpSelected: RequestsHostResult()
  of rpActivate: s.goToHandler(index)

proc runRequestMenu*(s: HeadlessDebugSession; action: ContextAction;
                     target: ContextTarget): RequestsHostResult =
  ## A Requests menu's entry chosen (a row's, or a picker's option).
  let vm = s.requestsVM
  if vm.isNil:
    return RequestsHostResult(note: "this session has no requests")
  let outcome = vm.runRequestMenuAction(action, target)
  if not outcome.done:
    return RequestsHostResult(note: "the request is no longer listed")
  if outcome.copied.len > 0:
    return RequestsHostResult(copied: outcome.copied,
                              note: "copied " & outcome.copied)
  if action == caRequestGoToHandler:
    return s.settle(outcome.activation)

proc showRequestWindow*(s: HeadlessDebugSession; rows, top: int) =
  ## The pane shows `rows` rows from list position `top`: tell the ViewModel
  ## (Viewport-Driven-Loading V1), which asks the engine for that window of a
  ## completed recording, and apply the answer.
  let vm = s.requestsVM
  if vm.isNil or rows <= 0:
    return
  vm.setViewport(Viewport(rows: rows, firstRow: max(0, top)))
  drainPlatformCallbacks()

proc pollRequests*(s: HeadlessDebugSession; nowMs: int64): bool =
  ## The idle tick: the tail polled when it is due (`pollTail`), its answer
  ## applied. Whether a poll was sent.
  let vm = s.requestsVM
  if vm.isNil:
    return false
  result = vm.pollTail(nowMs)
  if result:
    drainPlatformCallbacks()
