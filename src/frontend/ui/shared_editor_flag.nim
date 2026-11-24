## ui/shared_editor_flag.nim — which editor the desktop's editor pane draws.
##
## The setting `sharedEditor` (`common/config.nim`; on by default,
## `CODETRACER_SHARED_EDITOR=0` / `=1` overrides it for one launch,
## `index/config.loadConfig`) chooses between the shared editing core
## (`ui/shared_editor`) and Monaco. The command palette's **Developer: Toggle Shared
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
  ## On unless the configuration says `false`: a configuration without the
  ## key (an older file) gets the default, the shared editor.
  if config.isNil: return true
  var on = true
  {.emit: [on, " = (", config, ".sharedEditor !== false);"].}
  on

proc sharedEditorEnabled*(config: Config): bool =
  ## Whether a source editor mounted now is the shared editor.
  if runtimeOverride >= 0: runtimeOverride == 1
  else: configuredSharedEditor(config)

proc setSharedEditorOverride*(on: bool) =
  runtimeOverride = if on: 1 else: 0

proc clearSharedEditorOverride*() =
  runtimeOverride = -1
