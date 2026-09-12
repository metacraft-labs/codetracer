## test_visualiser_media_degrades_as_a_pane_row.nim — PLAT-12.
##
## A §5.2 media declaration this front-end cannot draw becomes the degraded
## state a pane already renders, through `resolveDegradation`, the existing
## precedence and `pdDependencyMissing` — with no row added to
## `PaneDegradation` and `degraded_state.nim` untouched.
##
## ## WHAT THIS ASSERTS THAT `value_visualisers_test` CANNOT
##
## That file is in `common-units` and `src/common/` cannot see
## `PaneDegradation` — the catalogue is the front-end's. So the gap and its
## sentence are asserted there and the ROUTE INTO THE CATALOGUE is asserted
## here: the axis a gap sets, the precedence against a trace that will not
## replay, and the fact that the union of `AllPaneDegradations` still covers
## the whole catalogue after this milestone (the coverage assertion
## `test_five_panes_drive_headlessly` makes, restated over the set this module
## introduces, because a sensitivity set that named a row NO pane renders would
## be a treatment nobody draws).
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## There is nothing to mock. `resolveDegradation` is the product's resolver,
## `DegradedStateSnapshot` is the product's snapshot, and the presentations are
## produced by the product's presenter from `PValue`s built the way an adapter
## builds them — `value_presentation_test`'s header carries that argument and
## it is unchanged here. No backend, no session, no host.
##
## ## COUNTED ASSERTIONS (§4c) AND §13
##
## `ck` is a TEMPLATE. A `check` inside a plain `proc` sets a module global and
## the test still reports `[OK]`.

import std/[strutils, unittest]

import ../../../../common/value_presentation
import ../../../../common/value_visualisers
import ../../../../common/project_definitions
import ../../store/value_media_degradation

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 42

proc i(text: string): PValue =
  PValue(kind: pvkInt, text: text, typeName: "int", sourceKind: "Int")

proc bytesOf(n: int): PValue =
  var acc: seq[PMember] = @[]
  for k in 0 ..< n:
    acc.add member("", i($(k mod 251)))
  PValue(kind: pvkSequence, typeName: "bytes", sourceKind: "Seq", members: acc)

proc image(): PValue =
  PValue(kind: pvkRecord, typeName: "Image", sourceKind: "Instance",
         members: @[member("width", i("64")), member("pixels", bytesOf(40))])

proc presentersFrom(text: string): PresenterSet =
  presentersFor(loadProjectDefinitions(@[
    DefinitionFile(kind: dfkVisualisers, origin: doProject,
                   path: definitionPath("", dfkVisualisers), text: text)]))

const PngRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "image/png"
mediaFrom = "pixels"
"""

const BytesRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Image"
media = "application/octet-stream"
mediaFrom = "pixels"
"""

