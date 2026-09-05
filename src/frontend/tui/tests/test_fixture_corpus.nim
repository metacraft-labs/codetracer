## test_fixture_corpus.nim — CTUI-1.
##
## ## What this suite is for
##
## `fixtures/fixture_provider.nim` can resolve a fixture name to a directory.
## That is not the same claim as "the fixture is a usable trace", and the
## difference is the whole reason this file exists: a directory holding a
## truncated container, a recording of a program that crashed on line 1, or a
## trace whose recorder produced no step records would all *resolve*. So every
## declared fixture is opened here through a **real** `HeadlessDebugSession`
## against a **real** `replay-server`, and asserted to be NAVIGABLE:
##
##   * a non-empty entry file,
##   * a non-zero tick bound,
##   * at least one calltrace frame, with a name on it,
##   * and a single `stepForward` that changes the reported position.
##
## CTUI-1 states the last one as a definition rather than as a test: *a fixture
## that cannot be stepped is not a fixture.*
##
## ## Everything asserted here comes from the backend
##
## No line number, tick value or frame count is written into this file as an
## expectation. A fixture is re-recorded whenever its program changes and
## whenever the recorder changes, and a suite pinned to `main.py:42` would go
## red on a compiler upgrade while telling the reader nothing about the trace.
## So the assertions are all *relational*: the position after a step differs
## from the position before it; the tick at the end of the recording exceeds
## the tick at its start; the widest structure the value layer reports has more
## members than CTUI-1's floor. The one place a name is written down is the
## Python function `descend`, because the program under test is ours and its
## call graph is the thing being asserted about.
##
## ## The three outcomes, and why an all-skipped run FAILS
##
## Per `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`, a test
## that detects a missing prerequisite and is counted as PASSED is a lie. This
## suite reports exactly the three outcomes CTUI-1's verification gate names:
##
##   * **verified** — the fixture opened and every assertion above held;
##   * **`MISSING-PREREQ SKIP: <fixture> (<recorder>)`** — a named, counted,
##     greppable skip, recorded as `[SKIPPED]` by `std/unittest` so the lane
##     runner reports it as a skip and not as a pass;
##   * **failed**.
##
## And the last case in the file is the guard that makes those honest: it
## asserts that every declared fixture was *examined* (the count control from
## Verification-Harness-Traps §4b — this loop's membership is knowable, so the
## control is the COUNT and not "at least one"), that at least one was
## verified, and that the runtime assertion tally equals the number derived
## from how many fixtures resolved (§4c). A case that returned early, a loop
## that skipped a member, or a resolution branch that asserted nothing all
## redden the file on the spot instead of being noticed by someone differencing
## two runs.
##
## `replay-server` is NOT part of that skip machinery. It is located exactly as
## `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim` locates it —
## `REPLAY_SERVER_BIN`, then `src/build-debug/bin/replay-server`, then a
## diagnostic failure naming the build command — because a run without it has
## not tested a corpus, it has tested nothing.
##
## ## No mocks
##
## Metacraft policy and CTUI-1's "Real-stack integration tests (no mocks)":
## real containers from real recorders, driven by a real `replay-server` over
## DAP. `MockBackendService` is permitted in exactly one file in this campaign
## (CTUI-0's stack-compiles test) and this is not it.

import std/[json, os, strutils, unittest]

import headless_session
import store/types

import fixtures/fixture_provider

# ---------------------------------------------------------------------------
# Counted assertions (Verification-Harness-Traps §4c)
# ---------------------------------------------------------------------------

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted. The tally is compared at the end against a number
  ## derived from the run's own shape, so a branch that asserted nothing
  ## cannot leave the suite green.
  inc countedAssertions
  check condition

# How many counted assertions each arm contributes. Written here, once, so the
# expectation in the final case is derived rather than hand-totalled.
const
  ChecksPerNavigableFixture = 8
  ChecksPerSkippedFixture = 2
  ChecksThreadCase = 1
  ChecksWideCaseResolved = 2
  ChecksWideCaseSkipped = 1
  ChecksSummaryCase = 5

# Run-shape counters the final case derives its expectation from. They are
# incremented by the per-fixture loop below, which is also what makes
# "every declared fixture was examined" checkable.
var verifiedFixtures = 0
var skippedFixtures = 0
var examinedFixtures = 0
var wideStateResolved = false

