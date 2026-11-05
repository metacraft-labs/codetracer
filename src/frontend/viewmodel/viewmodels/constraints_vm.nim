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
##
## ## The rows, and where each one is written (PLAT-62)
##
## The pane is drawn by three front-ends — the desktop's view, the terminal's
## pane and the GPUI window's leaf — and each used to decide its own rows from
## the report. They are decided HERE now: `rows` is the list in display
## order (each function's row, then its printed opcodes when the report has
## a listing), and every row carries its LINK TO SOURCE — the line that
## declares the function the compiler named, or the reason there is none.
##
## The link is computed from the project's own sources (`setSources`) by the
## parser test discovery uses (`noir_test_syntax.noirFunctionDeclarations`),
## and it refuses rather than guesses (`linkFunction`):
##
##   * `nargo info` names a function as its source does — `main`, `halve` —
##     so a name declared exactly once is placed on that line;
##   * a name declared more than once is placed nowhere, with the count,
##     because the report does not say which one it compiled — except `main`,
##     which is the crate root's (`src/main.nr`);
##   * a `directive_*` function is one the compiler generated, and no source
##     in the project declares it;
##   * a listing's `func N` numbers a circuit and does not name a function,
##     so it is not placed;
##   * an opcode is placed where the compile's debug symbols say it came from,
##     the innermost frame in the project's own sources
##     (`constraints_listing.placeOpcodes`), or says why it is not.
##
## A row's activation (a press, Enter, the menu's Go to Source) goes through
## `activateRow`, which calls the host's `onOpenSource` with the
## project-relative path and line; the host opens it in its editor. The
## row menu (`rowMenu` / `runRowMenu`) is the same on every front-end.

import std/strutils

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../../common/noir_constraints
from ../../../ct_test/frameworks/noir_test_syntax import NoirSourceFile,
  NoirFnDecl, noirFunctionDeclarations
from ./constraints_listing import OpcodeHasNoSourceReason

export noir_constraints
export NoirSourceFile, NoirFnDecl
export OpcodeHasNoSourceReason

type
  ConstraintSourceLink* = object
    ## Where a row is written in the project, or why it is not placed.
    linked*: bool
    path*: string
      ## Project-relative, `/`-separated; "" when not linked.
    line*: int
      ## 1-based; 0 when not linked.
    column*: int
    reason*: string
      ## Why the row has no source; "" when linked.

  ConstraintRowKind* = enum
    crkFunction = "function"
      ## A function `nargo info` (or the listing) names, with its count.
    crkOpcode = "opcode"
      ## One printed opcode of a function's listing.

  ConstraintRow* = object
    ## One row of the pane, as every front-end draws it.
    kind*: ConstraintRowKind
    function*: int
      ## The function's index in `report.functions`.
    opcode*: int
      ## crkOpcode: the opcode's index in its function's `rows`; -1 otherwise.
    name*: string
      ## The function's name, or the opcode's name.
    kindLabel*: string
      ## crkFunction: `acir` or `unconstrained`; "" for an opcode.
    count*: string
      ## crkFunction: its opcode count; crkOpcode: the opcode's index.
    args*: string
      ## crkOpcode: the opcode's operands, verbatim; "" otherwise.
    source*: ConstraintSourceLink

  ConstraintMenuAction* = enum
    cmGoToSource = "go-to-source"
    cmCopyName = "copy-name"
    cmCopySourceLocation = "copy-source-location"

  ConstraintMenuEntry* = object
    label*: string
    action*: ConstraintMenuAction
    enabled*: bool
    reason*: string
      ## Why a disabled entry is disabled.

  ConstraintActivation* = object
    ## What activating a row did.
    opened*: bool
      ## The host was asked to open the row's source.
    path*: string
    line*: int
    reason*: string
      ## Why nothing opened ("" when it did).

  ConstraintMenuOutcome* = object
    done*: bool
      ## The entry ran (false for a disabled one, or no such row).
    activation*: ConstraintActivation
      ## cmGoToSource.
    copied*: string
      ## cmCopyName / cmCopySourceLocation: the text for the clipboard.

  ConstraintOpenSource* = proc(path: string; line, column: int) {.closure.}
    ## The host's "open this project-relative file at this line".

  ConstraintsVM* = ref object of ViewModel
    # -- Mutable state --
    report*: Signal[ConstraintReport]
    projectName*: Signal[string]
    sources*: Signal[seq[NoirSourceFile]]
      ## The project's `.nr` sources under `src/`, by project-relative path —
      ## what the rows are placed against (`setSources`).
    selected*: Signal[int]
      ## The selected row's index in `rows`, -1 for none. The cursor a press,
      ## the list keys and the menu share.

    # -- Derived state --
    hasReport*: Memo[bool]
    acirOpcodes*: Memo[int]
    unconstrainedOpcodes*: Memo[int]
    headline*: Memo[string]
    rows*: Memo[seq[ConstraintRow]]
      ## The pane's rows in display order, each with its link to source.

    # -- Host --
    onOpenSource*: ConstraintOpenSource
      ## Installed by the host; nil when it cannot open files.

