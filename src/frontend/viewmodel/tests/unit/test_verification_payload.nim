## test_verification_payload.nim
##
## VN-M4's two verification tests, plus the contract rules they rest on.
##
## ## Read this before trusting a green run
##
## Verno's solver back end (`venir`) is Linux-only, so no run on this machine
## can produce a `proved` or a `not-proved`. That constraint is inherited from
## VN-M3 and is not new. **What is new, and is not about this machine at all:**
##
## > `venir` returns no counterexample model. Its entire output surface is four
## > JSON shapes carrying five strings between them
## > (`blocksense-network/Venir`, `src/stub_structs.rs`), and the
## > `Option<Model>` that `air::context::ValidityResult::Invalid` hands it is
## > discarded before its reporter ever sees it.
##
## So a Verno counterexample *on Linux, today* is a located obligation with
## `model.status == "unavailable"` and a stated reason. That is what
## `not_proved_assertion.json` is. The one fixture carrying model values,
## `not_proved_with_model.json`, is hand-authored and labelled as hypothetical
## in its own contents — `producer.version` is `"0.0.0-hypothetical"` and
## `run.workspace_root` reads `NOT A RECORDING`, both asserted below so they
## cannot be tidied away.
##
## Test by test:
##
## * `test_a_counterexample_payload_round_trips` — **exercised against the
##   shared conformance corpus, not reproduced against a solver.** Three of the
##   seven accepted fixtures are real `verno` runs recorded on this machine
##   (`no_solver`, `unsupported_lambda`, `pipeline_error_type_mismatch`); four
##   are hand-authored, and no solver produced any of them. What the test does
##   establish is that a payload crosses the boundary *without either side
##   parsing the other's textual output*, which is what the milestone's test
##   asks for. See `../fixtures/verno/payload/PROVENANCE.md`.
##
## * `test_trust_classification_is_never_absent` — **fully reproduced.** It
##   needs no verifier: it is a property of the decoder, checked against
##   documents built to break it.
##
## The cross-tier check in the last suite is the one worth reading closely: it
## compares the *payload's* line and column numbers against the *text tier's*
## parse of the same reporter block, on real, current `v1.0.0-beta.26` output.
## Neither number was copied from the other.
##
## Every fixture is loaded with `staticRead`, so deleting one is a compile
## error rather than a quietly smaller suite.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_verification_payload.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[bitops, json, options, strutils, unittest]

import ../../../../ct_test/contracts
import ../../viewmodels/verification_report
import ../../viewmodels/verification_payload

# ---------------------------------------------------------------------------
# The shared conformance corpus. Byte-identical to
# blocksense-network/verno:conformance/codetracer-payload/.
# ---------------------------------------------------------------------------

const
  PayloadManifest = staticRead("../fixtures/verno/payload/manifest.json")

  NoSolverPayload = staticRead("../fixtures/verno/payload/no_solver.json")
  UnsupportedPayload = staticRead("../fixtures/verno/payload/unsupported_lambda.json")
  PipelineErrorPayload =
    staticRead("../fixtures/verno/payload/pipeline_error_type_mismatch.json")
  ProvedPayload = staticRead("../fixtures/verno/payload/proved.json")
  NotProvedPayload = staticRead("../fixtures/verno/payload/not_proved_assertion.json")
  NotProvedWithModelPayload =
    staticRead("../fixtures/verno/payload/not_proved_with_model.json")
  TimedOutPayload = staticRead("../fixtures/verno/payload/timed_out_rlimit.json")

  RejectedMissingRunTrust =
    staticRead("../fixtures/verno/payload/rejected/missing_run_trust.json")
  RejectedMissingFindingTrust =
    staticRead("../fixtures/verno/payload/rejected/missing_finding_trust.json")
  RejectedUnknownOutcome =
    staticRead("../fixtures/verno/payload/rejected/unknown_outcome.json")
  RejectedUnknownSchema =
    staticRead("../fixtures/verno/payload/rejected/unknown_schema.json")
  RejectedLimitationAnswersCorrectness =
    staticRead("../fixtures/verno/payload/rejected/limitation_answers_correctness.json")
  RejectedCounterexampleClaimsRecording =
    staticRead("../fixtures/verno/payload/rejected/counterexample_claims_recording.json")
  RejectedModelUnavailableWithBindings =
    staticRead("../fixtures/verno/payload/rejected/model_unavailable_with_bindings.json")
  RejectedProvedWithoutSolverOracle =
    staticRead("../fixtures/verno/payload/rejected/proved_without_solver_oracle.json")
  RejectedCounterexampleWithoutRejection =
    staticRead("../fixtures/verno/payload/rejected/counterexample_without_a_rejection.json")
  RejectedFindingWithoutLocationOrReason =
    staticRead("../fixtures/verno/payload/rejected/finding_without_location_or_reason.json")

  # VN-M3's text fixture for the same program the payload fixture describes.
  # Both are real `v1.0.0-beta.26` output; neither was derived from the other.
  PipelineErrorText = staticRead("../fixtures/verno/pipeline_error_type_mismatch.txt")

  # VN-M3's other text fixtures, used by the degradation suite below.
  NoSolverText = staticRead("../fixtures/verno/no_solver.txt")
  FailedAssertionText = staticRead("../fixtures/verno/failed_obligation_assertion.txt")

