## Which files a `ct test run` read: running each provider process under
## io-mon's interpose monitor (CTC-3g).
##
## Standard.md §3.2: a producer that KNOWS its tests consumed an untracked
## file MUST NOT issue. `ct test run` knows only if it watched, so for the
## duration of a run that asks for it (``certificate_issuance.runAndAttest``,
## and only when untracked files exist in the default ``reads`` mode) every
## process a provider launches through the shared launcher
## (``process_exec.execCaptured``) is launched as
## ``io-mon run --depfile <session>/launch-<n>.iomon -- <argv>``. io-mon's shim
## follows the whole process tree, so the depfile records what the test
## process and everything it spawned opened. ``certificate_issuance`` turns the
## depfiles into the run's read set afterwards.
##
## This module only carries the session from the run to the launcher. It
## imports nothing from io-mon (the launcher is compiled into builds that do
## not carry io-mon's path) and decides nothing.
##
## WHY A THREAD-LOCAL, NOT A PARAMETER
## -----------------------------------
## Providers launch through ``execCaptured`` from their ``run`` procs, which
## ``run_orchestration`` calls on worker threads; threading a session
## parameter through some thirty provider call sites would be a change to
## every adapter's signature for a concern none of them has. The worker sets
## the session for the duration of one unit (``beginUnitCapture`` /
## ``endUnitCapture``), on its own thread, and the launcher reads it there.
## No provider spawns threads of its own (checked: only ``run_orchestration``
## and ``incremental_cli`` create threads), so every launch a unit makes is on
## the thread that set it.
##
## WHAT MAKES A CAPTURE INCOMPLETE, AND WHY THAT IS COUNTED HERE
## -------------------------------------------------------------
## A unit whose provider launched NOTHING through the launcher ran its test
## some other way (in process, or through a launcher this module does not
## see), so the monitor saw none of its reads. Such a unit is counted
## (``unitsUnmonitored``) and the whole read set is then "not captured": a read
## set that silently omitted one unit's reads is the false "read nothing" the
## default mode must never act on. Only counters cross threads, never strings,
## so a worker allocates nothing the spawning thread has to adopt.

import std/atomics

type
  ReadCaptureSession* = object
    ## One run's capture. Created, owned and read by ``runAndAttest`` on the
    ## spawning thread; the workers touch only the atomics, and read the
    ## three strings, which nothing mutates while the run is going.
    snoopCli*: string
      ## The io-mon CLI.
    shimLib*: string
      ## The interpose shim, pinned for the child (``REPRO_MONITOR_SHIM_LIB``).
    dir*: string
      ## Where the depfiles are written: ``launch-<n>.iomon``, n from 1.
    launches*: Atomic[int]
      ## How many launches were wrapped; also the last ``n`` used.
    unitsMonitored*: Atomic[int]
    unitsUnmonitored*: Atomic[int]
      ## Units that launched nothing through the launcher (see the header).

const
  DepfilePrefix* = "launch-"
  DepfileSuffix* = ".iomon"
  ShimLibEnvVar = "REPRO_MONITOR_SHIM_LIB"
    ## io-mon's own variable (``io_mon_capture.IoMonShimEnvVar``), restated
    ## because this module must not import io-mon.

var activeSession {.threadvar.}: ptr ReadCaptureSession
var unitLaunches {.threadvar.}: int

proc depfilePath*(session: ReadCaptureSession; n: int): string =
  ## The depfile of the ``n``-th wrapped launch.
  session.dir & "/" & DepfilePrefix & $n & DepfileSuffix

proc beginUnitCapture*(session: ptr ReadCaptureSession) =
  ## Called by the worker immediately before a unit's provider runs. ``nil``
  ## leaves launches unwrapped (no capture this run).
  activeSession = session
  unitLaunches = 0

proc endUnitCapture*() =
  ## Called by the worker when the unit's provider has returned (or raised).
  if activeSession != nil:
    if unitLaunches == 0:
      discard activeSession.unitsUnmonitored.fetchAdd(1)
    else:
      discard activeSession.unitsMonitored.fetchAdd(1)
  activeSession = nil
  unitLaunches = 0

proc monitoredLaunch*(argv: openArray[string]; env: var seq[string]): seq[string] =
  ## ``argv`` as the launcher should run it: unchanged when no capture is
  ## active on this thread; otherwise wrapped in ``io-mon run`` with its own
  ## depfile, and the shim pinned in ``env`` (``KEY=VALUE`` entries, layered
  ## over the inherited environment). io-mon exits with the command's own
  ## status and passes its streams through, so the caller sees the same run.
  let session = activeSession
  if session == nil or argv.len == 0:
    return @argv
  let n = session.launches.fetchAdd(1) + 1
  inc unitLaunches
  result = @[session.snoopCli, "run", "--depfile", session[].depfilePath(n), "--"]
  result.add argv
  if session.shimLib.len > 0:
    env.add ShimLibEnvVar & "=" & session.shimLib
