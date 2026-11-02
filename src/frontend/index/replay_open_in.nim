## replay_open_in.nim — the desktop's half of the ONE `replay-open-in`
## document (`Test-Results-Pane.md` §9.3), in Electron's main process.
##
## The terminal and GPUI read and write `replay-open-in` in their native state
## root themselves (`viewmodel/host/native_test_host`). The desktop's renderer
## cannot touch the filesystem, so the main process does it here, at the SAME
## path — `$CODETRACER_TUI_LAYOUT_DIR` when set, else
## `common/ct_home.ctStateDir` (the `table_columns` precedent) — and in the
## same text (`viewmodels/replay_open_setting`):
##
##   * the catalog answer (`ns9_panes.onNs9Panes`) carries the folder's
##     setting (`replayOpenInFor`), so the pane knows it with its tests;
##   * `CODETRACER::replay-open-in-save`: the palette's **Tests: Open
##     Recordings in …** for one workspace, merged over the document's other
##     workspaces and written staged; answered with `CODETRACER::replay-open-in`
##     (`workspace`, `policy`, and `error` when it could not be written).

import
  std / [async, jsffi, os],
  electron_vars,
  ../lib / [jslib, electron_lib],
  ../viewmodel/viewmodels/replay_open_setting,
  ../../common / [ct_home, ct_logging]

const
  ReplayOpenInMessage* = "CODETRACER::replay-open-in"
  NativeStateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"

proc renameSyncJs(oldPath, newPath: cstring)
  {.importjs: "require('fs').renameSync(#, #)".}

proc replayOpenInPath*(): string =
  let override = getEnv(NativeStateDirEnvVar)
  (if override.len > 0: override else: ctStateDir()) / ReplayOpenFileName

proc readReplayOpenText*(): string =
  let path = replayOpenInPath()
  if not fs.existsSync(cstring(path)):
    return ""
  try:
    $fs.readFileSync(cstring(path), cstring"utf8")
  except CatchableError:
    ""

proc replayOpenInFor*(workspace: string): TraceOpenPolicy =
  ## The setting of `workspace`, the default when it has none.
  replayOpenFor(readReplayOpenText(), workspace)

proc onReplayOpenInSave*(sender: js, response: js) {.async.} =
  ## One workspace's `replay-open-in`, written staged.
  let workspace = $cast[cstring](response[cstring"workspace"])
  let (ok, policy) = parsePolicyWord($cast[cstring](response[cstring"policy"]))
  var error = ""
  if not ok:
    error = "unknown value for " & ReplayOpenSettingName
  elif normalWorkspace(workspace).len == 0:
    error = replayOpenNoWorkspaceText()
  else:
    let path = replayOpenInPath()
    try:
      fs.mkdirSync(cstring(path.parentDir), js{recursive: true})
      fs.writeFileSync(cstring(path & ".new"), cstring(
        withReplayOpen(readReplayOpenText(), workspace, policy)))
      renameSyncJs(cstring(path & ".new"), cstring(path))
    except CatchableError as e:
      error = path & ": " & e.msg
      warnPrint "replay-open-in: cannot write ", path, ": ", e.msg
  if mainWindow.isNil:
    return
  mainWindow.webContents.send(cstring(ReplayOpenInMessage), js{
    workspace: cstring(normalWorkspace(workspace)), policy: cstring($policy),
    error: cstring(error)})
