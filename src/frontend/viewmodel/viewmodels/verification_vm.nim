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
import ./verification_payload
import ./counterexample_session_vm

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

    payloadStatus*: Signal[PayloadStatus]
      ## VN-M4. Whether this run's structured artifact was found, refused, or
      ## believed. `psAbsent` is the ordinary case for a producer that emits
      ## none, and is **not** a fault — the text tier is a supported tier.
    payload*: Signal[Option[VerificationPayload]]
      ## The structured artifact, when there was one and it was believed.
      ##
      ## Nothing renders it yet. VN-M4 is the contract; VN-M5 is the view. A
      ## payload that is loaded and validated but not yet drawn is exactly the
      ## state this milestone is meant to leave behind, and
      ## `ReplayIsNotOfferedHere` below stays true because of it.
    payloadProblems*: Signal[seq[string]]
      ## Why a payload that was present was refused. Never empty when
      ## `payloadStatus` is `psRejected`, and never populated silently: a
      ## refused artifact is a thing the developer should be able to find out
      ## about, because it usually means the two sides have drifted.
    payloadNotes*: Signal[seq[string]]
      ## Accepted, but disagreeing with the text tier in a way that did not
      ## force a refusal.

    isRunning*: Memo[bool]
    isCancellable*: Memo[bool]
    hasReport*: Memo[bool]
    statusText*: Memo[string]
    outcomeText*: Memo[string]
    markers*: Memo[seq[VerificationMarker]]
    findingCount*: Memo[int]
    failedObligationCount*: Memo[int]
    limitationCount*: Memo[int]

    selectedKey*: Signal[string]
      ## The pane's cursor: the key of the selected line
      ## (`VerificationLine.key`) — a finding, a counterexample offer or a
      ## counterexample step — or `""`. A key rather than an index, so the
      ## cursor stays on its finding when the lines are regrouped, and
      ## falls off (rather than onto a neighbour) when a new run replaces it.
    runnableLabel*: Signal[string]
    runUnavailableReason*: Signal[string]
      ## The run a HOST can start from the pane (the project's declared
      ## Verno action's label), or why it cannot. Both empty on a host that
      ## runs nothing: the panel then draws no Run control, rather than a
      ## control that does nothing.

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
  ##
  ## **VN-M5 did not weaken this, and the distinction is worth stating.** *This
  ## tier* is the text tier: a run whose payload is absent or refused. That is
  ## still every state VN-M3's test drives, and it still renders nothing about
  ## replay. What VN-M5 adds is an affordance that exists only when a payload
  ## has arrived, been believed, and been found to carry a model with steps —
  ## see `counterexampleOffers` below, which is empty in all of those states by
  ## the shape of the data rather than by a flag. `ReplayIsNotOfferedHere`
  ## remains a true statement about the tier it names, and
  ## `CounterexampleIsOfferedOnlyWhenSteppable` is its VN-M5 counterpart.

const CounterexampleIsOfferedOnlyWhenSteppable* = true
  ## VN-M5 deliverable 1's refusal half, named for the same reason its VN-M3
  ## sibling is.
  ##
  ## The offer is gated on `counterexample_session_vm.canOpenCounterexample`,
  ## which is `hasSteppableCounterexample`'s rule narrowed to one finding. A
  ## counterexample with no steps or an unavailable model is a located
  ## obligation and nothing more; a button over it would promise a walk the
  ## payload does not describe, and a *disabled* button would promise one
  ## later. Neither is rendered.

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
    let payloadStatus = createSignal(psAbsent)
    let payload = createSignal(none(VerificationPayload))
    let payloadProblems = createSignal(newSeq[string]())
    let payloadNotes = createSignal(newSeq[string]())
    let selectedKey = createSignal("")
    let runnableLabel = createSignal("")
    let runUnavailableReason = createSignal("")

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
      payloadStatus: payloadStatus,
      payload: payload,
      payloadProblems: payloadProblems,
      payloadNotes: payloadNotes,
      isRunning: isRunning,
      isCancellable: isCancellable,
      hasReport: hasReport,
      statusText: statusText,
      outcomeText: outcomeText,
      markers: markers,
      findingCount: findingCount,
      failedObligationCount: failedObligationCount,
      limitationCount: limitationCount,
      selectedKey: selectedKey,
      runnableLabel: runnableLabel,
      runUnavailableReason: runUnavailableReason,
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
  vm.payloadStatus.val = psAbsent
  vm.payload.val = none(VerificationPayload)
  vm.payloadProblems.val = @[]
  vm.payloadNotes.val = @[]
  vm.selectedKey.val = ""
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
  # And no payload either. A killed run's report file, if one exists, was
  # written by an *earlier* run — the staleness rule would refuse it anyway,
  # but a cancelled run must not even look.
  vm.payloadStatus.val = psAbsent
  vm.payload.val = none(VerificationPayload)
  vm.payloadProblems.val = @[]
  vm.payloadNotes.val = @[]

