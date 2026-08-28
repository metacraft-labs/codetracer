## NOT-A-TEST-LANE-FILE: production ViewModel-layer code. It declares no
## `suite`/`test` blocks; its behaviour is asserted by
## `src/frontend/viewmodel/tests/unit/test_verification_vm.nim`.

## viewmodels/verification_report.nim
##
## VN-M3 — what a verifier said, at the honest text tier.
##
## This module turns one Verno run into something an editor and a results pane
## can paint. It is the whole of
## `codetracer-specs/Planned-Features/SMT-Counterexample-And-Prover-State-Visualization.md`'s
## `SolverViz.TextFallback` tier and *nothing above it*: "a producer without
## structured model data still shows the textual diagnostic without claiming
## trace replay support."
##
## ## The one rule this module exists to enforce
##
## Verno can end a run in six distinguishable ways, and its own regression
## harness (`scripts/run-corpus.py` in `blocksense-network/verno`) already
## names them:
##
##   proved · not-proved · timed-out · unsupported · no-solver · pipeline-error
##
## **Exactly one of those six is a failed proof.** A construct Verno has not
## implemented is not one. A solver that ran out of resource budget is not one.
## A solver that could not be started at all is not one. A front-end error is
## not one.
##
## Collapsing them is not a cosmetic loss. A developer whose correct program
## uses a lambda, shown "unproven obligation" in their gutter, goes looking for
## a bug that is not there — and the tool has told them a falsehood about their
## code. `VN-M3` names this as the deliverable that matters most, so the
## distinction is carried in the type system here (`VerificationFindingKind`)
## rather than in a formatting decision at the edge, and
## `isFailedObligation` is the single place that says which is which.
##
## The classifier below is a deliberate line-by-line port of `run-corpus.py`'s
## `classify()`, including its ordering — a timeout and an unsupported
## construct are both recognised *before* anything is allowed to count as a
## lost proof. Where the two implementations could drift, the marker strings
## are stated as constants with the Verno source location that emits them.
##
## ## What is deliberately not here
##
## No structured payload, no proof-goal tree, no counterexample model, no trace
## — those are VN-M4 and VN-M5, and this tier must not hint at them. There is
## therefore no `openTrace`, no `stepThrough`, no `traceId` on a finding, and
## nothing downstream can synthesise one, because a `TestRunRow` built by
## `toTestEvents` below carries no `recording-created` event and so fails
## `test_run_summary_vm.hasRecording` by construction.
##
## Pure and plain-valued throughout — no `cstring`, no filesystem, no process —
## so it is asserted on both the C (`vm-unit`) and JS (`vm-unit-js`) backends.

import std/[options, strutils]

import ../../../ct_test/contracts