suite "PLAT-12: a media gap is the degraded state a pane already renders":

  test "an undrawable declaration sets the dependency axis to unsupported":
    let degraded = present(image(), StatePanelBudget,
                           presenters = presentersFrom(PngRule))
    ckEq degraded.mediaGaps.len, 1
    ckEq mediaDependencyState(degraded), pdsUnsupported
    # `pdsUnsupported` AND NOT `pdsAbsent`, always. There is nothing to install
    # into a surface that has no renderer, and `pdsAbsent` would offer a remedy
    # that cannot work — §14's retry-that-cannot-succeed, at value scale.
    ck mediaDependencyState(degraded) != pdsAbsent

  test "a declaration this surface CAN draw leaves the axis satisfied":
    # The control. A check that reported `pdsUnsupported` whatever happened
    # would be satisfied by a presenter that never drew anything.
    let drawn = present(image(), StatePanelBudget,
                        presenters = presentersFrom(BytesRule))
    ckEq drawn.mediaGaps.len, 0
    ckEq mediaDependencyState(drawn), pdsSatisfied
    ckEq valueDegradation(initDegradedStateSnapshot(), drawn), pdNone
    ckEq valueDegradationDetail(drawn), ""
    # And so does a value no rule matched at all, on a build with no
    # definitions loaded — which is every build today.
    let plain = present(image(), StatePanelBudget)
    ckEq mediaDependencyState(plain), pdsSatisfied
    ckEq valueDegradation(initDegradedStateSnapshot(), plain), pdNone

  test "the gap resolves to pdDependencyMissing on an otherwise healthy trace":
    let degraded = present(image(), StatePanelBudget,
                           presenters = presentersFrom(PngRule))
    ckEq valueDegradation(initDegradedStateSnapshot(), degraded),
         pdDependencyMissing
    ckEq valueSnapshot(initDegradedStateSnapshot(), degraded).dependency,
         pdsUnsupported
    # The other four axes are the caller's and are carried through untouched —
    # `surfaceDegradation` does the same for a contributed pane.
    let core = initDegradedStateSnapshot()
    let snapshot = valueSnapshot(core, degraded)
    ckEq snapshot.availability, core.availability
    ckEq snapshot.integrity, core.integrity
    ckEq snapshot.capability, core.capability
    ckEq snapshot.sourceAvailability, core.sourceAvailability

  test "a trace that will not replay outranks an image that will not draw":
    # The precedence is `DegradationPrecedence`'s and is not re-decided here.
    # A user whose recording cannot be opened must not be told to look for a
    # different surface to view a PNG on.
    let degraded = present(image(), StatePanelBudget,
                           presenters = presentersFrom(PngRule))
    var unreplayable = initDegradedStateSnapshot()
    unreplayable.availability = raUnreplayable
    ckEq valueDegradation(unreplayable, degraded), pdPermanentlyUnreplayable
    var expired = initDegradedStateSnapshot()
    expired.availability = raWindowExpired
    ckEq valueDegradation(expired, degraded), pdReplayWindowExpired
    var noEngine = initDegradedStateSnapshot()
    noEngine.capability = rcWorkerUnsupported
    ckEq valueDegradation(noEngine, degraded), pdEngineUnavailable
    # And each of those still reports `pdDependencyMissing` for an undegraded
    # session, so the three above are outranking rather than masking a bug.
    ckEq valueDegradation(initDegradedStateSnapshot(), degraded),
         pdDependencyMissing

  test "rows this module is not sensitive to report pdNone, not a weaker value":
    # `degraded_state`'s own rule: "a pane that is not sensitive to a condition
    # returns `pdNone` for it rather than a weaker value". A truncated or
    # divergent trace is a claim about a PANE's data; a value rendering is one
    # cell of whatever pane is asking, and a second banner inside one of its
    # rows would say the same thing twice.
    let drawn = present(image(), StatePanelBudget,
                        presenters = presentersFrom(BytesRule))
    var truncated = initDegradedStateSnapshot()
    truncated.integrity = tiTruncated
    ckEq valueDegradation(truncated, drawn), pdNone
    var divergent = initDegradedStateSnapshot()
    divergent.integrity = tiDivergent
    ckEq valueDegradation(divergent, drawn), pdNone
    var unverified = initDegradedStateSnapshot()
    unverified.sourceAvailability = savUnverified
    ckEq valueDegradation(unverified, drawn), pdNone
    ckEq ValuePresentationDegradations, {pdPermanentlyUnreplayable,
                                         pdReplayWindowExpired,
                                         pdEngineUnavailable,
                                         pdDependencyMissing}

  test "no row was added, and every row this set names is one a pane renders":
    # PLAT-11's residue 5, held: adding a row would change
    # `DegradationPrecedence`'s arity and the per-pane sets. Both are asserted
    # here as the numbers they were, so a future row cannot arrive through this
    # module without the argument for it.
    ckEq DegradationPrecedence.len, 7
    ckEq DegradationPrecedence[0], pdPermanentlyUnreplayable
    ckEq DegradationPrecedence[^1], pdNoVerifiedSource
    ckEq ord(high(PaneDegradation)) + 1, 8
    ckEq AllPaneDegradations.len, 6
    # And this module's set is a SUBSET of rows some pane already renders, so
    # it introduces no treatment nobody draws.
    var union: set[PaneDegradation] = {}
    for s in AllPaneDegradations:
      union = union + s
    for row in ValuePresentationDegradations:
      ck row in union

  test "the detail names the media type, the surface and a remedy":
    # §8.2: "a name and an install action, not 'unavailable'". Asserted as
    # SUBSTRINGS rather than as "the string is non-empty", which is the note
    # `surface_host.describe` carries for the same reason.
    let degraded = present(image(), StatePanelBudget,
                           presenters = presentersFrom(PngRule))
    let detail = valueDegradationDetail(degraded)
    ck detail.len > 0
    ckEq detail, describeDegradation(degraded)
    for needle in ["image/png", "state-panel", "To see it:", "40 bytes"]:
      ck detail.contains(needle)
    ck not detail.contains("unavailable")
    # THE REST OF THE VALUE STILL PRESENTS. A degradation that blanked the row
    # would hide data the reader could have had.
    ck degraded.root.text.contains("width:64")
    ck degraded.root.children.len > 0

  test "every assertion in this file ran":
    ckEq countedAssertions, ExpectedAssertions
