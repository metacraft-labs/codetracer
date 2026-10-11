## CI run state file management.
##
## Persists the active CI run context to disk so that commands like
## ``ct ci exec``, ``ct ci log``, ``ct ci finish`` can operate without
## requiring the run ID to be passed explicitly every time.
##
## State file location (in priority order):
## 1. ``$CODETRACER_STATE_DIR/ci-run.json``
## 2. ``$HOME/.codetracer-ci/ci-run.json``

import std/[json, os]
import ../../common/ct_home

type
  CIRunState* = object
    ## Serialisable state for the currently active CI run.
    runId*: string
    tenantId*: string
    baseUrl*: string
    token*: string
    sequenceCounter*: int

  CIStateError* = object of CatchableError
    ## Raised when state operations fail (missing file, corrupt JSON, etc.).

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc stateDir*(): string =
  ## Returns the directory where the CI state file is stored.
  let envDir = getEnv("CODETRACER_STATE_DIR", "")
  if envDir.len > 0:
    return envDir
  # `$CODETRACER_HOME/state/ci` relocates it with every other per-user location.
  let ctHomeState = ctHomeArea(chaState)
  if ctHomeState.len > 0:
    return ctHomeState / "ci"
  return getHomeDir() / ".codetracer-ci"

proc stateFilePath(): string =
  stateDir() / "ci-run.json"

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc hasActiveRun*(): bool =
  ## Returns true if a CI run state file exists on disk.
  fileExists(stateFilePath())

proc loadState*(): CIRunState =
  ## Loads the active run state from disk.
  ## Raises ``CIStateError`` if no state file exists or it is corrupt.
  let path = stateFilePath()
  if not fileExists(path):
    raise newException(CIStateError,
      "No active CI run. Start one with 'ct ci start' or attach with 'ct ci attach <runId>'.")
  try:
    let content = readFile(path)
    let node = parseJson(content)
    result = CIRunState(
      runId: node["runId"].getStr(),
      tenantId: node["tenantId"].getStr(),
      baseUrl: node["baseUrl"].getStr(),
      token: node["token"].getStr(),
      sequenceCounter: node["sequenceCounter"].getInt(),
    )
  except JsonParsingError as e:
    raise newException(CIStateError,
      "Corrupt CI state file at " & path & ": " & e.msg)
  except KeyError as e:
    raise newException(CIStateError,
      "Missing field in CI state file at " & path & ": " & e.msg)

proc saveState*(state: CIRunState) =
  ## Persists the run state to disk, creating the directory if needed.
  let dir = stateDir()
  if not dirExists(dir):
    createDir(dir)
  let node = %*{
    "runId": state.runId,
    "tenantId": state.tenantId,
    "baseUrl": state.baseUrl,
    "token": state.token,
    "sequenceCounter": state.sequenceCounter,
  }
  writeFile(stateFilePath(), $node)

proc clearState*() =
  ## Removes the state file, ending the active run context.
  let path = stateFilePath()
  if fileExists(path):
    removeFile(path)
