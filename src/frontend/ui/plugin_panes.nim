## ui/plugin_panes.nim — installed plugins in the desktop renderer and in a
## `ct host` browser page (Extensibility-Model.md §11): their contributed
## panes in the layout, their commands and the reserved `Plugins:` entries in
## the palette, their status items on the status bar, their keys in the key
## router, and the consent, fault and recovery screens.
##
## The plugins run beside the session in the main process (the desktop) or the
## server (`ct host`) — `index/plugin_sessions`. This module holds no plugin
## and asks none: everything it shows and every key it decides comes from the
## last `CODETRACER::plugins-state` that process sent for the tab
## (§11.7.1), and what the user does goes back on `plugins-message`.
##
## ## KEYS, DECIDED IN THE KEYDOWN (§11.7.1)
##
## `pluginKeyHook` runs inside the key router's listener. It decides from the
## tab's key snapshot (`key_snapshot`) with the same order the terminal uses
## (`tui/app/runtime`): every `Esc` is observed for the recovery chord first;
## then, unless a host modal is open, the plugin layers top first, then the
## plugins' static bindings for keys no user row binds. A key a plugin takes
## is consumed in this turn — the router calls `preventDefault` — and sent to
## the main process, which routes it with the input deadline. A key that falls
## through a suspect plugin's layer is reported, so that plugin is struck as
## the supervisor would strike it. The third `Esc` within the chord's window
## drops every plugin layer from the snapshot AT ONCE, before the main process
## answers, so the next key is the host's.
##
## ## THE DESKTOP'S SESSION
##
## On the desktop the tab's `SessionViewModel` lives here, and the plugins'
## process mirrors it: `hostSessionForPlugins` serves it as sync primary
## `desktop-<tab>` over `CODETRACER::plugins-sync` (`sync_host`), which is
## also how a plugin's relayed step reaches this session. Under `ct host` the
## server already holds the tab's session and this is not called.

import std/[json, jsffi, strutils, tables]

import isonim/web/web_renderer
import isonim/web/dom_api

import ../../common/view_vocabulary
import ../view_vocabulary/web_binding as wbind
import ../viewmodel/plugin_host/[protocol, key_snapshot]
import ../viewmodel/session_vm
import ../viewmodel/sync/[transport, sync_host]
import ./plugin_hooks

const
  PluginsStateChannel = cstring"CODETRACER::plugins-state"
  PluginsControlResultChannel = cstring"CODETRACER::plugins-control-result"
  PluginsSyncChannel = cstring"CODETRACER::plugins-sync"
  PluginsMessageChannel = cstring"CODETRACER::plugins-message"
  PluginsOpenChannel = cstring"CODETRACER::plugins-open"
  StatusLineShownMs = 8_000.0
  ReservedEntries* = [
    ("Plugins - Show status", @["status"]),
    ("Plugins - Recover input", @["recover"]),
    ("Plugins - Disable all for this session", @["disable-all"]),
    ("Plugins - Find the plugin causing a problem", @["bisect"])]
    ## §11.7.6: entries no plugin can shadow — the terminal's
    ## `plugin_service.ReservedPaletteEntries`, as `:plugins` verbs. A
    ## plugin's own entries carry its id in their label, so none can spell
    ## one of these exactly. The desktop palette reads `Name: argument` as a
    ## command and its argument, so no label here carries a colon (`label`).

type
  MountedPane = ref object
    id: string
    tab: int
      ## The tab whose layout holds the pane: each tab keeps its own
      ## GoldenLayout (`session_switch`), so a pane shows ITS tab's plugins.
    host: Element

  PluginUi = ref object
    ipc: JsObject
    activeTab: proc(): int
    userBound: proc(key: string): bool
    states: Table[int, JsonNode]
    panes: seq[MountedPane]
    escapes: seq[float]
    syncHost: SyncHost
    syncChannels: Table[int, SyncChannel]
    dialog: Element
    lastCommands: string
    lastStatus: string
    statusLine: string
    statusLineAtMs: float

