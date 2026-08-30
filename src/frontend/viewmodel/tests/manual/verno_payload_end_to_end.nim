## verno_payload_end_to_end.nim — VN-M4, driven by the real verifier.
##
## **Not a lane test, on purpose**, exactly as `verno_end_to_end.nim` is not.
## It needs a built `verno` binary, which is not a dependency of this
## repository, and the `vm-unit` glob covers `tests/unit/test_*.nim` only — so
## this file never runs in CI and can never become a green test that quietly
## stopped exercising anything.
##
## VN-M3 left one such harness behind and called it "the one command to run on
## Linux". This is its VN-M4 twin, and it exists because VN-M4's own suites
## check the *contract* against recorded and hand-authored documents, while
## this checks that a real `verno` writes a document CodeTracer accepts.
##
## Usage:
##
##   VERNO_BIN=<path-to-verno> nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/manual/verno_payload_end_to_end.nim
##
## ## What to expect, and where the machine matters
##
## On **macOS**, where `venir` is unavailable:
##
##   * `noir_verification` → `no-solver`, payload attached, no counterexample.
##   * `noir_verification_unsupported` → `unsupported`, payload attached, one
##     limitation naming `function types (lambdas, function values)`. This one
##     is written by Verno's *panic hook* — `todo!()` unwinds past every return
##     path — so seeing it here is the evidence that the hook works.
##   * `noir_verification_failing` → `no-solver`, payload attached.
##
## On **Linux**, with `nix develop` supplying `venir`, two things change and
## both are the point of running it there:
##
##   * `noir_verification` should report `proved`, and its payload's trust
##     class should be `solver-oracle` with an oracle footprint. If it is
##     `diagnostic-only`, the producer failed to record a footprint and the
##     verdict is resting on nothing.
##   * `noir_verification_failing` should report `not-proved` with a
##     counterexample whose `model.status` is **`unavailable`** and whose
##     `absent_reason` names `venir`. That is not a bug in this milestone: as
##     of `blocksense-network/Venir` `15c520b`, venir's reporter serialises
##     four message shapes and discards the `Option<Model>` that
##     `air::context::ValidityResult::Invalid` hands it, so there is no model
##     to forward. **If a model does appear, venir has changed and
##     `not_proved_with_model.json` should stop being labelled hypothetical.**
##
## Either way, diff the emitted `target/verno-report.json` against
## `../fixtures/verno/payload/not_proved_assertion.json`. If they disagree, the
## recorded fixture is wrong and should be replaced with what this printed — in
## **both** repositories, with `manifest.json` regenerated in both.

import std/[options, os, strutils]

import isonim/core/[signals, computation]

import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
import ../../viewmodels/verification_payload
import ../../viewmodels/verification_vm
import ../../host/project_action_runner

const RepoRoot =
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir.parentDir

const Packages = [
  "noir_verification",
  "noir_verification_unsupported",
  "noir_verification_failing",
]

proc findVerno(): string =
  result = getEnv("VERNO_BIN")
  if result.len > 0:
    return
  result = findExe("verno")
  if result.len == 0:
    quit("no `verno` on PATH; set VERNO_BIN to a built binary", 2)

proc describe(payload: VerificationPayload) =
  echo "  payload outcome:   ", payload.outcome
  echo "  payload detail:    ", payload.outcomeDetail
  echo "  producer:          ", payload.producerName, " ", payload.producerVersion,
    " against ", payload.languageRelease
  echo "  solver invoked:    ", payload.solverInvoked
  if not payload.solverInvoked:
    echo "  solver absent:     ", payload.solverUnavailableReason
  echo "  run trust:         ", payload.trust.class, " — ", payload.trust.reason
  if payload.trust.hasOracleFootprint:
    echo "  oracle:            ", payload.trust.oracleFootprint.tool, " ",
      payload.trust.oracleFootprint.toolArgs.join(" ")
    echo "  oracle solver:     ",
      if payload.trust.oracleFootprint.solver.len > 0:
        payload.trust.oracleFootprint.solver
      else:
        "(not recorded: " & payload.trust.oracleFootprint.solverAbsentReason & ")"
  echo "  findings:          ", payload.findings.len
  for finding in payload.findings:
    if finding.hasLocation:
      echo "    [", finding.kind, "] ", finding.location.file, ":",
        finding.location.range.startLine, ":", finding.location.range.startColumn,
        "-", finding.location.range.endColumn, "  ", finding.message
    else:
      echo "    [", finding.kind, "] (no location: ",
        finding.locationAbsentReason, ")  ", finding.message
    if finding.construct.len > 0:
      echo "      construct: ", finding.construct
  echo "  counterexamples:   ", payload.counterexampleTraces.len
  for trace in payload.counterexampleTraces:
    echo "    model status:    ", trace.model.status
    if trace.model.status != pmsComplete:
      echo "    model absent:    ", trace.model.absentReason
    echo "    model values:    ", trace.model.bindings.len
    for binding in trace.model.bindings:
      echo "      ", binding.name, " = ", binding.value
    echo "    steps:           ", trace.steps.len
    echo "    recorded run?:   ", trace.isRecordedExecution, " (must be false)"
  echo "  goal trees:        ", payload.goalTrees.len
  echo "  solver queries:    ", payload.solverQueries.len
  echo "  steppable?:        ", hasSteppableCounterexample(payload)

proc main() =
  let verno = findVerno()
  echo "verno: ", verno
  var attached = 0
  var rejected = 0
  for name in Packages:
    let root = RepoRoot / "test-programs" / name
    let declared = loadProjectActions(root)
    let candidates = vernoActions(declared)
    if candidates.len == 0:
      quit(root & " declares no Verno action", 2)
    # The project declares `verno`; point it at the binary under test without
    # rewriting anything else the project wrote. In particular **no
    # `--report-json` is added**: that the report appears anyway is the whole
    # claim being made here, because §9.3 does not let the IDE add one.
    var action = candidates[0]
    action.command = verno

    # Remove any report an earlier run left, so an attachment below is this
    # run's doing rather than a leftover the staleness rule happened to allow.
    let stale = root / "target" / PayloadFileName
    if fileExists(stale):
      removeFile(stale)

    let vm = createVerificationVM()
    var run = startAction(vm, action, root)
    if not run.active:
      echo "--- ", name, "\n  could not start: ", vm.startFailure.val
      continue
    var pumps = 0
    while not pump(vm, run):
      sleep(20)
      inc pumps

    echo "--- ", name
    echo "  command:           ", vm.commandLine.val
    echo "  pumps while running: ", pumps
    if vm.currentReport().isNone:
      echo "  no report (phase ", vm.phase.val, ")"
      continue
    let report = vm.currentReport().get
    echo "  text outcome:      ", report.outcome, "  (", report.summary, ")"
    echo "  report file:       ",
      if payloadPath(action, root).len > 0: payloadPath(action, root)
      else: "(none written)"
    echo "  payload status:    ", vm.payloadStatus.val
    for problem in vm.payloadProblems.val:
      echo "    refused: ", problem
    for note in vm.payloadNotes.val:
      echo "    note:    ", note
    case vm.payloadStatus.val
    of psAttached:
      inc attached
      describe(vm.currentPayload().get)
    of psRejected:
      inc rejected
    of psAbsent:
      echo "  (no structured payload; the text tier stands)"

  echo ""
  echo "attached: ", attached, "   rejected: ", rejected,
    "   of ", Packages.len, " packages"
  if rejected > 0:
    # A rejection here is a real finding, not a flake: it means the producer
    # and the consumer have drifted, and the reasons are printed above.
    quit("a payload was refused; see the reasons above", 1)

main()
