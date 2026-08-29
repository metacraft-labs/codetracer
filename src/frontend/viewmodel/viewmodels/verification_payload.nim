## NOT-A-TEST-LANE-FILE: production ViewModel-layer code. It declares no
## `suite`/`test` blocks; its behaviour is asserted by
## `src/frontend/viewmodel/tests/unit/test_verification_payload.nim`.

## viewmodels/verification_payload.nim
##
## VN-M4 — the structured artifact a verifier hands us, and what we refuse.
##
## `verification_report.nim` is the text tier: it reads what a verifier
## *printed*. This module reads what a verifier *emitted*, as one JSON document
## per run, and it is the consumer half of the contract specified in
## `codetracer-specs/Planned-Features/SMT-Counterexample-And-Prover-State-Visualization.md`
## and implemented on the producer side in `blocksense-network/verno` at
## `formal_verification/src/payload/`.
##
## The spec owns the payload names. `SolverCounterexampleTrace`,
## `ProofGoalTree`, `ProverStateFrame`, `SolverQueryAttachment` and
## `ProofVisualizationSourceMap` appear below spelled as the spec spells them,
## because this campaign contributes a producer and a consumer, not a second
## schema.
##
## ## What this module is for, in one sentence
##
## To make it impossible for a structured artifact to say something the text
## tier would not have said — while letting it say much *more*.
##
## ## The four rules it enforces, and why each one exists
##
## **1. An unrecognised schema is refused, never guessed at.** A document whose
## `schema` is not `codetracer.verification/v1` is not "mostly compatible"; it
## is a document written to a contract we have not read.
##
## **2. Trust is never assumed.** Every payload, and every finding,
## counterexample, goal tree and query inside it, carries a trust class from the
## four the spec names, and a document missing one is rejected rather than
## displayed at some level we picked. The whole reason the field exists is that
## a diagnostic must not be read as proof evidence, and a defaulted value would
## defeat it silently — so the value a *failed* decode leaves behind is
## `diagnostic-only`, twice over: `PayloadTrustClass` is declared
## least-trusting-first so the type's zero value is safe, and `decodeTrust`
## sets it explicitly as well.
##
## **3. The six outcomes survive.** The payload's outcome decodes into
## `verification_report.VerificationOutcome` — the *same* type the text tier
## uses, so there is no translation table to drift. An outcome string that is
## not one of the six is a rejection, not a fallback.
##
## **4. The text tier keeps the verdict; the payload supplies the structure.**
## This is the load-bearing asymmetry. `classifyVernoRun` has been attacked and
## has held; a payload arriving from a process we do not control has not. So an
## attached payload never changes `report.outcome`, and two specific
## disagreements are rejections rather than notes:
##
##   * a payload claiming `proved` where the text tier did not — it would turn
##     a failed run green;
##   * a payload *not* claiming a failed proof where the text tier found one —
##     it would hide a failure.
##
## Any other disagreement is recorded as a note and the payload is still
## attached, because the producer genuinely knows things the text cannot see.
##
## **A fifth rule that is not about content at all: a stale payload is
## refused.** The report file lives at a fixed path and survives the run that
## wrote it. Reading last week's counterexample for code the developer has since
## fixed is the most dangerous thing this contract could do, so a payload whose
## run started before *this* run started is rejected on sight.
##
## ## What this tier still does not do
##
## It does not render anything. VN-M4 is the contract; VN-M5 is the
## counterexample view. `verification_vm`'s `ReplayIsNotOfferedHere` stays true
## and the rendered panel is unchanged — a payload that is loaded and validated
## but not yet drawn is exactly the state this milestone is meant to leave
## behind.
##
## Pure and plain-valued throughout — no `cstring`, no filesystem, no process —
## so it is asserted on both the C (`vm-unit`) and JS (`vm-unit-js`) backends.
## The reader that touches the disk lives in
## `host/project_action_runner.nim`, following the same split
## `project_actions.parseTasksJson` / `project_action_runner.loadProjectActions`
## already uses.

import std/[json, options, strutils]

import ../../../ct_test/contracts
import ./verification_report

const PayloadSchemaId* = "codetracer.verification/v1"
  ## The only schema this consumer understands. Shared verbatim with the
  ## producer's `formal_verification::payload::SCHEMA_ID`.

const PayloadFileName* = "verno-report.json"
  ## The name the producer writes inside the package's target directory.
  ##
  ## A convention rather than a flag, and deliberately so: Noir-Studio.md §9.3
  ## has CodeTracer surface the actions a project declares and "invent no
  ## manifest of our own", so we run the project's own `tasks.json` command
  ## verbatim and cannot append `--report-json` to it. The producer writes the
  ## file without being asked, or there is no payload and the text tier stands.

const StalePayloadToleranceMs* = 2_000
  ## How far before the run's own start a payload's timestamp may sit before it
  ## is called stale. The producer records its start *after* the process is
  ## running, so a conforming payload is always at or after ours; the tolerance
  ## covers clock granularity, not a real ordering difference.

