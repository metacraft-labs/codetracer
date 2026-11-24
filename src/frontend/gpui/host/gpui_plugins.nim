## host/gpui_plugins.nim — the GPUI window's door to its session's plugins
## (Extensibility-Model.md §11): the native plugin processes the session runs
## beside it, through the front-end-agnostic `tui/host/plugin_processes` the
## terminal uses too. Renderer-free: `main.nim` draws what this answers.
##
## What the window takes from here, and why each is here rather than there:
##
## * **The session's plugins** (`openWindowPlugins`): `--no-extensions` and
##   `CODETRACER_NO_EXTENSIONS` decide BEFORE anything is discovered, so safe
##   mode starts no process at all.
## * **The relayed debugger moves** (`routeMovesToControls`): a plugin's
##   `stepForward` arrives as the window's own control (`next`), run by the
##   window's loop through `performControl` — the path a toolbar press takes —
##   so the move is settled, the panes are drawn at the new stop and the
##   plugins see it. Applied to the session's ViewModel behind the loop it would
##   be sent and never drawn (the terminal measured exactly that; it is why
##   `Supervisor.actionHook` exists).
## * **The keys** (`observeWindowEscape`, `routePluginKey`): §11.7 decided from
##   what the plugins pushed, in the key's own turn. The window calls the first
##   for EVERY key before anything else resolves it, and the second only where
##   a key would reach the router, with no host modal open.
## * **A focused plugin pane's keys** (`routePaneKey`): the view vocabulary's
##   own key handling runs on the tree the plugin pushed, here in the host, and
##   the transition goes to the plugin as a `view-event`; the plugin answers
##   later with a new tree. No plugin code runs to decide or to draw.
## * **A press on a plugin pane's row or control** (`routePaneClick`): the
##   same activation the terminal's click runs, by view node rather than by
##   row, sent as a `view-event`.
## * **The editor's plugin marks** (`editorDecorations`, `editorMarkers`): what
##   the plugins pushed for the file the editor shows, for `app/leaves` to draw.
## * **The omnibar's entries and the `:plugins` verbs** (`pluginEntries`,
##   `pluginsWordsOf`), a stopped plugin's fault actions among them
##   (`faultEntries`), and the footer's text (`footerText`).

import std/[json, options, os, sets, strutils]

import ../../tui/host/plugin_processes
import ../../tui/host/plugin_panes   # a plugin pane's view events, its decorations and markers
import ../../viewmodel/plugin_host/supervisor
import headless_app/layout_model   # where *Show pane* places a plugin's pane
import ../../viewmodel/session_vm
import ../../viewmodel/viewmodels/omnibar_vm
import ../../../common/view_vocabulary/mappings   # `feGpui`
import ../../../common/view_vocabulary/vocabulary   # `ViewNode`
import ../../../common/key_names   # `bindingKeyName`
import std/tables

export plugin_processes
export plugin_panes.PluginPanes, plugin_panes.SourceDecoration, plugin_panes.newPluginPanes
export vocabulary.ViewNode   # a contributed pane's view, for the window that draws it

const
  GpuiPluginsTargetPrefix* = "pluginsCommandLine:"
    ## How a plugin entry of the window's omnibar marks its target: the rest
    ## is a `:plugins …` line (`pluginsWordsOf`), not a menu `ClientAction`.

  GpuiPluginMoves* = [
    ("stepForward", "next"), ("stepIn", "step-in"), ("stepOut", "step-out"),
    ("stepBackward", "reverse-next"), ("reverseStepIn", "reverse-step-in"),
    ("reverseStepOut", "reverse-step-out"),
    ("continueExecution", "continue"), ("reverseContinue", "reverse-continue")]
    ## A plugin's relayed `debugControls` move, as the window's transport
    ## control (`transport_icons.TransportControls`' ids).

