## plugin_sessions_test.nim — `index/plugin_sessions`, the desktop main
## process's and `ct host`'s plugins (Extensibility-Model.md §11.2.1), driven
## against REAL plugin processes under Node.
##
## What is real: the `acme-tools` test package (a native executable built with
## the plugin SDK, `plugin_process_fixture`) discovered as an installed
## component, the grant ledger and the plugin settings in a scratch user root,
## `SessionPlugins` and the `Supervisor` over `process_link`'s `child_process`
## arm, the desktop's mirror of the renderer's session (`mirror_session`) and
## the renderer's side of it — a real `SyncHost` serving a real
## `SessionViewModel` as primary — joined by the same JSON the IPC channel
## carries, the key snapshot (`key_snapshot`) against the supervisor's own
## resolution, and the action relay into the primary's `DebugControlsVM`.
##
## ## THE STAND-INS, AND WHY THEY ARE NOT MOCKS
##
## * Each primary session is a `SessionViewModel` over
##   `backend/mock_backend.MockBackendService`, as in the supervisor's suites:
##   this suite is about where the plugins run and what crosses to them, not
##   the replay. The debugger's stop is written into the store as a replay's
##   answer would write it, and the mock's received commands are the evidence
##   that a plugin's step reached the primary's backend. The real replay, the
##   real recording and Electron are the GUI suite's
##   (`src/tests/gui/tests/plugins/`).
## * Electron's IPC between the two processes is a direct call carrying the
##   same JSON-text payload (`deliver`, `deliverSync`): the channel's
##   transport is Electron's, and what is under test is what each side does
##   with the messages, in their order.
##
## Main process lane (`-d:ctIndex -d:server`), run by node.

import std/[asyncjs, json, jsffi, sequtils, strutils, tables]

import isonim/core/[owner, signals]

import ../viewmodel/backend/mock_backend
import ../viewmodel/session_vm
import ../viewmodel/store/types
import ../viewmodel/sync/[transport, sync_host]
import ../viewmodel/plugin_host/[supervisor, key_snapshot, protocol]
import ../host/plugin_processes
import ../index/plugin_sessions
import ../viewmodel/tests/unit/plugin_process_fixture
import ../../common/node_os

proc writeFile(path, content: string) = writeFileBytes(path, content)

const Ceiling = 120_000

var checks, failures: int

proc ck(cond: bool; what: string) =
  inc checks
  if not cond:
    inc failures
    echo "  FAILED: ", what

proc sleep(ms: int): Future[void] {.importjs:
  "new Promise(function (r) { setTimeout(r, #); })".}
