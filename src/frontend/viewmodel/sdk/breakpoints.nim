## viewmodel/sdk/breakpoints.nim — THE ONE PRODUCER OF BREAKPOINTS, for every
## front-end.
##
## A breakpoint is on the point list because the ENGINE bound it (PLAT-40):
## every change is a `setBreakpoints` request for the file's whole set, and
## the rows the store holds for that file are replaced by what the engine
## answered (`ReplayDataStore.applyVerifiedBreakpoints`). The terminal and
## GPUI reach the engine through `HeadlessDebugSession`, which sends
## synchronously; the desktop and the web send through the session store's
## `BackendService` (`requestBreakpoints`). Both plan the change with the
## procs here, so a gutter click, a menu entry or a program-menu command
## means the same set on every front-end.
##
## DAP's `setBreakpoints` REPLACES the source's whole set
## (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetBreakpoints),
## so every plan is the file's complete set after the change, never a delta.
## A DISABLED breakpoint is not sent — the engine holds only the armed ones —
## and stays a row of the point list until it is deleted (PLAT-50).

import std/[json, options]
from std/os import extractFilename

import isonim/core/signals
from isonim/core/async_compat import nil

import ../backend/backend_service
import ../store/[replay_data_store, types]

export BreakpointSpec

proc heldBreakpoints*(store: ReplayDataStore; path: string): seq[BreakpointSpec] =
  ## `path`'s breakpoints as the store holds them, armed and disabled, with
  ## their columns, conditions and log messages.
  if store.isNil:
    return
  for r in store.pointList.rows.val:
    if r.kind == PointKindBreakpoint and r.path == path and r.line >= 1:
      result.add BreakpointSpec(line: r.line, column: r.column,
                                condition: r.condition,
                                logMessage: r.logMessage, enabled: r.enabled)

func breakpointAt*(held: openArray[BreakpointSpec];
                   line: int): Option[BreakpointSpec] =
  ## The breakpoint on `line`, armed or not.
  for sp in held:
    if sp.line == line:
      return some(sp)
  none(BreakpointSpec)

proc breakpointAt*(store: ReplayDataStore; path: string;
                   line: int): Option[BreakpointSpec] =
  breakpointAt(store.heldBreakpoints(path), line)

func plannedToggle*(held: openArray[BreakpointSpec];
                    line: int): seq[BreakpointSpec] =
  ## A press on the glyph column: the breakpoint on `line` removed if there is
  ## one (armed or not, line or column, as VS Code's glyph click removes every
  ## breakpoint on the line), else a whole-line breakpoint added. Every other
  ## line is kept as it is. The engine binds one breakpoint per line.
  var removing = false
  for sp in held:
    if sp.line == line: removing = true
    else: result.add sp
  if not removing:
    result.add BreakpointSpec(line: line, enabled: true)

func plannedAnchored*(held: openArray[BreakpointSpec]; line, column: int;
                      condition = ""; logMessage = ""): seq[BreakpointSpec] =
  ## A breakpoint at `line` anchored at `column` (Column-Aware Navigation M6),
  ## with an optional condition (M9) or log message (M10). It REPLACES whatever
  ## the line had (the engine binds one breakpoint per line) and is never a
  ## toggle.
  for sp in held:
    if sp.line != line: result.add sp
  result.add BreakpointSpec(line: line, column: max(0, column),
                            condition: condition, logMessage: logMessage,
                            enabled: true)

func plannedInlineToggle*(held: openArray[BreakpointSpec];
                          line, column: int): seq[BreakpointSpec] =
  ## `toggle-inline-breakpoint` at a caret on column 2 or later: the column
  ## breakpoint there removed if the line has one, else one put there in place
  ## of whatever the line had (Editor-Pane.md § Inline breakpoints).
  for sp in held:
    if sp.line == line and sp.column == column:
      for other in held:
        if other.line != line: result.add other
      return
  result = plannedAnchored(held, line, column)

