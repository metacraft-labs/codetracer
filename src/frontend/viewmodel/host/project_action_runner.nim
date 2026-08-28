## host/project_action_runner.nim
##
## VN-M3 — the half of a project action that touches the machine.
##
## `viewmodels/project_actions.nim` and `viewmodels/verification_vm.nim` are
## pure by rule: no filesystem, no process, no `cstring`, so they compile and
## are asserted on both Nim backends. That rule is worth keeping absolute,
## which means the reading and the launching have to live somewhere else. This
## is that somewhere, and `host/` exists to make the boundary obvious: a module
## in here may touch the platform, and a module in `viewmodels/` may not.
##
## Two things happen here and nothing else does:
##
## 1. **Reading what the project declared** — `.vscode/tasks.json`, a
##    root-level `tasks.json`, and `package.json`, in that order of preference
##    for the first two. Nothing is synthesised when they are absent.
##
## 2. **Running one declared action as a watchable process.** The launch goes
##    through `runquota_process`, the same launcher `ct_test` and `reprobuild`
##    already use — VN-M3 asks for the mechanism the project already has, and
##    a second process implementation in the tree would be exactly the bespoke
##    thing §9.3 refuses.
##
## ## Why this is a poll loop rather than a blocking call
##
## The deliverable is "long verification runs behave as long-running processes
## with visible state, not as a frozen UI". A blocking
## `execCaptured`-and-then-render would satisfy every unit test in this
## repository and still freeze the window for the four minutes a real solver
## can take. So the interface here is *stepwise*: `startAction` launches and
## returns a handle, `pump` drains whatever the child has written so far and
## pushes it into the ViewModel, and the caller's own event loop decides how
## often to call it. `runToCompletion` is a convenience for a CLI or a test —
## it is the only blocking entry point, and it is deliberately not the one an
## interactive host should use.
##
## Cancellation is real, not cosmetic: `cancelAction` signals the process
## group and settles the ViewModel into `vpCancelled` with **no report**,
## because a killed proof attempt established nothing.

import std/[options, os, strutils, times]

import runquota_process

import ../viewmodels/project_actions
import ../viewmodels/verification_vm

type
  ProjectActionRun* = object
    ## One running action. Not a ref: the caller owns it, and `runquota_process`
    ## needs `var` access to the child anyway.
    child*: LaunchedProcess
    active*: bool
    pushed*: int
      ## How many bytes of the child's output have already been pushed into the
      ## ViewModel, so `pump` sends each line exactly once.
    cancelling*: bool
    timedOut*: bool
      ## The wall-clock backstop fired. Kept separate from `cancelling`: a run
      ## the user stopped has no outcome, while a run that exceeded its budget
      ## has one — `timed-out`, which is a legitimate member of Verno's six and
      ## still not a failed proof.
    timeoutMs*: int

const
  TasksJsonNames* = [".vscode/tasks.json", "tasks.json"]
  PackageJsonName* = "package.json"

# ---------------------------------------------------------------------------
# Reading what the project declared
# ---------------------------------------------------------------------------

proc readIfPresent(path: string): string =
  if path.len == 0 or not fileExists(path):
    return ""
  try:
    readFile(path)
  except CatchableError:
    ""

proc tasksJsonPath*(projectRoot: string): string =
  ## The first of §9.3's task files that exists, or "".
  for name in TasksJsonNames:
    let candidate = projectRoot / name
    if fileExists(candidate):
      return candidate
  ""

proc packageJsonPath*(projectRoot: string): string =
  let candidate = projectRoot / PackageJsonName
  if fileExists(candidate): candidate else: ""

proc loadProjectActions*(projectRoot: string): ProjectActionSet =
  ## Everything `projectRoot` declares. A project that declares nothing gets an
  ## empty set — never a default action, for the reason `project_actions.nim`
  ## states at length.
  collectProjectActions(
    readIfPresent(tasksJsonPath(projectRoot)),
    readIfPresent(packageJsonPath(projectRoot)))

# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------

proc workingDirectory*(action: ProjectAction; projectRoot: string): string =
  ## Where to run it. A task's `options.cwd` is taken relative to the project
  ## root when it is relative, which is what VS Code does and what a developer
  ## writing `"cwd": "packages/a"` means.
  if action.cwd.len == 0:
    return projectRoot
  if action.cwd.isAbsolute:
    return action.cwd
  projectRoot / action.cwd

proc launchSpec*(action: ProjectAction; projectRoot: string): CommandSpec =
  ## The argv this action becomes.
  ##
  ## A `tasks.json` task is a program plus arguments and is launched directly —
  ## no shell, so no quoting hazard. A `package.json` script is a shell string
  ## by definition (`verno fv && echo ok` is a legal one), so it goes to
  ## `/bin/sh -c` verbatim rather than being split on whitespace into a command
  ## the project did not write.
  let cwd = workingDirectory(action, projectRoot)
  case action.source
  of pasTasksJson:
    commandSpec(argv = @[action.command] & action.args, cwd = cwd)
  of pasPackageJson:
    when defined(windows):
      commandSpec(argv = @["cmd", "/C", action.command], cwd = cwd)
    else:
      commandSpec(argv = @["/bin/sh", "-c", action.command], cwd = cwd)