proc announceSkip(res: FixtureResolution): string =
  ## Emit the one greppable line and return it, so the caller can assert on the
  ## text it actually printed rather than on a second copy of it.
  result = missingPrereqMessage(res.spec, res.detail)
  echo "  ", result

proc positionOf(session: HeadlessDebugSession): (string, int, uint64) =
  ## The debugger position as the BACKEND reports it: file, line, tick.
  ## Compared as a triple because any one of the three may legitimately repeat
  ## across a step — a loop body re-enters the same line, and a step within one
  ## line can leave the line alone — while all three repeating means nothing
  ## moved.
  (session.getCurrentFile(), session.getCurrentLine(),
   session.getCurrentRRTicks())

# ---------------------------------------------------------------------------
# Suite 1 — every declared fixture is navigable
# ---------------------------------------------------------------------------

suite "CTUI-1: the fixture corpus is navigable":

  for spec in DeclaredFixtures:
    # Closed over per iteration: `spec` is a `for` variable and each `test`
    # body runs immediately, so this is a loop of cases rather than a case with
    # a loop in it. That matters for the report — one `[OK]`/`[SKIPPED]` line
    # per fixture, named — and for the guard, which counts examinations.
    test "fixture " & spec.name & " opens and steps through a real session":
      inc examinedFixtures
      let resolution = resolveFixture(spec)

      if resolution.outcome == foMissingPrereq:
        inc skippedFixtures
        let message = announceSkip(resolution)
        # A skip still asserts. Both halves matter: that a REASON was given
        # (an empty `detail` would render a line naming nothing actionable),
        # and that the line carries the greppable prefix and the fixture's
        # name, which is what makes a skipped fixture findable in a CI log and
        # what CTUI-6 inherits by name rather than by silence.
        ck resolution.detail.len > 0
        ck message.startsWith(MissingPrereqSkipPrefix) and spec.name in message
        skip()
      else:
        inc verifiedFixtures
        if spec.name == "wide_state":
          wideStateResolved = true
        checkpoint("trace: " & resolution.tracePath)
        ck resolution.tracePath.len > 0
        ck dirExists(resolution.tracePath)

        let session = newHeadlessDebugSession(
          resolution.tracePath, findReplayServer())
        defer: session.close()

        # The backend answered the launch handshake and parked at a position.
        # Asserted before anything is read off that position, because a
        # `dsError` session answers every getter with a default that satisfies
        # nothing and explains nothing.
        ck session.getDebuggerStatus() == dsIdle

        let entryFile = session.getCurrentFile()
        checkpoint("entry file: " & entryFile & ":" & $session.getCurrentLine())
        ck entryFile.len > 0

        # At least one calltrace frame, and at least one of them NAMED. The
        # second half is the positive control on the first: a response whose
        # rows all carry empty names satisfies `len > 0` while telling a
        # calltrace pane nothing, and that is the shape a recorder that lost
        # its symbol table produces.
        session.requestAndLoadCalltrace(depth = 30, height = 80)
        let frames = session.getCalltraceLines()
        checkpoint("calltrace frames: " & $frames.len)
        ck frames.len >= 1
        var named = 0
        for frame in frames:
          if frame.name.len > 0:
            inc named
        checkpoint("named calltrace frames: " & $named)
        ck named >= 1

        # A single step changes the reported position.
        let before = positionOf(session)
        session.stepForward()
        let after = positionOf(session)
        checkpoint("step: " & $before & " -> " & $after)
        ck after != before

        # A non-zero tick bound. Read by running the recording OUT — with no
        # breakpoints set, `continue` stops at the end — and asking where the
        # backend says that is. Relational rather than absolute: the end of the
        # recording is strictly later than its start, which is false for an
        # empty trace and true for every real one, without this file knowing
        # what the number should be.
        session.continueForward()
        let bound = session.getCurrentRRTicks()
        checkpoint("tick bound: " & $bound & " (start " & $before[2] & ")")
        ck bound > 0'u64 and bound > before[2]

# ---------------------------------------------------------------------------
# Suite 2 — the two fixture-specific properties CTUI-1 names
# ---------------------------------------------------------------------------

