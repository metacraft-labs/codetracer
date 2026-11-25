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

import std/[algorithm, json, net, os, posix, sequtils, strutils, tables, times, unittest]

import isonim/core/[computation, owner, signals]

import codetracer_embed
import ../../../../common/value_presentation/[presenter, vocabulary as value_vocabulary]
import ../../../../common/value_presentation/json_adapter
from ../../../../common/value_presentation/surfaces import StatePanelBudget
import backend/mock_backend
import ../../../../common/plugin_model
import plugin_host/[host, process_link, protocol, supervisor, surface_host]
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

  test "a settings change made while the plugin is activating still reaches it":
    # `activate` carries the settings of the moment it is sent. A change made
    # before `activated` comes back is the change the user made last, and the
    # plugin must end up with it. The wait stops in that window: the poll that
    # sends `activate` cannot also read its answer, because the write is
    # flushed at the end of that poll.
    var r = newRig()
    r.sup.configure("acme-tools.metrics", true, %*{"label": "speed"})
    r.both()
    check r.sup.waitUntil("activating", proc(): bool =
      r.sup.slot("acme-tools.metrics").activating)
    check not r.active("acme-tools.metrics")
    r.sup.settingsChanged("acme-tools.metrics", %*{"label": "fast"})
    check r.sup.waitUntil("new label", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("label fast"))
    r.sup.shutdown()

