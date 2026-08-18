## test_trace_redraw_policy.nim
##
## Headless unit tests for `src/frontend/ui/trace_redraw_policy.nim`.
##
## Regression target: issue #566 — "the tracepoint results table disappears
## after the first jump".
##
## The inline tracepoint grid is one of the few panels with no ViewModel of its
## own (`viewmodels/trace_log_vm.nim` is the separate *Trace Log* panel, not the
## in-editor view zone), so there was no headless layer at which the bug could
## be observed. The decision that actually regressed —
## "rebuild the tracepoint DOM, or refresh it in place?" — was an unconditional
## `refreshTraceViewZoneDom()` buried in `editorAfterRedraw`; extracting it into
## a pure policy makes it observable here, in microseconds, on both the native
## and the JS lane.
##
## What went wrong, in terms of these inputs: after the user clicked a result
## row, the DataTable itself emitted `CtTraceJump`, that produced a completed
## move, and `editorAfterRedraw` answered `traRebuild` for a tracepoint whose
## results DOM was still perfectly alive. The rebuild wipes
## `viewZone.domNode.innerHTML`, which detaches the `<table>` the live
## jQuery-DataTables instance holds a reference to — while leaving
## `dataTable.context` non-nil, so `renderTableResults` then refuses to build a
## replacement, and the `.chart-table` container stays `hidden`. The grid
## vanished rather than merely going blank.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_trace_redraw_policy.nim

import std/unittest

import ../../../../frontend/ui/trace_redraw_policy

suite "tracepoint redraw policy":

  test "a live results grid is refreshed in place, never rebuilt":
    # THE regression case (#566): expanded tracepoint, view zone present, and
    # the table the DataTables instance is bound to still in the document.
    # This is the state on *every* move after the tracepoint has been run —
    # including the very jump the grid's own row click emits.
    check traceRedrawAction(
      expanded = true,
      hasViewZone = true,
      resultsDomMounted = true) == traRefreshInPlace

  test "a missing results subtree is rebuilt":
    # First expansion, or Monaco replaced the view zone's DOM: there is nothing
    # to preserve, so building from scratch is correct.
    check traceRedrawAction(
      expanded = true,
      hasViewZone = true,
      resultsDomMounted = false) == traRebuild

  test "a collapsed tracepoint is left alone":
    check traceRedrawAction(
      expanded = false,
      hasViewZone = true,
      resultsDomMounted = true) == traSkip
    check traceRedrawAction(
      expanded = false,
      hasViewZone = true,
      resultsDomMounted = false) == traSkip
    check traceRedrawAction(
      expanded = false,
      hasViewZone = false,
      resultsDomMounted = false) == traSkip

  test "an expanded tracepoint with no view zone is left alone":
    # `refreshTraceViewZoneDom` returns immediately when `viewZone` is nil, and
    # there is no DOM to refresh either — answering anything but `traSkip`
    # would be busywork on a component that cannot render.
    check traceRedrawAction(
      expanded = true,
      hasViewZone = false,
      resultsDomMounted = false) == traSkip

  test "every input combination has a defined answer":
    # Guards against a future edit reintroducing an implicit fall-through.
    for expanded in [false, true]:
      for hasViewZone in [false, true]:
        for mounted in [false, true]:
          let action = traceRedrawAction(expanded, hasViewZone, mounted)
          if not expanded or not hasViewZone:
            check action == traSkip
          elif mounted:
            check action == traRefreshInPlace
          else:
            check action == traRebuild
