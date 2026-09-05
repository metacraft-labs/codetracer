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
##     `Signal[seq[PointListEntry]]` that NOTHING in this repository fills
##     from a backend response — `setPoints` has exactly two call sites, its
##     own declaration and `storybook_components.nim:1379` (grep over
##     `src/frontend`, 2026-09-05). So a gutter bound to it would render
##     nothing on every real session while looking correctly wired. This
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

export source_pane

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

proc degradedMessageFor*(state: PaneDegradation): string =
  ## §14's row, as the one line the pane prints.
  ##
  ## Only `pdNoVerifiedSource` produces text here. The other degradations are
  ## other panes' — a source pane that printed "no calltrace" would be
  ## reinventing §14's canonical treatment, which is the thing §14 exists to
  ## prevent.
  if state == pdNoVerifiedSource:
    "No verified source for this revision — showing what is available."
  else:
    ""

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

proc annotationsFrom*(variables: seq[Variable]): seq[Annotation] =
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
    result.add Annotation(name: v.name, value: value)

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

proc followAndRequest*(vm: SourceVM): seq[SourceLineRequest] =
  ## Scroll to the execution pointer and report what the window now lacks.
  ##
  ## The two calls belong together and in this order: `followExecutionPointer`
  ## moves the window, `requestMissing` trims the held range to the NEW window
  ## and then asks for the gap. Reversed, the trim would run against the old
  ## window and the pane would ask for lines it is about to scroll away from.
  vm.followExecutionPointer()
  vm.requestMissing()
