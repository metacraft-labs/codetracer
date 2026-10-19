## test_session_mirroring.nim
##
## A primary session and its mirrors, end to end over the in-memory
## transport: the registry of mirrored signals, the publisher's revisioned
## batches, the subscriber's refusals, the action relay, the viewport, and a
## mirror switching between two primaries.
##
## WHAT IS REAL: `session_vm.createSessionVM` and `initializePanelViewModels`
## on both sides (so the primary's and the mirror's panel ViewModels are the
## shipped ones), `sync_host`, `mirror_session`, `sync_publisher`,
## `sync_subscriber`, `action_relay` and `transport`'s `SyncChannel`.
##
## THE STAND-INS, and why each is needed:
## - `MockBackendService` behind each PRIMARY: these suites are about what
##   crosses between a primary and a mirror, and a move is scripted by writing
##   the store the way the backend's answers write it. Where an action must
##   reach the backend (a step), the mock's recorded commands are the
##   evidence that it ran on the primary.
## - `InMemoryLink` as the transport: it queues and copies every message as a
##   real transport serialises it, so nothing here passes because a reply was
##   delivered inside its sender's call.
## - A manual `Scheduler`: when a batch is cut is what these suites assert on;
##   the production scheduler is a microtask, which a synchronous test cannot
##   interleave with.
##
## Runs on the C and JS backends (`vm-unit`, `vm-unit-js`).

import std/[json, options, sets, unittest]

import isonim/core/[async_compat, owner, signals]

import ../../backend/mock_backend
import ../../session_vm
import ../../store/replay_data_store
import ../../store/types
import ../../sync/[action_relay, mirror_session, sync_host, sync_publisher,
                   sync_subscriber, synced_signals, transport]
import ../../viewmodels/[calltrace_vm, debug_controls_vm, event_log_vm,
                         state_vm]

var checks = 0
template ck(cond: untyped) =
  inc checks
  check cond

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

var queued: seq[proc()]
let manual: Scheduler = proc(callback: proc()) = queued.add callback

proc settle(link: InMemoryLink) =
  ## Run the event loop until it is quiet: cut every scheduled batch, let the
  ## platform settle, deliver everything in flight — repeatedly, because a
  ## delivery (an action) causes the next batch.
  for _ in 0 ..< 100:
    if queued.len == 0 and link.pending == 0:
      return
    let run = queued
    queued = @[]
    for callback in run:
      callback()
    drainPlatformCallbacks()
    link.flush()
  doAssert false, "the mirror and its host did not settle"

proc newPrimary(): tuple[session: SessionViewModel; mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService())
  session.initializePanelViewModels()
  (session, mock)

proc moveTo(session: SessionViewModel; ticks: uint64; file: string;
            line: int) =
  ## A stop, written to the store as the backend's `ct/complete-move` writes
  ## it.
  var dbg = session.store.debugger.val
  dbg.rrTicks = ticks
  dbg.location = Location(file: file, line: line)
  dbg.status = dsIdle
  session.store.debugger.val = dbg

proc callLine(i: int; name: string): CallLine =
  CallLine(index: i.int64, name: name, depth: i mod 3,
           rrTicks: uint64(i * 10))

proc agree(primary, mirror: SessionViewModel): seq[string] =
  ## The keys whose values differ between the two sessions; empty when they
  ## agree on every mirrored signal.
  let p = syncedSignalsOf(primary)
  let m = syncedSignalsOf(mirror)
  for s in p.signals:
    let other = m.find(s.key)
    if other.isNone or other.get.read() != s.read():
      result.add s.key

# ---------------------------------------------------------------------------

suite "the mirrored signals":

  test "every panel ViewModel's signals are mirrored, and only a closure is not":
    createRoot proc(done: proc()) =
      let (session, _) = newPrimary()
      let reg = syncedSignalsOf(session)
      for owner in ["store.", "state.", "calltrace.", "eventLog.", "flow.",
                    "editor.", "timeline.", "debugControls.", "searchResults.",
                    "pointList.", "scratchpad.", "fileTree.",
                    "terminalOutput."]:
        var n = 0
        for k in reg.keys:
          if k.len > owner.len and k[0 ..< owner.len] == owner:
            inc n
        checkpoint owner
        ck n > 0
      # A new signal that cannot be mirrored must be noticed here, not
      # discovered as a webview that disagrees with its primary.
      ck reg.skippedKeys == @["state.lastContextMenu"]
      done()