suite "PLAT-12's plugin tier: a plugin that publishes visualisers":

  test "a published `visualisers` ViewModel becomes ptPlugin-tier visualisers":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("published", proc(): bool =
      r.sup.pluginVisualisers().len == 2)
    let vs = r.sup.pluginVisualisers()
    let v = vs[0]
    check v.tier == ptPlugin
    check v.tierDeclared
    check v.typeMatch == "Matrix"
    check v.summary == "matrix (acme-tools)"
    check v.id == "plugin:acme-tools.metrics#matrix"
    # A row that only hides a field is read with what it hides.
    let secret = vs.filterIt(it.typeMatch == "Account")
    check secret.len == 1
    check secret.len == 1 and secret[0].hide == @["password"]
    check secret.len == 1 and secret[0].tier == ptPlugin
    # A row the presenter's door refuses (a hidden "field" that is a path) is
    # dropped; the plugin's other rows still render.
    check not vs.anyIt(it.typeMatch == "Broken")
    # Its breaker open, the plugin contributes nothing.
    r.sup.setEnabled("acme-tools.metrics", false, persist = false)
    check r.sup.pluginVisualisers().len == 0
    r.sup.shutdown()

  test "a plugin computes answers for the values on screen; an answer for another stop is never shown":
    var r = newRig()
    r.sup.configure("acme-tools.metrics", true, %*{"computeVisualiser": true})
    r.both()
    check r.sup.waitUntil("rows published", proc(): bool =
      r.sup.pluginVisualisers().len == 2)
    # A computed row with no answers yet claims nothing.
    check not r.sup.pluginVisualisers().anyIt(it.computedDeclared)
    let fortyTwo = toPValue(%42)
    let seven = toPValue(%7)
    let asked = @[(input: executableInputOf(fortyTwo), typeName: "int"),
                  (input: executableInputOf(seven), typeName: "int")]
    let before = r.sup.visualiserRevision
    r.sup.requestVisualisations(asked)
    check r.sup.waitUntil("answered", proc(): bool =
      r.sup.pluginVisualisers().anyIt(it.computedDeclared))
    check r.sup.visualiserRevision > before
    let computed = r.sup.pluginVisualisers().filterIt(it.computedDeclared)
    check computed.len == 1
    check computed.len == 1 and computed[0].id == "plugin:acme-tools.metrics#readings"
    check computed.len == 1 and computed[0].tier == ptPlugin
    # The presenter renders the value with the plugin's answer.
    let vis = r.sup.pluginVisualisers()
    check present(fortyTwo, StatePanelBudget,
                  presenters = withVisualisers(vis)).root.text == "acme=" & executableInputOf(fortyTwo)
    check present(seven, StatePanelBudget,
                  presenters = withVisualisers(vis)).root.text == "acme=" & executableInputOf(seven)
    # The debugger moves: the answers were computed at the old stop and are
    # not shown at the new one.
    r.moveTo(11)
    check not r.sup.pluginVisualisers().anyIt(it.computedDeclared)
    # Asked at the new stop (before the turn that cuts its batch: the query
    # waits for it), answered there.
    r.sup.requestVisualisations(asked[0 .. 0])
    check r.sup.waitUntil("answered again", proc(): bool =
      r.sup.pluginVisualisers().anyIt(it.computedDeclared))
    let again = r.sup.pluginVisualisers().filterIt(it.computedDeclared)
    check again.len == 1 and again[0].computed.len == 1
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

  test "a front-end's own route takes a relayed action, and its refusal is the plugin's, by name":
    var r = newRig()
    var taken: seq[string]
    r.sup.actionHook = proc(msg: JsonNode; refusal: var string): bool =
      let name = msg{"vm"}.getStr("") & "." & msg{"action"}.getStr("")
      if name == "state.addWatch":
        refusal = "the front-end cannot show a watch here"
        return false
      taken.add name
      true
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.metrics"))
    r.mock.clearReceivedCommands()
    # Taken by the front-end: counted as applied, never sent behind it.
    discard r.sup.invoke("acme-tools.metrics", "metrics.step")
    check r.sup.waitUntil("taken", proc(): bool =
      r.sup.slot("acme-tools.metrics").actionsApplied == 1)
    check taken == @["debugControls.stepForward"]
    check r.mock.receivedCommands.len == 0
    # Refused: on the status line and in the plugin's refusals, and never
    # applied to the session.
    let watches = r.session.stateVM.watchExpressions.val.len
    discard r.sup.invoke("acme-tools.metrics", "metrics.watch")
    check r.sup.waitUntil("refused", proc(): bool =
      r.sup.slot("acme-tools.metrics").refusals.anyIt(
        it.contains("cannot show a watch")))
    check r.sup.statusLine.contains("acme-tools.metrics")
    check r.sup.statusLine.contains("cannot show a watch")
    check r.session.stateVM.watchExpressions.val.len == watches
    check r.sup.slot("acme-tools.metrics").actionsApplied == 1
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

  test "a pong queued behind a large frame is not a hang":
    # The frame takes ~2 s to drain, under the frame lock, so the watchdog's
    # pong waits behind it; the deadline is 300 ms. Bytes arriving are the
    # plugin answering.
    var r = newRig("trickle", tune = proc(s: Supervisor) = discard)
    r.sup.pongDeadlineMs = 300
    r.sup.pingBusyMs = 50
    r.sup.pingIdleMs = 50
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let pids = r.sup.processIds
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("the whole frame arrived", proc(): bool =
      r.sup.renderSurface("acme-tools.flame/flame").allText.contains("frame 1999"))
    check not r.sup.faults.anyIt(it.kind == fkHang)
    check r.sup.processIds == pids
    check r.sup.slot("acme-tools.flame").totalStrikes == 0
    # Silence is still a hang: stopped, it sends nothing, and is restarted.
    check kill(Pid(pids[0]), SIGSTOP) == 0
    check r.sup.waitUntil("a stopped process is hung", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkHang))
    discard kill(Pid(pids[0]), SIGCONT)
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

  test "a flooding plugin's relayed action and its answer still arrive":
    # The bucket drops what a plugin pushes past the limit, never its replies
    # or its actions: `flame.refresh` floods, then relays a watch and answers,
    # so both reach the host behind its own pushes with the bucket empty.
    var r = newRig("flood-relay")
    r.sup.setRateLimit(50, 100)
    r.sup.floodStrikeAfterMs = 60_000   # the drops are the subject, not the strike
    var taken: seq[string]
    r.sup.actionHook = proc(msg: JsonNode; refusal: var string): bool =
      taken.add msg{"vm"}.getStr("") & "." & msg{"action"}.getStr("") & " " &
        msg{"args"}{"expression"}.getStr("")
      true
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let id = r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("answered", proc(): bool =
      r.sup.answers.anyIt(it.id == id and it.kind == "done"))
    check r.sup.slot("acme-tools.flame").droppedMessages > 0
    check taken == @["state.addWatch after-flood"]
    check r.sup.slot("acme-tools.flame").actionsApplied == 1
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

  test "the dialog names a plugin that held the keyboard during the chord, even if its breaker took the layer first":
    # Under load a layer that swallowed the first Escapes lost it to its own
    # breaker before the third was read, and the dialog said "the plugins that
    # held the keyboard: none". The Escapes carry their arrival times (inside
    # the chord's window, however long the breaker takes to open here).
    var r = newRig("swallow-input", manifest = inputManifest())
    r.sup.inputDeadlineMs = 200
    r.sup.strikesToOpen = 1
    r.both()
    check r.layerUp()
    check not r.sup.observeEscape(arrivedMs = 1_000)
    # The swallowed key's deadline passes: one strike opens the breaker, and
    # the layer goes before the chord is complete.
    check r.press("j").found
    check r.sup.waitUntil("breaker open, layer gone", proc(): bool =
      r.sup.slot("acme-tools.flame").breaker == bsOpen and
        r.sup.slot("acme-tools.flame").layers.len == 0)
    check not r.sup.observeEscape(arrivedMs = 1_100)
    check r.sup.observeEscape(arrivedMs = 1_200)
    check r.sup.recoveryPlugins == @["acme-tools.flame"]
    r.sup.shutdown()

  test "the chord landing while a routine ping is in flight still probes the plugin":
    # The race the case above leaves to timing, made certain: the process is
    # stopped so a routine ping is OUTSTANDING when the chord fires (the chord
    # then sends no probe of its own), and both intervals are widened past the
    # ceiling. The pong to that pre-chord ping cannot clear the plugin; the
    # host must ask again (`chordProbeMs`) and that answer does.
    var r = newRig("slow-ack", manifest = inputManifest(),
                   tune = proc(s: Supervisor) =
                     s.pingIdleMs = 50
                     s.pingBusyMs = 50
                     s.pongDeadlineMs = 120_000)
    r.sup.configure("acme-tools.flame", true,
                    %*{"mode": "slow-ack", "ackDelayMs": 0})
    r.both()
    check r.layerUp()
    let pid = r.sup.pidOf("acme-tools.flame")
    check pid > 0
    check kill(Pid(pid), SIGSTOP) == 0
    # Stopped, it answers nothing: within a few 50 ms intervals a ping is out
    # and stays out.
    let t0 = epochTime()
    discard r.sup.waitUntil("a ping in flight", proc(): bool =
      epochTime() - t0 > 0.5)
    r.sup.pingIdleMs = 600_000
    r.sup.pingBusyMs = 600_000
    check not r.sup.observeEscape()
    check not r.sup.observeEscape()
    check r.sup.observeEscape()
    check r.sup.slot("acme-tools.flame").suspect
    check kill(Pid(pid), SIGCONT) == 0
    check r.sup.waitUntil("answering again", proc(): bool =
      not r.sup.slot("acme-tools.flame").suspect)
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
    # The context key and the operation's enablement are separate pushes;
    # the binding resolves only once both arrived (it read false 1 run in 6
    # at load ~150, waiting on the context key alone).
    check r.sup.waitUntil("context and enablement pushed", proc(): bool =
      r.sup.contextKeys.getOrDefault("plugin.acme-tools.metrics.ready", false) and
        r.sup.enablementOf("acme-tools.metrics", "metrics.step").enabled)
    let route = r.sup.resolveStaticKey("ctrl+alt+m", "")
    check route.found
    check route.plugin == "acme-tools.metrics"
    check route.op == "metrics.step"
    # The modifiers' spelling is folded: the terminal's canonical name for
    # the chord (what `CSI 109 ; 7 u` decodes to) is the same binding.
    check r.sup.resolveStaticKey("Ctrl+Alt+m", "").found
    check r.sup.claimsKey("Ctrl+Alt+m", "")
    check not r.sup.claimsKey("Ctrl+m", "")
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

