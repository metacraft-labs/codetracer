## NOT-A-TEST-LANE-FILE: production ViewModel-layer code. It declares no
## `suite`/`test` blocks; its behaviour is asserted by
## `src/frontend/viewmodel/tests/unit/test_verification_vm.nim`.

## viewmodels/verification_vm.nim
##
## VN-M3 — a verification run, as a long-running process with visible state.
##
## `Noir-Studio.md` §5.3 and §9.3 give the process model and are explicit that
## it must stay small: "its whole interface is three operations: start and
## stop, liveness and status, and *a trace opened*." Two of those three apply
## here — a text-tier verification run opens no trace, and §9.3's third
## operation is exactly what VN-M4/VN-M5 will earn. **Resist a fourth**: there
## is no restart policy, no dependency graph and no health check in this file,
## and none is justified by one process type.
##
## The deliverable this serves is "long verification runs behave as
## long-running processes with visible state, not as a frozen UI". Concretely:
##
## * every intermediate state is a legal, renderable enum value, so a run can
##   be painted at any moment without waiting for it to finish;
## * elapsed time and the last line the verifier printed are pushed in as they
##   arrive, so a four-minute proof attempt looks alive rather than hung;
## * the run is cancellable while it is running, and *cancelled* is a state of
##   its own rather than a failure — a cancelled proof attempt establishes
##   nothing, and reporting it as `not-proved` would be the same lie this
##   milestone exists to remove, one level up.
##
## The VM runs no process. It is pushed at by a host adapter and pulls at
## `verification_report`, which is pure. So the whole of the state machine is
## drivable headlessly on both backends.

