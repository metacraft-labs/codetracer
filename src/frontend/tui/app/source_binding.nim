## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and never `viewmodel/*` directly.
##
## app/source_binding.nim — CTUI-5. The ONE place that turns ViewModels into a
## `SourcePaneModel`.
##
## ## Why this exists as its own module rather than as a method on the pane
##
## `app/views/source_pane.nim` is a pure function of a value, and every reason
## for that is written in its header. Something still has to read the
## ViewModels, and putting it in the view would take all three properties away:
## the pane could no longer be asserted without a debugger, two frames could no
## longer be compared as values, and the pane's memory ceiling would stop being
## a property of a field a reader can see.
##
## So: this module reads, the pane draws, and the seam between them is a plain
## object. It is the same split CTUI-3 made between `app/layout/profile.nim`
## (pure) and `app/tui_app.nim` (reads a `HeadlessApp`).
##
## ## WHAT IT READS, AND THE ONE THING IT MUST NOT
##
##   * `SourceVM` — the held window, `firstHeldLine`, `totalLineCount`,
##     `viewportTop`, the identity triple, and **`executionLine`**, which is
##     `store.debugger.val.location.line`.
##
##     NOT `EditorVM.cursorLine`. CTUI-4 measured what happens when a pane
##     follows the caret: nothing in the ViewModel layer writes `cursorLine`
##     from the debugger position, so on the `calc` fixture the debugger
##     reached line 29 with the pane's window still holding 1..16. The caret
##     and the execution pointer are different questions and this binding asks
##     the second one.
##   * `EditorVM.degradedState` — Page-Descriptions.md §14's row, re-exposed by
##     `SourceVM.degradedState` as the SAME memo. The pane renders that row; it
##     does not invent a message.
##   * `SourceAvailability` from the store — mapped onto the pane's
##     `GutterProvenance`, which is what makes CTUI-4's verified/unverified
##     distinction visible instead of merely typed.
##   * the session's breakpoints and tracepoints, as `SourcePoint` values,
##     filtered to the file on screen. **Not `PointListVM`, and that is a
##     finding rather than a shortcut.** `PointListVM.points` is a
##     `Signal[seq[PointListEntry]]` that nothing a USER runs fills from a
##     backend response.
##
##     **The count in this paragraph was wrong and is corrected in place,
##     2026-09-16 (PLAT-23).** It said *"`setPoints` has exactly two call
##     sites, its own declaration and `storybook_components.nim:1379` (grep
##     over `src/frontend`, 2026-09-05)"*. That was true on 2026-09-05 and
##     there are now **three**: the declaration, the storybook fixture, and
##     `viewmodel/viewmodels/point_collection_source.applyCollections`, which
##     PLAT-11 wrote as its verification gate and whose own header calls itself
##     *"the first producer"*. PLAT-22's verification found the same stale
##     figure re-asserted in `editor_rows.EditorPoint` and corrected it there.
##
##     *The conclusion survives and the reason is what makes it still worth
##     saying:* `applyCollections` has **no production caller** — all **twelve**
##     of its call sites are tests (re-counted 2026-09-16 with
##     `grep -rn 'applyCollections(' src/`; PLAT-22's verification said thirteen)
##     — so a gutter bound to `PointListVM` would
##     render nothing on every real session while looking correctly wired.
##     "There is no producer" and "the producer is reached by nothing a user
##     runs" point at different work, and it is the second.
##
##     **A BACKEND PRODUCER EXISTS SINCE 2026-09-17, and it narrows this
##     paragraph rather than retiring it.** `points` is now
##     `ReplayDataStore.pointList.rows`, and `applyTracepointResults` writes one
##     row per spec of a `ct/run-tracepoints` sweep — so a session that RUNS a
##     tracepoint fills the signal from the engine. What is still true is the
##     part this binding depends on: nothing a user runs supplies a checkout's
##     DECLARED points, and a gutter is about declared points rather than about
##     a sweep that has already happened. This
##     binding therefore takes the points as a value, and
##     `test_source_stepping_forward_backward.nim` builds them from the
##     ENGINE's own `setBreakpoints` acknowledgement — the line the replay
##     server VERIFIED, not the line the test asked for. When a ViewModel owner
##     for the point list appears, the only change here is who calls
##     `marksForFile`.
##   * `StateVM.currentVariables` — the values the inline annotations show, at
##     THIS tick, rebuilt every frame. See `views/inline_annotations.nim` on
##     why nothing is cached: a stale annotation is indistinguishable from a
##     correct one.
##
## ## No mocks
##
## Nothing here constructs a ViewModel, a store or a backend. It takes the ones
## a real session built.

