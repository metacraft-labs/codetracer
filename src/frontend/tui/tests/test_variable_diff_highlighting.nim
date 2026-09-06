## test_variable_diff_highlighting.nim — CTUI-7, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-7: "steps forward over an assignment and asserts exactly the assigned
## variable carries `[MOD]`; steps *backward* and asserts the value reverts and
## the badge clears. Also asserts that a step which changes nothing marks
## nothing — a diff engine that marks every row after every step passes a
## forward-only test."
##
## All three, on `calc`, against the engine's own answers:
##
##   * FORWARD. A walk through `evaluate` records every stop: its tick, its
##     line, the variables the engine reported, and the REAL PANE painted at
##     that stop. The step this suite asserts on is CHOSEN FROM THE DATA — the
##     one whose diff names exactly one variable AND whose preceding SOURCE
##     LINE, read off disk at the path the backend reported, is an assignment to
##     that same name. So "exactly the assigned variable" is checked against the
##     PROGRAM, not against the diff engine's own opinion of what it assigned.
##   * BACKWARD. The same walk is retraced with `stepBack`, recording the same
##     things. The pair the assertion uses is one the ENGINE really produced in
##     BOTH directions — matched against the recordings, not assumed.
##   * NOTHING. A step whose diff names nothing marks nothing, with
##     `anchorKnown` asserted TRUE beside it so "marks nothing" cannot be
##     satisfied by "has no idea".
##
## ## THE BACKWARD ARM'S NON-VACUITY, WHICH IS THE POINT OF THE WHOLE FILE
##
## "The badge cleared" is worth nothing on its own — a pane that never sets a
## badge passes it. So the suite asserts, at the same tick, that the two values
## the naive implementation would have compared ARE DIFFERENT. A symmetric diff
## against "the tick we came from" would therefore have marked the row, and this
## one does not. That pair of assertions is the difference between the two
## readings of CTUI-7's contract, and it is why a forward-only test cannot tell
## them apart. See `app/views/diff_highlighter.nim`'s header.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`, WHICH IS WHERE CTUI-7 NAMES IT
##
## The same reason CTUI-5 and CTUI-6 recorded, unchanged:
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on an import resolving to
## `headless_session`. This suite's subject is a real `HeadlessDebugSession`
## over a real `replay-server`. The `tui` lane globs `tests/test_*.nim` and
## `app/tests/test_*.nim` identically, so nothing about the coverage changes;
## the path does.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server`, read through `StateVM.currentVariables` — the memo the
## desktop renders.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[algorithm, json, os, sequtils, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]

import ../app/variables_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 54

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  TargetFunction = "evaluate"
    ## The one name written into this file, and for CTUI-6's reason: the program
    ## under test is ours and its shape is what is being asserted about. Its
    ## LINES are never written down — they come from the engine.
  MaxStepIns = 60
  WalkSteps = 11
    ## Stops recorded going forward.
    ##
    ## MEASURED, and the number is bounded from ABOVE by something real:
    ## `stepBack` is reverse-*next*, so a walk that leaves `evaluate` cannot be
    ## retraced — from `main`'s line after the call, one reverse step goes back
    ## OVER the whole call rather than into it. Measured on this fixture
    ## (2026-09-06): eleven stops from `evaluate`'s entry stay inside it and end
    ## on its `return`, and the twelfth is in `main`. The suite does not depend
    ## on that: it matches the forward and backward tick sequences and FAILS,
    ## naming both, if no pair was produced in both directions.
  PaneWidth = 52
  PaneHeight = 48
    ## Tall enough for the whole tree at this stop, which is asserted rather
    ## than assumed (`totalRows <= bodyHeight` below). A pane that had scrolled
    ## the changed row off screen would report zero badges and the assertion
    ## "exactly one row is badged" would fail for the wrong reason.

  ChecksReachTarget = 5
  ChecksWalkShape = 5
  ChecksFirstStop = 4
  ChecksChoice = 4
  ChecksForwardArm = 11
  ChecksBackwardArm = 11
  ChecksTickStability = 2
  ChecksUniversalAssignments = 2
  ChecksNoOpArm = 6
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

