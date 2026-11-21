## test_plugin_process_host.nim — plugins run out of process
## (Extensibility-Model.md §11), driven against REAL plugin processes.
##
## The `acme-tools` test package (`plugin_packages/acme-tools/`) is built with
## the plugin SDK, installed as a component the way `ct install` lays one out,
## and started by the real `Supervisor` as a child process over real pipes. One
## executable hosts two plugins; `flame` misbehaves on request (its `mode`
## setting) — it segfaults, hangs, floods, swallows input, raises, exits and
## breaks the protocol — and every assertion is about what the host did.
##
## ## THE STAND-INS, AND WHY THEY ARE NOT MOCKS
##
## * The primary session is a real `SessionViewModel` over
##   `backend/mock_backend.MockBackendService`, one of the four
##   `BackendService` implementations the ViewModel layer ships, as PLAT-7's
##   suites use it. It is here because a session needs a transport and these
##   suites are about the plugin process, not the replay; the debugger's stop
##   is written into the store as a replay's answer would write it. The real
##   replay, the real recording and the real terminal are the TUI suite's
##   (`tui/tests/test_plat81_plugin_processes.nim`).
## * Nothing else is a stand-in. The relay reaches the real
##   `DebugControlsVM.stepForward`, whose request the backend receives.
##
## ## TIME
##
## The host is loaded (load above 100). Every wait is on STATE, with a
## generous ceiling (`waitUntil`), and a threshold that is not the subject of a
## test is widened so the machine's load cannot trip it. A threshold that IS the
## subject keeps its value, and the test waits for the consequence, not for the
## clock.

import std/[algorithm, json, os, posix, sequtils, strutils, tables, times, unittest]

import isonim/core/[computation, owner, signals]

import codetracer_embed
import ../../../../common/value_presentation/[presenter, vocabulary as value_vocabulary]
import backend/mock_backend
import ../../../../common/plugin_model
import plugin_host/[host, protocol, supervisor, surface_host]
import plugin_process_fixture

const Ceiling = 120_000

proc waitUntil(sup: Supervisor; what: string; cond: proc(): bool;
               ceilingMs = Ceiling): bool {.discardable.} =
  let start = monotonicMs()
  while not cond():
    sup.poll()
    if monotonicMs() - start > ceilingMs:
      var panes = ""
      for pane in sup.contributedPanes:
        panes.add "\n" & pane.id & ": " & $sup.renderSurface(pane.id).toJson
      checkpoint "timed out waiting for: " & what & "\n" & sup.report() & panes &
        "\nevents:\n" & sup.events[max(0, sup.events.len - 30) .. ^1].join("\n")
      return false
    os.sleep(2)
  true

proc settle(sup: Supervisor; ms: int) =
  ## Keep the loop turning for `ms` (used only where the assertion is that
  ## something did NOT happen in that window).
  let start = monotonicMs()
  while monotonicMs() - start < ms:
    sup.poll()
    os.sleep(2)

type Rig = object
  sup: Supervisor
  session: SessionViewModel
  mock: MockBackendService
  dir: string

var rigCount = 0

proc newRig(flameMode = "normal"; manifest = ""; extensions = true;
            tune: proc(s: Supervisor) = nil): Rig =
  inc rigCount
  let root = scratchRoot() / ("rig-" & $getpid() & "-" & $rigCount)
  removeDir(root)
  createDir(root)
  result.dir = installPackage(root, manifest)
  result.mock = newMockBackendService(autoRespond = true)
  let mock = result.mock
  var session: SessionViewModel
  createRoot proc(dispose: proc()) =
    session = createSessionVM(mock.toBackendService())
    session.initializePanelViewModels()
  result.session = session
  var st = session.store.debugger.val
  st.status = dsIdle
  st.location.file = "/src/main.nim"
  st.location.line = 10
  session.store.debugger.val = st
  let sup = newSupervisor("tui", "1.0.0", extensions)
  # Widened: not the subject of most tests (see the header).
  sup.pongDeadlineMs = 20_000
  sup.busyHangMs = 30_000
  sup.helloDeadlineMs = 60_000
  sup.inputDeadlineMs = 20_000
  sup.restartBaseMs = 10
  sup.restartCapMs = 50
  sup.logDir = root / "logs"
  if not tune.isNil: tune(sup)
  let text = readFile(result.dir / "plugin.json")
  let pkg = parsePluginPackage(text, "plugin.json", "acme-tools")
  doAssert pkg.allErrors.len == 0, renderAll(pkg.allErrors)
  sup.addPackage(result.dir, pkg)
  sup.configure("acme-tools.flame", true, %*{"mode": flameMode})
  sup.configure("acme-tools.metrics", true, newJObject())
  sup.attachSession(session, "s1")
  result.sup = sup

