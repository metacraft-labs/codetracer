## ui/plugin_hooks.nim — where the renderer's existing modules meet its
## installed plugins (`ui/plugin_panes`, Extensibility-Model.md §11) without
## importing them: the key router, the status bar and the command palette each
## read one of these, and `plugin_panes` sets them when it is installed.
##
## A module of its own because the three readers are imported BY modules that
## `plugin_panes` needs (the key router imports the status bar), so a direct
## import either way would be a cycle. Nil means "no plugins in this
## renderer": every reader treats it as nothing to do.

import std/jsffi

type
  PluginPaletteCommand* = tuple[label: string; run: proc()]

var pluginKeyHook*: proc(name: string; ev: JsObject; hostModalOpen: bool): bool
  ## Called by the key router for every key BEFORE its own resolution, in the
  ## keydown listener: true when a plugin took the key (the router then stops
  ## the event), false to route it as usual. `hostModalOpen` is whether a host
  ## modal layer (the palette, a menu, a context menu) is open, which ranks
  ## above every plugin layer (§11.7.3).

var pluginStatusText*: proc(): tuple[text, title: string]
  ## The status bar's plugin item: the plugins' status items, the top plugin
  ## layer, a plugin waiting for consent. "" renders nothing.

var pluginPaletteCommands*: proc(): seq[PluginPaletteCommand]
  ## The palette's plugin entries: the reserved `Plugins:` entries and every
  ## running plugin's commands and panes.

var pluginPaletteChanged*: proc()
  ## Set by the palette's owner (`ui_js`): rebuild the palette's index, the
  ## plugins' entries having changed.

var pluginStatusChanged*: proc()
  ## Set by the status bar: re-render, the plugins' item having changed.

var pluginTabSwitched*: proc()
  ## Called by `session_switch` when the tab on screen changes: the palette
  ## and the status bar show THAT tab's plugins.

var pluginNotify*: proc(text: string; actions: seq[PluginPaletteCommand])
  ## Set by the status bar: show a plugin's fault notification (§11.6.5) with
  ## its actions (`Re-enable`, `Disable`, `Show log`) as the notification's
  ## buttons.

var pluginTabClosed*: proc(tab: int)
  ## Called by `session_switch` when a tab closes: its plugins stop.