type
  PayloadTrustClass* = enum
    ## The four classes
    ## `SMT-Counterexample-And-Prover-State-Visualization.md` lists under "The
    ## payload must record whether the displayed data is". They line up with
    ## GRIP's `EvidenceDispositionIR`, minus its `rejected`, which describes an
    ## *attempt* rather than displayed data.
    ##
    ## The spec lists them most-trusted first. They are declared here in the
    ## opposite order, deliberately, because **a Nim enum's zero value is its
    ## first member** and a zero-initialised `PayloadTrust` is what a caller
    ## holds after a decode that failed. Declared the spec's way round, that
    ## default would read `checked-by-trusted-core` — the strongest claim in the
    ## vocabulary — out of an object that made no claim at all, which is the
    ## exact inversion this field exists to prevent. The least trusting value is
    ## therefore the one you get for free.
    ptcDiagnosticOnly = "diagnostic-only"
    ptcSolverOracle = "solver-oracle"
    ptcProofReconstructed = "proof-reconstructed"
    ptcCheckedByTrustedCore = "checked-by-trusted-core"

  PayloadOracleFootprint* = object
    ## What a `solver-oracle` claim rests on. Every field the producer could
    ## not fill is accompanied by the reason it could not — a footprint whose
    ## gaps were simply omitted would claim a more complete audit trail than
    ## exists.
    tool*: string
    toolArgs*: seq[string]
    exitCode*: Option[int]
    solver*: string
    solverAbsentReason*: string
    statistics*: seq[(string, string)]
    statisticsAbsentReason*: string

  PayloadTrust* = object
    class*: PayloadTrustClass
    reason*: string
    hasOracleFootprint*: bool
    oracleFootprint*: PayloadOracleFootprint

  PayloadSourceFile* = object
    index*: int
    path*: string
    absolutePath*: string

  ProofVisualizationSourceMap* = object
    ## The spec's `ProofVisualizationSourceMap`. Verno's mapping is one level
    ## deep — Noir source ranges only — because the VIR it builds is consumed
    ## in-process and never shown. `generatedOrigin` on a `ProverStateFrame` is
    ## where a deeper mapping would go.
    files*: seq[PayloadSourceFile]

  PayloadLocation* = object
    file*: string
    fileIndex*: int
    range*: SourceRange
      ## One-based lines and columns, the same numbers
      ## `noirc_errors::reporter` prints and the same numbers the text tier's
      ## parser reads out of that printing.
    byteStart*: int
    byteEnd*: int

  PayloadFindingKind* = enum
    ## Spelled exactly as `VerificationFindingKind` is spelled, so the two can
    ## be compared without a translation table.
    pfkProved = "proved"
    pfkFailedObligation = "failed-obligation"
    pfkLimitation = "limitation"
    pfkBudgetExhausted = "budget-exhausted"
    pfkSolverUnavailable = "solver-unavailable"
    pfkPipelineError = "pipeline-error"

  PayloadFinding* = object
    id*: string
    kind*: PayloadFindingKind
    message*: string
    detail*: string
    construct*: string
    hasLocation*: bool
    location*: PayloadLocation
    locationAbsentReason*: string
      ## Required whenever `hasLocation` is false. The producer says why it
      ## cannot point at a line rather than pointing at line 1.
    excerpt*: string
    trust*: PayloadTrust

  ModelStatus* = enum
    pmsComplete = "complete"
    pmsPartial = "partial"
    pmsUnavailable = "unavailable"

  ModelBinding* = object
    name*: string
      ## The developer's own name for the variable. The producer preserves it
      ## into the solver query, so a model value can be shown in the
      ## vocabulary of the source rather than of the encoding.
    localId*: Option[int]
    value*: string
    typeName*: string
    hasLocation*: bool
    location*: PayloadLocation

  CounterexampleModel* = object
    status*: ModelStatus
    absentReason*: string
      ## Required whenever `status` is not `pmsComplete`. An empty binding list
      ## with no status would read as "the solver found no relevant variables",
      ## which is a different and false claim.
    bindings*: seq[ModelBinding]

  CounterexampleStepKind* = enum
    cskAssumption = "assumption"
    cskAssignment = "assignment"
    cskBranch = "branch"
    cskLoopIteration = "loop-iteration"
    cskCall = "call"
    cskViolation = "violation"

  CounterexampleStep* = object
    index*: int
    kind*: CounterexampleStepKind
    hasLocation*: bool
    location*: PayloadLocation
    description*: string
    bindings*: seq[ModelBinding]
    taken*: Option[bool]
    iteration*: Option[int]
    pathCondition*: string

  ObligationKind* = enum
    pokPrecondition = "precondition"
    pokPostcondition = "postcondition"
    pokAssertion = "assertion"
    pokLoopInvariant = "loop-invariant"
    pokLoopDecreases = "loop-decreases"
    pokArithmeticOverflow = "arithmetic-overflow"
    pokOther = "other"

  ViolatedObligation* = object
    kind*: ObligationKind
    rawKind*: string
      ## The verifier's own wording, always — whether or not `kind` is
      ## `pokOther`. Categorising is a convenience; the verifier's words are
      ## the evidence.
    hasLocation*: bool
    location*: PayloadLocation
    message*: string

  SolverCounterexampleTrace* = object
    ## The spec's `SolverCounterexampleTrace`.
    id*: string
    findingId*: string
    trust*: PayloadTrust
    model*: CounterexampleModel
    steps*: seq[CounterexampleStep]
    hasViolatedObligation*: bool
    violatedObligation*: ViolatedObligation
    solverQueryId*: string
    isRecordedExecution*: bool
      ## Always false in any payload we accept. The field is required on the
      ## wire rather than merely absent so that the spec's rule — "must not be
      ## presented as recorded runtime evidence" — is something a decoder can
      ## check rather than something a renderer has to remember.

  ProofNodeKind* = enum
    pnkSourceObligation = "source-obligation"
    pnkTacticStep = "tactic-step"
    pnkSubgoal = "subgoal"
    pnkSmtQuery = "smt-query"
    pnkSolverResult = "solver-result"

  Hypothesis* = object
    name*: string
    statement*: string
    hasLocation*: bool
    location*: PayloadLocation

  ProverStateFrame* = ref object
    ## The spec's `ProverStateFrame`. A `ref` because the tree is recursive.
    id*: string
      ## Stable across regenerations of the same artifact, which is what lets a
      ## view keep the user's expansion state — the spec's
      ## `SolverViz.GeneratedOriginStable`.
    kind*: ProofNodeKind
    goal*: string
    hypotheses*: seq[Hypothesis]
    hasLocation*: bool
    location*: PayloadLocation
    generatedOrigin*: string
    producedBy*: string
    solverQueryId*: string
    children*: seq[ProverStateFrame]

  ProofGoalTree* = object
    ## The spec's `ProofGoalTree`.
    id*: string
    findingId*: string
    trust*: PayloadTrust
    root*: ProverStateFrame

  ReplayStatus* = enum
    prsNotAttempted = "not-attempted"
    prsReproduced = "reproduced"
    prsDiverged = "diverged"

  SolverQueryAttachment* = object
    ## The spec's `SolverQueryAttachment`.
    id*: string
    trust*: PayloadTrust
    smtlib*: string
    smtlibAbsentReason*: string
    options*: seq[string]
    rlimit*: Option[int]
    unsatCore*: seq[string]
    hasUnsatCore*: bool
    unsatCoreAbsentReason*: string
    statistics*: seq[(string, string)]
    statisticsAbsentReason*: string
    replayStatus*: ReplayStatus

  VerificationPayload* = object
    schema*: string
    producerName*: string
    producerVersion*: string
    sourceLanguage*: string
    languageRelease*: string

    startedAtUnixMs*: int64
    finishedAtUnixMs*: int64
    workspaceRoot*: string
    package*: string
    entryFile*: string
    argv*: seq[string]
    solverInvoked*: bool
    solverName*: string
    solverUnavailableReason*: string

    outcome*: VerificationOutcome
      ## The *same* enum the text tier uses. Sharing the type is what makes
      ## "the six outcomes survive the contract" a property of the code rather
      ## than of a comment.
    outcomeDetail*: string
    trust*: PayloadTrust
    findings*: seq[PayloadFinding]
    counterexampleTraces*: seq[SolverCounterexampleTrace]
    goalTrees*: seq[ProofGoalTree]
    solverQueries*: seq[SolverQueryAttachment]
    sourceMap*: ProofVisualizationSourceMap

  PayloadDecode* = object
    ## Either a payload or the reasons there is not one. Never both, and never
    ## a half-decoded payload: a consumer that displayed the readable half of a
    ## malformed document would be showing a developer a claim nobody made.
    ok*: bool
    payload*: VerificationPayload
    problems*: seq[string]

  PayloadStatus* = enum
    ## What happened when a run's payload was looked for.
    psAbsent = "absent"
      ## No payload. **Not a fault.** A producer we cannot identify, or an
      ## older Verno, leaves the text tier standing, and the text tier is a
      ## supported tier.
    psRejected = "rejected"
      ## A payload was present and refused. Always with stated reasons, never
      ## silently.
    psAttached = "attached"

  PayloadAttachment* = object
    status*: PayloadStatus
    payload*: Option[VerificationPayload]
    problems*: seq[string]
      ## Why it was rejected. Empty unless `status` is `psRejected`.
    notes*: seq[string]
      ## Accepted, but worth saying out loud — a disagreement with the text
      ## tier that is not one of the two that force a rejection.