var ui: PluginUi

proc jsNowMs(): float {.importjs: "Date.now()".}
proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc ipcSend(ipc: JsObject; channel: cstring; payload: JsObject) {.
  importjs: "#.send(#, #)".}
proc ipcOn(ipc: JsObject; channel: cstring;
           cb: proc(event: JsObject; payload: JsObject)) {.importjs: "#.on(#, #)".}
proc newDiv(): Element {.importjs: "(document.createElement('div'))".}
proc createEl(tag: cstring): Element {.importjs: "document.createElement(#)".}
proc setPreWrap(e: Element) {.importjs: "#.style.whiteSpace = 'pre-wrap'".}
proc closeDialog(e: Element) {.importjs: "#.close()".}
proc showModalOnce(e: Element) {.importjs:
  "(function (d) { if (!d.open) { d.showModal(); } })(#)".}
proc setText(e: Element; t: cstring) {.importjs: "#.textContent = #".}
proc setAttr(e: Element; name, value: cstring) {.importjs: "#.setAttribute(#, #)".}
proc clearChildren(e: Element) {.importjs: "#.replaceChildren()".}
proc appendEl(p, c: Element) {.importjs: "#.appendChild(#)".}
proc isConnected(e: Element): bool {.importjs:
  "(function (e) { return !!(e && e.isConnected); })(#)".}
proc onClick(e: Element; cb: proc(target: JsObject)) {.importjs:
  "#.addEventListener('click', function (ev) { (#)(ev.target); })".}
proc closestViewId(target: JsObject): cstring {.importjs: """
  (function (t) {
    var el = t && t.closest ? t.closest('[data-view-id]') : null;
    return el ? el.getAttribute('data-view-id') : '';
  })(#)""".}
proc stateField(state: JsObject; name: cstring): cstring {.importjs:
  "(String((# || {})[#] || ''))".}
proc containerElement(container: JsObject): Element {.importjs:
  "#.element".}
proc onContainerDestroy(container: JsObject; cb: proc()) {.importjs:
  "#.on('destroy', #)".}
proc addLayoutComponent(layout: JsObject; name: cstring; state: JsObject;
                        title: cstring) {.importjs:
  "#.addComponent(#, #, #)".}
proc documentBody(): Element {.importjs: "(document.body)".}
proc focusedContributedPane(): cstring {.importjs: """
  (function () {
    var a = document.activeElement;
    var el = a && a.closest ? a.closest('[data-contributed-pane]') : null;
    return el ? el.getAttribute('data-contributed-pane') : '';
  })()""".}

proc toJsonNode(o: JsObject): JsonNode =
  if o.isNil or o.isUndefined: newJObject()
  else: parseJson($jsonStringify(o))

proc toJsObject(j: JsonNode): JsObject = jsonParse(cstring($j))

proc send(kind: string; fields: JsonNode = newJObject()) =
  if ui.isNil or ui.ipc.isNil: return
  var msg = fields
  msg["kind"] = %kind
  msg["sessionId"] = %ui.activeTab()
  ui.ipc.ipcSend(PluginsMessageChannel, toJsObject(msg))

proc activeState(): JsonNode =
  if ui.isNil: return nil
  ui.states.getOrDefault(ui.activeTab(), nil)

proc control*(words: seq[string]) =
  ## Run a `:plugins` verb in the tab on screen's plugins.
  send("control", %*{"words": words})

# ---------------------------------------------------------------------------
# Panes
# ---------------------------------------------------------------------------

proc paneState(tab: int; id: string): JsonNode =
  let st = ui.states.getOrDefault(tab, nil)
  if st.isNil: return nil
  for p in st{"panes"}.getElems():
    if p{"id"}.getStr("") == id: return p
  nil

