## index/plugin_sessions.nim — installed plugins beside each replay session,
## in the desktop's main process and in `ct host` (Extensibility-Model.md
## §11.2.1: "on the server, beside the primary session … one plugin-host
## process per primary session").
##
## A session's plugins are `host/plugin_processes.SessionPlugins` — the
## same discovery (`loadPluginPackages`), grant ledger and consent, settings
## and `Supervisor` the terminal runs, compiled for Node. What differs is
## where the session is and where its state goes:
##
## * **The desktop.** The session lives in the renderer (each tab owns its
##   `DebuggerSession`). The renderer hosts it as a sync primary over the
##   `CODETRACER::plugins-sync` channel and this process MIRRORS it
##   (`mirror_session`), so the plugins see the tab's session as any mirror
##   does, and the actions they relay (a step) run on the renderer's session
##   through the mirror's relay (`Supervisor.actionHook`).
## * **`ct host`.** The server already holds each client tab's session
##   (`host_clients`, `HostedPrimary`); the plugins attach to it directly, and
##   their state goes to that client alone (`runAsClient`). One client's
##   plugins never see another's session: each tab has its own
##   `SessionPlugins`, its own `Supervisor`, its own processes.
##
## Either way the renderer gets `CODETRACER::plugins-state` whenever what it
## shows changed: the contributed panes' trees, status items, commands and
## their enablement, the consent and fault notices, and the KEY SNAPSHOT
## (`key_snapshot`) its key router decides plugin keys against in the turn a
## key arrives. Keys, Escapes, view events and the `:plugins` verbs come back
## on the `plugins-*` messages below.
##
## A pump timer (`PumpIntervalMs`) polls every session's supervisor; it runs
## while any session is open. `--no-extensions` (the main process's argv) or
## `CODETRACER_NO_EXTENSIONS` turns every session's plugins off before any
## discovery runs (`extension_selection.planExtensions`).

import std/[asyncjs, json, jsffi, strutils, tables]

import ../../common/[ct_logging, plugin_model]
import ../../ct/extension_selection
import ../host/plugin_processes
import ../host/plugin_panes as host_panes
import ../viewmodel/plugin_host/[protocol, supervisor, key_snapshot]
import ../viewmodel/session_vm
import isonim/core/signals   # the session store's `val`
import ../viewmodel/sync/[transport, mirror_session]

const
  PluginsStateChannel* = cstring"CODETRACER::plugins-state"
  PluginsControlResultChannel* = cstring"CODETRACER::plugins-control-result"
  PluginsSyncChannel* = cstring"CODETRACER::plugins-sync"
  PumpIntervalMs = 25
  RebuildEveryMs = 250.0
  ResendEveryMs = 1_000.0
    ## A state unchanged this long is sent again: the report's "reopens in
    ## N s" counts down.

type
  PluginDeliver* = proc(channel: cstring; payload: JsObject)
    ## Send to the renderer that shows this session.

  PluginSession* = ref object
    key*: string
    tab*: int
    plugins*: SessionPlugins
    deliver: PluginDeliver
    mirror*: MirrorSession
      ## The desktop's mirror of the renderer's session; nil under `ct host`.
    panes: PluginPanes
      ## The panes as presses act on them (`paneClickNode`) and the editor's
      ## plugin marks are read (`decorationsFor`, `markersFor`); made on first use.
    session: SessionViewModel
      ## The session the plugins see: the desktop's mirror, `ct host`'s primary.
    lastSent: string
    lastSentMs: float
    lastBuiltMs: float

var sessions = initOrderedTable[string, PluginSession]()
var pumpTimer: JsObject
var decided = false
var enabledForProcess = true
var extensionsSource* = ""