const AcceptedCorpus = [
  ("no_solver.json", NoSolverPayload),
  ("unsupported_lambda.json", UnsupportedPayload),
  ("pipeline_error_type_mismatch.json", PipelineErrorPayload),
  ("proved.json", ProvedPayload),
  ("not_proved_assertion.json", NotProvedPayload),
  ("not_proved_with_model.json", NotProvedWithModelPayload),
  ("timed_out_rlimit.json", TimedOutPayload),
]

const RejectedCorpus = [
  # The third element is a fragment of the reason the document must be refused
  # *for*. Without it a rejection test passes on any rejection, including one
  # caused by a typo somewhere else in the file.
  ("rejected/missing_run_trust.json", RejectedMissingRunTrust,
   "carries no trust class"),
  ("rejected/missing_finding_trust.json", RejectedMissingFindingTrust,
   "carries no trust class"),
  ("rejected/unknown_outcome.json", RejectedUnknownOutcome,
   "not one of the values this contract defines"),
  ("rejected/unknown_schema.json", RejectedUnknownSchema,
   "this build understands only"),
  ("rejected/limitation_answers_correctness.json",
   RejectedLimitationAnswersCorrectness,
   "a limitation says nothing about the program"),
  ("rejected/counterexample_claims_recording.json",
   RejectedCounterexampleClaimsRecording,
   "claims to be a recorded execution"),
  ("rejected/model_unavailable_with_bindings.json",
   RejectedModelUnavailableWithBindings,
   "says it is unavailable but carries values"),
  ("rejected/proved_without_solver_oracle.json", RejectedProvedWithoutSolverOracle,
   "has to say what discharged it"),
  ("rejected/counterexample_without_a_rejection.json",
   RejectedCounterexampleWithoutRejection,
   "cannot exist where nothing was rejected"),
  ("rejected/finding_without_location_or_reason.json",
   RejectedFindingWithoutLocationOrReason,
   "does not say why"),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc decoded(text: string): VerificationPayload =
  let outcome = decodeVerificationPayload(text)
  if not outcome.ok:
    # `panic!` rather than `return`, following VN-M3's precedent: a helper that
    # quietly produced a default payload would make every assertion below
    # vacuous.
    raise newException(ValueError,
      "fixture failed to decode: " & outcome.problems.join("; "))
  outcome.payload

proc anyProblemContains(problems: seq[string]; needle: string): bool =
  for problem in problems:
    if needle in problem:
      return true
  false

## SHA-256, written out here rather than taken as a dependency.
##
## The corpus is *shared*: `manifest.json` is byte-identical in
## `blocksense-network/verno` and in this repository, and both sides check
## every fixture against it. Without that, the two could quietly test different
## corpora and both stay green — which is precisely the failure the
## milestone's "a conformance fixture set both sides test against" deliverable
## is about.
##
## `nimcrypto` would do the job but is not JS-portable, and this suite runs on
## both backends on purpose. Forty lines of FIPS 180-4 is the cheaper answer,
## and `the_hand_written_sha256_agrees_with_the_published_test_vectors` below
## is what makes it trustworthy.
const Sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32,
]