proc renderPane(m: MountedPane) =
  ## Draw `m` from the last tree its plugin pushed for the tab on screen.
  if m.host.isNil: return
  clearChildren(m.host)
  let p = paneState(m.tab, m.id)
  var tree: ViewNode
  var stale = false
  if p.isNil:
    let st = ui.states.getOrDefault(m.tab, nil)
    let why =
      if st.isNil: "Plugins are starting."
      elif not st{"extensionsEnabled"}.getBool(true):
        "Extensions are off for this session (--no-extensions)."
      else: "No plugin in this session contributes '" & m.id & "'."
    tree = viewText("plugin-pane-absent:" & m.id, why)
  else:
    let decoded = decodeViewTree(p{"tree"})
    tree = if decoded.error.len > 0:
             viewText("plugin-pane-refused:" & m.id, decoded.error)
           else: decoded.tree
    stale = p{"stale"}.getBool(false)
  if stale:
    let note = newDiv()
    note.setAttr("class", "plugin-pane-stale")
    note.setText("(stale: computed at an earlier stop)")
    m.host.appendEl(note)
  let b = renderWeb[WebRenderer, Element](WebRenderer(), tree)
  mountWeb(b, m.host)

proc renderPanesOf(tab: int) =
  if ui.isNil: return
  var kept: seq[MountedPane]
  for m in ui.panes:
    if m.host.isConnected:
      kept.add m
      if m.tab == tab: m.renderPane()
  ui.panes = kept

proc mountPluginPane*(container: JsObject; state: JsObject) =
  ## GoldenLayout's `pluginPaneComponent` factory (`ui/layout`): the pane
  ## named by the state's `contributedPane`, drawn from its plugin's tree,
  ## its clicks sent to the plugin as view events.
  let id = $stateField(state, cstring"contributedPane")
  let root = containerElement(container)
  let host = newDiv()
  host.setAttr("class", "plugin-pane")
  host.setAttr("data-contributed-pane", cstring(id))
  root.appendEl(host)
  let m = MountedPane(id: id, host: host,
                      tab: (if ui.isNil: -1 else: ui.activeTab()))
  host.onClick(proc(target: JsObject) =
    let node = $closestViewId(target)
    if node.len > 0:
      send("view-event", %*{"surface": id,
                            "event": {"kind": "activate", "node": node}}))
  if not ui.isNil:
    ui.panes.add m
  m.renderPane()
  onContainerDestroy(container, proc() =
    if not ui.isNil:
      var kept: seq[MountedPane]
      for x in ui.panes:
        if x != m: kept.add x
      ui.panes = kept)

var layoutOf*: proc(): JsObject
  ## The window's GoldenLayout (`data.ui.layout`), set by `ui_js`.

proc openPluginPane*(id, title: string) =
  ## Show the contributed pane `id`: focus it if it is open, else add it.
  if ui.isNil: return
  for m in ui.panes:
    if m.id == id and m.tab == ui.activeTab() and m.host.isConnected:
      m.renderPane()
      return
  if layoutOf.isNil or layoutOf().isNil: return
  addLayoutComponent(layoutOf(), cstring"pluginPaneComponent",
    toJsObject(%*{"id": 0, "label": title, "contributedPane": id}),
    cstring(title))

# ---------------------------------------------------------------------------
# The dialog: consent, status, faults, recovery
# ---------------------------------------------------------------------------

proc dialogButton(d: Element; label: string; words: seq[string]): Element =
  ## A button running `words` (or closing the recovery dialog). A factory, not
  ## a closure built in `showDialog`'s loop, which would share the loop's one
  ## environment: every button would run the last button's words.
  result = createEl("button")
  result.setText(cstring(label))
  result.setAttr("data-plugin-verb", cstring(words.join(" ")))
  result.onClick(proc(target: JsObject) =
    d.closeDialog()
    if words.len > 0: control(words)
    else: send("close-recovery"))

