## Every pane that mounts into a GoldenLayout container is mounted FROM the
## component factory, which is the only site that knows the container exists.
##
## ## The defect
##
## `ui/layout.nim`'s `genericUiComponent` registration builds a pane's host with
## `element.mountComponentContainer(editorLabel)` — that call is what creates
## `#<x>Component-<id>` — and then dispatches on `state.content` to mount the
## pane's IsoNim view into it. Twenty-five panes were mounted that way. Five
## were not: `State`, `Calltrace`, `Timeline`, `EventLog` and `TerminalOutput`
## mounted from their `register` method, or from their `initXVMWithStore`, and
## then POLLED for a container neither of those moments can guarantee.
##
## Measured on 25 real Electron desktop session logs (2026-09), on the modern
## shared-store path: `#stateComponent-0`, `#calltraceComponent-0` and
## `#timelineComponent-0` were absent at **retry #1 in all 25 runs**. Two ran
## long enough to reach a verdict and both gave up at retry #200, after 10.9 s
## and 30.4 s of runway:
##
##     ERROR | state.nim     | tryMountIsoNimStatePanel: not ready after 200 retries, giving up
##     ERROR | calltrace.nim | tryMountIsoNimCalltrace: not ready after 200 retries, giving up
##     DEBUG | trace.nim     | IsoNim timeline panel: not ready after 200 retries, giving up
##
## The other 23 ended mid-poll between retry #20 and #110 with the container
## still absent. There is no retry margin to widen — the poll starts before the
## thing it polls for can exist — so the State, Call Trace and Timeline panes
## were blank on CodeTracer desktop in every session examined.
##
## ## Why a scan, and what it can and cannot see
##
## Whether a pane's DOM ends up populated is a runtime property and belongs in
## a DOM harness. What this scan asserts is the STRUCTURAL invariant behind it:
## the factory is the single site with the knowledge, so every direct-mount
## `Content` must be dispatched there. `1cb7b9d6` is the worked example of why
## the structural claim matters on its own — it added a second poll window at
## `StateComponent.register` and fixed Noir Studio, while `CalltraceComponent
## .register` had always made the equivalent call and still gave up on the
## desktop. A behavioural test on one surface cannot see that; a scan over the
## dispatch can.
##
## This scan answers "is there an arm", never "does the arm mount the right
## thing". Presence is not correctness.
##
## ## The control data is derived, not transcribed
##
## `armsMissingFrom` runs over the CURRENT `layout.nim` and over a PRE-FIX
## source derived from it by deleting the five arms this change added. The
## second run must report exactly those five. That makes the failing case a
## property of the real file rather than a copied excerpt that goes stale the
## first time the dispatch is edited, and it is what stops this suite passing
## because the scan matches nothing at all.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_every_mountable_pane_has_a_factory_arm.nim

import std/[algorithm, os, sequtils, strutils, unittest]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 34

const LayoutPath = "src/frontend/ui/layout.nim"

const DispatchOpens = "let isDirectMountComponent = state.content in {"
  ## The direct-mount set opens the region this scan reads. Both the set and
  ## the dispatch that follows it live between here and `DispatchCloses`.

const DispatchCloses = "discard component.afterInit()"
  ## The last statement of the factory's dispatch body.

const ArmsAddedByThisChange = [
  ## The five panes moved into the factory. Named here so the derived pre-fix
  ## source below is built by deleting exactly these, and so a later change
  ## that quietly drops one is a failure rather than a shrinking list.
  "State", "Calltrace", "Timeline", "EventLog", "TerminalOutput",
]

const ExemptFromDispatch = [
  ## `Content` values that are in the direct-mount set and legitimately have no
  ## arm. ONE entry, and its justification is in `layout.nim` itself rather
  ## than here — see `dispatchExemptionIsExplainedInSource` below, which reads
  ## that comment back. An allowlist whose reasons live only in the test is a
  ## list of things nobody checked.
  "AgentActivityDeepReview",
]