proc pluginLog(r: Rig): string =
  ## Everything the package's processes wrote to stdout and stderr: the
  ## plugin log the supervisor keeps under `logDir`.
  for f in walkFiles(r.sup.logDir / "*.stderr.log"):
    result.add readFile(f)

proc answerOf(r: Rig; id: string): JsonNode =
  for a in r.sup.answers:
    if a.id == id and a.kind == "answer":
      return a.payload{"value"}

proc invokeAndWait(r: Rig; plugin, op: string; args: JsonNode): JsonNode =
  let id = r.sup.invoke(plugin, op, args)
  doAssert id.len > 0, "invoke " & op & " was not sent"
  doAssert r.sup.waitUntil(op & " answered", proc(): bool =
    not r.answerOf(id).isNil), op & " was not answered"
  r.answerOf(id)

suite "§11.4.1: the protocol is not on the standard streams":

  test "a plugin that writes to stdout does not break the protocol; what it wrote is in its log":
    var r = newRig("echo")
    r.both()
    check r.sup.waitUntil("both active", proc(): bool =
      r.active("acme-tools.flame") and r.active("acme-tools.metrics"))
    let pid = r.sup.pidOf("acme-tools.flame")
    let id = r.sup.invoke("acme-tools.flame", "flame.refresh")
    check r.sup.waitUntil("done", proc(): bool =
      r.sup.answers.anyIt(it.id == id and it.kind == "done"))
    check r.sup.waitUntil("the refreshed pane", proc(): bool =
      r.sup.renderSurface("acme-tools.flame/flame").allText.contains("echoed"))
    check r.sup.waitUntil("the echo in the log", proc(): bool =
      r.pluginLog.contains("flame: refreshing (a line on stdout)"))
    check r.pluginLog.contains("flame: activating (a line on stdout)")
    # The bytes shaped like a frame went to the log as well, not the protocol.
    check r.pluginLog.contains("hello")
    check r.sup.faults.len == 0
    check r.sup.pidOf("acme-tools.flame") == pid
    r.sup.shutdown()

