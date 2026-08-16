## Pure decision table for "what should a completed debugger move do to an
## already-expanded tracepoint's inline results grid?"
##
## This module deliberately has **no imports**: `ui/editor.nim` and
## `ui/trace.nim` are JS-only (karax, Monaco and jQuery-DataTables bindings),
## so the rule that decides whether to *rebuild* or merely *refresh* the
## tracepoint view-zone DOM could not be unit-tested at all while it lived
## inline in `editorAfterRedraw`. Everything here compiles on the C backend, so
## `src/frontend/viewmodel/tests/unit/test_trace_redraw_policy.nim` exercises it
## headlessly.
##
## Why the rule exists (issue #566)
## --------------------------------
## `editorAfterRedraw` used to call `refreshTraceViewZoneDom()` for *every*
## expanded tracepoint on *every* completed move. That proc wipes
## `viewZone.domNode.innerHTML` and re-creates the `<table id="trace-table-N">`
## element — but the live jQuery-DataTables instance stored in
## `TraceComponent.dataTable.context` still points at the *detached* table, and
## `renderTableResults` only builds a table when that context is nil. So after
## the very first jump (which the DataTable's own row click emits!) the grid was
## orphaned: a fresh, empty `<table>` in the DOM that nothing ever populated,
## inside a `.chart-table` container that is created `hidden` and only un-hidden
## by `refreshTrace`.
##
## The fix is to stop destroying a *live* subtree: when the results DOM is still
## mounted, refresh it in place instead of rebuilding it.

type
  TraceRedrawAction* = enum
    ## What a completed move should do with one tracepoint's inline results.
    traSkip
      ## The tracepoint is collapsed, or has no Monaco view zone to render
      ## into. Nothing to do — `refreshTraceViewZoneDom` would return early
      ## anyway, and touching the DataTable would be pointless work.
    traRebuild
      ## The view zone exists but its results subtree is gone (first expansion,
      ## or the zone's DOM was replaced by Monaco). Build the trace DOM from
      ## scratch, then re-create the DataTable against the new table element.
    traRefreshInPlace
      ## The results DOM — specifically the `<table>` the DataTables instance
      ## was constructed against — is still mounted. Leave it alone and only
      ## re-run the visibility / layout pass. This is the regressed case: it
      ## used to take the rebuild path and destroy a working grid.

proc traceRedrawAction*(expanded, hasViewZone, resultsDomMounted: bool): TraceRedrawAction =
  ## Decide what to do with one expanded tracepoint after a completed move.
  ##
  ## `resultsDomMounted` must mean "the element the DataTable instance is bound
  ## to is still in the document" — see `traceResultsDomMounted` in
  ## `ui/trace.nim`. It is passed separately from `hasViewZone` (rather than
  ## being derived from it) so this decision stays a pure function of observable
  ## facts and every combination is reachable from a test.
  if not expanded:
    traSkip
  elif not hasViewZone:
    traSkip
  elif resultsDomMounted:
    traRefreshInPlace
  else:
    traRebuild
