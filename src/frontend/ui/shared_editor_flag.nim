## ui/shared_editor_flag.nim — which editor the desktop's editor pane draws.
##
## The developer setting `sharedEditor` (`common/config.nim`; off by default,
## `CODETRACER_SHARED_EDITOR=1` / `=0` overrides it for one launch,
## `index/config.loadConfig`) chooses between Monaco and the shared editing
## core (`ui/shared_editor`). The command palette's **Developer: Toggle Shared
## Editor** flips it in a running window (`setSharedEditorOverride`); the
## editor pane then re-mounts every open source editor with the other editor
## (`editor.remountSourceEditors`), keeping each one's caret line.

import ../types

const ToggleSharedEditorLabel* = "Developer: Toggle Shared Editor"
  ## The command palette's entry (`ui_js.refreshCommandPaletteMenuIndex`).

var runtimeOverride = -1
  ## -1: follow the configuration; 0 / 1: the palette's toggle, for this
  ## window.

proc configuredSharedEditor(config: Config): bool =
  if config.isNil: return false
  var on = false
  {.emit: [on, " = !!(", config, " && ", config, ".sharedEditor === true);"].}
  on

proc sharedEditorEnabled*(config: Config): bool =
  ## Whether a source editor mounted now is the shared editor.
  if runtimeOverride >= 0: runtimeOverride == 1
  else: configuredSharedEditor(config)

proc setSharedEditorOverride*(on: bool) =
  runtimeOverride = if on: 1 else: 0

proc clearSharedEditorOverride*() =
  runtimeOverride = -1