suite "§11.5: timers and async continuations are attributed to their plugin":

  test "a timer that loops forever is attributed by the watchdog":
    var r = newRig("timer-hang")
    r.sup.busyHangMs = 1_500
    r.sup.pingBusyMs = 100
    r.sup.pingIdleMs = 100
    r.both()
    check r.sup.waitUntil("hang fault", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkHang))
    let f = r.sup.faults.filterIt(it.kind == fkHang)[0]
    check f.plugin == "acme-tools.flame"
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    r.sup.shutdown()

  test "a timer that raises is its plugin's error, and the process keeps running":
    var r = newRig("timer-raise")
    r.both()
    check r.sup.waitUntil("the error", proc(): bool =
      r.sup.slot("acme-tools.flame").lastFault.contains(
        "flame's timer could not read its data"))
    let pid = r.sup.pidOf("acme-tools.flame")
    r.sup.settle(300)
    check r.sup.pidOf("acme-tools.flame") == pid
    check r.active("acme-tools.metrics")
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    check not r.sup.faults.anyIt(it.kind in {fkCrash, fkHang})
    r.sup.shutdown()

  test "an async continuation that loops forever is attributed by the watchdog":
    var r = newRig("async-hang")
    r.sup.busyHangMs = 1_500
    r.sup.pingBusyMs = 100
    r.sup.pingIdleMs = 100
    r.both()
    check r.sup.waitUntil("hang fault", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkHang))
    let f = r.sup.faults.filterIt(it.kind == fkHang)[0]
    check f.plugin == "acme-tools.flame"
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    r.sup.shutdown()

  test "an async continuation that raises is its plugin's error, and the process keeps running":
    var r = newRig("async-raise")
    r.both()
    check r.sup.waitUntil("the error", proc(): bool =
      r.sup.slot("acme-tools.flame").lastFault.contains(
        "flame's continuation could not read its data"))
    let pid = r.sup.pidOf("acme-tools.flame")
    r.sup.settle(300)
    check r.sup.pidOf("acme-tools.flame") == pid
    check r.sup.slot("acme-tools.metrics").totalStrikes == 0
    check not r.sup.faults.anyIt(it.kind in {fkCrash, fkHang})
    r.sup.shutdown()