proc setEnv(k, v: cstring) {.importjs: "process.env[#] = #".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc nowMs(): float {.importjs: "Date.now()".}
proc processExists(pid: int): bool {.importjs: """
  (function (pid) {
    try {
      var st = require('fs').readFileSync('/proc/' + pid + '/stat', 'utf8');
      var s = st.slice(st.lastIndexOf(')') + 2).split(' ')[0];
      return s !== 'Z' && s !== 'X';
    } catch (e) { return false; }
  })(#)""".}

proc eventually(what: string; cond: proc(): bool;
                ceilingMs = Ceiling): Future[bool] {.async.} =
  let start = nowMs()
  while not cond():
    if nowMs() - start > float(ceilingMs):
      echo "  timed out waiting for: ", what
      return false
    await sleep(10)
  return true

# ---------------------------------------------------------------------------
# A renderer tab: its session, served as sync primary `desktop-<tab>`
# ---------------------------------------------------------------------------

type Tab = ref object
  tab: int
  session: SessionViewModel
  mock: MockBackendService
  host: SyncHost
  channel: SyncChannel
  ps: PluginSession
  states: seq[JsonNode]
  controls: seq[JsonNode]

proc newPrimary(t: Tab) =
  t.mock = newMockBackendService(autoRespond = true)
  let mock = t.mock
  var session: SessionViewModel
  createRoot proc(dispose: proc()) =
    session = createSessionVM(mock.toBackendService())
    session.initializePanelViewModels()
  t.session = session
  var st = session.store.debugger.val
  st.status = dsIdle
  st.location.file = "/src/main.nim"
  st.location.line = 10
  session.store.debugger.val = st

proc moveTo(t: Tab; line: int) =
  var st = t.session.store.debugger.val
  st.location.line = line
  inc st.rrTicks
  t.session.store.debugger.val = st

proc openTab(tab: int): Tab =
  ## The renderer's `hostSessionForPlugins` and the main process's
  ## `onPluginsOpen`, in the order the IPC delivers them.
  let t = Tab(tab: tab)
  t.newPrimary()
  t.host = newSyncHost()
  let id = "desktop-" & $tab
  t.host.addPrimary(id, t.session)
  t.channel = newSyncChannel(proc(msg: JsonNode) =
    # Renderer → main: `plugins-sync`, as JSON text.
    t.ps.deliverSync(parseJson($msg)))
  t.ps = openDesktopPluginSession(1, tab,
    proc(channel: cstring; payload: JsObject) =
      let j = parseJson($jsonStringify(payload))
      if channel == PluginsSyncChannel:
        t.channel.deliver(j["msg"])
      elif channel == PluginsStateChannel:
        t.states.add j
      elif channel == PluginsControlResultChannel:
        t.controls.add j)
  t.host.attach(t.channel, follow = id)
  t

proc state(t: Tab): JsonNode =
  if t.states.len == 0: newJObject() else: t.states[^1]

proc paneText(t: Tab; id: string): string =
  for p in t.state{"panes"}.getElems():
    if p{"id"}.getStr("") == id:
      return $p{"tree"}
  ""

proc pluginOf(t: Tab; id: string): JsonNode =
  for p in t.state{"plugins"}.getElems():
    if p{"id"}.getStr("") == id: return p
  newJObject()

proc running(t: Tab; ids: varargs[string]): bool =
  for id in ids:
    if t.pluginOf(id){"state"}.getStr("") != "running": return false
  true

proc grantBoth(t: Tab) =
  t.ps.handle("control", %*{"words": ["grant", "acme-tools.metrics"]})
  t.ps.handle("control", %*{"words": ["grant", "acme-tools.flame"]})

var homeCount = 0

proc windowInputManifest(): string =
  ## The package with `flame` declaring `capturesWindowInput`: a window
  ## layer is refused without it (and the plugin then runs in a process of
  ## its own, §11.7.3).
  var doc = packageManifest()
  doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
  $doc

proc newHome(settings: JsonNode = nil; manifest = ""): string =
  ## A components root with `acme-tools` installed and a user root (the
  ## grant ledger, the plugin settings), named in the environment the way
  ## the desktop's and `ct host`'s processes inherit them. Read when a
  ## session's plugins open.
  inc homeCount
  result = scratchRoot() / ("sessions-" & $getCurrentProcessId() & "-" & $homeCount)
  createDir(result / "components")
  createDir(result / "user-root")
  discard installPackage(result / "components", manifest)
  if not settings.isNil:
    writeFile(result / "user-root" / "plugin-settings.json", $settings)
  setEnv("CODETRACER_COMPONENTS_ROOT", cstring(result / "components"))
  setEnv("CODETRACER_USER_ROOT", cstring(result / "user-root"))

proc closeAndWait(t: Tab): Future[void] {.async.} =
  let sup = t.ps.plugins.sup
  t.ps.closePluginSession()
  if not await eventually("processes stopped", proc(): bool =
      sup.processIds.len == 0):
    echo "  events:\n", sup.events[max(0, sup.events.len - 12) .. ^1].join("\n")

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------

var onlySections: seq[string]

proc argv(): seq[cstring] {.importjs: "(process.argv)".}

proc section(tag, title: string): bool =
  result = onlySections.len == 0 or tag in onlySections
  if result: echo title

proc main() {.async.} =
  for a in argv():
    if ($a).startsWith("--only="):
      onlySections = ($a)["--only=".len .. ^1].split(',')
  setEnv("CT_PLUGIN_TEST_SCRATCH", cstring(getTempDir() / "ct-plugin-sessions-test"))
  discard buildPackageExecutable()

  if section("desktop", "the desktop: a renderer tab's session, mirrored, and its plugins beside it"):
    discard newHome()
    let t = openTab(3)
    ck await eventually("first state", proc(): bool = t.states.len > 0),
      "the renderer is sent the tab's plugins state"
    ck t.state{"sessionId"}.getInt(-1) == 3, "addressed to the tab"
    ck t.state{"awaitingConsent"} == %*["acme-tools.metrics", "acme-tools.flame"],
      "installing is not accepting: both wait for consent"
    ck t.ps.plugins.sup.processIds.len == 0, "and no process runs"
    t.ps.handle("control", %*{"words": ["review", "acme-tools.metrics"]})
    ck t.controls.len > 0 and
      t.controls[^1]{"title"}.getStr("") == "GRANT acme-tools.metrics?" and
      t.controls[^1]{"body"}.getStr("").contains("runs the native program"),
      "the grant screen goes back to the renderer"
    t.grantBoth()
    ck await eventually("both running", proc(): bool =
      t.running("acme-tools.metrics", "acme-tools.flame")), "granted, both run"
    let pid = t.pluginOf("acme-tools.metrics"){"pid"}.getInt(0)
    ck pid > 0 and t.pluginOf("acme-tools.flame"){"pid"}.getInt(0) == pid,
      "in ONE process"
    ck await eventually("pane from the mirror", proc(): bool =
      t.paneText("acme-tools.metrics/overview").contains("main.nim:10")),
      "the pane shows the RENDERER's session, through the mirror"
    t.moveTo(77)
    ck await eventually("pane follows", proc(): bool =
      t.paneText("acme-tools.metrics/overview").contains("main.nim:77")),
      "and follows its moves"
    ck t.state{"status"}.getElems().anyIt(it{"text"}.getStr("") == "metrics ok"),
      "the status item is in the state"
    ck t.state{"commands"}.getElems().anyIt(
      it{"op"}.getStr("") == "metrics.step" and it{"enabled"}.getBool(false)),
      "the commands, with their pushed enablement"
    # A plugin's step runs on the renderer's session (the primary).
    t.mock.clearReceivedCommands()
    t.ps.handle("control", %*{"words": ["run", "acme-tools.metrics", "metrics.step"]})
    ck await eventually("step reached the primary", proc(): bool =
      t.mock.receivedCommands.len > 0),
      "the relayed step reached the primary's backend"
    # A key the renderer consumed, routed with the deadline: the plugin's
    # operation runs and its relayed step is handed to the primary again.
    # (The primary's first step is still in flight — the mock emits no
    # `complete-move` — so the evidence is the relay, not a second request.)
    let slot = t.ps.plugins.sup.slot("acme-tools.metrics")
    let applied = slot.actionsApplied
    let acks = slot.ackSamples.len
    t.ps.handle("key", %*{"key": "ctrl+alt+m", "plugin": "acme-tools.metrics",
                          "op": "metrics.step", "viaLayer": ""})
    ck await eventually("key's step", proc(): bool =
      slot.actionsApplied > applied and slot.ackSamples.len > acks),
      "a consumed key runs the plugin's operation, acknowledged on time"
    await t.closeAndWait()
    ck not processExists(pid), "closing the tab's plugins stops the process"

  if section("keys", "the key snapshot decides as the supervisor does"):
    discard newHome(%*{"plugins": {"acme-tools.flame": {"settings": {"mode": "swallow-input"}}}},
                    windowInputManifest())
    let t = openTab(4)
    t.grantBoth()
    let sup = t.ps.plugins.sup
    ck await eventually("layer pushed", proc(): bool =
      sup.allLayers.len > 0 and t.running("acme-tools.flame")),
      "flame's window layer is pushed"
    discard await eventually("ready context", proc(): bool =
      sup.contextKeys.getOrDefault("plugin.acme-tools.metrics.ready", false))
    var snap = sup.snapshotOf
    for key in ["a", "z", "7", "escape", "ctrl+alt+m", "ctrl+shift+p", "f5"]:
      let r = snap.resolveLayer(key, "")
      let s = sup.resolveLayerKey(key, "")
      ck r.found == s.found and r.plugin == s.plugin and r.op == s.op and
        r.viaLayer == s.viaLayer, "layer key '" & key & "': snapshot " & $r.found &
        " " & r.plugin & " / supervisor " & $s.found & " " & s.plugin
      let rs = snap.resolveStatic(key, "")
      let ss = sup.resolveStaticKey(key, "")
      ck rs.found == ss.found and rs.plugin == ss.plugin and rs.op == ss.op,
        "static key '" & key & "': snapshot " & $rs.found & " / supervisor " & $ss.found
    ck snap.resolveStatic("ctrl+alt+m", "").found,
      "metrics' Ctrl+Alt+M is a static binding once `ready` holds"
    # SUSPECT: a key the plugin never acknowledges; past the deadline its
    # layer is transparent in the snapshot as in the supervisor.
    sup.inputDeadlineMs = 300
    t.ps.handle("key", %*{"key": "a", "plugin": "acme-tools.flame",
                          "op": "flame.key", "viaLayer": snap.resolveLayer("a", "").viaLayer})
    ck await eventually("suspect", proc(): bool =
      sup.slot("acme-tools.flame").suspect), "the silent plugin turns suspect"
    t.ps.handle("state", newJObject())
    snap = t.state{"keys"}
    let r = snap.resolveLayer("b", "")
    ck not r.found and r.passedSuspect == @["acme-tools.flame"],
      "the snapshot's suspect layer is transparent, and names who was passed"
    let strikes = sup.slot("acme-tools.flame").strikes.len
    t.ps.handle("key-passed", %*{"key": "b", "focused": ""})
    ck sup.slot("acme-tools.flame").strikes.len == strikes + 1,
      "the renderer's report gives the strike the supervisor gives"
    # The recovery chord, observed per Escape.
    for _ in 1 .. 3: t.ps.handle("escape", newJObject())
    ck sup.recoveryOpen and sup.allLayers.len == 0,
      "three Escapes pop the layers and open the recovery dialog"
    ck t.state{"recoveryOpen"}.getBool(false) and
      t.state{"keys"}{"layers"}.len == 0, "and the renderer is told at once"
    await t.closeAndWait()

  if section("isolation", "two sessions, two processes, neither sees the other"):
    discard newHome()
    let a = openTab(5)
    a.grantBoth()
    discard await eventually("A running", proc(): bool = a.running("acme-tools.metrics"))
    # A session opened after the grant (a second `ct host` client, a new
    # tab): the grant is the user's, so its plugins start without asking.
    let b = openTab(6)
    ck await eventually("both sessions running", proc(): bool =
      a.running("acme-tools.metrics") and
      b.running("acme-tools.metrics", "acme-tools.flame")),
      "the grant is the user's: BOTH of the second session's plugins start " &
      "on `trace-opened` (each plugin's own activation, not the package's last)"
    ck b.state{"awaitingConsent"}.len == 0, "and it asks nothing"
    let pa = a.pluginOf("acme-tools.metrics"){"pid"}.getInt(0)
    let pb = b.pluginOf("acme-tools.metrics"){"pid"}.getInt(0)
    ck pa > 0 and pb > 0 and pa != pb, "one plugin-host process per session"
    discard await eventually("panes", proc(): bool =
      a.paneText("acme-tools.metrics/overview").contains("main.nim:10") and
      b.paneText("acme-tools.metrics/overview").contains("main.nim:10"))
    a.moveTo(42)
    ck await eventually("A's pane moves", proc(): bool =
      a.paneText("acme-tools.metrics/overview").contains("main.nim:42")),
      "A's plugin follows A"
    await sleep(500)
    ck b.paneText("acme-tools.metrics/overview").contains("main.nim:10"),
      "B's plugin never saw A's move"
    await a.closeAndWait()
    await b.closeAndWait()

  echo "CHECKS: ", checks
  if failures > 0:
    echo "[FAILED] plugin sessions (", failures, " of ", checks, ")"
    {.emit: "process.exitCode = 1;".}
  else:
    echo "[OK] plugin sessions"
  # A session a failed case left open keeps its pump timer (and its plugin
  # processes) alive; end here, and the exit guards stop the processes.
  closeAllPluginSessions()
  {.emit: "setTimeout(function () { process.exit(process.exitCode || 0); }, 500);".}

discard main()