proc openWindowPlugins*(session: SessionViewModel; noExtensionsFlag: bool;
                        startDir: string): SessionPlugins =
  ## The plugins of the window's session, attached to it: discovered,
  ## resolved, held to the user's grants and settings, and the enabled ones
  ## activated on `trace-opened` (their package's process starts lazily, on
  ## the window's first pump). Safe mode builds the service and starts
  ## nothing, so *Plugins: Show status* still says why.
  let id = "gpui-" & $getCurrentProcessId()
  result = openSessionPlugins(session, id,
                              extensionsEnabled = not extensionsOffFor(noExtensionsFlag),
                              startDir = startDir, frontEnd = "gpui",
                              surfaces = feGpui)
  result.attach(session, id)

proc routeMovesToControls*(p: SessionPlugins; queue: ref seq[string]) =
  ## Take the plugins' debugger moves into `queue` (transport control ids),
  ## for the window's loop to run as its own.
  if p.isNil: return
  p.sup.actionHook = proc(msg: JsonNode; refusal: var string): bool =
    if msg{"vm"}.getStr("") != "debugControls": return false
    let action = msg{"action"}.getStr("")
    for (name, control) in GpuiPluginMoves:
      if name == action:
        queue[].add control
        return true
    false

func pluginKeyName*(canonical: string): string =
  ## A window key's canonical name (`gpui_keys.canonicalKeyOfGpui`) as the
  ## supervisor compares a plugin binding (`key_names.bindingKeyName`): the
  ## modifiers' spelling folded, the key's own case kept — `J` is not `j`.
  bindingKeyName(canonical)

proc observeWindowEscape*(p: SessionPlugins; canonical: string): bool =
  ## §11.7.6, called for EVERY key before anything resolves it: an `Escape`
  ## is counted towards the recovery chord, and the key is still delivered as
  ## usual. True on the third within a second, which popped every plugin
  ## layer: the window then shows the recovery dialog.
  if p.isNil or not p.sup.extensionsEnabled: return false
  if pluginKeyName(canonical) != "Esc": return false
  p.sup.observeEscape()

proc routePluginKey*(p: SessionPlugins; canonical: string;
                     userBound: bool): bool =
  ## §11.7.2–§11.7.3: the plugin layers' answer for a key, top first, then —
  ## only when the user's own layer has no row for it — the plugin pass. True
  ## when a plugin took the key: it is consumed in this turn, and the plugin
  ## answers later (a key it never answers is dropped, never replayed). The
  ## supervisor's `hostModalOpen` keeps every plugin layer below the window's
  ## own modals.
  if p.isNil or not p.sup.extensionsEnabled or canonical.len == 0:
    return false
  let k = pluginKeyName(canonical)
  var route = p.sup.resolveLayerKey(k, "")
  if not route.found and not userBound:
    route = p.sup.resolveStaticKey(k, "")
  if not route.found:
    return false
  discard p.sup.routeKey(route, k)
  true

proc faultEntries*(p: SessionPlugins): seq[OmnibarEntry] =
  ## A fault notification's actions (§11.7.5: *Re-enable*, *Disable*, *Show
  ## log*) as omnibar entries, for each plugin a fault STOPPED: one whose
  ## notification is on record and whose breaker is open. The footer says the
  ## notification's sentence once; the entries stay while the plugin is
  ## stopped, so the action is there when the user goes to take it. A plugin
  ## the user re-enabled is on probation, not stopped, and offers none.
  if p.isNil: return
  var seen: seq[string]
  for n in p.sup.notifications:
    if n.plugin.len == 0 or n.plugin in seen: continue
    let s = p.sup.slot(n.plugin)
    if s.isNil or s.breaker != bsOpen: continue
    seen.add n.plugin
    for (action, verb) in [("Re-enable", "re-enable"), ("Disable", "disable")]:
      if action notin n.actions: continue
      let line = ":plugins " & verb & " " & n.plugin
      result.add OmnibarEntry(kind: OmnibarMode.omCommand,
        label: "Plugins: " & action & " " & n.plugin, detail: line,
        target: GpuiPluginsTargetPrefix & line)
  if seen.len > 0:
    result.add OmnibarEntry(kind: OmnibarMode.omCommand,
      label: "Plugins: Show log", detail: ":plugins log",
      target: GpuiPluginsTargetPrefix & ":plugins log")