proc showDialog(title, body: string; buttons: seq[(string, seq[string])]) =
  ## A plain `<dialog>`: the text the plugins' `control` answered, and a
  ## button per verb it offers.
  if ui.isNil: return
  if ui.dialog.isNil:
    ui.dialog = createEl("dialog")
    ui.dialog.setAttr("class", "plugin-dialog")
    ui.dialog.setAttr("data-ct-plugin-dialog", "")
    documentBody().appendEl(ui.dialog)
  let d = ui.dialog
  clearChildren(d)
  let h = newDiv()
  h.setAttr("class", "plugin-dialog-title")
  h.setText(cstring(title))
  d.appendEl(h)
  let pre = newDiv()
  pre.setAttr("class", "plugin-dialog-body")
  pre.setPreWrap()
  pre.setText(cstring(body))
  d.appendEl(pre)
  for (label, words) in buttons & @[("Close", newSeq[string]())]:
    d.appendEl(dialogButton(d, label, words))
  d.showModalOnce()

proc onControlResult(payload: JsonNode) =
  let title = payload{"title"}.getStr("")
  let body = payload{"body"}.getStr("")
  if title.len == 0:
    # A one-line answer: the status bar's plugin item carries it.
    let st = activeState()
    if not st.isNil: st["statusLine"] = %body
    if not pluginStatusChanged.isNil: pluginStatusChanged()
    return
  var buttons: seq[(string, seq[string])]
  if title.startsWith("GRANT "):
    let id = title["GRANT ".len .. ^1].strip(chars = {'?', ' '})
    buttons = @[("Allow", @["grant", id]), ("Keep it off", @["disable", id])]
  elif title == "RECOVER INPUT":
    let st = activeState()
    if not st.isNil:
      for p in st{"recoveryPlugins"}.getElems():
        let id = p.getStr("")
        buttons.add ("Disable " & id & " for this session",
                     @["disable-session", id])
        buttons.add ("Disable " & id, @["disable", id])
    buttons.add ("Disable all for this session", @["disable-all"])
  showDialog(title, body, buttons)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

proc commandsSignature(st: JsonNode): string =
  if st.isNil: return ""
  $st{"commands"} & $st{"panes"}.getElems().len & $st{"awaitingConsent"}

proc statusOf(st: JsonNode): tuple[text, title: string] =
  if st.isNil: return ("", "")
  var parts: seq[string]
  for it in st{"status"}.getElems():
    let t = it{"text"}.getStr("")
    if t.len > 0: parts.add t
  let layer = st{"layerLabel"}.getStr("")
  if layer.len > 0: parts.add layer
  for id in st{"awaitingConsent"}.getElems():
    parts.add "plugin " & id.getStr("") & " waits for your consent"
  # The last sentence (a dropped key, a refusal), for a few seconds after it
  # was said, as the terminal shows it on its status line.
  let line = st{"statusLine"}.getStr("")
  if not ui.isNil and line != ui.statusLine:
    ui.statusLine = line
    ui.statusLineAtMs = jsNowMs()
  if line.len > 0 and not ui.isNil and
     jsNowMs() - ui.statusLineAtMs < StatusLineShownMs:
    parts.add line
  (parts.join("  "), st{"statusText"}.getStr(""))

proc onState(payload: JsonNode) =
  let tab = payload{"sessionId"}.getInt(-1)
  let before = ui.states.getOrDefault(tab, nil)
  let wasRecovery = not before.isNil and before{"recoveryOpen"}.getBool(false)
  ui.states[tab] = payload
  renderPanesOf(tab)
  if tab != ui.activeTab(): return
  let sig = commandsSignature(payload)
  if sig != ui.lastCommands:
    ui.lastCommands = sig
    if not pluginPaletteChanged.isNil: pluginPaletteChanged()
  let status = $statusOf(payload)
  if status != ui.lastStatus:
    ui.lastStatus = status
    if not pluginStatusChanged.isNil: pluginStatusChanged()
  if payload{"recoveryOpen"}.getBool(false) and not wasRecovery:
    control(@["recovery-dialog"])

