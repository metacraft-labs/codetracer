## sync/action_relay.nim
##
## Action relay — serializes user actions from the view (mirror) process
## and applies them on the primary process's SessionViewModel.
##
## In the multi-process architecture, the view process captures user
## interactions (button clicks, scroll, search queries) and serializes
## them as JSON. The primary process receives these and calls the
## appropriate ViewModel action procs.
##
## The action relay is OPTIONAL: in same-process mode, actions call
## ViewModel procs directly without serialization.
##
## Wire format:
##   ```json
##   {"type": "action", "vm": "<vm-name>", "action": "<action-name>", "args": {...}}
##   ```
##
## Usage:
##   # View side — serialize an action
##   let msg = serializeAction("debugControls", "stepForward")
##   transport.send($msg)
##
##   # Primary side — apply the action
##   applyAction(session, parsedMsg)

import std/[json, options]

import signal_serializer  # for SessionViewModel forward decl
import ../store/[replay_data_store, types]
import ../viewmodels/[
  calltrace_vm,
  state_vm,
  debug_controls_vm,
  event_log_vm,
  search_vm,
]

# Re-export the SessionViewModel type from signal_serializer so that
# callers of action_relay can use it without importing signal_serializer
# directly.
export signal_serializer.SessionViewModel

# ---------------------------------------------------------------------------
# Full SessionViewModel with VM references (needed for action dispatch)
# ---------------------------------------------------------------------------

type
  FullSessionViewModel* = ref object
    ## Extended session reference that includes panel ViewModels.
    ## Used by applyAction to dispatch actions to the correct VM.
    ##
    ## This mirrors session_vm.SessionViewModel but avoids a circular
    ## import. The caller constructs it from the real SessionViewModel.
    store*: ReplayDataStore
    calltraceVM*: CalltraceVM
    stateVM*: StateVM
    debugControlsVM*: DebugControlsVM
    eventLogVM*: EventLogVM
    searchVM*: SearchVM

# ---------------------------------------------------------------------------
# Action serialization (view side)
# ---------------------------------------------------------------------------

proc serializeAction*(vm: string, action: string,
                      args: JsonNode = %*{}): JsonNode =
  ## Create an action message for transmission to the primary process.
  ## The `vm` identifies which ViewModel handles the action, `action`
  ## is the method name, and `args` carries any parameters.
  %*{"type": "action", "vm": vm, "action": action, "args": args}

# ---------------------------------------------------------------------------
# Action dispatch (primary side)
# ---------------------------------------------------------------------------

proc applyAction*(session: FullSessionViewModel, msg: JsonNode) =
  ## Execute a user action on the primary SessionViewModel.
  ##
  ## Dispatches on the "vm" and "action" keys to call the correct
  ## ViewModel action proc. Unknown vm/action combinations are silently
  ## ignored for forward compatibility.
  let vmName = msg["vm"].getStr
  let action = msg["action"].getStr
  let args = msg{"args"}

  case vmName
  of "calltrace":
    case action
    of "scroll":
      session.calltraceVM.scroll(args["position"].getBiggestInt.int64)
    of "selectEntry":
      if args["lineIndex"].kind == JNull:
        session.calltraceVM.selectEntry(none(int64))
      else:
        session.calltraceVM.selectEntry(some(args["lineIndex"].getBiggestInt.int64))
    of "toggleExpand":
      session.calltraceVM.toggleExpand(args["lineIndex"].getBiggestInt.int64)
    of "doubleClickEntry":
      session.calltraceVM.doubleClickEntry(args["lineIndex"].getBiggestInt.int64)
    of "setSearchQuery":
      session.calltraceVM.setSearchQuery(args["query"].getStr)
    of "setViewportHeight":
      session.calltraceVM.setViewportHeight(args["height"].getInt)
    of "setViewportDepth":
      session.calltraceVM.setViewportDepth(args["depth"].getInt)
    of "setRawIgnorePatterns":
      session.calltraceVM.setRawIgnorePatterns(args["patterns"].getStr)
    else: discard

  of "state":
    case action
    of "selectTab":
      # Parse the StateTab enum from its string representation.
      case args["tab"].getStr
      of "stLocals": session.stateVM.selectTab(stLocals)
      of "stGlobals": session.stateVM.selectTab(stGlobals)
      of "stWatches": session.stateVM.selectTab(stWatches)
      else: discard
    of "toggleExpand":
      session.stateVM.toggleExpand(args["path"].getStr)
    of "selectPath":
      session.stateVM.selectPath(args["path"].getStr)
    of "addWatch":
      session.stateVM.addWatch(args["expression"].getStr)
    of "removeWatch":
      session.stateVM.removeWatch(args["expression"].getStr)
    else: discard

  of "debugControls":
    case action
    of "stepForward": session.debugControlsVM.stepForward()
    of "stepBackward": session.debugControlsVM.stepBackward()
    of "stepIn": session.debugControlsVM.stepIn()
    of "stepOut": session.debugControlsVM.stepOut()
    of "continueExecution": session.debugControlsVM.continueExecution()
    of "reverseContinue": session.debugControlsVM.reverseContinue()
    of "reverseStepIn": session.debugControlsVM.reverseStepIn()
    of "reverseStepOut": session.debugControlsVM.reverseStepOut()
    else: discard

  of "eventLog":
    case action
    of "selectRow":
      if args["row"].kind == JNull:
        session.eventLogVM.selectRow(none(int))
      else:
        session.eventLogVM.selectRow(some(args["row"].getInt))
    of "doubleClickRow":
      session.eventLogVM.doubleClickRow(args["row"].getInt)
    of "nextPage": session.eventLogVM.nextPage()
    of "prevPage": session.eventLogVM.prevPage()
    of "sort":
      session.eventLogVM.sort(args["column"].getInt)
    of "setSearchQuery":
      session.eventLogVM.setSearchQuery(args["query"].getStr)
    of "setPageSize":
      session.eventLogVM.setPageSize(args["size"].getInt)
    else: discard

  of "search":
    case action
    of "setMode":
      case args["mode"].getStr
      of "smCommand": session.searchVM.setMode(smCommand)
      of "smFile": session.searchVM.setMode(smFile)
      of "smFindInFiles": session.searchVM.setMode(smFindInFiles)
      of "smFindSymbol": session.searchVM.setMode(smFindSymbol)
      else: discard
    of "setQuery":
      session.searchVM.setQuery(args["query"].getStr)
    of "selectResult":
      if args["index"].kind == JNull:
        session.searchVM.selectResult(none(int))
      else:
        session.searchVM.selectResult(some(args["index"].getInt))
    of "toggleResults":
      session.searchVM.toggleResults()
    else: discard

  else: discard
