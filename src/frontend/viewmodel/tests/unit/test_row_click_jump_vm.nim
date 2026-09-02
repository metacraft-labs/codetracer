## Headless ViewModel test — the two row-click gestures actually MOVE
## the debugger, against a real ``replay-server``.
##
## ## Why this test exists
##
## ``StepListVM.jumpToStepLine`` and ``LowLevelCodeVM.jumpToInstruction``
## each used to emit a command string — ``ct/line-step-jump`` and
## ``ct/asm-instruction-jump`` — that appears in no mapping table:
## not in ``EVENT_KIND_TO_DAP_MAPPING`` (``src/frontend/dap.nim``), not in
## ``VALID_DAP_COMMANDS`` (``backend/dap_commands.nim``), and in neither
## dispatch table in ``db-backend/src/dap_server.rs``.  The production
## ``sendProc`` (``ui_js.nim``) resolves the string through
## ``dapCommandToEventKind`` *before* touching any transport, and that
## proc raises ``ValueError`` on an unmapped string — so a row click threw
## synchronously out of the click handler.
##
## Both commands already had tests.  Both tests passed.  They passed
## because they asserted that the command was *dispatched on a mock*:
## ``MockBackendService.send`` records the command and validates nothing,
## so a string no engine implements is indistinguishable from one every
## engine implements.  That is the exact failure this file is written not
## to repeat.
##
## **So nothing here asserts a dispatch.**  Every assertion below is a
## position read back out of ``ReplayDataStore.debugger`` *after a real
## ``replay-server`` processed the request and emitted its
## ``ct/complete-move``*.  If the command were unmapped, the send would
## raise; if it were mapped but unimplemented, ``handle_request``'s
## fallthrough would refuse it by name and no complete-move would arrive;
## if it were implemented but wrong, the line/tick would land elsewhere.
## Only an actual move satisfies these checks.
##
## ## Self-calibration, so no arm can go vacuous
##
## The test never hardcodes a line number or a tick.  It *discovers* a
## second position by stepping the real trace, and asserts that the
## discovered position genuinely differs from the start
## (``findDistinctLaterPosition``).  A jump "back to where we already are" would
## prove nothing, so if the trace ever stops offering two distinct
## positions the test FAILS rather than silently passing on a degenerate
## premise.
##
## Compile + run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_row_click_jump_vm.nim
##
## Required environment:
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server (falls back
##     to the standard checkout locations).
## The trace is the in-repo ``src/db-backend/trace`` fixture; no recorder
## is involved.

import std/[json, os, strutils, unittest]

import isonim/viewmodel      # `dispose` for the two panel VMs
import isonim/core/signals   # `.val` on the VM/store signals

import ../../headless_session
import ../../store/[replay_data_store, types]
import ../../viewmodels/step_list_vm
import ../../viewmodels/low_level_code_vm
import ../../viewmodels/event_log_vm

# ---------------------------------------------------------------------------
# Fixture location
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "src" / "db-backend") and dirExists(dir / "src" / "frontend"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate codetracer repo root from " & currentSourcePath())

proc findReplayServer(): string =
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidates = [
    repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "release" / "replay-server",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  raise newException(IOError,
    "missing replay-server; set REPLAY_SERVER_BIN or build via " &
    "`cd src/db-backend && cargo build`")

proc tracePath(): string =
  let p = repoRoot() / "src" / "db-backend" / "trace"
  if not fileExists(p / "trace_metadata.json"):
    raise newException(IOError, "missing trace fixture at " & p)
  p

type
  Position = object
    ## A place in the recording, as the STORE reports it — i.e. what a
    ## pane would render, not what the wire happened to carry.
    file: string
    line: int
    ticks: uint64

proc positionOf(s: HeadlessDebugSession): Position =
  Position(file: s.getCurrentFile(), line: s.getCurrentLine(),
           ticks: s.getCurrentRRTicks())

proc traceRelativePath(reported: string): string =
  ## Convert the path the engine *reports* into the path the engine
  ## *accepts*.
  ##
  ## These differ, and the difference is load-bearing.  ``ct/complete-move``
  ## reports a workdir-relative path with a ``./`` prefix
  ## (``./test_code/rust_struct_test.rs``), but ``ct/source-line-jump``
  ## resolves through ``get_closest_step_id``, which matches the trace's
  ## raw path table — where the same file is
  ## ``test_code/rust_struct_test.rs``.  Handing the reported form
  ## straight back gets ``unknown location: ./test_code/...:18`` and no
  ## move at all.
  ##
  ## Production is unaffected, and that is worth stating precisely
  ## because it is the reason this helper is confined to the test:
  ## ``jumpToInstruction`` forwards ``LowLevelInstruction.highLevelPath``,
  ## which ``dap_handler.rs::load_asm_function`` fills from
  ## ``self.reader.path(step.path_id)`` — the raw path table, i.e.
  ## already the accepted form.  Only a caller that round-trips a
  ## *reported* location (which this test does, to stay
  ## self-calibrating) has to strip the prefix.
  ##
  ## RETIRE THIS once an engine carrying the `Handler::load_path_id` →
  ## `fuzzy_path_id_for` change ships: that makes the jump arms accept the
  ## reported spelling too, and this helper becomes a no-op that hides
  ## whether the engine under test actually has the fix. It is kept for now
  ## because it must keep passing against the engine that is deployed today.
  if reported.startsWith("./"): reported[2 .. ^1] else: reported

proc checkMoveWasEmitted(s: HeadlessDebugSession; what: string) =
  ## Assert the engine ALREADY emitted a ``ct/complete-move`` for the
  ## request we just sent, reading only the buffer — never the socket.
  ##
  ## Why this exists rather than going straight to
  ## ``consumeNextCompleteMove``: the native ``BackendService.send`` is a
  ## *blocking* ``sendDapRequest``, so by the time a jump call returns,
  ## a working command's ``stopped`` + ``ct/complete-move`` are already
  ## sitting in ``eventQueue``.  A command the engine refuses (an
  ## unmapped string, a payload that fails to deserialise) produces an
  ## error response and NO events — and ``consumeNextCompleteMove``
  ## would then block on a socket read that never returns, turning a
  ## failing assertion into a hung test.
  ##
  ## Checking the buffer first converts that into a named failure, which
  ## matters for the mutation arms: each of them must redden *its own*
  ## assertion with a readable reason, not time out.
  ##
  ## This RAISES rather than calling ``fail()``.  ``fail()`` sets the test
  ## status but does not unwind out of a proc, so the body would carry on
  ## into ``consumeNextCompleteMove`` and block anyway — a mutation arm
  ## that hangs instead of naming its failure. (Measured: the
  ## missing-``threadId`` arm did exactly that before this was a raise.)
  ##
  ## One case this still cannot rescue: a command the engine answers with
  ## NOTHING AT ALL — an unmapped string, or `ct/local-step-jump`, whose
  ## handler omits `respond_dap`. There the blocking send never returns
  ## and no assertion here is ever reached. That deadlock is not a gap in
  ## the test; it IS the defect that keeps this code off those commands.
  for ev in s.backend.eventQueue:
    if ev.getOrDefault("event").getStr("") == "ct/complete-move":
      return
  raise newException(ValueError,
    "no ct/complete-move was emitted for: " & what &
    " — the engine did not move the session")

proc findDistinctLaterPosition(s: HeadlessDebugSession;
                               start: Position;
                               maxSteps: int): Position =
  ## Step the real trace forward until the position differs from
  ## ``start`` in BOTH line and tick, and return it.
  ##
  ## Raises when no such position turns up.  That is deliberate: this
  ## value is the premise of every jump assertion below, and a premise
  ## that quietly collapsed to "jump to where we already are" would make
  ## the jump tests pass while measuring nothing.
  for _ in 0 ..< maxSteps:
    s.stepForward()
    let p = s.positionOf()
    if p.line != start.line and p.ticks != start.ticks:
      return p
  raise newException(ValueError,
    "trace fixture never reached a position with both a different line " &
    "and a different tick within " & $maxSteps & " steps; the jump " &
    "assertions would be vacuous, so failing instead")

# ---------------------------------------------------------------------------

suite "row-click jumps move the debugger (real replay-server)":

  test "Low Level Code row click lands the session on the row's source line":
    let session = newHeadlessDebugSession(tracePath(), findReplayServer())
    defer: session.close()

    let start = session.positionOf()
    check start.file.len > 0
    check start.line > 0

    # Discover a genuinely different position, and prove it is different
    # before using it as the thing we jump away from.
    let away = session.findDistinctLaterPosition(start, maxSteps = 20)
    check away.line != start.line
    check away.ticks != start.ticks
    check session.getCurrentLine() == away.line

    # The pane's own VM, built on the same store production builds it on
    # (`ui/low_level_code.nim::initLowLevelCodeVMWithStore`).
    let vm = createLowLevelCodeVM(session.session.store)
    defer: vm.dispose()

    # An asm row whose back-pointer names the line we started on.
    vm.jumpToInstruction(LowLevelInstruction(
      name: "mov",
      args: "",
      other: "",
      offset: 0,
      highLevelPath: traceRelativePath(start.file),
      highLevelLine: start.line,
    ))
    session.checkMoveWasEmitted("Low Level Code row click (ct/source-line-jump)")
    session.consumeNextCompleteMove()

    # THE EFFECT: the session moved to the line the row named.
    check session.getCurrentLine() == start.line
    check session.getCurrentFile() == start.file
    check session.getCurrentLine() != away.line
    # ...and the store — what the panes read — agrees.
    check session.session.store.debugger.val.location.line == start.line

    # A row that moved the session must not also be reporting a failure.
    check vm.errorMessage.val == ""

  test "Low Level Code row without a source back-pointer reports, and does not move":
    let session = newHeadlessDebugSession(tracePath(), findReplayServer())
    defer: session.close()

    let before = session.positionOf()
    let vm = createLowLevelCodeVM(session.session.store)
    defer: vm.dispose()

    vm.jumpToInstruction(LowLevelInstruction(
      name: "nop", args: "", other: "", offset: 4,
      highLevelPath: "",      # no debug info for this instruction
      highLevelLine: 0,
    ))

    # THE EFFECT: the pane says why nothing happened, and nothing happened.
    check vm.errorMessage.val.len > 0
    check session.getCurrentLine() == before.line
    check session.getCurrentRRTicks() == before.ticks

  test "Step List row click lands the session on the row's recorded tick":
    let session = newHeadlessDebugSession(tracePath(), findReplayServer())
    defer: session.close()

    let start = session.positionOf()
    let away = session.findDistinctLaterPosition(start, maxSteps = 20)
    check away.ticks != start.ticks
    check session.getCurrentRRTicks() == away.ticks

    let vm = createStepListVM(session.session.store)
    defer: vm.dispose()

    # A Step List row describing the position we started at.  The row's
    # `rrTicks` is what `jumpToStepLine` puts in `ticks`, and what
    # `dap_handler.rs::goto_ticks` replays to via `jump_to(StepId(..))`.
    vm.jumpToStepLine(StepLine(
      kind: slkLine,
      delta: -1,
      location: StepLineLocation(
        path: start.file,
        line: start.line,
        functionName: "",
        rrTicks: int(start.ticks),
      ),
      sourceLine: "",
      values: @[],
    ))
    session.checkMoveWasEmitted("Step List row click (ct/goto-ticks)")
    session.consumeNextCompleteMove()

    # THE EFFECT: the session is back at the row's tick and line.
    check session.getCurrentRRTicks() == start.ticks
    check session.getCurrentLine() == start.line
    check session.getCurrentRRTicks() != away.ticks
    check session.session.store.debugger.val.rrTicks == start.ticks

  test "Event Log boundary chip lands the session on the counterpart's tick":
    ## `EventLogVM.jumpToCounterpart` sent `{rrTicks, ticks}` and no
    ## `threadId`. `GoToTicksArguments` has no serde default, so the engine
    ## refused the request outright (`missing field threadId`) and the jump
    ## moved nothing.
    ##
    ## It had tests. They asserted `mock.findCommand("ct/goto-ticks").isSome`
    ## — true of a request the engine never accepts. This asserts the tick the
    ## session actually landed on.
    ##
    ## Single-recording on purpose: that is the case the old payload could
    ## never satisfy. With a sibling recording, `onSwitchProcessProc` rotates
    ## the session first and `dap.nim` stamps a routing `threadId` onto the
    ## request, which accidentally completed it — so a multi-recording fixture
    ## would have passed either way and measured nothing.
    let session = newHeadlessDebugSession(tracePath(), findReplayServer())
    defer: session.close()

    let start = session.positionOf()
    let away = session.findDistinctLaterPosition(start, maxSteps = 20)
    check away.ticks != start.ticks
    check session.getCurrentRRTicks() == away.ticks

    let vm = session.session.eventLogVM
    check not vm.isNil
    # No `recordingId`: nothing to rotate to, so nothing else can supply the
    # `threadId` this request needs.
    vm.jumpToCounterpart(MarkerEventRow(
      eventIndex: 0,
      markerId: 0,
      boundaryId: "b",
      keyText: "key",
      keyValue: "k",
      sourcePath: start.file,
      sourceLine: start.line,
      stepId: int64(start.ticks),
    ))
    session.checkMoveWasEmitted("Event Log boundary chip (ct/goto-ticks)")
    session.consumeNextCompleteMove()

    # THE EFFECT: the session is on the counterpart's tick.
    check session.getCurrentRRTicks() == start.ticks
    check session.getCurrentRRTicks() != away.ticks
    check session.session.store.debugger.val.rrTicks == start.ticks