proc noteFailedToStart*(vm: VerificationVM; reason: string) =
  vm.startFailure.val = reason
  vm.phase.val = vpFailedToStart

proc finish*(vm: VerificationVM; output: string; exitCode: Option[int];
             timedOut = false; payloadText = "";
             runStartedAtUnixMs: int64 = 0) =
  ## The run ended. Classify, assemble, and settle into `vpFinished`.
  ##
  ## A run cancelled by the user is not classified even if output arrived,
  ## for the reason in `noteCancelled`.
  ##
  ## VN-M4 adds `payloadText`: the structured artifact the verifier wrote, or
  ## `""` when it wrote none. The order below is the whole design in three
  ## lines — **the report is built first, from the text, and only then is the
  ## payload offered to it.** A payload never contributes to the verdict; it is
  ## measured against one that already exists. `runStartedAtUnixMs` is what
  ## lets `attachPayload` tell this run's artifact from one left behind by an
  ## earlier one, and it defaults to 0 only so that the many callers with no
  ## payload need not supply it. A caller that passes `payloadText` and leaves
  ## it 0 gets its payload **rejected** — `attachPayload` treats a missing
  ## start time as a rejection rather than as a skipped check, so forgetting
  ## the argument cannot quietly disable the one rule that keeps last week's
  ## counterexample off this week's code.
  if vm.phase.val == vpCancelling:
    vm.noteCancelled()
    return
  let report = reportForRun(
    output, exitCode, timedOut,
    commandLine = vm.commandLine.val,
    projectRoot = vm.projectRoot.val)
  vm.report.val = some(report)

  let attachment = attachPayload(report, payloadText, runStartedAtUnixMs)
  vm.payloadStatus.val = attachment.status
  vm.payload.val = attachment.payload
  vm.payloadProblems.val = attachment.problems
  vm.payloadNotes.val = attachment.notes
  vm.phase.val = vpFinished

