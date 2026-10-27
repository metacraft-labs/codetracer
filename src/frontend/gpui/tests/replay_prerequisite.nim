## Every real-engine plan suite checks its prerequisite even when invoked
## directly, then pins the same binary into each spawned frontend's environment.
import std/os
import ../../../common/replay_server_path

let previousRevisionRequirement = getEnv("CODETRACER_REQUIRE_REPLAY_REVISION")
putEnv("CODETRACER_REQUIRE_REPLAY_REVISION", "1")
let checkedReplayServer = locateReplayServer()
if previousRevisionRequirement.len > 0:
  putEnv("CODETRACER_REQUIRE_REPLAY_REVISION", previousRevisionRequirement)
else:
  delEnv("CODETRACER_REQUIRE_REPLAY_REVISION")
if checkedReplayServer.len == 0:
  raise newException(IOError, "prerequisite missing: " & missingReplayServerMessage())
putEnv(ReplayServerBinEnv, absolutePath(checkedReplayServer))