proc pluginEntries*(p: SessionPlugins): seq[OmnibarEntry] =
  ## The window's omnibar entries: the reserved four, every plugin command
  ## and pane, *Review* / *Grant* for each plugin waiting for consent, and a
  ## stopped plugin's fault actions (`faultEntries`).
  p.pluginPaletteEntries(GpuiPluginsTargetPrefix) &
    p.consentPaletteEntries(GpuiPluginsTargetPrefix) & p.faultEntries

proc pluginsWordsOf*(target: string): tuple[ok: bool, words: seq[string]] =
  ## A plugin entry's target, or a `:plugins …` line typed in the omnibar
  ## (`plugins …` once the omnibar took the colon), as the verbs'
  ## words (`SessionPlugins.control`).
  var line = target
  if line.startsWith(GpuiPluginsTargetPrefix):
    line = line[GpuiPluginsTargetPrefix.len .. ^1]
  line = line.strip
  if line.startsWith(":"): line = line[1 .. ^1]
  let words = line.splitWhitespace
  if words.len == 0 or words[0] != "plugins":
    return (false, @[])
  (true, words[1 .. ^1])

proc paneView*(p: SessionPlugins; qualifiedId: string): ViewNode =
  ## A contributed pane's view, from the tree its plugin last pushed
  ## (`Supervisor.renderSurface`: never plugin code, never nil).
  if p.isNil: return nil
  p.sup.renderSurface(qualifiedId)

proc pluginsBusy*(p: SessionPlugins): bool =
  ## §11.7.4: a request in flight, a process starting or due to restart —
  ## the window's loop polls soon (`armHoverTick`).
  not p.isNil and p.sup.extensionsEnabled and p.sup.busy

proc pluginsLive*(p: SessionPlugins): bool =
  ## Whether the window has plugins to pump at all: extensions on and a
  ## package installed. A plugin pushes whenever it likes (a new view after
  ## a step), so a live set is pumped on an idle tick too.
  not p.isNil and p.sup.extensionsEnabled and p.sup.packages.len > 0

proc setHostModal*(p: SessionPlugins; modalOpen: proc(): bool) =
  ## §11.7.3: the window's own modals (the omnibar, a text shown over the
  ## window, a menu, the right-click menu, the find bar) rank above every
  ## plugin layer, and no plugin may push one while they are open.
  if not p.isNil: p.sup.hostModalOpen = modalOpen

proc stateLine*(p: SessionPlugins): string =
  ## The status report on one line, for the window's gesture trace.
  if p.isNil: return ""
  var parts: seq[string]
  for l in p.sup.report().splitLines:
    if l.strip.len > 0: parts.add l.strip
  parts.join(" | ")

proc pluginPanesShown*(p: SessionPlugins): seq[tuple[id, title: string]] =
  ## Every pane an enabled plugin contributes, qualified, with its title.
  if p.isNil: return
  p.sup.contributedPanes

proc layerLabel*(p: SessionPlugins): string =
  ## §11.7.3: `FLAME MODE (acme-tools.flame)` while a plugin layer is on top.
  if p.isNil: "" else: p.sup.topLayerLabel

proc windowFooterNote*(p: SessionPlugins; statusNote: string;
                       lineNote = ""): string =
  ## The footer's note with plugins: the top plugin layer and its plugin
  ## first — who holds the keyboard is never hidden by a note — then the
  ## window's own note, then the plugins' status items and a plugin waiting
  ## for consent. The items are drawn BESIDE a note, not instead of it: the
  ## window's note stays until the next one, so items shown only without a
  ## note were gone after the session's first command (the terminal's same
  ## defect, fixed there in 62bebf8ead1).
  var parts: seq[string]
  let layer = p.layerLabel
  if layer.len > 0: parts.add layer
  if statusNote.len > 0: parts.add statusNote
  if not p.isNil:
    let items = p.statusText
    if items.len > 0: parts.add items
  # A plugin's decoration on the execution line (`lineDecorationNote`), as
  # the terminal repeats it on its status line.
  if lineNote.len > 0: parts.add lineNote
  parts.join("  ·  ")