# ---------------------------------------------------------------------------
# Small decoding helpers
# ---------------------------------------------------------------------------
#
# `ct_test/contracts.nim` has private versions of these and this module cannot
# import them, so they are re-declared here — the same choice
# `project_actions.readJson` made, and for the same reason.

proc has(node: JsonNode; name: string): bool =
  not node.isNil and node.kind == JObject and node.hasKey(name) and
    node[name].kind != JNull

proc str(node: JsonNode; name: string; default = ""): string =
  if node.has(name) and node[name].kind == JString: node[name].getStr else: default

proc num(node: JsonNode; name: string; default = 0): int =
  if node.has(name) and node[name].kind in {JInt, JFloat}: node[name].getInt else: default

proc bignum(node: JsonNode; name: string; default: int64 = 0): int64 =
  if node.has(name) and node[name].kind in {JInt, JFloat}:
    node[name].getBiggestInt
  else:
    default

proc flag(node: JsonNode; name: string; default = false): bool =
  if node.has(name) and node[name].kind == JBool: node[name].getBool else: default

proc optionalInt(node: JsonNode; name: string): Option[int] =
  if node.has(name) and node[name].kind in {JInt, JFloat}:
    some(node[name].getInt)
  else:
    none(int)

proc optionalBool(node: JsonNode; name: string): Option[bool] =
  if node.has(name) and node[name].kind == JBool:
    some(node[name].getBool)
  else:
    none(bool)