proc layoutSource(): string =
  readFile(LayoutPath)

proc dispatchRegion(source: string): string =
  ## The factory's direct-mount set plus the dispatch that follows it.
  ##
  ## Sliced rather than scanned whole because `Content.Build` and friends also
  ## appear in the auto-hide overlay handler further down the file, and a scan
  ## over the whole file would score those as dispatch arms and pass for the
  ## wrong reason.
  let opensAt = source.find(DispatchOpens)
  if opensAt < 0:
    return ""
  let closesAt = source.find(DispatchCloses, start = opensAt)
  if closesAt < 0:
    return ""
  source[opensAt ..< closesAt]

proc directMountContents(source: string): seq[string] =
  ## The `Content` values listed in `isDirectMountComponent`.
  result = @[]
  let opensAt = source.find(DispatchOpens)
  if opensAt < 0:
    return
  let closesAt = source.find("\n    }", start = opensAt)
  if closesAt < 0:
    return
  for line in source[opensAt ..< closesAt].splitLines:
    let t = line.strip()
    if not t.startsWith("Content."):
      continue
    result.add t["Content.".len ..< t.len].strip(chars = {',', ' '})
  result.sort()

proc dispatchArms(source: string): seq[string] =
  ## The `Content` values the factory dispatches on.
  result = @[]
  for line in dispatchRegion(source).splitLines:
    let t = line.strip()
    if not t.startsWith("if state.content == Content."):
      continue
    let tail = t["if state.content == Content.".len ..< t.len]
    result.add tail.strip(chars = {':', ' '})
  result.sort()
  result = result.deduplicate()

proc armsMissingFrom(source: string): seq[string] =
  ## Direct-mount `Content` values with no arm and no exemption. THE PREDICATE
  ## the whole suite turns on, applied to real sources on both sides.
  let arms = dispatchArms(source)
  result = @[]
  for content in directMountContents(source):
    if content in arms:
      continue
    if content in ExemptFromDispatch:
      continue
    result.add content
  result.sort()

proc withArmsRemoved(source: string; contents: openArray[string]): string =
  ## The pre-fix dispatch, derived from the current one.
  ##
  ## Deletes the arm line and the single call line under it for each named
  ## `Content`, which is the shape every one of the five was added in.
  var out0: seq[string] = @[]
  var skipNext = false
  for line in source.splitLines:
    if skipNext:
      skipNext = false
      continue
    let t = line.strip()
    var dropped = false
    for content in contents:
      if t == "if state.content == Content." & content & ":":
        dropped = true
        skipNext = true
        break
    if not dropped:
      out0.add line
  out0.join("\n")

proc dispatchExemptionIsExplainedInSource(source: string): bool =
  ## `AgentActivityDeepReview` is exempt because `layout.nim` says why, in the
  ## dispatch, where the arm would be. Checked here so the exemption cannot
  ## survive the deletion of its reason.
  dispatchRegion(source).contains("``Content.AgentActivityDeepReview`` has no renderer of its own")