type
  Stop = object
    ## One recorded stop, with everything the assertions read.
    tick: uint64
    line: int
    file: string
    values: Table[string, string]
      ## What the ENGINE reported, keyed by name.
    modified: seq[string]
      ## What the diff marked, sorted.
    modifiedRows: int
      ## How many rows the PANE painted a badge on.
    anchorKnown: bool
    anchorTick: uint64
    totalRows: int
    bodyHeight: int
    rows: Table[string, string]
      ## The text of every painted row that stands for a path.

proc frameFunction(session: HeadlessDebugSession): string =
  ## The function DAP `stackTrace` names for frame 0.
  let response = session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 5,
  })
  discard session.drainEvents()
  let frames = response.getOrDefault("body").getOrDefault("stackFrames")
  if frames.isNil or frames.len == 0: ""
  else: frames[0].getOrDefault("name").getStr("")

proc assignedNameOn(path: string; line: int): string =
  ## The variable a SOURCE LINE assigns, read straight off disk.
  ##
  ## THE INDEPENDENT GROUND TRUTH for "exactly the assigned variable". The
  ## expectation this suite compares the diff against comes from the recorded
  ## program's own text at the path the BACKEND reported — not from the diff,
  ## and not from a list in this file.
  ##
  ## Deliberately conservative: it recognises `x = …` and the augmented forms at
  ## the start of a line, and answers "" for everything else, `==` included. A
  ## parser that guessed would put a name into the expectation that the program
  ## never assigned.
  if not fileExists(path):
    return ""
  let lines = readFile(path).splitLines()
  if line < 1 or line > lines.len:
    return ""
  let text = lines[line - 1]
  var i = 0
  while i < text.len and text[i] in {' ', '\t'}:
    inc i
  let nameStart = i
  while i < text.len and (text[i].isAlphaNumeric or text[i] == '_'):
    inc i
  if i == nameStart:
    return ""
  let name = text[nameStart ..< i]
  var j = i
  while j < text.len and text[j] == ' ':
    inc j
  if j >= text.len:
    return ""
  if text[j] == '=':
    return if j + 1 < text.len and text[j + 1] == '=': "" else: name
  if text[j] in {'+', '-', '*', '/', '%'} and j + 1 < text.len and
     text[j + 1] == '=':
    return name
  ""

proc localPath(name: string): string =
  ## The pane's path for a top-level local.
  scopePath(skLocals) & "." & name

proc recordStop(session: HeadlessDebugSession;
                timeline: var ValueTimeline): Stop =
  ## Take one stop: load the locals, feed the timeline, build the REAL pane
  ## through the production binding, and read back what it says.
  session.requestAndLoadLocals()
  let vars = session.getLocals()
  let tick = session.getCurrentRRTicks()
  timeline.observeStop(tick, vars)
  let model = variablesModelFor(session.session.stateVM, timeline, tick)
  let screen = variablesScreen(model, PaneWidth, PaneHeight)
  result = Stop(
    tick: tick,
    line: session.getCurrentLine(),
    file: session.getCurrentFile(),
    values: snapshotOf(vars),
    modified: model.diff.modifiedPaths(),
    modifiedRows: screen.modifiedRows,
    anchorKnown: model.diff.anchorKnown,
    anchorTick: model.diff.anchorTick,
    totalRows: screen.totalRows,
    bodyHeight: screen.bodyHeight,
    rows: initTable[string, string]())
  for i, row in screen.visible:
    if row.kind in {vrkScope, vrkVariable}:
      result.rows[row.node.path] = rowText(screen.rows[1 + i])