proc strings(node: JsonNode; name: string): seq[string] =
  if node.has(name) and node[name].kind == JArray:
    for item in node[name]:
      if item.kind == JString:
        result.add item.getStr

proc stringPairs(node: JsonNode; name: string): seq[(string, string)] =
  if node.has(name) and node[name].kind == JObject:
    for key, value in node[name]:
      result.add (key, if value.kind == JString: value.getStr else: $value)

proc decodeEnum[T: enum](raw, what: string; problems: var seq[string];
                         into: var T): bool =
  ## Enum values are decoded by their *declared* spelling and nothing else.
  ##
  ## There is no fallback arm. That is the whole point: an unknown outcome
  ## string must be a rejection, because the alternative is choosing one of the
  ## six on the document's behalf — and five of the six are claims about
  ## whether the developer's program is correct.
  for value in T:
    if $value == raw:
      into = value
      return true
  problems.add what & " is `" & raw & "`, which is not one of the values this " &
    "contract defines"
  false

# ---------------------------------------------------------------------------
# Decoding the pieces
# ---------------------------------------------------------------------------

proc decodeTrust(node: JsonNode; what: string;
                 problems: var seq[string]): PayloadTrust =
  ## Rule 2, in one function.
  ##
  ## Called for the envelope and for every finding, counterexample, goal tree
  ## and solver query — because "every payload carries its trust class" is
  ## about every payload, and a nested object with no class would be displayed
  ## alongside one that has a class and be read as sharing it.
  # Said twice on purpose. `PayloadTrustClass` is declared least-trusting-first
  # so that a zero value is safe, and this line states the same thing at the
  # place it matters, so that reordering the enum for readability cannot
  # silently make a failed decode look trusted.
  result.class = ptcDiagnosticOnly
  if not node.has("trust"):
    problems.add what & " carries no trust class; a payload without one is " &
      "refused rather than displayed at an assumed level"
    return
  let trustNode = node["trust"]
  if trustNode.kind != JObject:
    problems.add what & "'s trust is not an object"
    return
  if not decodeEnum(trustNode.str("class"), what & "'s trust class", problems,
                    result.class):
    return
  result.reason = trustNode.str("reason")
  if result.reason.strip().len == 0:
    problems.add what & " states a trust class with no reason; a class with " &
      "no stated basis is exactly what this field exists to prevent"
  if trustNode.has("oracle_footprint"):
    let footprint = trustNode["oracle_footprint"]
    result.hasOracleFootprint = true
    result.oracleFootprint = PayloadOracleFootprint(
      tool: footprint.str("tool"),
      toolArgs: footprint.strings("tool_args"),
      exitCode: footprint.optionalInt("exit_code"),
      solver: footprint.str("solver"),
      solverAbsentReason: footprint.str("solver_absent_reason"),
      statistics: footprint.stringPairs("statistics"),
      statisticsAbsentReason: footprint.str("statistics_absent_reason"),
    )
    if result.oracleFootprint.solver.len == 0 and
        result.oracleFootprint.solverAbsentReason.len == 0:
      problems.add what & "'s oracle footprint names no solver and gives no reason"
    if result.oracleFootprint.statistics.len == 0 and
        result.oracleFootprint.statisticsAbsentReason.len == 0:
      problems.add what & "'s oracle footprint has no statistics and gives no reason"
  if result.class == ptcSolverOracle and not result.hasOracleFootprint:
    problems.add what & " claims `solver-oracle` trust with no oracle footprint"
  if result.class != ptcSolverOracle and result.hasOracleFootprint:
    problems.add what & " carries an oracle footprint but is not `solver-oracle`"

proc decodeLocation(node: JsonNode; found: var bool): PayloadLocation =
  found = false
  if node.isNil or node.kind != JObject:
    return
  found = true
  PayloadLocation(
    file: node.str("file"),
    fileIndex: node.num("file_index"),
    range: SourceRange(
      startLine: node.num("start_line"),
      startColumn: node.num("start_column"),
      endLine: node.num("end_line"),
      endColumn: node.num("end_column"),
    ),
    byteStart: node.num("byte_start"),
    byteEnd: node.num("byte_end"),
  )

