## value_presentation/surfaces.nim — the budget each surface declares.
##
## PLAT-2 deliverable 3: *"a budget per surface — a tracepoint line holds one
## line; the state panel holds a tree — so the presenter returns what fits
## rather than each surface truncating"*.
##
## ## WHY THE BUDGETS LIVE TOGETHER AND NOT BESIDE THEIR SURFACES
##
## Because the milestone's claim is a claim about the SET of them: *"the same
## value renders consistently across every surface, differing only by the
## budget each declares"* (PLAT-2 named six; there are EIGHT — see
## `SurfaceBudgets` below, and its own comment for the two that arrived after
## the milestone and why each is an addition to its scope rather than a
## subdivision of one of the six). That is checkable only if the budgets are in
## one place where a test can enumerate them — `SurfaceBudgets` below is that
## enumeration, and `value_presentation_test.nim` iterates it rather than naming
## budgets one at a time, so an eighth surface added here is asserted about
## without anyone editing the suite (Verification-Harness-Traps §4b: when the
## membership is knowable, the control is the COUNT).
##
## ## WHAT EACH NUMBER REPLACED
##
## Every constant below is the number the surface ALREADY used, moved rather
## than invented, so the migration is a change of mechanism and not a change of
## behaviour that would be indistinguishable from a bug:
##
## | budget          | number | where it was before |
## |-----------------|--------|---------------------|
## | `state-panel`   | depth 7, 200 members | `ui/state.nim`'s request-time `LOCALS_RR_DEPTH_LIMIT = 7`; the panel itself had NO render-time bound at all, which is why a 600-entry mapping rendered 600 entries into one `span` |
## | `tracepoint`    | 1 line, depth 10 | `textRepr`'s default `depth = 10`; the surface had no width bound |
## | `flow`          | 1 line, 30 cells | `ui/flow.nim`'s `FLOW_VALUE_LIMIT = 30`, which was a CSS `max-width: 30ch` — a clip, not a truncation, so the full string still crossed into the DOM |
## | `scratchpad`    | 1 line, depth 10 | `ui/scratchpad.nim` had no bound; depth came from `textRepr`'s default |
## | `event-log`     | 1 line, depth 10 | `ui/trace_log.nim` had no bound |
## | `tui-variables` | 1 line, caller's cells | `tui/app/views/tree_node.nim`'s `fieldWidths(width).value` |
## | `tui-tree`      | depth 16, 100 members | `headless_session.ValueDecodeDepth = 16` and `tui/app/views/variables.DefaultPageSize = 100` |
## | `calltrace-arg` | 1 line, depth 10, 16 members | `ui/calltrace.nim`'s `safeCallArgText` had NO depth bound, NO member cap and NO width bound — it rendered TEN scalar kinds by hand and returned `""` for every container. See the entry below |
##
## The three that CHANGE behaviour are named here rather than left to be
## discovered:
##
##   * `state-panel` gains a member cap it did not have. A pane that rendered
##     600 entries into a single text span was not showing a reader 600
##     entries; it was showing them 12 KB of text in a 55-character-wide cell.
##     The tree beside it already carried the members, and still does.
##   * `flow` now TRUNCATES at 30 cells instead of clipping with CSS. The
##     "view more" affordance keyed on `len > FLOW_VALUE_LIMIT` is now keyed on
##     `Presentation.truncated`, which is the same question asked of the
##     presenter instead of re-derived from a string the surface measured
##     itself — and it no longer costs two extra full renderings per value
##     (`ui/flow.nim` called `textRepr(compact=true)` twice on the same value
##     on lines 1746 and 1750, and again on 1776-1782).
##   * `calltrace-arg` now RENDERS CONTAINERS. `safeCallArgText` had a `case`
##     over ten scalar `TypeKind`s and an `else: ""`, so a call argument that
##     was a `Seq`, an `Instance`, a `Tuple`, a `Table`, a `Variant`, a
##     `Pointer` or an `Enum` showed the reader an EMPTY call-argument chip.
##     Its numbers below are therefore not "the number the surface already
##     used" — the surface had none — but the numbers the other one-line
##     desktop surfaces already carry, which is the nearest thing to a moved
##     constant that exists for a surface that never had one.

