## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/diff_highlighter.nim — CTUI-7. CodeTracer-TUI.md §3.3.4's "Diff
## Highlighting: when stepping forward or backward, any variable whose value
## changed between the previous and current step is highlighted with a distinct
## background/foreground accent (Green/Bold) and marked with `[MOD]`."
##
## ## THE ANCHOR IS THE RECORDING'S PREDECESSOR, NOT THE TICK YOU CAME FROM
##
## This is the whole file, and it is CTUI-7's one genuinely subtle contract:
##
##   > "The diff compares the current tick against the tick before the last
##   > navigation — including *backward* navigation, where the naive
##   > implementation marks everything modified."
##
## Read as "compare against whatever was on screen a moment ago", that sentence
## produces a pane which, after `step forward` over `total = …` and then `step
## back`, marks `total` MODIFIED AGAIN — because the value did indeed differ
## between the two ticks. And CTUI-7's own test says the opposite must happen:
##
##   > "steps *backward* and asserts the value reverts and THE BADGE CLEARS."
##
## Both sentences are true at once under exactly one reading, and it is the one
## §3.3.4 states directly: the badge means *"the step that produced this state
## changed this variable"*, so the comparison is always against **the tick
## immediately before the current one IN THE RECORDING**, whichever direction
## the user arrived from.
##
##   * forward `T-1 → T`: the anchor is `T-1` — which IS "the tick before the
##     last navigation", so the two readings agree here and a forward-only test
##     cannot tell them apart. `total` is marked.
##   * backward `T → T-1`: the anchor is `T-2`, NOT `T`. `total` at `T-1` equals
##     `total` at `T-2`, so the badge clears, the value has reverted, and the
##     pane says what the statement at `T-1` did rather than what undoing `T`
##     did.
##
## Two properties fall out of this and both are worth having: the badges at a
## tick are a property OF THAT TICK, so revisiting it shows the same screen; and
## a backward step cannot mark a row that no statement ever wrote.
##
## **A naive implementation is not a strawman here.** Diffing the previously
## *displayed* values against the new ones marks every difference on a backward
## step and every difference after a jump — which on a jump between frames is
## every row. `tests/test_variable_diff_highlighting.nim` drives all three
## cases: forward over an assignment, backward over the same one, and a step
## that changes nothing.
##
## ## THE TIMELINE HOLDS OBSERVATIONS, AND SAYS WHEN IT HAS NONE
##
## The anchor has to come from somewhere, and nothing in the ViewModel layer
## keeps a variable's value at a tick the session is not on: `StateVM`'s
## `valueHistory` is filled only by an explicit `ct/load-history` request for
## one named expression (`toggleHistory`), and `store.locals.locals` holds
## exactly the current stop's answer. So this module keeps what the session has
## already seen, and a tick whose predecessor was never observed reports
## `anchorKnown == false` and marks NOTHING.
##
## That is the honest answer and not a degradation: with no predecessor the pane
## cannot know what the step changed, and a pane that guessed would mark every
## row on the first stop of every session.
##
## ## Pure
##
## Nothing here knows a ViewModel or a debugger exists. `app/variables_binding`
## feeds it.

import std/[algorithm, sequtils, tables]

import ./styled_row

type
  VariableChange* = enum
    ## What happened to one variable between the anchor tick and the current
    ## one.
    vchUnchanged
    vchModified   ## present in both, with a different rendering
    vchAdded      ## present now and not at the anchor — the step bound it
    vchRemoved    ## present at the anchor and not now — the binding went away

  ValueSnapshot* = object
    ## Every variable's rendered value at one tick, keyed by the same
    ## dot-separated path `StateVM.expandedPaths` uses.
    tick*: uint64
    values*: Table[string, string]

  ValueTimeline* = object
    ## The snapshots this session has actually observed, newest LAST by tick.
    ##
    ## Bounded, because a long stepping session would otherwise hold every stop
    ## it ever visited: `capacity` snapshots are kept and the LEAST RECENTLY
    ## OBSERVED is evicted, so walking back and forth over a region keeps that
    ## region and forgets one visited once an hour ago.
    snapshots: seq[ValueSnapshot]
    lastUse: seq[int]
      ## Parallel to `snapshots`: the observation counter at which each entry
      ## was last written or re-observed.
    clock: int
    capacity*: int

  VariableDiff* = object
    ## What the current tick changed, as a value.
    currentTick*: uint64
    currentKnown*: bool
      ## Whether the current tick has been observed at all. False means the
      ## caller asked about a tick it never fed in, and NOTHING is marked.
    anchorTick*: uint64
    anchorKnown*: bool
    changes*: Table[string, VariableChange]
      ## Only the paths that changed; an unchanged variable is absent rather
      ## than present as `vchUnchanged`, so `changes.len` is the size of the
      ## change set and a test can assert it exactly.

