## test_project_action_runner.nim
##
## VN-M3 — the host half: reading a project's declared actions off disk, and
## running one as a watchable process.
##
## Everything below launches a **real** child process through the same
## `runquota_process` launcher `ct_test` uses. Nothing is mocked, because the
## claims being made are about process lifecycle — that a run in flight reports
## elapsed time and output before it ends, that a cancel actually kills, that a
## wall-clock backstop actually fires — and a mock can be made to say all three
## while none of them is true.
##
## The children are `/bin/sh`, `cat` and `sleep` rather than `verno`, and that
## is deliberate: the subject here is the *runner*, and pinning these cases to
## a verifier that is Linux-only for its solver half would make them
## unrunnable on this machine for a reason that has nothing to do with what
## they check. The verifier's own output is exercised, as real recorded text,
## in `test_verification_vm.nim`; `../fixtures/verno/PROVENANCE.md` says which
## of it came from a solver and which did not.
##
## POSIX only, and C backend only — `runquota_process` is a POSIX launcher and
## `std/os` file reads have no `nim js` equivalent. Hence the `vm-unit-js`
## rejection recorded in `ci/lib/test-lane-files.sh`.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_project_action_runner.nim

import std/[options, os, strutils, times, unittest]

import isonim/core/[signals, computation]

import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
import ../../viewmodels/verification_vm
import ../../host/project_action_runner

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
  ExamplePackage = RepoRoot / "test-programs" / "noir_verification"
  UnsupportedFixture =
    RepoRoot / "src" / "frontend" / "viewmodel" / "tests" / "fixtures" /
    "verno" / "unsupported_lambda.txt"