proc rowFor(stop: Stop; name: string): string =
  if stop.rows.hasKey(localPath(name)): stop.rows[localPath(name)] else: ""

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkExactlyOneBadge(stop: Stop; name: string) =
  ## The PANE marks `name` and nothing else.
  ##
  ## Deliberately NOT `stop.modified == @[name]`: the step was CHOSEN for
  ## satisfying that, so re-asserting it here would be an expectation the
  ## selection produced — the self-comparison shape CTUI-6 found in its own
  ## group-count assertion. What is asserted is what the selection does not
  ## imply: how many rows the PANE painted a badge on, and what the row for
  ## `name` says. The selection's own condition is a live assertion in its own
  ## right — `chosen >= 2` fails when no step in the walk has a one-variable
  ## diff that agrees with the source text, which is exactly what a diff engine
  ## that marked everything, or nothing, would produce.
  checkpoint("tick " & $stop.tick & " marked " & $stop.modified &
             ", pane badges " & $stop.modifiedRows & ", row '" &
             stop.rowFor(name) & "'")
  ck stop.modifiedRows == 1
  ck stop.rowFor(name).contains(ModifiedTag)
  ck stop.rowFor(name).contains(name)

template checkNoBadgeFor(stop: Stop; name: string) =
  ## The pane does NOT mark `name`, and the row is on screen — so the absence is
  ## an answer rather than an absent row.
  checkpoint("tick " & $stop.tick & " marked " & $stop.modified &
             ", pane badges " & $stop.modifiedRows & ", row '" &
             stop.rowFor(name) & "'")
  ck name notin stop.modified
  ck stop.rowFor(name).len > 0
  ck not stop.rowFor(name).contains(ModifiedTag)
  ck stop.rowFor(name).contains(name)

# ---------------------------------------------------------------------------

