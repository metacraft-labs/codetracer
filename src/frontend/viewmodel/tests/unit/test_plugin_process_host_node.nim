## test_plugin_process_host_node.nim — plugins run out of process
## (Extensibility-Model.md §11) on the JavaScript backend: the same
## `Supervisor` the native front-ends run, compiled by `nim js` and run by
## Node, as the desktop's main process and `ct host` run it, starting REAL
## plugin processes through `process_link`'s `child_process` arm.
##
## The `acme-tools` test package (`plugin_packages/acme-tools/`) is built with
## the plugin SDK by `plugin_process_fixture` (the compiler that compiled this
## suite, run through Node) and installed as a component the way `ct install`
## lays one out. It is a native executable; Node spawns it. One executable
## hosts two plugins; `flame` misbehaves on request (its `mode` setting).
##
## What the C suite (`test_plugin_process_host.nim`) proves about the
## supervisor's rules, this one proves about the JavaScript link under them:
## the handshake and two plugins in one pid, crash attribution and restart (a
## signal NAME from Node read back as SIGSEGV), hang attribution, the stop
## sequence's SIGTERM to the group, `--no-extensions`, a start that fails, a
## child that stops reading its stdin (the write queue), and what ends a
## plugin when the main process ends — SIGTERM, and SIGKILL with and without
## `setpriv`. For the last three the suite starts ITSELF a second time as the
## main process (`--guard-child`), and kills that process.
##
## ## THE STAND-INS, AND WHY THEY ARE NOT MOCKS
##
## * The primary session is a real `SessionViewModel` over
##   `backend/mock_backend.MockBackendService`, as in the C suite and for the
##   same reason: these suites are about the plugin process, not the replay.
##   The debugger's stop is written into the store as a replay's answer would
##   write it. The real replay and the real recording are the desktop's and
##   `ct host`'s end-to-end suites'.
## * The write-queue case starts `sleep` (coreutils) as the "plugin": the
##   property is about a real child that never reads its stdin, and a real
##   process that never reads is the honest one. No plugin protocol is spoken
##   to it.
##
## ## TIME
##
## Every wait is on STATE, with a generous ceiling, and thresholds that are
## not the subject of a case are widened (the host's load is often above 100).
##
## Node only (`vm-unit-js`): it spawns processes through `child_process`.

import std/[asyncjs, json, jsffi, sequtils, strutils, tables]

import isonim/core/[owner, signals]

import ../../backend/mock_backend
import ../../session_vm
import ../../store/types
import ../../../../common/plugin_model
import ../../../../common/node_os
import ../../plugin_host/[protocol, process_link, supervisor]
import ./plugin_process_fixture

proc readFile(path: string): string = readFileBytes(path)

const Ceiling = 120_000

var checks, failures: int

proc ck(cond: bool; what: string) =
  inc checks
  if not cond:
    inc failures
    echo "  FAILED: ", what

proc sleep(ms: int): Future[void] {.importjs:
  "new Promise(function (r) { setTimeout(r, #); })".}

proc argv(): seq[cstring] {.importjs: "(process.argv)".}
proc scriptPath(): cstring {.importjs: "(process.argv[1])".}
proc nodeExe(): cstring {.importjs: "(process.execPath)".}
proc setEnv(k, v: cstring) {.importjs: "process.env[#] = #".}
proc deleteEnv(k: cstring) {.importjs: "delete process.env[#]".}
proc exitNow(code: int) {.importjs: "process.exit(#)".}

proc pidAlive(pid: int): bool {.importjs: """
  (function (pid) {
    if (!(pid > 0)) { return false; }
    try {
      var st = require('fs').readFileSync('/proc/' + pid + '/stat', 'utf8');
      var state = st.slice(st.lastIndexOf(')') + 2).split(' ')[0];
      return state !== 'Z' && state !== 'X';
    } catch (e) { }
    try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
  })(#)""".}

proc killPid(pid, sig: int) {.importjs: """
  (function (pid, sig) { try { process.kill(pid, sig); } catch (e) { } })(#, #)""".}

