## host/plugin_service.nim — the terminal runtime's door to its plugins
## (`runtime.PluginsService`), and the plugins' palette entries. The plugins
## themselves, front-end-agnostic, are `plugin_processes`; GPUI uses that
## module without this one.

import std/json

import ../../viewmodel/viewmodels/omnibar_vm
import ../../viewmodel/plugin_host/supervisor
import ../app/[runtime, tui_app]
import ./plugin_processes
import ./plugin_panes

# ---------------------------------------------------------------------------
# The runtime's door
# ---------------------------------------------------------------------------

const
  ReservedPaletteEntries* = [
    ("Plugins: Show status", ":plugins"),
    ("Plugins: Recover input", ":plugins recover"),
    ("Plugins: Disable all for this session", ":plugins disable-all"),
    ("Plugins: Find the plugin causing a problem", ":plugins bisect")]
    ## §11.7.6: entries no plugin can shadow. A plugin's own entries carry its
    ## id in their label, so none can spell one of these exactly.

proc paletteEntries*(p: SessionPlugins): seq[OmnibarEntry] =
  for (label, line) in ReservedPaletteEntries:
    result.add OmnibarEntry(kind: OmnibarMode.omCommand, label: label,
                            detail: line, target: CommandLineTargetPrefix & line)
  if p.isNil: return
  for c in p.sup.commands:
    let line = ":plugins run " & c.plugin & " " & c.op
    result.add OmnibarEntry(kind: OmnibarMode.omCommand,
      label: c.title & " (" & c.plugin & ")", detail: line,
      target: CommandLineTargetPrefix & line)
  for pane in p.sup.contributedPanes:
    let line = ":plugins show " & pane.id
    result.add OmnibarEntry(kind: OmnibarMode.omCommand,
      label: "Show pane: " & pane.title & " (" & pane.id & ")", detail: line,
      target: CommandLineTargetPrefix & line)

proc service*(p: SessionPlugins): PluginsService =
  var lastLine = ""
  var shownFaults = 0
  let panes = newPluginPanes(p)
  PluginsService(
    panes: proc(): seq[tuple[id, title: string; running: bool]] =
      panes.contributedPanes(),
    paneView: proc(id: string): tuple[lines: seq[string]; cursor: int;
                                      stale: bool] =
      panes.paneView(id),
    paneKey: proc(id, key: string): bool = panes.paneKey(id, key),
    paneClick: proc(id: string; row: int): bool = panes.paneClick(id, row),
    decorations: proc(document: string):
        seq[tuple[line: int; glyph, text, plugin: string]] =
      panes.decorationsFor(document),
    control: proc(words: seq[string]): tuple[title, body: string] =
      p.control(words),
    statusText: proc(): string = p.statusText(),
    takeNote: proc(): string =
      if p.sup.notifications.len > shownFaults:
        shownFaults = p.sup.notifications.len
        return p.sup.notifications[^1].text & " (:plugins for more)"
      if p.sup.statusLine != lastLine:
        lastLine = p.sup.statusLine
        return lastLine
      "",
    observeEscape: proc(): bool = p.sup.observeEscape(),
    busy: proc(): bool = p.sup.busy,
    layerLabel: proc(): string = p.sup.topLayerLabel,
    routeLayerKey: proc(key: string): PluginRoute =
      let r = p.sup.resolveLayerKey(key, "")
      if not r.found: return (false, "")
      discard p.sup.routeKey(r, key)
      (true, ""),
    routeStaticKey: proc(key: string): PluginRoute =
      let r = p.sup.resolveStaticKey(key, "")
      if not r.found: return (false, "")
      discard p.sup.routeKey(r, key)
      (true, ""))

const PluginMoveCommands* = [
  ("stepForward", ":next"), ("stepIn", ":step"),
  ("stepBackward", ":reverse-next"), ("reverseStepIn", ":reverse-step"),
  ("continueExecution", ":continue"), ("reverseContinue", ":reverse-continue")]
  ## A plugin's relayed `debugControls` move, as the terminal's own command:
  ## the terminal pumps every move to its stop in its loop, so a move applied
  ## to the ViewModel behind the loop's back would be sent and never shown.

proc routeMoves*(p: SessionPlugins; queue: ref seq[string]) =
  ## Take the plugins' debugger moves into `queue`, for the loop to run.
  if p.isNil: return
  p.sup.actionHook = proc(msg: JsonNode): bool =
    if msg{"vm"}.getStr("") != "debugControls": return false
    let action = msg{"action"}.getStr("")
    for (name, line) in PluginMoveCommands:
      if name == action:
        queue[].add line
        return true
    false
