## sync/action_relay.nim
##
## Action relay — a user action taken in a mirror (a click, a key, a scroll)
## travels to the primary session and runs THERE, on the primary's
## ViewModel. The mirror never runs an action itself: its ViewModels have no
## backend, and the effect of the action (a request, a move) reaches the
## mirror the way everything else does, as the primary's next batch.
##
## Wire format:
##
##   {"type": "action", "session": id, "vm": "<vm>", "action": "<action>", "args": {…}}
##
## `args` are encoded with `std/jsonutils` (`actionArgs`), the same encoder
## the signal registry uses, so an enum, an `Option` or an object crosses as
## it does in a mirrored signal.
##
## THE VIEWPORT is one action, `viewport` / `set`, with the pane and its
## measured rows, depth and first row. It is the single place a mirror's
## measured viewport is mapped onto the primary's ViewModels, so the viewport
## contract (Viewport-Driven-Loading) changes this one arm, not every view.
##
## Only USER actions are relayed. Procs that feed a ViewModel from the backend
## or the host (`setResults`, `applyFlowUpdate`, `setLines`, `setRoot`, …) run
## on the primary's side already and have no business arriving from a view.
##
## Works on both the C and JS backends.

import std/[json, jsonutils, options, sets, tables]

import isonim/core/signals   # `Signal.val`: a pane's held viewport
  # `sets` / `tables`: in scope for `jsonutils`' hooks; see `synced_signals`.

import ../session_vm
import ../store/types as store_types
import ../collab/[codec, reducer, session_core, types as collab_types]
import ../viewmodels/[
  calltrace_vm,
  debug_controls_vm,
  editor_vm,
  event_log_vm,
  filesystem_vm,
  flow_vm,
  point_list_vm,
  scratchpad_vm,
  search_results_vm,
  search_vm,
  state_vm,
  terminal_output_model,
  terminal_output_vm,
  timeline_vm,
  trace_log_vm,
]

const
  EncodeOptions = ToJsonOptions(enumMode: joptEnumString)
  DecodeOptions = Joptions(allowMissingKeys: true, allowExtraKeys: true)

# ---------------------------------------------------------------------------
# Mirror side
# ---------------------------------------------------------------------------

proc actionArg*[T](value: T): JsonNode =
  ## Encode one action argument as the primary decodes it.
  toJson(value, EncodeOptions)

proc serializeAction*(vm: string; action: string;
                      args: JsonNode = newJObject();
                      sessionId = ""): JsonNode =
  ## An action message for the primary session `sessionId`.
  %*{"type": "action", "session": sessionId, "vm": vm, "action": action,
     "args": (if args.isNil: newJObject() else: args)}

proc viewportAction*(pane: string; rows: int; depth = 0; firstRow = -1;
                     sessionId = ""): JsonNode =
  ## The mirror's measured viewport for `pane`: `rows` visible rows, `depth`
  ## levels of nesting the width affords (the call trace), and the first row
  ## shown (`-1`: unchanged).
  serializeAction("viewport", "set",
                  %*{"pane": pane, "rows": rows, "depth": depth,
                     "firstRow": firstRow}, sessionId)

# ---------------------------------------------------------------------------
# Primary side
# ---------------------------------------------------------------------------

proc arg[T](args: JsonNode; name: string; fallback: T): T =
  ## Decode `args[name]` as a `T`; `fallback` when it is absent or does not
  ## decode, so a malformed action is ignored rather than raising on the
  ## primary.
  result = fallback
  if args.isNil or args.kind != JObject or not args.hasKey(name):
    return
  try:
    fromJson(result, args[name], DecodeOptions)
  except CatchableError, AssertionDefect:
    result = fallback

proc applyViewport(session: SessionViewModel; args: JsonNode): bool =
  let rows = args.arg("rows", 0)
  let depth = args.arg("depth", 0)
  let firstRow = args.arg("firstRow", -1)
  # Each pane's ONE size report (Viewport-Driven-Loading V1): a field the
  # mirror did not send keeps the value the primary already holds.
  proc merged(held: Viewport): Viewport =
    result = held
    if rows > 0: result.rows = rows
    if depth > 0: result.cols = depth
    if firstRow >= 0: result.firstRow = firstRow
  case args.arg("pane", "")
  of "calltrace":
    let vm = session.calltraceVM
    if vm.isNil: return false
    vm.setViewport(merged(vm.viewport.val))
    true
  of "eventLog":
    let vm = session.eventLogVM
    if vm.isNil: return false
    vm.setViewport(merged(vm.viewport.val))
    true
  of "terminalOutput":
    let vm = session.terminalOutputVM
    if vm.isNil: return false
    vm.setViewport(merged(vm.viewport.val))
    true
  of "state":
    let vm = session.stateVM
    if vm.isNil: return false
    vm.setViewport(merged(vm.viewport.val))
    true
  of "traceLog":
    let vm = session.traceLogVM
    if vm.isNil: return false
    vm.setViewport(merged(vm.viewport.val))
    true
  else:
    false