# ---------------------------------------------------------------------------
# Keys (§11.7)
# ---------------------------------------------------------------------------

proc pluginKeyName(name: string): string =
  ## The desktop's canonical key, in the plugin bindings' spelling: the
  ## terminal's (`runtime`: the canonical name, lower case).
  name.toLowerAscii

proc focusedSurface(): string =
  ## The contributed pane holding the focus, or "".
  $focusedContributedPane()

proc decideKey(name: string; ev: JsObject; hostModalOpen: bool): bool =
  if ui.isNil: return false
  let st = activeState()
  if st.isNil or not st{"extensionsEnabled"}.getBool(true): return false
  let snap = st{"keys"}
  let key = pluginKeyName(name)
  if key in ["esc", "escape"]:
    send("escape")
    let t = jsNowMs()
    var kept: seq[float]
    for x in ui.escapes:
      if t - x <= float(snap.chordWindowMs): kept.add x
    kept.add t
    ui.escapes = kept
    if kept.len >= snap.chordCount:
      # §11.7.6: the third `Esc` — every plugin layer is gone now, and the
      # key is still the host's (the terminal delivers it as usual too).
      ui.escapes = @[]
      snap.dropLayers()
      return false
  if hostModalOpen: return false
  let focused = focusedSurface()
  var route = snap.resolveLayer(key, focused)
  if route.passedSuspect.len > 0:
    send("key-passed", %*{"key": key, "focused": focused})
  if not route.found and not (not ui.userBound.isNil and ui.userBound(name)):
    route = snap.resolveStatic(key, focused)
  if not route.found: return false
  send("key", %*{"key": key, "plugin": route.plugin, "op": route.op,
                 "viaLayer": route.viaLayer})
  true

# ---------------------------------------------------------------------------
# The palette
# ---------------------------------------------------------------------------

proc label(text: string): string =
  ## A palette label: the desktop palette splits a query at its first `:`
  ## (`command_interpreter.parseCommandQuery`), so a plugin's `Metrics:
  ## Step forward` is offered as `Metrics - Step forward`.
  text.replace(": ", " - ").replace(":", " ")

proc controlEntry(label: string; words: seq[string]): PluginPaletteCommand =
  ## One palette entry running `words`. A factory, not a closure built in the
  ## loop below: a closure there would share the loop's one environment, and
  ## every entry would run the LAST iteration's words.
  (label: label, run: proc() = control(words))

proc paneEntry(label, id, title: string): PluginPaletteCommand =
  (label: label, run: proc() = openPluginPane(id, title))

proc paletteCommands(): seq[PluginPaletteCommand] =
  for (label, words) in ReservedEntries:
    result.add controlEntry(label, words)
  let st = activeState()
  if st.isNil: return
  for id in st{"awaitingConsent"}.getElems():
    let plugin = id.getStr("")
    result.add controlEntry("Plugins - Review " & plugin, @["review", plugin])
  for c in st{"commands"}.getElems():
    let plugin = c{"plugin"}.getStr("")
    let op = c{"op"}.getStr("")
    result.add controlEntry(label(c{"title"}.getStr(op)) & " (" & plugin & ")",
                            @["run", plugin, op])
  for p in st{"panes"}.getElems():
    let id = p{"id"}.getStr("")
    let title = p{"title"}.getStr(id)
    result.add paneEntry("Show pane - " & label(title) & " (" & id & ")", id, title)

# ---------------------------------------------------------------------------
# The desktop's sync primary
# ---------------------------------------------------------------------------