const
  DefaultTimelineCapacity* = 256
    ## Enough for a long stepping walk over one function. A number rather than
    ## "unbounded" for the reason CTUI-1 measured on `wide_state`: each stop's
    ## answer on that fixture carries a 600-entry mapping, and holding every
    ## stop is how a front-end grows by tens of megabytes per step.

  ModifiedTagStyle* = CellStyle(fg: "black", bg: "green", bold: true)
    ## §3.3.4's `[MOD]` marker: a BADGE, not a tinted word — black on green,
    ## bold. Both halves are asserted absolutely out of a real terminal by
    ## `tests/real_terminal/test_real_variables_pane.nim`, because a
    ## differential check between two tiers is blind to a colour both of them
    ## get wrong (`docs/tui-testing.md`, "What cross-tier equality cannot
    ## catch").
  ModifiedNameStyle* = CellStyle(fg: "green", bold: true)
    ## §3.3.4's "distinct background/foreground accent (Green/Bold)" on the
    ## changed row's name. A second, independent signal: the badge says WHICH
    ## rows changed at a glance across the pane, and the accent survives a
    ## narrow pane that has clipped the badge's column away.

# ---------------------------------------------------------------------------
# The timeline
# ---------------------------------------------------------------------------

proc initValueTimeline*(capacity = DefaultTimelineCapacity): ValueTimeline =
  ValueTimeline(snapshots: @[], lastUse: @[], clock: 0,
                capacity: max(2, capacity))

proc len*(timeline: ValueTimeline): int =
  ## How many ticks are held. Exposed so a test can assert the eviction bound
  ## rather than trust it.
  timeline.snapshots.len

proc observedTicks*(timeline: ValueTimeline): seq[uint64] =
  timeline.snapshots.mapIt(it.tick)

proc indexOfTick(timeline: ValueTimeline; tick: uint64): int =
  result = -1
  for i, snap in timeline.snapshots:
    if snap.tick == tick:
      return i

proc evictOldest(timeline: var ValueTimeline) =
  var victim = 0
  for i in 1 ..< timeline.lastUse.len:
    if timeline.lastUse[i] < timeline.lastUse[victim]:
      victim = i
  timeline.snapshots.delete(victim)
  timeline.lastUse.delete(victim)

proc observe*(timeline: var ValueTimeline; tick: uint64;
              values: Table[string, string]) =
  ## Record what the variables were at `tick`.
  ##
  ## Re-observing a tick REPLACES its snapshot rather than being ignored: the
  ## values at a tick are a fact about the recording and cannot change, so a
  ## second observation that differs means the first was taken before the
  ## response for that stop had landed — and keeping the stale one would make
  ## every diff against it wrong. Replacing is also what makes the entry
  ## most-recently-used, which is what keeps a region being walked resident.
  inc timeline.clock
  let at = timeline.indexOfTick(tick)
  if at >= 0:
    timeline.snapshots[at].values = values
    timeline.lastUse[at] = timeline.clock
    return
  # INSERTED IN TICK ORDER rather than appended and sorted, because the anchor
  # is "the greatest tick below this one" and a linear scan over an ordered seq
  # is both the simplest statement of that and the fastest thing at this size.
  var insertAt = timeline.snapshots.len
  for i, snap in timeline.snapshots:
    if snap.tick > tick:
      insertAt = i
      break
  timeline.snapshots.insert(ValueSnapshot(tick: tick, values: values), insertAt)
  timeline.lastUse.insert(timeline.clock, insertAt)
  while timeline.snapshots.len > timeline.capacity:
    timeline.evictOldest()

