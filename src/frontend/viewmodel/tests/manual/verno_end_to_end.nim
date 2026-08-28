## verno_end_to_end.nim — VN-M3, driven by the real verifier.
##
## **Not a lane test, on purpose.** It needs a built `verno` binary, which is
## not a dependency of this repository, and the `vm-unit` glob covers
## `tests/unit/test_*.nim` only — so this file never runs in CI and can never
## become a green test that quietly stopped exercising anything.
##
## What it is for: the automated suites feed the classifier *recorded* Verno
## output. This runs the whole path against the binary — the project's own
## `.vscode/tasks.json` action, launched through `runquota_process`, polled to
## completion, classified, and turned into findings and markers. It is the
## thing to run when you want to know that CodeTracer and Verno still agree,
## and it is the thing to run **on Linux** to obtain the one outcome macOS
## cannot produce.
##
## Usage:
##
##   VERNO_BIN=<path-to-verno> nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/manual/verno_end_to_end.nim
##
## ## What to expect, and where the machine matters
##
## `venir`, Verno's solver back end, is Linux-only.
##
## * On **macOS** every package reports `no-solver` except the unsupported one,
##   which reports `unsupported` — Verno refuses that long before the solver.
##   Both are real results and neither is a failed proof.
## * On **Linux**, with `nix develop` supplying `venir`, `noir_verification`
##   should report `proved` and `noir_verification_failing` should report
##   `not-proved` with a marker on the `assert` in its `main`. That second one
##   is the outcome `test_a_failed_obligation_lands_in_the_editor` exercises
##   against a recorded fixture; if the text below disagrees with
##   `../fixtures/verno/failed_obligation_assertion.txt`, the fixture is stale
##   and should be replaced with what this printed.

import std/[options, os, strutils]

import isonim/core/[signals, computation]

import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
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

proc main() =
  let verno = findVerno()
  echo "verno: ", verno
  for name in Packages:
    let root = RepoRoot / "test-programs" / name
    let declared = loadProjectActions(root)
    let candidates = vernoActions(declared)
    if candidates.len == 0:
      quit(root & " declares no Verno action", 2)
    # The project declares `verno`; point it at the binary under test without
    # rewriting anything else the project wrote.
    var action = candidates[0]
    action.command = verno

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
    echo "  command:  ", vm.commandLine.val
    echo "  status:   ", vm.statusText.val
    if vm.currentReport().isNone:
      echo "  no report (phase ", vm.phase.val, ")"
      continue
    let report = vm.currentReport().get
    echo "  outcome:  ", report.outcome
    echo "  summary:  ", report.summary
    echo "  answers correctness: ", answersCorrectness(report.outcome)
    echo "  failed obligations:  ", vm.failedObligationCount.val
    echo "  limitations:         ", vm.limitationCount.val
    echo "  pumps while running: ", pumps
    for marker in vm.currentMarkers():
      echo "  marker [", marker.kind, "] ", marker.file, ":",
        marker.range.startLine, ":", marker.range.startColumn, " ", marker.message
    if report.rawOutput.strip().len > 0:
      echo "  --- verifier said ---"
      for line in report.rawOutput.strip().splitLines:
        echo "  | ", line

main()
