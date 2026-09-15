## plugin_model/surfaces.nim — PLAT-9 deliverables 2 and 3, as pure decisions.
##
## Extensibility-Model.md §6.2 and §6.3 ask two questions about every surface a
## plugin contributes, and this module answers both without a renderer, a
## process or a clock — so both are assertable in a lane that links nothing.
##
##   * **§6.2 — which view runs here?** "An extension may supply **both**: an
##     abstract view as the baseline and a native view for one or more
##     front-ends, with the native one preferred where present."
##   * **§6.3 — and if there is none?** "A **required** surface with no view
##     for the active front-end makes the extension fail to activate, naming
##     the front-end and the surface. … An **optional** surface is simply not
##     present. … What must not happen is an extension that appears to load and
##     then silently does nothing — the plugin-system version of a test that
##     cannot fail."
##
## ## "ABSTRACT" IS NOT AUTOMATICALLY "EVERYWHERE", AND PLAT-3 SAYS SO
##
## The tempting reading of §6.2 is that an abstract view runs on every
## front-end by definition. PLAT-3 measured otherwise: `mappings.nim` records
## `msAbsent` on GPUI for exactly this entry —
##
##   ABSENT-ON-GPUI: Modal
##
## — and a surface whose abstract view is a `Modal` is therefore genuinely
## absent there, so calling it present would be the silent-nothing §6.3
## forbids.
##
## **THIS LINE NAMED THREE ENTRIES UNTIL 2026-09-15 AND NOW NAMES ONE.**
## PLAT-21 rendered the vocabulary through the real isonim-gpui shim and read
## the plan the Rust side builds: a tag that is not in the 35-entry tag map does
## NOT reach "a classifier with no case for it" — it keeps its spelling and
## classifies as `Div`, exactly as `button` and `ul` do. So `Table` and
## `ProgressIndicator` moved to `msPartial` and a plugin surface built on
## either is ADMITTED on GPUI now, where it used to be refused. `Modal` stayed,
## for the reason that was always the real one and was stated third: there is
## no element focus in that renderer, so the exclusivity a `Modal` IS cannot be
## built out of anything the medium offers. `mappings.gpuiMapping`'s three
## corrected rows carry the measurement.
##
## THAT LINE IS CHECKED AGAINST THE TABLE, NOT MAINTAINED BY HAND.
## `plugin_surfaces_test` reads it out of this file with `staticRead` and
## compares it, name for name, with `mappings.absentEntryNames(feGpui)`. It is
## checked because it was WRONG from the day it was written, in this header and
## in Extensibility-Model.md §6.4 both: it named `Image`, which is `msComplete`
## on GPUI and is one of two tags reaching a dedicated Rust element kind
## (`GpuiElementKind::Img`), and it omitted `Modal`, which has no modality, no
## focus trap and no layer at the renderer level. A plugin author reading it
## concluded that an `Image`-based abstract view could not run on GPUI and that
## a `Modal` was fine there; both are backwards, the CODE was right throughout
## (`chooseView` calls `mappingFor` and reads the real table), and nothing in
## the tree could say so because nothing read the table.
##
## So `chooseView` consults `mappingFor` — PLAT-3's own table, the one
## `view_vocabulary_test` verifies against isonim-gpui's source — rather than
## assuming. An entry that is `msPartial` DOES count as present: partial means
## "the front-end renders it and the binding supplies a semantic", which is a
## cost to the binding author and not an absence to the user.
##
## ## THE REFUSAL NAMES THE FRONT-END AND THE SURFACE, AND SAYS WHY
##
## §6.3 asks for both. `surfaceRefusals` produces one `PluginError` per
## required surface that has no view, carrying the plugin (as every
## `PluginError` does), the surface id, the front-end by its vocabulary name
## AND by the `--ui` value a user typed, and the reason — no view declared at
## all, or the declared vocabulary entries are absent on this front-end. A
## refusal a user cannot act on is the blank tab in a different costume.
##
## ## NO MOCKS AND NOTHING TO MOCK
##
## Every input is a value: a parsed manifest and a `FrontEnd`. There is no
## collaborator here to stand in for.

import std/strutils

import ./diagnostics
import ./manifest

export diagnostics, manifest

type
  ViewChoiceKind* = enum
    ## Which of §6.2's two arms serves this surface here, or neither.
    vcNone
      ## No view for this front-end. The ZERO VALUE, so a `ViewChoice` that
      ## was never computed reads as "nothing here" rather than as a view.
    vcAbstract
      ## §6.2's baseline: written once in PLAT-3's vocabulary.
    vcNative
      ## §6.2's other arm, and PREFERRED where supplied.

  ViewAbsence* = enum
    ## Why `vcNone`. Two different faults with two different remedies, which is
    ## why this is not a bool: "you declared nothing" and "what you declared
    ## does not exist here" are answered by an author in different ways.
    vaNotApplicable          ## the choice is not `vcNone`
    vaNothingDeclared        ## no abstract views and no native front-ends
    vaVocabularyAbsentHere   ## the declared entries map to `msAbsent` here

  ViewChoice* = object
    kind*: ViewChoiceKind
    frontEnd*: FrontEnd
    absence*: ViewAbsence
    absentViews*: seq[ViewKind]
      ## When `vaVocabularyAbsentHere`: exactly which entries are missing, so
      ## the refusal can name them. An author told "your view does not work on
      ## GPUI" has to guess which of five entries is the problem.

  ContributedPane* = object
    ## One pane surface, with the identity the layout will persist.
    plugin*: PluginId
    contribution*: Contribution
    qualifiedId*: string
      ## `<plugin>/<surface>` — `contributed_pane_id.qualifiedPaneId`, composed
      ## once here so no consumer composes it a second way.

