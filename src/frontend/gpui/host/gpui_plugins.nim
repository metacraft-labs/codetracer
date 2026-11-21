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
## * **The omnibar's entries and the `:plugins` verbs** (`pluginEntries`,
##   `pluginsWordsOf`), and the footer's text (`footerText`).

import std/[json, os, strutils]

import ../../tui/host/plugin_processes
import ../../viewmodel/plugin_host/supervisor
import ../../viewmodel/session_vm
import ../../viewmodel/viewmodels/omnibar_vm
import ../../../common/view_vocabulary/mappings   # `feGpui`
import ../../../common/view_vocabulary/vocabulary   # `ViewNode`
import std/tables

export plugin_processes
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
  p.sup.actionHook = proc(msg: JsonNode): bool =
    if msg{"vm"}.getStr("") != "debugControls": return false
    let action = msg{"action"}.getStr("")
    for (name, control) in GpuiPluginMoves:
      if name == action:
        queue[].add control
        return true
    false

func pluginKeyName*(canonical: string): string =
  ## A window key's canonical name (`gpui_keys.canonicalKeyOfGpui`) in the
  ## plugin manifests' grammar: lower case, and `escape` for `Esc`.
  let k = canonical.toLowerAscii
  if k == "esc": "escape" else: k

proc observeWindowEscape*(p: SessionPlugins; canonical: string): bool =
  ## §11.7.6, called for EVERY key before anything resolves it: an `Escape`
  ## is counted towards the recovery chord, and the key is still delivered as
  ## usual. True on the third within a second, which popped every plugin
  ## layer: the window then shows the recovery dialog.
  if p.isNil or not p.sup.extensionsEnabled: return false
  if pluginKeyName(canonical) != "escape": return false
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

proc pluginEntries*(p: SessionPlugins): seq[OmnibarEntry] =
  ## The window's omnibar entries: the reserved four, every plugin command
  ## and pane, and *Review* / *Grant* for each plugin waiting for consent.
  p.pluginPaletteEntries(GpuiPluginsTargetPrefix) &
    p.consentPaletteEntries(GpuiPluginsTargetPrefix)

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

proc windowFooterNote*(p: SessionPlugins; statusNote: string): string =
  ## The footer's note with plugins: the top plugin layer and its plugin
  ## first — who holds the keyboard is never hidden by a note — then the
  ## window's own note, or when it has none the plugins' status items and a
  ## plugin waiting for consent.
  var parts: seq[string]
  let layer = p.layerLabel
  if layer.len > 0: parts.add layer
  if statusNote.len > 0: parts.add statusNote
  elif not p.isNil:
    let items = p.statusText
    if items.len > 0: parts.add items
  parts.join("  ·  ")
