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
## ## The debt list is the point
##
## One pane still carries the defect, down from fifteen. They are listed,
## counted, and the count is asserted — so the list can only shrink
## deliberately, and a NEW pane that arrives with a marker and no release fails
## immediately rather than joining a silent majority.
##
## ## WHAT THIS SCAN STILL CANNOT SEE, and it cuts both ways
##
## It answers "does a release site exist at all", never "does it fire on every
## teardown path". A pane releasing at two sites is not proof it releases at
## all of them, so absence from the debt list is not a clearance.
##
## And in the other direction, the pane on the list below DOES clear its
## marker somewhere (`ui/editor.nim`), just not from `register` or
## `unregister`. It stays on the list rather than being cleared by a widened
## pattern, because a
## `jsDelete` on some other code path is exactly the thing this scan is not
## competent to judge. Widening the predicate to match them would trade a
## known-incomplete list for a list that is wrong and looks complete.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_pane_mount_markers_are_released.nim

import std/[algorithm, os, sequtils, strutils, unittest]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 38
  ## Was 46. The panel host (D4/D6) removed the marker from every pane it
  ## mounts, so the per-pane release checks became one "holds no marker"
  ## check per panel-host pane (15 panes x 2), the debt list shrank from 7 to
  ## 1, and the register-side list emptied (its panes hold no marker).

const UiDir = "src/frontend/ui"

const KnownMissingRelease = [
  ## Panes that carry a mounted-marker and do NOT release it. Every one of
  ## these comes back blank after a session switch or a panel close.
  ##
  ## This is a DEBT LIST, not a permission list. Shrink it by mounting the
  ## pane through `ui/panel_host`, or by adding the `unregister` override
  ## (`ui/scratchpad.nim` is the original).
  ##
  ## `editor` already `jsDelete`s its marker on SOME path, so the question for
  ## it is which teardowns reach it — which this scan cannot answer.
  "editor",
]

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

proc overridesUnregister(pane: string): bool =
  ## True when the pane overrides `unregister`.
  let source = readFile(UiDir / (pane & ".nim"))
  source.contains("method unregister*(self: ")

proc clearsMarkerOnRegister(pane: string): bool =
  ## True when `register` itself drops the marker for the incoming id.
  ##
  ## Matched on the `jsDelete` of the pane's own `MountedIds` table keyed by
  ## `self.id`, which is the whole of the idiom, rather than on the mere
  ## presence of `jsDelete`, which a pane may also use on a DOM node that has
  ## nothing to do with mount markers.
  let source = readFile(UiDir / (pane & ".nim"))
  for line in source.splitLines:
    let t = line.strip()
    if t.startsWith("discard jsDelete(isoNim") and
        t.contains("MountedIds[self.id])"):
      return true
  false

proc releasesItsMarker(pane: string): bool =
  ## Either mechanism counts. See the header: clearing on the way in is not a
  ## lesser fix, and scoring it as debt was a defect in this scan.
  overridesUnregister(pane) or clearsMarkerOnRegister(pane)

suite "panes release their mount markers":

  test "the scan finds the pane directory and the pane that holds a marker":
    # THE EMPTY-HAYSTACK GUARD. Every assertion below is over
    # `panesWithMountMarkers()`, and the "holds no marker" ones pass vacuously
    # if it returns nothing — a moved directory, a renamed marker, or a test
    # run from the wrong working directory would turn this suite green while
    # measuring an empty set. `Verification-Harness-Traps.md` trap 4. So the
    # one pane that still declares a marker must be found.
    counted dirExists(UiDir)
    let panes = panesWithMountMarkers()
    counted "editor" in panes
    # The prose-only module is not a pane: it quotes the old idiom.
    counted "isonim_panel_mount" notin panes

  test "the panes the panel host mounts hold no marker":
    # Each file is asserted to exist first, so a renamed pane fails here
    # rather than passing "notin" over a file that is not there.
    let panes = panesWithMountMarkers()
    for pane in PanelHostPanes:
      counted fileExists(UiDir / (pane & ".nim"))
      counted pane notin panes

  test "the release predicate still recognises a release":
    # The control: if `releasesItsMarker` returned false for everything, the
    # debt-list checks below would be meaningless. `scratchpad` overrides
    # `unregister`.
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
    counted KnownMissingRelease.len == 1

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