const
  GoToSourceLabel* = "Go to Source"
  CopyNameLabel* = "Copy Name"
  CopySourceLocationLabel* = "Copy Source Location"
  ConstraintsCommandVerb* = "constraints"
    ## `:constraints` — shows the pane (the terminal's command line, the GPUI
    ## window's omnibox).
  NumberedCircuitReason* =
    "the listing numbers this circuit; it does not name the source " &
    "function it was compiled from"
  DirectiveReason* =
    "the compiler generated this function (a directive); no source in the " &
    "project declares it"
  NoSourcesReason* = "the project's sources have not been read"
  CannotOpenReason* = "this window cannot open files"

const NoCircuitCompiledYet = "No circuit has been compiled for this project yet."
  ## What the pane says before anything has reported on a circuit: a fresh
  ## VM's report.

proc setReport*(vm: ConstraintsVM; report: ConstraintReport) =
  vm.report.val = report

proc setSources*(vm: ConstraintsVM; files: seq[NoirSourceFile]) =
  ## The project's sources the rows are placed against. The host reads them
  ## where it measures the circuit, so a report and its links describe the
  ## same files.
  vm.sources.val = files

proc setAbsence*(vm: ConstraintsVM; reason: string) =
  vm.report.val = absentReport(reason)

proc noteListingUnavailable*(vm: ConstraintsVM; reason: string) =
  ## A compile SUCCEEDED but emitted no constraint listing.
  ##
  ## ## What this replaces, and why it is not a refinement
  ##
  ## The sink used to call `setAbsence` here, which replaces the whole report.
  ## Measured against the live deployment on 2026-09-03: the pane opened
  ## showing `17 ACIR opcodes, 17 unconstrained` with three named rows, and
  ## pressing BUILD replaced all of it with the single word `unavailable`. A
  ## user's gesture DESTROYED correct information and put nothing in its place
  ## — the counts had not become wrong, and the compile had not failed.
  ##
  ## That is the shipped engine's state and not a rare one:
  ## `ci/deploy/noir-wasm.pin` is a revision that predates
  ## `VfsResponse.acir_listing`, so EVERY build on the live site takes this
  ## path. The absence was correct about the listing and wrong about
  ## everything else in the pane.
  ##
  ## So the counts are KEPT and the reason is stated beside them. This is
  ## decision 2 above applied to a second cause: a report that is partly
  ## available is shown partly, labelled, rather than discarded whole. An
  ## absence remains an absence — if there were no counts to begin with, there
  ## are none now, and `absentReport` is still what says so.
  var current = vm.report.val
  if current.absence.len > 0 or current.functions.len == 0:
    vm.report.val = absentReport(reason)
    return
  current.listingAbsence = reason
  vm.report.val = current

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

proc listingNoticeFor*(report: ConstraintReport): string =
  ## The line that appears when the pane has counts but NO rows, and "" when
  ## there is nothing to explain.
  ##
  ## THIS IS THE STATE THE LIVE SITE IS ACTUALLY IN, and it is why this notice
  ## exists rather than an empty listing body. The bundled report comes from
  ## `nargo info`, which prints totals and no opcodes at all, so there is
  ## genuinely nothing to list until something compiles. A pane that rendered a
  ## blank listing area for that would look broken; one that says which of the
  ## two answers it is holding is merely honest about a real difference.
  if report.absence.len > 0:
    return ""
  if report.functions.len == 0:
    return ""
  if report.hasListing():
    return ""
  # WHAT THE PANE WAS TOLD BEATS WHAT IT CAN INFER. A compile that succeeded
  # without emitting a listing knows why; the default sentence below is a
  # guess that would be wrong in exactly that case, and wrong in the
  # reassuring direction — it would tell a user to press Build when Build is
  # what had just failed to produce a listing.
  if report.listingAbsence.len > 0:
    return report.listingAbsence
  "Totals only. Build the project to see the generated opcodes themselves."

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