proc currentPayload*(vm: VerificationVM): Option[VerificationPayload] =
  vm.payload.val

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

  CounterexampleOffer* = object
    ## VN-M5 deliverable 1: the affordance that turns a failed obligation into
    ## a session, and the thing the "one action" acts on.
    ##
    ## **Built from the payload's findings, not from the text tier's rows**,
    ## and that is the load-bearing choice in this type. A counterexample names
    ## a *payload* finding id. The panel's rows are parsed out of the
    ## verifier's printed diagnostics and carry no such id, so pairing them
    ## would mean matching on message text or on ordinal — a guess. Attaching a
    ## counterexample to the wrong obligation is the same class of error the
    ## producer's `demangle` refuses to make when it will not invent a
    ## `LocalId`: a confident answer that is sometimes about the wrong thing.
    ## So the offer sits beside the rows and names the finding the producer
    ## named.
    findingId*: string
    kindLabel*: string
    message*: string
    location*: string
      ## The finding's own location, or `""`. This is the finding's, not the
      ## counterexample's — the obligation is located even when the steps that
      ## reach it are not.
    stepCount*: int
    modelStatusLabel*: string

  VerificationGroup* = object
    ## PLAT-63. One kind's findings, under a heading naming the kind and the
    ## count.
    kind*: VerificationFindingKind
    heading*: string
    rows*: seq[int]
      ## Indices into `VerificationPanelModel.rows`, in report order.

  VerificationLineKind* = enum
    ## PLAT-63. What one line of the Verification pane's list is.
    vlNote            ## a sentence: the correctness or no-model note, the
                      ## counterexample's provenance and positions
    vlOffer           ## a failed obligation whose counterexample opens
    vlGroup           ## a kind's heading
    vlFinding         ## one finding of the run
    vlCounterexample  ## the open counterexample's heading
    vlStep            ## one step of the open counterexample

  VerificationLine* = object
    ## PLAT-63. One line of the pane, already in words, and the source it
    ## leads to. The desktop's view, the terminal's pane and the GPUI leaf
    ## draw these and nothing else, so the three list the same lines in the
    ## same order.
    kind*: VerificationLineKind
    key*: string
      ## The line's selection key — `finding:<row>`, `offer:<finding id>`,
      ## `step:<index>` — or `""` for a line the cursor skips.
    findingKind*: VerificationFindingKind
    kindLabel*: string
      ## vlFinding / vlOffer: the kind in words.
    title*: string
      ## vlFinding: `findingTitle`; vlStep: the step's kind; vlOffer: the
      ## action's words.
    message*: string
    location*: string
      ## `file:line:column`, `""` when the line has none; vlStep: the
      ## position's words (`position not recorded` for an unknown one).
    text*: string
      ## vlNote / vlGroup / vlCounterexample: the whole line.
    isFailure*: bool
    isCurrent*: bool
      ## vlStep: the step the counterexample is on.
    row*: int
      ## vlFinding: the index into `rows`; vlStep: the step's index; -1.
    findingId*: string
      ## vlOffer: the payload finding whose counterexample it opens.
    hasSource*: bool
    file*: string
    line*, column*: int
      ## Where a press leads (as the verifier spelled the file), when
      ## `hasSource`.
    noSourceReason*: string
      ## Why a press leads nowhere in the source, when it does not.

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
    payloadStatus*: PayloadStatus
      ## Whether the run's structured report was found and attached
      ## (`attachPayload`): drawn as the panel's `data-ct-verification-payload`.
    answersCorrectness*: bool
      ## Whether the run said anything about the program at all. False for
      ## four of the six outcomes, and the view says so in words when it is.
    rows*: seq[VerificationPanelRow]
    modelAbsentReason*: string
      ## The producer's own words for why this run's counterexample carries no
      ## model, or `""`.
      ##
      ## Carried onto the panel so the *absence of the button* has an
      ## explanation next to it. A payload that arrived, was believed, and has
      ## `model.status == unavailable` is the case most likely to be read as a
      ## broken feature, and it is the one where the producer has already
      ## written down the reason.
    counterexampleOffers*: seq[CounterexampleOffer]
      ## Empty for every run without an *attached* payload carrying a
      ## *steppable* counterexample — which is every state VN-M3's
      ## `test_the_text_tier_never_offers_replay` drives, and is why that test
      ## still passes unchanged with this field in place.
    runLabel*: string
      ## The run the host can start (`VerificationVM.runnableLabel`), or `""`
      ## for a host that runs nothing — then no Run control is drawn.
    canRun*: bool
      ## A Run control is drawn and acts: the host offered a run and none is
      ## in flight.
    runUnavailableReason*: string
      ## Why the host cannot run one (no Verno action declared), or `""`.
    groups*: seq[VerificationGroup]
      ## PLAT-63. `rows`, grouped by kind in `FindingGroupOrder` — what every
      ## front-end draws under the header.
    lines*: seq[VerificationLine]
      ## PLAT-63. The whole list every front-end draws, in its order: the
      ## notes, the counterexample offers, the findings by kind, and the
      ## open counterexample's steps. The keys select, the menu and a press
      ## act on these.
    selectedKey*: string

