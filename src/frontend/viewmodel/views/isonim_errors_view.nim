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

import std/[strutils, tables]

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

proc problemRowClass(p: BuildProblemLine): string =
  ## Class for a single problem row.  Combines the row marker and
  ## severity modifier so the page-object's
  ## ``.problems-severity-error`` / ``-warning`` selectors match.
  "problems-row problems-severity-" & severityClassSuffix(p.severity)

proc iconClass(p: BuildProblemLine): string =
  ## Class for the per-row severity icon span.
  "problems-icon problems-icon-" & severityClassSuffix(p.severity)

proc onProblemClick(vm: ErrorsVM; problem: BuildProblemLine): proc() =
  ## Closure factory so each row captures its own ``BuildProblemLine``.
  ## Without this each click handler would share the same loop variable
  ## reference.
  let captured = problem
  result = proc() = vm.jumpToProblem(captured)

proc onFilterClick(vm: ErrorsVM; filter: ProblemFilterTag): proc() =
  ## Closure factory so each filter button captures its own filter
  ## value.  Same DSL closure-sharing concern as ``onProblemClick``.
  let captured = filter
  result = proc() = vm.setFilter(captured)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderProblemRowMock(r: MockRenderer; vm: ErrorsVM;
                          problem: BuildProblemLine): MockNode =
  ## Render a single problem row for the Mock renderer.  Pulled out so
  ## the ``flat`` / ``grouped`` branches can share the same row markup.
  let p = problem
  let onClick = onProblemClick(vm, p)
  result = ui(r):
    tdiv(class = problemRowClass(p),
         onclick = onClick):
      tdiv(class = iconClass(p)):
        text severityIcon(p.severity)
      tdiv(class = "problems-path"):
        text p.path
      tdiv(class = "problems-location"):
        text locationText(p)
      tdiv(class = "problems-message"):
        text p.message