suite "the publisher":

  test "one reactive change is one batch, at the next revision":
    createRoot proc(done: proc()) =
      let (session, _) = newPrimary()
      var sent: seq[JsonNode]
      let pub = createSyncPublisher(session, "s1",
        proc(msg: JsonNode) = sent.add(msg), manual)
      ck queued.len == 0           # construction publishes nothing
      session.moveTo(10, "main.nim", 3)
      session.stateVM.selectTab(stGlobals)
      for callback in queued: callback()
      queued = @[]
      ck sent.len == 1
      ck sent[0]["type"].getStr == "signal-batch"
      ck sent[0]["session"].getStr == "s1"
      ck sent[0]["revision"].getInt == 1
      var keys: seq[string]
      for e in sent[0]["batch"]: keys.add e["key"].getStr
      ck "store.debugger" in keys
      ck "state.activeTab" in keys
      # Nothing changed: nothing sent.
      pub.flush()
      ck sent.len == 1
      session.moveTo(20, "main.nim", 4)
      pub.flush()
      ck sent.len == 2 and sent[1]["revision"].getInt == 2
      queued = @[]
      pub.dispose()
      done()

  test "a snapshot publishes what is pending first and carries its revision":
    createRoot proc(done: proc()) =
      let (session, _) = newPrimary()
      var sent: seq[JsonNode]
      let pub = createSyncPublisher(session, "s1",
        proc(msg: JsonNode) = sent.add(msg), manual)
      session.moveTo(10, "main.nim", 3)
      let snap = pub.snapshot()
      ck sent.len == 1 and sent[0]["revision"].getInt == 1
      ck snap["type"].getStr == "signal-snapshot"
      ck snap["revision"].getInt == 1
      ck snap["batch"].len == syncedSignalsOf(session).signals.len
      queued = @[]
      pub.dispose()
      done()

suite "the subscriber":

  test "it refuses another session, a stale batch and a lost revision":
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let (mirrorSession, _) = newPrimary()
      var sent: seq[JsonNode]
      let pub = createSyncPublisher(primary, "s1",
        proc(msg: JsonNode) = sent.add(msg), manual)
      let sub = createSyncSubscriber(mirrorSession)
      sub.follow("s1")
      # Before the snapshot, a batch is refused.
      primary.moveTo(10, "a.nim", 1)
      pub.flush()
      ck not sub.onMessage(sent[^1])
      ck sub.onMessage(pub.snapshot())
      ck sub.inStep and sub.revision == 1
      ck mirrorSession.store.debugger.val.rrTicks == 10
      # The next revision applies; the same one again is refused.
      primary.moveTo(20, "a.nim", 2)
      pub.flush()
      let r2 = sent[^1]
      ck sub.onMessage(r2)
      ck not sub.onMessage(r2)
      # Another session's batch is refused even at the right revision.
      var foreign = r2.copy
      foreign["session"] = %"s2"
      foreign["revision"] = %3
      ck not sub.onMessage(foreign)
      # A lost revision puts the subscriber out of step.
      primary.moveTo(30, "a.nim", 3)
      pub.flush()
      primary.moveTo(40, "a.nim", 4)
      pub.flush()
      ck not sub.onMessage(sent[^1])   # revision 4 after 2
      ck not sub.inStep
      ck mirrorSession.store.debugger.val.rrTicks == 20
      queued = @[]
      pub.dispose()
      done()

