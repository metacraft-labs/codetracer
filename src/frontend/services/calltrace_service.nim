import service_imports, jsconsole

proc restart*(self: CalltraceService) =
  self.calltraceJumps = @[j""]
  # self.searchResults = JsAssoc[cstring, seq[Call]]{}

proc loadCallstack*(self: CalltraceService, codeID: int64, withArgs: bool): Future[seq[Call]] {.async.} =
  # no caching outside of asyncSend for now
  # but cache there
  var id = $codeID & " " & $withArgs
  echo "send load-callstack"
  return await self.data.asyncSend("load-callstack", js{codeID: codeID, withArgs: withArgs}, id, seq[Call])


proc calltraceJump*(self: CalltraceService, location: Location) = # location: Location) = # codeID: int64, functionID: FunctionID, callID: int64) = #: Future[void] =
  var debugger = self.data.services.debugger
  self.nonLocalJump = false # TODO non-local jumps
  debugger.currentOperation = &"calltrace jump {location.functionName} {location.key}"
  #debugger.stableBusy = true
  self.calltraceJumps.add(j(debugger.currentOperation))
  self.data.ipc.send "CODETRACER::calltrace-jump", location
  avgTimePerRRTick(debugger, location.rrTicks)


proc callstackJump*(self: CalltraceService, index: int, functionName: cstring) =
  if functionName != j"" and index > 0:
    self.inCalltraceJump = false
    self.data.services.debugger.stableBusy =true
    inc self.data.services.debugger.operationCount
    self.data.services.debugger.currentOperation = &"callstack jump {index} {functionName}"
    self.data.ipc.send "CODETRACER::callstack-jump", js{index: index, functionName: functionName}

proc searchCalltrace*(self: CalltraceService, query: cstring): Future[seq[Call]] {.async.} =
  return await self.data.asyncSend("search-calltrace", query, $query, seq[Call])

proc loadCallArgs*(self: CalltraceService, calltraceLoadArgs: CalltraceLoadArgs) {.async.} =
  self.data.ipc.send "CODETRACER::load-call-args", calltraceLoadArgs

proc expandCalls*(
    self: CalltraceService,
    callKey: cstring,
    nonExpandedKind: CalltraceNonExpandedKind,
    count: int) =
  let target = CollapseCallsArgs(callKey: callKey, nonExpandedKind: nonExpandedKind, count: count)
  self.data.ipc.send "CODETRACER::expand-calls", target

proc collapseCalls*(
    self: CalltraceService,
    callKey: cstring,
    nonExpandedKind: CalltraceNonExpandedKind,
    count: int) =
  let target = CollapseCallsArgs(callKey: callKey, nonExpandedKind: nonExpandedKind, count: count)
  self.data.ipc.send "CODETRACER::collapse-calls", target