proc tempProject(name: string): string =
  result = getTempDir() / ("ct-vnm3-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / ".vscode")

proc writeTasks(root, tasksJson: string) =
  writeFile(root / ".vscode" / "tasks.json", tasksJson)

proc onlyAction(root: string): ProjectAction =
  let declared = loadProjectActions(root)
  doAssert declared.problems.len == 0, $declared.problems
  doAssert declared.actions.len == 1
  declared.actions[0]

suite "VN-M3 a project's declarations are read off disk":

  test "the Noir example package in this repository declares its own actions":
    # Not a fixture string: the real file, at the real path, in this tree.
    check fileExists(ExamplePackage / ".vscode" / "tasks.json")
    check tasksJsonPath(ExamplePackage) ==
      ExamplePackage / ".vscode" / "tasks.json"
    let declared = loadProjectActions(ExamplePackage)
    check declared.problems.len == 0
    check declared.actions.len == 3
    check vernoActions(declared).len == 2
    check vernoActions(declared)[0].label == "Verify with Verno"

  test "a project that declares nothing yields nothing":
    let root = tempProject("bare")
    defer: removeDir(root)
    check tasksJsonPath(root) == ""
    check packageJsonPath(root) == ""
    check loadProjectActions(root).actions.len == 0

  test "a root-level tasks.json is read when there is no .vscode one":
    let root = tempProject("rootlevel")
    defer: removeDir(root)
    writeFile(root / "tasks.json",
      """{"tasks": [{"label": "t", "command": "true"}]}""")
    check tasksJsonPath(root) == root / "tasks.json"
    check loadProjectActions(root).actions.len == 1

  test "`options.cwd` resolves against the project root":
    let root = tempProject("cwd")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "t", "command": "true",
                  "options": {"cwd": "packages/a"}}]}""")
    check workingDirectory(onlyAction(root), root) == root / "packages" / "a"

suite "VN-M3 a declared action runs as a real process":

  test "a real child's output is classified into one of Verno's six outcomes":
    # `cat` of a recorded Verno run: the process is real, the exit code is
    # real, and the text is the verifier's own.
    let root = tempProject("run")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "Verify", "command": "cat",
                  "args": ["""" & UnsupportedFixture & """"]}]}""")
    let vm = createVerificationVM()
    runAction(vm, onlyAction(root), root)
    check vm.phase.val == vpFinished
    check vm.currentReport().isSome
    check vm.currentReport().get.outcome == voUnsupported
    check vm.failedObligationCount.val == 0
    check vm.limitationCount.val == 1

  test "a package.json script runs through a shell, so `&&` still means `&&`":
    let root = tempProject("script")
    defer: removeDir(root)
    writeFile(root / "package.json", """
      {"name": "demo",
       "scripts": {"verify": "echo first && echo Verification successful!"}}""")
    let declared = loadProjectActions(root)
    check declared.actions.len == 1
    let vm = createVerificationVM()
    runAction(vm, declared.actions[0], root)
    check vm.phase.val == vpFinished
    check vm.currentReport().get.outcome == voProved

  test "a run in flight reports elapsed time and output before it ends":
    # The deliverable is "not a frozen UI". The check is that the ViewModel is
    # in `vpRunning`, with a non-zero elapsed time and the child's first line
    # already pushed, while the child is still alive.
    let root = tempProject("slow")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "Verify", "command": "/bin/sh",
                  "args": ["-c", "echo solving; sleep 1; echo Verification successful!"]}]}""")
    let vm = createVerificationVM()
    var run = startAction(vm, onlyAction(root), root)
    check run.active

    var sawRunningWithOutput = false
    var statusWhileRunning = ""
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      if pump(vm, run):
        break
      if vm.phase.val == vpRunning and vm.elapsedMs.val > 0 and
          vm.lastOutputLine.val == "solving":
        sawRunningWithOutput = true
        statusWhileRunning = vm.statusText.val
      sleep(20)
    check sawRunningWithOutput
    # Captured mid-run, not after: a status line that only becomes informative
    # once the process has exited is exactly the frozen UI this rules out.
    check statusWhileRunning.contains("Verifying with Verno")
    check statusWhileRunning.contains("solving")

    while not pump(vm, run):
      sleep(20)
    check vm.phase.val == vpFinished
    check vm.currentReport().get.outcome == voProved

  test "cancelling kills the child, and produces no outcome at all":
    let root = tempProject("cancel")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "Verify", "command": "sleep", "args": ["30"]}]}""")
    let vm = createVerificationVM()
    var run = startAction(vm, onlyAction(root), root)
    check run.active

    discard pump(vm, run)
    cancelAction(vm, run)
    check vm.phase.val == vpCancelling

    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not pump(vm, run):
      sleep(20)
    check not run.active
    check vm.phase.val == vpCancelled
    # A killed proof attempt established nothing. Classifying its partial
    # output would manufacture a verdict out of an interruption.
    check vm.currentReport().isNone
    check vm.failedObligationCount.val == 0

  test "a wall-clock backstop is a timeout, not a rejected program":
    let root = tempProject("timeout")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "Verify", "command": "sleep", "args": ["30"]}]}""")
    let vm = createVerificationVM()
    var run = startAction(vm, onlyAction(root), root, timeoutMs = 300)
    let deadline = epochTime() + 15.0
    while epochTime() < deadline and not pump(vm, run):
      sleep(20)
    check not run.active
    check vm.phase.val == vpFinished
    check vm.currentReport().get.outcome == voTimedOut
    check not isFailedProof(vm.currentReport().get.outcome)
    check vm.failedObligationCount.val == 0

  test "a verifier that is not installed is not a verdict on the program":
    let root = tempProject("missing")
    defer: removeDir(root)
    writeTasks(root, """
      {"tasks": [{"label": "Verify",
                  "command": "ct-vnm3-no-such-verifier-anywhere",
                  "args": ["formal-verify"]}]}""")
    let vm = createVerificationVM()
    runAction(vm, onlyAction(root), root)
    check vm.phase.val in {vpFailedToStart, vpFinished}
    if vm.phase.val == vpFinished:
      # Some launchers report a missing program through the child's exit
      # status rather than by refusing to launch. Either way the one thing
      # that must not happen is a `not-proved`.
      check vm.currentReport().get.outcome != voNotProved
    check vm.failedObligationCount.val == 0
