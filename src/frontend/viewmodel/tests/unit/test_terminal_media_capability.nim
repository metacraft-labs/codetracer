## test_terminal_media_capability.nim — PLAT-14. THE OTHER HALF OF PLAT-12'S
## SENTENCE: "this surface draws it, that one says why not".
##
## PLAT-12 landed with `Budget.media` equal to `{mcOctetStream}` on all seven
## surfaces, and `value_presentation/surfaces.nim` recorded why: *"Nothing in
## this repository draws any of those yet: the terminal's image tiers are
## PLAT-14 … Declaring a capability here that nothing implements would turn
## every such value into a blank region."* PLAT-14 implements the terminal's
## image tiers, so this file asserts the widening — and, just as importantly,
## asserts that it is a FUNCTION of the resolved terminal rather than a wider
## constant, because a constant would put the blank region back on every
## terminal without a graphics protocol.
##
## ## WHAT ONLY THIS FILE CAN SAY
##
## `test_visualiser_media_degrades_as_a_pane_row.nim` asserts the ROUTE from a
## media gap into `PaneDegradation`. It cannot say that any surface draws
## anything, because when it was written none did. This file asserts the pair:
## the same value, the same declaration, the same presenter — drawn on one
## budget and degraded on another, with the degradation naming the type, the
## surface and a remedy, and with the rest of the value still present in BOTH.
##
## ## NO NEW CONCEPT, AND THAT IS THE POINT
##
## Nothing here introduces a degradation mechanism. `mediaDependencyState`,
## `valueDegradation`, `valueSnapshot` and `describeDegradation` are PLAT-12's
## and PLAT-9's, unchanged; `pdDependencyMissing` and `pdsUnsupported` are
## PLAT-9's rows, unchanged; `PaneDegradation` gains no member. The only new
## thing is `terminalMediaCapability`, which answers "what can THIS terminal
## draw" and is a set, not a mechanism.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. The declaration is TOML text handed to the product's own
## `loadProjectDefinitions`; the values are `PValue`s built the way an adapter
## builds them; the presenter, the budgets, the resolver and the catalogue are
## the product's. The tier and the protocol are values
## `app/theme/image_capability.resolveImageCapability` produces — reached here
## without a terminal, which is the same split `test_image_capability.nim`
## records.
##
## ## COUNTED ASSERTIONS (§4c) AND §13
##
## `ck` is a TEMPLATE. A `check` inside a plain `proc` sets a module global and
## the test still reports `[OK]`.

import std/[strutils, unittest]

import ../../../../common/value_presentation
import ../../../../common/value_visualisers
import ../../../../common/project_definitions
import ../../../../common/terminal_graphics/media
import ../../store/value_media_degradation

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 91

proc i(text: string): PValue =
  PValue(kind: pvkInt, text: text, typeName: "int", sourceKind: "Int")

proc bytesOf(n: int): PValue =
  var acc: seq[PMember] = @[]
  for k in 0 ..< n:
    acc.add member("", i($(k mod 251)))
  PValue(kind: pvkSequence, typeName: "bytes", sourceKind: "Seq", members: acc)

proc frame(): PValue =
  ## A recorded framebuffer as a recorder would hand it over: a record with a
  ## named byte field and an ordinary scalar beside it. The scalar is what
  ## "the rest of the value still presents" is asserted on.
  PValue(kind: pvkRecord, typeName: "Frame", sourceKind: "Instance",
         members: @[member("tick", i("4211")), member("pixels", bytesOf(40))])

proc presentersFrom(text: string): PresenterSet =
  presentersFor(loadProjectDefinitions(@[
    DefinitionFile(kind: dfkVisualisers, origin: doProject,
                   path: definitionPath("", dfkVisualisers), text: text)]))

const PngRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Frame"
media = "image/png"
mediaFrom = "pixels"
summary = "tick {tick}"
"""

const JpegRule = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Frame"
media = "image/jpeg"
mediaFrom = "pixels"
summary = "tick {tick}"
"""

let
  KittyMedia = terminalMediaCapability(itProtocol, ipKitty)
  ITermMedia = terminalMediaCapability(itProtocol, ipITerm2)
  CellMedia = terminalMediaCapability(itHalfBlock, ipNone)

