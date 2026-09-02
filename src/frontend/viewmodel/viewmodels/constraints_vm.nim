## ConstraintsVM — reactive state for the Constraints pane
## (`Content.Constraints`).
##
## The model is `common/noir_constraints.ConstraintReport`, which is shared
## with the index process rather than owned here: the desktop fills it by
## running `nargo info --json`, and the web build fills it from the counts the
## bundle carries for the template it ships. One parser, one shape, two
## sources — see that module's header for why the rows are per ACIR function
## and not the per-module roll-up §1a's picture draws.
##
## ## Staleness is a state, not an omission
##
## The counts describe a set of sources. The moment a visitor edits one they
## describe a project that no longer exists, and an unlabelled stale number is
## worse than no number because it is indistinguishable from a current one.
## `markStale` is the flag for that, and it is wired as far as the view: it sets
## `report.stale` without discarding the counts, and the `headline` memo runs
## `headlineFor`, which appends " (stale)".
##
## NOTHING CALLS IT. `markStale` occurs three times in the whole tree — its
## definition, one re-export in `ui/constraints.nim`, and this sentence. It has
## no call site, so the editor's change hook does not reach it and a visitor who
## edits a source still sees an unlabelled count: exactly the state the
## paragraph above calls worse than no number. What is missing is not the
## mechanism but the one call that decides when to use it.
##
## On a host that cannot recompute — a browser, today — being stale would be
## permanent until the sources are restored, which is why the pane is built to
## say so rather than show a spinner nothing will ever resolve.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../../common/noir_constraints

export noir_constraints

type
  ConstraintsVM* = ref object of ViewModel
    # -- Mutable state --
    report*: Signal[ConstraintReport]
    projectName*: Signal[string]

    # -- Derived state --
    hasReport*: Memo[bool]
    acirOpcodes*: Memo[int]
    unconstrainedOpcodes*: Memo[int]
    headline*: Memo[string]

proc setReport*(vm: ConstraintsVM; report: ConstraintReport) =
  vm.report.val = report

proc setAbsence*(vm: ConstraintsVM; reason: string) =
  vm.report.val = absentReport(reason)

proc markStale*(vm: ConstraintsVM; stale: bool) =
  ## Flag the counts as describing sources that have since changed. Does
  ## nothing to an absent report: "there are no counts" cannot become "the
  ## counts are old".
  var current = vm.report.val
  if current.absence.len > 0:
    return
  if current.stale == stale:
    return
  current.stale = stale
  vm.report.val = current

proc headlineFor*(report: ConstraintReport): string =
  ## The one line above the rows.
  if report.absence.len > 0:
    return "unavailable"
  if report.functions.len == 0:
    return "no circuit"
  let acir = report.acirTotal()
  let brillig = report.unconstrainedTotal()
  result = $acir & " ACIR opcode" & (if acir == 1: "" else: "s")
  if brillig > 0:
    result.add ", " & $brillig & " unconstrained"
  if report.stale:
    result.add " (stale)"

proc createConstraintsVM*(): ConstraintsVM =
  withViewModel proc(dispose: proc()): ConstraintsVM =
    let report = createSignal(absentReport(
      "No circuit has been compiled for this project yet."))
    let projectName = createSignal("")

    let hasReport = createMemo[bool] proc(): bool =
      report.val.hasCounts()

    let acirOpcodes = createMemo[int] proc(): int =
      report.val.acirTotal()

    let unconstrainedOpcodes = createMemo[int] proc(): int =
      report.val.unconstrainedTotal()

    let headline = createMemo[string] proc(): string =
      headlineFor(report.val)

    ConstraintsVM(
      report: report,
      projectName: projectName,
      hasReport: hasReport,
      acirOpcodes: acirOpcodes,
      unconstrainedOpcodes: unconstrainedOpcodes,
      headline: headline,
      disposeProc: dispose,
    )