import std/[options, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./project_actions
import ./verification_report

type
  VerificationPhase* = enum
    ## Where a run is. `vpFailedToStart` is separate from `vpFinished`
    ## because a verifier that never ran produced no outcome at all, and the
    ## six-outcome vocabulary has no value for "we could not launch it" — that
    ## is a fact about this machine, not about Verno or about the program.
    vpIdle = "idle"
    vpStarting = "starting"
    vpRunning = "running"
    vpCancelling = "cancelling"
    vpCancelled = "cancelled"
    vpFinished = "finished"
    vpFailedToStart = "failed-to-start"

  VerificationVM* = ref object of ViewModel
    phase*: Signal[VerificationPhase]
    actionId*: Signal[string]
    actionLabel*: Signal[string]
    commandLine*: Signal[string]
    projectRoot*: Signal[string]
    elapsedMs*: Signal[int]
    outputLineCount*: Signal[int]
    lastOutputLine*: Signal[string]
      ## The most recent line the verifier printed. Verno is not chatty during
      ## a long solve, so this is often stale — which is why `elapsedMs` is
      ## shown next to it rather than instead of it.
    startFailure*: Signal[string]
    report*: Signal[Option[VerificationReport]]

    isRunning*: Memo[bool]
    isCancellable*: Memo[bool]
    hasReport*: Memo[bool]
    statusText*: Memo[string]
    outcomeText*: Memo[string]
    markers*: Memo[seq[VerificationMarker]]
    findingCount*: Memo[int]
    failedObligationCount*: Memo[int]
    limitationCount*: Memo[int]

const VerificationProviderId* = "verno"

const ReplayIsNotOfferedHere* = true
  ## VN-M3 deliverable: "**No claim of replay anywhere in this tier's UI**".
  ##
  ## Named as a constant so that a future change which starts offering replay
  ## has to delete this line and read the sentence above it. The property is
  ## enforced structurally in two places rather than by this flag —
  ## `verification_report.toTestEvents` emits no `recording-created` event, and
  ## `isonim_verification_view` renders no trace affordance — and asserted in
  ## `test_the_text_tier_never_offers_replay`.

# ---------------------------------------------------------------------------
# Recognising a verification action
# ---------------------------------------------------------------------------

proc isVernoAction*(action: ProjectAction): bool =
  ## Whether this project-declared action invokes Verno.
  ##
  ## This is an *adapter recognising its own producer*, which is the only
  ## thing §9.3 leaves room for: "we surface what a project declares and
  ## invent no manifest of our own", so there is no `"ct.verifier": "verno"`
  ## field for a project to add. A project that runs Verno under a wrapper
  ## script we do not recognise still gets its action run and its output
  ## shown — it simply gets the raw text rather than parsed findings, which is
  ## the honest degradation for a producer we cannot identify.
  let words = (action.command & " " & action.args.join(" ")).toLowerAscii
  var head = action.command.toLowerAscii
  let slash = max(head.rfind('/'), head.rfind('\\'))
  if slash >= 0:
    head = head[slash + 1 .. ^1]
  if head == "verno" or head == "verno.exe":
    return true
  " verno " in " " & words & " "

proc vernoActions*(actions: ProjectActionSet): seq[ProjectAction] =
  for action in actions.actions:
    if isVernoAction(action):
      result.add action

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

proc formatElapsed*(elapsedMs: int): string =
  if elapsedMs < 0:
    return "0s"
  if elapsedMs < 1000:
    return $elapsedMs & "ms"
  let seconds = elapsedMs div 1000
  if seconds < 60:
    return $seconds & "s"
  $(seconds div 60) & "m " & $(seconds mod 60) & "s"

proc phaseStatusText(phase: VerificationPhase; label: string; elapsedMs: int;
                     lastLine, failure: string;
                     report: Option[VerificationReport]): string =
  ## One line naming the state, always renderable.
  ##
  ## A running proof attempt never renders as a bare spinner: it says what it
  ## is doing and for how long, because "frozen" and "working" are otherwise
  ## indistinguishable, and a solver is entitled to think for minutes.
  case phase
  of vpIdle:
    if label.len > 0: label & " — not run" else: "not run"
  of vpStarting:
    "Starting " & label & "…"
  of vpRunning:
    var text = "Verifying with Verno — " & formatElapsed(elapsedMs)
    if lastLine.len > 0:
      text.add " — " & lastLine
    text
  of vpCancelling:
    "Stopping " & label & "…"
  of vpCancelled:
    "Cancelled after " & formatElapsed(elapsedMs) & " — nothing was proved or disproved"
  of vpFailedToStart:
    if failure.len > 0: "Could not start " & label & ": " & failure
    else: "Could not start " & label
  of vpFinished:
    if report.isSome:
      outcomeLabel(report.get.outcome) & " — " & formatElapsed(elapsedMs)
    else:
      "Finished — " & formatElapsed(elapsedMs)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createVerificationVM*(): VerificationVM =
  withViewModel proc(dispose: proc()): VerificationVM =
    let phase = createSignal(vpIdle)
    let actionId = createSignal("")
    let actionLabel = createSignal("")
    let commandLine = createSignal("")
    let projectRoot = createSignal("")
    let elapsedMs = createSignal(0)
    let outputLineCount = createSignal(0)
    let lastOutputLine = createSignal("")
    let startFailure = createSignal("")
    let report = createSignal(none(VerificationReport))

    let isRunning = createMemo[bool] proc(): bool =
      phase.val in {vpStarting, vpRunning, vpCancelling}

    let isCancellable = createMemo[bool] proc(): bool =
      phase.val in {vpStarting, vpRunning}

    let hasReport = createMemo[bool] proc(): bool =
      report.val.isSome

    let statusText = createMemo[string] proc(): string =
      phaseStatusText(phase.val, actionLabel.val, elapsedMs.val,
                      lastOutputLine.val, startFailure.val, report.val)

    let outcomeText = createMemo[string] proc(): string =
      if report.val.isSome: outcomeLabel(report.val.get.outcome) else: ""

    let markers = createMemo[seq[VerificationMarker]] proc(): seq[VerificationMarker] =
      if report.val.isSome: editorMarkers(report.val.get) else: @[]

    let findingCount = createMemo[int] proc(): int =
      if report.val.isSome: report.val.get.findings.len else: 0

    let failedObligationCount = createMemo[int] proc(): int =
      if report.val.isNone:
        return 0
      for finding in report.val.get.findings:
        if isFailedObligation(finding.kind):
          inc result

    let limitationCount = createMemo[int] proc(): int =
      if report.val.isNone:
        return 0
      for finding in report.val.get.findings:
        if finding.kind == vfkLimitation:
          inc result

    VerificationVM(
      phase: phase,
      actionId: actionId,
      actionLabel: actionLabel,
      commandLine: commandLine,
      projectRoot: projectRoot,
      elapsedMs: elapsedMs,
      outputLineCount: outputLineCount,
      lastOutputLine: lastOutputLine,
      startFailure: startFailure,
      report: report,
      isRunning: isRunning,
      isCancellable: isCancellable,
      hasReport: hasReport,
      statusText: statusText,
      outcomeText: outcomeText,
      markers: markers,
      findingCount: findingCount,
      failedObligationCount: failedObligationCount,
      limitationCount: limitationCount,
      disposeProc: dispose,
    )

# ---------------------------------------------------------------------------
# Actions — start, stop, status. §5.3's three operations, minus the trace.
# ---------------------------------------------------------------------------

proc start*(vm: VerificationVM; action: ProjectAction; projectRoot = "") =
  ## Begin a run of a project-declared action. Clears the previous report:
  ## showing last run's findings next to this run's spinner is how a stale
  ## green reads as a fresh one.
  vm.actionId.val = action.id
  vm.actionLabel.val = action.label
  vm.commandLine.val = commandLine(action)
  vm.projectRoot.val = projectRoot
  vm.elapsedMs.val = 0
  vm.outputLineCount.val = 0
  vm.lastOutputLine.val = ""
  vm.startFailure.val = ""
  vm.report.val = none(VerificationReport)
  vm.phase.val = vpStarting

proc noteRunning*(vm: VerificationVM) =
  if vm.phase.val == vpStarting:
    vm.phase.val = vpRunning

proc noteElapsed*(vm: VerificationVM; elapsedMs: int) =
  vm.elapsedMs.val = elapsedMs
  if vm.phase.val == vpStarting:
    vm.phase.val = vpRunning

proc noteOutput*(vm: VerificationVM; line: string) =
  ## One line of the verifier's output arrived. Kept as a count plus the last
  ## line rather than a buffer: the full text is in the report when the run
  ## ends, and a growing string in a signal re-renders the pane on every line.
  let trimmed = line.strip()
  if trimmed.len > 0:
    vm.lastOutputLine.val = trimmed
  vm.outputLineCount.val = vm.outputLineCount.val + 1
  if vm.phase.val == vpStarting:
    vm.phase.val = vpRunning

proc requestCancel*(vm: VerificationVM) =
  if vm.phase.val in {vpStarting, vpRunning}:
    vm.phase.val = vpCancelling

proc noteCancelled*(vm: VerificationVM) =
  ## The process is gone. No report: a cancelled run has no outcome, and
  ## classifying its partial output would manufacture one.
  vm.phase.val = vpCancelled
  vm.report.val = none(VerificationReport)

proc noteFailedToStart*(vm: VerificationVM; reason: string) =
  vm.startFailure.val = reason
  vm.phase.val = vpFailedToStart

proc finish*(vm: VerificationVM; output: string; exitCode: Option[int];
             timedOut = false) =
  ## The run ended. Classify, assemble, and settle into `vpFinished`.
  ##
  ## A run cancelled by the user is not classified even if output arrived,
  ## for the reason in `noteCancelled`.
  if vm.phase.val == vpCancelling:
    vm.noteCancelled()
    return
  vm.report.val = some(reportForRun(
    output, exitCode, timedOut,
    commandLine = vm.commandLine.val,
    projectRoot = vm.projectRoot.val))
  vm.phase.val = vpFinished

proc currentMarkers*(vm: VerificationVM): seq[VerificationMarker] =
  vm.markers.val

proc currentReport*(vm: VerificationVM): Option[VerificationReport] =
  vm.report.val

# ---------------------------------------------------------------------------
# The render plan
# ---------------------------------------------------------------------------

type
  VerificationPanelRow* = object
    ## One row of the results panel, already reduced to strings.
    kind*: VerificationFindingKind
    kindLabel*: string
      ## The kind in words, shown on the row itself. A results panel that
      ## distinguished a limitation from a failed obligation only by colour
      ## would fail this milestone's central deliverable for every developer
      ## who does not already know the colour convention.
    title*: string
    message*: string
    detail*: string
    location*: string
    excerpt*: string
    isFailure*: bool
      ## True only for a failed obligation. The view has no other way to
      ## decide, on purpose.

  VerificationPanelModel* = object
    phase*: VerificationPhase
    actionLabel*: string
    commandLine*: string
    statusText*: string
    outcomeText*: string
    elapsed*: string
    running*: bool
    cancellable*: bool
    hasReport*: bool
    answersCorrectness*: bool
      ## Whether the run said anything about the program at all. False for
      ## four of the six outcomes, and the view says so in words when it is.
    rows*: seq[VerificationPanelRow]

proc kindLabel*(kind: VerificationFindingKind): string =
  case kind
  of vfkProved: "proved"
  of vfkFailedObligation: "failed obligation"
  of vfkLimitation: "verifier limitation"
  of vfkBudgetExhausted: "solver budget exhausted"
  of vfkSolverUnavailable: "solver unavailable"
  of vfkPipelineError: "pipeline error"

proc panelModel*(vm: VerificationVM): VerificationPanelModel =
  ## The whole panel as a plain record, so the view is a pure function of it
  ## and both renderers paint the same tree.
  result = VerificationPanelModel(
    phase: vm.phase.val,
    actionLabel: vm.actionLabel.val,
    commandLine: vm.commandLine.val,
    statusText: vm.statusText.val,
    outcomeText: vm.outcomeText.val,
    elapsed: formatElapsed(vm.elapsedMs.val),
    running: vm.isRunning.val,
    cancellable: vm.isCancellable.val,
    hasReport: vm.hasReport.val,
  )
  let report = vm.report.val
  if report.isNone:
    return
  result.answersCorrectness = answersCorrectness(report.get.outcome)
  for index, finding in report.get.findings:
    result.rows.add VerificationPanelRow(
      kind: finding.kind,
      kindLabel: kindLabel(finding.kind),
      title: findingTitle(finding, index),
      message: finding.message,
      detail: finding.detail,
      location:
        if finding.hasLocation:
          finding.file & ":" & $finding.range.startLine & ":" & $finding.range.startColumn
        else:
          "",
      excerpt: finding.excerpt,
      isFailure: isFailedObligation(finding.kind),
    )
