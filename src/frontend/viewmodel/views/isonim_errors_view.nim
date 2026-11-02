## views/isonim_errors_view.nim
##
## IsoNim DOM-rendering view for the Errors / Problems panel.
##
## Renders a live, reactive DOM tree driven by ``ErrorsVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/errors.nim`` (the IsoNim view is the single source of
## truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure (matching the Playwright contract in
## ``src/tests/gui/page-objects/panes/build/problems-pane.ts``):
##
##   div.problems-panel
##     div.problems-header
##       div.problems-counts
##         div.problems-count-badge.problems-count-error      text reactive
##         div.problems-count-badge.problems-count-warning    text reactive
##         div.problems-count-badge                           text reactive
##       div.problems-controls
##         div.problems-filter-btn[.active]                   click→setFilter
##         ...
##         div.problems-filter-btn[.active]                   click→toggleGroupByFile
##     div#problems-list.problems-list
##       div.problems-empty                                   when no rows
##       OR div.problems-grouped > div.problems-file-group + rows
##       OR div.problems-row.problems-severity-{error|warning|info}
##         (one per visible problem; click → vm.jumpToProblem(p))
##
## The list body is reactive: an outer ``createRenderEffect`` tears it
## down and rebuilds it from the latest signal values whenever
## ``vm.visibleProblems`` or ``vm.groupByFile`` changes.  The header
## counts and filter-button modifiers update reactively via DSL
## attribute expressions because the macro emits per-attribute
## ``createRenderEffect``s automatically.

when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The DSL's calls on a `WebRenderer` resolve where the generic view is
  # instantiated; the overloads must be in scope there.
  import isonim/web/web_renderer

import ../store/types
import ../viewmodels/errors_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

# The words — a severity's icon and class, a row's location, the header's
# counts, the filter labels, the empty state — are the ViewModel's
# (`errors_vm`, PLAT-55), so the terminal and the GPUI window say exactly what
# this panel says.

proc filterBtnClass(vm: ErrorsVM; filter: ProblemFilterTag): string =
  ## Class for a filter button.  Active when the VM's filter matches.
  if vm.filter.val == filter:
    "problems-filter-btn active"
  else:
    "problems-filter-btn"

proc groupBtnClass(vm: ErrorsVM): string =
  ## Class for the group-by-file toggle.  Active when the toggle is on.
  if vm.groupByFile.val:
    "problems-filter-btn active"
  else:
    "problems-filter-btn"

proc problemRowClass(vm: ErrorsVM; p: BuildProblemLine;
                     masterIndex: int): string =
  ## Class for a single problem row.  Combines the row marker and
  ## severity modifier so the page-object's
  ## ``.problems-severity-error`` / ``-warning`` selectors match.
  ##
  ## The selected row additionally gets ``problems-row-selected``. Selection
  ## is compared BY MASTER INDEX, not by value: two diagnostics on the same
  ## line of the same file are equal as ``BuildProblemLine``s, and a
  ## value comparison would highlight both.
  result = "problems-row problems-severity-" & severityClassSuffix(p.severity)
  if masterIndex >= 0 and masterIndex == vm.selectedIndex.val:
    result &= " problems-row-selected"

proc iconClass(p: BuildProblemLine): string =
  ## Class for the per-row severity icon span.
  "problems-icon problems-icon-" & severityClassSuffix(p.severity)

proc onProblemClick(vm: ErrorsVM; problem: BuildProblemLine;
                    masterIndex: int): proc() =
  ## Closure factory so each row captures its own ``BuildProblemLine``.
  ## Without this each click handler would share the same loop variable
  ## reference.
  ##
  ## A click SELECTS the row as well as jumping, so that a subsequent
  ## `next error` continues from where the user clicked rather than from
  ## wherever the keyboard had last been — the two ways of moving through
  ## the list share one cursor.
  let captured = problem
  let capturedIndex = masterIndex
  result = proc() =
    vm.selectProblemIndex(capturedIndex)
    vm.jumpToProblem(captured)

proc onFilterClick(vm: ErrorsVM; filter: ProblemFilterTag): proc() =
  ## Closure factory so each filter button captures its own filter
  ## value.  Same DSL closure-sharing concern as ``onProblemClick``.
  let captured = filter
  result = proc() = vm.setFilter(captured)