type
  VerificationOutcome* = enum
    ## Verno's six-outcome vocabulary, spelled exactly as
    ## `scripts/run-corpus.py` spells it so a CodeTracer report and a corpus
    ## report can be compared without a translation table.
    voProved = "proved"
    voNotProved = "not-proved"
    voTimedOut = "timed-out"
    voUnsupported = "unsupported"
    voNoSolver = "no-solver"
    voPipelineError = "pipeline-error"

  VerificationFindingKind* = enum
    ## What one line of a report *is*. The kinds are not severities: a
    ## limitation and a failed obligation can both stop you shipping, and they
    ## still demand opposite reactions from the developer.
    vfkProved = "proved"
      ## Every obligation discharged.
    vfkFailedObligation = "failed-obligation"
      ## The solver ran and could not discharge an obligation. **The only kind
      ## that is evidence about the program's correctness.**
    vfkLimitation = "limitation"
      ## Verno does not implement a construct the program uses. Says nothing
      ## about whether the program is correct.
    vfkBudgetExhausted = "budget-exhausted"
      ## The solver ran out of resource budget or wall clock. Says nothing
      ## about whether the program is correct.
    vfkSolverUnavailable = "solver-unavailable"
      ## The Noir -> VIR pipeline completed and the solver was never started.
      ## Says nothing about whether the program is correct. This is the normal
      ## outcome on macOS, where `venir` is unavailable.
    vfkPipelineError = "pipeline-error"
      ## Verno failed before the solver: a parse, type-check, monomorphisation
      ## or VIR-generation error. A defect in the program or in Verno, but not
      ## a proof result.

  VerificationFinding* = object
    kind*: VerificationFindingKind
    message*: string
      ## The verifier's own headline, verbatim.
    detail*: string
      ## The verifier's secondary label ("failed postcondition"), verbatim, or
      ## empty.
    construct*: string
      ## For `vfkLimitation` only: the construct Verno named after its
      ## `UNSUPPORTED:` prefix. Empty otherwise.
    file*: string
    range*: SourceRange
    hasLocation*: bool
      ## Whether `file`/`range` mean anything. Verno's limitation panics carry
      ## no source span at all, so this is genuinely optional and must not be
      ## faked with line 1 column 1 — a marker on the wrong line is worse than
      ## no marker.
    excerpt*: string
      ## The rendered diagnostic block as the verifier printed it, kept for the
      ## hover and the results pane. This is the "textual diagnostic" the
      ## fallback tier promises.

  VerificationReport* = object
    outcome*: VerificationOutcome
    summary*: string
      ## One line saying why, in the shape `run-corpus.py` writes into its
      ## report.
    findings*: seq[VerificationFinding]
    exitCode*: Option[int]
    timedOut*: bool
    commandLine*: string
    projectRoot*: string
    rawOutput*: string

  VerificationMarkerKind* = enum
    ## What a gutter marker claims. There is no "warning" here on purpose: the
    ## kind *is* the claim, and a view that cannot tell a limitation from a
    ## failed obligation would be free to render them the same.
    vmkFailedObligation = "failed-obligation"
    vmkLimitation = "limitation"
    vmkPipelineError = "pipeline-error"

  VerificationMarker* = object
    kind*: VerificationMarkerKind
    file*: string
    range*: SourceRange
    message*: string
    hoverText*: string
      ## What the editor shows on hover: the headline, the secondary label and
      ## the verifier's own block. Never a summary we invented.
    severity*: DiagnosticSeverity

# ---------------------------------------------------------------------------
# The marker strings, and where Verno emits them
# ---------------------------------------------------------------------------

const
  UnsupportedPrefix* = "UNSUPPORTED: "
    ## Every `todo!()` in Verno's translator carries this prefix and names the
    ## construct after it (`docs/src/limitations.md`). It is deliberately
    ## distinct from `unreachable!()`, which stays a pipeline error so that an
    ## internal compiler error cannot hide as a documented limitation.
  UnimplementedMarker* = "not yet implemented"
    ## What `todo!()`/`unimplemented!()` panic with. Matched as a fallback for
    ## the `todo!()`s that predate the prefix.
  UnreachableMarker* = "internal error: entered unreachable code"
    ## `unreachable!()`. `docs/src/limitations.md`: "A panic reading `internal
    ## error: entered unreachable code` is **not** a limitation." Named here so
    ## the fallback above cannot swallow it.
  RlimitMarker* = "Resource limit (rlimit) exceeded"
    ## Verus serialises a resource-limit exhaustion as an ordinary error block;
    ## this string is the only thing distinguishing it from a real unprovable
    ## result. From `air/src/main.rs` in the pinned verus-lib revision.
  NoSolverMarker* = "Failed to start the Venir binary"
    ## `formal_verification/src/venir_communication.rs`.
  SuccessMarker* = "Verification successful!"
    ## `venir_communication.rs:114`.
  VerificationFailedMarker* = "Verification failed"
    ## `venir_communication.rs:108-112`, "Verification failed due to N
    ## previous errors!".
  VerificationCrashedMarker* = "Verification crashed"
    ## `venir_communication.rs:104` and `:208`.