suite "CTUI-1: fixture-specific properties":

  test "threads: the backend reports more than one recorded thread":
    ## CTUI-1: "The `threads` fixture additionally asserts more than one
    ## recorded thread is reported; if the fixture is absent this is the skip
    ## that CTUI-6 inherits, propagated BY NAME rather than by silence."
    ##
    ## Both arms assert. The skip arm is not a formality: it pins that the
    ## refusal is attributed — a future change that made the fixture resolve to
    ## a single-threaded trace would land in the other arm and go red on the
    ## thread count, and a change that dropped the attribution goes red here.
    let resolution = resolveFixture("threads")
    if resolution.outcome == foMissingPrereq:
      let message = announceSkip(resolution)
      ck message.startsWith(MissingPrereqSkipPrefix) and "threads" in message
      skip()
    else:
      let session = newHeadlessDebugSession(
        resolution.tracePath, findReplayServer())
      defer: session.close()
      let response = session.sendRawDapRequest("threads", %*{})
      let body = response.getOrDefault("body")
      var reported = 0
      if not body.isNil:
        let threads = body.getOrDefault("threads")
        if not threads.isNil and threads.kind == JArray:
          reported = threads.len
      checkpoint("DAP threads: " & $reported & " -> " & $body)
      ck reported > 1

  test "wide_state: a >500-member structure and a >50-frame recursion":
    ## The two numbers CTUI-1 gives this fixture, asserted against what the
    ## backend reports rather than against the program's constants — a fixture
    ## whose recorder stopped materialising 600 dict entries, or whose replay
    ## layer capped the stack, is exactly the regression CTUI-6 and CTUI-7's
    ## performance gates would otherwise discover as a mysterious pass.
    let resolution = resolveFixture("wide_state")
    if resolution.outcome == foMissingPrereq:
      let message = announceSkip(resolution)
      ck message.startsWith(MissingPrereqSkipPrefix) and "wide_state" in message
      skip()
    else:
      let replayServer = findReplayServer()

      # (a) The wide structure. Run the recording out and read the widest
      # thing the value layer reports at the last recorded step.
      block wideStructure:
        let session = newHeadlessDebugSession(resolution.tracePath, replayServer)
        defer: session.close()
        session.continueForward()
        session.requestAndLoadLocals()
        var widest = 0
        var widestName = ""
        for local in session.getLocals():
          if local.children.len > widest:
            widest = local.children.len
            widestName = local.name
        checkpoint("widest local: " & widestName & " with " & $widest &
                   " member(s), of " & $session.getLocals().len & " local(s)")
        ck widest > 500

      # (b) The deep recursion. The breakpoint's LINE comes from the calltrace
      # the backend returned for the recursive function, not from this file, so
      # editing the program cannot silently disarm the check. Then continue
      # until the reported stack is deeper than CTUI-1's floor: each stop is
      # one level further in, so the loop is bounded by the recursion's own
      # depth and the bound is generous.
      block deepRecursion:
        let session = newHeadlessDebugSession(resolution.tracePath, replayServer)
        defer: session.close()
        session.requestAndLoadCalltrace(depth = 200, height = 400)

        var recursiveFile = ""
        var recursiveLine = 0
        for frame in session.getCalltraceLines():
          if frame.name == "descend":
            recursiveFile = frame.location.file
            recursiveLine = frame.location.line
            break
        checkpoint("recursive frame reported at " & recursiveFile & ":" &
                   $recursiveLine)
        # No `ck` here: this is a precondition of the measurement, not the
        # measurement. If the backend reports no `descend` frame at all the
        # loop below never runs and the assertion after it fails with a depth
        # of zero — which is the honest report, and is what a `ck` on the
        # precondition would have masked by supplying a second, softer failure.
        var deepest = 0
        var stops = 0
        if recursiveFile.len > 0 and recursiveLine > 0:
          session.setBreakpoint(recursiveFile, recursiveLine)
          # TERMINATION, and it is not the iteration bound. `continue` at the
          # end of a recording returns immediately at the SAME position rather
          # than blocking — measured on this corpus: four successive
          # `continue`s on `calc` all answer `line=113 ticks=171` in 16-18 ms.
          # So "the tick did not advance" is a real, promptly-reachable end
          # state, and using it means a program that lost its recursion makes
          # this case FAIL with the depth it actually saw instead of hanging.
          # Verification-Harness-Traps §1 is about the opposite mistake: a
          # harness whose only exit is a timeout cannot tell "slow" from
          # "hung", and neither can its reader.
          var previousTick = session.getCurrentRRTicks()
          for _ in 0 ..< 200:
            session.continueForward()
            let tick = session.getCurrentRRTicks()
            if tick <= previousTick:
              break
            previousTick = tick
            inc stops
            let response = session.sendRawDapRequest("stackTrace", %*{
              "threadId": 1, "startFrame": 0, "levels": 400,
            })
            let body = response.getOrDefault("body")
            if body.isNil:
              break
            let frames = body.getOrDefault("stackFrames")
            let depth =
              if frames.isNil or frames.kind != JArray: 0
              else: frames.len
            if depth > deepest:
              deepest = depth
            # DRAIN THE EVENT BUFFER, and it is not housekeeping. Every
            # `continue` makes replay-server push events the session buffers
            # until somebody asks for them, and on this fixture each stop's
            # events carry the 600-member `wide_mapping`. Measured over this
            # loop with the drain removed: RSS climbs ~39 MB per stop, 126 MB
            # -> 2.85 GB over 67 stops, linear and never released; with it,
            # the same loop stays flat at ~164 MB. Nothing here reads the
            # events — `continueForward` synchronises on its own — so the only
            # thing the buffer does for this suite is grow.
            discard session.drainEvents()
            if deepest > 50:
              break
        checkpoint("deepest stack the backend reported: " & $deepest &
                   " frame(s), over " & $stops & " stop(s) at " &
                   recursiveFile & ":" & $recursiveLine)
        ck deepest > 50