suite "PLAT-14: what a resolved terminal can draw":

  test "tier 0 widens the set; every cell tier does not":
    # THE TABLE, written out. `terminal_graphics/media`'s header gives
    # the reason for each row: the bridge between §5.2's ENCODED types and the
    # cell tiers' RASTER input is a decoder this build has none of, so a cell
    # tier draws exactly what it drew before PLAT-14.
    ckEq KittyMedia, {mcOctetStream, mcImagePng}
    ckEq ITermMedia, {mcOctetStream, mcImagePng, mcImageJpeg}
    var cellTiers = 0
    for tier in [itHalfBlock, itQuadrant, itSextant, itBraille, itAscii]:
      ckEq terminalMediaCapability(tier, ipNone), MediaCapabilityNote
      # …and a tier below 0 cannot be rescued by naming a protocol beside it.
      ckEq terminalMediaCapability(tier, ipKitty), MediaCapabilityNote
      inc cellTiers
    ckEq cellTiers, 5
    # Tier 0 with no protocol and with a protocol this build cannot emit are
    # both the narrow set: the widening follows the EMITTER, not the tier name.
    ckEq terminalMediaCapability(itProtocol, ipNone), MediaCapabilityNote
    ckEq terminalMediaCapability(itProtocol, ipSixel), MediaCapabilityNote
    # Kitty's `f=100` is PNG. A JPEG handed to it is transmitted and rejected,
    # which is a blank region with extra steps.
    ck mcImageJpeg notin KittyMedia
    ck mcImageJpeg in ITermMedia
    # SVG, audio and rendered text are outside PLAT-14 on every tier.
    var never = 0
    for cls in [mcImageSvg, mcAudioWav, mcAudioOgg, mcTextMarkdown,
                mcTextHtml]:
      ck cls notin KittyMedia
      ck cls notin ITermMedia
      ck cls notin CellMedia
      inc never
    ckEq never, 5

  test "the seven declared surface budgets are UNCHANGED by this milestone":
    # The constants are the floor, and the floor did not move: a surface whose
    # declared set said `image/png` unconditionally would be claiming a
    # capability on a `TERM=dumb` CI log.
    var surfaces = 0
    for budget in SurfaceBudgets:
      ckEq budget.media, MediaCapabilityNote
      inc surfaces
    ckEq surfaces, 7
    ckEq SurfaceBudgets.len, 7
    # …and the zero-argument spellings of the two TUI budgets are the floor
    # too, which is the fail-low default: a caller that has not resolved an
    # image capability gets what was true before PLAT-14.
    ckEq tuiTreeBudget().media, MediaCapabilityNote
    ckEq tuiRowBudget(40, false).media, MediaCapabilityNote
    ckEq tuiValueBudget().media, MediaCapabilityNote
    ckEq tuiTreeBudget(), TuiTreeBudget