const PreSolverMarkers* = [
  "Non-ghost function",
  "cannot compile crate",
  "no binary packages",
  "no verifiable functions",
  "cannot find a Nargo.toml",
]
  ## Verno prints verification diagnostics only after `venir` has answered, so
  ## any output naming a pre-solver phase means the pipeline itself failed.
  ## Mirrors `run-corpus.py::reached_solver`.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc firstLineContaining(output, needle: string): string =
  for line in output.splitLines:
    if needle in line:
      return line.strip()
  needle

proc firstErrorLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith("error") or stripped.startsWith("Error"):
      return stripped
  for line in output.splitLines:
    if line.strip().len > 0:
      return line.strip()
  ""

proc reachedSolver*(output: string): bool =
  ## True when Verno got as far as running the solver. Port of
  ## `run-corpus.py::reached_solver`.
  for marker in PreSolverMarkers:
    if marker in output:
      return false
  VerificationFailedMarker in output or VerificationCrashedMarker in output

proc unsupportedConstruct*(output: string): string =
  ## The construct Verno named, or "" when it did not name one.
  let position = output.find(UnsupportedPrefix)
  if position < 0:
    return ""
  let tail = output[position + UnsupportedPrefix.len .. ^1]
  let newline = tail.find('\n')
  if newline < 0: tail.strip() else: tail[0 ..< newline].strip()

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

proc classifyVernoRun*(exitCode: Option[int]; output: string;
                       timedOut: bool): (VerificationOutcome, string) =
  ## Map one run to an outcome and a one-line reason.
  ##
  ## A line-by-line port of `run-corpus.py::classify`, **ordering included**:
  ## a timeout and an unsupported construct are both checked before anything
  ## is allowed to count as a lost proof. Any change here that is not also
  ## made there splits the IDE's vocabulary from the corpus gate's, which is
  ## the drift the shared spelling exists to prevent.
  if timedOut:
    return (voTimedOut, "wall clock exceeded")

  if RlimitMarker in output:
    return (voTimedOut, "solver rlimit exhausted")

  if UnsupportedPrefix in output:
    return (voUnsupported, firstLineContaining(output, UnsupportedPrefix))

  if UnreachableMarker in output:
    # Checked *before* the generic panic marker: `unreachable!()` means an
    # invariant Verno relies on did not hold. It is a bug to be reported, and
    # folding it into `unsupported` would let internal compiler errors hide as
    # documented limitations.
    return (voPipelineError, firstLineContaining(output, UnreachableMarker))

  if UnimplementedMarker in output:
    return (voUnsupported, firstLineContaining(output, UnimplementedMarker))

  if NoSolverMarker in output:
    return (voNoSolver, "Noir -> VIR pipeline completed; `venir` not available")

  if SuccessMarker in output:
    return (voProved, "verification successful")

  if exitCode.isSome and exitCode.get == 0:
    return (voProved, "exited 0 without a success banner")

  if "error:" in output or "Aborting due to" in output:
    if reachedSolver(output):
      return (voNotProved, firstErrorLine(output))
    return (voPipelineError, firstErrorLine(output))

  let fallback = firstErrorLine(output)
  if fallback.len > 0:
    return (voPipelineError, fallback)
  if exitCode.isSome:
    return (voPipelineError, "exit " & $exitCode.get)
  (voPipelineError, "no output and no exit status")

proc isFailedProof*(outcome: VerificationOutcome): bool =
  ## The single definition of "the verifier rejected this program".
  ##
  ## Five of the six outcomes answer `false`, and each of the five is a
  ## different reason the question was not answered rather than an answer of
  ## "no". Every place in the IDE that would otherwise write its own
  ## `!= voProved` calls this instead.
  outcome == voNotProved

proc isFailedObligation*(kind: VerificationFindingKind): bool =
  kind == vfkFailedObligation

proc answersCorrectness*(outcome: VerificationOutcome): bool =
  ## Whether the run said anything at all about whether the program is
  ## correct. `proved` and `not-proved` do; the other four report on the
  ## *tool*, not on the program.
  outcome in {voProved, voNotProved}