suite "§8.1: a native plugin's process and socket primitives":

  test "a declared program runs to completion; an undeclared one is refused by name":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let ran = r.invokeAndWait("acme-tools.flame", "flame.run",
      %*{"program": "sh", "args": ["-c", "echo to-stdout; echo to-stderr >&2; exit 4"]})
    check ran{"startError"}.getStr == ""
    check ran{"exitCode"}.getInt == 4
    check ran{"output"}.getStr.contains("to-stdout")
    check ran{"output"}.getStr.contains("to-stderr")
    let refused = r.invokeAndWait("acme-tools.flame", "flame.run",
      %*{"program": "ls", "args": ["/"]})
    check refused{"startError"}.getStr.contains("declared executable set")
    check refused{"pid"}.getInt == 0
    check r.sup.faults.len == 0
    r.sup.shutdown()

  test "a program past its deadline is killed with its whole process group":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let pidFile = r.dir.parentDir / "grandchild.pid"
    removeFile(pidFile)
    let ran = r.invokeAndWait("acme-tools.flame", "flame.run",
      # The deadline leaves a loaded host time to start `sh` and let it write
      # the pid (at 500 ms, load ~90 once killed `sh` before it had).
      %*{"program": "sh", "timeoutMs": 3_000,
         "args": ["-c", "sleep 600 & echo $! > " & pidFile & "; wait"]})
    check ran{"timedOut"}.getBool
    check ran{"pid"}.getInt > 0
    check fileExists(pidFile)
    let grandchild = parseInt(readFile(pidFile).strip)
    check r.sup.waitUntil("the grandchild is gone", proc(): bool =
      not pidAlive(grandchild))
    check not pidAlive(ran{"pid"}.getInt)
    r.sup.shutdown()

  test "a loopback listener and a connection; deactivation closes them and kills what it started":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame"))
    let listened = r.invokeAndWait("acme-tools.flame", "flame.listen", newJObject())
    let port = listened{"port"}.getInt(0)
    check port > 0
    # The plugin connects to its own listener over real loopback TCP.
    let echoed = r.invokeAndWait("acme-tools.flame", "flame.connect",
      %*{"port": port, "text": "hello, plugin"})
    check echoed{"reply"}.getStr == "HELLO, PLUGIN"
    # And so does this suite, as an outside peer would.
    var outside = newSocket()
    outside.connect("127.0.0.1", Port(port))
    outside.send(encodeFrame("from outside"))
    # `recv(size, timeout)` waits for exactly `size` bytes: one whole frame.
    let got = outside.recv(4 + "FROM OUTSIDE".len, timeout = Ceiling)
    check got.len >= 4 and got[4 .. ^1] == "FROM OUTSIDE"
    outside.close()
    let spawned = r.invokeAndWait("acme-tools.flame", "flame.spawn",
      %*{"args": ["-c", "sleep 600"]})
    let child = spawned{"pid"}.getInt(-1)
    check child > 0 and pidAlive(child)
    let handles = r.invokeAndWait("acme-tools.flame", "flame.handles", newJObject())
    check handles{"report"}.getStr.contains("sh (pid " & $child & ")")
    # Deactivation is what ends them.
    r.sup.deactivate("acme-tools.flame")
    check r.sup.waitUntil("inactive", proc(): bool = not r.active("acme-tools.flame"))
    check r.sup.waitUntil("its child is gone", proc(): bool = not pidAlive(child))
    check r.sup.waitUntil("its listener is closed", proc(): bool =
      var s = newSocket()
      defer: s.close()
      try:
        s.connect("127.0.0.1", Port(port))
        false
      except OSError:
        true)
    check r.active("acme-tools.metrics")
    r.sup.shutdown()

