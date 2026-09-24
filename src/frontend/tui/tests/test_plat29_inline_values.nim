## PLAT-29 — the DAP data that feeds the locals and the inline values names
## the STOP it was requested at, and is reconciled before it is applied and
## again before it is drawn.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat29_inline_values.nim
##
## `store/stop_timeline` puts the fourth producer §11 names — *"the DAP data
## that feeds inline values"* — on the same `reconcile` boundary as the other
## three. The version is the debugger's STOP; a `ct/load-locals` answer names
## the stop it was sent at (`HeadlessDebugSession.fetchLocals`), and
## `ReplayDataStore.applyLocalsResponse` drops one the debugger has moved past.
## `viewmodels/inline_value_timeline.InlineValueGate` is the draw half. This
## suite asserts:
##
##   * over the timeline itself: the SAME stop is `roApplied`; a move — another
##     tick, another line, another file, another HCR generation — drops
##     (`drEvidenceDeleted`); a move mirrored twice is ONE move; a request
##     sent before any stop was known is dropped; one older than the timeline
##     remembers is `drVersionForgotten`; and a verdict counted into a draw
##     report leaves the arrival report alone;
##   * on a REAL recording through a REAL `replay-server`: a real
##     `ct/load-locals` answer, requested at one stop and applied after a real
##     `next` moved the debugger, is DROPPED — the store keeps what it had, and
##     the gate withholds the previous stop's values rather than drawing them
##     beside the new line; its twin, applied without the move, is APPLIED;
##     two answers arriving IN ORDER after a move between their requests —
##     the web renderer's shape — drop the first and apply the second; and the
##     shipped refresh loop draws values through the gate with every arrival
##     applied.
##
## NO MOCKS: real `DebuggerState`s, the shipped reconciler, and — in the
## second suite — a real recording through a real `replay-server`. The gap
## between the request and the answer is made by calling the two halves of
## the shipped load (`fetchLocals`, `applyLocals`) with a real step between
## them; nothing about the answer or the move is simulated.

import std/[os, strutils, unittest]

import codetracer_embed
import ../app/runtime
import ../app/source_binding
import ../app/tui_app
import ../app/theme/capabilities
import ../host/tui_session
import ../../viewmodel/headless_session
import ../../viewmodel/store/[replay_data_store, types]
import ../../viewmodel/viewmodels/inline_value_timeline
import ../../../common/view_vocabulary/editor_rows
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc localsCurrent(store: ReplayDataStore): bool =
  ## Whether the store's locals are about the stop the debugger is at — the
  ## gate's own verdict, asked through the timeline without counting.
  store.observeStop()
  var scratch: StalenessReport
  store.hasLocalsStamp and
    store.stops.reconcileStamp(store.localsStamp, scratch) != roDropped

proc stopAt(ticks: uint64; file = "calc.py"; line = 3; gen = 0;
          digest = "d0"): DebuggerState =
  DebuggerState(rrTicks: ticks,
                location: Location(file: file, line: line,
                                   sourceGeneration: gen,
                                   sourceDigest: digest))

