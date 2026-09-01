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

import std/tables

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/errors_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc severityClassSuffix(severity: BuildLineSeverity): string =
  ## CSS class suffix for the severity icon/row.  Mirrors the legacy
  ## ``severityClass`` proc in ``frontend/ui/errors.nim`` so the
  ## ``.problems-severity-error`` / ``-warning`` / ``-info`` selectors
  ## the page-object relies on keep matching.
  case severity
  of blsError:   "error"
  of blsWarning: "warning"
  of blsInfo:    "info"
  of blsNone:    "info"

proc severityIcon(severity: BuildLineSeverity): string =
  ## Unicode icon for a severity row.  Matches the glyphs the legacy
  ## ``severityIcon`` proc emitted (BLACK CIRCLE / WARNING SIGN /
  ## CIRCLED LATIN SMALL LETTER I).
  case severity
  of blsError:   "\xe2\x97\x8f"
  of blsWarning: "\xe2\x9a\xa0"
  of blsInfo:    "\xe2\x93\x98"
  of blsNone:    "\xe2\x93\x98"

proc locationText(p: BuildProblemLine): string =
  ## Format ``"line:col"`` or just ``"line"`` when ``col`` is unknown.
  ## Mirrors the legacy ``locationText`` proc.
  if p.col >= 0:
    $p.line & ":" & $p.col
  else:
    $p.line

proc errorBadgeText(vm: ErrorsVM): string =
  ## Header badge text for the error count.  Matches the legacy
  ## ``severityIcon(ProbError) & " " & $errorCount`` rendering.
  severityIcon(blsError) & " " & $vm.errorCount.val

proc warningBadgeText(vm: ErrorsVM): string =
  ## Header badge text for the warning count.
  severityIcon(blsWarning) & " " & $vm.warningCount.val

proc totalBadgeText(vm: ErrorsVM): string =
  ## Header badge text for the total count.  Matches the legacy
  ## ``"Total: " & $allProblems.len`` rendering.
  "Total: " & $vm.totalCount.val

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

template renderProblemRow(r, vm, p, masterIndex: untyped): untyped =
  ui(r):
    tdiv(class = problemRowClass(vm, p, masterIndex),
         onclick = onProblemClick(vm, p, masterIndex)):
      tdiv(class = iconClass(p)):
        text severityIcon(p.severity)
      tdiv(class = "problems-path"):
        text p.path
      tdiv(class = "problems-location"):
        text locationText(p)
      tdiv(class = "problems-message"):
        text p.message

template renderProblemsEmpty(r: untyped): untyped =
  ui(r):
    tdiv(class = "problems-empty"):
      text "No problems detected."

template renderGroupedProblemShell(r, headerText: untyped): untyped =
  ui(r):
    tdiv(class = "problems-file-group"):
      tdiv(class = "problems-file-header"):
        text headerText

template renderProblemsGroupedRoot(r: untyped): untyped =
  ui(r):
    tdiv(class = "problems-grouped"):
      discard

template renderErrorsShell(r, vm, rootClass, listContainer: untyped): untyped =
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
            text "All"
          tdiv(class = filterBtnClass(vm, pfErrors),
               onclick = onFilterClick(vm, pfErrors)):
            text "Errors"
          tdiv(class = filterBtnClass(vm, pfWarnings),
               onclick = onFilterClick(vm, pfWarnings)):
            text "Warnings"
          tdiv(class = groupBtnClass(vm),
               onclick = proc() = vm.toggleGroupByFile()):
            text "Group by File"
      tdiv(ref = listContainer,
           id = "problems-list",
           class = "problems-list"):
        discard

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderErrorsPanel*(r: MockRenderer; vm: ErrorsVM): MockNode =
  ## Render the errors panel for the Mock renderer.
  var listContainer: MockNode

  let panel = renderErrorsShell(r, vm, "problems-panel", listContainer)

  createRenderEffect proc() =
    let visible = vm.visibleRefs.val
    let grouped = vm.groupByFile.val
    r.clearChildren(listContainer)

    if visible.len == 0:
      r.appendChild(listContainer, renderProblemsEmpty(r))
      return

    if grouped:
      var order: seq[string] = @[]
      var groups: Table[string, seq[ProblemRef]]
      for i in 0 ..< visible.len:
        let entry = visible[i]
        let p = entry.problem
        if not groups.hasKey(p.path):
          groups[p.path] = @[]
          order.add(p.path)
        groups[p.path].add(entry)

      let groupedNode = renderProblemsGroupedRoot(r)
      r.appendChild(listContainer, groupedNode)
      for pathIndex in 0 ..< order.len:
        let pathStr = order[pathIndex]
        let rows = groups[pathStr]
        let header = pathStr & " (" & $rows.len & ")"
        let groupNode = renderGroupedProblemShell(r, header)
        r.appendChild(groupedNode, groupNode)
        for rowIndex in 0 ..< rows.len:
          let entry = rows[rowIndex]
          r.appendChild(groupNode,
                        renderProblemRow(r, vm, entry.problem, entry.index))
    else:
      for i in 0 ..< visible.len:
        let entry = visible[i]
        r.appendChild(listContainer,
                      renderProblemRow(r, vm, entry.problem, entry.index))

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderErrorsPanel*(r: WebRenderer; vm: ErrorsVM): isonim_dom.Element =
    ## Render the panel for the real DOM.
    var listContainer: isonim_dom.Element

    let panel = renderErrorsShell(r, vm, "problems-panel isonim-problems",
                                  listContainer)

    createRenderEffect proc() =
      let visible = vm.visibleRefs.val
      let grouped = vm.groupByFile.val
      r.clearChildren(listContainer)

      if visible.len == 0:
        r.appendChild(listContainer, renderProblemsEmpty(r))
        return

      if grouped:
        var order: seq[string] = @[]
        var groups: Table[string, seq[ProblemRef]]
        for i in 0 ..< visible.len:
          let entry = visible[i]
          let p = entry.problem
          if not groups.hasKey(p.path):
            groups[p.path] = @[]
            order.add(p.path)
          groups[p.path].add(entry)

        let groupedNode = renderProblemsGroupedRoot(r)
        r.appendChild(listContainer, groupedNode)
        for pathIndex in 0 ..< order.len:
          let pathStr = order[pathIndex]
          let rows = groups[pathStr]
          let header = pathStr & " (" & $rows.len & ")"
          let groupNode = renderGroupedProblemShell(r, header)
          r.appendChild(groupedNode, groupNode)
          for rowIndex in 0 ..< rows.len:
            let entry = rows[rowIndex]
            r.appendChild(groupNode,
                          renderProblemRow(r, vm, entry.problem, entry.index))
      else:
        for i in 0 ..< visible.len:
          let entry = visible[i]
          r.appendChild(listContainer,
                        renderProblemRow(r, vm, entry.problem, entry.index))

    panel

  proc mountIsoNimErrors*(container: isonim_dom.Element; vm: ErrorsVM) =
    ## Mount the IsoNim errors panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderErrorsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