import vocabulary

const
  MediaCapabilityNote* = {mcOctetStream}
    ## PLAT-12. What EVERY surface below declares in its `Budget.media`, and
    ## the reason the eight sets are identical. (Seven until 2026-09-15, when
    ## PLAT-21's `gpui-panel` joined them and declared exactly this floor for
    ## the same reason: nothing in this repository draws pixels for a GPU
    ## surface either.)
    ##
    ## §5.2 lets a project declare that a region of a value is an image, a
    ## waveform, a framebuffer, rendered markdown or a chart. Nothing in this
    ## repository draws any of those yet: the terminal's image tiers are
    ## PLAT-14, the desktop's `ValueComponent` has no media element, and
    ## `PresentationNode` carries a media TYPE and a SIZE rather than a
    ## payload. Declaring a capability here that nothing implements would turn
    ## every such value into a blank region, which is the outcome PLAT-9's
    ## degradation model exists to prevent — so the sets say what is true.
    ##
    ## `application/octet-stream` IS TRUE ON ALL EIGHT, and it is not a
    ## placeholder. Raw bytes are the one medium every surface already honours:
    ## `builtin.byte-buffer` has rendered `01 02 ff … (12 bytes)` since CTUI-7,
    ## on a line, and a media label naming the type and the size is the same
    ## fidelity. So the "this surface draws it" arm of `surfaceDrawsMedia` is
    ## reachable and tested rather than dead code beside a degradation path.
    ##
    ## NAMED ONCE AND REFERENCED EIGHT TIMES rather than written out eight
    ## times, so that widening one surface is a visible divergence from the
    ## note instead of an eighth copy silently drifting (§14). PLAT-14 is
    ## expected to give `tui-tree` and `tui-row` more than this; the desktop's
    ## own image work is expected to give `state-panel` more.
    ##
    ## **PLAT-14 HAS DONE THAT, AND IT IS A FUNCTION AND NOT A WIDER CONSTANT.**
    ## See `terminal_graphics/media.terminalMediaCapability`, which lives in
    ## THAT package rather than this one so the dependency points the way the
    ## layering does: the renderer knows what a media class is, the pipeline
    ## knows nothing about tiers, and `ci/test/value-presentation-boundary.sh`
    ## can still compile this package on its own. The constants below are still
    ## exactly this set, because what a terminal can draw is not a property of
    ## the surface — it is a property of the terminal, the multiplexer and the
    ## link, resolved at run time by
    ## `app/theme/image_capability.resolveImageCapability`. A surface whose
    ## declared media set said `image/png` unconditionally would be claiming a
    ## capability on a `TERM=dumb` CI log, and the value would degrade into the
    ## blank region PLAT-9's model exists to prevent — the same error this
    ## comment was written to avoid, one milestone later.

  StatePanelBudget* = Budget(
    name: "state-panel",
    lines: 0,          ## a tree; as many lines as the pane has rows
    cells: 0,          ## the DOM wraps and the tree indents; no cell bound
    depth: 7,          ## `ui/state.nim`'s own request depth limit
    members: 200,
    expandable: true,
    annotated: false,
    media: MediaCapabilityNote)

  TracepointBudget* = Budget(
    name: "tracepoint",
    lines: 1,
    cells: 0,          ## a tracepoint row is as wide as the panel
    depth: 10,
    members: 32,
    expandable: false,
    annotated: false,
    media: MediaCapabilityNote)

  FlowBudget* = Budget(
    name: "flow",
    lines: 1,
    cells: 30,         ## `FLOW_VALUE_LIMIT`
    depth: 10,
    members: 16,
    expandable: false,
    annotated: false,
    media: MediaCapabilityNote)

  ScratchpadBudget* = Budget(
    name: "scratchpad",
    lines: 1,
    cells: 0,
    depth: 10,
    members: 32,
    expandable: true,  ## the scratchpad's rows expand into children
    annotated: false,
    media: MediaCapabilityNote)

  EventLogBudget* = Budget(
    name: "event-log",
    lines: 1,
    cells: 0,
    depth: 10,
    members: 32,
    expandable: false,
    annotated: false,
    media: MediaCapabilityNote)

  TuiTreeBudget* = Budget(
    name: "tui-tree",
    lines: 0,
    cells: 0,
    depth: 16,         ## `headless_session.ValueDecodeDepth`
    members: 100,      ## `tui/app/views/variables.DefaultPageSize`
    expandable: true,
    annotated: false,
    media: MediaCapabilityNote)

  CalltraceArgBudget* = Budget(
    name: "calltrace-arg",
    lines: 1,
    cells: 0,          ## the call-trace row's `.call-arg` chips wrap in the DOM
    depth: 10,         ## `textRepr`'s default, which every other one-line
                       ## desktop surface carries
    members: 16,       ## `flow`'s, the other inline one-line chip surface
    expandable: false, ## a chip has no affordance; the value popup does
    annotated: false,
    media: MediaCapabilityNote)

  GpuiPanelBudget* = Budget(
    name: "gpui-panel",
    lines: 0,          ## a tree; the pane scrolls, so no line bound
    cells: 0,          ## SEE THE NOTE BELOW — a GPU surface has no cells
    depth: 7,          ## the state panel's, because it IS the state panel
    members: 200,      ## the state panel's, for the same reason
    expandable: true,
    annotated: false,
    media: MediaCapabilityNote)
    ## **PLAT-21 deliverable 2: the GPUI surface declares its own budget.**
    ##
    ## The third front-end's state panel. It is the EIGHTH member of
    ## `SurfaceBudgets` below, and adding it is what that array's count control
    ## exists to force somebody to think about — see its own comment.
    ##
    ## *`cells: 0`, and that is not laziness.* `Budget.cells` is *"maximum
    ## display cells on ONE line, measured by `measure`"*, which is a terminal's
    ## unit. A GPU surface's line capacity is a pixel width divided by a font
    ## metric it resolves at paint time, and a surface that guessed a cell count
    ## would be truncating a value against a number it made up — which is
    ## exactly the "each surface truncating" PLAT-2 removed. `0` means unbounded
    ## and is the honest answer, and it is the SAME answer `state-panel` already
    ## gives for the DOM (*"the DOM wraps and the tree indents; no cell
    ## bound"*). Two of three front-ends decline this field, which is worth
    ## noticing about the field and is recorded in PLAT-21's status rather than
    ## filed as a gap: the escape hatch the vocabulary already has (`0` =
    ## unbounded) is sufficient, so nothing had to be added for GPUI.
    ##
    ## *The numbers are `state-panel`'s, moved rather than invented*, which is
    ## the rule the header states for every other constant in this file: the
    ## GPUI state panel is the same pane on a third medium, so it inherits the
    ## same depth and the same member cap, and a difference between the two
    ## columns is then a difference in the RENDERING rather than in the budget.

  SurfaceBudgets*: array[8, Budget] = [
    StatePanelBudget, TracepointBudget, FlowBudget, ScratchpadBudget,
    EventLogBudget, TuiTreeBudget, CalltraceArgBudget, GpuiPanelBudget]
    ## THE EIGHT NAMED SURFACES, and exactly eight.
    ##
    ## **SEVEN UNTIL 2026-09-15, when PLAT-21 added `gpui-panel`.** The comment
    ## below says the length is part of the contract *"so a suite that iterates
    ## it and asserts `SurfaceBudgets.len == 7` fails when an eighth is added
    ## without the milestone's scope being revisited"*. PLAT-21 is that
    ## revisiting: it gives the debugger panes a third front-end, and a front-end
    ## that rendered values at another medium's budget would be the "each
    ## surface truncating" defect wearing a borrowed constant. Four suites
    ## carried the literal `7` and each was moved by hand, from a run.
    ##
    ## PLAT-2's brief named six. `calltrace-arg` is the seventh and it is an
    ## ADDITION to the milestone's stated scope rather than a subdivision of
    ## one of the six: `ui/calltrace.nim` carried a `safeCallArgText` that was
    ## missed by the first migration, its output crosses into the SCRATCHPAD
    ## (`viewmodel/views/isonim_calltrace_view.addCallArgToScratchpad` wraps it
    ## in a `TypeKind.Raw` `Value`), and a scratchpad row rendered by the
    ## presenter beside a call-argument chip rendered by hand is exactly the
    ## "two spellings of one value in one pane" the milestone's own risk names.
    ##
    ## The array's LENGTH is part of the contract: a suite that iterates it and
    ## asserts `SurfaceBudgets.len == 7` fails when an eighth is added without
    ## the milestone's scope being revisited, which is the count control
    ## Verification-Harness-Traps §4b asks for. It fired, as designed, when
    ## `gpui-panel` arrived; four suites went red and each number was re-taken
    ## from a run. `tuiRowBudget` below is NOT a member — it is `tui-tree`
    ## narrowed to one row's cells — and `gpuiRowBudget` is not one either, for
    ## exactly the same reason.

