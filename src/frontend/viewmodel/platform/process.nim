## The process facade.
##
## Desktop: spawned binaries. Web: wasm modules in the tab. Container:
## processes in the container (Noir-Studio.md §3.1).
##
## ## The two shapes, and why both exist
##
## `run` is the one-shot: launch, wait, hand back status and captured output.
## Most callers want this, and expressing it separately keeps them from
## hand-rolling a collect-until-exit loop each time.
##
## `start` is the watchable form. NS1 and §9.3 both insist on it: a four-minute
## solver run must not be a blocking call, because a blocking call satisfies
## every unit test in the repository and still freezes the window. So `start`
## returns a handle immediately, output arrives through callbacks, and the
## caller's own loop decides the cadence. `viewmodel/host/project_action_runner.nim`
## already discovered this shape independently; this is that lesson made
## general.
##
## ## Why there is no `Process` object
##
## `osproc.Process` holds a pid and three stream objects, none of which mean
## anything outside the process that made them. `ProcessHandle` is an opaque
## string instead: the desktop instantiation puts a pid in it, the web one a
## worker id, the container one whatever its endpoint minted. Signals and waits
## take the handle, so the same code drives all three.
##
## ## Why `command` is argv and never a string
##
## A shell string forces every instantiation to agree on a shell, and the web
## has none. `quoteShell` — the exact call that broke `welcome_screen_vm_test.nim`
## under `nim js` with `cannot export: quoteShell` — exists only because callers
## build shell strings. Take argv and the need disappears.

import ./outcome
import ./capabilities

export outcome

type
  ProcessHandle* = distinct string
    ## Opaque and serialisable. See the module note: a pid would have been
    ## enough in-process and would have had to change the day it was not.

  ProcessStream* = enum
    psStdout
    psStderr

  ProcessOutputChunk* = object
    stream*: ProcessStream
    text*: string

  ProcessExit* = object
    exitCode*: int
    signalled*: bool
      ## The child was killed rather than exiting. Distinct from a non-zero
      ## exit: a cancelled run establishes nothing, and callers that conflate
      ## the two report a cancellation as a failure.
    signalName*: string

  ProcessRunResult* = object
    exit*: ProcessExit
    stdout*: string
    stderr*: string

  ProcessSignal* = enum
    sigInterrupt
      ## Ask politely. SIGINT on a desktop; a cooperative cancel elsewhere.
    sigTerminate
    sigKill

  ProcessSpec* = object
    ## Everything needed to launch, and nothing that only makes sense locally.
    command*: string
      ## The program. Resolved against the platform's search path when it
      ## contains no separator.
    args*: seq[string]
    workingDir*: string
      ## Empty means the platform's default, which on the web is the project
      ## store root and in a container is the workspace root. Never the
      ## front end's own cwd — a front end has no business having one.
    env*: seq[tuple[key, value: string]]
      ## Additions and overrides only. A full environment would be a desktop
      ## concept leaking into two platforms that have none.
    clearEnv*: bool
    stdinText*: string
      ## Supplied up front. Interactive stdin is `capProcessInteractiveStdin`
      ## and goes through `writeStdin`, which the web profile does not have.
    timeoutMs*: int
      ## 0 means no wall-clock backstop.

  ProcessFacade* = ref object
    profile*: PlatformProfile

    run*: proc(spec: ProcessSpec): PlatformFuture[PlatformOutcome[ProcessRunResult]]

    start*: proc(spec: ProcessSpec;
                 onOutput: proc(chunk: ProcessOutputChunk);
                 onExit: proc(exit: ProcessExit)
                ): PlatformFuture[PlatformOutcome[ProcessHandle]]

    signal*: proc(handle: ProcessHandle;
                  signal: ProcessSignal): PlatformFuture[PlatformOutcome[Nothing]]
    writeStdin*: proc(handle: ProcessHandle;
                      text: string): PlatformFuture[PlatformOutcome[Nothing]]
    closeStdin*: proc(handle: ProcessHandle): PlatformFuture[PlatformOutcome[Nothing]]
    isRunning*: proc(handle: ProcessHandle): PlatformFuture[PlatformOutcome[bool]]

    which*: proc(program: string): PlatformFuture[PlatformOutcome[string]]
      ## Where the platform would find `program`, or `pkNotFound`. The web
      ## instantiation answers from its wasm module registry, which is what
      ## makes "this project script has no wasm build" a nameable outcome
      ## rather than a mid-run surprise.

proc `==`*(a, b: ProcessHandle): bool {.borrow.}
proc `$`*(handle: ProcessHandle): string {.borrow.}

proc processSpec*(command: string; args: seq[string] = @[];
                  workingDir = ""; timeoutMs = 0): ProcessSpec =
  ProcessSpec(command: command, args: args, workingDir: workingDir,
              env: @[], clearEnv: false, stdinText: "", timeoutMs: timeoutMs)

proc succeededExit*(exit: ProcessExit): bool =
  exit.exitCode == 0 and not exit.signalled

proc unavailableProcess*(profile: PlatformProfile): ProcessFacade =
  ProcessFacade(
    profile: profile,
    run: proc(spec: ProcessSpec): auto =
      resolvedUnsupported[ProcessRunResult]("running programs"),
    start: proc(spec: ProcessSpec;
                onOutput: proc(chunk: ProcessOutputChunk);
                onExit: proc(exit: ProcessExit)): auto =
      resolvedUnsupported[ProcessHandle]("running programs"),
    signal: proc(handle: ProcessHandle; signal: ProcessSignal): auto =
      resolvedUnsupported[Nothing]("signalling programs"),
    writeStdin: proc(handle: ProcessHandle; text: string): auto =
      resolvedUnsupported[Nothing]("interactive input"),
    closeStdin: proc(handle: ProcessHandle): auto =
      resolvedUnsupported[Nothing]("interactive input"),
    isRunning: proc(handle: ProcessHandle): auto =
      resolvedUnsupported[bool]("running programs"),
    which: proc(program: string): auto =
      resolvedUnsupported[string]("locating programs"))