# ---------------------------------------------------------------------------
# Suite 3 — the guard that makes the two suites above honest
# ---------------------------------------------------------------------------

suite "CTUI-1: corpus completeness":

  test "every declared fixture was examined and at least one was verified":
    ## THE ALL-SKIPPED GUARD. CTUI-1: "The lane fails if EVERY case skipped. A
    ## zero-assertion pass is the failure mode the silent self-pass audit
    ## catalogues, and this guard is what keeps a recorder-less environment
    ## from masquerading as green."
    checkpoint("examined=" & $examinedFixtures &
               " verified=" & $verifiedFixtures &
               " skipped=" & $skippedFixtures &
               " declared=" & $DeclaredFixtures.len)

    # The corpus CTUI-1 names, by name. A fixture silently dropped from
    # `DeclaredFixtures` would otherwise leave every count below consistent and
    # smaller, which is the partial-set shape Verification-Harness-Traps §4b is
    # about: nothing is wrong with what was examined, there is simply less of
    # it, and no assertion notices.
    var declaredNames: seq[string]
    for spec in DeclaredFixtures:
      declaredNames.add(spec.name)
    checkpoint("declared: " & declaredNames.join(", "))
    ck declaredNames == @["noir_space_ship", "calc", "threads", "wide_state"]

    # The count control. `examinedFixtures` is incremented once per case in the
    # loop, so this fails if a case was never generated, or was generated and
    # returned before its first statement.
    ck examinedFixtures == DeclaredFixtures.len
    ck verifiedFixtures + skippedFixtures == DeclaredFixtures.len

    # The guard itself.
    ck verifiedFixtures >= 1

    # And the assertion tally, derived from the run's shape rather than
    # hand-totalled, so an arm that stopped asserting is caught here even when
    # its own case still reports [OK].
    let expected =
      ChecksPerNavigableFixture * verifiedFixtures +
      ChecksPerSkippedFixture * skippedFixtures +
      ChecksThreadCase +
      (if wideStateResolved: ChecksWideCaseResolved else: ChecksWideCaseSkipped) +
      ChecksSummaryCase
    # `ck` increments BEFORE it evaluates, so `countedAssertions` already
    # includes this assertion — and `ChecksSummaryCase` is 5, which counts it.
    ck countedAssertions == expected

    # Read by ci/lib/run-nim-test-lane.sh. A RUNTIME count, so it reports what
    # the run actually asserted rather than what the source claims — the whole
    # point of the `CHECKS:` convention (see the runner's header, and
    # Verification-Harness-Traps §7).
    echo "CHECKS: ", countedAssertions
