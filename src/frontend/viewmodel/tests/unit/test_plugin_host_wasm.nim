## test_plugin_host_wasm.nim — CodeTracer's WebAssembly plugin host
## (Extensibility-Model.md §11.9) driven by the real `Supervisor`: a real
## `ct-plugin-host` process, real pipes, real WebAssembly modules built from
## Nim with the plugin SDK (`wasm_plugins/wasm_test_plugins.nim`), the real
## engine and the real `plugin_io.nim` primitives behind its imports.
##
## ## NO MOCKS
##
## Nothing here stands in for anything. The plugins misbehave for real — a
## handler that never returns, one that allocates until its limit, one that
## keeps its call running while the host is killed with SIGKILL — and every
## assertion is about what the supervisor and the host did about it. The one
## thing the suite controls is the host's thresholds (`wasmHostArgs`,
## `pingBusyMs`): they are not the subject of these cases, and the host is
## loaded (load above 100), so every wait is on STATE with a generous ceiling.
##
## ## THE CASES
##
## 1. Three plugins from two packages in ONE host process (one pid, asserted):
##    `wasm-faults.spin` loops for ever, `wasm-faults.hog` grows memory past
##    its limit, `wasm-steady.echo` is healthy. The first two are faulted and
##    reported by name; echo answers before, between and after them from the
##    same instance (its count never resets), and the host never restarts.
## 2. A plugin without `fs:read` calling the read import is refused by
##    `decide`; the same plugin with the grant reads the declared path.
## 3. Killing `ct-plugin-host` mid-call charges the crash to the plugin that
##    was executing; after two, that plugin runs in a host of its own and its
##    neighbour is not restarted again.
## 4. A module importing anything the host does not offer is refused at
##    activation, naming the import.

import std/[json, os, posix, sequtils, strutils, tables, unittest]

import ../../../../common/plugin_model
import plugin_host/supervisor
import wasm_host_fixture

const Ceiling = 180_000

proc waitUntil(sup: Supervisor; what: string; cond: proc(): bool;
               ceilingMs = Ceiling): bool {.discardable.} =
  let start = monotonicMs()
  while not cond():
    sup.poll()
    if monotonicMs() - start > ceilingMs:
      checkpoint "timed out waiting for: " & what & "\n" & sup.report() &
        "\nevents:\n" & sup.events[max(0, sup.events.len - 40) .. ^1].join("\n")
      return false
    os.sleep(2)
  true

var rigCount = 0

proc newRoot(): string =
  inc rigCount
  result = wasmScratchRoot() / ("rig-" & $getpid() & "-" & $rigCount)
  removeDir(result)
  createDir(result)

proc newWasmSupervisor(root: string; deadlineMs = 500; memoryMb = 32): Supervisor =
  result = newSupervisor("tui", "1.0.0", true)
  result.wasmHost = pluginHostBin()
  result.wasmHostArgs = @["--call-deadline-ms", $deadlineMs,
                          "--memory-mb", $memoryMb]
  result.logDir = root / "logs"
  # Widened: liveness is not the subject (see the header).
  result.pongDeadlineMs = 30_000
  result.busyHangMs = 60_000
  result.helloDeadlineMs = 60_000
  result.inputDeadlineMs = 30_000
  result.pingBusyMs = 200

proc add(sup: Supervisor; dir: string) =
  let pkg = parsePluginPackage(readFile(dir / "plugin.json"), "plugin.json",
                               dir.extractFilename.split('@')[0])
  doAssert pkg.allErrors.len == 0, renderAll(pkg.allErrors)
  sup.addPackage(dir, pkg)
  for id in pkg.pluginIds:
    sup.configure(id, true, newJObject())

proc answerOf(sup: Supervisor; id: string; got: var JsonNode): bool =
  for a in sup.takeAnswers(id):
    if a.kind in ["answer", "error"]:
      got = a.payload
      return true
  false

proc ask(sup: Supervisor; plugin, kind: string; input: JsonNode): JsonNode =
  let id = sup.query(plugin, kind, input, deadlineMs = 60_000)
  doAssert id.len > 0, plugin & " is not active"
  var got: JsonNode
  doAssert sup.waitUntil("an answer from " & plugin, proc(): bool =
    sup.answerOf(id, got))
  got

proc faultOf(sup: Supervisor; plugin: string): seq[Fault] =
  sup.faults.filterIt(it.plugin == plugin)

proc hostInstances(sup: Supervisor): seq[Instance] =
  if sup.wasmGroup.isNil: @[] else: sup.wasmGroup.instances