proc kindLabel*(kind: VerificationFindingKind): string =
  case kind
  of vfkProved: "proved"
  of vfkFailedObligation: "failed obligation"
  of vfkLimitation: "verifier limitation"
  of vfkBudgetExhausted: "solver budget exhausted"
  of vfkSolverUnavailable: "solver unavailable"
  of vfkPipelineError: "pipeline error"

proc payloadFindingKindLabel*(kind: PayloadFindingKind): string =
  ## The payload's own finding kinds in words. Spelled to match `kindLabel`
  ## above, because the two vocabularies are the same six and a developer
  ## reading one row and one offer should not meet two names for one thing.
  case kind
  of pfkProved: "proved"
  of pfkFailedObligation: "failed obligation"
  of pfkLimitation: "verifier limitation"
  of pfkBudgetExhausted: "solver budget exhausted"
  of pfkSolverUnavailable: "solver unavailable"
  of pfkPipelineError: "pipeline error"

proc counterexampleOffers*(vm: VerificationVM): seq[CounterexampleOffer] =
  ## Which of this run's findings can be opened as a counterexample session.
  ##
  ## Three conditions, all of them about the data:
  ##
  ## 1. a payload was attached — a rejected or absent one offers nothing;
  ## 2. the finding has a counterexample trace naming it;
  ## 3. that trace has steps and a model that is not `unavailable`.
  ##
  ## Condition 3 is `canOpenCounterexample`, which is
  ## `hasSteppableCounterexample`'s rule narrowed to one finding, so the button
  ## and the session it opens cannot disagree about what is openable.
  if vm.payloadStatus.val != psAttached or vm.payload.val.isNone:
    return @[]
  let payload = vm.payload.val.get
  for finding in payload.findings:
    if not canOpenCounterexample(payload, finding.id):
      continue
    let trace = counterexampleFor(payload, finding.id).get
    result.add CounterexampleOffer(
      findingId: finding.id,
      kindLabel: payloadFindingKindLabel(finding.kind),
      message: finding.message,
      location:
        if finding.hasLocation:
          finding.location.file & ":" &
            $finding.location.range.startLine & ":" &
            $finding.location.range.startColumn
        else:
          "",
      stepCount: trace.steps.len,
      modelStatusLabel: modelStatusLabel(trace.model.status))

proc openCounterexample*(vm: VerificationVM;
                         session: CounterexampleSessionVM;
                         findingId: string): bool {.discardable.} =
  ## **Deliverable 1, as one call.** From a failed obligation in the results
  ## panel to a session sitting on the first step of its counterexample.
  ##
  ## There is no intermediate "load the trace" step and no second click,
  ## because the payload is already in this VM: the run that produced the
  ## obligation produced the model, and `attachPayload` accepted them together.
  ##
  ## Returns false, and closes any session that was open, when the payload is
  ## absent or refused or the finding has nothing steppable — with
  ## `session.refusalReason` saying which.
  if vm.payloadStatus.val != psAttached or vm.payload.val.isNone:
    session.close()
    session.refusalReason.val = NoStepsToOpenReason
    return false
  session.openCounterexample(vm.payload.val.get, findingId)

# ---------------------------------------------------------------------------
# PLAT-63 — the pane every front-end draws: findings by kind, the lines, the
# cursor, a press and the row menu
# ---------------------------------------------------------------------------

const
  FindingGroupOrder* = [vfkFailedObligation, vfkPipelineError,
                        vfkBudgetExhausted, vfkSolverUnavailable,
                        vfkLimitation, vfkProved]
    ## The order the kinds' groups are listed in: what the developer must act
    ## on first. A failed obligation is a claim about the program; a pipeline
    ## error and a spent budget are the run not finishing; a missing solver
    ## is the machine; a limitation is the verifier; `proved` needs nothing.

  NoSourceLocationReason* = "this finding has no source location"
    ## Why a finding's press and its Go to Source lead nowhere. The text tier
    ## states it rather than inventing line 1 (`editorMarkers`' rule).
  OpenCounterexampleLabel* = "Step through the counterexample"
    ## An offer's words: the desktop's button.
  CounterexampleProvenanceNote* = SolverDerivedProvenance
    ## The open counterexample's banner, on every front-end.

