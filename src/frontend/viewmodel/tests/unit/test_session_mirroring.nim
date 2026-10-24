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

import std/[json, options, sets, tables, unittest]

import isonim/core/[async_compat, owner, signals]

import ../../backend/mock_backend
import ../../session_vm
import ../../store/replay_data_store
import ../../store/types
import ../../sync/[action_relay, mirror_session, sync_host, sync_publisher,
                   sync_subscriber, synced_signals, transport]
import ../../viewmodels/[calltrace_vm, debug_controls_vm, event_log_vm,
                         flow_layout, flow_vm,
                         filesystem_vm, terminal_output_model,
                         terminal_output_vm,
                         state_vm]
import ../../viewport

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
      session.stateVM.selectPath("g")
      for callback in queued: callback()
      queued = @[]
      ck sent.len == 1
      ck sent[0]["type"].getStr == "signal-batch"
      ck sent[0]["session"].getStr == "s1"
      ck sent[0]["revision"].getInt == 1
      var keys: seq[string]
      for e in sent[0]["batch"]: keys.add e["key"].getStr
      ck "store.debugger" in keys
      ck "state.selectedPath" in keys
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
      primary.stateVM.selectPath("w")
      link.settle()

      let differing = agree(primary, mirror.session)
      checkpoint $differing
      ck differing.len == 0
      ck mirror.session.store.debugger.val.rrTicks == 200
      ck mirror.session.store.locals.locals.val[0].name == "y"
      ck mirror.session.calltraceVM.selectedEntry.val == some(1'i64)
      ck mirror.session.stateVM.selectedPath.val == "w"
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

      mirror.relay("state", "selectPath", %*{"path": actionArg("g")})
      mirror.relay("calltrace", "selectEntry",
                   %*{"lineIndex": actionArg(some(3'i64))})
      link.settle()
      ck primary.stateVM.selectedPath.val == "g"
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

  test "a watch typed on the mirror reaches the primary's watch list":
    # The page's watch input calls `StateVM.addWatch`, which goes through the
    # collaboration core as a view operation, not through `relay`: this is
    # the route a real page takes, and the one the action relay above does
    # not exercise.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      mirror.session.stateVM.addWatch("initial_shield")
      link.settle()
      ck primary.stateVM.watchExpressions.val == @["initial_shield"]
      mirror.dispose()
      host.dispose()
      done()

  test "a selection and a watch made before the mirror's snapshot survive its next view operation":
    # codetracer-pm issues/2026-10-22-a-watch-typed-in-the-browser-never-
    # produces-a-row.md, measured under `ct host`: the page chose the Watches
    # tab and typed a watch while its first snapshot was on the wire. The
    # snapshot carried the primary's view document from BEFORE those
    # operations, and replaced the page's; the batches after it carried the
    # primary's answer as signals, so the pane looked right — but the page's
    # document stayed the old one, and the next view operation on the page
    # projected it: the pane went back to Locals with no watches, and the
    # primary, whose own tab never changed, never sent it again. The second
    # watch then landed in a tab nobody was looking at.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      # The host's messages to the mirror are HELD, so the test decides
      # when each arrives; the mirror's reach the host at once.
      var held: seq[JsonNode]
      var mirrorEnd: SyncChannel
      let toMirror = newSyncChannel(proc(msg: JsonNode) = held.add msg.copy)
      mirrorEnd = newSyncChannel(proc(msg: JsonNode) =
        toMirror.deliver(msg.copy))
      proc deliverHeld() =
        while held.len > 0 or queued.len > 0:
          let run = queued
          queued = @[]
          for callback in run: callback()
          let msgs = held
          held = @[]
          for msg in msgs: mirrorEnd.deliver(msg)
      let mirror = createMirrorSession(mirrorEnd)
      host.attach(toMirror)
      # `activate` reaches the mirror, which subscribes; its snapshot is
      # held, as it was on the wire.
      while held.len > 0 and held[0]{"type"}.getStr != "signal-snapshot":
        mirrorEnd.deliver(held[0])
        held.delete(0)
      check held.len == 1   # the snapshot, not yet delivered
      let svm = mirror.session.stateVM
      svm.selectPath("w")
      svm.addWatch("initial_shield")
      deliverHeld()
      ck primary.stateVM.selectedPath.val == "w"
      ck primary.stateVM.watchExpressions.val == @["initial_shield"]
      ck svm.selectedPath.val == "w"
      ck svm.watchExpressions.val == @["initial_shield"]
      # Any later view operation on the mirror — here a row expanded.
      svm.toggleExpand("asteroid_masses_positive")
      deliverHeld()
      ck primary.stateVM.expandedPaths.val.contains("asteroid_masses_positive")
      ck svm.selectedPath.val == "w"
      ck svm.watchExpressions.val == @["initial_shield"]
      # And the next watch joins the first, in the tab being looked at.
      svm.addWatch("asteroid_masses_positive[1]")
      deliverHeld()
      ck primary.stateVM.watchExpressions.val ==
         @["initial_shield", "asteroid_masses_positive[1]"]
      ck svm.watchExpressions.val ==
         @["initial_shield", "asteroid_masses_positive[1]"]
      ck svm.selectedPath.val == "w"
      mirror.dispose()
      host.dispose()
      done()

  test "a selection and a watch made before the mirror follows a session reach it":
    # The same report, the other order measured under `ct host`: the page
    # is on screen, and its tab strip and watch input usable, BEFORE the
    # server's session exists (it is made at the replay's first stop) and so
    # before the page follows it. The operations were applied to the page's
    # own document and sent nowhere (`publishLocalViewOp` had no session to
    # name); the snapshot that followed replaced that document, and the
    # Watches tab and the watch were gone — from the page AND from the
    # session, which had never heard of them.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      check mirror.following.len == 0   # no session is hosted yet
      let svm = mirror.session.stateVM
      svm.selectPath("w")
      svm.addWatch("initial_shield")
      ck svm.selectedPath.val == "w"   # shown at once, as typed
      host.addPrimary("s1", primary)
      link.settle()
      ck mirror.following == "s1"
      ck primary.stateVM.selectedPath.val == "w"
      ck primary.stateVM.watchExpressions.val == @["initial_shield"]
      ck svm.selectedPath.val == "w"
      ck svm.watchExpressions.val == @["initial_shield"]
      mirror.dispose()
      host.dispose()
      done()

  test "a mirror's view operation is not taken for one the primary already applied":
    # The same report, a third time under `ct host`: the page's click on the
    # Watches tab reached the server's session and was DROPPED as a
    # duplicate. A collaboration core names its operations
    # `<actor>:<sequence>`, and the actor is `local-actor-<storeId>` — a
    # counter of the PROCESS, so the page's first session and the server's
    # first session are both `local-actor-1`, and both number their
    # operations from 1. The server had made a view operation of its own
    # first (the call trace following the stop), and the page's tab, the
    # same `local-actor-1:1`, was refused as already applied. The two cores
    # are given that same actor here, as two processes give it to them.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      mirror.session.collabCore.localActorId =
        primary.collabCore.localActorId
      link.settle()
      # The primary's own view operation, first.
      primary.stateVM.toggleExpand("asteroid_masses_positive")
      link.settle()
      mirror.session.stateVM.selectPath("w")
      mirror.session.stateVM.addWatch("initial_shield")
      link.settle()
      ck primary.stateVM.selectedPath.val == "w"
      ck primary.stateVM.watchExpressions.val == @["initial_shield"]
      ck mirror.session.stateVM.selectedPath.val == "w"
      ck mirror.session.stateVM.watchExpressions.val == @["initial_shield"]
      mirror.dispose()
      host.dispose()
      done()

  test "a reloaded page's view operations reach the session it left":
    # `hosted_primary`: THE SESSION OUTLIVES CONNECTIONS, and a reloaded page
    # is a new mirror whose collaboration core starts its sequence again —
    # in a new page, with the same `local-actor-1` as the page before it.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let first = newInMemoryLink()
      host.attach(first.a)
      let before = createMirrorSession(first.b)
      first.settle()
      before.session.stateVM.addWatch("initial_shield")
      first.settle()
      let actor = before.session.collabCore.localActorId
      host.detach(first.a)
      before.dispose()
      let second = newInMemoryLink()
      host.attach(second.a)
      let after = createMirrorSession(second.b)
      after.session.collabCore.localActorId = actor
      second.settle()
      ck after.session.stateVM.watchExpressions.val == @["initial_shield"]
      after.session.stateVM.addWatch("asteroid_masses_positive[1]")
      second.settle()
      ck primary.stateVM.watchExpressions.val ==
         @["initial_shield", "asteroid_masses_positive[1]"]
      ck after.session.stateVM.watchExpressions.val ==
         @["initial_shield", "asteroid_masses_positive[1]"]
      after.dispose()
      host.dispose()
      done()

  test "a watch another mirror added can be removed on this one":
    # Variable-State-Pane.md: watch expressions "add, edit, remove", in every
    # front-end. A removal names the watch's live add tags, which the mirror
    # reads from ITS view document (`liveWatchForExpression`); a document that
    # only a snapshot ever updated had no such watch, and the removal was a
    # silent no-op.
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let linkA = newInMemoryLink()
      host.attach(linkA.a)
      let mirrorA = createMirrorSession(linkA.b)
      linkA.settle()
      let linkB = newInMemoryLink()
      host.attach(linkB.a)
      let mirrorB = createMirrorSession(linkB.b)
      linkB.settle()
      mirrorB.session.stateVM.addWatch("initial_shield")
      linkB.settle()
      linkA.settle()
      ck primary.stateVM.watchExpressions.val == @["initial_shield"]
      ck mirrorA.session.stateVM.watchExpressions.val == @["initial_shield"]
      mirrorA.session.stateVM.removeWatch("initial_shield")
      linkA.settle()
      linkB.settle()
      ck primary.stateVM.watchExpressions.val.len == 0
      ck mirrorA.session.stateVM.watchExpressions.val.len == 0
      ck mirrorB.session.stateVM.watchExpressions.val.len == 0
      mirrorA.dispose()
      mirrorB.dispose()
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

  test "a value holding a nil JSON node is mirrored, in the snapshot and in a batch":
    # The flow window's recorded values are `JsonNode`s, nil for a step that
    # recorded none (`FlowValueText.value`). Encoded as the same reference,
    # the nil reached `std/json`'s `$` / `copy` / `==`, which dereference it:
    # the snapshot and every later batch raised, and the mirror kept the last
    # message it had received (under `ct host`, a page with no stop and no
    # watches). The link copies each message as a real transport does, so it
    # meets the nil as the socket did.
    proc windowWith(text: string): FlowLayoutWindow =
      FlowLayoutWindow(tabSize: 4, steps: @[FlowLayoutStep(
        stepCount: 0, line: 3,
        beforeValues: @[FlowValueText(expression: "x", text: text)])])
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      primary.flowVM.layoutWindows.val = @[windowWith("1")]
      check primary.flowVM.layoutWindows.val[0].steps[0].beforeValues[0].value.isNil
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      # The snapshot.
      let windows = mirror.session.flowVM.layoutWindows.val
      ck windows.len == 1
      if windows.len == 1:
        ck windows[0].steps[0].beforeValues[0].text == "1"
        let v = windows[0].steps[0].beforeValues[0].value
        ck v.isNil or v.kind == JNull
      # A batch carrying the nil, and a move after it: the session keeps
      # being mirrored.
      primary.flowVM.layoutWindows.val = @[windowWith("2")]
      primary.moveTo(7, "/src/main.nr", 12)
      link.settle()
      ck mirror.session.flowVM.layoutWindows.val.len == 1
      if mirror.session.flowVM.layoutWindows.val.len == 1:
        ck mirror.session.flowVM.layoutWindows.val[0].steps[0].beforeValues[0].text == "2"
      ck mirror.session.store.debugger.val.location.line == 12
      # Encoding did not write `null` into the primary's own value.
      ck primary.flowVM.layoutWindows.val[0].steps[0].beforeValues[0].value.isNil
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
      first.stateVM.selectPath("g")
      second.moveTo(222, "second.nim", 22)
      link.settle()
      ck mirror.session.store.debugger.val.rrTicks == 111

      host.activate("second")
      link.settle()
      ck mirror.following == "second"
      ck mirror.session.store.debugger.val.rrTicks == 222
      ck mirror.session.stateVM.selectedPath.val == ""
      checkpoint $agree(second, mirror.session)
      ck agree(second, mirror.session).len == 0
      # The first session, unwatched, kept its position and its pane state.
      ck first.store.debugger.val.rrTicks == 111
      ck first.stateVM.selectedPath.val == "g"

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
      ck mirror.session.stateVM.selectedPath.val == "g"
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

suite "mirrors pinned each to its own primary (a ct host client each)":
  # `CLI/ct/host.md`, "Sessions are isolated": every `ct host` client has a
  # session of its own on the server's one host, and its page follows that
  # session only (`sync_host.attach(…, follow)`, `hosted_primary`).

  proc settleBoth(a, b: InMemoryLink) =
    for _ in 0 ..< 10:
      a.settle()
      b.settle()

  test "each follows its own; a move of one is not shown to the other":
    createRoot proc(done: proc()) =
      let (first, _) = newPrimary()
      let (second, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("first", first)
      host.addPrimary("second", second)
      let linkA = newInMemoryLink()
      let linkB = newInMemoryLink()
      host.attach(linkA.a, follow = "first")
      host.attach(linkB.a, follow = "second")
      let a = createMirrorSession(linkA.b)
      let b = createMirrorSession(linkB.b)
      settleBoth(linkA, linkB)
      ck a.following == "first"
      ck b.following == "second"

      first.moveTo(111, "first.nim", 11)
      second.moveTo(222, "second.nim", 22)
      settleBoth(linkA, linkB)
      ck a.session.store.debugger.val.rrTicks == 111
      ck b.session.store.debugger.val.rrTicks == 222

      first.moveTo(333, "first.nim", 33)
      settleBoth(linkA, linkB)
      ck a.session.store.debugger.val.rrTicks == 333
      ck b.session.store.debugger.val.rrTicks == 222

      # The host's active session is not theirs to follow.
      host.activate("second")
      settleBoth(linkA, linkB)
      ck a.following == "first"
      ck a.session.store.debugger.val.rrTicks == 333
      a.dispose()
      b.dispose()
      host.dispose()
      done()

  test "a pinned mirror can neither subscribe to nor act on another's session":
    createRoot proc(done: proc()) =
      let (first, _) = newPrimary()
      let (second, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("first", first)
      host.addPrimary("second", second)
      let linkB = newInMemoryLink()
      host.attach(linkB.a, follow = "second")
      let b = createMirrorSession(linkB.b)
      linkB.settle()
      first.moveTo(111, "first.nim", 11)
      linkB.settle()

      b.switchTo("first")
      linkB.settle()
      ck b.unknownSession == "first"
      ck b.session.store.debugger.val.rrTicks != 111

      linkB.b.send(serializeAction("state", "addWatch",
        %*{"expression": actionArg("w")}, "first"))
      linkB.settle()
      ck first.stateVM.watchExpressions.val.len == 0
      b.dispose()
      host.dispose()
      done()

  test "a mirror pinned before its session is hosted follows it once it is":
    createRoot proc(done: proc()) =
      let (first, _) = newPrimary()
      let (second, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("first", first)
      let link = newInMemoryLink()
      host.attach(link.a, follow = "second")
      let mirror = createMirrorSession(link.b)
      link.settle()
      # Not the active session in its place: nothing until its own exists.
      ck mirror.following == ""
      second.moveTo(222, "second.nim", 22)
      host.addPrimary("second", second)
      link.settle()
      ck mirror.following == "second"
      ck mirror.session.store.debugger.val.rrTicks == 222
      mirror.dispose()
      host.dispose()
      done()

suite "a mirror whose panels act on the primary (a VS Code webview)":

  test "a view's call on the mirror's ViewModel runs on the primary":
    # The views call the ViewModels as anywhere; with `relayActions` the
    # mirror's ViewModels hand those calls to the primary
    # (Shared-DOM-Front-Ends D6), which runs them on its own backend.
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b, relayActions = true)
      link.settle()
      primary.store.calltrace.lines.val = @[callLine(0, "main"),
                                             callLine(1, "helper")]
      primary.store.calltrace.totalCallsCount.val = 2
      link.settle()

      # An `Option` argument.
      mirror.session.calltraceVM.selectEntry(some(1'i64))
      # An enum argument.
      mirror.session.stateVM.selectPath("g")
      link.settle()
      ck primary.calltraceVM.selectedEntry.val == some(1'i64)
      ck mirror.session.calltraceVM.selectedEntry.val == some(1'i64)
      ck primary.stateVM.selectedPath.val == "g"
      ck mirror.session.stateVM.selectedPath.val == "g"

      # An action that asks the backend: the PRIMARY's backend is asked.
      mock.clearReceivedCommands()
      mirror.session.calltraceVM.doubleClickEntry(1)
      link.settle()
      ck mock.findCommand("ct/calltrace-jump").isSome

      # A clearing `Option`.
      mirror.session.calltraceVM.selectEntry(none(int64))
      link.settle()
      ck primary.calltraceVM.selectedEntry.val.isNone

      # The size the mirror's view measured reaches the primary's ViewModel,
      # and the mirror keeps it too.
      mirror.session.eventLogVM.setViewport(Viewport(rows: 17))
      link.settle()
      ck primary.eventLogVM.viewport.val.rows == 17
      ck mirror.session.eventLogVM.viewport.val.rows == 17
      mirror.dispose()
      host.dispose()
      done()

  test "without relayActions a mirror's ViewModel acts on its own":
    createRoot proc(done: proc()) =
      let (primary, _) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("s1", primary)
      let link = newInMemoryLink()
      host.attach(link.a)
      let mirror = createMirrorSession(link.b)
      link.settle()
      ck mirror.session.calltraceVM.actionSink.isNil
      ck mirror.session.stateVM.actionSink.isNil
      mirror.dispose()
      host.dispose()
      done()

suite "a ct host page's mirror (Shared-DOM-Front-Ends D2)":
  # `ct host`: the server owns the client's session and the page mirrors it,
  # relaying its panels' actions with `action_relay` exactly as a VS Code
  # webview does — while its toolbar still steps the replay the page drives.
  # The page measures its panes; the server's session has no screen, so
  # nothing loads for a pane until the page's measurement reaches it
  # (Viewport-Driven-Loading V3). That never happened: the page's mirror
  # relayed nothing, the call trace stayed empty in the browser, and a click
  # on a call went to the mirror's inert backend.

  test "the call trace the page measured loads on the server's session":
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("ct-host/replay-0", primary)
      let link = newInMemoryLink()
      host.attach(link.a, follow = "ct-host/replay-0")
      var hostSteps: seq[string]
      let mirror = createHostedPageMirror(link.b,
        debugCommandsFor = proc(session: SessionViewModel): DebugCommands =
          result = defaultDebugCommands(session.store)
          result.step = proc(actionId: string) = hostSteps.add actionId)
      link.settle()
      primary.moveTo(100, "main.c", 69)
      link.settle()

      mock.clearReceivedCommands()
      mirror.session.calltraceVM.setViewport(
        Viewport(rows: 17, cols: 87, firstRow: 0))
      link.settle()
      drainPlatformCallbacks()
      ck primary.calltraceVM.viewport.val.rows == 17
      ck mock.findCommand("ct/load-calltrace-section").isSome

      # A click on a call jumps on the server's session, over its backend.
      primary.store.calltrace.lines.val = @[callLine(0, "main"),
                                             callLine(1, "helper")]
      primary.store.calltrace.totalCallsCount.val = 2
      link.settle()
      mock.clearReceivedCommands()
      mirror.session.calltraceVM.doubleClickEntry(0)
      link.settle()
      ck mock.findCommand("ct/calltrace-jump").isSome

      # The toolbar is still the page's: a step is not relayed.
      mock.clearReceivedCommands()
      mirror.session.debugControlsVM.invokeToolbarStep("next")
      link.settle()
      ck hostSteps == @["next"]
      ck mock.findCommand("next").isNone
      mirror.dispose()
      host.dispose()
      done()

  test "the actions that reach the page's own callbacks stay on the page":
    # The file tree opens a file in the PAGE's editor and loads a folder
    # through the page (`onOpenFile`, `onFolderExpanded`, installed by
    # `ui/filesystem`); the terminal output saves the page's view choice
    # (`onViewChosen`). The server's session has none of these callbacks, so
    # relayed there they would do nothing: the Files pane stayed on
    # "Loading..." in the browser when every panel action was relayed.
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      host.addPrimary("ct-host/replay-0", primary)
      let link = newInMemoryLink()
      host.attach(link.a, follow = "ct-host/replay-0")
      let mirror = createHostedPageMirror(link.b)
      link.settle()
      var opened, expanded: seq[string]
      var chosen = 0
      mirror.session.fileTreeVM.onOpenFile = proc(path: string) =
        opened.add path
      mirror.session.fileTreeVM.onFolderExpanded = proc(path: string) =
        expanded.add path
      mirror.session.terminalOutputVM.onViewChosen =
        proc(memory: Table[string, TerminalView]) = inc chosen
      mirror.session.terminalOutputVM.setRecordingKey("rec",
        initTable[string, TerminalView]())

      let before = host.actionsApplied
      mock.clearReceivedCommands()
      mirror.session.fileTreeVM.openFile("/src/main.c")
      mirror.session.fileTreeVM.expandPath("/src")
      mirror.session.terminalOutputVM.setView(tvLines)
      link.settle()
      ck opened == @["/src/main.c"]
      ck expanded == @["/src"]
      ck chosen == 1
      ck host.actionsApplied == before
      ck "/src" notin primary.fileTreeVM.expandedPaths.val
      mirror.dispose()
      host.dispose()
      done()

  test "a pane measured before the server's session exists loads once it does":
    # The page mounts and measures its panes as soon as the trace is shown;
    # the server hosts the client's session only on the replay's first stop
    # (`hosted_primary`). A report sent before then names no hosted session
    # and is dropped, and a pane that is not resized never reports again.
    createRoot proc(done: proc()) =
      let (primary, mock) = newPrimary()
      let host = newSyncHost(manual)
      let link = newInMemoryLink()
      host.attach(link.a, follow = "ct-host/replay-0")
      let mirror = createHostedPageMirror(link.b)
      link.settle()
      ck mirror.following == ""
      mirror.session.calltraceVM.setViewport(
        Viewport(rows: 17, cols: 87, firstRow: 0))
      mirror.session.eventLogVM.setViewport(Viewport(rows: 12))
      link.settle()
      drainPlatformCallbacks()

      mock.clearReceivedCommands()
      primary.moveTo(100, "main.c", 69)
      host.addPrimary("ct-host/replay-0", primary)
      link.settle()
      drainPlatformCallbacks()
      ck mirror.following == "ct-host/replay-0"
      ck primary.calltraceVM.viewport.val.rows == 17
      ck primary.calltraceVM.viewport.val.cols == 87
      ck primary.eventLogVM.viewport.val.rows == 12
      ck mock.findCommand("ct/load-calltrace-section").isSome
      mirror.dispose()
      host.dispose()
      done()

echo "CHECKS: ", checks