proc renderErrorsPanel*(r: MockRenderer; vm: ErrorsVM): MockNode =
  ## Render the errors panel for the Mock renderer.
  ##
  ## The header / controls section is built once via the DSL with
  ## reactive attributes (badge text, filter-button modifiers).  An
  ## outer ``createRenderEffect`` rebuilds the ``#problems-list`` body
  ## whenever ``vm.visibleProblems`` or ``vm.groupByFile`` changes — the
  ## same shape the build / terminal-output views use.
  var listContainer: MockNode

  let panel = ui(r):
    tdiv(class = "problems-panel"):
      tdiv(class = "problems-header"):
        tdiv(class = "problems-counts"):
          tdiv(class = "problems-count-badge problems-count-error"):
            text errorBadgeText(vm)
          tdiv(class = "problems-count-badge problems-count-warning"):
            text warningBadgeText(vm)
          tdiv(class = "problems-count-badge"):
            text totalBadgeText(vm)
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

  createRenderEffect proc() =
    let visible = vm.visibleProblems.val
    let grouped = vm.groupByFile.val
    r.clearChildren(listContainer)

    if visible.len == 0:
      let empty = ui(r):
        tdiv(class = "problems-empty"):
          text "No problems detected."
      r.appendChild(listContainer, empty)
      return

    if grouped:
      # Build a flat ordered list of (path, rows) groups, preserving
      # the order in which each path first appears.  Mirrors the
      # legacy ``groupByFilePath`` proc.
      var order: seq[string] = @[]
      var groups: Table[string, seq[BuildProblemLine]]
      for p in visible:
        if not groups.hasKey(p.path):
          groups[p.path] = @[]
          order.add(p.path)
        groups[p.path].add(p)

      let groupedNode = ui(r):
        tdiv(class = "problems-grouped"):
          discard
      r.appendChild(listContainer, groupedNode)
      for path in order:
        # Copy out into locals so the DSL closure captures owned
        # values rather than ``lent`` iterator views (Nim refuses to
        # capture lent references inside a closure).
        let pathStr = path
        let rows = groups[pathStr]
        let header = pathStr & " (" & $rows.len & ")"
        let groupNode = ui(r):
          tdiv(class = "problems-file-group"):
            tdiv(class = "problems-file-header"):
              text header
        r.appendChild(groupedNode, groupNode)
        for p in rows:
          let row = renderProblemRowMock(r, vm, p)
          r.appendChild(groupNode, row)
    else:
      for p in visible:
        let row = renderProblemRowMock(r, vm, p)
        r.appendChild(listContainer, row)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebProblemRow(vm: ErrorsVM;
                           problem: BuildProblemLine): isonim_dom.Element =
    ## Build a single problem row in the real DOM.  Click handler
    ## dispatches a jump request via the VM.
    let row = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(row, cstring"class", cstring(problemRowClass(problem)))

    let icon = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(icon, cstring"class", cstring(iconClass(problem)))
    icon.textContent = cstring(severityIcon(problem.severity))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(icon))

    let path = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(path, cstring"class", cstring"problems-path")
    path.textContent = cstring(problem.path)
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(path))

    let loc = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(loc, cstring"class", cstring"problems-location")
    loc.textContent = cstring(locationText(problem))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(loc))

    let msg = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(msg, cstring"class", cstring"problems-message")
    msg.textContent = cstring(problem.message)
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(msg))

    let handler = onProblemClick(vm, problem)
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) = handler())
    row

  proc renderErrorsPanel*(r: WebRenderer; vm: ErrorsVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  Uses ``textContent`` for
    ## per-row body fields because the legacy view used Karax ``text``
    ## nodes too — the message strings are not ANSI-decorated HTML.
    var listContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "problems-panel isonim-problems"):
        tdiv(class = "problems-header"):
          tdiv(class = "problems-counts"):
            tdiv(class = "problems-count-badge problems-count-error"):
              text errorBadgeText(vm)
            tdiv(class = "problems-count-badge problems-count-warning"):
              text warningBadgeText(vm)
            tdiv(class = "problems-count-badge"):
              text totalBadgeText(vm)
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

    createRenderEffect proc() =
      let visible = vm.visibleProblems.val
      let grouped = vm.groupByFile.val
      # Tear down the previous body.  IsoNim's reactive root cleans up
      # the closures attached to the discarded row nodes.
      let containerAsNode = isonim_dom.Node(listContainer)
      while not isonim_dom.isNodeNil(containerAsNode.firstChild):
        discard isonim_dom.removeChild(containerAsNode, containerAsNode.firstChild)

      if visible.len == 0:
        let empty = isonim_dom.createElement(isonim_dom.document, cstring"div")
        isonim_dom.setAttribute(empty, cstring"class", cstring"problems-empty")
        empty.textContent = cstring"No problems detected."
        isonim_dom.appendChild(isonim_dom.Node(listContainer),
                               isonim_dom.Node(empty))
        return

      if grouped:
        var order: seq[string] = @[]
        var groups: Table[string, seq[BuildProblemLine]]
        for p in visible:
          if not groups.hasKey(p.path):
            groups[p.path] = @[]
            order.add(p.path)
          groups[p.path].add(p)

        let groupedNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
        isonim_dom.setAttribute(groupedNode, cstring"class", cstring"problems-grouped")
        isonim_dom.appendChild(isonim_dom.Node(listContainer),
                               isonim_dom.Node(groupedNode))

        for path in order:
          let rows = groups[path]
          let groupNode = isonim_dom.createElement(isonim_dom.document, cstring"div")
          isonim_dom.setAttribute(groupNode, cstring"class", cstring"problems-file-group")
          let header = isonim_dom.createElement(isonim_dom.document, cstring"div")
          isonim_dom.setAttribute(header, cstring"class", cstring"problems-file-header")
          header.textContent = cstring(path & " (" & $rows.len & ")")
          isonim_dom.appendChild(isonim_dom.Node(groupNode),
                                 isonim_dom.Node(header))
          isonim_dom.appendChild(isonim_dom.Node(groupedNode),
                                 isonim_dom.Node(groupNode))
          for p in rows:
            let row = createWebProblemRow(vm, p)
            isonim_dom.appendChild(isonim_dom.Node(groupNode),
                                   isonim_dom.Node(row))
      else:
        for p in visible:
          let row = createWebProblemRow(vm, p)
          isonim_dom.appendChild(isonim_dom.Node(listContainer),
                                 isonim_dom.Node(row))

    panel

  proc mountIsoNimErrors*(container: isonim_dom.Element; vm: ErrorsVM) =
    ## Mount the IsoNim errors panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderErrorsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