proc hostSessionForPlugins*(tab: int; session: SessionViewModel) =
  ## The desktop: serve tab `tab`'s session to its plugins' process as sync
  ## primary `desktop-<tab>`, and ask for its plugins.
  if ui.isNil or session.isNil: return
  if ui.syncHost.isNil:
    ui.syncHost = newSyncHost()
  let id = "desktop-" & $tab
  if not sync_host.primary(ui.syncHost, id).isNil:
    ui.syncHost.removePrimary(id)
  if ui.syncChannels.hasKey(tab):
    ui.syncHost.detach(ui.syncChannels[tab])
  let ipc = ui.ipc
  let channel = newSyncChannel(proc(msg: JsonNode) =
    ipc.ipcSend(PluginsSyncChannel,
                toJsObject(%*{"sessionId": tab, "msg": msg})))
  ui.syncChannels[tab] = channel
  ui.syncHost.addPrimary(id, session)
  # The open first: the main process makes the mirror, then the attachment's
  # `activate` reaches it (one renderer's messages arrive in order).
  ipc.ipcSend(PluginsOpenChannel, toJsObject(%*{"sessionId": tab}))
  ui.syncHost.attach(channel, follow = id)

proc releaseSessionPlugins*(tab: int) =
  ## The tab closed: its plugins stop.
  if ui.isNil: return
  if ui.syncChannels.hasKey(tab):
    if not ui.syncHost.isNil:
      ui.syncHost.detach(ui.syncChannels[tab])
      ui.syncHost.removePrimary("desktop-" & $tab)
    ui.syncChannels.del(tab)
    ui.ipc.ipcSend(PluginsMessageChannel,
                   toJsObject(%*{"kind": "close", "sessionId": tab}))
  ui.states.del(tab)

# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------

proc refreshForActiveTab*() =
  ## The tab on screen changed: show its plugins.
  if ui.isNil: return
  renderPanesOf(ui.activeTab())
  ui.lastCommands = ""
  ui.lastStatus = ""
  let st = activeState()
  ui.lastCommands = commandsSignature(st)
  if not pluginPaletteChanged.isNil: pluginPaletteChanged()
  if not pluginStatusChanged.isNil: pluginStatusChanged()

proc installPluginUi*(ipc: JsObject; activeTab: proc(): int;
                      userBound: proc(key: string): bool = nil) =
  ## Listen for the plugins' state and set the hooks the key router, the
  ## status bar and the palette read. Idempotent.
  if not ui.isNil or ipc.isNil: return
  ui = PluginUi(ipc: ipc, activeTab: activeTab, userBound: userBound,
                states: initTable[int, JsonNode](),
                syncChannels: initTable[int, SyncChannel]())
  ipc.ipcOn(PluginsStateChannel, proc(event: JsObject; payload: JsObject) =
    onState(toJsonNode(payload)))
  ipc.ipcOn(PluginsControlResultChannel, proc(event: JsObject; payload: JsObject) =
    onControlResult(toJsonNode(payload)))
  ipc.ipcOn(PluginsSyncChannel, proc(event: JsObject; payload: JsObject) =
    let msg = toJsonNode(payload)
    let tab = msg{"sessionId"}.getInt(-1)
    if ui.syncChannels.hasKey(tab) and not msg{"msg"}.isNil:
      ui.syncChannels[tab].deliver(msg["msg"]))
  pluginKeyHook = decideKey
  pluginStatusText = proc(): tuple[text, title: string] = statusOf(activeState())
  pluginPaletteCommands = paletteCommands
  pluginTabSwitched = refreshForActiveTab
  pluginTabClosed = releaseSessionPlugins
  # A page that loaded after its plugins' state was first sent asks again.
  send("state")

proc pluginStateText(): cstring =
  ## The tab on screen's last plugins state, as JSON text ("" when none):
  ## `window.__ctPluginState()`, which the GUI suites read.
  let st = activeState()
  if st.isNil: cstring"" else: cstring($st)

{.emit: ["window.__ctPluginState = function () { return ", pluginStateText,
         "(); };"].}
