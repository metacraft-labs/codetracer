## store/value_media_degradation.nim — PLAT-12. A §5.2 media declaration this
## front-end cannot draw, as the degraded state a pane already renders.
##
## ## WHY THIS REUSES `PaneDegradation` RATHER THAN ADDING TO IT
##
## Extensibility-Model.md §8.2, quoted by `surface_host.nim`, settled this
## question once for a plugin surface whose external component is absent: "a
## plugin whose external component is absent is **degraded, not broken**, and
## CodeTracer already has a model for exactly that … inventing a parallel
## 'plugin unavailable' banner would be a second mechanism saying the same
## thing worse". A terminal that cannot show `image/png` is that sentence with
## a different subject, so the answer is the same: `resolveDegradation`, the
## existing precedence, and `pdDependencyMissing`.
##
## **No row was added to `PaneDegradation` and `degraded_state.nim` is
## untouched.** That is deliberate and PLAT-11 wrote down why, as its residue
## 5: adding a row "would have changed `DegradationPrecedence`'s arity and the
## per-pane sets". It would also have broken two live assertions —
## `test_five_panes_drive_headlessly`'s `DegradationPrecedence[^1] ==
## pdNoVerifiedSource` and `test_plugin_surfaces`'s two neighbour checks around
## `pdDependencyMissing` — for a row whose treatment is identical to one that
## already exists. A catalogue grows when a pane needs a NEW treatment, not
## when a new condition needs an existing one.
##
## ## THE AXIS IS `PluginDependencyState`, AND IT NOW HAS A NON-PLUGIN PRODUCER
##
## This is the one honest stretch in the module and it is recorded rather than
## glossed. `DegradedStateSnapshot.dependency` is spelled
## `PluginDependencyState` because PLAT-9 named it for its first user. What the
## axis MEANS is "a thing this surface declared it needs is not available
## here", and its two non-satisfied values are split by REMEDY, which is
## exactly the distinction a media gap needs:
##
##   `pdsAbsent`      renewable — install the missing thing
##   `pdsUnsupported` "the host … could not run it either way", so telling a
##                    user to install something would be the retry that cannot
##                    succeed
##
## A surface with no renderer for `image/png` is `pdsUnsupported` and not
## `pdsAbsent`: there is nothing to install into a terminal that has no inline
## image protocol, and the remedy `describeMediaGap` gives says so. PLAT-9's
## own doc comment on `pdsUnsupported` names the process SDK because that was
## its first producer; the value is the general one, the same way
## `PaneDegradation` gained a non-§14 row in PLAT-9 and the row said which
## specification it came from.
##
## ## THE SENSITIVITY SET IS THIS MODULE'S, WHICH IS THE DESIGNED EXTENSION
##
## `degraded_state.nim`'s own header: "each pane declares as data the subset of
## rows it renders. A pane's memo is then a call, not a decision tree." A value
## rendering is not a pane, so `ValuePresentationDegradations` below is a
## caller's subset rather than a new entry in `AllPaneDegradations` — and
## `resolveDegradation` takes the set as a parameter precisely so a caller can
## bring its own. Nothing about the existing catalogue's coverage assertions
## changes: the union of `AllPaneDegradations` still covers every row, because
## this set is a subset of rows that are already in it.
##
## ## NO MOCKS, NOTHING STANDING IN FOR ANYTHING
##
## Two total functions over two real types. `resolveDegradation` is the
## product's own resolver and `Presentation` is the product's own presentation.

import ../../../common/value_presentation
import ./degraded_state

export degraded_state

const
  ValuePresentationDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdDependencyMissing,
  }
    ## The rows a VALUE RENDERING renders a treatment for.
    ##
    ## The three that mean the execution cannot be seen at all, plus the media
    ## gap. It is NOT sensitive to truncation, divergence or source
    ## verification, and the reason is `ContributedPaneDegradations`': those
    ## are claims about a PANE's data, and a value rendering is one cell of
    ## whatever pane is asking — the pane already raises them and a second
    ## banner inside one of its rows would say the same thing twice.

func mediaDependencyState*(p: Presentation): PluginDependencyState =
  ## The dependency axis, for one rendered value.
  ##
  ## `pdsSatisfied` when the presentation honoured every media declaration it
  ## met — which is every presentation on a build with no project definitions
  ## loaded, and every presentation of a value no media rule matched.
  ##
  ## `pdsUnsupported` AND NOT `pdsAbsent` for a gap, always. See this module's
  ## header: every way a media declaration can fail here is one nothing the
  ## user can install will fix — the type is outside §5.2's list, or this
  ## surface draws no such thing, or the value has no such field. `pdsAbsent`
  ## would offer a remedy that cannot work.
  if p.mediaGaps.len == 0: pdsSatisfied else: pdsUnsupported

func valueSnapshot*(core: DegradedStateSnapshot;
                    p: Presentation): DegradedStateSnapshot =
  ## The session's four axes, plus this VALUE's dependency axis.
  ##
  ## The same shape `surface_host.snapshotFor` builds for a contributed pane,
  ## and for the same reason: ONE snapshot, so `resolveDegradation` is the same
  ## call every other consumer makes and the precedence between "the trace will
  ## not replay" and "this image will not draw" is decided once, in the array
  ## that already decides it.
  result = core
  result.dependency = mediaDependencyState(p)

func valueDegradation*(core: DegradedStateSnapshot;
                       p: Presentation): PaneDegradation =
  ## §8.2's reuse, spelled out: `resolveDegradation`, the existing precedence,
  ## and this module's sensitivity set. There is no second resolver, no second
  ## enum and no second precedence.
  resolveDegradation(valueSnapshot(core, p), ValuePresentationDegradations)

func valueDegradationDetail*(p: Presentation): string =
  ## §8.2's "what is missing and how to get it", for a rendered value.
  ##
  ## Forwards to `describeDegradation`, which is beside the gap it describes —
  ## a second sentence written here would be a second answer to "why is this
  ## not drawn", and the suite asserts the tool and the remedy as SUBSTRINGS
  ## rather than asserting the string is non-empty (`surface_host.describe`
  ## carries the same note).
  describeDegradation(p)