proc startAction*(vm: VerificationVM; action: ProjectAction;
                  projectRoot: string; timeoutMs = -1): ProjectActionRun =
  ## Launch, and put the ViewModel into `vpStarting`.
  ##
  ## A launch that fails — the commonest case being a verifier that is not
  ## installed — lands in `vpFailedToStart`, which is deliberately *not* one of
  ## Verno's six outcomes: "we could not start it" is a fact about this machine
  ## and says nothing about the program.
  vm.start(action, projectRoot = projectRoot)
  result.timeoutMs = timeoutMs
  try:
    result.child = launchProcess(launchSpec(action, projectRoot))
    result.active = true
    vm.noteRunning()
  except CatchableError as err:
    vm.noteFailedToStart(err.msg)
    result.active = false

proc drainInto(vm: VerificationVM; run: var ProjectActionRun) =
  ## Push whatever the child has written since the last call, one line at a
  ## time, so the panel's "last output line" is current rather than final.
  let text = run.child.stdoutText
  if text.len <= run.pushed:
    return
  let fresh = text[run.pushed .. ^1]
  run.pushed = text.len
  for line in fresh.splitLines:
    if line.strip().len > 0:
      vm.noteOutput(line)

proc elapsedMillis(run: ProjectActionRun): int =
  ## Wall clock since launch.
  ##
  ## Read from `startedSeconds`, **not** from `child.completion.elapsedMillis`:
  ## `completion` is only populated once the child is reaped, so using it while
  ## the run is in flight reports `0ms` for the whole of a four-minute solve —
  ## which is precisely the "frozen UI" this file exists to avoid, arrived at
  ## by reading the wrong field.
  if run.child.completion.exited or run.child.completion.signaled or
      run.child.completion.timedOut:
    return int(run.child.completion.elapsedMillis)
  max(0, int((epochTime() - run.child.startedSeconds) * 1000.0))

proc settle(vm: VerificationVM; run: var ProjectActionRun) =
  ## The child is gone. Hand the whole output to the classifier.
  let completion = run.child.completion
  let output =
    if completion.stderr.len == 0: completion.stdout
    elif completion.stdout.len == 0: completion.stderr
    else: completion.stdout & completion.stderr
  vm.noteElapsed(int(completion.elapsedMillis))
  if run.cancelling:
    vm.noteCancelled()
  else:
    vm.finish(
      output,
      if completion.exited: some(completion.exitCode) else: none(int),
      timedOut = completion.timedOut or run.timedOut)
  run.active = false
  close(run.child)

proc pump*(vm: VerificationVM; run: var ProjectActionRun): bool =
  ## Advance the run by whatever has happened since the last call.
  ##
  ## Returns true once the run is over. Non-blocking: everything it does is a
  ## `WNOHANG` wait and a drain of the pipes, so a host can call it from a
  ## timer without the window stopping.
  if not run.active:
    return true
  if run.timeoutMs >= 0 and not run.timedOut and
      (epochTime() - run.child.startedSeconds) * 1000.0 > float(run.timeoutMs):
    run.timedOut = true
    terminate(run.child)
  # `pollCompletion` is what drains the child's pipes into `stdoutText`, so
  # the drain has to follow it or every line arrives one pump late.
  let finished = pollCompletion(run.child)
  drainInto(vm, run)
  vm.noteElapsed(elapsedMillis(run))
  if not finished:
    return false
  settle(vm, run)
  true

proc cancelAction*(vm: VerificationVM; run: var ProjectActionRun) =
  ## Ask the process group to stop, and remember that we did.
  ##
  ## `vm.requestCancel` moves the ViewModel to `vpCancelling`, which is what
  ## makes `finish` refuse to classify whatever partial output arrives — see
  ## `verification_vm.finish`.
  if not run.active:
    return
  run.cancelling = true
  vm.requestCancel()
  terminate(run.child)

proc runToCompletion*(vm: VerificationVM; run: var ProjectActionRun;
                      pollIntervalMs = 20) =
  ## Block until the run ends. For a CLI or a test only: an interactive host
  ## must drive `pump` from its own loop, or it gives up the whole point of
  ## this file.
  while not pump(vm, run):
    sleep(pollIntervalMs)

proc runAction*(vm: VerificationVM; action: ProjectAction; projectRoot: string;
                timeoutMs = -1; pollIntervalMs = 20) =
  ## Start and drive one action to completion. The convenience form.
  var run = startAction(vm, action, projectRoot, timeoutMs)
  if run.active:
    runToCompletion(vm, run, pollIntervalMs)