# ---------------------------------------------------------------------------
# Diagnostic parsing
# ---------------------------------------------------------------------------
#
# Verno renders solver diagnostics through `noirc_errors::reporter::report_all`
# — codespan-reporting — which is the same renderer Noir uses for compile
# errors. So the block below is shaped like this:
#
#   error: assertion failed
#      ┌─ src/main.nr:15:12
#      │
#   15 │     assert(n == 40);
#      │            -------- assertion failed
#      │
#
# The parser is validated against *real* current output: see
# `tests/fixtures/verno/PROVENANCE.md`, where the pipeline-error fixture is a
# genuine beta.26 reporter block captured on the machine this was written on.

const LocationMarker = "┌─"   ## the "┌─" that opens a location line

type ParsedDiagnostic* = object
  severity*: DiagnosticSeverity
  message*: string
  detail*: string
  file*: string
  range*: SourceRange
  hasLocation*: bool
  excerpt*: string

proc parseLocation(line: string; file: var string; startLine, startColumn: var int): bool =
  ## `  ┌─ path/to/file.nr:15:12` -> ("path/to/file.nr", 15, 12).
  ##
  ## Split from the right, twice: a Windows path contains a drive colon and
  ## splitting from the left would cut it in half.
  let marker = line.find(LocationMarker)
  if marker < 0:
    return false
  let rest = line[marker + LocationMarker.len .. ^1].strip()
  let lastColon = rest.rfind(':')
  if lastColon <= 0:
    return false
  let firstColon = rest.rfind(':', last = lastColon - 1)
  if firstColon <= 0:
    return false
  try:
    startLine = parseInt(rest[firstColon + 1 ..< lastColon].strip())
    startColumn = parseInt(rest[lastColon + 1 .. ^1].strip())
  except ValueError:
    return false
  file = rest[0 ..< firstColon].strip()
  file.len > 0

proc underlineSpan(line: string): (int, string) =
  ## An underline row is `  │            -------- assertion failed`.
  ## Returns the width of the dash run and whatever the reporter wrote after
  ## it. `(0, "")` when this is not an underline row.
  let bar = line.find("│")               # "│"
  if bar < 0:
    return (0, "")
  # The gutter of an underline row is blank; a *source* row carries its line
  # number there. Without this check, a source line that happens to begin with
  # a minus (`-x + y`) would be read as an eight-column underline.
  for index in 0 ..< bar:
    if line[index] in {'0' .. '9'}:
      return (0, "")
  let rest = line[bar + 3 .. ^1]              # "│" is three UTF-8 bytes
  var index = 0
  while index < rest.len and rest[index] == ' ':
    inc index
  var width = 0
  while index + width < rest.len and rest[index + width] == '-':
    inc width
  if width == 0:
    return (0, "")
  (width, rest[index + width .. ^1].strip())

proc parseVernoDiagnostics*(output: string): seq[ParsedDiagnostic] =
  ## Every `error:`/`warning:` block in a codespan-rendered report.
  ##
  ## Only lowercase headers start a block: the run-level trailer
  ## `Error: Verification failed due to 1 previous errors!` is a summary line,
  ## not a diagnostic, and turning it into a seventh finding with no location
  ## would put a phantom row in the results pane.
  var accumulated: seq[ParsedDiagnostic] = @[]
  var current: ParsedDiagnostic
  var open = false
  var sawUnderline = false

  proc flush() =
    if open:
      current.excerpt = current.excerpt.strip(leading = false)
      accumulated.add current
    open = false
    sawUnderline = false

  for line in output.splitLines:
    if line.startsWith("error: ") or line.startsWith("warning: "):
      flush()
      current = ParsedDiagnostic(
        severity: if line.startsWith("error: "): dsError else: dsWarning,
        message: line[line.find(':') + 1 .. ^1].strip(),
        range: SourceRange(startLine: 0, startColumn: 0, endLine: 0, endColumn: 0),
      )
      current.excerpt = line & "\n"
      open = true
      continue

    if not open:
      continue

    current.excerpt.add line & "\n"

    if not current.hasLocation:
      var file = ""
      var startLine = 0
      var startColumn = 0
      if parseLocation(line, file, startLine, startColumn):
        current.file = file
        current.range = SourceRange(
          startLine: startLine, startColumn: startColumn,
          endLine: startLine, endColumn: startColumn)
        current.hasLocation = true
        continue

    if current.hasLocation and not sawUnderline:
      let (width, label) = underlineSpan(line)
      if width > 0:
        sawUnderline = true
        current.range.endColumn = current.range.startColumn + width
        if label.len > 0:
          current.detail = label

  flush()
  accumulated

# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

proc limitationFinding(output, construct: string): VerificationFinding =
  ## A limitation, said as a limitation.
  ##
  ## No location: Verno's `todo!()` panics carry a *Rust* source position
  ## (`expr_to_vir/types.rs:56:13`), never a Noir one, and pointing the
  ## developer's gutter at a line of Verno's own source — or guessing at a
  ## line of theirs — would be worse than saying where it cannot point.
  let named = if construct.len > 0: construct else: "a construct Verno does not implement"
  VerificationFinding(
    kind: vfkLimitation,
    message: "Verno does not support " & named,
    detail: "This is a limitation of the verifier, not a failed proof. " &
      "The program may well be correct; Verno cannot say either way.",
    construct: construct,
    hasLocation: false,
    excerpt: output.strip(),
  )

proc buildReport*(outcome: VerificationOutcome; summary, output: string;
                  exitCode: Option[int]; timedOut: bool;
                  commandLine = ""; projectRoot = ""): VerificationReport =
  ## Turn a classified run into findings.
  ##
  ## The `case` below is the deliverable. Note that `voUnsupported` produces
  ## *exactly one* `vfkLimitation` finding and never consults the parsed
  ## diagnostics — so even a run that panicked *after* printing an `error:`
  ## block cannot contribute a failed obligation. The kind of a finding is
  ## decided by the outcome, once, here; nothing downstream re-derives it.
  result = VerificationReport(
    outcome: outcome,
    summary: summary,
    exitCode: exitCode,
    timedOut: timedOut,
    commandLine: commandLine,
    projectRoot: projectRoot,
    rawOutput: output,
  )
  let diagnostics = parseVernoDiagnostics(output)

  case outcome
  of voProved:
    result.findings.add VerificationFinding(
      kind: vfkProved,
      message: "Every proof obligation was discharged.",
      excerpt: summary,
    )
  of voNotProved:
    for diagnostic in diagnostics:
      if diagnostic.severity != dsError:
        continue
      result.findings.add VerificationFinding(
        kind: vfkFailedObligation,
        message: diagnostic.message,
        detail: diagnostic.detail,
        file: diagnostic.file,
        range: diagnostic.range,
        hasLocation: diagnostic.hasLocation,
        excerpt: diagnostic.excerpt,
      )
    if result.findings.len == 0:
      # The solver rejected the program without a parseable block. Say so
      # rather than showing nothing: a rejected program with an empty report
      # reads as a passing one.
      result.findings.add VerificationFinding(
        kind: vfkFailedObligation,
        message: summary,
        excerpt: output.strip(),
      )
  of voUnsupported:
    result.findings.add limitationFinding(output, unsupportedConstruct(output))
  of voTimedOut:
    result.findings.add VerificationFinding(
      kind: vfkBudgetExhausted,
      message: "The solver ran out of budget before it could answer.",
      detail: "Not a failed proof: nothing was established either way. " &
        "Re-run with a larger `--rlimit` to get an answer.",
      excerpt: output.strip(),
    )
  of voNoSolver:
    result.findings.add VerificationFinding(
      kind: vfkSolverUnavailable,
      message: "The Noir to VIR pipeline completed; the solver was not started.",
      detail: "Verno's solver back end (`venir`) is not available on this " &
        "machine, so no proof was attempted. Nothing was established either way.",
      excerpt: output.strip(),
    )
  of voPipelineError:
    for diagnostic in diagnostics:
      result.findings.add VerificationFinding(
        kind: vfkPipelineError,
        message: diagnostic.message,
        detail: diagnostic.detail,
        file: diagnostic.file,
        range: diagnostic.range,
        hasLocation: diagnostic.hasLocation,
        excerpt: diagnostic.excerpt,
      )
    if result.findings.len == 0:
      result.findings.add VerificationFinding(
        kind: vfkPipelineError,
        message: summary,
        excerpt: output.strip(),
      )