proc decodeOptionalLocation(parent: JsonNode; name: string;
                            found: var bool): PayloadLocation =
  if parent.has(name):
    decodeLocation(parent[name], found)
  else:
    found = false
    PayloadLocation()

proc decodeBindings(parent: JsonNode; name: string): seq[ModelBinding] =
  if not parent.has(name) or parent[name].kind != JArray:
    return
  for node in parent[name]:
    var hasLocation = false
    let location = decodeOptionalLocation(node, "location", hasLocation)
    result.add ModelBinding(
      name: node.str("name"),
      localId: node.optionalInt("local_id"),
      value: node.str("value"),
      typeName: node.str("type_name"),
      hasLocation: hasLocation,
      location: location,
    )

proc decodeFinding(node: JsonNode; index: int;
                   problems: var seq[string]): PayloadFinding =
  let what = "finding " & $index
  result.id = node.str("id")
  if result.id.len == 0:
    problems.add what & " has no id; counterexamples and goal trees refer to " &
      "findings by id, so an unnamed finding cannot be referred to"
  discard decodeEnum(node.str("kind"), what & "'s kind", problems, result.kind)
  result.message = node.str("message")
  result.detail = node.str("detail")
  result.construct = node.str("construct")
  result.excerpt = node.str("excerpt")
  result.location = decodeOptionalLocation(node, "location", result.hasLocation)
  result.locationAbsentReason = node.str("location_absent_reason")
  if not result.hasLocation and result.locationAbsentReason.len == 0:
    problems.add what & " has no source location and does not say why; a " &
      "marker on an arbitrary line is a claim about code that made no such claim"
  if result.kind == pfkLimitation and result.construct.len == 0:
    problems.add what & " is a limitation but does not name the construct, so " &
      "the developer is told their program is unverifiable without being told why"
  result.trust = decodeTrust(node, what, problems)

proc decodeCounterexample(node: JsonNode; index: int; findingIds: seq[string];
                          problems: var seq[string]): SolverCounterexampleTrace =
  let what = "counterexample " & $index
  result.id = node.str("id")
  result.findingId = node.str("finding_id")
  if result.findingId notin findingIds:
    problems.add what & " refers to finding `" & result.findingId &
      "`, which this payload does not contain"
  result.trust = decodeTrust(node, what, problems)

  # The spec's honesty rule, checked rather than remembered:
  # "When no real execution exists, the counterexample trace remains a visual
  # diagnostic artifact and must not be presented as recorded runtime
  # evidence."
  result.isRecordedExecution = node.flag("is_recorded_execution", true)
  if result.isRecordedExecution:
    problems.add what & " claims to be a recorded execution; a solver model " &
      "is never one, and a payload that says otherwise is refused rather than " &
      "shown with a caveat"

  if not node.has("model"):
    problems.add what & " has no model object; a counterexample must say " &
      "whether it has values and, if not, why not"
  else:
    let modelNode = node["model"]
    discard decodeEnum(modelNode.str("status"), what & "'s model status",
                       problems, result.model.status)
    result.model.absentReason = modelNode.str("absent_reason")
    result.model.bindings = decodeBindings(modelNode, "bindings")
    if result.model.status != pmsComplete and result.model.absentReason.len == 0:
      problems.add what & "'s model is not complete and does not say what is " &
        "missing"
    if result.model.status == pmsUnavailable and result.model.bindings.len > 0:
      problems.add what & "'s model says it is unavailable but carries values"

  var violations = 0
  if node.has("steps") and node["steps"].kind == JArray:
    for stepIndex, stepNode in node["steps"].getElems:
      var step = CounterexampleStep(
        index: stepNode.num("index", stepIndex),
        description: stepNode.str("description"),
        bindings: decodeBindings(stepNode, "bindings"),
        taken: stepNode.optionalBool("taken"),
        iteration: stepNode.optionalInt("iteration"),
        pathCondition: stepNode.str("path_condition"),
      )
      discard decodeEnum(stepNode.str("kind"),
                         what & " step " & $stepIndex & "'s kind", problems,
                         step.kind)
      step.location = decodeOptionalLocation(stepNode, "location", step.hasLocation)
      if step.kind == cskViolation:
        inc violations
      result.steps.add step
  if violations > 1:
    problems.add what & " marks " & $violations & " steps as the violation; " &
      "the spec asks for *the first* obligation the model violates, and more " &
      "than one would leave a view to choose"

  if node.has("violated_obligation"):
    let obligation = node["violated_obligation"]
    result.hasViolatedObligation = true
    discard decodeEnum(obligation.str("kind"), what & "'s violated obligation kind",
                       problems, result.violatedObligation.kind)
    result.violatedObligation.rawKind = obligation.str("raw_kind")
    result.violatedObligation.message = obligation.str("message")
    result.violatedObligation.location =
      decodeOptionalLocation(obligation, "location",
                             result.violatedObligation.hasLocation)
    if result.violatedObligation.rawKind.len == 0:
      problems.add what & "'s violated obligation does not carry the " &
        "verifier's own wording"
  result.solverQueryId = node.str("solver_query_id")