suite "CTUI-7: the diff marks what the step changed, in both directions":

  test "calc: forward marks the assigned variable, backward clears it, and a " &
       "step that changes nothing marks nothing":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      # ---- reach the function whose body is a chain of assignments ---------
      var stepIns = 0
      while stepIns < MaxStepIns and session.frameFunction() != TargetFunction:
        session.stepIn()
        discard session.drainEvents()
        inc stepIns
      echo "CTUI-7 DIFF: reached " & session.frameFunction() & " after " &
           $stepIns & " stepIn(s) at " & session.getCurrentFile() & ":" &
           $session.getCurrentLine()
      ck stepIns < MaxStepIns
      ck session.frameFunction() == TargetFunction
      ck session.getCurrentFile().len > 0
      ck fileExists(session.getCurrentFile())
      ck session.getDebuggerStatus() == dsIdle

      # ---- PASS 1: walk FORWARD, recording every stop ----------------------
      var timeline = initValueTimeline()
      var forward: seq[Stop] = @[]
      for i in 0 ..< WalkSteps:
        # The step comes BEFORE the record, except on the first pass, so the
        # walk ENDS on a recorded stop. A trailing step would leave the session
        # one stop past the walk, and the backward pass would then open with a
        # reverse step over a transition the forward pass never saw.
        if i > 0:
          session.stepForward()
          discard session.drainEvents()
        forward.add recordStop(session, timeline)

      let ticks = forward.mapIt(it.tick)
      ck forward.len == WalkSteps
      ck ticks.len == deduplicate(ticks).len
      ck timeline.len == WalkSteps
      ck timeline.observedTicks() == sorted(ticks)
      var ascending = true
      for i in 1 ..< ticks.len:
        if ticks[i] <= ticks[i - 1]:
          ascending = false
      ck ascending

      # THE FIRST STOP HAS NO PREDECESSOR, so it marks nothing — and says so
      # rather than marking everything, which is the naive answer.
      checkpoint("first stop: anchorKnown " & $forward[0].anchorKnown &
                 ", marked " & $forward[0].modified & ", " &
                 $forward[0].values.len & " variable(s)")
      ck not forward[0].anchorKnown
      ck forward[0].modified.len == 0
      ck forward[0].modifiedRows == 0
      # …and the SECOND stop does have one, so "no anchor" is a property of the
      # first stop rather than of this timeline.
      ck forward[1].anchorKnown

      # ---- PASS 2: retrace BACKWARD, recording every stop ------------------
      var backward: seq[Stop] = @[]
      for _ in 0 ..< WalkSteps - 1:
        session.stepBackward()
        discard session.drainEvents()
        backward.add recordStop(session, timeline)
      let backTicks = backward.mapIt(it.tick)
      echo "CTUI-7 DIFF: forward ticks " & $ticks & "\n" &
           "CTUI-7 DIFF: backward ticks " & $backTicks

      # ---- CHOOSE THE STEP TO ASSERT ON, FROM THE DATA ---------------------
      # Every condition is a fact this suite derived rather than arranged: the
      # diff names exactly one variable; the SOURCE LINE that ran to produce
      # that stop assigns that same name; and the ENGINE really produced the
      # pair in BOTH directions, so the backward arm below is a real reverse
      # step over the same statement.
      var chosen = -1
      var assigned = ""
      var backIndex = -1
      for k in countdown(forward.high, 2):
        if forward[k].modified.len != 1:
          continue
        let name = assignedNameOn(forward[k - 1].file, forward[k - 1].line)
        if name.len == 0 or name != forward[k].modified[0]:
          continue
        var found = -1
        for b in 1 ..< backward.len:
          if backward[b - 1].tick == forward[k].tick and
             backward[b].tick == forward[k - 1].tick:
            found = b
            break
        if found < 0:
          continue
        chosen = k
        assigned = name
        backIndex = found
        break
      echo "CTUI-7 DIFF: chose forward step " & $chosen & " — line " &
           (if chosen > 0: $forward[chosen - 1].line else: "-") &
           " assigns '" & assigned & "', ticks " &
           (if chosen > 0: $forward[chosen - 1].tick & " -> " &
                           $forward[chosen].tick else: "-") &
           ", reversed at backward step " & $backIndex
      ck chosen >= 2
      ck assigned.len > 0
      ck backIndex >= 1
      ck forward[chosen].anchorTick == forward[chosen - 1].tick

      let before = forward[chosen - 1]
      let after = forward[chosen]
      let reverted = backward[backIndex]

      # ---- THE FORWARD ARM -------------------------------------------------
      checkExactlyOneBadge(after, assigned)
      # The value really did change, read from the ENGINE's own answers at the
      # two stops rather than from the diff.
      ck before.values.hasKey(assigned)
      ck after.values.hasKey(assigned)
      ck before.values[assigned] != after.values[assigned]
      # …and the row shows the NEW value, so the badge is on a row a reader can
      # act on rather than on one whose text is stale.
      ck after.rowFor(assigned).contains(after.values[assigned])
      # …and the whole tree was on screen, so "exactly one row is badged" is a
      # statement about the pane rather than about what fitted in it.
      ck after.totalRows <= after.bodyHeight
      # Every OTHER variable at this stop is unmarked. Counted, rather than
      # asserted as "at least one is unmarked".
      var unmarked = 0
      for name in after.values.keys:
        if name != assigned:
          inc unmarked
      checkpoint("variables at the assignment: " & $after.values.len &
                 ", unmarked " & $unmarked)
      ck unmarked == after.values.len - 1
      ck unmarked >= 1
      # …and the pane really painted them: the badge count is one out of many
      # rows rather than one out of one.
      ck after.rows.len > 2

      # ---- THE BACKWARD ARM ------------------------------------------------
      ck reverted.tick == before.tick
      # THE VALUE REVERTED, read from the engine at the stop the reverse step
      # actually reached.
      ck reverted.values.hasKey(assigned)
      ck reverted.values[assigned] == before.values[assigned]
      ck reverted.values[assigned] != after.values[assigned]
      # THE BADGE CLEARED.
      checkNoBadgeFor(reverted, assigned)
      # …and it is not vacuous: the anchor is known, so the pane HAD an opinion,
      # and the opinion was "nothing here changed this variable".
      ck reverted.anchorKnown
      ck reverted.anchorTick == forward[chosen - 2].tick
      # THE NON-VACUITY TWIN, and the reason a forward-only test cannot tell the
      # two readings of the contract apart: a diff against "the tick we came
      # from" would compare these two values, which DIFFER, and would mark the
      # row. See app/views/diff_highlighter.nim's header.
      ck after.values[assigned] != reverted.values[assigned]

      # ---- A TICK'S BADGES ARE A PROPERTY OF THAT TICK ---------------------
      # The same tick, reached going forward and going backward, says the same
      # thing. A pane that diffed against the previously-DISPLAYED values could
      # not have this property. Counted over the whole overlap and asserted
      # once, so a single disagreeing tick reddens the file.
      var revisited = 0
      var disagreements: seq[string] = @[]
      for b in backward:
        for f in forward:
          if b.tick == f.tick:
            inc revisited
            if b.modified != f.modified:
              disagreements.add $b.tick & ": " & $f.modified & " vs " &
                $b.modified
      checkpoint("ticks revisited in both directions: " & $revisited &
                 ", disagreements " & $disagreements)
      ck revisited >= 2
      ck disagreements.len == 0

      # ---- EVERY ASSIGNMENT IN THE WALK IS MARKED --------------------------
      # The arm above is EXISTENTIAL — it finds one step and reads the pane at
      # it. This one is UNIVERSAL, over the same walk: for every stop whose
      # preceding source line assigns a name the engine reports at that stop,
      # that name must be in the change set. A diff that missed a kind of
      # change — a string, say, whose two values both rendered as `[]` — passes
      # the existential arm on some other step and fails here.
      var assignments = 0
      var markedAssignments = 0
      var missed: seq[string] = @[]
      for k in 1 ..< forward.len:
        let name = assignedNameOn(forward[k - 1].file, forward[k - 1].line)
        if name.len == 0 or not forward[k].values.hasKey(name):
          continue
        inc assignments
        if name in forward[k].modified:
          inc markedAssignments
        else:
          missed.add "tick " & $forward[k].tick & " line " &
            $forward[k - 1].line & " assigns " & name & ", marked " &
            $forward[k].modified
      if missed.len > 0:
        checkpoint(missed.join("\n"))
      echo "CTUI-7 DIFF: " & $assignments & " assignment step(s) in the walk, " &
           $markedAssignments & " marked"
      ck assignments >= 3
      ck markedAssignments == assignments

      # ---- A STEP THAT CHANGES NOTHING MARKS NOTHING -----------------------
      # Chosen from the data: a stop whose diff names nothing but HAS an anchor,
      # so "marks nothing" is an answer rather than the absence of one.
      var quiet = -1
      for i in 1 ..< forward.len:
        if forward[i].anchorKnown and forward[i].modified.len == 0:
          quiet = i
          break
      echo "CTUI-7 DIFF: no-op step " & $quiet & " at line " &
           (if quiet > 0: $forward[quiet].line else: "-") & ", anchor tick " &
           (if quiet > 0: $forward[quiet].anchorTick else: "-") & ", " &
           (if quiet > 0: $forward[quiet].values.len else: "-") & " variable(s)"
      ck quiet >= 1
      ck forward[quiet].anchorKnown
      ck forward[quiet].modified.len == 0
      ck forward[quiet].modifiedRows == 0
      # …and the stop really had variables to be wrong about, so "nothing
      # marked" is not "nothing there".
      ck forward[quiet].values.len > 0
      ck forward[quiet].anchorTick == forward[quiet - 1].tick

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksReachTarget + ChecksWalkShape + ChecksFirstStop +
        ChecksChoice + ChecksForwardArm + ChecksBackwardArm +
        ChecksTickStability + ChecksUniversalAssignments + ChecksNoOpArm) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