proc reportForRun*(output: string; exitCode: Option[int]; timedOut = false;
                   commandLine = ""; projectRoot = ""): VerificationReport =
  ## Classify and assemble in one step — the entry point a run uses.
  let (outcome, summary) = classifyVernoRun(exitCode, output, timedOut)
  buildReport(outcome, summary, output, exitCode, timedOut, commandLine, projectRoot)

# ---------------------------------------------------------------------------
# The editor surface
# ---------------------------------------------------------------------------

proc markerKindFor(kind: VerificationFindingKind): Option[VerificationMarkerKind] =
  case kind
  of vfkFailedObligation: some(vmkFailedObligation)
  of vfkLimitation: some(vmkLimitation)
  of vfkPipelineError: some(vmkPipelineError)
  of vfkProved, vfkBudgetExhausted, vfkSolverUnavailable: none(VerificationMarkerKind)

proc hoverTextFor*(finding: VerificationFinding): string =
  ## What hovering the marker shows. The verifier's own words, plus the kind
  ## spelled out — a developer who hovers a marker should not have to know
  ## CodeTracer's colour conventions to learn whether their program is wrong.
  result = finding.message
  if finding.detail.len > 0:
    result.add "\n" & finding.detail
  if finding.excerpt.len > 0 and finding.excerpt != finding.message:
    result.add "\n\n" & finding.excerpt

proc editorMarkers*(report: VerificationReport): seq[VerificationMarker] =
  ## Gutter markers for the findings that have a place to sit.
  ##
  ## Two properties, both asserted in the suite:
  ##
  ## * a marker's `kind` comes from its finding's kind, so a limitation can
  ##   never be painted as a failed obligation even if a future Verno starts
  ##   attaching Noir spans to its `todo!()`s;
  ## * a finding with `hasLocation == false` produces no marker at all rather
  ##   than one at line 1, because a marker on an arbitrary line is a claim
  ##   about code that made no such claim.
  for finding in report.findings:
    if not finding.hasLocation:
      continue
    let kind = markerKindFor(finding.kind)
    if kind.isNone:
      continue
    result.add VerificationMarker(
      kind: kind.get,
      file: finding.file,
      range: finding.range,
      message: finding.message,
      hoverText: hoverTextFor(finding),
      severity:
        # A limitation is a warning about the *verifier*; a failed obligation
        # and a front-end error are errors about the *program*.
        if finding.kind == vfkLimitation: dsWarning else: dsError,
    )

proc failedObligationMarkers*(report: VerificationReport): seq[VerificationMarker] =
  for marker in editorMarkers(report):
    if marker.kind == vmkFailedObligation:
      result.add marker

# ---------------------------------------------------------------------------
# The results-pane surface
# ---------------------------------------------------------------------------

proc testStatusFor*(kind: VerificationFindingKind): TestResultStatus =
  ## How one finding lands in the four-valued wire status the test-results
  ## pane already speaks.
  ##
  ## This is a *narrowing*, and it is the one place where the six-outcome
  ## vocabulary meets a coarser one — so the narrowing is done deliberately
  ## and only here, and `outcomeLabel` below is carried alongside it in words
  ## so the pane never has only the narrowed value to show.
  ##
  ## `tsSkipped` for a limitation and for an absent solver is the load-bearing
  ## choice: both mean "this was not attempted", which is what a skip is, and
  ## neither is `tsFailed`.
  case kind
  of vfkProved: tsPassed
  of vfkFailedObligation: tsFailed
  of vfkLimitation: tsSkipped
  of vfkSolverUnavailable: tsSkipped
  of vfkBudgetExhausted: tsErrored
  of vfkPipelineError: tsErrored

