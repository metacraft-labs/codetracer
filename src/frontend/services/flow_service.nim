import service_imports

# The flow window is loaded per stop by the session's stop loader
# (`viewmodel/sdk/stop_loader`, pane `spFlow`) and held by the session's
# `FlowVM`.

proc loadStepLines*(self: FlowService, location: Location, count: int) =
  self.data.ipc.send "CODETRACER::load-step-lines", LoadStepLinesArg(
    location: location,
    forwardCount: count,
    backwardCount: count)

proc restart*(self: FlowService) =
  discard