# ---------------------------------------------------------------------------
# Links to source
# ---------------------------------------------------------------------------

proc unlinked(reason: string): ConstraintSourceLink =
  ConstraintSourceLink(linked: false, reason: reason)

proc linkFunction*(fn: ConstraintFunction;
                   decls: seq[NoirFnDecl]): ConstraintSourceLink =
  ## Where `fn` is written, from the project's declarations — or why it is
  ## placed nowhere. See the header for the rules; each refuses rather than
  ## guesses, because a row that opens the wrong line is worse than one that
  ## says it has none.
  if fn.kind == cfkAcir and fn.name.startsWith("func "):
    return unlinked(NumberedCircuitReason)
  var found: seq[NoirFnDecl] = @[]
  for d in decls:
    if d.name == fn.name and not d.isTest:
      found.add d
  if found.len == 0:
    if fn.name.startsWith("directive_"):
      return unlinked(DirectiveReason)
    return unlinked("no function named " & fn.name &
                    " is declared in this project's sources")
  var pick = -1
  if found.len == 1:
    pick = 0
  elif fn.name == "main":
    # The program's entry point is the crate root's `main`.
    for i, d in found:
      if d.path == "src/main.nr":
        pick = i
  if pick < 0:
    return unlinked($found.len & " functions in this project are named " &
                    fn.name & ", and the report does not say which one " &
                    "this is")
  ConstraintSourceLink(linked: true, path: found[pick].path,
                       line: found[pick].line, column: found[pick].column)

proc linksFor*(report: ConstraintReport;
               sources: seq[NoirSourceFile]): seq[ConstraintSourceLink] =
  ## Every function's link, in `report.functions` order.
  if sources.len == 0:
    for _ in report.functions:
      result.add unlinked(NoSourcesReason)
    return
  let decls = noirFunctionDeclarations(sources)
  for fn in report.functions:
    result.add linkFunction(fn, decls)

proc linkOpcode*(place: ConstraintOpcodePlace): ConstraintSourceLink =
  ## Where a printed opcode came from, or why it is placed nowhere: a report no
  ## artefact was read for has said nothing about its opcodes yet.
  if place.placed:
    return ConstraintSourceLink(linked: true, path: place.path,
                                line: place.line, column: place.column)
  unlinked(if place.reason.len > 0: place.reason
           else: OpcodeHasNoSourceReason)

proc whereText*(link: ConstraintSourceLink): string =
  ## `src/main.nr:3`, or "" for a row placed nowhere.
  if link.linked: link.path & ":" & $link.line else: ""

proc kindLabelOf*(kind: ConstraintFunctionKind): string =
  case kind
  of cfkAcir: "acir"
  of cfkUnconstrained: "unconstrained"

proc rowsFor*(report: ConstraintReport;
              sources: seq[NoirSourceFile]): seq[ConstraintRow] =
  ## The pane's rows in display order: each function's row, then its printed
  ## opcodes. None for an absent report.
  if report.absence.len > 0:
    return @[]
  let links = linksFor(report, sources)
  for f, fn in report.functions:
    result.add ConstraintRow(kind: crkFunction, function: f, opcode: -1,
                             name: fn.name, kindLabel: kindLabelOf(fn.kind),
                             count: $fn.opcodes, source: links[f])
    for o, op in fn.rows:
      result.add ConstraintRow(kind: crkOpcode, function: f, opcode: o,
                               name: op.name, count: $op.index, args: op.args,
                               source: linkOpcode(op.place))

proc rowTitle*(row: ConstraintRow): string =
  ## The row's tooltip: where a press goes, or why it goes nowhere.
  if row.source.linked: "Go to " & whereText(row.source)
  else: "No source: " & row.source.reason

proc rowText*(row: ConstraintRow): string =
  ## The row as one line of text (Copy Name's text for an opcode).
  case row.kind
  of crkFunction: row.name
  of crkOpcode:
    if row.args.len > 0: row.name & " " & row.args else: row.name

# ---------------------------------------------------------------------------
# Selection, activation and the row menu — the same on every front-end
# ---------------------------------------------------------------------------