proc both(r: Rig) =
  r.sup.activate("acme-tools.metrics")
  r.sup.activate("acme-tools.flame")

proc active(r: Rig; id: string): bool = r.sup.slot(id).active

proc moveTo(r: Rig; line: int) =
  var st = r.session.store.debugger.val
  st.location.line = line
  inc st.rrTicks
  r.session.store.debugger.val = st

proc allText(n: ViewNode): string =
  ## Every label, text and option of a tree, for `contains`.
  if n.isNil: return ""
  result = n.label & " " & n.text
  for o in n.options: result.add " " & o.label
  for c in n.children: result.add " " & allText(c)

proc pidAlive(pid: int): bool = pid > 0 and kill(Pid(pid), 0) == 0

suite "§11.2: one native process hosts a package's plugins":

  test "both plugins activate in ONE process and contribute their panes":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("both active", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame"))
    let pid = r.sup.pidOf("acme-tools.metrics")
    check pid > 0
    check r.sup.pidOf("acme-tools.flame") == pid
    check r.sup.processIds == @[pid]
    check r.sup.waitUntil("panes drawn", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:10") and
      r.sup.renderSurface("acme-tools.flame/flame").allText.contains("main 60%"))
    check r.sup.contributedPanes.mapIt(it.id) ==
      @["acme-tools.metrics/overview", "acme-tools.flame/flame"]
    r.sup.shutdown()
    check not pidAlive(pid)

  test "disabling one plugin leaves its sibling running in the SAME process":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("both active", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame"))
    let pid = r.sup.pidOf("acme-tools.metrics")
    var persisted: seq[(string, bool)]
    r.sup.onDisable = proc(id: string; enabled: bool) = persisted.add (id, enabled)
    r.sup.setEnabled("acme-tools.flame", false)
    r.sup.settle(300)
    check not r.active("acme-tools.flame")
    check r.active("acme-tools.metrics")
    check r.sup.pidOf("acme-tools.metrics") == pid
    check pidAlive(pid)
    check persisted == @[("acme-tools.flame", false)]
    check r.sup.renderSurface("acme-tools.flame/flame").allText.contains("disabled")
    # Disabling the last one stops the process (§11.2.2).
    r.sup.setEnabled("acme-tools.metrics", false)
    check r.sup.waitUntil("process stopped", proc(): bool = not pidAlive(pid))
    r.sup.shutdown()

  test "--no-extensions starts no plugin process":
    var r = newRig(extensions = false)
    r.both()
    r.sup.settle(300)
    check r.sup.processIds.len == 0
    check not r.active("acme-tools.metrics")
    check r.sup.report().contains("--no-extensions")
    check r.sup.renderSurface("acme-tools.metrics/overview").allText.contains(
      "Extensions are off")
    r.sup.shutdown()

  test "settings are per plugin, validated against its schema, and reach it":
    var r = newRig()
    r.sup.configure("acme-tools.metrics", true, %*{"label": "speed", "bogus": 1})
    check r.sup.slot("acme-tools.metrics").settingProblems.len == 1
    check render(r.sup.slot("acme-tools.metrics").settingProblems[0]).contains(
      "plugins.acme-tools.metrics.settings.bogus")
    r.both()
    check r.sup.waitUntil("label shown", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("label speed"))
    r.sup.settingsChanged("acme-tools.metrics", %*{"label": "fast"})
    check r.sup.waitUntil("new label", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("label fast"))
    r.sup.shutdown()

suite "PLAT-12's plugin tier: a plugin that publishes visualisers":

  test "a published `visualisers` ViewModel becomes ptPlugin-tier visualisers":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("published", proc(): bool =
      r.sup.pluginVisualisers().len == 1)
    let v = r.sup.pluginVisualisers()[0]
    check v.tier == ptPlugin
    check v.tierDeclared
    check v.typeMatch == "Matrix"
    check v.summary == "matrix (acme-tools)"
    check v.id == "plugin:acme-tools.metrics#matrix"
    # Its breaker open, the plugin contributes nothing.
    r.sup.setEnabled("acme-tools.metrics", false, persist = false)
    check r.sup.pluginVisualisers().len == 0
    r.sup.shutdown()

suite "§11.4: mirrored state, epochs and the action relay":

  test "the pane follows the debugger, stamped with the new position":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("drawn", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:10"))
    let before = r.sup.epoch.position
    r.moveTo(42)
    check r.sup.epoch.position == before + 1
    check r.sup.isStale("acme-tools.metrics/overview")
    check r.sup.waitUntil("follows", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:42"))
    check r.sup.renderSurface("acme-tools.metrics/overview").allText.contains(
      "position " & $(before + 1))
    check not r.sup.isStale("acme-tools.metrics/overview")
    r.sup.shutdown()

  test "an answer computed at the old position is never shown":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.metrics"))
    # Current answer: shown.
    let fresh = r.sup.query("acme-tools.metrics", "values", %*{})
    check r.sup.waitUntil("fresh answer", proc(): bool =
      r.sup.answers.anyIt(it.id == fresh))
    # The plugin computes for 400 ms; the debugger moves meanwhile.
    let stale = r.sup.query("acme-tools.metrics", "values", %*{"delayMs": 400})
    r.sup.poll()
    r.moveTo(50)
    check r.sup.waitUntil("stale dropped", proc(): bool = r.sup.staleDropped >= 1)
    check not r.sup.answers.anyIt(it.id == stale)
    r.sup.shutdown()

  test "a plugin command runs a real action on the primary through the relay":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.metrics"))
    r.mock.clearReceivedCommands()
    let id = r.sup.invoke("acme-tools.metrics", "metrics.step")
    check id.len > 0
    check r.sup.waitUntil("action applied", proc(): bool =
      r.sup.slot("acme-tools.metrics").actionsApplied == 1)
    check r.mock.receivedCommands.len > 0
    r.sup.shutdown()

suite "§11.6, §11.8: faults are attributed, and siblings survive":

  test "SIGKILL restarts the process, re-activates both, re-sends a snapshot":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("both active", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame"))
    let pid = r.sup.pidOf("acme-tools.metrics")
    discard kill(Pid(pid), SIGKILL)
    check r.sup.waitUntil("restarted", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame") and
      r.sup.pidOf("acme-tools.metrics") notin [0, pid])
    check r.sup.pidOf("acme-tools.flame") == r.sup.pidOf("acme-tools.metrics")
    # The fresh snapshot: the restarted plugin draws the current stop.
    r.moveTo(77)
    check r.sup.waitUntil("snapshot", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:77"))
    check r.sup.faults.len == 1
    check r.sup.faults[0].kind == fkCrash
    r.sup.shutdown()

  test "a plugin that segfaults on activation: blamed by name, siblings restarted at most 3 times":
    var r = newRig("segfault")
    r.both()
    check r.sup.waitUntil("flame breaker open", proc(): bool =
      r.sup.slot("acme-tools.flame").breaker == bsOpen)
    check r.sup.waitUntil("metrics alone", proc(): bool =
      r.active("acme-tools.metrics"))
    let flameFaults = r.sup.faults.filterIt(it.plugin == "acme-tools.flame")
    check flameFaults.len >= 1
    check flameFaults.len <= 3
    check r.sup.faults.allIt(it.plugin == "acme-tools.flame")
    check flameFaults[0].detail.contains("SIGSEGV")
    check r.sup.notifications[0].text.contains("Plugin 'acme-tools.flame' was stopped")
    let pid = r.sup.pidOf("acme-tools.metrics")
    r.sup.settle(500)
    check r.sup.pidOf("acme-tools.metrics") == pid   # never restarted again
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    r.sup.shutdown()

  test "a handler that loops forever is attributed by the watchdog":
    var r = newRig("hang-invoke", tune = proc(s: Supervisor) = discard)
    r.sup.busyHangMs = 1_500
    r.sup.pingBusyMs = 100
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("hang fault", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkHang))
    let f = r.sup.faults.filterIt(it.kind == fkHang)[0]
    check f.plugin == "acme-tools.flame"
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    check r.sup.waitUntil("metrics back", proc(): bool = r.active("acme-tools.metrics"))
    r.sup.shutdown()

  test "a flood is rate limited and becomes a strike; the sibling is unaffected":
    var r = newRig("flood")
    # The bucket is the subject, not its size: a smaller one is breached on a
    # debug build at load 150 as surely as the spec's is on a release build.
    r.sup.setRateLimit(50, 100)
    r.sup.floodStrikeAfterMs = 200
    r.both()
    check r.sup.waitUntil("flood strike", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkFlood))
    check r.sup.slot("acme-tools.flame").droppedMessages > 0
    check r.sup.faults.filterIt(it.kind == fkFlood).allIt(it.plugin == "acme-tools.flame")
    check r.sup.waitUntil("metrics drawn", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim"))
    r.sup.shutdown()

  test "a handler error is that plugin's, and the process keeps running":
    var r = newRig("raise")
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let pid = r.sup.pidOf("acme-tools.flame")
    let id = r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("error", proc(): bool =
      r.sup.answers.anyIt(it.id == id and it.kind == "error"))
    check r.sup.slot("acme-tools.flame").lastFault.contains("flame data is unreadable")
    check r.sup.pidOf("acme-tools.flame") == pid
    r.sup.shutdown()

  test "unattributed exits strike every plugin, then quarantine separates them":
    var r = newRig("exit")
    r.sup.strikesToOpen = 10
    r.both()
    for round in 1 .. 2:
      check r.sup.waitUntil("active " & $round, proc(): bool =
        r.active("acme-tools.flame") and r.active("acme-tools.metrics"))
      discard r.sup.invoke("acme-tools.flame", "flame.refresh")
      check r.sup.waitUntil("fault " & $round, proc(): bool =
        r.sup.faults.len >= round)
    check r.sup.packages["acme-tools"].quarantined
    check r.sup.waitUntil("each in its own process", proc(): bool =
      r.active("acme-tools.flame") and r.active("acme-tools.metrics"))
    check r.sup.pidOf("acme-tools.flame") != r.sup.pidOf("acme-tools.metrics")
    # The next fault is attributed by construction.
    let before = r.sup.slot("acme-tools.metrics").totalStrikes
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("third fault", proc(): bool = r.sup.faults.len >= 3)
    check r.sup.faults[^1].plugin == "acme-tools.flame"
    check r.sup.slot("acme-tools.metrics").totalStrikes == before
    r.sup.shutdown()

  test "a frame of garbage is a protocol violation, and the process is restarted":
    var r = newRig("protocol")
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("violation", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkProtocol))
    check r.sup.waitUntil("back", proc(): bool = r.active("acme-tools.metrics"))
    r.sup.shutdown()

suite "§11.2.2, §11.3, §11.4.2: what the host refuses to load":

  test "a native package whose plugin does not declare `process` is refused":
    var doc = packageManifest()
    doc["plugins"][1]["capabilities"] = %*[]
    doc["plugins"][1].delete("traceEgress")
    let pkg = parsePluginPackage($doc, "plugin.json", "acme-tools")
    let errs = pkg.allErrors
    check errs.anyIt(it.code == pecNativeWithoutProcess and
                     it.plugin == "acme-tools.flame")
    check not pkg.isOk

  test "a plugin id outside the package's namespace is refused":
    var doc = packageManifest()
    doc["plugins"][0]["id"] = %"other.metrics"
    let pkg = parsePluginPackage($doc, "plugin.json", "acme-tools")
    check pkg.allErrors.anyIt(it.code == pecPluginIdComponentMismatch and
                              it.plugin == "other.metrics")

  test "a third-party surface declaring a native view is refused":
    var doc = packageManifest()
    doc["plugins"][0]["contributes"]["pane"][0]["nativeViews"] = %*["terminal"]
    let pkg = parsePluginPackage($doc, "plugin.json", "acme-tools")
    check pkg.allErrors.anyIt(it.code == pecNativeViewRefused)

  test "a process whose plugin list differs from the manifest fails to load, naming the plugin":
    var doc = packageManifest()
    var ghost = doc["plugins"][0].copy
    ghost["id"] = %"acme-tools.ghost"
    doc["plugins"].add ghost
    var r = newRig(manifest = $doc)
    r.sup.activate("acme-tools.metrics")
    check r.sup.waitUntil("load error", proc(): bool =
      r.sup.packages["acme-tools"].loadErrors.len > 0)
    check r.sup.packages["acme-tools"].loadErrors.anyIt(
      it.contains("acme-tools.ghost"))
    check r.sup.report().contains("acme-tools.ghost")
    r.sup.settle(200)
    check r.sup.processIds.len == 0
    r.sup.shutdown()

  test "a plugin binding the palette key or the recovery chord is refused, by name":
    var doc = packageManifest()
    doc["plugins"][0]["keybindings"].add %*{"key": "ctrl+shift+p",
                                            "command": "metrics.step"}
    doc["plugins"][1]["keybindings"] = %*[{"key": "escape escape escape",
                                           "command": "flame.refresh"}]
    var r = newRig(manifest = $doc)
    let errs = r.sup.bindingConflicts()
    check errs.anyIt(it.code == pecReservedKey and it.plugin == "acme-tools.metrics")
    check errs.anyIt(it.code == pecReservedKey and it.plugin == "acme-tools.flame")
    r.sup.shutdown()

proc inputManifest(): string =
  ## The package with `flame` declaring `capturesWindowInput`, which a window
  ## layer requires (§11.7.3).
  var doc = packageManifest()
  doc["plugins"][1]["capturesWindowInput"] = %*{"reason":
    "the misbehaving-plugin suite drives a layer that takes every printable key"}
  $doc

proc layerUp(r: Rig): bool =
  r.sup.waitUntil("layer pushed", proc(): bool =
    r.active("acme-tools.flame") and r.sup.slot("acme-tools.flame").layers.len == 1)

proc press(r: Rig; key: string): KeyRoute =
  ## A key through the plugin layers, as a front-end's router sends it.
  result = r.sup.resolveLayerKey(key, "")
  if result.found:
    discard r.sup.routeKey(result, key)

suite "§11.7.3: plugin layers":

  test "a window-capturing plugin runs in its own process instance":
    var r = newRig("swallow-input", manifest = inputManifest())
    r.both()
    check r.layerUp()
    check r.sup.waitUntil("metrics", proc(): bool = r.active("acme-tools.metrics"))
    check r.sup.pidOf("acme-tools.flame") != r.sup.pidOf("acme-tools.metrics")
    check r.sup.topLayerLabel == "FLAME MODE (acme-tools.flame)"
    r.sup.shutdown()

  test "a window layer from a plugin that did not declare capturesWindowInput is refused":
    var r = newRig("swallow-input")
    r.both()
    check r.sup.waitUntil("refused", proc(): bool =
      r.sup.slot("acme-tools.flame").refusals.anyIt(it.contains("capturesWindowInput")))
    check r.sup.slot("acme-tools.flame").layers.len == 0
    r.sup.shutdown()

  test "no plugin layer is consulted while a host modal is open":
    var r = newRig("swallow-input", manifest = inputManifest())
    r.both()
    check r.layerUp()
    var modal = true
    r.sup.hostModalOpen = proc(): bool = modal
    check not r.sup.resolveLayerKey("j", "").found
    modal = false
    check r.sup.resolveLayerKey("j", "").found
    r.sup.shutdown()

suite "§11.7.4, §11.7.5: input deadlines and the breaker":

  test "a plugin that swallows keys loses the keyboard: dropped, transparent, then open":
    var r = newRig("swallow-input", manifest = inputManifest(),
                   tune = proc(s: Supervisor) = discard)
    r.sup.inputDeadlineMs = InputDeadlineMs     # the subject: the spec's value
    r.both()
    check r.layerUp()
    # Key 1 goes to the plugin and is never acknowledged.
    check r.press("j").found
    check r.sup.waitUntil("missed deadline", proc(): bool =
      r.sup.slot("acme-tools.flame").suspect)
    check r.sup.statusLine == "`j` went to acme-tools.flame, which did not answer"
    check r.sup.slot("acme-tools.flame").strikes.len == 1
    check r.sup.enablementOf("acme-tools.flame", "flame.refresh").reason ==
      "plugin not responding"
    # Key 2 falls through to whatever is below the layer.
    check not r.press("k").found
    check r.sup.slot("acme-tools.flame").breaker == bsClosed
    # Key 3: the third strike opens the breaker and the layer is gone.
    check not r.press("l").found
    check r.sup.slot("acme-tools.flame").breaker == bsOpen
    check r.sup.slot("acme-tools.flame").layers.len == 0
    check r.sup.allLayers.len == 0
    r.sup.shutdown()

  test "a key acknowledged under the deadline is no strike, and its latency is recorded":
    var r = newRig("slow-ack", manifest = inputManifest())
    r.sup.inputDeadlineMs = 10_000   # widened: 300 ms is the subject, not the clock
    r.sup.configure("acme-tools.flame", true, %*{"mode": "slow-ack", "ackDelayMs": 300})
    r.both()
    check r.layerUp()
    check r.press("j").found
    check r.sup.waitUntil("acked", proc(): bool =
      r.sup.slot("acme-tools.flame").ackSamples.len == 1)
    let s = r.sup.slot("acme-tools.flame")
    check s.ackSamples[0] >= 300
    check s.slowAcks == 1
    check s.strikes.len == 0
    check not s.suspect
    check r.sup.report().contains("ack p50")
    r.sup.shutdown()

  test "a plugin killed while holding a layer: the layer goes at once, the next key falls through":
    var r = newRig("swallow-input", manifest = inputManifest())
    r.both()
    check r.layerUp()
    let pid = r.sup.pidOf("acme-tools.flame")
    discard kill(Pid(pid), SIGKILL)
    check r.sup.waitUntil("crash seen", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkCrash))
    check not r.sup.resolveLayerKey("j", "").found
    # A crash while holding an input layer opens the breaker at once.
    check r.sup.slot("acme-tools.flame").breaker == bsOpen
    r.sup.shutdown()

  test "half-open after the backoff; one strike reopens; the third opening latches until Re-enable":
    var r = newRig("swallow-input", manifest = inputManifest())
    r.sup.inputDeadlineMs = 300
    r.sup.breakerBackoffMs = 200
    r.sup.strikesToOpen = 1
    r.both()
    for opening in 1 .. 3:
      check r.layerUp()
      check r.press("j").found
      check r.sup.waitUntil("open " & $opening, proc(): bool =
        r.sup.slot("acme-tools.flame").openings == opening)
      if opening < 3:
        check not r.sup.slot("acme-tools.flame").latched
        check r.sup.waitUntil("half-open " & $opening, proc(): bool =
          r.sup.slot("acme-tools.flame").breaker == bsHalfOpen)
    check r.sup.slot("acme-tools.flame").latched
    r.sup.settle(600)
    check r.sup.slot("acme-tools.flame").breaker == bsOpen
    check r.sup.stateOf(r.sup.slot("acme-tools.flame")) == "stopped until re-enabled"
    r.sup.reEnable("acme-tools.flame")
    check r.sup.slot("acme-tools.flame").breaker == bsHalfOpen
    check r.layerUp()
    r.sup.shutdown()

suite "§11.7.6: the escape no plugin can capture":

  test "three Escapes pop a layer that binds Escape, and open the recovery dialog":
    var r = newRig("swallow-input", manifest = inputManifest())
    r.both()
    check r.layerUp()
    check r.sup.resolveLayerKey("escape", "").found   # the plugin binds it
    check not r.sup.observeEscape()
    check not r.sup.observeEscape()
    check r.sup.observeEscape()
    check r.sup.recoveryOpen
    check r.sup.recoveryPlugins == @["acme-tools.flame"]
    check r.sup.allLayers.len == 0
    check not r.sup.resolveLayerKey("escape", "").found
    r.sup.disableAllForSession()
    check r.sup.waitUntil("no process", proc(): bool = r.sup.processIds.len == 0)
    r.sup.shutdown()

  test "a healthy plugin whose layer the chord popped answers a probe and gets its bindings back":
    # The chord is not evidence about the plugin (the user may simply have
    # pressed Escape three times), so the host asks the process at once
    # instead of waiting for an `ack` that can never come: a suspect plugin
    # receives no key and no command. Both ping intervals are widened far past
    # the ceiling, so only the chord's own probe can clear it in time.
    var r = newRig("slow-ack", manifest = inputManifest(),
                   tune = proc(s: Supervisor) =
                     s.pingIdleMs = 600_000
                     s.pingBusyMs = 600_000)
    r.sup.configure("acme-tools.flame", true,
                    %*{"mode": "slow-ack", "ackDelayMs": 0})
    r.both()
    check r.layerUp()
    check r.sup.waitUntil("enablement pushed", proc(): bool =
      r.sup.enablementOf("acme-tools.flame", "flame.refresh").enabled)
    check not r.sup.observeEscape()
    check not r.sup.observeEscape()
    check r.sup.observeEscape()
    check r.sup.recoveryPlugins == @["acme-tools.flame"]
    check r.sup.slot("acme-tools.flame").layers.len == 0
    check r.sup.slot("acme-tools.flame").suspect
    check r.sup.waitUntil("answering again", proc(): bool =
      not r.sup.slot("acme-tools.flame").suspect)
    check r.sup.enablementOf("acme-tools.flame", "flame.refresh").enabled
    check r.sup.events.anyIt(it.contains(
      "acme-tools.flame is answering again; its layers and bindings are back"))
    let id = r.sup.invoke("acme-tools.flame", "flame.refresh")
    check id.len > 0
    check r.sup.waitUntil("refresh done", proc(): bool =
      r.sup.answers.anyIt(it.id == id and it.kind == "done"))
    r.sup.shutdown()

  test "the chord does not launder a missed input deadline: pongs do not clear it":
    # The negative control of the probe above: a plugin that missed an input
    # deadline is suspect on evidence, and its watchdog still answers pings
    # (it is not busy; it simply never acknowledges). Only an `ack` may clear
    # that suspicion, before the chord and after it.
    var r = newRig("swallow-input", manifest = inputManifest(),
                   tune = proc(s: Supervisor) =
                     s.pingIdleMs = 50
                     s.pingBusyMs = 50)
    r.sup.inputDeadlineMs = InputDeadlineMs     # the subject: the spec's value
    r.both()
    check r.layerUp()
    check r.press("j").found
    check r.sup.waitUntil("missed deadline", proc(): bool =
      r.sup.slot("acme-tools.flame").suspect)
    check not r.sup.observeEscape()
    check not r.sup.observeEscape()
    check r.sup.observeEscape()
    check r.sup.recoveryPlugins == @["acme-tools.flame"]
    let pid = r.sup.pidOf("acme-tools.flame")
    proc pongs(): int =
      for inst in r.sup.packages["acme-tools"].instances:
        if not inst.link.isNil and int(inst.link.pid) == pid:
          return inst.pongs
    let before = pongs()
    check r.sup.waitUntil("several pongs after the chord", proc(): bool =
      pongs() >= before + 3)
    check r.sup.pidOf("acme-tools.flame") == pid
    check r.sup.slot("acme-tools.flame").suspect
    check r.sup.enablementOf("acme-tools.flame", "flame.refresh").reason ==
      "plugin not responding"
    check not r.sup.events.anyIt(it.contains("is answering again"))
    r.sup.shutdown()

  test "bisect halves the enabled plugins per step":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("both", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame"))
    let b = r.sup.startBisect()
    check b.disabled == @["acme-tools.metrics"]
    check r.sup.slot("acme-tools.metrics").sessionDisabled
    r.sup.answerBisect(b, problemRemains = true)
    check b.culprit == "acme-tools.flame"
    check not r.sup.slot("acme-tools.metrics").sessionDisabled
    r.sup.shutdown()

suite "§11.7.2: the plugin pass and pushed state":

  test "a static binding resolves on the plugin's last pushed context, never asking it":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("context pushed", proc(): bool =
      r.sup.contextKeys.getOrDefault("plugin.acme-tools.metrics.ready", false))
    let route = r.sup.resolveStaticKey("ctrl+alt+m", "")
    check route.found
    check route.plugin == "acme-tools.metrics"
    check route.op == "metrics.step"
    # Before activation, an operation is disabled with "plugin starting".
    var cold = newRig()
    check cold.sup.enablementOf("acme-tools.metrics", "metrics.step").reason ==
      "plugin starting"
    r.sup.shutdown()
    cold.sup.shutdown()

suite "§11.10: the in-process view path is bounded":

  test "a compiled-in view slower than its budget is a fault, and stops being called":
    # The one in-process plugin here is real code compiled into this suite,
    # which is what §11.10 keeps the path for. No stand-in.
    const SlowManifest = """{
  "id": "acme.slow", "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [ { "event": "trace-opened" } ],
  "contributes": { "pane": [ { "id": "slow", "title": "Slow", "views": ["Text"] } ] }
}"""
    var calls = 0
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(SlowManifest, "slow.json", proc(ctx: PluginContext) =
      ctx.contributeView("slow", proc(): ViewNode =
        inc calls
        os.sleep(60)
        viewText("slow.text", "slow")))
    host.resolveAll()
    discard host.activateFor(ActivationEvent(kind: aeTraceOpened))
    host.surfaces.viewBudget = initDuration(milliseconds = 20)
    for i in 1 .. 6:
      discard host.renderSurface("acme.slow/slow")
    check calls == DefaultSurfaceFaultLimit
    check host.surfaces.isPluginDisabled("acme.slow")
    check host.surfaces.faults[0].message.contains("budget")

suite "§11.11: the measured transport":

  test "invoke/ack round trip and a 1,000-node view over the pipe":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.metrics"))
    var samples: seq[int]
    for i in 0 ..< 200:
      let id = r.sup.invoke("acme-tools.metrics", "metrics.echo", %*{"key": "x"},
                            key = "x")
      let t0 = monotonicMs()
      check r.sup.waitUntil("echo", proc(): bool =
        r.sup.answers.anyIt(it.id == id))
      samples.add int(monotonicMs() - t0)
      discard r.sup.takeAnswers(id)
    let (p50, p99) = r.sup.slot("acme-tools.metrics").latency
    echo "MEASURE invoke/ack over a pipe, 200 keys: ack p50 ", p50, " ms, p99 ",
         p99, " ms; answer p50 ", samples.sorted[100], " ms"
    # A 1,000-node tree pushed by the plugin, from the query that asks for it
    # to the host holding the decoded tree.
    var viewSamples: seq[int]
    for i in 0 ..< 50:
      let t0 = monotonicMs()
      let id = r.sup.query("acme-tools.metrics", "bigview", %*{"n": i})
      check r.sup.waitUntil("bigview", proc(): bool =
        r.sup.answers.anyIt(it.id == id) and
        r.sup.renderSurface("acme-tools.metrics/overview").allText.contains(
          "seq " & $i & " "))
      viewSamples.add int(monotonicMs() - t0)
      discard r.sup.takeAnswers(id)
    viewSamples.sort()
    check r.sup.renderSurface("acme-tools.metrics/overview").children.len == 1000
    echo "MEASURE a 1,000-node view tree over a pipe, 50 pushes: p50 ",
         viewSamples[25], " ms, p99 ", viewSamples[^1], " ms"
    r.sup.shutdown()
