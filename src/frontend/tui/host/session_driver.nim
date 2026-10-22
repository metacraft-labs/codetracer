## host/session_driver.nim — what a native host does after it asks the engine
## for something, in one place for every native host loop.
##
## The terminal (`tui_session.applyOutcome`), GPUI (`gpui/main.nim`) and the
## editors' pane server (Editor-Hosted-Front-Ends E1) each run their own input
## loop, but what follows an input is the same: a navigation consumes the
## `stopped` + `ct/complete-move` pair it produces and then loads the new
## stop's panes; a click on a call-trace row goes to that call; a click on its
## toggle expands or collapses the call's children and reads the section
## again; an origin query waits for its chain. Each loop used to hand-code the
## sequence (Headless-SDK-Front-Ends HSF-S1, deliverable 3). This module is the
## one copy, over `HeadlessDebugSession` and the session's own ViewModels.
##
## RENDERER-FREE AND TOTAL. Nothing here knows a terminal, a window or a
## protocol, and nothing raises: a refused or failed request is returned as a
## message for the host to show, because a host loop that let an exception
## escape would lose the screen it is restoring (see `settleMove`).

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it spawns replay-server.".}

import std/json

import isonim/core/signals   # `Signal.val`, the store's reads

import native_host
from backend/stdio_backend import sendDapRequestNoResponse, drainEvents,
  waitForEvent
import store/types as store_types   # `CallLine`
from viewmodels/calltrace_vm import reloadWindow
from ../app/origin_binding import OriginEventName
from viewmodels/debug_controls_vm import DebugControlsVM, transportAvailable,
  stepForward, stepBackward, stepIn, stepOut, reverseStepIn, reverseStepOut,
  continueExecution, reverseContinue, moveInHistory, HistoryDirection,
  nextHistoryIndex

import viewmodels/point_menu_ops
from store/replay_data_store import setTracepointsEnabled, deleteTracepoint,
  enabledTracepointSpecs
from std/os import extractFilename

export native_host, OriginEventName, point_menu_ops

const
  OriginWaitMs* = 20_000
    ## How long a host waits for that chain before saying none arrived.

type
  PointMenuOutcome* = object
    ## What one Debug-menu point item did, for the host to show.
    performed*: bool
      ## The item changed something (a row, the engine's set, a sweep ran).
      ## False with a `message` saying why not — the item is answered, never
      ## silently inert.
    message*: string
      ## The status line's sentence.
    swept*: seq[TracepointSweepHit]
      ## `pmoRunAllTracepoints`: the sweep's hits, for the host's overlay.
    sweptSpecs*: int
      ## `pmoRunAllTracepoints`: how many tracepoints were swept.