proc groupHeading*(kind: VerificationFindingKind; count: int): string =
  ## A kind's group heading: the kind in words and how many there are.
  kindLabel(kind) & " (" & $count & ")"

proc findingKey*(row: int): string = "finding:" & $row
proc offerKey*(findingId: string): string = "offer:" & findingId
proc stepKey*(index: int): string = "step:" & $index

proc locationText(file: string; line, column: int): string =
  file & ":" & $line & ":" & $column

proc correctnessNoteText*(model: VerificationPanelModel): string =
  ## The sentence that keeps four of the six outcomes from reading as a
  ## verdict on the program.
  if not model.hasReport or model.answersCorrectness:
    return ""
  "Nothing was proved or disproved about this program."

proc noModelNoteText*(model: VerificationPanelModel): string =
  ## The sentence shown when a payload arrived, was believed, and carries no
  ## model to walk.
  if model.counterexampleOffers.len > 0 or model.modelAbsentReason.len == 0:
    return ""
  "No counterexample to step through: " & model.modelAbsentReason

proc groupsOf(rows: openArray[VerificationPanelRow]): seq[VerificationGroup] =
  for kind in FindingGroupOrder:
    var group = VerificationGroup(kind: kind)
    for index, row in rows:
      if row.kind == kind:
        group.rows.add index
    if group.rows.len > 0:
      group.heading = groupHeading(kind, group.rows.len)
      result.add group

proc linesOf(model: VerificationPanelModel; report: Option[VerificationReport];
             payload: Option[VerificationPayload];
             session: CounterexampleSessionVM): seq[VerificationLine] =
  ## The pane's list, in the order every front-end draws it.
  for note in [correctnessNoteText(model), noModelNoteText(model)]:
    if note.len > 0:
      result.add VerificationLine(kind: vlNote, text: note, row: -1,
                                  noSourceReason: "")
  for offer in model.counterexampleOffers:
    var line = VerificationLine(kind: vlOffer, key: offerKey(offer.findingId),
                                findingKind: vfkFailedObligation,
                                kindLabel: offer.kindLabel,
                                title: OpenCounterexampleLabel,
                                message: offer.message,
                                location: offer.location, isFailure: true,
                                row: -1, findingId: offer.findingId)
    if payload.isSome:
      for finding in payload.get.findings:
        if finding.id == offer.findingId:
          if finding.hasLocation:
            line.hasSource = true
            line.file = finding.location.file
            line.line = finding.location.range.startLine
            line.column = finding.location.range.startColumn
          else:
            line.noSourceReason =
              if finding.locationAbsentReason.len > 0:
                finding.locationAbsentReason
              else: NoSourceLocationReason
    result.add line
  for group in model.groups:
    result.add VerificationLine(kind: vlGroup, findingKind: group.kind,
                                kindLabel: kindLabel(group.kind),
                                text: group.heading, row: -1)
    for index in group.rows:
      let row = model.rows[index]
      var line = VerificationLine(kind: vlFinding, key: findingKey(index),
                                  findingKind: row.kind,
                                  kindLabel: row.kindLabel, title: row.title,
                                  message: row.message,
                                  location: row.location,
                                  isFailure: row.isFailure, row: index)
      if report.isSome and index < report.get.findings.len and
         report.get.findings[index].hasLocation:
        let finding = report.get.findings[index]
        line.hasSource = true
        line.file = finding.file
        line.line = finding.range.startLine
        line.column = finding.range.startColumn
      else:
        line.noSourceReason = NoSourceLocationReason
      result.add line
  if session.isNil or not session.isOpen.val:
    return
  let cx = sessionModel(session)
  result.add VerificationLine(kind: vlCounterexample, text: cx.title, row: -1)
  result.add VerificationLine(kind: vlNote, text: cx.provenance, row: -1)
  let positions = positionSummary(cx)
  if positions.len > 0:
    result.add VerificationLine(kind: vlNote, text: positions, row: -1)
  for step in cx.rows:
    var words = step.description
    for binding in step.bindings:
      if words.len > 0:
        words.add "  "
      words.add binding.name & " = " & binding.value
    var line = VerificationLine(kind: vlStep, key: stepKey(step.index),
                                title: step.kindLabel, message: words,
                                location: step.positionText,
                                isFailure: step.isViolation,
                                isCurrent: step.isCurrent, row: step.index)
    if step.position.isKnown:
      line.hasSource = true
      line.file = step.position.file
      line.line = step.position.line
      line.column = max(1, step.position.column)
    else:
      line.noSourceReason = UnknownPositionText & ": " & step.position.reason
    result.add line