proc snapshotAt*(timeline: ValueTimeline; tick: uint64): ValueSnapshot =
  ## The snapshot for `tick`, or one with an empty table. Callers here always
  ## check `hasTick` first; the empty answer exists so a test that reads a tick
  ## it never fed gets a value rather than an exception.
  let at = timeline.indexOfTick(tick)
  if at >= 0: timeline.snapshots[at]
  else: ValueSnapshot(tick: tick, values: initTable[string, string]())

proc hasTick*(timeline: ValueTimeline; tick: uint64): bool =
  timeline.indexOfTick(tick) >= 0

proc anchorTickFor*(timeline: ValueTimeline;
                    tick: uint64): tuple[known: bool; tick: uint64] =
  ## The greatest OBSERVED tick strictly below `tick`.
  ##
  ## See this module's header: it is the recording's predecessor, not the tick
  ## the user came from, and that difference is the whole behaviour of a
  ## backward step.
  result = (false, 0'u64)
  for snap in timeline.snapshots:
    if snap.tick < tick:
      result = (true, snap.tick)
    else:
      break

# ---------------------------------------------------------------------------
# The diff
# ---------------------------------------------------------------------------

proc diffAt*(timeline: ValueTimeline; tick: uint64): VariableDiff =
  ## What the step that produced `tick` changed.
  result = VariableDiff(currentTick: tick, currentKnown: false,
                        anchorTick: 0, anchorKnown: false,
                        changes: initTable[string, VariableChange]())
  if not timeline.hasTick(tick):
    return
  result.currentKnown = true
  let anchor = timeline.anchorTickFor(tick)
  if not anchor.known:
    # Nothing before this tick has been seen, so nothing can be said about what
    # the step changed. Marking everything would be the naive answer and it is
    # wrong in the direction that matters: the first stop of a session would
    # light up every row.
    return
  result.anchorKnown = true
  result.anchorTick = anchor.tick
  let before = timeline.snapshotAt(anchor.tick).values
  let now = timeline.snapshotAt(tick).values
  for path, value in now:
    if not before.hasKey(path):
      result.changes[path] = vchAdded
    elif before[path] != value:
      result.changes[path] = vchModified
  for path, value in before:
    if not now.hasKey(path):
      result.changes[path] = vchRemoved

proc changeFor*(diff: VariableDiff; path: string): VariableChange =
  if diff.changes.hasKey(path): diff.changes[path] else: vchUnchanged

proc isModified*(diff: VariableDiff; path: string): bool =
  ## Whether the row for `path` carries `[MOD]`.
  ##
  ## An ADDED binding counts, and a REMOVED one does not — not as a nicety but
  ## because a removed binding has no row to put a badge on, while a binding the
  ## step created is precisely "a variable whose value changed" from a reader's
  ## point of view. The distinction is kept in the enum so a caller that wants
  ## to draw them differently can, and so a test can assert which one it saw.
  diff.changeFor(path) in {vchModified, vchAdded}

proc modifiedPaths*(diff: VariableDiff): seq[string] =
  ## Every path that carries `[MOD]`, sorted.
  ##
  ## SORTED because a `Table`'s iteration order is its hash order, and a test
  ## comparing "exactly these variables changed" against an unordered answer
  ## would be comparing two sets through a sequence and failing at random.
  result = @[]
  for path, change in diff.changes:
    if change in {vchModified, vchAdded}:
      result.add path
  result.sort()

proc describe*(diff: VariableDiff): string =
  ## One line for a failure message. Never used to make a decision.
  if not diff.currentKnown:
    return "tick " & $diff.currentTick & " was never observed"
  if not diff.anchorKnown:
    return "tick " & $diff.currentTick & " has no observed predecessor"
  "tick " & $diff.currentTick & " against " & $diff.anchorTick & ": " &
    $diff.modifiedPaths()
