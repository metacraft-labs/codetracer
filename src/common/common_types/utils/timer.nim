type
  Timer* = ref object
    point: float
    # The timer also keeps some metadata that help us detect
    # when the process it measures gets replaced.
    currentOpID*: int

proc initTimer*(): Timer =
  Timer(point: 0)

proc startTimer*(self: Timer, operationCount: int) =
  self.point = epochTime()
  self.currentOpID = operationCount

proc stopTimer*(self: Timer) =
  self.point = 0
  self.currentOpID = 0

proc elapsed*(self: Timer): float =
  epochTime() - self.point

# Return elapsed time formatted
proc formatted*(self: Timer): string =
  let elapsed = self.elapsed()
  fmt"{elapsed:.3f}s"

proc compareMetadata*(self: Timer, operationCount: int): bool =
  return self.currentOpID == operationCount