proc panelModel*(vm: VerificationVM;
                 session: CounterexampleSessionVM = nil):
                 VerificationPanelModel =
  ## The whole panel as a plain record, so the view is a pure function of it
  ## and every renderer paints the same tree. `session` adds the open
  ## counterexample's lines (PLAT-63); without it the list stops at the
  ## findings.
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
    payloadStatus: vm.payloadStatus.val,
    counterexampleOffers: counterexampleOffers(vm),
    modelAbsentReason:
      if vm.payloadStatus.val == psAttached and vm.payload.val.isSome:
        modelIsAbsentBecause(vm.payload.val.get)
      else:
        "",
    runLabel: vm.runnableLabel.val,
    canRun: vm.runnableLabel.val.len > 0 and not vm.isRunning.val,
    runUnavailableReason: vm.runUnavailableReason.val,
    selectedKey: vm.selectedKey.val,
  )
  let report = vm.report.val
  if report.isSome:
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
            locationText(finding.file, finding.range.startLine,
                         finding.range.startColumn)
          else:
            "",
        excerpt: finding.excerpt,
        isFailure: isFailedObligation(finding.kind),
      )
  result.groups = groupsOf(result.rows)
  let payload =
    if vm.payloadStatus.val == psAttached: vm.payload.val
    else: none(VerificationPayload)
  result.lines = linesOf(result, report, payload, session)

# ---------------------------------------------------------------------------
# The cursor
# ---------------------------------------------------------------------------

proc selectableKeys*(lines: openArray[VerificationLine]): seq[string] =
  ## The keys the cursor moves through, in list order.
  for line in lines:
    if line.key.len > 0:
      result.add line.key

proc lineOfKey*(lines: openArray[VerificationLine]; key: string): int =
  ## The list index of the line `key` names, -1 when it is not listed.
  if key.len == 0:
    return -1
  for i, line in lines:
    if line.key == key:
      return i
  -1

proc selectLine*(vm: VerificationVM; key: string) =
  ## Put the cursor on `key` (`""` clears it).
  vm.selectedKey.val = key

proc moveSelection*(vm: VerificationVM; session: CounterexampleSessionVM;
                    delta: int; toEnd = false): string =
  ## Move the cursor `delta` selectable lines (clamped), or to the first /
  ## last with `toEnd` (the sign of `delta` saying which). From no cursor,
  ## a move down lands on the first line and a move up on the last. Answers
  ## the key the cursor is on, `""` when the list has nothing to select.
  let keys = selectableKeys(panelModel(vm, session).lines)
  if keys.len == 0:
    vm.selectedKey.val = ""
    return ""
  let at = keys.find(vm.selectedKey.val)
  let next =
    if toEnd: (if delta < 0: 0 else: keys.high)
    elif at < 0: (if delta < 0: keys.high else: 0)
    else: clamp(at + delta, 0, keys.high)
  vm.selectedKey.val = keys[next]
  keys[next]

# ---------------------------------------------------------------------------
# A press, and Enter
# ---------------------------------------------------------------------------