proc jsArgv(): seq[cstring] {.importjs: "(process.argv)".}
proc jsEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc jsNowMs(): float {.importjs: "Date.now()".}
proc jsSetInterval(cb: proc(); ms: int): JsObject {.importjs: "setInterval(#, #)".}
proc jsClearInterval(t: JsObject) {.importjs: "clearInterval(#)".}
proc jsCwd(): cstring {.importjs: "process.cwd()".}
proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc extensionsEnabled*(): bool =
  ## `--no-extensions` / `CODETRACER_NO_EXTENSIONS`, decided once per process
  ## and before any plugin is looked at.
  if not decided:
    decided = true
    var args: seq[string]
    let argv = jsArgv()
    for i in 2 ..< argv.len:
      args.add $argv[i]
    let plan = planExtensions(args, $jsEnv(cstring(ExtensionsEnvVar)))
    if plan.kind == epkDecided:
      enabledForProcess = plan.enabled
      extensionsSource = $plan.source
    else:
      # A malformed flag (`--no-extensions=false`) is read as the user
      # reaching for the recovery route: off.
      enabledForProcess = false
      extensionsSource = plan.message
    infoPrint "plugins: extensions ",
      (if enabledForProcess: "on" else: "off"), " (", extensionsSource, ")"
  enabledForProcess

# ---------------------------------------------------------------------------
# What the renderer is sent
# ---------------------------------------------------------------------------

proc snapshotOf*(sup: Supervisor): JsonNode =
  ## The key snapshot (`key_snapshot`): what `resolveLayerKey` and
  ## `resolveStaticKey` read, in the order they read it.
  var layers = newJArray()
  var statics = newJArray()
  for s in sup.slots.values:
    if s.breaker == bsOpen or not s.active: continue
    for l in s.layers:
      var bs = newJArray()
      for b in l.bindings:
        bs.add %*{"key": b.key, "op": b.op, "when": b.whenClause}
      layers.add %*{"plugin": s.id, "token": l.token, "window": l.window,
                    "owner": l.owner, "label": l.label, "suspect": s.suspect,
                    "bindings": bs}
  for s in sup.slots.values:
    if s.suspect or s.breaker == bsOpen or not s.active: continue
    for b in s.spec.bindings:
      if not sup.enablementOf(s.id, b.op).enabled: continue
      statics.add %*{"plugin": s.id, "key": b.key, "scope": b.scope,
                     "when": b.whenClause, "op": b.op}
  var ctx = newJObject()
  for k, v in sup.contextKeys: ctx[k] = %v
  var reserved = newJArray()
  for k in sup.reservedKeys: reserved.add %k.toLowerAscii
  %*{SnapshotLayers: layers, SnapshotStatics: statics, SnapshotContext: ctx,
     SnapshotReserved: reserved, SnapshotChordCount: RecoveryChordCount,
     SnapshotChordWindowMs: RecoveryChordWindowMs}

