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
                                         paneEventLog, panePointList}
    ## The panes PLAT-21 expresses in the vocabulary. A CLOSED SET a test
    ## asserts, not a list a reader infers from which procs exist.

  PaneNativePanes*: set[PaneKind] = {paneEditor}
    ## The panes that are native views. See the header: this is PLAT-3's
    ## admission decision applied, not a shortcut.

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

proc variableRow(v: store_types.Variable; path: string;
                 budget: Budget; expanded: HashSet[string]): ViewNode =
  ## One variable, as a `Tree` node.
  ##
  ## The LABEL is `name = <the presenter's answer at this budget>`. See the
  ## header for why the value is in the label and why that is not filed as a
  ## GPUI gap.
  let rendered =
    if v.presented.isNil: v.value
    else: presentText(v.presented, budget)
  var children: seq[ViewNode] = @[]
  for c in v.children:
    children.add variableRow(c, path & "." & c.name, budget, expanded)
  viewTreeNode(path, v.name & " = " & rendered, children,
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
    cells.add @[$r.eventIndex, r.kind, r.value]
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
  of paneDebugControls, paneFlow, paneTimeline, paneSearch, paneScratchpad,
     paneShell, paneFileTree, paneBuildOutput:
    # NOT YET EXPRESSED, and reported rather than silently empty.
    #
    # PLAT-21's goal names five panes and these eight are not among them. Each
    # gets a `Text` saying so, which is PLAT-9's degradation rule — the layout
    # keeps the slot and the front-end renders a report — rather than a blank
    # region a reader would read as "this pane is broken".
    PaneView(
      pane: kind,
      root: viewText($kind & ".report",
        "the " & $kind & " pane is not yet expressed in PLAT-3's vocabulary"),
      entries: {pkText},
      report: "not expressed in the vocabulary (PLAT-21 covers five panes)")