suite "ct-plugin-host: many packages in one process, each plugin in its own instance":

  test "an endless loop and a memory hog are faulted by name; their neighbour never stops answering":
    let root = newRoot()
    let faults = installWasmPackage(root, "wasm-faults", wasmPackage("wasm-faults", @[
      wasmPlugin("wasm-faults.spin", ["spin.run"], ["spin.status"]),
      wasmPlugin("wasm-faults.hog", ["hog.run"], ["hog.status"])]),
      testModule("wasm-faults"))
    let steady = installWasmPackage(root, "wasm-steady", wasmPackage("wasm-steady", @[
      wasmPlugin("wasm-steady.echo", [], ["echo.status"]),
      wasmPlugin("wasm-steady.busy", ["busy.run"], ["busy.status"])]),
      testModule("wasm-steady"))
    let sup = newWasmSupervisor(root)
    sup.add(faults)
    sup.add(steady)
    for id in ["wasm-faults.spin", "wasm-faults.hog", "wasm-steady.echo"]:
      sup.activate(id)
    check sup.waitUntil("three plugins active", proc(): bool =
      sup.slot("wasm-faults.spin").active and sup.slot("wasm-faults.hog").active and
      sup.slot("wasm-steady.echo").active)

    # One process for both packages.
    let pid = sup.pidOf("wasm-steady.echo")
    check pid > 0
    check sup.pidOf("wasm-faults.spin") == pid
    check sup.pidOf("wasm-faults.hog") == pid
    check sup.processIds() == @[pid]
    check sup.hostInstances.len == 1

    var asked = 0
    proc echoOnce() =
      inc asked
      let a = sup.ask("wasm-steady.echo", "echo", %*{"n": asked})
      check a{"value"}{"echo"}{"n"}.getInt == asked
      # The SAME instance answered: its count did not start again.
      check a{"value"}{"answered"}.getInt == asked

    echoOnce()
    # spin: its call never returns.
    let spinReq = sup.invoke("wasm-faults.spin", "spin.run")
    check spinReq.len > 0
    # Asked while spin holds the host's thread; answered once spin is cut off.
    let during = sup.query("wasm-steady.echo", "echo", %*{"n": asked + 1},
                           deadlineMs = 60_000)
    inc asked
    check sup.waitUntil("spin faulted", proc(): bool =
      sup.faultOf("wasm-faults.spin").len > 0)
    # What it pushed went with its instance, in the turn that saw the fault
    # (it is pushed again when the plugin is activated anew, below).
    check sup.slot("wasm-faults.spin").status.len == 0
    check not sup.slot("wasm-faults.spin").active
    var duringAnswer: JsonNode
    check sup.waitUntil("echo's answer from during spin", proc(): bool =
      sup.answerOf(during, duringAnswer))
    check duringAnswer{"value"}{"answered"}.getInt == asked
    echoOnce()

    # hog: allocates until its limit.
    check sup.invoke("wasm-faults.hog", "hog.run").len > 0
    check sup.waitUntil("hog faulted", proc(): bool =
      sup.faultOf("wasm-faults.hog").len > 0)
    check sup.slot("wasm-faults.hog").status.len == 0
    check not sup.slot("wasm-faults.hog").active
    echoOnce()

    let spinFault = sup.faultOf("wasm-faults.spin")[0]
    check spinFault.kind == fkHang
    check "deadline" in spinFault.detail
    let hogFault = sup.faultOf("wasm-faults.hog")[0]
    check hogFault.kind == fkCrash
    check "memory limit" in hogFault.detail
    # Reported by name, with what the host did.
    let texts = sup.notifications.mapIt(it.text).join("\n")
    check "Plugin 'wasm-faults.spin' was stopped" in texts
    check "Plugin 'wasm-faults.hog' was stopped" in texts
    check "the other plugins kept running" in texts
    # Echo's pushed state was never touched.
    check sup.slot("wasm-steady.echo").status.len == 1
    # No fault was charged to echo, and the host never restarted.
    check sup.faultOf("wasm-steady.echo").len == 0
    check sup.faultOf("").len == 0
    check sup.hostInstances.len == 1
    check sup.hostInstances[0].starts == 1
    check sup.pidOf("wasm-steady.echo") == pid
    check processAlive(pid)
    # The faulted plugins come back in fresh instances of the same process.
    check sup.waitUntil("spin and hog active again", proc(): bool =
      sup.slot("wasm-faults.spin").active and sup.slot("wasm-faults.hog").active)
    check sup.pidOf("wasm-faults.spin") == pid
    echoOnce()
    check sup.hostInstances[0].starts == 1
    sup.shutdown()

  test "the read import is refused by decide without fs:read, and reads the declared path with it":
    let root = newRoot()
    let dataDir = root / "data"
    createDir(dataDir)
    writeFile(dataDir / "note.txt", "read through the host\n")
    let module = testModule("wasm-reader")
    proc readWith(capabilities: seq[string]): JsonNode =
      let r = newRoot()
      let reads = if "fs:read" in capabilities: @[dataDir] else: @[]
      let dir = installWasmPackage(r, "wasm-reader", wasmPackage("wasm-reader", @[
        wasmPlugin("wasm-reader.files", ["files.read"], [], capabilities, reads)]),
        module)
      let sup = newWasmSupervisor(r)
      sup.add(dir)
      sup.activate("wasm-reader.files")
      doAssert sup.waitUntil("reader active", proc(): bool =
        sup.slot("wasm-reader.files").active)
      let id = sup.invoke("wasm-reader.files", "files.read",
                          %*{"path": dataDir / "note.txt"})
      var got: JsonNode
      doAssert sup.waitUntil("the read's answer", proc(): bool =
        sup.answerOf(id, got))
      sup.shutdown()
      got
    let refused = readWith(@[])
    check refused{"value"}{"status"}.getStr == "ioRefused"
    check "needs 'fs:read'" in refused{"value"}{"message"}.getStr
    check "wasm-reader.files" in refused{"value"}{"message"}.getStr
    check refused{"value"}{"data"}.getStr == ""
    let granted = readWith(@["fs:read"])
    check granted{"value"}{"status"}.getStr == "ioOk"
    check granted{"value"}{"data"}.getStr == "read through the host\n"

  test "a host killed mid-call is charged to the executing plugin; twice, and it runs in a host of its own":
    let root = newRoot()
    let steady = installWasmPackage(root, "wasm-steady", wasmPackage("wasm-steady", @[
      wasmPlugin("wasm-steady.echo", [], ["echo.status"]),
      wasmPlugin("wasm-steady.busy", ["busy.run"], ["busy.status"])]),
      testModule("wasm-steady"))
    let sup = newWasmSupervisor(root, deadlineMs = 60_000)
    sup.restartBaseMs = 50
    sup.restartCapMs = 200
    sup.add(steady)
    sup.activate("wasm-steady.echo")
    sup.activate("wasm-steady.busy")
    proc bothActive(): bool =
      sup.slot("wasm-steady.echo").active and sup.slot("wasm-steady.busy").active
    check sup.waitUntil("both active", bothActive)

    proc killMidCall(): int =
      ## Start busy's long call, wait until the watchdog names it, SIGKILL
      ## the host that runs it. Returns the pid killed.
      let pid = sup.pidOf("wasm-steady.busy")
      doAssert sup.invoke("wasm-steady.busy", "busy.run", %*{"ms": 50_000}).len > 0
      let inst = sup.slot("wasm-steady.busy").hostInstance
      doAssert sup.waitUntil("the watchdog names busy", proc(): bool =
        inst.busy == "wasm-steady.busy")
      doAssert posix.kill(Pid(pid), SIGKILL) == 0
      pid

    for round in 1 .. 2:
      let before = sup.faultOf("wasm-steady.busy").len
      let killed = killMidCall()
      check sup.waitUntil("the crash charged to busy", proc(): bool =
        sup.faultOf("wasm-steady.busy").len > before)
      let f = sup.faultOf("wasm-steady.busy")[^1]
      check f.kind == fkCrash
      check sup.faultOf("wasm-steady.echo").len == 0
      check sup.faultOf("").len == 0
      check sup.waitUntil("both active again", bothActive)
      check sup.pidOf("wasm-steady.echo") != killed
      check sup.slot("wasm-steady.busy").hostCrashes == round

    # Two crashes: busy now has a host of its own.
    let echoPid = sup.pidOf("wasm-steady.echo")
    let busyPid = sup.pidOf("wasm-steady.busy")
    check busyPid != echoPid
    check sup.slot("wasm-steady.busy").hostInstance.dedicated == "wasm-steady.busy"
    check "runs in a ct-plugin-host of its own" in
      sup.notifications.mapIt(it.text).join("\n")
    let echoInst = sup.slot("wasm-steady.echo").hostInstance
    let echoStarts = echoInst.starts
    discard sup.ask("wasm-steady.echo", "echo", %*{"n": 1})

    # A third crash costs its neighbour nothing.
    let before = sup.faultOf("wasm-steady.busy").len
    discard killMidCall()
    check sup.waitUntil("the third crash recorded", proc(): bool =
      sup.faultOf("wasm-steady.busy").len > before)
    for _ in 0 ..< 200:
      sup.poll()
      os.sleep(5)
    check sup.pidOf("wasm-steady.echo") == echoPid
    check echoInst.starts == echoStarts
    check sup.slot("wasm-steady.echo").hostInstance == echoInst
    check sup.slot("wasm-steady.echo").active
    discard sup.ask("wasm-steady.echo", "echo", %*{"n": 2})
    sup.shutdown()

  test "a module importing what the host does not offer is refused at activation, naming the import":
    let root = newRoot()
    # The smallest module that imports something outside the allow-list:
    # `(module (import "env" "system" (func (param i32))))`.
    let bytes = "\x00asm\x01\x00\x00\x00" &
      "\x01\x05\x01\x60\x01\x7f\x00" &
      "\x02\x0e\x01\x03env\x06system\x00\x00"
    let module = root / "imports-system.wasm"
    writeFile(module, bytes)
    let dir = installWasmPackage(root, "wasm-escape", wasmPackage("wasm-escape", @[
      wasmPlugin("wasm-escape.shell", [], [])]), module)
    let sup = newWasmSupervisor(root)
    sup.add(dir)
    sup.activate("wasm-escape.shell")
    check sup.waitUntil("the activation refused", proc(): bool =
      sup.faultOf("wasm-escape.shell").len > 0)
    let f = sup.faultOf("wasm-escape.shell")[0]
    check f.kind == fkStartFailure
    check "env" in f.detail and "system" in f.detail
    check not sup.slot("wasm-escape.shell").active
    sup.shutdown()