func tuiTreeBudget*(media = MediaCapabilityNote): Budget =
  ## `TuiTreeBudget` with the media set the RESOLVED terminal can draw.
  ##
  ## The zero-argument spelling is `TuiTreeBudget` exactly, which is the
  ## fail-low default: a caller that has not resolved an image capability gets
  ## the set that was true before PLAT-14, and the value degrades honestly
  ## rather than claiming a renderer nobody asked the terminal about.
  result = TuiTreeBudget
  result.media = media

func tuiRowBudget*(cells: int; focused: bool;
                   media = MediaCapabilityNote): Budget =
  ## One row of the TUI's variables pane.
  ##
  ## The cell count is the caller's because it is the PANE's, computed by
  ## `tui/app/views/tree_node.fieldWidths` from the terminal's width — the one
  ## budget in this file that cannot be a constant. `focused` raises
  ## `annotated`, which is §3.3.4's "decimal and hexadecimal simultaneously
  ## upon focus" expressed as a budget rather than as a second code path.
  ##
  ## `media` defaults to `MediaCapabilityNote` for `tuiTreeBudget`'s reason: a
  ## caller that has not resolved an image capability must get the set that was
  ## true before PLAT-14.
  Budget(name: "tui-row", lines: 1, cells: cells, depth: 1,
         members: 8, expandable: false, annotated: focused,
         media: media)

