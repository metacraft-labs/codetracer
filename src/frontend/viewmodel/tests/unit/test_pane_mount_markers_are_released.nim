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
## ## Two ways to release, and the scan now knows both
##
## The original predicate was "does this pane override `unregister`". That is
## one correct fix and not the only one. `ui/verification.nim` and
## `ui/command.nim` clear the marker on the way IN instead — `register` adopts
## the newest component and `jsDelete`s the marker for its id — and that is
## arguably the stronger of the two, because it does not depend on teardown
## having run at all. Scoring those panes as debt was a FALSE POSITIVE of the
## heuristic, not a finding, so `clearsMarkerOnRegister` is now checked beside
## `releasesItsMarker` and both count as released.
##
## ## The panel host removed the shape
##
## Shared-DOM-Front-Ends D4/D6 mount panes from the code that creates their
## containers (`ui/panel_host`), which keeps no marker: a mount lives and dies
## with its container. Every pane converted that way dropped its marker table,
## so this scan now finds one pane where it found eighteen, and the panes the
## panel host mounts are asserted to hold none — a marker reintroduced into
## one of them is the defect coming back.
##
## ## No pane holds one now
##
## HSF-D6 mounted the last panes through the panel host and moved the editor's
## latch onto the editor component itself (`renderedByIsoNim`), which dies with
## the component. So the scan now asserts that NO `ui/*.nim` declares an
## `isoNim…MountedIds` table: a marker reappearing anywhere is the defect
## coming back. The predicate is kept honest by positive controls on
## synthetic source, so an empty result cannot come from a scan that has
## stopped matching.
##
## ## WHAT THIS SCAN STILL CANNOT SEE, and it cuts both ways
##
## It answers "does a release site exist at all", never "does it fire on every
## teardown path". A pane releasing at two sites is not proof it releases at
## all of them, so absence from the debt list is not a clearance.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_pane_mount_markers_are_released.nim

import std/[algorithm, os, sequtils, strutils, unittest]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 36
  ## The directory guard, the empty-scan assertion, three predicate controls,
  ## and two per panel-host pane (15 x 2).

const UiDir = "src/frontend/ui"

const PanelHostPanes = [
  ## Panes mounted through `ui/panel_host`, which keeps no marker. Each held
  ## one before; a marker reappearing in one is the defect coming back.
  "agent_activity",
  "agent_workspace",
  "calltrace_editor",
  "command",
  "constraints",
  "filesystem",
  "repl",
  "request_panel",
  "scratchpad",
  "step_list",
  "test_results",
  "trace_log",
  "unified_diff",
  "vcs",
  "verification",
]

proc paneName(path: string): string =
  path.extractFilename.changeFileExt("")

proc declaresMountMarker(source: string): bool =
  ## True when `source` DECLARES an `isoNim…MountedIds` table — a line that
  ## begins with the name (optionally after `var`, optionally exported,
  ## optionally with a pragma such as `{.used.}`) followed by `=` or `:`.
  ##
  ## This used to be `source.contains("MountedIds")`, which is not what the
  ## doc comment below promised. `ui/isonim_panel_mount.nim` (ce3faf0a3,
  ## 2026-09-04) — the module that REPLACED the id-keyed latch with a mark on
  ## the container — quotes the old idiom
  ## (`if isoNimVCSMountedIds.hasKey(componentId): return`) in its header, and
  ## the substring match counted that prose as a pane with a marker and no
  ## release. A file that explains the latch is not a pane that holds one.
  for line in source.splitLines:
    var t = line.strip()
    if t.startsWith("var "):
      t = t[4 .. ^1].strip()
    if not t.startsWith("isoNim"):
      continue
    let nameEnd = t.find("MountedIds")
    if nameEnd < 0:
      continue
    var rest = t[nameEnd + "MountedIds".len .. ^1]
    if rest.startsWith("*"):
      rest = rest[1 .. ^1]
    rest = rest.strip()
    if rest.startsWith("{."):
      let close = rest.find(".}")
      if close < 0:
        continue
      rest = rest[close + 2 .. ^1].strip()
    if rest.startsWith("=") or rest.startsWith(":"):
      # Reject a use such as `isoNimFooMountedIds[id] = true`: the name must
      # be the whole identifier before the `=`/`:`.
      if t[0 ..< nameEnd].allCharsInSet(IdentChars):
        return true
  false

proc panesWithMountMarkers(): seq[string] =
  ## Every `ui/*.nim` that declares an `isoNim…MountedIds` table.
  result = @[]
  for path in walkFiles(UiDir / "*.nim"):
    let source = readFile(path)
    if declaresMountMarker(source):
      result.add paneName(path)
  result.sort()

suite "no pane keeps a mount marker":

  test "the scan finds the pane directory, and no pane declares a marker":
    counted dirExists(UiDir)
    let panes = panesWithMountMarkers()
    if panes.len > 0:
      echo "panes declaring a mount marker: ", panes.join(", ")
    counted panes.len == 0

  test "the predicate still recognises a marker, and not prose about one":
    # THE EMPTY-HAYSTACK GUARD (`Verification-Harness-Traps.md` trap 4): the
    # assertion above passes vacuously if the predicate has stopped matching,
    # so it is exercised on source that does declare a marker.
    counted declaresMountMarker(
      "var isoNimFooMountedIds = JsAssoc[int, bool]{}")
    counted declaresMountMarker(
      "var isoNimFooMountedIds* {.used.}: JsAssoc[int, bool]")
    counted not declaresMountMarker(
      "  if isoNimVCSMountedIds.hasKey(componentId): return")

  test "the panes the panel host mounts hold no marker":
    # Each file is asserted to exist first, so a renamed pane fails here
    # rather than passing "notin" over a file that is not there.
    let panes = panesWithMountMarkers()
    for pane in PanelHostPanes:
      counted fileExists(UiDir / (pane & ".nim"))
      counted pane notin panes

suite "mount-marker suite self-check":

  test "pane_mount_marker_assertion_count_is_measured":
    check countedAssertions == ExpectedAssertions