suite "PLAT-29: a DAP answer is reconciled against the stop it was asked at":

  test "the same stop is applied as computed":
    var tl = initStopTimeline()
    tl.observe(stopAt(10))
    let s = tl.stamp()
    tl.observe(stopAt(10))                          # still the same stop
    ck tl.admit(s)
    ck tl.report.count(pkInlineValues, roApplied) == 1

  test "a move — tick, line, file or HCR generation — drops it":
    var tl = initStopTimeline()
    for moved in [stopAt(11), stopAt(10, line = 4), stopAt(10, file = "util.py"),
                  stopAt(10, gen = 1), stopAt(10, digest = "d1")]:
      tl.observe(stopAt(10))
      let s = tl.stamp()
      tl.observe(moved)
      ck not tl.admit(s)
    ck tl.report.count(pkInlineValues, roDropped) == 5
    ck tl.report.reasonCount(drEvidenceDeleted) == 5
    ck tl.report.count(pkInlineValues, roApplied) == 0

  test "one move mirrored twice is one version, so its own request survives":
    # The web renderer reports every move twice (`ui_js` and `ui/state`); a
    # request sent between the two mirrors must not be made stale by the
    # second.
    var tl = initStopTimeline()
    tl.observe(stopAt(10))
    let v = tl.stamp().version
    tl.observe(stopAt(10))
    ck tl.stamp().version == v
    let s = tl.stamp()
    tl.observe(stopAt(10))
    ck tl.admit(s)

  test "a request sent before any stop was known is dropped":
    var tl = initStopTimeline()
    let s = tl.stamp()
    tl.observe(stopAt(10))
    ck not tl.admit(s)
    ck tl.report.reasonCount(drEvidenceDeleted) == 1

  test "a request older than the timeline remembers is forgotten, and counted":
    var tl = initStopTimeline()
    tl.observe(stopAt(0))
    let s = tl.stamp()
    for t in 1 .. StopTimelineDepth + 2:
      tl.observe(stopAt(uint64(t)))
    ck not tl.admit(s)
    ck tl.report.reasonCount(drVersionForgotten) == 1

  test "a verdict counted into another report leaves the arrivals alone":
    # The draw half counts into the GATE's report through `reconcileStamp`;
    # the store's arrival report must not move when a frame is drawn.
    var tl = initStopTimeline()
    tl.observe(stopAt(10))
    let s = tl.stamp()
    var draws: StalenessReport
    ck tl.reconcileStamp(s, draws) == roApplied
    tl.observe(stopAt(11))
    ck tl.reconcileStamp(s, draws) == roDropped
    ck draws.total() == 2
    ck tl.report.total() == 0

