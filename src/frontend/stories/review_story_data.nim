## The review the Deep Review stories show: an agent's change to the story
## program (test-programs/noir_space_ship), as a DeepReview dataset file.
##
## The change under review clamps a hit's damage to the shield that is left
## (`calculate_damage` in `src/shield.nr`), so a hit can no longer take the
## shield below zero. The file's text is the program's own `src/shield.nr`,
## which is the reviewed (new) revision; the one hunk is the change: the bare
## `damage` the function used to return became the clamp and `damage as Field`.
##
## The recorded values are not typed in. They are what the program computes:
## `simulateField` runs the same arithmetic as `iterate_asteroids` (the
## Prover.toml inputs, Noir's integer division where the program casts to
## `u32`), so every value a story shows beside a line is the value that run
## records there, and the values agree with the other stories, which are
## stopped at `src/shield.nr:7` in pass 2 of the positive field
## (`mass = 200`, `damage = 2000`, `remaining_shield = 9000` before the hit).
##
## The record shapes are DeepReview's (`common_types/codetracer_features/
## deepreview.nim`), with `functionKey` naming the function and one flow per
## invocation, as a review export carries them.

import std/[strutils, tables]

import ../../common/types as ct
import ../viewmodel/viewmodels/[diff_document, review_flow_overlay]

const
  ShieldPath* = "src/shield.nr"
  ShieldSource = staticRead("../../../test-programs/noir_space_ship/src/shield.nr")
  InitialShield = 10000
  ShieldRegenPercentage = 10
  PositiveMasses = [100, 2000, 200, 100, 100, 50, 50, 14]
  NegativeMasses = [2000, 300, 200, 20, 15, 20, 1, 1]
  StoryCalculateDamageCall* = 2
    ## The `calculate_damage` call the stories are stopped just after: pass 2
    ## of the positive field (`iterate_asteroids` line 6, then line 7).
  StoryIterateAsteroidsPass* = 2
    ## The pass of `iterate_asteroids`' loop the stories are stopped in.

type
  DamageCall = object
    ## One `calculate_damage(initial_shield, remaining_shield, mass)` call.
    remaining, mass, shieldPct, unclamped, damage: int
  Pass = object
    ## One pass of `iterate_asteroids`' loop.
    i, mass, before, afterHit, regeneration, after: int
    call: DamageCall

func damageFor(remaining, mass: int): DamageCall =
  ## `calculate_damage` and `calculate_remaining_shield_pct`, as the program
  ## computes them (`(remaining_shield * 100) as u32 / initial_shield as u32`).
  let pct = (remaining * 100) div InitialShield
  let unclamped = if pct == 100: mass else: mass * (100 - pct)
  DamageCall(remaining: remaining, mass: mass, shieldPct: pct,
             unclamped: unclamped, damage: min(unclamped, remaining))

func simulateField(masses: openArray[int]): seq[Pass] =
  ## `iterate_asteroids` over one asteroid field.
  var remaining = InitialShield
  for i, mass in masses:
    let call = damageFor(remaining, mass)
    let before = remaining
    remaining -= call.damage
    let afterHit = remaining
    var regeneration = 0
    if remaining > 0:
      # `calculate_shield_regeneration`: a percentage of the capacity, up to
      # the capacity.
      regeneration = InitialShield * ShieldRegenPercentage div 100
      if remaining + regeneration > InitialShield:
        regeneration = InitialShield - remaining
      remaining += regeneration
    result.add(Pass(i: i, mass: mass, before: before, afterHit: afterHit,
                    regeneration: regeneration, after: remaining, call: call))

func value(name: string; v: int): ct.DeepReviewVariableValue =
  ct.DeepReviewVariableValue(name: name, value: $v, kind: "int")

type StepWriter = object
  steps: seq[ct.DeepReviewFlowStep]
  rrTicks: int

proc add(w: var StepWriter; line: int; values: seq[ct.DeepReviewVariableValue];
         loopId = -1; iteration = 0) =
  w.rrTicks += 10
  w.steps.add(ct.DeepReviewFlowStep(line: line, stepCount: w.steps.len,
                                    rrTicks: w.rrTicks, loopId: loopId,
                                    iteration: iteration, values: values))