suite "PLAT-14: this surface draws it, that one says why not":

  test "a PNG declaration DRAWS on a Kitty terminal's tree budget":
    let drawn = present(frame(), tuiTreeBudget(KittyMedia),
                        presenters = presentersFrom(PngRule))
    # DRAWN, not degraded: no gap, the dependency axis satisfied, and the
    # existing resolver reporting no degradation at all.
    ckEq drawn.mediaGaps.len, 0
    ckEq mediaDependencyState(drawn), pdsSatisfied
    ckEq valueDegradation(initDegradedStateSnapshot(), drawn), pdNone
    ckEq valueDegradationDetail(drawn), ""
    # …and the rendering is the media label, naming the type and the size —
    # which is what a surface with pixels turns into a picture.
    ck drawn.root.text.contains("image/png")
    ckEq drawn.root.mediaType, "image/png"
    ck drawn.root.mediaBytes > 0

  test "the SAME value on the desktop's state panel degrades, and says why":
    let degraded = present(frame(), StatePanelBudget,
                           presenters = presentersFrom(PngRule))
    ckEq degraded.mediaGaps.len, 1
    ckEq mediaDependencyState(degraded), pdsUnsupported
    ckEq valueDegradation(initDegradedStateSnapshot(), degraded),
         pdDependencyMissing
    let detail = valueDegradationDetail(degraded)
    checkpoint(detail)
    # WHAT IS MISSING AND HOW TO GET IT — §8.2's rule, asserted as substrings
    # rather than as "the string is non-empty".
    ck detail.contains("image/png")
    ck detail.contains("state-panel")
    ck detail.contains("open the value on a surface that draws it")
    # THE REST OF THE VALUE STILL PRESENTS. A degradation that blanked the
    # value would be the blank region §8.2 exists to forbid, and the summary
    # the rule declared is what a reader still gets.
    ckEq degraded.root.text, "tick 4211"
    ck degraded.root.text.len > 0

  test "the SAME value on a terminal with no graphics protocol degrades too":
    # This is the row PLAT-12 could only assert in the abstract: a TERMINAL
    # surface that cannot draw. The gap names `tui-tree`, not `state-panel`,
    # so a reader is told which surface refused.
    let degraded = present(frame(), tuiTreeBudget(CellMedia),
                           presenters = presentersFrom(PngRule))
    ckEq degraded.mediaGaps.len, 1
    ckEq degraded.mediaGaps[0].surface, "tui-tree"
    ckEq degraded.mediaGaps[0].mediaType, "image/png"
    ckEq degraded.mediaGaps[0].class, mcImagePng
    ck degraded.mediaGaps[0].fieldPresent
    ckEq valueDegradation(initDegradedStateSnapshot(), degraded),
         pdDependencyMissing
    ck valueDegradationDetail(degraded).contains("tui-tree")
    ckEq degraded.root.text, "tick 4211"

  test "a JPEG draws on iTerm2 and degrades on Kitty, same value, same rule":
    # The pair that shows the set is per-PROTOCOL and not per-tier. One
    # declaration, one value, two terminals, two outcomes.
    let onIterm = present(frame(), tuiTreeBudget(ITermMedia),
                          presenters = presentersFrom(JpegRule))
    ckEq onIterm.mediaGaps.len, 0
    ck onIterm.root.text.contains("image/jpeg")
    let onKitty = present(frame(), tuiTreeBudget(KittyMedia),
                          presenters = presentersFrom(JpegRule))
    ckEq onKitty.mediaGaps.len, 1
    ckEq onKitty.mediaGaps[0].class, mcImageJpeg
    ckEq valueDegradation(initDegradedStateSnapshot(), onKitty),
         pdDependencyMissing
    # …and the PNG rule on the SAME Kitty budget draws, so the refusal above
    # is about the media type and not about the budget.
    ckEq present(frame(), tuiTreeBudget(KittyMedia),
                 presenters = presentersFrom(PngRule)).mediaGaps.len, 0

  test "one row's budget carries the terminal's set too":
    # `tuiRowBudget` is `tui-tree` narrowed to one row's cells, and a value
    # that draws in the tree must not degrade in the row that shows it.
    let row = present(frame(), tuiRowBudget(40, false, KittyMedia),
                      presenters = presentersFrom(PngRule))
    ckEq row.mediaGaps.len, 0
    ckEq row.budget.name, "tui-row"
    ck row.root.text.contains("image/png")
    let narrow = present(frame(), tuiRowBudget(40, false),
                         presenters = presentersFrom(PngRule))
    ckEq narrow.mediaGaps.len, 1
    ckEq narrow.mediaGaps[0].surface, "tui-row"

suite "PLAT-14: no new degradation concept was added":

  test "the catalogue and the sensitivity set are PLAT-9's, unchanged":
    # PLAT-12's own assertion, restated after this milestone widened a media
    # set: if PLAT-14 had needed a new row, this is where it would show.
    ck pdDependencyMissing in ValuePresentationDegradations
    ckEq ValuePresentationDegradations.card, 4
    var union: set[PaneDegradation] = {}
    for s in AllPaneDegradations:
      union = union + s
    var covered = 0
    for row in ValuePresentationDegradations:
      ck row in union
      inc covered
    ckEq covered, 4
    # The dependency axis for a drawable declaration is `pdsSatisfied` and for
    # an undrawable one is `pdsUnsupported` — never `pdsAbsent`, because
    # nothing a user installs puts an image protocol into `screen`.
    let drawn = present(frame(), tuiTreeBudget(KittyMedia),
                        presenters = presentersFrom(PngRule))
    let gap = present(frame(), tuiTreeBudget(CellMedia),
                      presenters = presentersFrom(PngRule))
    ckEq mediaDependencyState(drawn), pdsSatisfied
    ckEq mediaDependencyState(gap), pdsUnsupported
    ck mediaDependencyState(gap) != pdsAbsent

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    ckEq countedAssertions, ExpectedAssertions