func gpuiRowBudget*(media = MediaCapabilityNote): Budget =
  ## One ROW of the GPUI state panel — `gpui-panel` narrowed to a line, the
  ## same relationship `tuiRowBudget` has to `tui-tree`.
  ##
  ## It takes NO cell count, and that is the one real difference between this
  ## and its terminal twin. `tuiRowBudget(cells, focused)` needs the number
  ## because a terminal row's capacity is a column count the pane computed; a
  ## GPU row's is pixels, which the surface does not know until it paints. So
  ## the parameter that cannot be answered is absent rather than defaulted to a
  ## number somebody chose — a defaulted cell count would truncate every GPUI
  ## row against a constant with no provenance, which is the defect PLAT-2's
  ## `flow` entry records from the other direction.
  Budget(name: "gpui-row", lines: 1, cells: 0, depth: 1,
         members: 8, expandable: false, annotated: false, media: media)

func tuiValueBudget*(): Budget =
  ## The rendering stored on a `store/types.Variable` when a `ct/load-locals`
  ## response is decoded.
  ##
  ## `lines: 1` and a real member cap, where `headless_session.extractValueText`
  ## had a depth limit of 16 and NO member cap — so one 600-entry mapping
  ## produced a 12 KB string that was then classified, measured and clipped
  ## once per row per frame. That cost is the measurement recorded in
  ## `type_formatters.trimmedRange` (11 ms -> 4.3 ms against a 15 ms gate); this
  ## budget removes its cause rather than working around it.
  Budget(name: "tui-value", lines: 1, cells: 0, depth: 16, members: 64,
         expandable: true, annotated: false, media: MediaCapabilityNote)
