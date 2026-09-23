## frontend/view_vocabulary/pane_views.nim — PLAT-21 deliverable 1. **The
## debugger panes, written ONCE in PLAT-3's vocabulary.**
##
## PLAT-21: *"Each pane's view written once in PLAT-3's vocabulary, with the
## GPUI mapping alongside the existing terminal and web mappings"*, and
## *"the debugger panes — source, state, call trace, event log, tracepoints —
## rendered by GPUI from the same ViewModels the other two front-ends use"*.
##
## So this module takes the product's OWN ViewModels and answers `ViewNode`
## trees. It imports no renderer, contains no tag, no cell, no pixel and no
## `when defined(js)`: the three bindings in this directory are what turn what
## it returns into a terminal widget, a DOM element or an isonim-gpui element.
##
## ## WHY IT IS HERE AND NOT IN `src/common/view_vocabulary/`
##
## Because it reads ViewModels, and `src/common/view_vocabulary.nim`'s header
## states the property that makes the vocabulary useful: the package is pure and
## compilable where no front-end is checked out. A pane view is the first thing
## in this campaign that is both medium-independent AND product-specific, and
## `src/frontend/view_vocabulary/` — which already holds the two bindings — is
## where that belongs.
##
## ## THE SOURCE PANE IS A NATIVE VIEW, AND THAT IS NOT A GAP
##
## PLAT-3's admission test REFUSED `Editor`, `Timeline/scrubber` and
## `Frame viewer`, and recorded why in `admission.Rejections`: they pass the
## "both front-ends have one" half and fail the "can be specified without
## reference to a medium" half. PLAT-22 says the same thing from the other end —
## *"the editor is deliberately not a PLAT-3 vocabulary entry: it is a native
## view, the sanctioned escape, for the same reason the terminal's is"*.
##
## So `sourcePaneView` answers `vocabulary.nativeEscape`, which is PLAT-9's
## sanctioned form and which `portability.checkPortable` REFUSES — on purpose.
## The four expressible panes are portable and asserted to be; the source pane
## is declared per medium and asserted to be refused. A milestone that quietly
## rendered the source pane as a `Markdown` or a `List` of lines would be
## claiming the vocabulary covers an editor, which is the lowest-common-
## denominator drift PLAT-3's risk note exists against.
##
## ## WHAT EACH PANE IS, AND THE ONE THING THE VOCABULARY CANNOT SAY
##
##   state        `Tabs` over §3.3.4's three roots, plus a `Tree` of variables.
##   call trace   a `List`, one option per visible call line.
##   event log    a `Table`, one row per recorded event.
##   tracepoints  a `List`, one option per point.
##   source       a native view (above).
##
## **A VARIABLES PANE IS A TREE WITH COLUMNS AND THE VOCABULARY HAS NO SUCH
## ENTRY.** `Tree` carries one `label` per node; `Table` carries `columns` and
## `rows` and no hierarchy. Every one of the three front-ends draws the state
## panel as name / type / value columns under an expandable hierarchy, so the
## rendering here folds the value into the label — `name = value`. That is
## recorded as an OBSERVATION and NOT filed as a GPUI gap, because it is not one:
## the terminal and the web are equally short of it, so it is not evidence that
## the vocabulary encoded one front-end, which is the question PLAT-21 exists to
## answer. It is evidence that sixteen entries do not cover a debugger, which is
## a different (and older) statement, and `admission.nim` is where a seventeenth
## entry would have to earn its place.
##
## ## VALUES GO THROUGH PLAT-2'S PIPELINE, AT A BUDGET THE CALLER DECLARES
##
## PLAT-21 deliverable 2: *"Values rendered through PLAT-2's pipeline, with the
## GPUI surface declaring its own budget rather than truncating"*. Every
## variable's rendering below is `presentText(v.presented, budget)` — the
## presenter, at the budget the front-end passed — and there is no `[0 ..< n]`,
## no `&"…"` and no width in this file. `surfaces.GpuiPanelBudget` is what the
## GPUI front-end passes; `TuiTreeBudget` and `StatePanelBudget` are what the
## other two pass; and the cross-renderer suite drives all three at ONE budget
## to assert PLAT-2's purity requirement and at their OWN budgets to assert they
## are different.