type
  VerificationActivationKind* = enum
    vakNone            ## nothing to go to; `note` says why
    vakSource          ## go to `file:line:column` in the editor
    vakCounterexample  ## the counterexample opened in the pane
    vakStep            ## the counterexample moved to a step with no position

  VerificationActivation* = object
    kind*: VerificationActivationKind
    file*: string
      ## vakSource: the file as the verifier spelled it — resolve it with
      ## `sourceCandidates`.
    line*, column*: int
    note*: string
      ## What the press did, in words, for the status line.

proc sourceCandidates*(vm: VerificationVM; file: string): seq[string] =
  ## Where `file`, as the verifier spelled it, may be on disk, best first.
  ##
  ## The payload spells a file from the verified package's root
  ## (`src/main.nr`); the text tier prints what Noir's reporter prints, a
  ## path from the package root's PARENT (`typeerr/src/main.nr` for the
  ## package `typeerr`, measured on a real run — see the VN-M4 corpus'
  ## PROVENANCE). So the candidates are the path under the run's project
  ## root, then under its parent; nothing is guessed beyond those two. The
  ## VM reads no filesystem (it compiles to JS too): the host opens the
  ## first that exists.
  if file.len == 0:
    return @[]
  if file.startsWith("/"):
    return @[file]
  var root = vm.projectRoot.val
  while root.len > 1 and root.endsWith("/"):
    root.setLen(root.len - 1)
  if root.len == 0:
    return @[file]
  result.add root & "/" & file
  let slash = root.rfind('/')
  if slash > 0:
    result.add root[0 ..< slash] & "/" & file

proc activateLine*(vm: VerificationVM; session: CounterexampleSessionVM;
                   key: string): VerificationActivation =
  ## A press on the line `key` names, or Enter on it: the line selected,
  ## and then
  ##
  ## * a finding goes to its source location, or says it has none;
  ## * an offer opens its counterexample in the pane (`openCounterexample`,
  ##   VN-M5's one action);
  ## * a step becomes the counterexample's current step, and goes to its
  ##   source position when it has one — `position not recorded` otherwise,
  ##   never a guessed line.
  let lines = panelModel(vm, session).lines
  let at = lineOfKey(lines, key)
  if at < 0:
    return VerificationActivation(kind: vakNone,
                                  note: "that line is no longer listed")
  vm.selectedKey.val = key
  let line = lines[at]
  case line.kind
  of vlOffer:
    if session.isNil:
      return VerificationActivation(kind: vakNone,
        note: "this window cannot show a counterexample")
    if vm.openCounterexample(session, line.findingId):
      VerificationActivation(kind: vakCounterexample,
        note: "counterexample of " & line.message & ": " &
              $session.stepCount.val & " steps")
    else:
      VerificationActivation(kind: vakNone, note: session.refusalReason.val)
  of vlStep:
    if not session.isNil:
      session.goToStep(line.row)
    if line.hasSource:
      VerificationActivation(kind: vakSource, file: line.file,
                             line: line.line, column: line.column,
                             note: "step " & $(line.row + 1) & ": " &
                                   line.location)
    else:
      VerificationActivation(kind: vakStep,
        note: "step " & $(line.row + 1) & ": " & UnknownPositionText)
  of vlFinding:
    if line.hasSource:
      VerificationActivation(kind: vakSource, file: line.file,
                             line: line.line, column: line.column,
                             note: line.location)
    else:
      VerificationActivation(kind: vakNone, note: line.noSourceReason)
  of vlNote, vlGroup, vlCounterexample:
    VerificationActivation(kind: vakNone)

# ---------------------------------------------------------------------------
# The row menu
# ---------------------------------------------------------------------------

type
  VerificationMenuAction* = enum
    vmaGoToSource = "Go to Source"
    vmaOpenCounterexample = "Step Through the Counterexample"
    vmaCopyMessage = "Copy Message"
    vmaCopyLocation = "Copy Location"
    vmaCloseCounterexample = "Close the Counterexample"

  VerificationMenuEntry* = object
    label*: string
    action*: VerificationMenuAction
    enabled*: bool
    reason*: string
      ## Why it is disabled, `""` when it is not.

  VerificationMenuOutcome* = object
    activation*: VerificationActivation
      ## Go to Source and Step Through: what the press would have done.
    copied*: string
      ## The text to put on the clipboard, `""` for none.
    note*: string