func inlineBreakpointPlan*(held: openArray[BreakpointSpec]; line, column,
                           lineMaxColumn: int;
                           columnsSupported = true): seq[BreakpointSpec] =
  ## The one rule for the caret's column, every front-end's: clamped to the
  ## line's last column; column 1 is a line breakpoint (Column-Aware M6's
  ## invariant), and so is every column when the recorder does not advertise
  ## column breakpoints.
  var col = max(1, column)
  if lineMaxColumn >= 1:
    col = min(col, lineMaxColumn)
  if col < 2 or not columnsSupported:
    plannedToggle(held, line)
  else:
    plannedInlineToggle(held, line, col)

func columnBreakpointAt*(held: openArray[BreakpointSpec];
                         line, column: int): bool =
  ## Whether a column breakpoint is bound there: the menu's Add / Remove.
  for sp in held:
    if sp.line == line and sp.column == column and column >= 2:
      return true

func plannedEnabled*(held: openArray[BreakpointSpec]; line: int;
                     enabled: bool): Option[seq[BreakpointSpec]] =
  ## The breakpoint on `line` armed or disarmed, everything else kept; `none`
  ## when the line has no breakpoint (a right-click on an empty gutter slot
  ## does nothing). Its line breakpoint when it has one, which a column
  ## breakpoint on the same line does not follow.
  var found = false
  var plan: seq[BreakpointSpec] = @[]
  let target = breakpointAt(held, line)
  for sp in held:
    var s = sp
    if target.isSome and s.line == line and s.column == target.get.column:
      found = true
      s.enabled = enabled
    plan.add s
  if found: some(plan) else: none(seq[BreakpointSpec])

proc setBreakpointsArgs*(path: string; plan: openArray[BreakpointSpec]): JsonNode =
  ## The `setBreakpoints` arguments for `path`'s planned set: the ARMED
  ## breakpoints only, each with its column (M1), condition (M9) and log
  ## message (M10) when it has one.
  var bps = newJArray()
  var lines = newJArray()
  for sp in plan:
    if not sp.enabled:
      continue
    var bp = %*{"line": sp.line}
    if sp.column > 0: bp["column"] = %sp.column
    if sp.condition.len > 0: bp["condition"] = %sp.condition
    if sp.logMessage.len > 0: bp["logMessage"] = %sp.logMessage
    bps.add bp
    lines.add %sp.line
  %*{"source": {"name": extractFilename(path), "path": path},
     "breakpoints": bps, "lines": lines}

proc answeredBreakpoints*(plan: openArray[BreakpointSpec];
                          body: JsonNode): seq[BreakpointSpec] =
  ## `path`'s set after the engine answered `setBreakpointsArgs(plan)`:
  ## each armed breakpoint the engine VERIFIED, at the line it bound (and,
  ## for an anchored one, the column it echoes), and every disabled one as it
  ## was. An armed breakpoint the engine did not verify is not held — it
  ## would never stop.
  var answers: seq[JsonNode] = @[]
  if not body.isNil and body.kind == JObject:
    answers = body.getOrDefault("breakpoints").getElems
  var i = 0
  for sp in plan:
    if not sp.enabled:
      result.add sp
      continue
    let at = i
    inc i
    if at >= answers.len:
      continue
    let bp = answers[at]
    if not bp.getOrDefault("verified").getBool(false):
      continue
    var bound = sp
    bound.line = bp.getOrDefault("line").getInt(sp.line)
    if sp.column > 0:
      bound.column = bp.getOrDefault("column").getInt(sp.column)
    result.add bound