var onlySections: seq[string]
  ## `--only=<tag>,<tag>`: run those sections (the mutation harness grades an
  ## arm by the section that must kill it).

proc section(tag, title: string): bool =
  result = onlySections.len == 0 or tag in onlySections
  if result:
    echo title

proc waitUntil(sup: Supervisor; what: string; cond: proc(): bool;
               ceilingMs = Ceiling): Future[bool] {.async.} =
  let start = monotonicMs()
  while not cond():
    sup.poll()
    if monotonicMs() - start > ceilingMs:
      echo "  timed out waiting for: ", what, "\n", sup.report(),
        "\n  events:\n", sup.events[max(0, sup.events.len - 30) .. ^1].join("\n")
      return false
    await sleep(2)
  return true

proc settle(sup: Supervisor; ms: int): Future[void] {.async.} =
  let start = monotonicMs()
  while monotonicMs() - start < ms:
    sup.poll()
    await sleep(2)

proc shutdownAndWait(sup: Supervisor): Future[void] =
  ## `shutdown` on this backend returns at once and reports through `onDone`.
  newPromise(proc(resolve: proc()) =
    sup.shutdown(onDone = resolve))

type Rig = object
  sup: Supervisor
  session: SessionViewModel
  mock: MockBackendService
  dir: string

var rigCount = 0

proc newRig(flameMode = "normal"; extensions = true;
            removeExecutable = false): Rig =
  inc rigCount
  let root = scratchRoot() / ("node-rig-" & $getCurrentProcessId() & "-" & $rigCount)
  createDir(root)
  result.dir = installPackage(root)
  if removeExecutable:
    removeFile(result.dir / "bin" / "acme-tools-plugins")
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
  let sup = newSupervisor("desktop", "1.0.0", extensions)
  # Widened: not the subject of most cases (see the header).
  sup.pongDeadlineMs = 20_000
  sup.busyHangMs = 30_000
  sup.helloDeadlineMs = 60_000
  sup.inputDeadlineMs = 20_000
  sup.restartBaseMs = 10
  sup.restartCapMs = 50
  sup.logDir = root / "logs"
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
  if n.isNil: return ""
  result = n.label & " " & n.text
  for o in n.options: result.add " " & o.label
  for c in n.children: result.add " " & allText(c)

proc bothActive(r: Rig): proc(): bool =
  result = proc(): bool =
    r.active("acme-tools.metrics") and r.active("acme-tools.flame")

# ---------------------------------------------------------------------------
# The main process, started a second time, for the cases about its end
# ---------------------------------------------------------------------------

proc guardChild(stuck: bool): Future[void] {.async.} =
  ## `--guard-child [--stuck]`: start both plugins (with `--stuck`, leave
  ## `flame` looping in a handler), print the plugin's pid, and run until
  ## killed.
  var r = newRig(if stuck: "hang-invoke" else: "normal")
  r.both()
  if not await r.sup.waitUntil("both active", r.bothActive):
    exitNow(3)
  if stuck:
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    await r.sup.settle(300)
  echo "PLUGIN-PID ", r.sup.pidOf("acme-tools.metrics")
  while true:
    r.sup.poll()
    await sleep(20)

proc startGuardChild(noSetpriv, stuck: bool): JsObject {.importjs: """
  (function (node, script, noSetpriv, stuck) {
    var env = Object.assign({}, process.env);
    if (noSetpriv) { env.CODETRACER_PLUGIN_NO_SETPRIV = '1'; }
    else { delete env.CODETRACER_PLUGIN_NO_SETPRIV; }
    var child = require('child_process').spawn(node,
      stuck ? [script, '--guard-child', '--stuck'] : [script, '--guard-child'],
      { stdio: ['ignore', 'pipe', 'inherit'], env: env });
    child.__out = '';
    child.stdout.on('data', function (d) { child.__out += d.toString(); });
    return child;
  })(process.execPath, process.argv[1], #, #)""".}

proc childOutput(c: JsObject): cstring {.importjs: "#.__out".}
proc childPid(c: JsObject): int {.importjs: "#.pid".}