proc sha256Hex(input: string): string =
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32,
  ]
  var message = newSeq[uint8](input.len)
  for index, character in input:
    message[index] = uint8(ord(character))
  let bitLength = uint64(input.len) * 8
  message.add 0x80'u8
  while message.len mod 64 != 56:
    message.add 0'u8
  for shift in countdown(7, 0):
    message.add uint8((bitLength shr (uint64(shift) * 8'u64)) and 0xff'u64)

  var offset = 0
  while offset < message.len:
    var w: array[64, uint32]
    for index in 0 ..< 16:
      let base = offset + index * 4
      w[index] = (uint32(message[base]) shl 24) or
        (uint32(message[base + 1]) shl 16) or
        (uint32(message[base + 2]) shl 8) or
        uint32(message[base + 3])
    for index in 16 ..< 64:
      let s0 = rotateRightBits(w[index - 15], 7) xor
        rotateRightBits(w[index - 15], 18) xor (w[index - 15] shr 3)
      let s1 = rotateRightBits(w[index - 2], 17) xor
        rotateRightBits(w[index - 2], 19) xor (w[index - 2] shr 10)
      w[index] = w[index - 16] + s0 + w[index - 7] + s1
    var
      a = h[0]
      b = h[1]
      c = h[2]
      d = h[3]
      e = h[4]
      f = h[5]
      g = h[6]
      hh = h[7]
    for index in 0 ..< 64:
      let s1 = rotateRightBits(e, 6) xor rotateRightBits(e, 11) xor
        rotateRightBits(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = hh + s1 + ch + Sha256K[index] + w[index]
      let s0 = rotateRightBits(a, 2) xor rotateRightBits(a, 13) xor
        rotateRightBits(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
    offset += 64

  result = ""
  for word in h:
    result.add toHex(word, 8).toLowerAscii

# ---------------------------------------------------------------------------

suite "VN-M4 test_a_counterexample_payload_round_trips":
  ## STATUS ON THIS MACHINE: exercised against the shared conformance corpus.
  ## NOT reproduced against a live solver — `venir` is Linux-only — and, more
  ## than that, `venir` returns no model even on Linux. See this file's header
  ## and ../fixtures/verno/payload/PROVENANCE.md.

  test "a counterexample crosses the boundary without either side parsing text":
    # The milestone's test, stated as it is worded: Verno emits a
    # counterexample for a known-false postcondition and CodeTracer loads it
    # from the conformance fixtures. Nothing below reads a rendered diagnostic;
    # every value comes out of the structured document.
    let payload = decoded(NotProvedWithModelPayload)
    check payload.outcome == voNotProved
    check payload.findings.len == 1
    check payload.findings[0].kind == pfkFailedObligation
    check payload.findings[0].hasLocation
    check payload.findings[0].location.range.startLine == 15
    check payload.findings[0].location.range.startColumn == 12
    check payload.findings[0].location.range.endColumn == 20
    # Byte offsets survive too; the text tier has no way to know these at all.
    check payload.findings[0].location.byteStart == 411
    check payload.findings[0].location.byteEnd == 419

    let trace = counterexampleFor(payload, payload.findings[0].id)
    check trace.isSome
    check trace.get.model.status == pmsPartial
    check trace.get.model.bindings.len == 2
    check trace.get.model.bindings[0].name == "x1"
    check trace.get.model.bindings[0].value == "10"
    check trace.get.model.bindings[0].localId == some(0)
    check trace.get.model.bindings[0].hasLocation

    # The path the model forces, and the obligation it violates — the two
    # things VN-M5 needs and the text tier cannot express at all.
    check trace.get.steps.len == 4
    check trace.get.steps[0].kind == cskAssumption
    check trace.get.steps[0].pathCondition == "-32 <= x1 && x1 < 32"
    check trace.get.steps[1].kind == cskAssignment
    check trace.get.steps[1].bindings[0].name == "x2"
    check trace.get.steps[3].kind == cskViolation
    check trace.get.steps[3].hasLocation
    check trace.get.steps[3].location.range.startLine == 15
    check trace.get.hasViolatedObligation
    check trace.get.violatedObligation.kind == pokAssertion
    check trace.get.violatedObligation.rawKind == "assertion failed"

  test "a proof-goal tree arrives with its hypotheses and source ranges":
    let payload = decoded(NotProvedWithModelPayload)
    let tree = goalTreeFor(payload, "f0")
    check tree.isSome
    check not tree.get.root.isNil
    check tree.get.root.kind == pnkSourceObligation
    check tree.get.root.goal == "assert(n == 40)"
    check tree.get.root.hypotheses.len == 1
    check tree.get.root.hypotheses[0].statement == "-32 <= x1 & x1 < 32"
    check tree.get.root.hasLocation
    check tree.get.root.location.range.startLine == 15
    # Recursive, and the recursion is real rather than one level deep.
    check tree.get.root.children.len == 1
    check tree.get.root.children[0].kind == pnkSmtQuery
    check tree.get.root.children[0].children.len == 1
    check tree.get.root.children[0].children[0].kind == pnkSolverResult
    # And a node's id is stable, which is what lets a view keep the user's
    # expansion state across a regeneration.
    check tree.get.root.children[0].children[0].id == "g0/root/query/result"

  test "the solver query the counterexample came from is reachable from it":
    let payload = decoded(NotProvedWithModelPayload)
    let trace = counterexampleFor(payload, "f0").get
    check trace.solverQueryId == "q0"
    let query = solverQueryById(payload, trace.solverQueryId)
    check query.isSome
    check query.get.rlimit == some(60)
    check query.get.replayStatus == prsNotAttempted
    check query.get.statistics.len == 2
    # An absent unsat core says why it is absent rather than reading as an
    # empty one.
    check query.get.unsatCore.len == 0
    check query.get.unsatCoreAbsentReason.len > 0

  test "every fixture in the shared corpus decodes":
    for (name, text) in AcceptedCorpus:
      let outcome = decodeVerificationPayload(text)
      if not outcome.ok:
        echo name, " was refused: ", outcome.problems.join("; ")
      check outcome.ok

  test "the payload a real Verno run can produce today has no model, and says so":
    # This is the honest state of the world, asserted so it cannot drift
    # unnoticed. `not_proved_assertion.json` is what a Linux run *would*
    # produce: a located obligation, a counterexample object, and a model that
    # states its own absence with the reason.
    let payload = decoded(NotProvedPayload)
    let trace = counterexampleFor(payload, "f0").get
    check trace.model.status == pmsUnavailable
    check trace.model.bindings.len == 0
    check trace.model.absentReason.contains("venir")
    check not hasSteppableCounterexample(payload)
    check modelIsAbsentBecause(payload).len > 0
    # And the fixture that *does* carry a model is the hypothetical one.
    check hasSteppableCounterexample(decoded(NotProvedWithModelPayload))

  test "the hypothetical fixture says in its own contents that it is one":
    # It is the only fixture carrying model values and no solver produced them.
    # Two markers keep it from being mistaken for a recording in a log or a bug
    # report, and both are asserted so they cannot be tidied away.
    let payload = decoded(NotProvedWithModelPayload)
    check payload.producerVersion == "0.0.0-hypothetical"
    check payload.workspaceRoot.contains("NOT A RECORDING")

  test "every fixture says whether a verno run produced it, and only three did":
    # The rule the previous test applies to one fixture, applied to all of
    # them. `not_proved_with_model.json` is not the only hand-authored
    # document in the corpus — `proved.json`, `not_proved_assertion.json` and
    # `timed_out_rlimit.json` are authored too, and they carry the *same*
    # `producer.version` as the real recordings, so `workspace_root` is the
    # only thing separating them. Left unasserted, that prefix could be
    # changed to `<recorded:` and nothing would fail, which is exactly the
    # masquerade the corpus is supposed to make impossible. The three real
    # runs are named here rather than counted, so adding a fixture forces a
    # decision about which it is instead of silently joining a majority.
    const Recorded = [
      "no_solver.json", "pipeline_error_type_mismatch.json",
      "unsupported_lambda.json"]
    var recordedSeen: seq[string] = @[]
    for (name, text) in AcceptedCorpus:
      let payload = decoded(text)
      if name in Recorded:
        checkpoint(name)
        check payload.workspaceRoot.startsWith("<recorded:")
        recordedSeen.add name
      else:
        checkpoint(name)
        check payload.workspaceRoot.startsWith("<authored:")
    check recordedSeen.len == Recorded.len

  test "a counterexample is never a recorded execution":
    # The visualization spec's rule, checked at the decoder rather than left to
    # a renderer to remember. A payload asserting otherwise is refused, not
    # shown with a caveat.
    for (_, text) in AcceptedCorpus:
      let outcome = decodeVerificationPayload(text)
      if outcome.ok:
        for trace in outcome.payload.counterexampleTraces:
          check not trace.isRecordedExecution
    let refused = decodeVerificationPayload(RejectedCounterexampleClaimsRecording)
    check not refused.ok
    check anyProblemContains(refused.problems, "claims to be a recorded execution")

suite "VN-M4 test_trust_classification_is_never_absent":
  ## STATUS ON THIS MACHINE: fully reproduced. It needs no verifier.

  test "every accepted payload carries a trust class, and so does every part of it":
    for (name, text) in AcceptedCorpus:
      let payload = decoded(text)
      checkpoint(name)
      check payload.trust.reason.strip().len > 0
      for finding in payload.findings:
        check finding.trust.reason.strip().len > 0
      for trace in payload.counterexampleTraces:
        check trace.trust.reason.strip().len > 0
      for tree in payload.goalTrees:
        check tree.trust.reason.strip().len > 0
      for query in payload.solverQueries:
        check query.trust.reason.strip().len > 0

  test "a payload with no trust class is rejected, not displayed at an assumed level":
    let refused = decodeVerificationPayload(RejectedMissingRunTrust)
    check not refused.ok
    check anyProblemContains(refused.problems, "carries no trust class")

  test "a *finding* with no trust class is rejected too":
    # The nested case is the one that would slip through: a finding with no
    # class, displayed next to one that has a class, would be read as sharing
    # it.
    let refused = decodeVerificationPayload(RejectedMissingFindingTrust)
    check not refused.ok
    check anyProblemContains(refused.problems, "carries no trust class")

  test "a trust class with no stated reason is rejected":
    # The field exists so a reader can see what a claim rests on. A class with
    # no basis is the thing it was added to prevent.
    var doc = parseJson(NoSolverPayload)
    doc["trust"]["reason"] = %""
    let refused = decodeVerificationPayload($doc)
    check not refused.ok
    check anyProblemContains(refused.problems, "no reason")

  test "the four trust classes the spec names are the four this decoder knows":
    # Enumerated rather than eyeballed. A fifth added on one side and not the
    # other must fail here rather than be silently ignored.
    var spellings: seq[string] = @[]
    for value in PayloadTrustClass:
      spellings.add $value
    check spellings.len == 4
    for expected in ["checked-by-trusted-core", "proof-reconstructed",
                     "solver-oracle", "diagnostic-only"]:
      check expected in spellings

  test "the zero value of a trust class is the least trusting one":
    # A Nim enum's zero value is its first member, and a zero-initialised
    # `PayloadTrust` is what a caller holds after a decode that failed. If the
    # declaration order followed the spec's — most trusted first — that default
    # would read `checked-by-trusted-core` out of an object that made no claim
    # at all. Pinned here because the declaration order looks like a
    # presentational choice and is not one.
    var untouched: PayloadTrust
    check untouched.class == ptcDiagnosticOnly
    check PayloadTrustClass.low == ptcDiagnosticOnly

  test "a solver-oracle claim needs a footprint, and a footprint that ran":
    let payload = decoded(ProvedPayload)
    check payload.trust.class == ptcSolverOracle
    check payload.trust.hasOracleFootprint
    check payload.trust.oracleFootprint.tool == "venir"
    # And every field the producer could not fill says why. A footprint whose
    # gaps were simply omitted would claim a more complete audit trail than
    # exists.
    check payload.trust.oracleFootprint.solver.len == 0
    check payload.trust.oracleFootprint.solverAbsentReason.len > 0
    check payload.trust.oracleFootprint.statistics.len == 0
    check payload.trust.oracleFootprint.statisticsAbsentReason.len > 0

    var doc = parseJson(ProvedPayload)
    doc["trust"].delete("oracle_footprint")
    let refused = decodeVerificationPayload($doc)
    check not refused.ok
    check anyProblemContains(refused.problems, "no oracle footprint")

  test "a proved verdict that does not rest on the solver oracle is rejected":
    let refused = decodeVerificationPayload(RejectedProvedWithoutSolverOracle)
    check not refused.ok
    check anyProblemContains(refused.problems, "has to say what discharged it")

  test "a failed obligation is diagnostic-only, never evidence the program is wrong":
    # With quantifiers and a resource limit, "the solver did not discharge
    # this" is not "the program is wrong". Every producer in this corpus says
    # so, and the wording is the producer's own.
    let payload = decoded(NotProvedPayload)
    check payload.trust.class == ptcDiagnosticOnly
    check payload.findings[0].trust.class == ptcDiagnosticOnly
    for trace in payload.counterexampleTraces:
      check trace.trust.class == ptcDiagnosticOnly

  test "nothing in this corpus claims to have been checked by a trusted core":
    # There is no kernel anywhere in this pipeline. A payload claiming
    # `checked-by-trusted-core` or `proof-reconstructed` would be claiming
    # machinery that does not exist.
    for (name, text) in AcceptedCorpus:
      let payload = decoded(text)
      checkpoint(name)
      check payload.trust.class notin {ptcCheckedByTrustedCore, ptcProofReconstructed}

suite "VN-M4 the six outcomes survive the contract":

  test "each payload's outcome is the text tier's own enum value":
    # Not a parallel vocabulary: `VerificationPayload.outcome` *is*
    # `VerificationOutcome`. There is no translation table, so there is nothing
    # to drift.
    check decoded(ProvedPayload).outcome == voProved
    check decoded(NotProvedPayload).outcome == voNotProved
    check decoded(TimedOutPayload).outcome == voTimedOut
    check decoded(UnsupportedPayload).outcome == voUnsupported
    check decoded(NoSolverPayload).outcome == voNoSolver
    check decoded(PipelineErrorPayload).outcome == voPipelineError

  test "all six outcomes are covered by the corpus":
    var seen: set[VerificationOutcome] = {}
    for (_, text) in AcceptedCorpus:
      let outcome = decodeVerificationPayload(text)
      if outcome.ok:
        seen.incl outcome.payload.outcome
    for outcome in VerificationOutcome:
      checkpoint($outcome)
      check outcome in seen

  test "an outcome the contract does not define is a rejection, not a fallback":
    # There is no default arm in the decoder, and this is why: five of the six
    # values are claims about whether the developer's program is correct, so
    # choosing one on the document's behalf is choosing what to tell them.
    let refused = decodeVerificationPayload(RejectedUnknownOutcome)
    check not refused.ok
    check anyProblemContains(refused.problems,
                             "not one of the values this contract defines")

  test "an unsupported construct is a limitation in the payload too, and names itself":
    # The property VN-M3 defends in the text tier, defended again at the wire.
    # This fixture is a *real recording* of a real `verno` run on this machine.
    let payload = decoded(UnsupportedPayload)
    check payload.outcome == voUnsupported
    check not isFailedProof(payload.outcome)
    check not answersCorrectness(payload.outcome)
    check payload.findings.len == 1
    check payload.findings[0].kind == pfkLimitation
    check payload.findings[0].construct == "function types (lambdas, function values)"
    # No location, and it says why rather than pointing at line 1.
    check not payload.findings[0].hasLocation
    check payload.findings[0].locationAbsentReason.contains("Rust source position")
    check payload.counterexampleTraces.len == 0

  test "a limitation can never sit in a payload that claims to answer correctness":
    let refused = decodeVerificationPayload(RejectedLimitationAnswersCorrectness)
    check not refused.ok
    check anyProblemContains(refused.problems,
                             "a limitation says nothing about the program")

  test "only a rejection may carry a counterexample":
    let refused = decodeVerificationPayload(RejectedCounterexampleWithoutRejection)
    check not refused.ok
    check anyProblemContains(refused.problems,
                             "cannot exist where nothing was rejected")

  test "the two finding-kind vocabularies are spelled identically":
    # `findingKindMatches` compares spellings rather than switching on a case,
    # so a value added to one enum and not the other stops matching instead of
    # mapping to a neighbour. That only works if the spellings agree today.
    check findingKindMatches(pfkProved, vfkProved)
    check findingKindMatches(pfkFailedObligation, vfkFailedObligation)
    check findingKindMatches(pfkLimitation, vfkLimitation)
    check findingKindMatches(pfkBudgetExhausted, vfkBudgetExhausted)
    check findingKindMatches(pfkSolverUnavailable, vfkSolverUnavailable)
    check findingKindMatches(pfkPipelineError, vfkPipelineError)
    check not findingKindMatches(pfkLimitation, vfkFailedObligation)

  test "a wall-clock timeout has no payload at all, and that is the contract":
    # The one outcome the contract cannot carry. A wall-clock kill takes the
    # producer down before it can write anything, so the file is either absent
    # or left over from an earlier run — and the second case is caught by the
    # staleness rule. The text tier owns this outcome, alone.
    let report = reportForRun("", none(int), timedOut = true)
    check report.outcome == voTimedOut
    check attachPayload(report, "", 1_000_000).status == psAbsent

suite "VN-M4 graceful degradation to the text tier":

  test "no payload is not a fault; the text tier stands":
    # A producer we cannot identify, or an older Verno, leaves the text tier
    # standing — and the text tier is a supported tier, so saying "problem"
    # here would train a developer to ignore the panel.
    let report = reportForRun(NoSolverText, some(1))
    let attachment = attachPayload(report, "", 1_000_000)
    check attachment.status == psAbsent
    check attachment.problems.len == 0
    check attachment.payload.isNone

  test "a malformed payload is refused with a stated reason, never silently":
    let report = reportForRun(NoSolverText, some(1))
    let attachment = attachPayload(report, "{ not json", 1_000_000)
    check attachment.status == psRejected
    check attachment.problems.len > 0
    check anyProblemContains(attachment.problems, "not valid JSON")

  test "a payload written to a schema this build does not know is refused":
    let report = reportForRun(NoSolverText, some(1))
    let attachment = attachPayload(report, RejectedUnknownSchema, 1_000_000)
    check attachment.status == psRejected
    check anyProblemContains(attachment.problems, "this build understands only")

  test "a payload left over from an earlier run is refused":
    # The report file lives at a fixed path and outlives the run that wrote it.
    # This is the difference between showing a counterexample for the code on
    # screen and showing one for the code that was there last week.
    let report = reportForRun(NoSolverText, some(1))
    let payload = decoded(NoSolverPayload)
    let stale = attachPayload(report, NoSolverPayload,
                              payload.startedAtUnixMs + 60_000)
    check stale.status == psRejected
    check anyProblemContains(stale.problems, "left over from an earlier run")

    # And a payload from *this* run is accepted, so the check above is not
    # passing because everything is rejected.
    let fresh = attachPayload(report, NoSolverPayload, payload.startedAtUnixMs)
    check fresh.status == psAttached
    check fresh.payload.isSome

  test "a run that did not record its start time gets its payload refused":
    # The staleness rule has to fail closed. `VerificationVM.finish` defaults
    # `runStartedAtUnixMs` to 0 so the many callers with no payload need not
    # supply it, and a caller that passes a payload and forgets it would
    # otherwise get an *unchecked* attachment: a decoded payload's own
    # `started_at_unix_ms` is required to be positive, so `positive < 0 - 2000`
    # is never true and the comparison silently does nothing. A check that can
    # be switched off by omitting an argument is a check that will be.
    let report = reportForRun(NoSolverText, some(1))
    let unchecked = attachPayload(report, NoSolverPayload, 0)
    check unchecked.status == psRejected
    check anyProblemContains(unchecked.problems, "did not record when it started")

  test "a payload may not turn a failed run green":
    # The first of the two disagreements that force a rejection. A structured
    # artifact that claimed `proved` over a text tier that did not would be the
    # worst thing this contract could do.
    let failing = reportForRun(
      FailedAssertionText, some(1))
    check failing.outcome == voNotProved
    let payload = decoded(ProvedPayload)
    let attachment = attachPayload(failing, ProvedPayload, payload.startedAtUnixMs)
    check attachment.status == psRejected
    check anyProblemContains(attachment.problems, "may not turn a failed run green")

  test "a payload may not hide a failure the verifier's own output reports":
    # The second. This is also the venir-crash case: the text tier classifies a
    # crashed solver as `not-proved` (`run-corpus.py::reached_solver` treats
    # "Verification crashed" as having reached the solver) while the producer
    # calls it `pipeline-error`. The two disagree, the text keeps the verdict,
    # and the payload is refused rather than either being silently preferred.
    let failing = reportForRun(
      FailedAssertionText, some(1))
    let payload = decoded(NoSolverPayload)
    let attachment = attachPayload(failing, NoSolverPayload, payload.startedAtUnixMs)
    check attachment.status == psRejected
    check anyProblemContains(attachment.problems, "may not hide a failure")

  test "any other disagreement is a note, and the payload is still attached":
    # The producer genuinely knows things the text cannot see, so a
    # disagreement between two non-answers is worth recording rather than
    # worth refusing.
    let pipelineReport = reportForRun(PipelineErrorText, some(1))
    check pipelineReport.outcome == voPipelineError
    let payload = decoded(NoSolverPayload)
    let attachment = attachPayload(pipelineReport, NoSolverPayload,
                                   payload.startedAtUnixMs)
    check attachment.status == psAttached
    check attachment.notes.len == 1
    check attachment.notes[0].contains("the output's verdict is the one shown")

  test "an attached payload does not change the text tier's verdict or its markers":
    # VN-M4 adds structure, not authority. Everything VN-M3 asserts about the
    # report has to still hold with a payload attached, and the cheapest way to
    # guarantee that is for the attachment to produce a *separate* value rather
    # than mutate the report.
    let report = reportForRun(NoSolverText, some(1))
    let before = report
    let payload = decoded(NoSolverPayload)
    discard attachPayload(report, NoSolverPayload, payload.startedAtUnixMs)
    check report.outcome == before.outcome
    check report.findings.len == before.findings.len
    check editorMarkers(report).len == editorMarkers(before).len

suite "VN-M4 the payload and the printed text agree about where things are":

  test "the payload's line and column are the reporter's line and column":
    # The strongest thing this suite can establish on a machine with no solver,
    # and it rests on real, current `v1.0.0-beta.26` output on both sides.
    #
    # `pipeline_error_type_mismatch.txt` is a codespan block VN-M3 captured;
    # `pipeline_error_type_mismatch.json` is the payload a `verno` run wrote
    # for the same source. Neither number below was copied from the other: the
    # text's came from parsing `┌─ src/main.nr:2:20`, the payload's from
    # `codespan_reporting`'s own column arithmetic, reimplemented in the
    # producer.
    #
    # This matters beyond tidiness. A solver diagnostic goes through the *same*
    # `report_all`, so an agreement demonstrated here carries to the case no
    # machine here can run.
    let textDiagnostics = parseVernoDiagnostics(PipelineErrorText)
    let payload = decoded(PipelineErrorPayload)
    check textDiagnostics.len == 2
    check payload.findings.len == 2
    for index in 0 ..< 2:
      checkpoint("diagnostic " & $index)
      check payload.findings[index].message == textDiagnostics[index].message
      check payload.findings[index].hasLocation == textDiagnostics[index].hasLocation
      check payload.findings[index].location.range.startLine ==
        textDiagnostics[index].range.startLine
      check payload.findings[index].location.range.startColumn ==
        textDiagnostics[index].range.startColumn
      check payload.findings[index].detail == textDiagnostics[index].detail

  test "the file paths differ, and the difference is the reporter's own":
    # Recorded honestly rather than asserted away. The two fixtures were
    # captured from different working directories, and `fm::FileMap::get_name`
    # shortens a path against the process's current directory — so the text
    # says `typeerr/src/main.nr` and the payload says `src/main.nr`. The
    # *coordinates* are what the editor needs to agree on, and they do.
    let textDiagnostics = parseVernoDiagnostics(PipelineErrorText)
    let payload = decoded(PipelineErrorPayload)
    check textDiagnostics[0].file == "typeerr/src/main.nr"
    check payload.findings[0].location.file == "src/main.nr"
    check payload.findings[0].location.file.endsWith("src/main.nr")

  test "the payload carries byte offsets the text tier cannot recover":
    # The reason a structured tier is worth having at all: `┌─ file:2:20`
    # cannot be turned back into a byte range without the source, and a view
    # that wants to highlight an exact span needs one.
    let payload = decoded(PipelineErrorPayload)
    check payload.findings[0].location.byteStart == 48
    check payload.findings[0].location.byteEnd == 49
    check payload.findings[1].location.byteStart == 23
    check payload.findings[1].location.byteEnd == 26

  test "every location resolves through the source map":
    for (name, text) in AcceptedCorpus:
      let payload = decoded(text)
      checkpoint(name)
      for finding in payload.findings:
        if finding.hasLocation:
          check finding.location.fileIndex >= 0
          check finding.location.fileIndex < payload.sourceMap.files.len
          check payload.sourceMap.files[finding.location.fileIndex].path ==
            finding.location.file

suite "VN-M4 the conformance corpus is shared, and provably the same on both sides":

  test "the hand-written sha256 agrees with the published test vectors":
    # FIPS 180-4 Appendix B. Without this the digest check below would be a
    # check of one implementation against itself.
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  test "every fixture matches the digest the producer recorded for it":
    # `manifest.json` is byte-identical in `blocksense-network/verno` and here,
    # and both sides run this check against their own copy of the fixtures. So
    # a fixture edited on one side and not the other fails on *both* — which is
    # what makes "a conformance fixture set both sides test against" true
    # rather than aspirational.
    let manifest = parseJson(PayloadManifest)
    check manifest["schema"].getStr == PayloadSchemaId
    var byPath: seq[(string, string)] = @[]
    for (name, text) in AcceptedCorpus:
      byPath.add (name, text)
    for (name, text, _) in RejectedCorpus:
      byPath.add (name, text)

    var listed: seq[string] = @[]
    for entry in manifest["fixtures"]:
      let path = entry["path"].getStr
      listed.add path
      var found = false
      for (name, text) in byPath:
        if name == path:
          found = true
          checkpoint(path)
          check sha256Hex(text) == entry["sha256"].getStr
      check found

    # Both directions *between the manifest and the list this suite embeds* —
    # which is what these two assertions compare, and is worth saying exactly,
    # because the stronger reading is false. A manifest entry with no embedded
    # fixture is caught (and a fixture deleted from disk is a `staticRead`
    # compile error). A stray `.json` dropped into the fixtures directory that
    # is in neither the manifest nor `AcceptedCorpus`/`RejectedCorpus` is
    # **not** caught: nothing here lists the directory. Such a file is
    # unchecked rather than mis-checked — it is invisible to both sides, so it
    # cannot make them drift — but the guarantee is narrower than "every file
    # in the directory", and the comment that used to sit here said otherwise.
    check listed.len == byPath.len
    for (name, _) in byPath:
      check name in listed

  test "every rejected fixture is refused for the reason it was written for":
    # A rejection test without the reason would pass on any rejection,
    # including one caused by an unrelated typo in the fixture.
    for (name, text, reason) in RejectedCorpus:
      checkpoint(name)
      let outcome = decodeVerificationPayload(text)
      check not outcome.ok
      if not anyProblemContains(outcome.problems, reason):
        echo name, " was refused for ", outcome.problems.join("; "),
          " rather than for: ", reason
      check anyProblemContains(outcome.problems, reason)

  test "a proof tree that nests without end is refused rather than allowed to recurse":
    # Not a hostile-input theatre piece: the decoder walks a tree from a file,
    # and a file is a file. Refusing at a stated depth is a rejection with a
    # reason; recursing until the process dies is not.
    var deep = "{\"id\":\"n\",\"kind\":\"subgoal\",\"goal\":\"g\",\"children\":["
    var closing = "]}"
    for _ in 0 ..< 80:
      deep.add "{\"id\":\"n\",\"kind\":\"subgoal\",\"goal\":\"g\",\"children\":["
      closing.add "]}"
    deep.add closing

    var doc = parseJson(NotProvedWithModelPayload)
    doc["goal_trees"][0]["root"] = parseJson(deep)
    let refused = decodeVerificationPayload($doc)
    check not refused.ok
    check anyProblemContains(refused.problems, "nests deeper than")

suite "VN-M4 the decoder's failure values are stated, not inherited":

  test "a missing trust class does not decode as the most trusting one":
    # A zero-initialised `PayloadTrustClass` is its *first* member. That is the
    # whole reason `ptcDiagnosticOnly` is declared first: declared the way the
    # spec lists them, a decoder that returned early without setting the field
    # would hand a caller "checked by a trusted core" out of an object that
    # made no claim at all — the exact inversion of what the field is for. The
    # payload is refused either way; this pins the value it is refused *with*,
    # and it pins the declaration order that makes that value safe.
    check PayloadTrustClass.low == ptcDiagnosticOnly
    check default(PayloadTrust).class == ptcDiagnosticOnly
    let refused = decodeVerificationPayload(RejectedMissingRunTrust)
    check not refused.ok
    check refused.payload.trust.class == ptcDiagnosticOnly
    check refused.payload.trust.class != ptcCheckedByTrustedCore
    # And every nested trust is the same, in a payload that *has* nested
    # objects. Looping over `refused.payload.findings` would assert nothing:
    # a rejected decode returns a default-initialised payload, so that seq is
    # always empty and the loop body never runs.
    let accepted = decodeVerificationPayload(NotProvedPayload)
    check accepted.ok
    check accepted.payload.findings.len > 0
    for finding in accepted.payload.findings:
      check finding.trust.class != ptcCheckedByTrustedCore

  test "an omitted is_recorded_execution is a rejection, not a permissive default":
    # The field is required on the wire precisely so that its absence cannot
    # read as "false". A producer that forgot it has not promised anything.
    var doc = parseJson(NotProvedPayload)
    doc["counterexample_traces"][0].delete("is_recorded_execution")
    let refused = decodeVerificationPayload($doc)
    check not refused.ok
    check anyProblemContains(refused.problems, "claims to be a recorded execution")

  test "a document that is valid JSON but not an object is refused":
    for text in ["[]", "\"a string\"", "42", "null"]:
      checkpoint(text)
      let refused = decodeVerificationPayload(text)
      check not refused.ok
      check refused.problems.len > 0

  test "an empty document is refused rather than treated as an empty run":
    # `attachPayload` treats empty *text* as "no payload", which is the honest
    # reading of an absent file. The decoder, asked directly, must not agree:
    # a zero-byte file that exists is a producer that failed halfway.
    let refused = decodeVerificationPayload("")
    check not refused.ok