suite "§11.6.2: liveness has a channel of its own":

  test "a pong never waits behind a frame the plugin is writing (measured)":
    # The host stops reading the protocol while the plugin's handler writes
    # more than a pipe holds, so the plugin's main thread is blocked in a
    # write, holding the frame lock. The pongs must still come, and name
    # the plugin as busy.
    let root = scratchRoot() / ("liveness-" & $getpid())
    removeDir(root)
    createDir(root)
    let dir = installPackage(root)
    let link = spawnPluginProcess(dir / "bin" / "acme-tools-plugins")
    defer:
      link.signalGroup(SIGKILL)
      while not link.pollExit(): os.sleep(2)
      link.closeAll()
    proc pump(cond: proc(m: JsonNode): bool): bool =
      let start = monotonicMs()
      while monotonicMs() - start < Ceiling:
        link.flushWrites()
        for f in link.readMessages():
          if cond(parseJson(f)): return true
        os.sleep(2)
      false
    check link.send(hostHello("1.0.0", "tui", "linux"))
    check pump(proc(m: JsonNode): bool = m{"type"}.getStr == "hello")
    check link.send(%*{"type": "activate", "plugin": "acme-tools.metrics",
      "grants": ["process"], "settings": {}, "epoch": Epoch(session: "s1").toJson})
    check pump(proc(m: JsonNode): bool = m{"type"}.getStr == "activated")
    check link.send(%*{"type": "invoke", "plugin": "acme-tools.metrics",
      "id": "flood", "op": "metrics.views", "args": {"count": 400}})
    link.flushWrites()
    var seqNo = 0
    proc ping(): JsonNode =
      ## One ping and its pong; nil when none came within five times the
      ## host's own deadline (a pong that late is the fault under test, and
      ## waiting longer would only slow the red down).
      inc seqNo
      let want = seqNo
      check link.send(%*{"type": "ping", "seq": want})
      link.flushWrites()
      let t0 = monotonicMs()
      while monotonicMs() - t0 < 5 * PongDeadlineMs:
        for f in link.readPongs():
          let m = parseJson(f)
          if m{"type"}.getStr == "pong" and m{"seq"}.getInt == want:
            m["latencyMs"] = %int(monotonicMs() - t0)
            return m
        os.sleep(1)
    # Wait on state, not time: ping until a pong names the plugin busy, so
    # its handler has started. A loaded host may take a while to get there.
    var started = false
    let waitFrom = monotonicMs()
    while not started and monotonicMs() - waitFrom < Ceiling:
      let pong = ping()
      check not pong.isNil
      if pong.isNil: break
      started = pong{"busy"}.getStr == "acme-tools.metrics"
      if not started: os.sleep(20)
    check started
    # From here the handler cannot finish: 400 trees are megabytes, and the
    # protocol is never read, so its main thread stays blocked in a write
    # holding the frame lock. Every pong must still come, and name it.
    var latencies: seq[int]
    var busyNamed = 0
    for i in 1 .. 40:
      let pong = ping()
      check not pong.isNil
      if pong.isNil: break
      latencies.add pong{"latencyMs"}.getInt
      if pong{"busy"}.getStr == "acme-tools.metrics": inc busyNamed
      os.sleep(20)
    check latencies.len == 40
    check busyNamed == 40
    let sortedL = latencies.sorted
    let p50 = sortedL[sortedL.len div 2]
    let p99 = sortedL[^1]
    check p99 < PongDeadlineMs
    var load = ""
    try: load = readFile("/proc/loadavg").splitWhitespace()[0]
    except CatchableError: discard
    echo "MEASURE pong latency with the protocol pipe full, 40 pings: p50 ", p50,
         " ms, p99 ", p99, " ms (busy named in ", busyNamed, "), load ", load

