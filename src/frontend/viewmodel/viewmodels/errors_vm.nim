## viewmodels/errors_vm.nim
##
## ErrorsVM — ViewModel for the Errors / Problems panel.
##
## Holds reactive state for:
## - The list of structured ``BuildProblemLine`` rows surfaced to the
##   panel (one row per parsed compiler diagnostic).
## - The active severity filter (``ProblemFilterTag``).
## - The group-by-file toggle.
##
## Derives:
## - ``visibleProblems``: the ``problems`` list filtered by the active
##   ``filter`` value.  The view consumes this so the empty-state
##   overlay renders whenever the filter wipes every row out.
## - ``errorCount`` / ``warningCount``: severity tallies used by the
##   header count badges.
## - ``totalCount``: convenience alias for ``problems.val.len``.
##
## The VM has no auto-load effect: the legacy ``BuildComponent``
## already pushes problems into ``BuildVM.problems`` via
## ``appendProblem`` (and the bulk ``syncLegacyBuildIntoVM`` path); the
## errors module mirrors that signal into ``ErrorsVM.problems`` via the
## ``setProblems`` action.  Mirrors the contract of ``BuildVM`` itself —
## events arrive through the legacy mediator subscriptions; the VM is a
## platform-neutral facade so headless tests under
## ``src/tests/gui/tests/views/isonim_views_test.nim`` can drive the
## full reactive flow without needing the build pipeline.
##
## Usage::
##
##   let vm = createErrorsVM(store)
##   vm.setProblems(@[
##     BuildProblemLine(severity: blsError, path: "main.nim",
##                       line: 1, col: 1, message: "boom")])
##   echo vm.totalCount.val          # 1
##   echo vm.errorCount.val          # 1
##   vm.setFilter(pfWarnings)
##   echo vm.visibleProblems.val.len # 0
##
## When the user clicks a problem row the view calls
## ``vm.jumpToProblem(problem)`` which dispatches a ``ct/jump-location``
## request via the backend.  In production the legacy
## ``ErrorsComponent`` rendered an inline ``onclick = jumpLocation(loc)``
## closure; routing the click through the VM keeps the signal flow
## self-contained for headless tests.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  ErrorsVM* = ref object of ViewModel
    ## Reactive state for the Errors / Problems panel.
    ##
    ## Mutable signals:
    ##   problems       — every problem row produced by the build pipeline.
    ##   filter         — the active severity filter.
    ##   groupByFile    — whether the view should group rows by file path.
    ##
    ## Derived memos:
    ##   visibleProblems — ``problems`` filtered by ``filter``.
    ##   errorCount      — number of ``blsError`` rows in ``problems``.
    ##   warningCount    — number of ``blsWarning`` rows in ``problems``.
    ##   totalCount      — convenience: ``problems.val.len``.
    store*: ReplayDataStore

    # -- Mutable state --
    problems*: Signal[seq[BuildProblemLine]]
    filter*: Signal[ProblemFilterTag]
    groupByFile*: Signal[bool]

    # -- Derived state --
    visibleProblems*: Memo[seq[BuildProblemLine]]
    errorCount*: Memo[int]
    warningCount*: Memo[int]
    totalCount*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setProblems*(vm: ErrorsVM; problems: seq[BuildProblemLine]) =
  ## Replace the problem list wholesale.  Used by the legacy build
  ## pipeline's ``syncLegacyErrorsIntoVM`` after a bulk update; per-row
  ## updates flow through ``appendProblem`` instead.
  vm.problems.val = problems

proc appendProblem*(vm: ErrorsVM; problem: BuildProblemLine) =
  ## Append a single problem row.  Called by the legacy build pipeline
  ## whenever ``parseBuildLocation`` emits a structured diagnostic so
  ## the ``ErrorsVM`` mirrors the same data ``BuildVM.problems``
  ## carries without coupling the two view-models.
  var entries = vm.problems.val
  entries.add(problem)
  vm.problems.val = entries

proc clearProblems*(vm: ErrorsVM) =
  ## Reset the problem list.  The view re-displays the
  ## ``"No problems detected."`` empty-state overlay.
  vm.problems.val = @[]

proc setFilter*(vm: ErrorsVM; filter: ProblemFilterTag) =
  ## Set the active severity filter.  Memoed signals (``visibleProblems``)
  ## recompute automatically.
  vm.filter.val = filter

proc setGroupByFile*(vm: ErrorsVM; on: bool) =
  ## Toggle the group-by-file rendering mode.
  vm.groupByFile.val = on

proc toggleGroupByFile*(vm: ErrorsVM) =
  ## Flip the group-by-file rendering mode.
  vm.groupByFile.val = not vm.groupByFile.val

proc jumpToProblem*(vm: ErrorsVM; problem: BuildProblemLine) =
  ## Dispatch a jump-location request for the given problem.  The
  ## legacy view called ``jumpLocation(loc)`` directly; routing this
  ## via the backend keeps the signal flow self-contained for headless
  ## tests.  In production the legacy ``ErrorsComponent`` is no longer
  ## rendered, so the VM is the single source for jump dispatch.
  let args = %*{
    "path": problem.path,
    "line": problem.line,
  }
  discard vm.store.backend.send("ct/jump-location", args)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc severityCount(rows: seq[BuildProblemLine];
                   severity: BuildLineSeverity): int =
  ## Count the rows whose severity matches ``severity``.  Pulled out so
  ## both the ``errorCount`` / ``warningCount`` memos can share the
  ## traversal.
  for r in rows:
    if r.severity == severity:
      inc result

proc filterRows(rows: seq[BuildProblemLine];
                filter: ProblemFilterTag): seq[BuildProblemLine] =
  ## Return only the rows matching the active ``filter``.  Mirrors the
  ## legacy ``filterProblems`` proc.
  case filter
  of pfAll:
    return rows
  of pfErrors:
    for r in rows:
      if r.severity == blsError:
        result.add(r)
  of pfWarnings:
    for r in rows:
      if r.severity == blsWarning:
        result.add(r)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createErrorsVM*(store: ReplayDataStore): ErrorsVM =
  ## Create an ErrorsVM inside a reactive root owned by ``withViewModel``.
  ## The reactive root is disposed via ``vm.dispose()``.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults (no problems, ``pfAll``
  ##    filter, group-by-file off).
  ## 2. Derived memos for ``visibleProblems`` / ``errorCount`` /
  ##    ``warningCount`` / ``totalCount``.
  withViewModel proc(dispose: proc()): ErrorsVM =
    let problems = createSignal(newSeq[BuildProblemLine]())
    let filter = createSignal(pfAll)
    let groupByFile = createSignal(false)

    let visibleProblems = createMemo[seq[BuildProblemLine]] proc(): seq[BuildProblemLine] =
      filterRows(problems.val, filter.val)

    let errorCount = createMemo[int] proc(): int =
      severityCount(problems.val, blsError)

    let warningCount = createMemo[int] proc(): int =
      severityCount(problems.val, blsWarning)

    let totalCount = createMemo[int] proc(): int =
      problems.val.len

    ErrorsVM(
      store: store,
      problems: problems,
      filter: filter,
      groupByFile: groupByFile,
      visibleProblems: visibleProblems,
      errorCount: errorCount,
      warningCount: warningCount,
      totalCount: totalCount,
      disposeProc: dispose,
    )