func lineOf(text: string): int =
  ## The 1-based line of `src/shield.nr` that starts with `text` (after its
  ## indentation): the flow is anchored to the program's real lines, so an
  ## edit to the program moves the anchors with it rather than leaving them
  ## on the wrong statement.
  let lines = ShieldSource.splitLines
  for i, line in lines:
    if line.strip.startsWith(text):
      return i + 1
  raiseAssert "src/shield.nr has no line starting with " & text

proc calculateDamageFlow(call: DamageCall; executionIndex, rrBase: int):
    ct.DeepReviewFunctionFlow =
  var w = StepWriter(rrTicks: rrBase)
  w.add(lineOf("let shield_pct"), @[value("shield_pct", call.shieldPct)])
  w.add(lineOf("let mut damage = 0"), @[value("damage", 0)])
  w.add(lineOf("if(shield_pct == 100)"), @[value("shield_pct", call.shieldPct)])
  if call.shieldPct == 100:
    w.add(lineOf("damage = mass * 1"),
          @[value("mass", call.mass), value("damage", call.unclamped)])
  else:
    w.add(lineOf("damage = mass * (100 - shield_pct)"),
          @[value("mass", call.mass), value("shield_pct", call.shieldPct),
            value("damage", call.unclamped)])
  w.add(lineOf("if(damage as u32 > remaining_shield as u32)"),
        @[value("damage", call.unclamped), value("remaining_shield", call.remaining)])
  if call.unclamped > call.remaining:
    w.add(lineOf("damage = remaining_shield;"), @[value("damage", call.damage)])
  w.add(lineOf("damage as Field"), @[value("damage", call.damage)])
  ct.DeepReviewFunctionFlow(functionKey: "calculate_damage",
                            executionIndex: executionIndex, steps: w.steps)

proc iterateAsteroidsFlow(passes: seq[Pass]; executionIndex, rrBase: int):
    ct.DeepReviewFunctionFlow =
  const Loop = 1
  var w = StepWriter(rrTicks: rrBase)
  w.add(lineOf("let mut remaining_shield = initial_shield"),
        @[value("remaining_shield", InitialShield)])
  for p in passes:
    w.add(lineOf("for i in 0..8"), @[value("i", p.i)], Loop, p.i)
    w.add(lineOf("let mass = masses[i]"), @[value("mass", p.mass)], Loop, p.i)
    w.add(lineOf("let damage = calculate_damage"),
          @[value("damage", p.call.damage)], Loop, p.i)
    w.add(lineOf("remaining_shield -= damage"),
          @[value("remaining_shield", p.afterHit)], Loop, p.i)
    w.add(lineOf("let mut regeneration = 0"), @[value("regeneration", 0)], Loop, p.i)
    w.add(lineOf("if (remaining_shield as u32 > 0)"),
          @[value("remaining_shield", p.afterHit)], Loop, p.i)
    if p.afterHit > 0:
      w.add(lineOf("regeneration = calculate_shield_regeneration"),
            @[value("regeneration", p.regeneration)], Loop, p.i)
      w.add(lineOf("remaining_shield += regeneration"),
            @[value("remaining_shield", p.after)], Loop, p.i)
    w.add(lineOf("status_report(i"),
          @[value("i", p.i), value("remaining_shield", p.after)], Loop, p.i)
  let survived = passes[^1].after > 0
  w.add(lineOf("let result = remaining_shield as u32 > 0"),
        @[ct.DeepReviewVariableValue(name: "result", value: $survived, kind: "bool")])
  ct.DeepReviewFunctionFlow(functionKey: "iterate_asteroids",
                            executionIndex: executionIndex, steps: w.steps)

proc shieldHunk(): ct.DeepReviewHunk =
  ## The change: the bare `damage` the function returned became the clamp.
  ## Context is the three lines either side, as `git diff` gives it.
  let lines = ShieldSource.splitLines
  let first = lineOf("if(damage as u32 > remaining_shield as u32)")
  let last = lineOf("damage as Field")
  result = ct.DeepReviewHunk(oldStart: first - 3, oldCount: 3 + 1 + 1,
                             newStart: first - 3,
                             newCount: 3 + (last - first + 1) + 1)
  for n in first - 3 .. first - 1:
    result.lines.add(ct.DeepReviewHunkLine(`type`: "context",
      content: " " & lines[n - 1], oldLine: n, newLine: n))
  result.lines.add(ct.DeepReviewHunkLine(`type`: "removed",
    content: "-    damage", oldLine: first, newLine: 0))
  for n in first .. last:
    result.lines.add(ct.DeepReviewHunkLine(`type`: "added",
      content: "+" & lines[n - 1], oldLine: 0, newLine: n))
  result.lines.add(ct.DeepReviewHunkLine(`type`: "context",
    content: " " & lines[last], oldLine: first + 1, newLine: last + 1))