suite "§11.7: an invoke's ack does not wait for the main thread":

  test "a busy main thread does not hold back an autoAck plugin's ack (measured)":
    # The plugin's main thread is held in a query handler (`values` sleeps
    # `delayMs`), as a burst of signal batches or a fresh plugin's state
    # snapshot holds it in a loaded window. An `invoke` sent behind that
    # query must still be acknowledged at once: the reader thread acks an
    # autoAck plugin's invoke when it reads it. The answer comes only after
    # the query, so the order of the frames is the proof, and the latency is
    # the measurement.
    let root = scratchRoot() / ("early-ack-" & $getpid())
    removeDir(root)
    createDir(root)
    let dir = installPackage(root)
    let link = spawnPluginProcess(dir / "bin" / "acme-tools-plugins")
    defer:
      link.signalGroup(SIGKILL)
      while not link.pollExit(): os.sleep(2)
      link.closeAll()
    var seen: seq[JsonNode]   # every frame read since the round began
    var unmatched = 0         # the first frame `pump` has not looked at
    proc pump(cond: proc(m: JsonNode): bool): bool =
      ## Frames read in one batch after the one that matched are kept for the
      ## next call, not dropped.
      let start = monotonicMs()
      while true:
        while unmatched < seen.len:
          inc unmatched
          if cond(seen[unmatched - 1]): return true
        if monotonicMs() - start >= Ceiling: return false
        link.flushWrites()
        for f in link.readMessages():
          seen.add parseJson(f)
        os.sleep(1)
    check link.send(hostHello("1.0.0", "tui", "linux"))
    check pump(proc(m: JsonNode): bool = m{"type"}.getStr == "hello")
    check link.send(%*{"type": "activate", "plugin": "acme-tools.metrics",
      "grants": ["process"], "settings": {}, "epoch": Epoch(session: "s1").toJson})
    check pump(proc(m: JsonNode): bool = m{"type"}.getStr == "activated")
    var latencies: seq[int]
    for i in 1 .. 10:
      seen.setLen(0)
      unmatched = 0
      let qid = "busy-" & $i
      let iid = "key-" & $i
      check link.send(%*{"type": "query", "plugin": "acme-tools.metrics",
        "id": qid, "kind": "values", "input": {"delayMs": 1500}})
      link.flushWrites()
      # Wait on state: the main thread is inside the query once a pong
      # names the plugin busy.
      var busy = false
      var pingSeq = 0
      let waitFrom = monotonicMs()
      while not busy and monotonicMs() - waitFrom < Ceiling:
        inc pingSeq
        check link.send(%*{"type": "ping", "seq": pingSeq})
        link.flushWrites()
        let t0 = monotonicMs()
        while monotonicMs() - t0 < 10_000 and not busy:
          var answered = false
          for f in link.readPongs():
            let m = parseJson(f)
            if m{"seq"}.getInt == pingSeq:
              answered = true
              busy = m{"busy"}.getStr == "acme-tools.metrics"
          if answered: break
          os.sleep(2)
      check busy
      let t0 = monotonicMs()
      check link.send(%*{"type": "invoke", "plugin": "acme-tools.metrics",
        "id": iid, "op": "metrics.echo", "args": {"key": "k"}, "fromKey": true})
      check pump(proc(m: JsonNode): bool =
        m{"type"}.getStr == "ack" and m{"id"}.getStr == iid)
      latencies.add int(monotonicMs() - t0)
      # The query was still running: its answer had not come.
      check not seen.anyIt(it{"id"}.getStr == qid)
      check pump(proc(m: JsonNode): bool = m{"id"}.getStr == iid and
                                           m{"type"}.getStr == "answer")
      # Acked once: the main thread did not ack it again.
      check seen.countIt(it{"type"}.getStr == "ack" and
                         it{"id"}.getStr == iid) == 1
    let sortedL = latencies.sorted
    var load = ""
    try: load = readFile("/proc/loadavg").splitWhitespace()[0]
    except CatchableError: discard
    echo "MEASURE ack of an invoke behind a 1,500 ms handler, 10 keys: p50 ",
         sortedL[sortedL.len div 2], " ms, max ", sortedL[^1], " ms, load ", load
    check sortedL[^1] < 1500