import std/strutils

import codetracer_embed

import ./views/source_pane
# QUALIFIED BECAUSE `Annotation` IS NOW TWO TYPES IN THIS FILE'S SCOPE, AND
# THE SECOND ONE ARRIVED THROUGH THE FACADE (PLAT-34). `codetracer_embed` now
# re-exports the editing core, which reaches `editor/transaction.Annotation` —
# a transaction's typed metadata — while `views/inline_annotations.Annotation`
# is an inline value beside a source line and has been since CTUI-5. Neither
# name is wrong and neither type moved; what changed is that one file can see
# both. Importing the module explicitly is what lets the two uses below say
# WHICH, and it is preferred to renaming a five-year-old type to make a new
# export fit.
import ./views/inline_annotations
# PLAT-22's shared editor row model and the derivation both front-ends' editors
# go through.
#
# **EXACTLY ONE RULE MOVED, AND AN EARLIER SPELLING OF THIS COMMENT CLAIMED
# FOUR** — corrected here on 2026-09-16 rather than edited away, because a
# false completeness claim in a header is worse than a named gap: the header is
# what the next author reads instead of the code (§14a).
#
# MOVED: `followAndRequest`, two calls whose whole content is an ORDERING,
# which is the worst possible thing to have two copies of.
#
# NOT MOVED, and still declared below or beside: `provenanceFor`,
# `marksForFile`, `annotationsFrom`, `views/source_pane.markFor` and
# `inline_annotations.mentionsWord`. Those five are graded only by the `tui`
# lane, and moving code whose graders cannot be run is the trade this campaign
# refuses. `editor_rows.markFor`'s header records the one mark combination on
# which the two spellings already DISAGREE.
#
# AND ONE COPY THIS IMPORT CREATED, COLLAPSED BY PLAT-23 ON 2026-09-16:
# `degradedMessageFor` was declared HERE as well as in `editor_surface.nim` —
# identical in body and in parameter list, one spelled `proc` and one `func`
# (PLAT-22's residue said "signature", which glossed that), with this module
# re-exporting both. It compiled because the local declaration won inside
# the module and no other module called the unqualified name, which is precisely
# why nothing went red: §14's two-copies shape, created by the extraction that
# was meant to remove one, and invisible to the compiler.
#
# PLAT-22 recorded it as residue 14 rather than collapsing it, on the ground
# that *"its only graders are the `tui` lane's, and the `tui` lane cannot be run
# here"*. **That ground was narrower than it looked.** The lane's compile
# failure is `fatal error: tree_sitter/api.h: No such file or directory`, and
# the header sits in the SAME store path the lane's own `--passL` flags already
# name (`build/grammars/tui-link-flags.txt`) — it is `-L` and `-rpath` with no
# `-I`. With that one directory on `CPATH`,
# `src/frontend/tui/tests/test_cross_renderer_panes.nim` compiles and runs here:
# 240 checks, rc 0, before and after this deletion. So the copy is gone and the
# removal is GRADED rather than argued.
#
# The one-argument `degradedMessageFor` now resolves through the `export` below
# to `editor_surface`'s. `frame_viewer_binding.degradedMessageFor` is a
# two-argument OVERLOAD and is untouched.
import ../../view_vocabulary/editor_surface

export source_pane
export editor_surface

type
  SourcePointKind* = enum
    ## What a gutter mark stands for. An enum rather than
    ## `PointListEntry.kind`'s free-form string, because a typo in a string
    ## degrades into "no mark on this line" — a silent, plausible-looking
    ## screen — while a typo in an enum member does not compile.
    sptBreakpoint
    sptTracepoint

  SourcePoint* = object
    ## One breakpoint or tracepoint, as the pane needs it.
    ##
    ## Shaped like `PointListEntry` (path, line, kind, enabled) so that the day
    ## something fills `PointListVM` from the backend, the conversion is four
    ## field copies. See this module's header for why it is not read from there
    ## today.
    path*: string
    line*: int
    kind*: SourcePointKind
    enabled*: bool