proc pluginPidOf(child: JsObject): Future[int] {.async.} =
  let start = monotonicMs()
  while monotonicMs() - start < Ceiling:
    let output = $childOutput(child)
    let at = output.find("PLUGIN-PID ")
    if at >= 0:
      let e = output.find('\n', at)
      if e > 0:
        return parseInt(output[at + "PLUGIN-PID ".len ..< e].strip)
    await sleep(20)
  return 0

proc gone(pid: int; ceilingMs = 30_000): Future[bool] {.async.} =
  let start = monotonicMs()
  while pidAlive(pid):
    if monotonicMs() - start > ceilingMs:
      return false
    await sleep(20)
  return true

proc mainEnds(sig: int; noSetpriv, stuck: bool; what: string;
              expectGone = true): Future[void] {.async.} =
  let child = startGuardChild(noSetpriv, stuck)
  let pid = await pluginPidOf(child)
  ck pid > 0, what & ": the main process started its plugin process"
  if pid <= 0:
    killPid(childPid(child), int(SIGKILL))
    return
  ck pidAlive(pid), what & ": the plugin process runs"
  killPid(childPid(child), sig)
  ck await gone(childPid(child)), what & ": the main process ended"
  if expectGone:
    let ended = await gone(pid)
    ck ended, what & ": and its plugin process ended with it"
    if not ended: killPid(pid, int(SIGKILL))
  else:
    ck not await gone(pid, 3_000), what & ": its plugin process outlives it " &
      "(the documented gap)"
    killPid(pid, int(SIGKILL))

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------