proc requestBreakpoints*(store: ReplayDataStore; path: string;
                         plan: seq[BreakpointSpec];
                         onDone: proc(applied: bool) = nil) =
  ## Hold `plan` as `path`'s set at once (resolution `requested`), send it
  ## through the session's backend and, when the engine answers, make the
  ## store's rows for `path` what it verified (`applyVerifiedBreakpoints`).
  ##
  ## HELD BEFORE THE ANSWER, because a breakpoint belongs to the project and
  ## not to the session (Mode-Transitions.md §5): the gutter accepts one in
  ## Edit mode, where no engine answers, and the next session sends it
  ## (`resendBreakpoints`). A refused or failed request leaves the requested
  ## set standing; `onDone` (optional) learns whether the engine answered.
  if store.isNil:
    if not onDone.isNil: onDone(false)
    return
  store.applyVerifiedBreakpoints(path, plan, resolution = "requested")
  if store.backend.isNil:
    if not onDone.isNil: onDone(false)
    return
  let theStore = store
  let thePath = path
  let thePlan = plan
  async_compat.onComplete(
    store.backend.send("setBreakpoints", setBreakpointsArgs(path, plan)),
    proc(response: JsonNode) =
      let ok = responseSucceeded(response)
      if ok:
        theStore.applyVerifiedBreakpoints(thePath,
          answeredBreakpoints(thePlan, responseBody(response)))
      if not onDone.isNil: onDone(ok),
    proc(message: string) =
      if not onDone.isNil: onDone(false))

# ---------------------------------------------------------------------------
# The operations, over a session store
# ---------------------------------------------------------------------------

proc toggleBreakpoint*(store: ReplayDataStore; path: string; line: int) =
  ## A gutter click (`plannedToggle`).
  store.requestBreakpoints(path, plannedToggle(store.heldBreakpoints(path), line))

proc setAnchoredBreakpoint*(store: ReplayDataStore; path: string;
                            line, column: int; condition = "";
                            logMessage = "") =
  ## A column breakpoint (M6/M9) or a column logpoint (M10)
  ## (`plannedAnchored`).
  store.requestBreakpoints(path, plannedAnchored(store.heldBreakpoints(path),
    line, column, condition, logMessage))

proc toggleInlineBreakpoint*(store: ReplayDataStore; path: string; line, column,
                             lineMaxColumn: int; columnsSupported = true) =
  ## Shift+F9 and the context menu's inline entry, at the caret.
  store.requestBreakpoints(path, inlineBreakpointPlan(
    store.heldBreakpoints(path), line, column, lineMaxColumn, columnsSupported))

proc setBreakpointEnabled*(store: ReplayDataStore; path: string; line: int;
                           enabled: bool): bool =
  ## Arm or disarm the breakpoint on `line`; false (nothing sent) when the
  ## line has none.
  let plan = plannedEnabled(store.heldBreakpoints(path), line, enabled)
  if plan.isNone:
    return false
  store.requestBreakpoints(path, plan.get)
  true

proc deleteBreakpoint*(store: ReplayDataStore; path: string; line: int): bool =
  ## Remove the breakpoint on `line` — never a toggle: false (nothing sent)
  ## when the line has none.
  let held = store.heldBreakpoints(path)
  if breakpointAt(held, line).isNone:
    return false
  store.requestBreakpoints(path, plannedToggle(held, line))
  true

proc breakpointFiles*(store: ReplayDataStore; path = ""): seq[string] =
  ## Every file the store holds a breakpoint in, in row order — or only
  ## `path`, when it names one that has any.
  if store.isNil:
    return
  for r in store.pointList.rows.val:
    if r.kind == PointKindBreakpoint and r.path notin result and
       (path.len == 0 or r.path == path):
      result.add r.path

proc clearBreakpoints*(store: ReplayDataStore; path = "") =
  ## Delete every breakpoint of `path`, or of every file when `path` is "":
  ## one `setBreakpoints` with none per file.
  for p in store.breakpointFiles(path):
    store.requestBreakpoints(p, @[])

proc setAllBreakpointsEnabled*(store: ReplayDataStore; enabled: bool;
                               path = "") =
  ## Arm or disarm every breakpoint of `path` (every file when ""), one
  ## request per file whose set changes.
  for p in store.breakpointFiles(path):
    var plan = store.heldBreakpoints(p)
    var changing = false
    for sp in plan.mitems:
      if sp.enabled != enabled:
        sp.enabled = enabled
        changing = true
    if changing:
      store.requestBreakpoints(p, plan)

proc resendBreakpoints*(store: ReplayDataStore) =
  ## Send every file's held set again — for an engine that restarted and
  ## holds none of them (the desktop's subsystem restart).
  for p in store.breakpointFiles():
    store.requestBreakpoints(p, store.heldBreakpoints(p))