proc performPointMenuOp*(s: HeadlessDebugSession; op: PointMenuOp;
                         path: string; line: int;
                         nextTracepointId: var int): PointMenuOutcome =
  ## THE NATIVE PERFORMER of the program menu's breakpoint and tracepoint
  ## items (M76, codetracer#843) — the terminal's and GPUI's, over the
  ## desktop's semantics (`ui_js.nim`'s `removeBreakpointAtPosition` …
  ## `ui/trace.runTracepoints`): an item that names one point acts on the one
  ## at `path:line`, the editor caret's line; an "All" item acts on every
  ## point of every file.
  ##
  ## `nextTracepointId` is the host's sweep counter: "Run All Tracepoints"
  ## numbers its specs from it and advances it, so the ids of two sweeps
  ## never collide. `pmoAddTracepoint` is the front end's — it opens its own
  ## editor — and is answered here as not performed.
  ##
  ## TOTAL: a refused or failed request is a message, never an exception, on
  ## `session_driver`'s rule (a host loop must not lose its screen).
  let store = s.session.store
  let at = path.extractFilename & ":" & $line
  proc said(performed: bool; message: string): PointMenuOutcome =
    PointMenuOutcome(performed: performed, message: message)
  try:
    case op
    of pmoNone, pmoAddTracepoint:
      said(false, "the front end opens the tracepoint editor")
    of pmoDeleteBreakpoint:
      if s.deleteBreakpointAt(path, line): said(true, "deleted the breakpoint at " & at)
      else: said(false, "there is no breakpoint at " & at)
    of pmoDeleteAllBreakpoints:
      let files = s.clearAllBreakpoints()
      if files > 0: said(true, "deleted the breakpoints in " & $files & " file(s)")
      else: said(false, "there are no breakpoints to delete")
    of pmoEnableBreakpoint, pmoDisableBreakpoint:
      let enable = op == pmoEnableBreakpoint
      let word = if enable: "enabled" else: "disabled"
      if not s.hasBreakpointAt(path, line):
        said(false, "there is no breakpoint at " & at)
      elif s.setBreakpointEnabled(path, line, enable):
        said(true, word & " the breakpoint at " & at)
      else:
        said(false, "the engine refused the breakpoint at " & at)
    of pmoEnableAllBreakpoints, pmoDisableAllBreakpoints:
      let enable = op == pmoEnableAllBreakpoints
      let n = s.setAllBreakpointsEnabled(enable)
      if n > 0:
        said(true, (if enable: "enabled " else: "disabled ") & $n &
                   " breakpoint(s)")
      else:
        said(false, "no breakpoint is " &
                    (if enable: "disabled" else: "enabled"))
    of pmoDeleteTracepoint:
      if store.deleteTracepoint(path, line):
        said(true, "deleted the tracepoint at " & at)
      else: said(false, "there is no tracepoint at " & at)
    of pmoEnableTracepoint, pmoDisableTracepoint:
      let enable = op == pmoEnableTracepoint
      if store.setTracepointsEnabled(path, line, enable) > 0:
        said(true, (if enable: "enabled" else: "disabled") &
                   " the tracepoint at " & at)
      else:
        said(false, "there is no " & (if enable: "disabled" else: "enabled") &
                    " tracepoint at " & at)
    of pmoEnableAllTracepoints, pmoDisableAllTracepoints:
      let enable = op == pmoEnableAllTracepoints
      let n = store.setTracepointsEnabled("", 0, enable, every = true)
      if n > 0:
        said(true, (if enable: "enabled " else: "disabled ") & $n &
                   " tracepoint(s)")
      else:
        said(false, "no tracepoint is " &
                    (if enable: "disabled" else: "enabled"))
    of pmoRunAllTracepoints:
      let specs = store.enabledTracepointSpecs(nextTracepointId)
      if specs.len == 0:
        said(false, "there are no enabled tracepoints to run")
      else:
        nextTracepointId += specs.len
        let hits = s.runTracepoints(specs)
        PointMenuOutcome(performed: true, swept: hits, sweptSpecs: specs.len,
                         message: "ran " & $specs.len & " tracepoint(s): " &
                                  $hits.len & " hit(s)")
  except CatchableError as e:
    said(false, "could not " & $op & ": " & e.msg)


proc settleMove*(s: HeadlessDebugSession): bool =
  ## Consume the `stopped` + `ct/complete-move` pair a navigation command
  ## produces, and push the new position into the store. `false` when the
  ## pair did not arrive (the engine declined the move, or the read's budget
  ## ran out).
  ##
  ## TOTAL: `consumeNextCompleteMove` raises `ValueError` when its message
  ## budget runs out, and a host that let that escape would drop the screen it
  ## is restoring on a command the engine merely declined. The caller sees an
  ## unchanged position instead, which is what the screen shows anyway.
  try:
    s.consumeNextCompleteMove()
    true
  except CatchableError:
    false

proc afterMove*(s: HeadlessDebugSession) =
  ## What every host loads once the debugger has stopped somewhere new: the
  ## per-stop panes through the SDK's stop loader (`loadStopPanes`), and the
  ## call the debugger is in, selected as the desktop selects it on every
  ## move (`selectCurrentCall`).
  discard s.loadStopPanes()
  s.selectCurrentCall()

