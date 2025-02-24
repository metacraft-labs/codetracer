import service_imports

proc loadHistory*(self: HistoryService, expression: cstring) {.async.} =
  if self.data.config.history:
    self.data.ipc.send "CODETRACER::load-history", LoadHistoryArg(
      expression: expression,
      location: self.data.services.debugger.location
    )

proc historyJump*(self: HistoryService, event: Location) =
  self.data.ipc.send "CODETRACER::history-jump", event

func restart*(service: HistoryService) =
  discard