proc outcomeLabel*(outcome: VerificationOutcome): string =
  ## The outcome in words, for a pane that can only show four statuses.
  case outcome
  of voProved: "proved"
  of voNotProved: "not proved"
  of voTimedOut: "timed out (solver budget exhausted, not a failed proof)"
  of voUnsupported: "unsupported construct (a limitation of the verifier, not a failed proof)"
  of voNoSolver: "no solver available (nothing was proved or disproved)"
  of voPipelineError: "pipeline error (Verno failed before the solver)"

proc findingTitle*(finding: VerificationFinding; index: int): string =
  case finding.kind
  of vfkProved: "verification"
  of vfkFailedObligation:
    if finding.hasLocation:
      finding.file & ":" & $finding.range.startLine
    else:
      "obligation " & $(index + 1)
  of vfkLimitation:
    if finding.construct.len > 0: "unsupported: " & finding.construct
    else: "unsupported construct"
  of vfkBudgetExhausted: "solver budget"
  of vfkSolverUnavailable: "solver"
  of vfkPipelineError:
    if finding.hasLocation:
      finding.file & ":" & $finding.range.startLine
    else: "pipeline"

proc toTestEvents*(report: VerificationReport; runId: string;
                   actionLabel = "verify"): seq[TestEvent] =
  ## The report as the event stream `ct test` already emits, so a proof result
  ## reaches the results pane through machinery that was written before this
  ## milestone and needs no special case for it.
  ##
  ## **No `tekRecordingCreated` event is emitted, ever.** That is not an
  ## omission: `test_run_summary_vm.hasRecording` gates the pane's drill-down
  ## affordance on a `recording-created` event having carried a trace path, so
  ## a verification row structurally cannot offer to open a trace. VN-M3
  ## promises no replay, and this is the promise enforced by the shape of the
  ## data rather than by a check someone could forget to write.
  const providerId = "verno"
  result.add TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: tekRunStarted,
    providerId: providerId,
    runId: runId,
    message: report.commandLine,
  )
  result.add TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: tekDiagnostic,
    providerId: providerId,
    runId: runId,
    diagnostic: some(TestDiagnostic(
      severity: if isFailedProof(report.outcome): dsError else: dsInfo,
      message: "verno: " & outcomeLabel(report.outcome) & " — " & report.summary,
      file: report.projectRoot,
    )),
  )
  for index, finding in report.findings:
    let testId = providerId & "/noir/verno/" & report.projectRoot & "::" &
      actionLabel & " " & findingTitle(finding, index)
    result.add TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: tekTestStarted,
      providerId: providerId,
      runId: runId,
      testId: testId,
    )
    # The captured output of a "test" that is really a proof obligation is the
    # verifier's own diagnostic, prefixed by the outcome **in words**. That
    # prefix is the whole reason this event exists: the pane's status enum has
    # four values and Verno's vocabulary has six, so a row whose status alone
    # said `skipped` would not say *why* it was skipped — and "unsupported
    # construct" versus "no solver on this machine" are opposite instructions
    # to the developer.
    result.add TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: tekOutput,
      providerId: providerId,
      runId: runId,
      testId: testId,
      output: outcomeLabel(report.outcome) & "\n" & hoverTextFor(finding),
    )
    if isFailedObligation(finding.kind):
      # Only a failed obligation is reported through the failure channel, and
      # it carries its source range so the pane can jump to it. A limitation
      # reaching this branch would be the defect this milestone exists to
      # prevent.
      result.add TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekFailure,
        providerId: providerId,
        runId: runId,
        testId: testId,
        status: some(tsFailed),
        message: finding.message,
        diagnostic: some(TestDiagnostic(
          severity: dsError,
          message: finding.message,
          file: finding.file,
          range:
            if finding.hasLocation: some(finding.range)
            else: none(SourceRange),
        )),
      )
    result.add TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: tekTestFinished,
      providerId: providerId,
      runId: runId,
      testId: testId,
      status: some(testStatusFor(finding.kind)),
      message: finding.message,
    )
  result.add TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: tekRunFinished,
    providerId: providerId,
    runId: runId,
    message: outcomeLabel(report.outcome),
  )