proc decodeFrame(node: JsonNode; path: string; depth: int;
                 problems: var seq[string]): ProverStateFrame =
  const MaxDepth = 64
    ## A proof tree deep enough to exhaust the stack is a malformed document,
    ## not a hard proof. Refusing at a stated depth is a rejection with a
    ## reason; recursing until the process dies is not.
  if depth > MaxDepth:
    problems.add path & " nests deeper than " & $MaxDepth & " levels"
    return nil
  result = ProverStateFrame(
    id: node.str("id"),
    goal: node.str("goal"),
    generatedOrigin: node.str("generated_origin"),
    producedBy: node.str("produced_by"),
    solverQueryId: node.str("solver_query_id"),
  )
  discard decodeEnum(node.str("kind"), path & "'s kind", problems, result.kind)
  if result.id.len == 0:
    problems.add path & " has no id; a view keeps the user's expansion state " &
      "by node id, so an unnamed node cannot survive a regeneration"
  result.location = decodeOptionalLocation(node, "location", result.hasLocation)
  if node.has("hypotheses") and node["hypotheses"].kind == JArray:
    for hypothesisNode in node["hypotheses"]:
      var hasLocation = false
      let location = decodeOptionalLocation(hypothesisNode, "location", hasLocation)
      result.hypotheses.add Hypothesis(
        name: hypothesisNode.str("name"),
        statement: hypothesisNode.str("statement"),
        hasLocation: hasLocation,
        location: location,
      )
  if node.has("children") and node["children"].kind == JArray:
    for childIndex, childNode in node["children"].getElems:
      let child = decodeFrame(childNode, path & "/" & $childIndex, depth + 1, problems)
      if not child.isNil:
        result.children.add child

proc decodeGoalTree(node: JsonNode; index: int; findingIds: seq[string];
                    problems: var seq[string]): ProofGoalTree =
  let what = "goal tree " & $index
  result.id = node.str("id")
  result.findingId = node.str("finding_id")
  if result.findingId notin findingIds:
    problems.add what & " refers to finding `" & result.findingId &
      "`, which this payload does not contain"
  result.trust = decodeTrust(node, what, problems)
  if not node.has("root"):
    problems.add what & " has no root node"
  else:
    result.root = decodeFrame(node["root"], what & " root", 0, problems)

proc decodeSolverQuery(node: JsonNode; index: int;
                       problems: var seq[string]): SolverQueryAttachment =
  let what = "solver query " & $index
  result.id = node.str("id")
  result.trust = decodeTrust(node, what, problems)
  result.smtlib = node.str("smtlib")
  result.smtlibAbsentReason = node.str("smtlib_absent_reason")
  if result.smtlib.len == 0 and result.smtlibAbsentReason.len == 0:
    problems.add what & " carries no SMT-LIB text and does not say why"
  result.options = node.strings("options")
  result.rlimit = node.optionalInt("rlimit")
  result.hasUnsatCore = node.has("unsat_core")
  result.unsatCore = node.strings("unsat_core")
  result.unsatCoreAbsentReason = node.str("unsat_core_absent_reason")
  result.statistics = node.stringPairs("statistics")
  result.statisticsAbsentReason = node.str("statistics_absent_reason")
  discard decodeEnum(node.str("replay_status"), what & "'s replay status",
                     problems, result.replayStatus)

# ---------------------------------------------------------------------------
# Decoding the whole document
# ---------------------------------------------------------------------------