proc functionSpan(name: string; calls: int): ct.DeepReviewFunctionCoverage =
  ## A function's span: its `fn` line to the line before the next `fn` (or
  ## the end of the file).
  let lines = ShieldSource.splitLines
  var start = 0
  for i, line in lines:
    if line.contains("fn " & name & "("):
      start = i + 1
      break
  doAssert start > 0, "src/shield.nr has no fn " & name
  var stop = lines.len
  for i in start ..< lines.len:
    if lines[i].strip.startsWith("fn ") or lines[i].strip.startsWith("pub fn "):
      stop = i
      break
  while stop > start and lines[stop - 1].strip.len == 0:
    dec stop
  ct.DeepReviewFunctionCoverage(name: name, startLine: start, endLine: stop,
                                callCount: calls, executionCount: calls)

proc storyShieldReviewFile*(): ct.DeepReviewFileData =
  ## `src/shield.nr` in the story's review: its text, the change, and what
  ## the recording of the program's run (both asteroid fields) recorded in it.
  let positive = simulateField(PositiveMasses)
  let negative = simulateField(NegativeMasses)
  let hunk = shieldHunk()
  var regenerations = 0
  for p in positive & negative:
    if p.afterHit > 0: inc regenerations
  var added, removed = 0
  for line in hunk.lines:
    if line.`type` == "added": inc added
    elif line.`type` == "removed": inc removed
  result = ct.DeepReviewFileData(
    path: ShieldPath,
    sourceContent: ShieldSource,
    flags: ct.DeepReviewFileFlags(hasCoverage: true, hasFlow: true),
    diff: ct.DeepReviewFileDiff(status: "M", linesAdded: added,
                                linesRemoved: removed, hunks: @[hunk]),
    functions: @[
      functionSpan("iterate_asteroids", 2),
      functionSpan("calculate_damage", positive.len + negative.len),
      functionSpan("calculate_shield_regeneration", regenerations),
      # Called by `calculate_damage` and by `status_report`, once each per pass.
      functionSpan("calculate_remaining_shield_pct",
                   2 * (positive.len + negative.len)),
      functionSpan("status_report", positive.len + negative.len),
    ],
    loops: @[ct.DeepReviewLoop(loopId: 1, headerLine: lineOf("for i in 0..8"),
                               startLine: lineOf("for i in 0..8"),
                               endLine: lineOf("status_report(i") + 1,
                               totalIterations: positive.len + negative.len)])
  # The calls in the order the run made them: the positive field, then the
  # negative one, each pass calling `calculate_damage` once.
  var rr = 1000
  var executionIndex = 0
  for p in positive & negative:
    result.flow.add(calculateDamageFlow(p.call, executionIndex, rr))
    inc executionIndex
    rr += 1000
  result.flow.add(iterateAsteroidsFlow(positive, 0, 500))
  result.flow.add(iterateAsteroidsFlow(negative, 1, 9500))

proc storyShieldFlowDecorations*(file: ct.DeepReviewFileData; doc: DiffDocument):
    seq[ReviewFlowDecoration] =
  ## The flow classes of the displayed invocations, instantiated here, where
  ## the native type world (`FlowUpdate`, `ViewSource` and the branch states
  ## the flow rule reads) is in scope.
  reviewFlowDecorationsOf(file, 0, doc, ct.FlowUpdate, ct.ViewSource)

proc storyShieldValueAnnotations*(file: ct.DeepReviewFileData; doc: DiffDocument):
    seq[ReviewValueAnnotation] =
  ## The values of the displayed invocations, every recorded pass asked for.
  reviewValueAnnotationsOf(file, 0, doc, high(int16).int)