suite "the factory mounts every mountable pane":

  test "the scan finds the dispatch and a plausible number of panes":
    # THE EMPTY-HAYSTACK GUARD. Every assertion below is over
    # `directMountContents()` and `dispatchArms()`, and all of them pass
    # vacuously if the region markers stop matching — a refactor of
    # `layout.nim` would turn this suite green while measuring nothing.
    counted fileExists(LayoutPath)
    let source = layoutSource()
    counted dispatchRegion(source).len > 0
    counted directMountContents(source).len >= 25
    counted dispatchArms(source).len >= 25
    # And the region really is the factory's, not the auto-hide handler's:
    # `mountComponentContainer` is what creates the container these arms mount
    # into, and it is called above this region in the same registration.
    counted source.contains("element.mountComponentContainer(editorLabel)")

  test "every direct-mount Content has an arm in the factory":
    let source = layoutSource()
    let missing = armsMissingFrom(source)
    if missing.len > 0:
      echo "direct-mount Content values with no factory arm: ", missing.join(", ")
    counted missing.len == 0

  test "CONTROL DATA: the same scan reports exactly five on the pre-fix source":
    # Without this the suite could pass because `dispatchArms` matched every
    # line in the file, or because `directMountContents` returned nothing.
    # The pre-fix source is the current one with the five arms deleted, so the
    # scan is exercised against a tree it MUST fail on, by name.
    let source = layoutSource()
    let preFix = source.withArmsRemoved(ArmsAddedByThisChange)
    counted preFix.len < source.len
    let missing = armsMissingFrom(preFix)
    counted missing.len == 5
    for pane in ArmsAddedByThisChange:
      counted pane in missing

    # And the deletion took only what it claimed: the other twenty-odd arms
    # survive it, so "five missing" is a measurement and not an artefact of a
    # butchered source.
    counted "Build" in dispatchArms(preFix)
    counted "Filesystem" in dispatchArms(preFix)
    counted "Scratchpad" in dispatchArms(preFix)

  test "the three desktop-blank panes are dispatched, each by name":
    # Named individually, not left to the aggregate above: "some pane has an
    # arm" cannot fail for its own reason, and these three are the ones the 25
    # session logs showed blank.
    let arms = layoutSource().dispatchArms()
    counted "State" in arms
    counted "Calltrace" in arms
    counted "Timeline" in arms

  test "the two panes of the same shape are dispatched too":
    let arms = layoutSource().dispatchArms()
    counted "EventLog" in arms
    counted "TerminalOutput" in arms

  test "the exemption list is one entry, and layout.nim carries its reason":
    # A gate whose allowlist grows silently is not a gate. This one has a
    # single member, its reason is asserted to be present IN THE DISPATCH, and
    # it is asserted to be a real direct-mount Content rather than a stale name
    # that exempts nothing.
    counted ExemptFromDispatch.len == 1
    let source = layoutSource()
    counted dispatchExemptionIsExplainedInSource(source)
    for content in ExemptFromDispatch:
      counted content in directMountContents(source)
      counted content notin dispatchArms(source)

  test "the mount procs the arms call are reachable from layout.nim":
    # The arms are `tryMountIsoNimX()` calls, which compile only if the proc is
    # exported and the module imported. Both were changed by this commit, and a
    # revert of either would make the arm text above true and the build false —
    # so the scan asserts them rather than trusting that a green build implies
    # it, since this suite does not build `layout.nim`.
    let source = layoutSource()
    counted source.contains("calltrace, trace, event_log, terminal_output,")
    for procName in ["tryMountIsoNimStatePanel", "tryMountIsoNimCalltrace",
                     "tryMountIsoNimTimelinePanel", "tryMountIsoNimEventLogPanel",
                     "tryMountIsoNimTerminalOutputPanel"]:
      counted dispatchRegion(source).contains(procName & "()")

  test "the timeline's give-up is logged as loudly as the other two":
    # Not a dispatch property, and here anyway because it is the same defect
    # seen from the logging side: the timeline failed in every session the
    # other two failed in, and only its failure was invisible. `clog` at DEBUG,
    # under a message that did not even name the proc, is why nobody reported
    # a blank Timeline pane in 25 sessions of blank State and Call Trace panes.
    let trace = readFile("src/frontend/ui/trace.nim")
    counted trace.contains("cerror \"[PIPELINE] tryMountIsoNimTimelinePanel: not ready after 200 \"")
    counted trace.contains("tryMountIsoNimTimelinePanel: retry #")
    counted not trace.contains("clog \"IsoNim timeline panel: not ready")

suite "factory-arm suite self-check":

  test "factory_arm_assertion_count_is_measured":
    check countedAssertions == ExpectedAssertions