proc applyAction*(session: SessionViewModel; msg: JsonNode): bool =
  ## Run the action `msg` names on `session`'s ViewModel. `true` when it was
  ## a known action of a ViewModel the session has; anything else is ignored,
  ## so an older primary keeps working against a newer mirror.
  if session.isNil or msg.isNil or msg.kind != JObject:
    return false
  let vm = msg{"vm"}.getStr("")
  let action = msg{"action"}.getStr("")
  let a = msg{"args"}
  result = true
  case vm
  of "viewport":
    return action == "set" and session.applyViewport(a)

  of "collab":
    # A view operation a mirror's own ViewModel performed — a tab chosen, a
    # row expanded, a watch added — on the shared view state its
    # collaboration core keeps (`mirror_session.relayViewOps`). The primary
    # applies it as it applies a peer's, and the result reaches every mirror
    # as the primary's next batch.
    if action != "viewop" or session.collabCore.isNil:
      return false
    var op: collab_types.ViewOpEnvelope
    try:
      op = parseViewOpEnvelope(a)
    except CatchableError:
      return false
    # The mirror's collaboration core is its own document, with its own
    # session id; the operation was sent to THIS session (the relay names
    # it), so it is applied as one of this document's.
    op.sessionId = session.collabCore.document.state.sessionId
    return session.collabCore.applyRemoteViewOp(op).status != asRejected

  of "calltrace":
    let v = session.calltraceVM
    if v.isNil: return false
    case action
    of "scroll":
      v.setViewport(v.viewport.val.scrolledTo(a.arg("position", 0)))
    of "selectEntry": v.selectEntry(a.arg("lineIndex", none(int64)))
    of "toggleExpand": v.toggleExpand(a.arg("lineIndex", 0'i64))
    of "toggleExpandCallChildren":
      v.toggleExpandCallChildren(a.arg("lineIndex", 0'i64))
    of "doubleClickEntry": v.doubleClickEntry(a.arg("lineIndex", 0'i64))
    of "setSearchQuery": v.setSearchQuery(a.arg("query", ""))
    of "setRawIgnorePatterns": v.setRawIgnorePatterns(a.arg("patterns", ""))
    of "selectCall": v.selectCall(a.arg("callKey", ""))
    of "jumpToSearchResult": v.jumpToSearchResult(a.arg("index", 0))
    # Kept for mirrors that predate the `viewport` action.
    of "setViewportHeight":
      v.setViewport(v.viewport.val.withRows(a.arg("height", 0)))
    of "setViewportDepth":
      v.setViewport(v.viewport.val.withCols(a.arg("depth", 0)))
    else: return false

  of "state":
    let v = session.stateVM
    if v.isNil: return false
    case action
    of "selectTab": v.selectTab(a.arg("tab", stLocals))
    of "toggleExpand": v.toggleExpand(a.arg("path", ""))
    of "selectPath": v.selectPath(a.arg("path", ""))
    of "addWatch": v.addWatch(a.arg("expression", ""))
    of "removeWatch": v.removeWatch(a.arg("expression", ""))
    of "editWatch": v.editWatch(a.arg("old", ""), a.arg("expression", ""))
    of "toggleHistory": v.toggleHistory(a.arg("expression", ""))
    of "onShowOrigin":
      v.onShowOrigin(a.arg("expression", ""),
                     a.arg("location", store_types.Location()))
    of "jumpToHistoryEntry": v.jumpToHistoryEntry(a.arg("ticks", 0'i64))
    of "loadMore": v.loadMore(a.arg("path", ""))
    else: return false

  of "debugControls":
    let v = session.debugControlsVM
    if v.isNil: return false
    case action
    of "stepForward": v.stepForward()
    of "stepBackward": v.stepBackward()
    of "stepIn": v.stepIn()
    of "stepOut": v.stepOut()
    of "continueExecution": v.continueExecution()
    of "reverseContinue": v.reverseContinue()
    of "reverseStepIn": v.reverseStepIn()
    of "reverseStepOut": v.reverseStepOut()
    of "restoreAt": v.restoreAt(a.arg("rrTicks", 0'u64))
    of "jumpToLive": v.jumpToLive()
    of "invokeToolbarStep": v.invokeToolbarStep(a.arg("actionId", ""))
    else: return false

  of "eventLog":
    let v = session.eventLogVM
    if v.isNil: return false
    case action
    of "selectRow": v.selectRow(a.arg("row", none(int)))
    of "doubleClickRow": v.doubleClickRow(a.arg("row", 0))
    of "nextPage": v.nextPage()
    of "prevPage": v.prevPage()
    of "sort": v.sort(a.arg("column", 0))
    of "sortBy": v.sortBy(a.arg("order", EventLogOrder()))
    of "toggleColumnsMenu": v.toggleColumnsMenu()
    of "setSearchQuery": v.setSearchQuery(a.arg("query", ""))
    of "setFilterInput": v.setFilterInput(a.arg("raw", ""))
    of "dismissToast": v.dismissToast(a.arg("workspaceId", ""))
    # Kept for mirrors that predate the `viewport` action.
    of "setPageSize":
      v.setViewport(v.viewport.val.withRows(a.arg("size", 0)))
    else: return false

  of "flow":
    let v = session.flowVM
    if v.isNil: return false
    case action
    of "setMode": v.setMode(a.arg("mode", FlowMode.low))
    of "selectIteration": v.selectIteration(a.arg("iteration", 0))
    of "stepIterationForward": v.stepIterationForward()
    of "stepIterationBackward": v.stepIterationBackward()
    of "hoverStep": v.hoverStep(a.arg("step", none(int)))
    of "clickStep": v.clickStep(a.arg("step", 0))
    of "toggleRawValues": v.toggleRawValues()
    else: return false

  of "editor":
    let v = session.editorVM
    if v.isNil: return false
    case action
    of "switchTab": v.switchTab(a.arg("index", 0))
    of "closeTab": v.closeTab(a.arg("index", 0))
    of "setCursor": v.setCursor(a.arg("line", 0), a.arg("column", 0))
    of "toggleFlowOverlay": v.toggleFlowOverlay()
    of "toggleBreakpointGutter": v.toggleBreakpointGutter()
    else: return false

  of "timeline":
    let v = session.timelineVM
    if v.isNil: return false
    case action
    of "seek": v.seek(a.arg("tick", 0'u64))
    of "seekAtFraction": v.seekAtFraction(a.arg("fraction", 0.0))
    of "zoom": v.zoom(a.arg("level", 1.0))
    of "pan": v.pan(a.arg("startTick", 0'u64), a.arg("endTick", 0'u64))
    of "hover": v.hover(a.arg("tick", none(uint64)))
    of "hoverAtFraction": v.hoverAtFraction(a.arg("fraction", 0.0))
    else: return false

  of "terminalOutput":
    let v = session.terminalOutputVM
    if v.isNil: return false
    case action
    of "setView": v.setView(a.arg("view", tvLines))
    of "toggleView": v.toggleView()
    of "jumpToEvent": v.jumpToEvent(a.arg("eventIndex", 0))
    of "jumpToWrite": v.jumpToWrite(a.arg("write", 0))
    of "scrubTo": v.scrubTo(a.arg("write", 0))
    of "cancelScrub": v.cancelScrub()
    else: return false

  of "traceLog":
    let v = session.traceLogVM
    if v.isNil: return false
    case action
    of "selectEntry": v.selectEntry(a.arg("index", 0))
    of "jumpToEntry": v.jumpToEntry(a.arg("index", 0))
    else: return false

  of "scratchpad":
    let v = session.scratchpadVM
    if v.isNil: return false
    case action
    of "removeValue": v.removeValue(a.arg("index", 0))
    of "clearValues": v.clearValues()
    of "removeChain": v.removeChain(a.arg("index", 0))
    of "clearChains": v.clearChains()
    of "toggleExpand": v.toggleExpand(a.arg("path", ""))
    of "addFromExpression": v.addFromExpression(a.arg("expression", ""))
    of "addValue": v.addValue(a.arg("entry", store_types.ScratchpadValueEntry()))
    else: return false

  of "fileTree":
    let v = session.fileTreeVM
    if v.isNil: return false
    case action
    of "toggleExpanded": v.toggleExpanded(a.arg("path", ""))
    of "expandPath": v.expandPath(a.arg("path", ""))
    of "collapsePath": v.collapsePath(a.arg("path", ""))
    of "expandToFile": v.expandToFile(a.arg("filePath", ""))
    of "openFile": v.openFile(a.arg("path", ""))
    else: return false

  of "searchResults":
    let v = session.searchResultsVM
    if v.isNil: return false
    case action
    of "setQuery": v.setQuery(a.arg("query", ""))
    of "search": v.search(a.arg("query", ""))
    of "toggleOption": v.toggleOption(a.arg("which", soCase))
    of "selectResult": v.selectResult(a.arg("index", 0))
    of "setActive": v.setActive(a.arg("on", false))
    else: return false

  of "search":
    let v = session.searchVM
    if v.isNil: return false
    case action
    of "setMode": v.setMode(a.arg("mode", smCommand))
    of "setQuery": v.setQuery(a.arg("query", ""))
    of "selectResult": v.selectResult(a.arg("index", none(int)))
    of "toggleResults": v.toggleResults()
    else: return false

  of "pointList":
    let v = session.pointListVM
    if v.isNil: return false
    case action
    of "selectPoint": v.selectPoint(a.arg("index", none(int)))
    of "startEditing": v.startEditing(a.arg("index", 0))
    of "stopEditing": v.stopEditing()
    else: return false

  else:
    return false