proc decodeVerificationPayload*(text: string): PayloadDecode =
  ## Read one payload document, or say why not.
  ##
  ## Every problem is collected rather than the first being raised, so a
  ## producer change that breaks three rules is not fixed one round-trip at a
  ## time.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    return PayloadDecode(ok: false,
      problems: @["the verification report is not valid JSON: " & err.msg])
  except:
    # On the JS backend `parseJson` delegates to `JSON.parse`, whose throw
    # arrives as a *foreign* exception that no typed Nim handler catches — so
    # without this arm a malformed report takes down the renderer instead of
    # producing a problem line. `project_actions.readJson` shipped with exactly
    # this defect until the `vm-unit-js` lane ran its suite on the backend the
    # web debugger actually uses.
    return PayloadDecode(ok: false,
      problems: @["the verification report is not valid JSON"])

  if doc.isNil or doc.kind != JObject:
    return PayloadDecode(ok: false,
      problems: @["the verification report is not a JSON object"])

  var problems: seq[string] = @[]
  var payload = VerificationPayload(schema: doc.str("schema"))

  # Rule 1. Checked first and returned on, because every field below is only
  # meaningful under a schema we recognise.
  if payload.schema != PayloadSchemaId:
    return PayloadDecode(ok: false, problems: @[
      "the verification report declares schema `" & payload.schema &
        "`, and this build understands only `" & PayloadSchemaId &
        "`; a document written to a contract we have not read is refused " &
        "rather than partly believed"])

  let producer = if doc.has("producer"): doc["producer"] else: newJObject()
  payload.producerName = producer.str("name")
  payload.producerVersion = producer.str("version")
  payload.sourceLanguage = producer.str("source_language")
  payload.languageRelease = producer.str("language_release")
  if payload.producerName.len == 0:
    problems.add "the verification report does not name its producer"

  let run = if doc.has("run"): doc["run"] else: newJObject()
  payload.startedAtUnixMs = run.bignum("started_at_unix_ms")
  payload.finishedAtUnixMs = run.bignum("finished_at_unix_ms")
  payload.workspaceRoot = run.str("workspace_root")
  payload.package = run.str("package")
  payload.entryFile = run.str("entry_file")
  payload.argv = run.strings("argv")
  if payload.startedAtUnixMs <= 0:
    problems.add "the verification report does not say when its run started, " &
      "so a report left behind by an earlier run could not be told from this one"
  let solver = if run.has("solver"): run["solver"] else: newJObject()
  payload.solverInvoked = solver.flag("invoked")
  payload.solverName = solver.str("name")
  payload.solverUnavailableReason = solver.str("unavailable_reason")
  if not payload.solverInvoked and payload.solverUnavailableReason.len == 0:
    problems.add "the verification report says no solver was invoked and does " &
      "not say why"

  # Rule 3.
  discard decodeEnum(doc.str("outcome"), "the verification report's outcome",
                     problems, payload.outcome)
  payload.outcomeDetail = doc.str("outcome_detail")
  payload.trust = decodeTrust(doc, "the verification report", problems)

  if doc.has("source_map") and doc["source_map"].has("files"):
    for fileNode in doc["source_map"]["files"]:
      payload.sourceMap.files.add PayloadSourceFile(
        index: fileNode.num("index"),
        path: fileNode.str("path"),
        absolutePath: fileNode.str("absolute_path"),
      )

  if doc.has("findings") and doc["findings"].kind == JArray:
    for index, findingNode in doc["findings"].getElems:
      payload.findings.add decodeFinding(findingNode, index, problems)

  var findingIds: seq[string] = @[]
  for finding in payload.findings:
    if finding.id in findingIds:
      problems.add "two findings share the id `" & finding.id & "`"
    findingIds.add finding.id

  # Every location must resolve through the source map, or a view cannot open
  # the file the payload points at.
  for finding in payload.findings:
    if finding.hasLocation and
        (finding.location.fileIndex < 0 or
         finding.location.fileIndex >= payload.sourceMap.files.len):
      problems.add "finding `" & finding.id & "` points at source-map file " &
        $finding.location.fileIndex & " of " & $payload.sourceMap.files.len

  if doc.has("counterexample_traces") and doc["counterexample_traces"].kind == JArray:
    for index, traceNode in doc["counterexample_traces"].getElems:
      let trace = decodeCounterexample(traceNode, index, findingIds, problems)
      payload.counterexampleTraces.add trace

  if doc.has("goal_trees") and doc["goal_trees"].kind == JArray:
    for index, treeNode in doc["goal_trees"].getElems:
      payload.goalTrees.add decodeGoalTree(treeNode, index, findingIds, problems)

  if doc.has("solver_queries") and doc["solver_queries"].kind == JArray:
    for index, queryNode in doc["solver_queries"].getElems:
      payload.solverQueries.add decodeSolverQuery(queryNode, index, problems)

  # The cross-cutting rules. Each of these is a way for a payload to say
  # something the six-outcome vocabulary forbids.
  for finding in payload.findings:
    if finding.kind == pfkLimitation and answersCorrectness(payload.outcome):
      problems.add "finding `" & finding.id & "` is a limitation, but the " &
        "run's outcome claims to answer whether the program is correct; a " &
        "limitation says nothing about the program"
    if finding.kind == pfkFailedObligation and payload.outcome != voNotProved:
      problems.add "finding `" & finding.id & "` is a failed obligation, but " &
        "the run's outcome is `" & $payload.outcome &
        "`; only `not-proved` may carry one"

  if payload.counterexampleTraces.len > 0 and payload.outcome != voNotProved:
    problems.add "the report carries a counterexample but its outcome is `" &
      $payload.outcome & "`; a model of a rejected obligation cannot exist " &
      "where nothing was rejected"

  if payload.outcome == voProved and payload.trust.class != ptcSolverOracle:
    problems.add "the report says `proved` but does not rest its verdict on " &
      "the solver oracle; a discharged obligation has to say what discharged it"
  if payload.trust.class == ptcSolverOracle and not payload.solverInvoked:
    problems.add "the report claims `solver-oracle` trust but says no solver " &
      "was invoked"

  if problems.len > 0:
    PayloadDecode(ok: false, problems: problems)
  else:
    PayloadDecode(ok: true, payload: payload)

# ---------------------------------------------------------------------------
# Attaching a payload to a run
# ---------------------------------------------------------------------------

