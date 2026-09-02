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
## ## Staleness is a state, and an edit is what enters it
##
## The counts describe a set of sources. The moment a visitor edits one they
## describe a project that no longer exists, and an unlabelled stale number is
## worse than no number because it is indistinguishable from a current one.
## `markStale` and the `(stale)` suffix in `headlineFor` implement that;
## `noteSourceEdited` is what calls them, and `ui/constraints
## .noteEditorSourceChanged` is what the editor's `onDidChangeContent` reaches
## to get here.
##
## THIS HEADER HAS BEEN WRONG IN BOTH DIRECTIONS, which is why the wiring is
## named above rather than described. It first read "`markStale` is therefore
## called from the editor's change hook, and the view says so", describing a
## protocol neither end implemented; that was corrected to "`markStale` has no
## callers", which was true and left the pane still never labelling anything.
## A sentence claiming a call that does not exist reads, in review, exactly
## like a call that does — so if the wiring is ever removed, this paragraph is
## the one to delete with it.
##
## ## What "stale" means here, given the counts have two provenances
##
## This was the open question that kept the wiring unwritten, and it is settled
## by defining the word against the SOURCE ON SCREEN rather than against time:
##
##   **`(stale)` means these counts do not describe the source now in the
##   editor.** Not "these were right a moment ago" — that reading is temporal
##   and only fits one of the two producers.
##
## Both producers then fit the one definition:
##
##   * The BUNDLE's counts (`platform/noir_template`'s
##     `noirTemplateNargoInfoJson`, sent by `ui/web_entry_surface` and parsed
##     at `ui_js.nim`'s first `setReport`) describe the sources as shipped.
##     They stop describing what is on screen the instant the visitor types.
##   * A COMPILE's counts (`reportFromAcirListing` over the ACIR listing that
##     compile emitted, via `noirConstraintsSink`) describe the sources as they
##     were at that compile. Same thing, later.
##
## Under that definition an edit invalidates either, identically, and the pane
## needs no second flag to say which kind of stale it is. `provenance` already
## says which artefact produced the number; `stale` says whether it still
## applies.
##
## ## THREE DECISIONS, because "add the call" is not the whole of it
##
## **1. Which events invalidate?** An edit to a file that can change what a
## compile would count — `.nr` sources and `Nargo.toml` — and nothing else.
## `editInvalidatesCounts` is that rule. A README or a `Prover.toml` (which
## carries witness inputs, not the circuit) leaves the counts describing the
## program on screen, and dimming them for it would train a reader to ignore
## the label. Programmatic edits are excluded one layer up: `editor.nim`'s
## `reloadChange` guard already distinguishes a visitor typing from a tab being
## reloaded, and a `setValue` during a reload must not mark anything stale.
##
## **2. What does the pane show while stale?** The counts, KEPT, labelled
## `(stale)` and dimmed — not cleared. Clearing would discard the last number
## the project actually had, which is still the best available answer to "how
## big is this circuit", and it would blank the pane on a keystroke. The label
## is what makes keeping it honest; §15's rule is that an unlabelled stale
## number is worse than none, not that a labelled one is.
##
## **3. Does an in-flight recompile clear the mark?** NO. It clears when a NEW
## REPORT LANDS and not a moment earlier — `setReport` writes a report whose
## `stale` is false, which is the only thing that unsets it. While a recompile
## is running the numbers on screen still describe the superseded sources, so
## clearing at dispatch would show an unlabelled stale count for exactly the
## seconds a compile takes: the failure mode this exists to prevent, reinstated
## in the window where the user is most likely to be watching. A compile that
## FAILS likewise leaves the mark set, which is correct for the same reason.
##
## ## WHAT THE REACHABILITY GUARD NOW SEES HERE, and what it does not
##
## `ci/test/frontend-reachability-guard.py` used to report `markStale` in
## bucket [B], "nothing reaches it at all". It no longer does — and that is NOT
## the guard confirming the wiring. `markStale`'s only caller is
## `noteSourceEdited`, in THIS module, so the guard moves it to bucket [C],
## "only its own module reaches it", which is not counted by default. A symbol
## propped up by an unreached sibling would move to exactly the same place.
##
## What makes the chain real is that the sibling IS reached: `ui/constraints`
## imports and calls `noteSourceEdited`. The guard cannot distinguish those two
## cases, so it is not the evidence for this fix.
## `tests/unit/test_constraints_stale_on_edit.nim` is: it starts from an edit
## and asserts the pane's painted headline changes.
##
## See `Generated-Code-Listing.md` §15.

import std/strutils

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
  ##
  ## Idempotent by the `current.stale == stale` guard, which is load-bearing
  ## rather than tidy: `noteSourceEdited` reaches this on EVERY KEYSTROKE, and
  ## without the guard each one would write the signal and re-run the pane's
  ## memos and render effect for a value that did not change.
  var current = vm.report.val
  if current.absence.len > 0:
    return
  if current.stale == stale:
    return
  current.stale = stale
  vm.report.val = current

proc editInvalidatesCounts*(path: string): bool =
  ## Whether editing `path` can change what the next compile would count.
  ##
  ## `.nr` sources and `Nargo.toml`. A Noir package's constraint count is a
  ## function of its circuit and its dependency set, and those two files are
  ## where both live.
  ##
  ## DELIBERATELY NOT "any file in the project". `Prover.toml` carries witness
  ## inputs, which change what a proof is ABOUT and not how big it is; a README
  ## changes nothing at all. Marking the counts stale for those would put the
  ## label on the pane during edits that cannot have invalidated anything, and
  ## a label that appears when nothing is wrong is one a reader learns to skip
  ## — which costs exactly the credibility this whole mechanism is for.
  ##
  ## Case-insensitive, and matched on the BASENAME for the manifest: the
  ## editor's tab names are project-relative (`src/main.nr`, `Nargo.toml`) but
  ## a workspace member's manifest is `crates/foo/Nargo.toml`, and both are the
  ## manifest of something that gets compiled.
  let lower = path.toLowerAscii()
  if lower.endsWith(".nr"):
    return true
  lower == "nargo.toml" or lower.endsWith("/nargo.toml")

proc noteSourceEdited*(vm: ConstraintsVM; path: string) =
  ## The editor's change hook, arriving. `path` is the edited file.
  ##
  ## THE CALLER THIS MODULE SPENT TWO HEADERS DESCRIBING. It is reached from
  ## `ui/constraints.noteEditorSourceChanged`, which `ui_js` installs into
  ## `ui/editor.editorSourceChangedHook`, which `initMonacoForEditor` fires
  ## from Monaco's `onDidChangeContent`.
  ##
  ## Takes the path rather than being a bare `invalidate()` so the RULE about
  ## which files matter is a pure function this module's suite can drive
  ## directly, instead of a condition buried in a `when defined(js)` closure
  ## no headless lane can reach.
  if not editInvalidatesCounts(path):
    return
  vm.markStale(true)

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