proc renderProblemRow[R, N](r: R; vm: ErrorsVM; p: BuildProblemLine; masterIndex: int): N =
  ui(r):
    tdiv(role = "button", tabindex = "0", class = problemRowClass(vm, p, masterIndex),
         onclick = onProblemClick(vm, p, masterIndex)):
      tdiv(class = iconClass(p)):
        text severityIcon(p.severity)
      tdiv(class = "problems-path"):
        text p.path
      tdiv(class = "problems-location"):
        text locationText(p)
      tdiv(class = "problems-message"):
        text p.message

proc renderProblemsEmpty[R, N](r: R): N =
  ui(r):
    tdiv(class = "problems-empty"):
      text ProblemsEmptyText

proc renderGroupedProblemShell[R, N](r: R; headerText: string): N =
  ui(r):
    tdiv(class = "problems-file-group"):
      tdiv(class = "problems-file-header"):
        text headerText

proc renderProblemsGroupedRoot[R, N](r: R): N =
  ui(r):
    tdiv(class = "problems-grouped"):
      discard

proc renderErrorsShell[R, N](r: R; vm: ErrorsVM; rootClass: string; listContainer: var N): N =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "problems-header"):
        tdiv(class = "problems-counts"):
          tdiv(class = "problems-count-badge problems-count-error"):
            text errorBadgeText(vm)
          tdiv(class = "problems-count-badge problems-count-warning"):
            text warningBadgeText(vm)
          tdiv(class = "problems-count-badge"):
            text totalBadgeText(vm)
        # THE NAVIGATION ANNOUNCEMENT (EMT-D22.2 / D22.3).
        #
        # The repo has no status bar — the only `setStatus` in the tree is the
        # LSP client's private one — so rather than invent a surface this
        # feature cannot test, the announcement is painted here, in the pane
        # the message is about. `statusMessage` is empty until something is
        # announced, so this is blank in the ordinary case.
        tdiv(class = "problems-status"):
          text vm.statusMessage.val
        tdiv(class = "problems-controls"):
          tdiv(class = filterBtnClass(vm, pfAll),
               onclick = onFilterClick(vm, pfAll)):
            text ProblemFilterLabels[pfAll]
          tdiv(class = filterBtnClass(vm, pfErrors),
               onclick = onFilterClick(vm, pfErrors)):
            text ProblemFilterLabels[pfErrors]
          tdiv(class = filterBtnClass(vm, pfWarnings),
               onclick = onFilterClick(vm, pfWarnings)):
            text ProblemFilterLabels[pfWarnings]
          tdiv(class = groupBtnClass(vm),
               onclick = proc() = vm.toggleGroupByFile()):
            text GroupByFileLabel
      tdiv(ref = listContainer,
           id = "problems-list",
           class = "problems-list"):
        discard

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderErrorsPanel*[R, N](r: R; vm: ErrorsVM): N =
  ## The errors panel, under any renderer (Shared-DOM-Front-Ends D3),
  ## mounted on the desktop by `ui/panel_host`. The rows are rebuilt from
  ## `vm.visibleRefs` whenever it or the grouping changes.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild
  var listContainer: N

  let panel = renderErrorsShell[R, N](r, vm, "problems-panel isonim-problems",
                                    listContainer)

  createRenderEffect proc() =
    # The list is the ViewModel's (`errors_vm.displayRows`, the one the native
    # panes draw): the empty state, the rows, or each file's header followed
    # by its rows.
    let display = vm.displayRows()
    let problems = vm.problems.val
    r.clearChildren(listContainer)

    if display.len == 1 and display[0].kind == pdEmpty:
      r.appendChild(listContainer, renderProblemsEmpty[R, N](r))
      return

    if vm.groupByFile.val:
      let groupedNode = renderProblemsGroupedRoot[R, N](r)
      r.appendChild(listContainer, groupedNode)
      var groupNode: N
      for d in display:
        case d.kind
        of pdFileHeader:
          groupNode = renderGroupedProblemShell[R, N](r, d.text)
          r.appendChild(groupedNode, groupNode)
        of pdRow:
          r.appendChild(groupNode,
                        renderProblemRow[R, N](r, vm, problems[d.index], d.index))
        of pdEmpty:
          discard
    else:
      for d in display:
        if d.kind == pdRow:
          r.appendChild(listContainer,
                        renderProblemRow[R, N](r, vm, problems[d.index], d.index))

  panel
