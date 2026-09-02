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
## ## Staleness is a state, and NOTHING CURRENTLY ENTERS IT
##
## The counts describe a set of sources. The moment a visitor edits one they
## describe a project that no longer exists, and an unlabelled stale number is
## worse than no number because it is indistinguishable from a current one.
## `markStale` and the `(stale)` suffix in `headlineFor` implement that.
##
## **`markStale` has no callers.** This header used to read "`markStale` is
## therefore called from the editor's change hook, and the view says so", which
## described a protocol neither end implements: there is no such call, in this
## module's own suite or anywhere in `src/`. The sentence is corrected rather
## than deleted because the mechanism is right and only the wiring is absent —
## and because a comment asserting a call that does not exist reads, in review,
## exactly like a call that does.
##
## ## Why it was not simply wired, which is a real question and not an oversight
##
## The two halves of this pane have DIFFERENT provenance, so "stale" means two
## different things and the wiring cannot be written until one is chosen:
##
##   * The COUNTS, on the web, come from `platform/noir_template`'s
##     `noirTemplateNargoInfoJson` — a compile-time constant measured against
##     the BUNDLED sources. After an edit these are not "stale" in the sense
##     the word implies. `(stale)` says *these were right a moment ago*; what
##     is actually true is that they describe a different program than the one
##     on screen, and always did once the visitor typed.
##   * The LISTING (`Generated-Code-Listing.md` §8) comes from a real compile
##     of the visitor's own sources, and its staleness IS temporal: it
##     describes the compile it came from, at the time it happened.
##
## `provenance` already carries which artefact a report describes. The open
## decision is whether it should also carry WHEN — and what an edit should do:
## mark stale and wait, or recompile. See `Generated-Code-Listing.md` §15.
##
## Note that once the listing comes from a `program`-mode compile, that same
## artefact yields the counts too: `nargo info`'s opcode total is the ACIR row
## count, measured equal at 17 on the bundled template. So the compile-time
## constant is not permanent, and the two staleness meanings collapse into one
## as soon as it goes.

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
