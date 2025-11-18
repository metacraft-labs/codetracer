const
  MinCheckIntervalMs* = 1_000
  MaxCheckIntervalMs* = 5_000

proc idleCheckInterval*(timeoutMs: int): int =
  ## Compute a polling interval for idle checks.
  ## Returns -1 when disabled (timeout < 0).
  if timeoutMs < 0:
    return -1
  let half = timeoutMs div 2
  if half < MinCheckIntervalMs:
    return MinCheckIntervalMs
  if half > MaxCheckIntervalMs:
    return MaxCheckIntervalMs
  return half

proc shouldExitIdle*(socketAttached: bool, lastConnectionMs: int, lastActivityMs: int,
                     nowMs: int, timeoutMs: int): bool =
  ## Decide whether the idle timeout condition has been reached.
  if timeoutMs < 0:
    return false
  let sinceConnection = nowMs - lastConnectionMs
  let sinceActivity = nowMs - lastActivityMs
  if socketAttached:
    return sinceActivity >= timeoutMs
  else:
    return sinceConnection >= timeoutMs