proc stateOf*(ps: PluginSession): JsonNode =
  let p = ps.plugins
  let sup = p.sup
  var panes = newJArray()
  for pane in sup.contributedPanes:
    panes.add %*{"id": pane.id, "title": pane.title,
                 "tree": sup.renderSurface(pane.id).toJson,
                 "stale": sup.isStale(pane.id)}
  var status = newJArray()
  for it in sup.statusItems:
    let lines = viewLines(it.tree)
    status.add %*{"plugin": it.plugin, "item": it.item,
                  "text": (if lines.len > 0: lines[0].strip else: "")}
  var commands = newJArray()
  for c in sup.commands:
    let (enabled, reason) = sup.enablementOf(c.plugin, c.op)
    # `position`: the stop the plugin computed this enablement at, so a
    # reader can tell an answer about this stop from one about the last.
    let slot = sup.slot(c.plugin)
    let at = if slot.isNil or not slot.enablement.hasKey(c.op): -1'i64
             else: slot.enablement[c.op].epoch.position
    commands.add %*{"plugin": c.plugin, "op": c.op, "title": c.title,
                    "enabled": enabled, "reason": reason, "position": at}
  var notes = newJArray()
  for n in sup.notifications:
    notes.add %*{"plugin": n.plugin, "text": n.text, "actions": n.actions,
                 "atMs": n.atMs}
  # The editor's plugin marks for the file the session is stopped in
  # (§11.4.4): decorations after a line's code, markers in the glyph margin.
  var marks = %*{"file": "", "decorations": [], "markers": []}
  if not ps.session.isNil:
    let file = ps.session.store.debugger.val.location.file
    if file.len > 0:
      if ps.panes.isNil: ps.panes = newPluginPanes(ps.plugins)
      marks["file"] = %file
      for d in ps.panes.decorationsFor(file):
        marks["decorations"].add %*{"line": d.line, "glyph": d.glyph,
                                    "text": d.text, "plugin": d.plugin}
      for m in ps.panes.markersFor(file):
        marks["markers"].add %*{"line": m.line, "glyph": m.glyph,
                                "text": m.text, "plugin": m.plugin}
  var plugins = newJArray()
  for id, s in sup.slots:
    let (p50, p99) = s.latency
    plugins.add %*{"id": id, "state": sup.stateOf(s), "pid": sup.pidOf(id),
                   "breaker": $s.breaker, "latched": s.latched,
                   "strikes": s.totalStrikes, "slowAcks": s.slowAcks,
                   "ackP50": p50, "ackP99": p99}
  %*{"sessionId": ps.tab,
     "position": sup.epoch.position,
       # The stop the session is at (each command's `position` names its own).
     "extensionsEnabled": sup.extensionsEnabled,
     "panes": panes, "status": status, "commands": commands,
     "awaitingConsent": p.awaitingConsent, "notifications": notes,
     "statusLine": sup.statusLine, "statusText": p.statusText(),
     "layerLabel": sup.topLayerLabel,
     "recoveryOpen": sup.recoveryOpen, "recoveryPlugins": sup.recoveryPlugins,
     "plugins": plugins, "problems": p.problems, "editorMarks": marks,
     "keys": sup.snapshotOf}

proc send(ps: PluginSession; force = false) =
  let state = ps.stateOf
  let text = $state
  let now = jsNowMs()
  if not force and text == ps.lastSent and now - ps.lastSentMs < ResendEveryMs:
    return
  ps.lastSent = text
  ps.lastSentMs = now
  ps.deliver(PluginsStateChannel, jsonParse(cstring(text)))

proc pumpAll() =
  var keys: seq[string]
  for k in sessions.keys: keys.add k
  for k in keys:
    let ps = sessions.getOrDefault(k)
    if ps.isNil: continue
    try:
      # The state is built (and compared) when the supervisor says something
      # changed, and otherwise a few times a second: what changes without a
      # `changed` (a breaker's countdown) is not worth a JSON per tick.
      if ps.plugins.pump() or jsNowMs() - ps.lastBuiltMs >= RebuildEveryMs:
        ps.lastBuiltMs = jsNowMs()
        ps.send()
    except CatchableError as e:
      errorPrint "plugins: pumping ", ps.key, ": ", e.msg

proc ensureTimer() =
  if pumpTimer.isNil and sessions.len > 0:
    pumpTimer = jsSetInterval(pumpAll, PumpIntervalMs)
  elif not pumpTimer.isNil and sessions.len == 0:
    jsClearInterval(pumpTimer)
    pumpTimer = nil

# ---------------------------------------------------------------------------
# Opening and closing
# ---------------------------------------------------------------------------