proc provenanceFor*(availability: SourceAvailability): GutterProvenance =
  ## §14's source axis, as the pane's three-way distinction.
  ##
  ## `savUnverified` covers both "read off a machine rather than out of the
  ## recording" (`sfsUnverified`) and "the requested revision is not the one I
  ## have" (`sfsGenerationUnavailable`). Both are text the pane may render and
  ## must not certify, which is exactly one visual treatment.
  case availability
  of savVerified: gpVerified
  of savUnverified: gpUnverified
  of savAbsent: gpAbsent

proc revisionLabel*(vm: SourceVM): string =
  ## `@<generation>` — plus `#<digest>` when the recording carries one.
  ##
  ## Empty for generation 0 with no digest, which is EVERY recording this
  ## workspace produces today (CTUI-4: "No recorder in this workspace emits a
  ## `sourceDigest`", and every `Location` carries `source_generation: 0`). So
  ## the label is normally absent and appears exactly when there is something
  ## to disambiguate — which is the case it exists for.
  let rev = vm.revision.val
  if rev.sourceGeneration == 0 and rev.sourceDigest.len == 0:
    return ""
  result = "@" & $rev.sourceGeneration
  if rev.sourceDigest.len > 0:
    result.add "#" & rev.sourceDigest

proc marksForFile*(points: openArray[SourcePoint];
                   path: string): seq[(int, GutterMark)] =
  ## The gutter marks on `path`, in the order the pane's `markFor` reads them.
  ##
  ## TRACEPOINTS FIRST, BREAKPOINTS SECOND, because `markFor` lets the last
  ## declaration win and a line carrying both must show `●` — the one that
  ## stops — rather than `◆`.
  result = @[]
  for p in points:
    if p.path != path or p.line <= 0:
      continue
    if p.kind == sptTracepoint:
      result.add (p.line, gmTracepoint)
  for p in points:
    if p.path != path or p.line <= 0:
      continue
    if p.kind == sptBreakpoint:
      result.add (p.line, (if p.enabled: gmBreakpoint
                           else: gmBreakpointDisabled))

proc annotationsFrom*(variables: seq[Variable]):
                     seq[inline_annotations.Annotation] =
  ## `StateVM.currentVariables`, as `name: value` pairs.
  ##
  ## A variable with no rendered value is DROPPED rather than shown as
  ## `x: ` — an annotation with an empty value says the debugger reported
  ## nothing for `x`, which is not what it means: it means this formatter had
  ## nothing to print. Silence is the honest rendering of that.
  result = @[]
  for v in variables:
    let value = v.value.strip()
    if v.name.len == 0 or value.len == 0:
      continue
    result.add inline_annotations.Annotation(name: v.name, value: value)

proc sourcePaneModelFor*(vm: SourceVM;
                         availability: SourceAvailability;
                         points: seq[SourcePoint] = @[];
                         variables: seq[Variable] = @[];
                         heat = LineHeat();
                         gutterMode = gutLineNumbers): SourcePaneModel =
  ## The pane's model for the CURRENT frame.
  ##
  ## Everything is read at call time and nothing is retained: the returned
  ## value is the whole of what the pane will draw, so two frames are two
  ## values and the difference between them is exactly the difference on
  ## screen.
  let path = vm.path.val
  result = initSourcePaneModel(
    path = path,
    revisionLabel = vm.revisionLabel(),
    provenance = provenanceFor(availability),
    firstHeldLine = vm.heldFirstLine.val,
    heldLines = vm.heldLines.val,
    totalLineCount = vm.totalLineCount.val,
    viewportTop = vm.visibleFirstLine.val,
    executionLine = vm.executionLine.val,
    marks = marksForFile(points, path),
    values = annotationsFrom(variables),
    heat = heat,
    gutterMode = gutterMode,
    degradedMessage = (
      if availability == savAbsent: degradedMessageFor(vm.degradedState.val)
      else: ""))

# `followAndRequest` IS NO LONGER DECLARED HERE. PLAT-22 moved it to
# `view_vocabulary/editor_surface.nim` and this module re-exports it (see the
# import above), so the call sites in `host/tui_session.nim` and in this
# front-end's suites are unchanged. It moved because a second front-end's host
# needed the same two calls in the same order, and a two-line function whose
# entire content is an ORDERING is the worst possible thing to have two copies
# of: both compile, both run, and only one of them is right
# (Verification-Harness-Traps §14).