proc findingKindMatches*(kind: PayloadFindingKind;
                         other: VerificationFindingKind): bool =
  ## The two enums are spelled identically on purpose. Comparing their
  ## spellings rather than writing a `case` means a value added to one and not
  ## the other stops matching instead of silently mapping to a neighbour.
  $kind == $other

proc attachPayload*(report: VerificationReport; payloadText: string;
                    runStartedAtUnixMs: int64): PayloadAttachment =
  ## Decide whether this run's payload may be believed.
  ##
  ## `runStartedAtUnixMs` is required rather than optional: without it the
  ## staleness check cannot run, and a check that can be skipped by omitting an
  ## argument is a check that will be.
  if payloadText.strip().len == 0:
    # The text tier is a supported tier. A producer that emits no payload is
    # not a fault, and saying so would train a developer to ignore the panel.
    return PayloadAttachment(status: psAbsent)

  let decoded = decodeVerificationPayload(payloadText)
  if not decoded.ok:
    return PayloadAttachment(status: psRejected, problems: decoded.problems)

  let payload = decoded.payload
  var problems: seq[string] = @[]
  var notes: seq[string] = @[]

  # The staleness rule. The report file lives at a fixed path and outlives the
  # run that wrote it, so this is the difference between showing a
  # counterexample for the code on screen and showing one for the code that was
  # there last week.
  #
  # The rule fails *closed*. A caller that supplies a payload but no start time
  # gets a rejection rather than an unchecked attachment: with
  # `runStartedAtUnixMs` at 0 the comparison below can never fire (a decoded
  # payload's `startedAtUnixMs` is already required to be positive), so
  # omitting the argument would silently switch the check off. That is the one
  # failure mode this rule exists to prevent, and it must not be reachable by
  # forgetting a parameter.
  if runStartedAtUnixMs <= 0:
    problems.add "this run did not record when it started, so a verification " &
      "report left behind by an earlier run could not be told from this " &
      "one's; the report is refused rather than shown unchecked"
  elif payload.startedAtUnixMs < runStartedAtUnixMs - StalePayloadToleranceMs:
    problems.add "the verification report was written by a run that started " &
      $(runStartedAtUnixMs - payload.startedAtUnixMs) &
      "ms before this one; it is left over from an earlier run and says " &
      "nothing about the code that was just verified"

  # Rule 4, the two directions that force a rejection.
  if payload.outcome == voProved and report.outcome != voProved:
    problems.add "the verification report claims the program was proved, but " &
      "the verifier's own output reads `" & outcomeLabel(report.outcome) &
      "`; a structured artifact may not turn a failed run green"
  if isFailedProof(report.outcome) and not isFailedProof(payload.outcome):
    problems.add "the verifier's output reports a failed proof and the " &
      "verification report does not (`" & $payload.outcome &
      "`); a structured artifact may not hide a failure the text found"

  if problems.len > 0:
    return PayloadAttachment(status: psRejected, problems: problems)

  if payload.outcome != report.outcome:
    notes.add "the verification report says `" & $payload.outcome &
      "` where the verifier's output reads `" & $report.outcome &
      "`; the output's verdict is the one shown, and the report supplies the " &
      "structure"

  PayloadAttachment(status: psAttached, payload: some(payload), notes: notes)

# ---------------------------------------------------------------------------
# Queries a view will want, kept here so no view re-derives them
# ---------------------------------------------------------------------------

proc counterexampleFor*(payload: VerificationPayload;
                        findingId: string): Option[SolverCounterexampleTrace] =
  for trace in payload.counterexampleTraces:
    if trace.findingId == findingId:
      return some(trace)
  none(SolverCounterexampleTrace)

proc goalTreeFor*(payload: VerificationPayload;
                  findingId: string): Option[ProofGoalTree] =
  for tree in payload.goalTrees:
    if tree.findingId == findingId:
      return some(tree)
  none(ProofGoalTree)

proc solverQueryById*(payload: VerificationPayload;
                      id: string): Option[SolverQueryAttachment] =
  for query in payload.solverQueries:
    if query.id == id:
      return some(query)
  none(SolverQueryAttachment)

proc hasSteppableCounterexample*(payload: VerificationPayload): bool =
  ## Whether anything in this payload could be stepped through.
  ##
  ## **This is VN-M5's gate, and it is here rather than there on purpose.** A
  ## counterexample with no model and no steps is a located obligation and
  ## nothing more; offering to "step through" it would promise a walk through
  ## an execution the payload does not describe. Against every payload Verno
  ## can produce today this answers `false`, because `venir` returns no model
  ## at all.
  for trace in payload.counterexampleTraces:
    if trace.steps.len > 0 and trace.model.status != pmsUnavailable:
      return true
  false

proc modelIsAbsentBecause*(payload: VerificationPayload): string =
  ## The producer's own words for why there are no model values, or "" if
  ## there are some. A view that says "no counterexample available" without
  ## this would be hiding the interesting half of the answer.
  for trace in payload.counterexampleTraces:
    if trace.model.status == pmsUnavailable:
      return trace.model.absentReason
  ""