proc selectRow*(vm: ConstraintsVM; index: int) =
  ## Select row `index` (-1 clears); an index past the rows clears.
  let n = vm.rows.val.len
  vm.selected.val = if index >= 0 and index < n: index else: -1

proc moveSelection*(vm: ConstraintsVM; operation: string; page = 10): bool =
  ## The list keys (`list.focus-next` …): move the selection. Whether
  ## `operation` was a move.
  let n = vm.rows.val.len
  let cur = vm.selected.val
  var next = cur
  case operation
  of "list.focus-next": next = (if cur < 0: 0 else: cur + 1)
  of "list.focus-previous": next = (if cur < 0: n - 1 else: cur - 1)
  of "list.focus-first": next = 0
  of "list.focus-last": next = n - 1
  of "list.focus-page-down": next = (if cur < 0: 0 else: cur + max(1, page))
  of "list.focus-page-up": next = (if cur < 0: 0 else: cur - max(1, page))
  else: return false
  if n == 0:
    vm.selected.val = -1
  else:
    vm.selected.val = clamp(next, 0, n - 1)
  true

proc activateRow*(vm: ConstraintsVM; index: int): ConstraintActivation =
  ## Select row `index` and open its source through the host — a press, Enter
  ## or Go to Source. A row placed nowhere opens nothing and says why.
  let rows = vm.rows.val
  if index < 0 or index >= rows.len:
    return ConstraintActivation(reason: "no such row")
  vm.selected.val = index
  let link = rows[index].source
  if not link.linked:
    return ConstraintActivation(reason: link.reason)
  if vm.onOpenSource.isNil:
    return ConstraintActivation(reason: CannotOpenReason)
  vm.onOpenSource(link.path, link.line, link.column)
  ConstraintActivation(opened: true, path: link.path, line: link.line)

proc rowMenu*(vm: ConstraintsVM; index: int): seq[ConstraintMenuEntry] =
  ## Row `index`'s context menu, in order; empty for no such row.
  let rows = vm.rows.val
  if index < 0 or index >= rows.len:
    return @[]
  let link = rows[index].source
  result.add ConstraintMenuEntry(label: GoToSourceLabel, action: cmGoToSource,
                                 enabled: link.linked, reason: link.reason)
  result.add ConstraintMenuEntry(label: CopyNameLabel, action: cmCopyName,
                                 enabled: true)
  result.add ConstraintMenuEntry(label: CopySourceLocationLabel,
                                 action: cmCopySourceLocation,
                                 enabled: link.linked, reason: link.reason)

proc runRowMenu*(vm: ConstraintsVM; index: int;
                 action: ConstraintMenuAction): ConstraintMenuOutcome =
  ## Choose `action` of row `index`'s menu. A disabled entry does nothing
  ## (`done` false), as the desktop's disabled entries do.
  var enabled = false
  for e in vm.rowMenu(index):
    if e.action == action:
      enabled = e.enabled
  if not enabled:
    return
  let row = vm.rows.val[index]
  vm.selected.val = index
  result.done = true
  case action
  of cmGoToSource:
    result.activation = vm.activateRow(index)
  of cmCopyName:
    result.copied = row.rowText
  of cmCopySourceLocation:
    result.copied = whereText(row.source)

proc createConstraintsVM*(): ConstraintsVM =
  withViewModel proc(dispose: proc()): ConstraintsVM =
    let report = createSignal(absentReport(NoCircuitCompiledYet))
    let projectName = createSignal("")
    let sources = createSignal(newSeq[NoirSourceFile]())
    let selected = createSignal(-1)

    let hasReport = createMemo[bool] proc(): bool =
      report.val.hasCounts()

    let acirOpcodes = createMemo[int] proc(): int =
      report.val.acirTotal()

    let unconstrainedOpcodes = createMemo[int] proc(): int =
      report.val.unconstrainedTotal()

    let headline = createMemo[string] proc(): string =
      headlineFor(report.val)

    let rows = createMemo[seq[ConstraintRow]] proc(): seq[ConstraintRow] =
      rowsFor(report.val, sources.val)

    ConstraintsVM(
      report: report,
      projectName: projectName,
      sources: sources,
      selected: selected,
      hasReport: hasReport,
      acirOpcodes: acirOpcodes,
      unconstrainedOpcodes: unconstrainedOpcodes,
      headline: headline,
      rows: rows,
      disposeProc: dispose,
    )