proc applyTestThresholds*(sup: Supervisor) =
  ## `CODETRACER_PLUGIN_TEST_THRESHOLDS`: a JSON object of the supervisor's
  ## input-defence thresholds (`inputDeadlineMs`, `strikesToOpen`,
  ## `breakerBackoffMs`, `breakerBackoffCapMs`, `openingsToLatch`,
  ## `strikeWindowMs`), for the GUI suites that walk a breaker through
  ## half-open and latch in minutes rather than the product's 30 s backoffs.
  ## Unset in the product; a malformed value is logged and ignored.
  let text = $jsEnv(cstring"CODETRACER_PLUGIN_TEST_THRESHOLDS")
  if text.len == 0: return
  try:
    let t = parseJson(text)
    if t.hasKey("inputDeadlineMs"): sup.inputDeadlineMs = t["inputDeadlineMs"].getInt
    if t.hasKey("strikesToOpen"): sup.strikesToOpen = t["strikesToOpen"].getInt
    if t.hasKey("breakerBackoffMs"): sup.breakerBackoffMs = t["breakerBackoffMs"].getInt
    if t.hasKey("breakerBackoffCapMs"): sup.breakerBackoffCapMs = t["breakerBackoffCapMs"].getInt
    if t.hasKey("openingsToLatch"): sup.openingsToLatch = t["openingsToLatch"].getInt
    if t.hasKey("strikeWindowMs"): sup.strikeWindowMs = t["strikeWindowMs"].getInt
    if t.hasKey("halfOpenProbationMs"): sup.halfOpenProbationMs = t["halfOpenProbationMs"].getInt
    infoPrint "plugins: test thresholds ", text
  except CatchableError as e:
    warnPrint "plugins: CODETRACER_PLUGIN_TEST_THRESHOLDS ignored: ", e.msg

proc openPluginSession*(key: string; tab: int; session: SessionViewModel;
                        sessionId: string; deliver: PluginDeliver;
                        frontEnd: string; startDir = ""): PluginSession =
  ## The plugins of one session: discovered, held to the grants, and
  ## activated on `trace-opened` (`SessionPlugins.attach`). Replaces a
  ## session already open under `key`.
  if sessions.hasKey(key):
    sessions[key].plugins.close()
    sessions.del(key)
  let dir = if startDir.len > 0: startDir else: $jsCwd()
  result = PluginSession(key: key, tab: tab, deliver: deliver, session: session)
  try:
    result.plugins = openSessionPlugins(session, sessionId, extensionsEnabled(),
                                        dir, frontEnd = frontEnd,
                                        surfaces = feWeb)
    result.plugins.sup.applyTestThresholds()
    result.plugins.attach(session, sessionId)
  except CatchableError as e:
    # The session is the user's; its plugins failing to open must not take
    # it down. Nothing runs, and the log says why.
    errorPrint "plugins: session ", key, " could not open its plugins: ", e.msg
    return nil
  sessions[key] = result
  for line in result.plugins.problems:
    warnPrint "plugins: ", key, ": ", line
  infoPrint "plugins: session ", key, " opened, ",
    $result.plugins.sup.slots.len, " plugin(s) installed"
  ensureTimer()
  result.send(force = true)

proc pluginSession*(key: string): PluginSession =
  sessions.getOrDefault(key)

proc closePluginSession*(ps: PluginSession) =
  if ps.isNil: return
  if sessions.getOrDefault(ps.key) == ps:
    sessions.del(ps.key)
  ps.plugins.close()
  if not ps.mirror.isNil:
    ps.mirror.dispose()
    ps.mirror = nil
  ensureTimer()
  infoPrint "plugins: session ", ps.key, " closed"

proc closeAllPluginSessions*() =
  var all: seq[PluginSession]
  for ps in sessions.values: all.add ps
  for ps in all: ps.closePluginSession()

# ---------------------------------------------------------------------------
# The desktop: a mirror of the renderer's session
# ---------------------------------------------------------------------------

proc desktopKey*(window, tab: int): string =
  ## A desktop session's key: its window's `webContents` id and its tab.
  "desktop-" & $window & "-" & $tab

