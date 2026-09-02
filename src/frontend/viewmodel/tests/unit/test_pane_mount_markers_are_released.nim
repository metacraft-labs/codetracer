## A pane that carries a mounted-marker must release it on `unregister`.
##
## ## The defect
##
## Panes that mount an IsoNim view into a GoldenLayout container share one
## shape, and it is write-once at both ends:
##
##   var fooComponentRef: FooComponent                 # assigned `if isNil`
##   var isoNimFooMountedIds: JsAssoc[int, bool]       # set true on mount
##
##   method register*(self: FooComponent; ...) =
##     if fooComponentRef.isNil:
##       fooComponentRef = self
##       tryMountIsoNimFooPanel()
##
## `tryMountIsoNimFooPanel` returns early when `isoNimFooMountedIds.hasKey(id)`.
## Neither global is cleared anywhere unless the pane overrides `unregister`.
##
## `ui/session_switch.nim` unregisters EVERY component of a closing session, and
## `ui/layout.nim` unregisters a closed panel. After either, the ref still points
## at a component whose DOM container is gone, and the mounted marker for its id
## survives into the next component given that id — whose mount then returns at
## the guard and draws nothing.
##
## **The pane comes back blank, permanently, and silently.** A mount that
## returns early at a guard is indistinguishable from a pane with nothing to
## show, which is why this survived: there is no error, no exception and no log.
##
## ## Why this test is a scan and not a mount
##
## Driving the real failure needs GoldenLayout, a mediator and a DOM — the
## `scratchpad_add_dispatch_test` harness. That test exists and is worth having,
## but it covers ONE pane, and this defect is a property of a SHAPE that
## eighteen panes share. A scan is the only instrument that can be exhaustive
## here, so this asserts the structural invariant across every pane at once and
## leaves the behavioural proof to the harness.
##
## ## The allowlist is the point
##
## Fifteen panes still carry the defect. They are listed, counted, and the count
## is asserted — so the list can only shrink deliberately, and a NEW pane that
## arrives with a marker and no release fails immediately rather than joining a
## silent majority.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_pane_mount_markers_are_released.nim

import std/[algorithm, os, sequtils, strutils, unittest]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 42

const UiDir = "src/frontend/ui"

const KnownMissingRelease = [
  ## Panes that carry a mounted-marker and do NOT release it. Every one of
  ## these comes back blank after a session switch or a panel close.
  ##
  ## This is a DEBT LIST, not a permission list. Shrink it by adding the
  ## `unregister` override — `ui/constraints.nim` is the worked example, and
  ## `ui/scratchpad.nim` is the original.
  "agent_activity",
  "agent_workspace",
  "calltrace_editor",
  "command",
  "editor",
  "filesystem",
  "low_level_code",
  "no_source",
  "repl",
  "request_panel",
  "step_list",
  "trace_log",
  "unified_diff",
  "vcs",
  "verification",
]

proc paneName(path: string): string =
  path.extractFilename.changeFileExt("")

proc panesWithMountMarkers(): seq[string] =
  ## Every `ui/*.nim` that declares an `isoNim…MountedIds` table.
  result = @[]
  for path in walkFiles(UiDir / "*.nim"):
    let source = readFile(path)
    if source.contains("MountedIds"):
      result.add paneName(path)
  result.sort()

proc releasesItsMarker(pane: string): bool =
  ## True when the pane overrides `unregister`. The override is the only place
  ## either global can be cleared.
  let source = readFile(UiDir / (pane & ".nim"))
  source.contains("method unregister*(self: ")

suite "panes release their mount markers":

  test "the scan finds the pane directory and a plausible number of panes":
    # THE EMPTY-HAYSTACK GUARD. Every assertion below is over
    # `panesWithMountMarkers()`, and all of them pass vacuously if it returns
    # nothing — a moved directory, a renamed marker, or a test run from the
    # wrong working directory would turn this whole suite green while
    # measuring an empty set. `Verification-Harness-Traps.md` trap 4.
    counted dirExists(UiDir)
    let panes = panesWithMountMarkers()
    counted panes.len >= 15
    counted "constraints" in panes
    counted "test_results" in panes
    counted "scratchpad" in panes

  test "constraints and test_results release their markers":
    # The two panes this change fixes. Named individually rather than left to
    # the allowlist, because "absent from a debt list" is satisfied by a pane
    # that no longer exists.
    counted releasesItsMarker("constraints")
    counted releasesItsMarker("test_results")
    counted "constraints" notin KnownMissingRelease
    counted "test_results" notin KnownMissingRelease

  test "scratchpad still releases its marker":
    # The original, and the control: if `releasesItsMarker` were broken so that
    # it returned false for everything, the assertions above would be
    # meaningless and this would catch it.
    counted releasesItsMarker("scratchpad")

  test "every pane either releases its marker or is on the debt list":
    let panes = panesWithMountMarkers()
    var offenders: seq[string] = @[]
    for pane in panes:
      if releasesItsMarker(pane):
        continue
      if pane in KnownMissingRelease:
        continue
      offenders.add pane
    if offenders.len > 0:
      echo "panes with a mount marker and no release, not on the debt list: ",
        offenders.join(", ")
    counted offenders.len == 0

  test "the debt list is exact, so it can only shrink deliberately":
    # WHY AN EXACT COUNT. A debt list that merely "contains" the offenders
    # grows silently — a pane added tomorrow with a marker and no release could
    # be appended in the same commit that introduced it, and nothing would
    # notice. The count is asserted, so shrinking it is a deliberate edit and
    # growing it is a conversation.
    counted KnownMissingRelease.len == 15

    # And every name on it is real: a stale entry would mask a pane that had
    # been renamed rather than fixed.
    let panes = panesWithMountMarkers()
    for pane in KnownMissingRelease:
      counted pane in panes

  test "the debt list names no pane that has since been fixed":
    # The other direction, and the one that makes the list decay usefully:
    # fixing a pane without removing its entry would leave the count truthful
    # and the list a lie.
    for pane in KnownMissingRelease:
      counted not releasesItsMarker(pane)

suite "mount-marker suite self-check":

  test "pane_mount_marker_assertion_count_is_measured":
    check countedAssertions == ExpectedAssertions