suite "PLAT-29: real DAP answers on a real recording":

  let resolution = resolveFixture("calc")

  template withSession(body: untyped) =
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let caps = resolveCapabilities(
        initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                        lang = "en_US.UTF-8"), initCapabilityFlags())
      let rt {.inject.} = newTuiRuntime(newTuiApp(), caps, 160, 48)
      let s {.inject.} = openTuiSession(resolution.tracePath,
                                        viewportHeight = 42)
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      body

  test "an answer the debugger moved past is dropped, and not drawn":
    withSession:
      let store = s.session.session.store
      # Walk until a stop has locals, so "withheld" is not satisfied by a
      # stop that had nothing to draw.
      var steps = 0
      s.refresh(rt)
      while steps < 20 and store.locals.locals.val.len == 0:
        s.session.stepForward()
        s.refresh(rt)
        inc steps
      checkpoint("stop with locals after " & $steps & " steps")
      ck store.locals.locals.val.len > 0
      ck store.localsCurrent()
      let before = store.locals.locals.val
      let arrivalsBefore = store.stops.report.total()

      # THE GAP: a real request at this stop, a real `next`, then the answer.
      let answer = s.session.fetchLocals()
      ck answer.ok
      let at = store.debugger.val
      s.session.stepForward()
      let moved = store.debugger.val
      checkpoint("moved from tick " & $at.rrTicks & " line " &
                 $at.location.line & " to tick " & $moved.rrTicks & " line " &
                 $moved.location.line)
      ck stopIdentityOf(at) != stopIdentityOf(moved)
      ck not s.session.applyLocals(answer)
      ck store.stops.report.total() == arrivalsBefore + 1
      ck store.stops.report.count(pkInlineValues, roDropped) == 1
      ck store.stops.report.reasonCount(drEvidenceDeleted) == 1
      # The store kept what it had — and what it had is the PREVIOUS stop's
      # locals, which is exactly why the draw half exists.
      ck store.locals.locals.val == before
      ck not store.localsCurrent()
      var gate = InlineValueGate()
      let offered = inlineValuesOf(s.state, tuiRowBudget(160, false))
      ck offered.len > 0                  # there WAS something to withhold
      ck gate.installable(store, offered).len == 0
      ck gate.report.count(pkInlineValues, roDropped) == 1

      # THE TWIN: the same fetch-then-apply with no move between is applied,
      # and the gate then draws what it is handed.
      let fresh = s.session.fetchLocals()
      ck s.session.applyLocals(fresh)
      ck store.localsCurrent()
      ck store.stops.report.count(pkInlineValues, roApplied) >= 1
      let now = inlineValuesOf(s.state, tuiRowBudget(160, false))
      ck gate.installable(store, now) == now
      ck gate.report.count(pkInlineValues, roApplied) == 1

  test "answers named by their request after the debugger moved: the old one dropped":
    # THE WEB RENDERER'S SHAPE, over real DAP data: each request is recorded
    # under the transport's identity for it as it is sent
    # (`noteLocalsRequestSent`), and its answer, arriving later, names the same
    # identity (`applyLocalsAnswer`) — matched by NAME, never by arrival order,
    # because the web sends `ct/load-locals` from two places. Here the second
    # request is sent after a real `next`, and the answers arrive in the
    # opposite order to the requests: the one asked at the stop the debugger
    # has left is dropped whenever it lands. (The web wiring that produces the
    # identities is driven in `src/frontend/tests/locals_answer_identity_test.nim`.)
    withSession:
      let store = s.session.session.store
      s.refresh(rt)
      let droppedBefore = store.stops.report.count(pkInlineValues, roDropped)
      store.noteLocalsRequestSent("0:1")
      let first = s.session.fetchLocals()
      s.session.stepForward()
      store.noteLocalsRequestSent("0:2")
      let second = s.session.fetchLocals()
      ck first.ok and second.ok
      ck store.pendingLocals.len == 2
      ck store.applyLocalsAnswer(second.rows, "0:2")       # asked at this stop
      ck not store.applyLocalsAnswer(first.rows, "0:1")    # asked at the old one
      # A second delivery of one answer is told the first verdict and is not
      # reconciled — or counted — again.
      ck not store.applyLocalsAnswer(first.rows, "0:1")
      ck store.applyLocalsAnswer(second.rows, "0:2")
      ck store.stops.report.count(pkInlineValues, roDropped) == droppedBefore + 1
      store.forgetLocalsRequest("0:1")
      store.forgetLocalsRequest("0:2")
      ck store.pendingLocals.len == 0
      # An answer naming a request the store holds no record of is dropped.
      ck not store.applyLocalsAnswer(first.rows, "0:1")
      ck store.stops.report.count(pkInlineValues, roDropped) == droppedBefore + 2
      ck store.localsCurrent()
      # And what the store now holds is the SECOND answer, byte for byte —
      # the drop did not write the first one over it.
      var nonWatch: seq[string] = @[]
      for v in second.rows:
        if not v.isWatch: nonWatch.add v.name
      var held: seq[string] = @[]
      for v in store.locals.locals.val: held.add v.name
      ck held == nonWatch

  test "the shipped refresh loop: every arrival applied, values drawn":
    withSession:
      let store = s.session.session.store
      var drawn = 0
      for _ in 0 ..< 12:
        s.session.stepForward()
        s.refresh(rt)
        drawn += rt.app.source.values.len
      checkpoint("arrivals:\n" & reportLines(store.stops.report).join("\n"))
      checkpoint("draws:\n" & reportLines(s.valueGate.report).join("\n"))
      ck store.stops.report.count(pkInlineValues, roApplied) >= 12
      ck store.stops.report.count(pkInlineValues, roDropped) == 0
      ck s.valueGate.report.count(pkInlineValues, roApplied) >= 12
      ck s.valueGate.report.count(pkInlineValues, roDropped) == 0
      ck drawn > 0

suite "PLAT-29 inline values — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