func chooseView*(c: Contribution; fe: FrontEnd): ViewChoice =
  ## §6.2's rule, as one function.
  ##
  ## NATIVE FIRST, and that ordering IS the "preferred where present" clause.
  ## A surface that supplies both gets its native view on the front-end it was
  ## written for and its abstract view everywhere else, which is §6.2's
  ## "honest arrangement — it lets an extension be excellent on the desktop
  ## without being absent in the terminal".
  result.frontEnd = fe
  if fe in c.nativeFrontEnds:
    result.kind = vcNative
    result.absence = vaNotApplicable
    return
  if c.views.len == 0:
    result.kind = vcNone
    result.absence = vaNothingDeclared
    return
  for v in c.views:
    if mappingFor(fe, v).status == msAbsent:
      result.absentViews.add v
  if result.absentViews.len > 0:
    result.kind = vcNone
    result.absence = vaVocabularyAbsentHere
    return
  result.kind = vcAbstract
  result.absence = vaNotApplicable

func uiFlagFor*(fe: FrontEnd): string =
  ## How a user SELECTS this front-end, so a refusal names the thing they
  ## typed. Derived from `FrontEndAliases` rather than written out again: the
  ## aliases are the `--ui` spellings, and a second list of them would be the
  ## place the two drift apart (Verification-Harness-Traps §14).
  var flags: seq[string] = @[]
  for entry in FrontEndAliases:
    if entry.frontEnd == fe and entry.spelling != frontEndName(fe):
      flags.add "--ui=" & entry.spelling
  if flags.len == 0: "" else: flags.join(" or ")

func describeFrontEnd*(fe: FrontEnd): string =
  ## The front-end named the two ways a reader might know it: PLAT-3's
  ## vocabulary name, and the `--ui` value that selects it.
  let flags = uiFlagFor(fe)
  if flags.len == 0: "the " & frontEndName(fe) & " front-end"
  else: "the " & frontEndName(fe) & " front-end (" & flags & ")"

func describeAbsence*(plugin: PluginId; c: Contribution;
                      choice: ViewChoice): string =
  ## The detail of a §6.3 refusal. NAMES THE FRONT-END AND THE SURFACE, which
  ## is what §6.3 asks for in as many words, and then says what to do.
  var supported: seq[string] = @[]
  for fe in FrontEnd:
    if fe in c.nativeFrontEnds: supported.add frontEndName(fe)
  let where =
    if supported.len > 0:
      " It supplies a native view for " & supported.join(", ") & " only."
    else:
      ""
  case choice.absence
  of vaNotApplicable:
    ""
  of vaNothingDeclared:
    "required " & $c.kind & " surface '" & c.id & "' has no view for " &
      describeFrontEnd(choice.frontEnd) & "." & where &
      " Declare an abstract view in PLAT-3's vocabulary ('views') as the " &
      "baseline, add '" & frontEndName(choice.frontEnd) & "' to " &
      "'nativeViews', or mark the surface 'optional' so " & plugin &
      " loads here without it."
  of vaVocabularyAbsentHere:
    var names: seq[string] = @[]
    for v in choice.absentViews: names.add vocabularyName(v)
    "required " & $c.kind & " surface '" & c.id & "' declares the abstract " &
      "view(s) " & names.join(", ") & ", which PLAT-3's mapping table " &
      "records as absent on " & describeFrontEnd(choice.frontEnd) & "." &
      where & " Use an entry that maps there, add '" &
      frontEndName(choice.frontEnd) & "' to 'nativeViews', or mark the " &
      "surface 'optional'."

func surfaceRefusals*(m: PluginManifest; fe: FrontEnd): seq[PluginError] =
  ## §6.3's load-time consequence: every REQUIRED rendering surface with no
  ## view on `fe`, as an error naming the front-end and the surface.
  ##
  ## An OPTIONAL surface produces nothing here — "simply not present" — and
  ## the host is what leaves it out of the registry. That asymmetry is the
  ## whole of §6.3 and it is in one place.
  for c in m.contributions:
    if c.kind notin RenderingContributionKinds: continue
    if c.requirement != srRequired: continue
    let choice = chooseView(c, fe)
    if choice.kind != vcNone: continue
    result.add pluginError(m.id, pecSurfaceUnavailableOnFrontEnd,
      describeAbsence(m.id, c, choice))

func availableSurfaces*(m: PluginManifest; fe: FrontEnd): seq[Contribution] =
  ## The rendering surfaces that HAVE a view here. The complement of what
  ## `surfaceRefusals` and the optional-absence rule remove, by name, because
  ## a host needs the positive list and deriving it at the call site is how
  ## the two readings of §6.3 drift apart.
  for c in m.contributions:
    if c.kind notin RenderingContributionKinds: continue
    if chooseView(c, fe).kind == vcNone: continue
    result.add c

func absentOptionalSurfaces*(m: PluginManifest; fe: FrontEnd): seq[Contribution] =
  ## The surfaces §6.3 makes "simply not present". Named rather than merely
  ## missing: a user asking why a pane is not in their palette is owed the
  ## answer, and a list nobody can enumerate cannot produce one.
  for c in m.contributions:
    if c.kind notin RenderingContributionKinds: continue
    if c.requirement == srRequired: continue
    if chooseView(c, fe).kind == vcNone: result.add c

func contributedPanes*(m: PluginManifest): seq[ContributedPane] =
  ## Every pane this manifest contributes, with its qualified id composed once.
  for c in m.contributions:
    if c.kind != ckPane: continue
    result.add ContributedPane(plugin: m.id, contribution: c,
                               qualifiedId: qualifiedPaneId(m.id, c.id))
