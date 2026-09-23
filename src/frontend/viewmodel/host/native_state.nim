## native_state.nim — where a NATIVE host (the terminal, GPUI) keeps the state
## it writes for itself, and how it writes a small document there.
##
## `$CODETRACER_TUI_LAYOUT_DIR` if set, else `$XDG_STATE_HOME/codetracer`, else
## `~/.local/state/codetracer`. The override keeps PLAT-6's name because it is
## the hook every Tier-2 suite already uses to point a spawned binary at a
## directory of its own; it overrides the whole root, not only the layout.
##
## `tui/host/layout_store.layoutStateRoot` is this function — one root, so a
## preference and a layout written by the same user land beside each other.
##
## Native-only: it asks the environment and the filesystem.

import std/os

const
  NativeStateDirEnvVar* = "CODETRACER_TUI_LAYOUT_DIR"
    ## Overrides the whole state root.
  NativeStateHomeEnvVar* = "XDG_STATE_HOME"
  StagedWriteSuffix* = ".new"

proc nativeStateRoot*(): string =
  let override = getEnv(NativeStateDirEnvVar)
  if override.len > 0:
    return override
  let stateHome = getEnv(NativeStateHomeEnvVar)
  if stateHome.len > 0:
    return stateHome / "codetracer"
  getHomeDir() / ".local" / "state" / "codetracer"

proc writeStaged*(path, text: string): string =
  ## Write `text` to `<path>.new` and rename it onto `path`, so a process
  ## killed mid-write leaves the previous document intact (PLAT-6's rule).
  ## Returns "" on success, else a one-line message naming the path.
  let temp = path & StagedWriteSuffix
  try:
    createDir(path.parentDir)
    writeFile(temp, text)
    moveFile(temp, path)
    ""
  except CatchableError as e:
    try:
      if fileExists(temp):
        removeFile(temp)
    except CatchableError:
      discard
    path & ": " & e.msg
