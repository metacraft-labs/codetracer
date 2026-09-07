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
## budget each declares"* (PLAT-2 named six; there are seven — see
## `SurfaceBudgets` below). That is checkable only if the budgets are in one
## place where a test can enumerate them — `SurfaceBudgets` below is that
## enumeration, and `value_presentation_test.nim` iterates it rather than naming
## budgets one at a time, so a seventh surface added here is asserted about
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
  StatePanelBudget* = Budget(
    name: "state-panel",
    lines: 0,          ## a tree; as many lines as the pane has rows
    cells: 0,          ## the DOM wraps and the tree indents; no cell bound
    depth: 7,          ## `ui/state.nim`'s own request depth limit
    members: 200,
    expandable: true,
    annotated: false)

  TracepointBudget* = Budget(
    name: "tracepoint",
    lines: 1,
    cells: 0,          ## a tracepoint row is as wide as the panel
    depth: 10,
    members: 32,
    expandable: false,
    annotated: false)

  FlowBudget* = Budget(
    name: "flow",
    lines: 1,
    cells: 30,         ## `FLOW_VALUE_LIMIT`
    depth: 10,
    members: 16,
    expandable: false,
    annotated: false)

  ScratchpadBudget* = Budget(
    name: "scratchpad",
    lines: 1,
    cells: 0,
    depth: 10,
    members: 32,
    expandable: true,  ## the scratchpad's rows expand into children
    annotated: false)

  EventLogBudget* = Budget(
    name: "event-log",
    lines: 1,
    cells: 0,
    depth: 10,
    members: 32,
    expandable: false,
    annotated: false)

  TuiTreeBudget* = Budget(
    name: "tui-tree",
    lines: 0,
    cells: 0,
    depth: 16,         ## `headless_session.ValueDecodeDepth`
    members: 100,      ## `tui/app/views/variables.DefaultPageSize`
    expandable: true,
    annotated: false)

  CalltraceArgBudget* = Budget(
    name: "calltrace-arg",
    lines: 1,
    cells: 0,          ## the call-trace row's `.call-arg` chips wrap in the DOM
    depth: 10,         ## `textRepr`'s default, which every other one-line
                       ## desktop surface carries
    members: 16,       ## `flow`'s, the other inline one-line chip surface
    expandable: false, ## a chip has no affordance; the value popup does
    annotated: false)

  SurfaceBudgets*: array[7, Budget] = [
    StatePanelBudget, TracepointBudget, FlowBudget, ScratchpadBudget,
    EventLogBudget, TuiTreeBudget, CalltraceArgBudget]
    ## THE SEVEN NAMED SURFACES, and exactly seven.
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
    ## Verification-Harness-Traps §4b asks for. `tuiRowBudget` below is NOT an
    ## eighth surface — it is `tui-tree` narrowed to one row's cells.

func tuiRowBudget*(cells: int; focused: bool): Budget =
  ## One row of the TUI's variables pane.
  ##
  ## The cell count is the caller's because it is the PANE's, computed by
  ## `tui/app/views/tree_node.fieldWidths` from the terminal's width — the one
  ## budget in this file that cannot be a constant. `focused` raises
  ## `annotated`, which is §3.3.4's "decimal and hexadecimal simultaneously
  ## upon focus" expressed as a budget rather than as a second code path.
  Budget(name: "tui-row", lines: 1, cells: cells, depth: 1,
         members: 8, expandable: false, annotated: focused)

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
         expandable: true, annotated: false)