proc main() {.async.} =
  let args = argv().mapIt($it)
  if "--guard-child" in args:
    await guardChild("--stuck" in args)
    return
  for a in args:
    if a.startsWith("--only="):
      onlySections = a["--only=".len .. ^1].split(',')
  setEnv("CT_PLUGIN_TEST_SCRATCH", cstring(getTempDir() / "ct-plugin-process-tests-node"))
  discard buildPackageExecutable()

  if section("handshake", "§11.2: the handshake, and two plugins in ONE process"):
    var r = newRig()
    r.both()
    ck await r.sup.waitUntil("both active", r.bothActive), "both plugins activate"
    let pid = r.sup.pidOf("acme-tools.metrics")
    ck pid > 0, "the package's process has a pid"
    ck r.sup.pidOf("acme-tools.flame") == pid, "flame runs in the SAME process as metrics"
    ck r.sup.processIds == @[pid], "one process for the package"
    ck pid in liveProcessGroups(), "the link registered the process's group"
    ck r.sup.events.anyIt(it.startsWith("start acme-tools pid " & $pid)),
      "the start is logged with the pid"
    ck await r.sup.waitUntil("panes drawn", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:10") and
      r.sup.renderSurface("acme-tools.flame/flame").allText.contains("main 60%")),
      "both panes are drawn from what the plugins pushed over the pipe"
    ck r.sup.contributedPanes.mapIt(it.id) ==
      @["acme-tools.metrics/overview", "acme-tools.flame/flame"],
      "both contributed panes are listed"
    r.moveTo(42)
    ck await r.sup.waitUntil("pane follows", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:42")),
      "the mirrored stop reaches the plugin and its pane follows"
    await r.sup.shutdownAndWait()
    ck not pidAlive(pid), "shutdown reaps the process (Node's event loop not blocked)"
    ck pid notin liveProcessGroups(), "and forgets its group"
    ck r.sup.events.anyIt(it == "stopped acme-tools"), "it stopped gracefully"

  if section("no-extensions", "--no-extensions starts no plugin process"):
    var r = newRig(extensions = false)
    r.both()
    await r.sup.settle(300)
    ck r.sup.processIds.len == 0, "no process"
    ck not r.active("acme-tools.metrics"), "nothing is active"
    ck r.sup.report().contains("--no-extensions"), "the report says why"
    ck r.sup.renderSurface("acme-tools.metrics/overview").allText.contains(
      "Extensions are off"), "the pane says why"
    await r.sup.shutdownAndWait()

  if section("crash", "§11.6, §11.8: a SIGKILLed process is a crash, and is restarted"):
    var r = newRig()
    r.both()
    ck await r.sup.waitUntil("both active", r.bothActive), "both active"
    let pid = r.sup.pidOf("acme-tools.metrics")
    killPid(pid, int(SIGKILL))
    ck await r.sup.waitUntil("restarted", proc(): bool =
      r.active("acme-tools.metrics") and r.active("acme-tools.flame") and
      r.sup.pidOf("acme-tools.metrics") notin [0, pid]),
      "a new process re-activates both plugins"
    ck r.sup.pidOf("acme-tools.flame") == r.sup.pidOf("acme-tools.metrics"),
      "still one process"
    r.moveTo(77)
    ck await r.sup.waitUntil("snapshot", proc(): bool =
      r.sup.renderSurface("acme-tools.metrics/overview").allText.contains("main.nim:77")),
      "the restarted plugin follows the session"
    ck r.sup.faults.len == 1 and r.sup.faults[0].kind == fkCrash, "one crash"
    ck r.sup.faults.len == 1 and r.sup.faults[0].detail.contains("SIGKILL"),
      "Node's signal name is read back as SIGKILL: " &
        (if r.sup.faults.len > 0: r.sup.faults[0].detail else: "")
    await r.sup.shutdownAndWait()

  if section("segfault", "§11.6.1: a segfault is blamed by name; the sibling survives"):
    var r = newRig("segfault")
    r.both()
    ck await r.sup.waitUntil("flame breaker open", proc(): bool =
      r.sup.slot("acme-tools.flame").breaker == bsOpen), "flame's breaker opens"
    ck await r.sup.waitUntil("metrics alone", proc(): bool =
      r.active("acme-tools.metrics")), "metrics runs on"
    let flameFaults = r.sup.faults.filterIt(it.plugin == "acme-tools.flame")
    ck flameFaults.len in 1 .. 3, "flame restarted at most 3 times"
    ck r.sup.faults.allIt(it.plugin == "acme-tools.flame"),
      "every fault is flame's: the crash record on stderr was read before the exit"
    ck flameFaults.len > 0 and flameFaults[0].detail.contains("SIGSEGV"),
      "the exit is SIGSEGV"
    ck r.sup.notifications.len > 0 and
      r.sup.notifications[0].text.contains("Plugin 'acme-tools.flame' was stopped"),
      "the user is told which plugin"
    ck r.sup.slot("acme-tools.metrics").totalStrikes == 0, "metrics has no strike"
    await r.sup.shutdownAndWait()

  if section("hang", "§11.6.2: a handler that loops forever is attributed by the watchdog"):
    var r = newRig("hang-invoke")
    r.sup.busyHangMs = 1_500
    r.sup.pingBusyMs = 100
    r.both()
    ck await r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame")),
      "flame active"
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    ck await r.sup.waitUntil("hang fault", proc(): bool =
      r.sup.faults.anyIt(it.kind == fkHang)), "a hang fault"
    let hangs = r.sup.faults.filterIt(it.kind == fkHang)
    ck hangs.len > 0 and hangs[0].plugin == "acme-tools.flame",
      "the hang is flame's (the watchdog's `busy`)"
    ck r.sup.slot("acme-tools.metrics").totalStrikes == 0, "not metrics'"
    ck await r.sup.waitUntil("metrics back", proc(): bool =
      r.active("acme-tools.metrics")), "metrics is back"
    await r.sup.shutdownAndWait()

  if section("stop", "§11.8: the stop sequence signals the group: SIGTERM for a stuck process"):
    var r = newRig("hang-invoke")
    r.sup.shutdownGraceMs = 300
    r.both()
    ck await r.sup.waitUntil("active", proc(): bool = r.active("acme-tools.flame")),
      "flame active"
    let pid = r.sup.pidOf("acme-tools.flame")
    discard r.sup.invoke("acme-tools.flame", "flame.refresh")
    await r.sup.settle(200)
    r.sup.setEnabled("acme-tools.metrics", false, persist = false)
    r.sup.setEnabled("acme-tools.flame", false, persist = false)
    ck await r.sup.waitUntil("stopped", proc(): bool = not pidAlive(pid)),
      "a process stuck in a handler is stopped"
    ck await r.sup.waitUntil("the stop observed", proc(): bool =
      r.sup.events.anyIt(it == "stopped acme-tools")), "as a stop, not a fault"
    ck r.sup.faults.len == 0, "no fault is recorded for a stop"
    let inst = r.sup.packages["acme-tools"].instances[0]
    ck inst.link.exit == esSignalled and inst.link.exitCode == int(SIGTERM),
      "by SIGTERM to its group, after the grace: " & inst.link.describeExit
    await r.sup.shutdownAndWait()

  if section("start-failure", "a package whose executable cannot be started"):
    # Both routes: Node's own spawn error, and `setpriv`'s failed exec.
    for viaSetpriv in [false, true]:
      if viaSetpriv and not usesPdeathHelper(): continue
      let route = if viaSetpriv: " (through setpriv)" else: " (Node's spawn error)"
      if not viaSetpriv: setEnv("CODETRACER_PLUGIN_NO_SETPRIV", "1")
      var r = newRig(removeExecutable = true)
      r.both()
      ck await r.sup.waitUntil("start failure", proc(): bool =
        r.sup.faults.anyIt(it.kind == fkStartFailure)),
        "a start failure, as `execve` failing reads on the C backend" & route
      let f = r.sup.faults.filterIt(it.kind == fkStartFailure)
      ck f.len > 0 and f[0].detail.contains("status 127"), "exit status 127" &
        route & ": " & (if f.len > 0: f[0].detail else: "")
      await r.sup.shutdownAndWait()
      if not viaSetpriv: deleteEnv("CODETRACER_PLUGIN_NO_SETPRIV")

  if section("write-queue", "a child that stops reading: the write queue holds the bytes"):
    let link = spawnPluginProcess("sleep", @["600"])
    ck link.pid > 0, "the child started"
    let big = %*{"type": "settings-changed", "blob": repeat('x', 3 * 1024 * 1024)}
    var accepted = 0
    var refused = false
    for i in 0 ..< 12:
      if link.send(big):
        inc accepted
      else:
        refused = true
        break
      link.flushWrites()
      await sleep(5)
    ck refused, "send refuses once the child is " & $MaxQueuedBytes &
      " bytes behind (accepted " & $accepted & ")"
    ck link.queuedBytes > MaxQueuedBytes,
      "queuedBytes counts what the child has not taken: " & $link.queuedBytes
    link.signalGroup(SIGKILL)
    let start = monotonicMs()
    while not link.pollExit() and monotonicMs() - start < Ceiling:
      await sleep(5)
    ck link.exit == esSignalled and link.exitCode == int(SIGKILL),
      "SIGKILL to the group ends it: " & link.describeExit
    link.closeAll()

  if section("main-ends", "the main process ends: its plugin processes end with it"):
    # A plugin STUCK in a handler: one that would still read its stdin exits
    # on end-of-file whatever the main process did, which proves nothing
    # about the guards.
    await mainEnds(int(SIGTERM), true, true,
      "SIGTERM, a stuck plugin, without setpriv (the exit guard)")
    await mainEnds(int(SIGINT), true, true,
      "SIGINT, a stuck plugin, without setpriv (the exit guard)")
    if usesPdeathHelper():
      await mainEnds(int(SIGKILL), false, true,
        "SIGKILL, a stuck plugin, through setpriv --pdeathsig")
    else:
      echo "  (setpriv is not on PATH: the SIGKILL-through-setpriv case is not run)"
    await mainEnds(int(SIGKILL), true, false,
      "SIGKILL, without setpriv (the plugin reads end-of-file on its stdin)")
    # What the module header says remains: SIGKILL, no setpriv, a plugin
    # stuck in a handler. Pinned, so the header cannot drift from the fact.
    await mainEnds(int(SIGKILL), true, true,
      "SIGKILL, a stuck plugin, without setpriv", expectGone = false)

  echo "CHECKS: ", checks
  if failures > 0:
    echo "[FAILED] plugin processes on Node (", failures, " of ", checks, ")"
    {.emit: "process.exitCode = 1;".}
  else:
    echo "[OK] plugin processes on Node"

discard main()