suite "a primary and its mirror":

  test "they agree after a scripted sequence of moves":
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      ck mirror.following == "s1"
      ck mirror.subscriber.inStep
      ck agree(primary, mirror.session).len == 0

      primary.moveTo(100, "src/main.nim", 12)
      primary.store.calltrace.lines.val = @[callLine(0, "main"),
                                             callLine(1, "helper")]
      primary.store.calltrace.totalCallsCount.val = 2
      link.settle()
      primary.store.locals.locals.val = @[Variable(name: "x", value: "1",
                                                   typeName: "int")]
      primary.calltraceVM.selectEntry(some(1'i64))
      link.settle()
      primary.moveTo(200, "src/helper.nim", 4)
      primary.store.locals.locals.val = @[Variable(name: "y", value: "2",
                                                   typeName: "int")]
      primary.stateVM.selectTab(stWatches)
      link.settle()

      let differing = agree(primary, mirror.session)
      checkpoint $differing
      ck differing.len == 0
      ck mirror.session.store.debugger.val.rrTicks == 200
      ck mirror.session.store.locals.locals.val[0].name == "y"
      ck mirror.session.calltraceVM.selectedEntry.val == some(1'i64)
      ck mirror.session.stateVM.activeTab.val == stWatches
      mirror.dispose()
      host.dispose()
      done()

  test "an action taken on the mirror runs on the primary":
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()

      mirror.relay("state", "addWatch", %*{"expression": actionArg("a + b")})
      link.settle()
      ck primary.stateVM.watchExpressions.val == @["a + b"]
      ck mirror.session.stateVM.watchExpressions.val == @["a + b"]

      mirror.relay("state", "selectTab", %*{"tab": actionArg(stGlobals)})
      mirror.relay("calltrace", "selectEntry",
                   %*{"lineIndex": actionArg(some(3'i64))})
      link.settle()
      ck primary.stateVM.activeTab.val == stGlobals
      ck primary.calltraceVM.selectedEntry.val == some(3'i64)

      # A step reaches the PRIMARY's backend; the mirror's sends nothing
      # anyone answers.
      mock.clearReceivedCommands()
      mirror.relay("debugControls", "stepForward")
      link.settle()
      ck mock.findCommand("next").isSome
      ck host.actionsApplied == 4

      # An action the primary does not know is ignored.
      mirror.relay("nonexistent", "doSomething")
      link.settle()
      ck host.actionsApplied == 4
      ck agree(primary, mirror.session).len == 0
      mirror.dispose()
      host.dispose()
      done()

  test "a mirror's toolbar runs the commands of the host that drives the replay":
    # The page under `ct host`: the server owns the session, the page steps
    # the replay itself. Its toolbar must step through the page's own route,
    # not the defaults over the mirror's inert backend.
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      var hostSteps: seq[string]
      let mirror = createMirrorSession(link.b,
        debugCommandsFor = proc(session: SessionViewModel): DebugCommands =
          result = defaultDebugCommands(session.store)
          result.step = proc(actionId: string) = hostSteps.add actionId)
      link.settle()

      mock.clearReceivedCommands()
      mirror.session.debugControlsVM.invokeToolbarStep("next")
      link.settle()
      ck hostSteps == @["next"]
      # It was the page's step, not one relayed to the session's owner.
      ck mock.findCommand("next").isNone
      ck host.actionsApplied == 0
      mirror.dispose()
      host.dispose()
      done()

  test "a viewport set on the mirror reaches the primary":
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()

      mirror.setViewport("calltrace", rows = 37, depth = 5, firstRow = 10)
      mirror.setViewport("eventLog", rows = 24)
      link.settle()
      ck primary.calltraceVM.viewportHeight.val == 37
      ck primary.calltraceVM.viewportDepth.val == 5
      ck primary.calltraceVM.scrollPosition.val == 10
      ck primary.eventLogVM.pageSize.val == 24
      # And the primary's answer — its viewport state — is what the mirror
      # then shows.
      ck mirror.session.calltraceVM.viewportHeight.val == 37
      ck mirror.session.eventLogVM.pageSize.val == 24
      mirror.dispose()
      host.dispose()
      done()

  test "a lost batch is recovered with a new snapshot":
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      # A transport that drops the next batch it carries to the mirror.
      var dropNext = false
      var mirrorEnd: SyncChannel
      let toMirror = newSyncChannel(proc(msg: JsonNode) =
        if dropNext and msg{"type"}.getStr == "signal-batch":
          dropNext = false
          return
        mirrorEnd.deliver(msg.copy))
      var hostEnd = toMirror
      mirrorEnd = newSyncChannel(proc(msg: JsonNode) =
        hostEnd.deliver(msg.copy))
      let mirror = createMirrorSession(mirrorEnd)
      host.attach(toMirror)
      ck mirror.subscriber.inStep
      dropNext = true
      primary.moveTo(10, "a.nim", 1)
      for callback in queued: callback()
      queued = @[]
      primary.moveTo(20, "a.nim", 2)
      for callback in queued: callback()
      queued = @[]
      # Revision 2 arrived after a lost revision 1: refused, a snapshot
      # asked for and applied.
      ck mirror.subscriber.inStep
      ck mirror.session.store.debugger.val.rrTicks == 20
      ck agree(primary, mirror.session).len == 0
      mirror.dispose()
      host.dispose()
      done()

suite "several primaries, one set of mirrors":

  test "switching mirrors the second; the first keeps its position":
    createRoot proc(done: proc()) =
      let (first, _) = newPrimary()
      let (second, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("first", first)
      host.addPrimary("second", second)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      ck mirror.following == "first"

      first.moveTo(111, "first.nim", 11)
      first.stateVM.selectTab(stGlobals)
      second.moveTo(222, "second.nim", 22)
      link.settle()
      ck mirror.session.store.debugger.val.rrTicks == 111

      host.activate("second")
      link.settle()
      ck mirror.following == "second"
      ck mirror.session.store.debugger.val.rrTicks == 222
      ck mirror.session.stateVM.activeTab.val == stLocals
      checkpoint $agree(second, mirror.session)
      ck agree(second, mirror.session).len == 0
      # The first session, unwatched, kept its position and its pane state.
      ck first.store.debugger.val.rrTicks == 111
      ck first.stateVM.activeTab.val == stGlobals

      # It moves while hidden; the mirror does not show it.
      first.moveTo(333, "first.nim", 33)
      link.settle()
      ck mirror.session.store.debugger.val.rrTicks == 222

      # An action now runs on the session the mirror follows.
      mirror.relay("state", "addWatch", %*{"expression": actionArg("w")})
      link.settle()
      ck second.stateVM.watchExpressions.val == @["w"]
      ck first.stateVM.watchExpressions.val.len == 0

      host.activate("first")
      link.settle()
      ck mirror.session.store.debugger.val.rrTicks == 333
      ck mirror.session.stateVM.activeTab.val == stGlobals
      checkpoint $agree(first, mirror.session)
      ck agree(first, mirror.session).len == 0
      mirror.dispose()
      host.dispose()
      done()

  test "a mirror asking for a session the host lacks is told so":
    createRoot proc(done: proc()) =
      let (first, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("first", first)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      mirror.switchTo("gone")
      link.settle()
      ck mirror.unknownSession == "gone"
      ck not mirror.subscriber.inStep
      mirror.dispose()
      host.dispose()
      done()

echo "CHECKS: ", checks