proc runDebugControl*(s: HeadlessDebugSession; id: string): bool =
  ## A debugger control by its toolbar id, through the ViewModel the
  ## desktop's toolbar calls (`DebugControlsVM`), then the move settled.
  ## `false` when the control is unavailable here (the recording cannot step
  ## backwards, a session is not open) or the move did not arrive.
  ##
  ## The caller decides what to redraw; it calls `afterMove` (or its own
  ## superset of it) when this returns.
  let vm = s.session.debugControlsVM
  if vm.isNil or not vm.transportAvailable(id):
    return false
  case id
  of "run-to-entry":
    # The desktop's "run to entry" is a seek to the recording's first tick,
    # which settles its own move.
    try:
      s.gotoTick(0'u64)
      return true
    except CatchableError:
      return false
  of "next": vm.stepForward()
  of "reverse-next": vm.stepBackward()
  of "step-in": vm.stepIn()
  of "step-out": vm.stepOut()
  of "reverse-step-in": vm.reverseStepIn()
  of "reverse-step-out": vm.reverseStepOut()
  of "continue": vm.continueExecution()
  of "reverse-continue": vm.reverseContinue()
  else: return false
  s.settleMove()

proc historyMove*(s: HeadlessDebugSession; direction: HistoryDirection): bool =
  ## History back or forward through the session's one jump history
  ## (`DebugControlsVM`, the desktop's rule), then the move settled. `false`
  ## when there is no entry that way, or the move did not arrive.
  let vm = s.session.debugControlsVM
  if vm.isNil or nextHistoryIndex(vm.history.val.len, vm.historyIndex.val,
                                  direction) == 0:
    return false
  vm.moveInHistory(direction)
  s.settleMove()

proc heldCallLine(s: HeadlessDebugSession; index: int64;
                  line: var CallLine): bool =
  ## The call-trace line with trace `index`, if the store holds the section
  ## containing it.
  let store = s.session.store
  let at = index - store.calltrace.startLineIndex.val
  let lines = store.calltrace.lines.val
  if at < 0 or at >= lines.len.int64:
    return false
  line = lines[at.int]
  true

proc jumpToCall*(s: HeadlessDebugSession; index: int64): string =
  ## Go to the call at trace `index`, as the desktop's click on a call-trace
  ## row does (`CalltraceVM.doubleClickEntry`'s `ct/calltrace-jump`); the
  ## jump waits for its own move. Returns "" on success, else why not.
  var line: CallLine
  if not s.heldCallLine(index, line):
    return "the call is not in the section held"
  try:
    s.calltraceJumpByLine(line)
    ""
  except CatchableError as e:
    "could not go to the call: " & e.msg

proc toggleCallChildren*(s: HeadlessDebugSession; index: int64): string =
  ## Expand or collapse the children of the call at trace `index` — the
  ## desktop's toggle (`CalltraceVM.toggleExpandCallChildren`: `ct/expand-calls`
  ## or `ct/collapse-calls` for the call's key) — then have the call trace's
  ## ViewModel read the window its pane reported again
  ## (`CalltraceVM.reloadWindow`). Returns "" on success (or when the call has
  ## no children to toggle), else why not.
  var line: CallLine
  if not s.heldCallLine(index, line) or not line.hasChildren:
    return ""
  let collapse = line.isExpanded
  let command = if collapse: "ct/collapse-calls" else: "ct/expand-calls"
  try:
    # FIRE AND FORGET, as the desktop's `backend.send` is: the engine sends
    # no response to `ct/expand-calls` / `ct/collapse-calls` (measured — a
    # blocking `sendDapRequest` never returned), only the changed section
    # the next load reads.
    s.backend.sendDapRequestNoResponse(command, %*{
      "callKey": line.callKey, "nonExpandedKind": 1, "count": 0})
    discard s.backend.drainEvents()
    s.session.calltraceVM.reloadWindow()
    s.settle()
    ""
  except CatchableError as e:
    "could not " & (if collapse: "collapse" else: "expand") &
      " the call: " & e.msg

proc awaitOriginEvent*(s: HeadlessDebugSession;
                       timeoutMs = OriginWaitMs): JsonNode =
  ## Wait for the chain an origin query (`ct/originChain`) asked for. No
  ## `stopped` comes for such a query, so a host must not settle a move here.
  ## nil when no chain arrived within `timeoutMs`; the session's own read
  ## bound is restored either way.
  let saved = s.backend.bound
  if saved.timeoutMs == 0 or saved.timeoutMs > timeoutMs:
    s.backend.bound.timeoutMs = timeoutMs
  try:
    result = s.backend.waitForEvent(OriginEventName)
  except CatchableError:
    result = nil
  s.backend.bound = saved