import std/[options, sets, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/viewmodel as isonim_viewmodel

import store/types as store_types
import viewmodels/state_vm
import viewmodels/calltrace_vm
import viewmodels/event_log_vm
import viewmodels/point_list_vm
# PLAT-41 — the five newly expressed panes' ViewModels.
import viewmodels/debug_controls_vm
import viewmodels/flow_vm
import viewmodels/search_vm
import viewmodels/scratchpad_vm
import viewmodels/shell_vm

import headless_app/layout_model

import ../../common/view_vocabulary
import ../../common/value_presentation

type
  PaneView* = object
    ## One pane, as the vocabulary expresses it.
    ##
    ## `entries` and `report` are part of the VALUE rather than things a caller
    ## re-derives, for the reason `mappings.absentEntries` gives: three places
    ## saying "the state pane is a Tabs and a Tree" is where the fourth one
    ## drifts (Verification-Harness-Traps §14).
    pane*: PaneKind
    root*: ViewNode
    entries*: set[ViewKind]
      ## Every vocabulary entry this pane's tree uses, READ OUT OF the tree.
    report*: string
      ## Non-empty when the pane is rendering a REPORT rather than data — a
      ## session that has not launched, a pane whose producer has nothing.
      ## PLAT-9's rule: never a blank region.
    native*: string
      ## Non-empty when this pane is a native view rather than a vocabulary
      ## tree. Carries the medium it was declared for.

const
  PaneVocabularyPanes*: set[PaneKind] = {paneState, paneCalltrace,
                                         paneEventLog, panePointList,
                                         # PLAT-41 adds five.
                                         paneDebugControls, paneFlow,
                                         paneSearch, paneScratchpad, paneShell}
    ## The panes expressed in the vocabulary. A CLOSED SET a test asserts, not
    ## a list a reader infers from which procs exist.

  PaneNativePanes*: set[PaneKind] = {paneEditor,
                                     # PLAT-41 adds the second one.
                                     paneTimeline}
    ## The panes that are native views. See the header: this is PLAT-3's
    ## admission decision applied, not a shortcut. Both members are refused BY
    ## NAME in `admission.Rejections` — "Editor" and "Timeline / scrubber" —
    ## so this set is that table's consequence rather than a preference.

  PaneAcceptedExceptions*: set[PaneKind] = {paneFileTree, paneBuildOutput}
    ## **Panes this front-end deliberately does not draw, with the reason
    ## recorded at the dispatch arm.**
    ##
    ## A set rather than a comment so the claim is ASSERTABLE: PLAT-23 warns
    ## that an accepted exception *"must not become a way to close the gate
    ## without drawing anything"*, and the guard against that is a member here
    ## having to be justified out loud and counted against `PaneKind`, not a
    ## reader trusting that somebody thought about it.
    ##
    ## Both are edit-mode panes whose subject is the working tree, and the only
    ## session in scope is a replay one. See the dispatch arm.

  PaneAccountedFor*: set[PaneKind] =
    PaneVocabularyPanes + PaneNativePanes + PaneAcceptedExceptions
    ## **The identity PLAT-41 owes: every pane is in exactly one of the three.**
    ##
    ## Asserted in both directions against `PaneKind` — that this covers the
    ## enum, and that the three sets are pairwise disjoint. A pane in two of
    ## them would mean two answers to one question, and a pane in none would be
    ## the silent omission the accepted-exception rule exists to prevent.

  MaxTreeRows* = 200
    ## How many variables the state pane's tree offers at once.
    ##
    ## NOT a truncation of a VALUE — that is the budget's job and PLAT-2's
    ## boundary gate forbids doing it here. This is the number of ROWS, which
    ## is the pane's own paging question, and it is the same order as
    ## `StatePanelBudget.members` (200) so the two bounds cannot disagree by
    ## an order of magnitude without somebody noticing.

func entriesOf*(root: ViewNode): set[ViewKind] =
  ## Every entry a tree uses. One function, so `PaneView.entries` and any
  ## assertion over it ask the same question.
  for n in walk(root):
    result.incl n.kind

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

func stateTabOptions*(): seq[ViewOption] =
  ## §3.3.4's three roots, derived from `StateTab` rather than written out, so
  ## a fourth tab cannot arrive without appearing here.
  for t in StateTab:
    result.add ViewOption(id: $t, label: ($t)[2 .. ^1])

const VariableLabelSeparator* = ": "
  ## **The vocabulary's spelling of "this name has this value"**, named once so
  ## every medium draws the same row. It was ` = ` until PLAT-40, while the
  ## desktop's state pane draws `name:value` — so PLAT-39's screen reader,
  ## whose published row grammar splits on the first colon, read the desktop's
  ## state pane and found NO row it could parse in the native window's (its
  ## filed GAP 1). The desktop's shape is the one adopted: it is the shape a
  ## reader of either screen now parses with one rule.

proc variableLabel*(name, rendered: string): string =
  ## A variable row's label: its name, `VariableLabelSeparator`, the
  ## presenter's answer.
  name & VariableLabelSeparator & rendered

proc variableRow(v: store_types.Variable; path: string;
                 budget: Budget; expanded: HashSet[string]): ViewNode =
  ## One variable, as a `Tree` node.
  ##
  ## The LABEL is `variableLabel(name, <the presenter's answer at this
  ## budget>)`. See the
  ## header for why the value is in the label and why that is not filed as a
  ## GPUI gap.
  let rendered =
    if v.presented.isNil: v.value
    else: presentText(v.presented, budget)
  var children: seq[ViewNode] = @[]
  for c in v.children:
    children.add variableRow(c, path & "." & c.name, budget, expanded)
  viewTreeNode(path, variableLabel(v.name, rendered), children,
               expanded = path in expanded)

proc statePaneView*(vm: StateVM; budget: Budget): PaneView =
  ## The state panel: a `Tabs` over the three roots and a `Tree` of variables.
  result.pane = paneState
  if vm.isNil:
    result.report = "the state panel has no ViewModel; the session has not " &
                    "launched"
    result.root = viewText("state.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let tab = vm.activeTab.val
  let expanded = vm.expandedPaths.val
  let vars = vm.currentVariables.val
  var rows: seq[ViewNode] = @[]
  for i, v in vars:
    if i >= MaxTreeRows: break
    rows.add variableRow(v, v.name, budget, expanded)
  if rows.len == 0:
    result.report = "no variables at this position"
  let tree = viewTreeNode("state.root",
    (case tab
     of stLocals: "locals"
     of stGlobals: "globals"
     of stWatches: "watches") &
    (if result.report.len > 0: " — " & result.report else: ""),
    rows, expanded = true)
  # THE CURSOR IS DERIVED FROM `StateVM.selectedPath`, which is the signal the
  # terminal's `variables_binding.publishSelection` writes and the desktop's
  # state view reads. Deriving it from the pane's own index instead would make
  # the pane the owner of a cursor two other front-ends already agree on.
  let selected = vm.selectedPath.val
  var cursor = 0
  let visible = visibleRows(tree)
  for i, n in visible:
    if n.id == selected:
      cursor = i
      break
  tree.cursor = cursor
  let tabs = viewTabs("state.tabs", stateTabOptions(), selected = ord(tab))
  result.root = viewCollapsible("state", "State", @[tabs, tree],
                                expanded = true)
  result.entries = entriesOf(result.root)

# ---------------------------------------------------------------------------
# Call trace
# ---------------------------------------------------------------------------

proc calltracePaneView*(vm: CalltraceVM): PaneView =
  ## The call trace: a `List`, one option per visible call line.
  ##
  ## A `List` rather than a `Tree`, deliberately. `CalltraceVM` already answers
  ## `visibleLines` — the rows the pane's own expansion state says are showing —
  ## and `CallLine.depth` is carried per row. Re-deriving a hierarchy here from
  ## the depths would be a second expansion model beside the one the ViewModel
  ## owns, which is exactly the "two owners" `admission.nim` refused the
  ## split/dock container for.
  result.pane = paneCalltrace
  if vm.isNil:
    result.report = "the call trace has no ViewModel; the session has not " &
                    "launched"
    result.root = viewText("calltrace.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let lines = vm.visibleLines.val
  var options: seq[ViewOption] = @[]
  for line in lines:
    let label = repeat("  ", max(line.depth, 0)) &
      (if line.displayName.len > 0: line.displayName else: line.name)
    options.add ViewOption(id: $line.index, label: label)
  if options.len == 0:
    result.report = "no call trace has been loaded"
    result.root = viewText("calltrace.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let selected = vm.selectedEntry.val
  var highlight = 0
  if selected.isSome:
    for i, line in lines:
      if line.index == selected.get:
        highlight = i
        break
  result.root = viewList("calltrace", options, highlight = highlight)
  result.entries = entriesOf(result.root)

# ---------------------------------------------------------------------------
# Event log
# ---------------------------------------------------------------------------

const EventLogColumns* = @["#", "kind", "value"]
  ## The event log's columns. Named once; the pane and any assertion over it
  ## read the same list.

proc eventLogPaneView*(vm: EventLogVM): PaneView =
  ## The event log: a `Table`.
  ##
  ## A `Table` and not a `List` because the pane's cursor really is
  ## two-dimensional — `EventLogVM` carries `sortColumn` as well as
  ## `selectedRow`, so a column IS part of this pane's state.
  result.pane = paneEventLog
  if vm.isNil:
    result.report = "the event log has no ViewModel; the session has not " &
                    "launched"
    result.root = viewText("eventLog.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let rows = vm.eventRows.val
  if rows.len == 0:
    result.report = "no events have been loaded"
    result.root = viewText("eventLog.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var cells: seq[seq[string]] = @[]
  for r in rows:
    # The output's LINE TERMINATOR is not part of the text a cell shows: a
    # `print` arrives as `2 + 3 = 5\n`, and a cell holding the `\n` draws a
    # blank line under every event in a medium that honours it (PLAT-40
    # measured every row of the native window's event log double-spaced).
    cells.add @[$r.eventIndex, r.kind, r.value.strip(leading = false,
                                                     chars = {'\n', '\r'})]
  let table = viewTable("eventLog", EventLogColumns, cells)
  let selected = vm.selectedRow.val
  if selected.isSome and selected.get >= 0 and selected.get < cells.len:
    table.cursor = selected.get
  table.column = max(min(vm.sortColumn.val, EventLogColumns.high), 0)
  result.root = table
  result.entries = entriesOf(result.root)

# ---------------------------------------------------------------------------
# Tracepoints
# ---------------------------------------------------------------------------

proc tracepointsPaneView*(vm: PointListVM): PaneView =
  ## The tracepoint list: a `List`, one option per point.
  ##
  ## A point whose `line` is 0 could not be located, and `point_list_vm`'s own
  ## comment says a pane "must not offer it as a jump target". The vocabulary
  ## already has the word for that — a `ViewOption` is (identity, label,
  ## availability) — so an unlocated point is `disabled`, and
  ## `behaviour.nextEnabled` then skips it on every medium without any pane
  ## knowing why.
  result.pane = panePointList
  if vm.isNil:
    result.report = "the tracepoint list has no ViewModel; the session has " &
                    "not launched"
    result.root = viewText("pointList.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let points = vm.points.val
  if points.len == 0:
    result.report = "no tracepoint collections are active"
    result.root = viewText("pointList.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var options: seq[ViewOption] = @[]
  for i, p in points:
    options.add ViewOption(
      id: $i,
      label: p.kind & " " & p.label & " (" & p.path & ":" & $p.line & ")",
      disabled: p.line == 0)
  let selected = vm.selectedPoint.val
  var highlight = 0
  if selected.isSome and selected.get >= 0 and selected.get < options.len:
    highlight = selected.get
  result.root = viewList("pointList", options, highlight = highlight)
  result.entries = entriesOf(result.root)

# ===========================================================================
# PLAT-41 — the eight panes that had no view
# ===========================================================================
#
# **THE EIGHT DO NOT ALL GET THE SAME ANSWER, AND THAT IS THE MILESTONE'S
# WHOLE CONTENT.** Splitting them three ways is not a shortcut around writing
# eight views; it is what PLAT-3's own recorded decisions require, and writing
# eight vocabulary trees would have overturned two of them silently.
#
#   5 expressed here   debugControls, flow, search, scratchpad, shell
#   1 native escape    timeline  — PLAT-3 REJECTED "Timeline / scrubber" BY NAME
#   2 accepted except. fileTree, buildOutput — no replay ViewModel, by decision
#
# **WHY TIMELINE IS NOT A VOCABULARY TREE.** `admission.Rejections` refuses
# "Timeline / scrubber" in the same table that refuses the editor, and for a
# reason that does not soften: *"a scrubber's contract is continuous position
# within a range, and its usefulness is its resolution. A terminal's resolution
# is the number of columns it has; a pointer's is the number of pixels. An
# abstraction over both would have to pick one and lie to the other."* It even
# names the two implementations that exist deliberately —
# `tui/app/views/timeline_bar.nim` and `viewmodel/views/isonim_timeline_view.nim`.
# A `ProgressIndicator` here would be exactly the lie that table forbids: it
# would answer "position within a range" and drop the resolution, and every
# medium would read it as a scrubber it is not.
#
# **WHY DEBUG CONTROLS *IS* ONE, THOUGH "Toolbar / status bar" IS ALSO
# REJECTED.** That rejection refuses admitting a TOOLBAR ENTRY, and its own
# words are the reason this pane is fine without one: a toolbar is *"a
# container of Buttons and Texts with a position, and position is the
# layout's"*. `Button` and `Text` are both already in the vocabulary, and the
# position stays PLAT-4's. So this view adds no entry — it uses two that exist.
# Rendering the pane is not the same act as admitting a word for the pane.

proc debugControlsPaneView*(vm: DebugControlsVM): PaneView =
  ## The debugger's controls: a `Tree` of `Button`s and one `Text`.
  ##
  ## **THIS IS THE PANE PLAT-37's FRAME SHOWED AS AN APOLOGY.** Its captured
  ## window read *"the debugControls pane is not yet expressed in PLAT-3's
  ## vocabulary"*, which was true and is the sentence this proc deletes.
  ##
  ## Availability is read from the ViewModel's own memos rather than recomputed:
  ## `canStepForward` and friends already answer whether an operation is legal
  ## at this stop, so a `Button` carries `disabled` from them and every medium's
  ## focus order skips an illegal control without any pane knowing why. A view
  ## that re-derived "can I step" would be a second opinion about a question the
  ## ViewModel already answers (§30).
  result.pane = paneDebugControls
  if vm.isNil:
    result.report = "the debug controls have no ViewModel; the session has " &
                    "not launched"
    result.root = viewText("debugControls.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var children: seq[ViewNode] = @[]
  children.add viewButton("debugControls.stepBackward", "Step back",
                          disabled = not vm.canStepBackward.val)
  children.add viewButton("debugControls.stepForward", "Step forward",
                          disabled = not vm.canStepForward.val)
  children.add viewButton("debugControls.reverseContinue", "Reverse continue",
                          disabled = not vm.canReverseContinue.val)
  children.add viewButton("debugControls.continue", "Continue",
                          disabled = not vm.canContinue.val)
  children.add viewText("debugControls.status", vm.statusText.val)
  result.root = viewTreeNode("debugControls", "Debug controls", children)
  result.entries = entriesOf(result.root)

proc flowPaneView*(vm: FlowVM): PaneView =
  ## Flow: a `Table`, one row per recorded step.
  ##
  ## A `Table` because a flow step is four fields the reader compares across
  ## rows — where it was, what it evaluated, and the value before and after —
  ## and comparing down a column is the whole point of the pane.
  ##
  ## `loadingState` is consulted BEFORE the row count, and the order matters:
  ## "still loading" and "loaded, and there is nothing" are different facts and
  ## a pane that reported both as "no steps" would be the two-empties collapse
  ## PLAT-23 measured (`locals=0` and `locals=8` on one step).
  result.pane = paneFlow
  if vm.isNil:
    result.report = "flow has no ViewModel; the session has not launched"
    result.root = viewText("flow.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let steps = vm.steps.val
  if steps.len == 0:
    result.report =
      if vm.loadingState.val == lsLoading: "flow is still loading"
      else: "no flow steps have been loaded"
    result.root = viewText("flow.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var cells: seq[seq[string]] = @[]
  for s in steps:
    cells.add @[$s.step, s.location, s.expression, s.beforeValue, s.afterValue]
  let table = viewTable("flow",
    @["step", "location", "expression", "before", "after"], cells)
  let hovered = vm.hoveredStep.val
  if hovered.isSome and hovered.get >= 0 and hovered.get < cells.len:
    table.cursor = hovered.get
  result.root = table
  result.entries = entriesOf(result.root)

proc searchPaneView*(vm: SearchVM): PaneView =
  ## Search: a `Tree` of the query `Input` and a `List` of results.
  ##
  ## The query is an `Input` rather than a `Text` because it is the pane's
  ## editable state — `SearchVM.query` is a `Signal[string]` a reader types
  ## into — and the vocabulary distinguishes a reading from a control. A result
  ## is a `ViewOption`, which is (identity, label, availability): the identity
  ## is what a caller acts on, so a medium does not have to parse the label
  ## back into a location.
  result.pane = paneSearch
  if vm.isNil:
    result.report = "search has no ViewModel; the session has not launched"
    result.root = viewText("search.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var children: seq[ViewNode] = @[]
  children.add viewInput("search.query", vm.query.val)
  var options: seq[ViewOption] = @[]
  for i, r in vm.results.val:
    options.add ViewOption(id: "search.result." & $i,
                           label: (if r.detail.len > 0: r.label & " — " & r.detail
                                   else: r.label))
  let list = viewList("search.results", options)
  let sel = vm.selectedResult.val
  if sel.isSome and sel.get >= 0 and sel.get < options.len:
    list.cursor = sel.get
  children.add list
  result.root = viewTreeNode("search", "Search", children)
  result.entries = entriesOf(result.root)
  if options.len == 0:
    result.report = "no search results"

proc scratchpadPaneView*(vm: ScratchpadVM): PaneView =
  ## The scratchpad: a `Table` of pinned expressions and their values.
  ##
  ## A `Table` rather than a `List` because a pinned value is genuinely two
  ## fields — the expression a reader pinned and the value it had — and a list
  ## of "expr = value" strings would make every medium parse the label back
  ## apart to render two columns.
  result.pane = paneScratchpad
  if vm.isNil:
    result.report = "the scratchpad has no ViewModel; the session has not " &
                    "launched"
    result.root = viewText("scratchpad.report", result.report)
    result.entries = entriesOf(result.root)
    return
  let entries = vm.entries.val
  if entries.len == 0:
    result.report = "no values have been pinned to the scratchpad"
    result.root = viewText("scratchpad.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var cells: seq[seq[string]] = @[]
  for e in entries:
    cells.add @[e.expression, e.valueText]
  result.root = viewTable("scratchpad", @["expression", "value"], cells)
  result.entries = entriesOf(result.root)

proc shellPaneView*(vm: ShellVM): PaneView =
  ## The shell: a `Tree` of the input `Input` and a `List` of history.
  ##
  ## **IT IS HISTORY AND NOT A TRANSCRIPT, BECAUSE THAT IS WHAT THE VIEWMODEL
  ## HAS.** `ShellVM` carries `inputBuffer`, `inputHistory`, `historyIndex` and
  ## `scrollPosition` — and no output. A view that drew an output pane would be
  ## drawing a field nothing fills, which is the well-formed apology this
  ## milestone exists to delete, one level further in. The absence is recorded
  ## in `result.report` rather than papered over with an empty box.
  result.pane = paneShell
  if vm.isNil:
    result.report = "the shell has no ViewModel; the session has not launched"
    result.root = viewText("shell.report", result.report)
    result.entries = entriesOf(result.root)
    return
  var children: seq[ViewNode] = @[]
  children.add viewInput("shell.input", vm.inputBuffer.val)
  var options: seq[ViewOption] = @[]
  for i, h in vm.inputHistory.val:
    options.add ViewOption(id: "shell.history." & $i, label: h)
  let list = viewList("shell.history", options)
  let idx = vm.historyIndex.val
  if idx >= 0 and idx < options.len:
    list.cursor = idx
  children.add list
  result.root = viewTreeNode("shell", "Shell", children)
  result.entries = entriesOf(result.root)
  result.report = "the shell ViewModel carries input and history and no " &
                  "output; this pane shows what exists"

# ---------------------------------------------------------------------------
# Timeline — the SECOND sanctioned native escape
# ---------------------------------------------------------------------------

proc timelinePaneView*(medium: string): PaneView =
  ## The timeline, declared for ONE medium. See the PLAT-41 block above.
  ##
  ## This is `sourcePaneView`'s shape for `admission.Rejections`' second
  ## refusal, and it is a deliberate REFUSAL to express rather than a gap:
  ## `portability.checkPortable` rejects a native escape on purpose, so the
  ## suite asserts this pane is refused exactly as it asserts the other six are
  ## portable.
  result.pane = paneTimeline
  result.native = medium
  result.root = nativeEscape("timeline", medium, "timeline")
  result.entries = entriesOf(result.root)
  result.report = "the timeline is a native view; PLAT-3's admission test " &
                  "refused a Timeline/scrubber entry because a scrubber's " &
                  "usefulness is its resolution and no abstraction over a " &
                  "column and a pixel can keep both"

# ---------------------------------------------------------------------------
# Source — the sanctioned native escape
# ---------------------------------------------------------------------------

proc sourcePaneView*(medium: string): PaneView =
  ## The source pane, declared for ONE medium. See the header.
  result.pane = paneEditor
  result.native = medium
  result.root = nativeEscape("source", medium, "editor")
  result.entries = entriesOf(result.root)
  result.report = "the source pane is a native view; PLAT-3's admission test " &
                  "refused an Editor entry and PLAT-22 owns the GPUI one"

# ---------------------------------------------------------------------------
# The one door
# ---------------------------------------------------------------------------

proc paneView*(kind: PaneKind; vm: ViewModel; budget: Budget;
               medium: string): PaneView =
  ## **The ONE entry point a front-end calls.**
  ##
  ## Exhaustive over `PaneKind` with no `else`, for `headless_app.paneViewModel`'s
  ## own reason: a pane added to the enum without a view is a name nothing
  ## renders, and the compiler is what says so.
  case kind
  of paneState: statePaneView(StateVM(vm), budget)
  of paneCalltrace: calltracePaneView(CalltraceVM(vm))
  of paneEventLog: eventLogPaneView(EventLogVM(vm))
  of panePointList: tracepointsPaneView(PointListVM(vm))
  of paneEditor: sourcePaneView(medium)
  # PLAT-41 — five newly expressed.
  of paneDebugControls: debugControlsPaneView(DebugControlsVM(vm))
  of paneFlow: flowPaneView(FlowVM(vm))
  of paneSearch: searchPaneView(SearchVM(vm))
  of paneScratchpad: scratchpadPaneView(ScratchpadVM(vm))
  of paneShell: shellPaneView(ShellVM(vm))
  # PLAT-41 — the second sanctioned native escape.
  of paneTimeline: timelinePaneView(medium)
  # PLAT-41 — the two ACCEPTED EXCEPTIONS, named with their reason.
  of paneFileTree, paneBuildOutput:
    # **AN ACCEPTED EXCEPTION, NAMED, WITH THE REASON — NOT A SILENT OMISSION.**
    #
    # These two are the only `PaneKind` values with no ViewModel, and that is a
    # DECISION rather than a gap. `headless_app.paneViewModel` has an arm for
    # them which returns `nil` under a comment in capitals, and the argument it
    # makes is the one accepted here: a `HeadlessSessionSlot` is a REPLAY
    # session, while these two are EDIT-MODE panes whose subject is the working
    # tree. Wiring `FilesystemVM` — which exists — to `paneFileTree` *"would
    # mean claiming a replay session owns the working tree, which is the
    # provenance confusion §2's whole table exists to keep apart."*
    #
    # PLAT-41 had to either accept that argument or refute it in writing, and
    # may not quietly wire what that comment refuses. **It is accepted**, for a
    # reason its own text gives: the panes are not unexpressible and no
    # vocabulary entry is missing for them — a file tree is a `Tree` and build
    # output is a `Table` or a `Text`, all of which exist. What is missing is a
    # SOURCE, and the only source in scope here is the wrong one. Expressing
    # them from a replay slot would draw a working tree that the session has no
    # claim to, which is worse than drawing nothing: it would be confidently
    # wrong rather than visibly absent.
    #
    # The remedy is named so this does not read as permanent: an EDIT-MODE
    # session owns these, and the pane views can be written the day one exists
    # to ask. Until then the report says which, and `PaneAcceptedExceptions`
    # below makes the set assertable rather than inferable from this comment.
    PaneView(
      pane: kind,
      root: viewText($kind & ".report",
        "the " & $kind & " pane is an edit-mode view; a replay session does " &
        "not own the working tree and will not claim to"),
      entries: {pkText},
      report: "accepted exception: edit-mode pane, no replay-session source")