proc openDesktopPluginSession*(window, tab: int; deliver: PluginDeliver;
                               startDir = ""): PluginSession =
  ## The renderer's tab `tab` hosts its session as sync primary
  ## `desktop-<tab>`; mirror it here and run its plugins beside it.
  let channel = newSyncChannel(proc(msg: JsonNode) =
    deliver(PluginsSyncChannel,
            jsonParse(cstring($(%*{"sessionId": tab, "msg": msg})))))
  let mirror = createMirrorSession(channel)
  result = openPluginSession(desktopKey(window, tab), tab, mirror.session,
                             "desktop-" & $tab, deliver, "electron", startDir)
  if result.isNil:
    mirror.dispose()
    return
  result.mirror = mirror
  let m = mirror
  # A relayed action (a plugin's step) runs on the renderer's session, the
  # primary, as a mirror's view operations do.
  result.plugins.sup.actionHook = proc(msg: JsonNode; refusal: var string): bool =
    m.relay(msg{"vm"}.getStr(""), msg{"action"}.getStr(""),
            (if msg{"args"}.isNil: newJObject() else: msg{"args"}))
    true

proc deliverSync*(ps: PluginSession; msg: JsonNode) =
  ## A sync message from the renderer's primary, for the mirror.
  if not ps.isNil and not ps.mirror.isNil:
    ps.mirror.channel.deliver(msg)

# ---------------------------------------------------------------------------
# What the renderer asks
# ---------------------------------------------------------------------------

proc toJsonNode*(payload: JsObject): JsonNode =
  if payload.isNil or payload.isUndefined: newJObject()
  else: parseJson($jsonStringify(payload))

proc control*(ps: PluginSession; words: seq[string]) =
  ## `:plugins …` (the palette's reserved entries, the grant screen, the
  ## recovery dialog's buttons): the answer goes back as
  ## `plugins-control-result`.
  let (title, body) = ps.plugins.control(words)
  ps.deliver(PluginsControlResultChannel, jsonParse(cstring($(%*{
    "sessionId": ps.tab, "title": title, "body": body,
    "verb": (if words.len > 0: words[0] else: "")}))))
  ps.send(force = true)

proc routeConsumedKey*(ps: PluginSession; key, plugin, op, viaLayer: string) =
  ## The renderer consumed `key` for `plugin` (decided on the snapshot):
  ## the `invoke`, with the input deadline (§11.7.4).
  discard ps.plugins.sup.routeKey(
    KeyRoute(found: true, plugin: plugin, op: op, viaLayer: viaLayer), key)
  ps.send()

proc keyPassedSuspect*(ps: PluginSession; key, focusedSurface: string) =
  ## A key fell through a suspect plugin's layer in the renderer: the strike
  ## `resolveLayerKey` gives for it, given here.
  discard ps.plugins.sup.resolveLayerKey(key, focusedSurface)
  ps.send(force = true)