proc entry(action: VerificationMenuAction; reason = ""): VerificationMenuEntry =
  VerificationMenuEntry(label: $action, action: action,
                        enabled: reason.len == 0, reason: reason)

proc rowMenu*(vm: VerificationVM; session: CounterexampleSessionVM;
              key: string): seq[VerificationMenuEntry] =
  ## The right press's menu on the line `key` names — the same entries, in
  ## the same order, with the same reasons, on every front-end. Empty for a
  ## line that is not listed or cannot be selected.
  let lines = panelModel(vm, session).lines
  let at = lineOfKey(lines, key)
  if at < 0:
    return @[]
  let line = lines[at]
  let noSource = if line.hasSource: "" else: line.noSourceReason
  case line.kind
  of vlOffer:
    result.add entry(vmaOpenCounterexample)
    result.add entry(vmaGoToSource, noSource)
    result.add entry(vmaCopyMessage)
    result.add entry(vmaCopyLocation,
                     if line.location.len > 0: "" else: NoSourceLocationReason)
  of vlFinding:
    result.add entry(vmaGoToSource, noSource)
    result.add entry(vmaCopyMessage)
    result.add entry(vmaCopyLocation,
                     if line.location.len > 0: "" else: NoSourceLocationReason)
  of vlStep:
    result.add entry(vmaGoToSource, noSource)
    result.add entry(vmaCopyMessage)
    result.add entry(vmaCloseCounterexample)
  of vlNote, vlGroup, vlCounterexample:
    discard

proc runRowMenu*(vm: VerificationVM; session: CounterexampleSessionVM;
                 key: string;
                 action: VerificationMenuAction): VerificationMenuOutcome =
  ## Choose `action` from the menu of the line `key` names, as the menu
  ## decides it NOW: nothing runs for an entry the line's menu does not have
  ## or has disabled.
  var chosen = false
  for e in rowMenu(vm, session, key):
    if e.action == action:
      if not e.enabled:
        return VerificationMenuOutcome(note: e.reason)
      chosen = true
  if not chosen:
    return VerificationMenuOutcome(note: "that line is no longer listed")
  let lines = panelModel(vm, session).lines
  let line = lines[lineOfKey(lines, key)]
  vm.selectedKey.val = key
  case action
  of vmaGoToSource:
    if line.kind == vlStep and not session.isNil:
      session.goToStep(line.row)
    result.activation = VerificationActivation(kind: vakSource,
      file: line.file, line: line.line, column: line.column,
      note: locationText(line.file, line.line, line.column))
    result.note = result.activation.note
  of vmaOpenCounterexample:
    result.activation = activateLine(vm, session, key)
    result.note = result.activation.note
  of vmaCopyMessage:
    result.copied =
      if line.kind == vlStep: line.title & ": " & line.message
      else: line.message
    result.note = "copied the message"
  of vmaCopyLocation:
    result.copied = line.location
    result.note = "copied " & line.location
  of vmaCloseCounterexample:
    if not session.isNil:
      session.close()
    vm.selectedKey.val = ""
    result.note = "closed the counterexample"

# ---------------------------------------------------------------------------
# The run a host offers
# ---------------------------------------------------------------------------

const
  NoVernoActionReason* =
    "this project declares no Verno action (.vscode/tasks.json or " &
    "package.json)"
  NoProjectReason* = "this window has no project to verify"
    ## Why a host offers no run, in the words every front-end shows: the
    ## native host (`host/native_verification_host`) and the desktop's
    ## (`ui/verification`) both say these.

proc offerRun*(vm: VerificationVM; label: string; unavailableReason = "") =
  ## A host that can run the project's verifier says so: `label` is the
  ## declared action's (`""` with `unavailableReason` when none is declared).
  vm.runnableLabel.val = label
  vm.runUnavailableReason.val = unavailableReason
