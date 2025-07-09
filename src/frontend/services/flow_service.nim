import service_imports

proc loadFlow*(self: FlowService, taskId: TaskId) {.async.} =
  # cdebug "flow_service: loadFlow enabled:" & $self.enabledFlow, taskId
  if self.enabledFlow:
    # cdebug "send load-flow"
    self.data.ipc.send "CODETRACER::load-flow", FlowQuery(
      location: self.data.services.debugger.location,
      taskId: taskId)

proc loadFlowShape*(self: FlowService) {.async.} =
  if self.enabledFlow:
    self.data.ipc.send "CODETRACER::load-flow-shape", self.data.services.debugger.location

proc loadStepLines*(self: FlowService, location: Location, count: int) =
  self.data.ipc.send "CODETRACER::load-step-lines", LoadStepLinesArg(
    location: location,
    forwardCount: count,
    backwardCount: count)

proc restart*(self: FlowService) =
  discard