proc escape*(ps: PluginSession; arrivedMs = -1'i64) =
  ## Every `Escape` the renderer's router saw (§11.7.6), with when it
  ## arrived on the renderer's clock: the chord is timed on that, not on when
  ## this process got to it.
  if ps.plugins.sup.observeEscape(arrivedMs):
    infoPrint "plugins: recovery chord in ", ps.key
  ps.send(force = true)

proc viewEvent*(ps: PluginSession; surface: string; event: JsonNode) =
  ## A press on a plugin pane's element (`ui/plugin_panes.activatePressed`):
  ## the node, and its option or table row, activated as the terminal's and
  ## GPUI's presses activate it (`paneClickNode`) — the row highlighted or
  ## chosen, and the plugin sent the vocabulary's own transition. Any other
  ## event is the plugin's as it came.
  if event{"kind"}.getStr("") == "activate":
    if ps.panes.isNil: ps.panes = newPluginPanes(ps.plugins)
    discard ps.panes.paneClickNode(surface, event{"node"}.getStr(""),
                                   event{"option"}.getInt(-1))
  else:
    ps.plugins.sup.viewEvent(surface, event)
  ps.send(force = true)

proc handle*(ps: PluginSession; kind: string; msg: JsonNode) =
  ## One `plugins-*` message from the renderer.
  if ps.isNil: return
  case kind
  of "control":
    var words: seq[string]
    for w in msg{"words"}.getElems(): words.add w.getStr("")
    ps.control(words)
  of "key":
    ps.routeConsumedKey(msg{"key"}.getStr(""), msg{"plugin"}.getStr(""),
                        msg{"op"}.getStr(""), msg{"viaLayer"}.getStr(""))
  of "key-passed":
    ps.keyPassedSuspect(msg{"key"}.getStr(""), msg{"focused"}.getStr(""))
  of "escape":
    ps.escape(int64(msg{"at"}.getFloat(-1.0)))
  of "view-event":
    ps.viewEvent(msg{"surface"}.getStr(""), msg{"event"})
  of "close-recovery":
    ps.plugins.sup.closeRecovery()
    ps.send(force = true)
  of "state":
    ps.send(force = true)
  else:
    warnPrint "plugins: unknown message ", kind

# ---------------------------------------------------------------------------
# The IPC handlers (`ipc_utils.configureIpcMain`)
# ---------------------------------------------------------------------------

proc jsSenderId(event: JsObject): int {.importjs: """
  (function (e) {
    return (e && e.sender && typeof e.sender.id === 'number') ? e.sender.id : -1;
  })(#)""".}
proc jsSendTo(event: JsObject; channel: cstring; payload: JsObject) {.importjs:
  "#.sender.send(#, #)".}
proc jsOnceDestroyed(event: JsObject; cb: proc()) {.importjs:
  "#.sender.once('destroyed', #)".}
proc jsTab(payload: JsObject): int {.importjs:
  "((# || {}).sessionId | 0)".}

var serverSessionFor*: proc(tab: int): PluginSession
  ## Under `ct host`: the plugins of the CURRENT client's tab `tab`
  ## (`host_clients`); nil on the desktop. A client reaches only its own.

proc sessionFor(event: JsObject; tab: int): PluginSession =
  if not serverSessionFor.isNil:
    serverSessionFor(tab)
  else:
    sessions.getOrDefault(desktopKey(jsSenderId(event), tab))

proc onPluginsOpen*(sender: JsObject; response: JsObject) {.async.} =
  ## The desktop renderer hosts tab `sessionId`'s session as a sync primary
  ## and asks for its plugins. Under `ct host` the server opened them when
  ## it opened the tab's session; this only re-sends their state.
  let tab = jsTab(response)
  if not serverSessionFor.isNil:
    let ps = serverSessionFor(tab)
    if not ps.isNil: ps.send(force = true)
    return
  let window = jsSenderId(sender)
  let event = sender
  let ps = openDesktopPluginSession(window, tab,
    proc(channel: cstring; payload: JsObject) =
      try: jsSendTo(event, channel, payload)
      except CatchableError: discard)
  if ps.isNil: return
  let key = ps.key
  jsOnceDestroyed(sender, proc() =
    let open = sessions.getOrDefault(key)
    if not open.isNil: open.closePluginSession())

proc onPluginsSync*(sender: JsObject; response: JsObject) {.async.} =
  ## The renderer's sync primary, to the mirror (desktop only).
  let ps = sessionFor(sender, jsTab(response))
  if ps.isNil: return
  let raw = response[cstring"msg"]
  if raw.isNil or raw.isUndefined: return
  ps.deliverSync(toJsonNode(raw))

proc onPluginsMessage*(sender: JsObject; response: JsObject) {.async.} =
  ## Keys, Escapes, view events and the `:plugins` verbs.
  let msg = toJsonNode(response)
  let ps = sessionFor(sender, msg{"sessionId"}.getInt(-1))
  if ps.isNil: return
  let kind = msg{"kind"}.getStr("")
  if kind == "close" and serverSessionFor.isNil:
    ps.closePluginSession()
    return
  ps.handle(kind, msg)
