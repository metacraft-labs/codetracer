## Shared process-execution bridge for ct_test providers.
##
## ct_test's language providers historically shelled out through
## ``std/osproc.execCmdEx`` — a blocking call that returns combined
## stdout+stderr and an exit code, with no output bound, no resource
## accounting, and no coordination with the rest of the system.  Every
## framework adapter (``cpp_common``, ``js_common``, ``ruby_common``,
## ``crystal_spec``, ``smart_contract_common`` …) reimplemented the same
## launch-and-capture dance on top of it.
##
## Process launch + output capture + (optionally) runquota lease negotiation
## is exactly the responsibility of the shared runner that already lives in the
## runquota repo as ``runquota_process`` (and ``runquota_exec`` for the
## lease-coordinated variant).  reprobuild already routes ALL of its subprocess
## work through that library; this module does the same for ct_test so the two
## tools share one launch/scheduling implementation instead of each carrying
## their own.
##
## Layering: the *high-level test logic* — discovery, per-test orchestration,
## result/event aggregation — stays in ct_test.  Only the low-level process
## launch, output capture, and (future) resource scheduling are delegated to
## ``runquota_process`` here.  Providers should depend on this module rather
## than on ``std/osproc`` directly.

import runquota_process

type
  CapturedRun* = object
    ## Result of running one provider subprocess to completion.
    ##
    ## ``output`` preserves the ``execCmdEx`` contract the providers already
    ## parse (combined stdout+stderr); the remaining fields surface the richer
    ## accounting ``runquota_process`` captures for free, so callers that want
    ## per-test wall time (e.g. for the CI-sharding cost model) or memory
    ## telemetry no longer have to time the call by hand.
    output*: string                    ## combined stdout+stderr, possibly cut
    exitCode*: int
    timedOut*: bool
    durationMs*: int
    peakResidentMemoryBytes*: uint64
    processCount*: uint32
    outputBytes*: uint64
      ## How many bytes the child *actually* wrote, counted before the capture
      ## bound was applied.  Equal to ``output.len`` for every run that fit.
    truncated*: bool
      ## ``true`` when the capture bound cut the output — i.e. ``output`` is a
      ## PREFIX of what the child produced and the tail is gone.
      ##
      ## This field exists because silent truncation is a correctness hazard,
      ## not a cosmetic one.  ``runquota_process`` stops appending at the bound
      ## but keeps counting, so the information is available; ``CapturedRun``
      ## used to drop it, leaving every consumer to parse a prefix as if it
      ## were the whole answer.  For a parser that is usually a loud syntax
      ## error, but for the *list-shaped* outputs ct_test consumes — one record
      ## per line, ``git ls-files -z`` above all — a prefix is indistinguishable
      ## from a complete short answer, and the loss is invisible.  Callers that
      ## cannot tolerate a partial answer MUST check this.

const
  DefaultCaptureLimit* = 16 * 1024 * 1024
    ## Per-stream capture bound.  ``execCmdEx`` was unbounded; an explicit cap
    ## keeps a runaway test from flooding the runner's memory while staying far
    ## above any realistic framework-output size.

proc execCaptured*(argv: openArray[string]; cwd = "";
                   env: openArray[string] = [];
                   timeoutMs = -1;
                   captureLimit = DefaultCaptureLimit): CapturedRun =
  ## Launch ``argv`` to completion through ``runquota_process`` and capture its
  ## output.  This is the drop-in for the providers'
  ## ``execCmdEx(commandLine(argv), {poUsePath}, workingDir = cwd)`` pattern:
  ##
  ## * the program is resolved on ``PATH`` when it is not an absolute path
  ##   (``runquota_process`` launches POSIX children with ``poUsePath``), and
  ## * stderr is merged into stdout (``poStdErrToStdOut``), so ``output`` is the
  ##   same combined stream ``execCmdEx`` produced.
  ##
  ## ``env`` is *layered over* the inherited environment (``applyChildEnv``), so
  ## passing ``@[]`` inherits the parent environment unchanged — ``PATH`` and
  ## friends survive, matching ``execCmdEx``.  ``timeoutMs < 0`` waits
  ## indefinitely; a non-negative value bounds the run and sets ``timedOut``.
  ##
  ## Unlike ``execCmdEx``, passing ``argv`` directly avoids a shell round-trip
  ## and the quoting hazards of joining into a command string.
  var child = launchProcess(commandSpec(
    argv = @argv,
    cwd = cwd,
    env = @env,
    stdoutLimit = captureLimit,
    stderrLimit = captureLimit))
  let completion = waitForCompletion(child, timeoutMs)
  # POSIX launches merge stderr into stdout, so ``completion.stdout`` already
  # holds the combined stream.  On the off chance a backend reports the two
  # separately, concatenate so callers never silently drop stderr.
  result.output =
    if completion.stderr.len == 0: completion.stdout
    elif completion.stdout.len == 0: completion.stderr
    else: completion.stdout & completion.stderr
  result.exitCode = completion.exitCode
  result.timedOut = completion.timedOut
  result.durationMs = int(completion.elapsedMillis)
  result.peakResidentMemoryBytes = completion.peakResidentMemoryBytes
  result.processCount = completion.processCount
  # ``stdoutBytes``/``stderrBytes`` are the *pre-bound* counters the capture
  # loop maintains, so the comparison detects truncation exactly rather than by
  # the "output.len == limit" guess (which both misses a run that happened to
  # end on the bound and misfires on one that did not).
  result.outputBytes = completion.stdoutBytes + completion.stderrBytes
  result.truncated = result.outputBytes > uint64(result.output.len)

proc execCapturedShell*(command: string; cwd = "";
                        env: openArray[string] = [];
                        timeoutMs = -1;
                        captureLimit = DefaultCaptureLimit): CapturedRun =
  ## Run a shell command STRING, preserving the exact semantics of the
  ## ``execCmdEx(command, {poUsePath}, …)`` calls the providers are migrating
  ## off: the string is handed to the platform shell, so any shell feature the
  ## command relies on keeps working — pipes/redirections, an inline literal
  ## like ``ruby -e '…'``, or a ``commandLine(argv, pkgs)`` nix-shell wrapper.
  ##
  ## Prefer ``execCaptured`` (argv, no shell round-trip) for plain
  ## ``commandLine(argv)`` joins; reach for this only where the command is a
  ## genuine shell string. Both run through the same ``runquota_process``
  ## launch path, so either way the process work leaves ``execCmdEx`` behind.
  when defined(windows):
    execCaptured(@["cmd", "/C", command], cwd, env, timeoutMs, captureLimit)
  else:
    execCaptured(@["/bin/sh", "-c", command], cwd, env, timeoutMs, captureLimit)