const PluginPaneAnchors* = [paneState, paneCalltrace, paneEventLog, paneEditor]
  ## Where *Show pane* places a plugin's pane that the layout does not hold:
  ## a TAB beside the first of these that is placed (the Variables stack in
  ## the shared default), as the terminal places one
  ## (`tui/app/layout/binding.ContributedPaneAnchors`). With no anchor the
  ## pane went into the root row with no weight: a column too narrow to show.

proc pluginPaneCommand*(tree: LayoutNode; id, title: string): LayoutCommand =
  ## The layout command that docks plugin pane `id` into `tree`.
  for a in PluginPaneAnchors:
    if tree.contains(a):
      return cmdAddContributedPane(id, title, after = some(builtinRef(a)))
  cmdAddContributedPane(id, title)

proc routePaneKey*(panes: PluginPanes; focusedPane, canonical: string): bool =
  ## §11.4.4: a key on the FOCUSED plugin pane (`focusedPane`, the window's
  ## focused pane id) goes to its view when the view vocabulary's entry reads
  ## it — a list's arrows and Enter, a checkbox's Space — and is sent to the
  ## plugin as a `view-event`. False, and the key is the window's, for a pane
  ## that is not a loaded plugin's, for a key the view does not read, and for
  ## the keys that move the focus or open the omnibar's command line (Tab,
  ## Shift+Tab, `:`), as in the terminal.
  if panes.isNil or panes.plugins.isNil:
    return false
  if focusedPane notin panes.plugins.loadedPanes:
    return false
  let k = pluginKeyName(canonical)
  if k in ["tab", "shift+tab", ":"]:
    return false
  panes.paneKey(focusedPane, k)

proc routePaneClick*(panes: PluginPanes; pane, node: string; index: int): bool =
  ## §11.4.4: a press on a plugin pane's row or control — the element drawing
  ## view node `node` of contributed pane `pane`, on its option or table row
  ## `index` (-1 for the node itself; `window_clicks.gcpPluginNode`). The
  ## node is activated as the terminal's click activates it
  ## (`plugin_panes.paneClickNode`) and the plugin is sent the `view-event`.
  ## False for a pane that is not a loaded plugin's, or a node its pushed
  ## tree does not have.
  if panes.isNil or panes.plugins.isNil:
    return false
  if pane notin panes.plugins.loadedPanes:
    return false
  panes.paneClickNode(pane, node, index)

proc editorDecorations*(panes: PluginPanes; document: string): seq[SourceDecoration] =
  ## The running plugins' editor decorations for `document` (the path the
  ## editor shows), as they pushed them: a glyph and a text on a line. A
  ## stopped or disabled plugin draws none (§11.7.5).
  if panes.isNil: @[] else: panes.decorationsFor(document)

proc editorMarkers*(panes: PluginPanes; document: string): seq[SourceDecoration] =
  ## The running plugins' declared `marker` surfaces for `document`: a glyph
  ## for the gutter's mark column, on a line.
  if panes.isNil: @[] else: panes.markersFor(document)

proc lineDecorationNote*(panes: PluginPanes; document: string; line: int): string =
  ## The decoration on `line` (the execution line) for the footer, as the
  ## terminal repeats it on its status line: `◆ metrics: line 10
  ## (acme-tools.metrics)`, or "" for none.
  for d in panes.editorDecorations(document):
    if d.line == line and d.text.len > 0:
      return d.glyph & " " & d.text & " (" & d.plugin & ")"
  ""
