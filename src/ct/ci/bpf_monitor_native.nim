## Native BPF process monitor using libbpf (no bpftrace subprocess).
##
## This module provides the same monitoring capabilities as ``bpf_monitor.nim``
## (process EXEC, EXIT, and interval metrics events) but loads compiled BPF
## programs directly into the kernel via libbpf, instead of spawning bpftrace.
##
## Advantages over the bpftrace backend:
##   - Works with Linux capabilities (CAP_BPF) — no root/sudo required
##   - Efficient binary event format via ring buffer (no JSON parsing)
##   - No external script file dependency
##
## Both backends produce the same output types (``ProcessStartEvent``,
## ``ProcessExitEvent``, ``ProcessMetricsEvent``, ``ProcessEnvironment``)
## and can be used interchangeably by ``ci_commands.nim``.
##
## Usage:
##   let cap = detectNativeBPFCapability()
##   if cap == bpfAvailable:
##     var mon = startNativeMonitor(rootPid, bpfObjectPath)
##     while mon.running:
##       pollNativeEvents(mon)
##       # process mon.pendingStarts, mon.pendingExits, etc.
##     stopNativeMonitor(mon)

import std/[algorithm, os, strformat, strutils, tables, times]
import nimcrypto/[sha2, hash]
import ../online_sharing/api_client
import ci_api_client
import libbpf_wrapper

# Re-export the process event types for callers importing this module.
export ci_api_client.ProcessStartEvent
export ci_api_client.ProcessExitEvent
export ci_api_client.ProcessMetricsEvent
export ci_api_client.ProcessEnvironment

# ---------------------------------------------------------------------------
# BPF event struct definitions (mirror events.h)
# ---------------------------------------------------------------------------
# These must match the C structs in src/bpf-monitor/events.h exactly.
# The structs are read from the ring buffer via pointer casts.

const
  BPF_EVENT_EXEC_BEGIN* = 1'u32
  BPF_EVENT_EXEC_ARGV*  = 2'u32
  BPF_EVENT_EXEC_ENVP*  = 3'u32
  BPF_EVENT_EXEC_END*   = 4'u32
  BPF_EVENT_EXIT*       = 5'u32
  BPF_EVENT_INTV*       = 6'u32

  BPF_MONITOR_PATH_MAX   = 256
  BPF_MONITOR_CGROUP_MAX = 128
  BPF_MONITOR_ARG_MAX    = 256
  BPF_MONITOR_ENVKEY_MAX = 128
  BPF_MONITOR_ENVVAL_MAX = 256

type
  BpfExecBeginEvent* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    ppid*: uint32
    timestampNs*: uint64
    binaryPath*: array[BPF_MONITOR_PATH_MAX, char]
    cwd*: array[BPF_MONITOR_PATH_MAX, char]
    cgroup*: array[BPF_MONITOR_CGROUP_MAX, char]

  BpfExecArgvEvent* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    index*: uint16
    pad: uint16
    value*: array[BPF_MONITOR_ARG_MAX, char]

  BpfExecEnvpEvent* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    raw*: array[BPF_MONITOR_ENVKEY_MAX + BPF_MONITOR_ENVVAL_MAX, char]

  BpfExecEndEvent* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    execveRet*: int32
    pad: uint32

  BpfExitEventC* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    exitCode*: int32
    pad: uint32
    timestampNs*: uint64
    memMaxKb*: uint64
    netRecvBytes*: uint64
    netSendBytes*: uint64
    diskReadBytes*: uint64
    diskWriteBytes*: uint64

  BpfIntvEventC* {.packed.} = object
    eventType*: uint32
    pid*: uint32
    timestampNs*: uint64
    cpuNs*: uint64
    memRssKb*: uint64
    netRecvBytes*: uint64
    netSendBytes*: uint64
    diskReadBytes*: uint64
    diskWriteBytes*: uint64

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  NativeBPFCapability* = enum
    ## Result of probing for native BPF support.
    nbpfAvailable       ## BPF programs load and attach successfully
    nbpfNoObject        ## monitor.bpf.o file not found
    nbpfLoadFailed      ## BPF object failed to load (kernel/verifier error)
    nbpfAttachFailed    ## Tracepoint attachment failed (permissions?)
    nbpfUnsupported     ## Other failure

  NativeExecAccumulator = object
    ## Accumulates EXEC sub-events until EXEC_END arrives.
    pid: int
    parentPid: int
    timestampNs: uint64
    binaryPath: string
    cwd: string
    cgroup: string
    argv: seq[string]
    envVars: seq[tuple[key: string, value: string]]

  NativeBPFMonitor* = object
    ## Handle for native BPF monitoring via libbpf.
    bpfObj: ptr BpfObject
    ringBuf: ptr RingBuffer
    links: seq[ptr BpfLink]
    rootPid*: int
    running*: bool
    bpfObjectPath*: string
    ## Event buffers — same types as BPFMonitor for API compatibility.
    pendingStarts*: seq[ProcessStartEvent]
    pendingExits*: seq[ProcessExitEvent]
    pendingMetrics*: seq[ProcessMetricsEvent]
    pendingEnvs*: seq[ProcessEnvironment]
    ## Internal accumulators
    execAccum: Table[int, NativeExecAccumulator]
    knownEnvIds: Table[string, bool]

# ---------------------------------------------------------------------------
# Timestamp conversion
# ---------------------------------------------------------------------------

proc ktime_nsToIso8601(ns: uint64): string =
  ## Converts a ktime_get_ns() nanosecond timestamp to ISO 8601 UTC.
  ##
  ## ktime_get_ns() returns time since boot (CLOCK_MONOTONIC).
  ## We convert to wall-clock time by computing the offset between
  ## CLOCK_MONOTONIC and CLOCK_REALTIME at the current moment.
  ## This is approximate (the offset can drift by a few ms over time)
  ## but sufficient for process monitoring timestamps.
  let now = epochTime()
  # CLOCK_MONOTONIC as nanoseconds (approximate — we use the BPF event's
  # own ktime value, which was captured atomically in the kernel).
  # Wall clock conversion:
  # wall_ns = ktime_ns + (realtime - monotonic).
  # We approximate (realtime - monotonic) as (now - uptime).
  # For simplicity, just use the current wall clock time for events
  # arriving in near-real-time (< 1s latency from kernel to userspace).
  let secs = int64(ns) div 1_000_000_000'i64
  let millis = (int64(ns) mod 1_000_000_000'i64) div 1_000_000'i64

  # Read system boot time from /proc/stat to compute the offset.
  # Fallback: use current time if we can't read it.
  var bootTimeS: int64 = 0
  try:
    let uptimeStr = readFile("/proc/uptime").split(" ")[0]
    let uptimeS = int64(parseFloat(uptimeStr))
    let realtimeS = int64(now)
    bootTimeS = realtimeS - uptimeS
  except:
    # Fallback: approximate boot time as (now - ktime/1e9).
    bootTimeS = int64(now) - secs

  let wallSecs = bootTimeS + secs
  let dt = fromUnix(wallSecs).utc()
  dt.format("yyyy-MM-dd'T'HH:mm:ss") & fmt".{millis:03d}Z"

# ---------------------------------------------------------------------------
# C char array → Nim string conversion
# ---------------------------------------------------------------------------

proc charArrayToString(arr: openArray[char]): string =
  ## Converts a null-terminated C char array to a Nim string.
  result = ""
  for c in arr:
    if c == '\0':
      break
    result.add(c)

# ---------------------------------------------------------------------------
# Environment hashing (matches bpf_monitor.nim's computeEnvId)
# ---------------------------------------------------------------------------

proc computeEnvId(envVars: seq[tuple[key: string, value: string]]): string =
  ## SHA-256 hex digest of sorted environment variables.
  var sorted = envVars
  sorted.sort(
    proc(a, b: tuple[key: string, value: string]): int =
      cmp(a.key, b.key))
  var ctx: sha256
  ctx.init()
  for kv in sorted:
    ctx.update(kv.key)
    ctx.update("=")
    ctx.update(kv.value)
    ctx.update("\n")
  result = $ctx.finish()

# ---------------------------------------------------------------------------
# Ring buffer callback
# ---------------------------------------------------------------------------
# This is called by libbpf for each event in the ring buffer during
# ringBufferPoll(). The ctx pointer is a NativeBPFMonitor*.

proc ringBufferCallback(ctx: pointer, data: pointer,
    size: csize_t): cint {.cdecl.} =
  ## Processes a single BPF ring buffer event.
  ## Called by libbpf during ringBufferPoll().
  if size < csize_t(sizeof(uint32)):
    return 0

  let monitor = cast[ptr NativeBPFMonitor](ctx)
  let eventType = cast[ptr uint32](data)[]

  case eventType
  of BPF_EVENT_EXEC_BEGIN:
    if size < csize_t(sizeof(BpfExecBeginEvent)):
      return 0
    let ev = cast[ptr BpfExecBeginEvent](data)
    let pid = int(ev.pid)
    var accum = NativeExecAccumulator(
      pid: pid,
      parentPid: int(ev.ppid),
      timestampNs: ev.timestampNs,
      binaryPath: charArrayToString(ev.binaryPath),
      cwd: charArrayToString(ev.cwd),
      cgroup: charArrayToString(ev.cgroup),
      argv: @[],
      envVars: @[],
    )
    monitor.execAccum[pid] = accum

  of BPF_EVENT_EXEC_ARGV:
    if size < csize_t(sizeof(BpfExecArgvEvent)):
      return 0
    let ev = cast[ptr BpfExecArgvEvent](data)
    let pid = int(ev.pid)
    if pid in monitor.execAccum:
      monitor.execAccum[pid].argv.add(charArrayToString(ev.value))

  of BPF_EVENT_EXEC_ENVP:
    if size < csize_t(sizeof(BpfExecEnvpEvent)):
      return 0
    let ev = cast[ptr BpfExecEnvpEvent](data)
    let pid = int(ev.pid)
    if pid in monitor.execAccum:
      # Split raw "KEY=VALUE" string into key and value.
      let rawStr = charArrayToString(ev.raw)
      let eqPos = rawStr.find('=')
      let key = if eqPos >= 0: rawStr[0..<eqPos] else: rawStr
      let value = if eqPos >= 0: rawStr[eqPos+1..^1] else: ""
      monitor.execAccum[pid].envVars.add((key, value))

  of BPF_EVENT_EXEC_END:
    if size < csize_t(sizeof(BpfExecEndEvent)):
      return 0
    let ev = cast[ptr BpfExecEndEvent](data)
    let pid = int(ev.pid)
    if pid in monitor.execAccum:
      let accum = monitor.execAccum[pid]
      monitor.execAccum.del(pid)

      # Only emit events for successful execve (ret == 0).
      if ev.execveRet != 0:
        return 0

      # Compute environment ID and emit ProcessEnvironment if new.
      var envId = ""
      if accum.envVars.len > 0:
        envId = computeEnvId(accum.envVars)
        if envId notin monitor.knownEnvIds:
          monitor.knownEnvIds[envId] = true
          monitor.pendingEnvs.add(ProcessEnvironment(
            id: envId,
            variables: accum.envVars,
          ))

      # Build command line from argv.
      let cmdLine = accum.argv.join(" ")

      # Build working directory — prefer BPF-captured cwd, fallback to
      # reading /proc/<pid>/cwd.
      var workDir = accum.cwd
      if workDir.len == 0:
        try:
          workDir = expandSymlink("/proc/" & $pid & "/cwd")
        except:
          workDir = ""

      monitor.pendingStarts.add(ProcessStartEvent(
        pid: pid,
        parentPid: accum.parentPid,
        binaryPath: accum.binaryPath,
        commandLine: cmdLine,
        workingDirectory: workDir,
        environmentId: envId,
        startedAt: ktime_nsToIso8601(accum.timestampNs),
      ))

  of BPF_EVENT_EXIT:
    if size < csize_t(sizeof(BpfExitEventC)):
      return 0
    let ev = cast[ptr BpfExitEventC](data)
    monitor.pendingExits.add(ProcessExitEvent(
      pid: int(ev.pid),
      exitCode: int(ev.exitCode),
      exitedAt: ktime_nsToIso8601(ev.timestampNs),
      maxMemoryBytes: int64(ev.memMaxKb) * 1024,
      totalNetRecvBytes: int64(ev.netRecvBytes),
      totalNetSendBytes: int64(ev.netSendBytes),
      totalDiskReadBytes: int64(ev.diskReadBytes),
      totalDiskWriteBytes: int64(ev.diskWriteBytes),
      cpuTimeNs: 0,  # Phase 2
    ))

    # Check if the root PID has exited.
    if int(ev.pid) == monitor.rootPid:
      monitor.running = false

  of BPF_EVENT_INTV:
    if size < csize_t(sizeof(BpfIntvEventC)):
      return 0
    let ev = cast[ptr BpfIntvEventC](data)
    # TODO Phase 2: convert cpu_ns to percent using interval duration.
    monitor.pendingMetrics.add(ProcessMetricsEvent(
      pid: int(ev.pid),
      timestamp: ktime_nsToIso8601(ev.timestampNs),
      cpuPercent: 0.0,  # Phase 2: cpuNs / intervalNs * 100
      memoryBytes: int64(ev.memRssKb) * 1024,
      diskReadBytes: int64(ev.diskReadBytes),
      diskWriteBytes: int64(ev.diskWriteBytes),
      netSendBytes: int64(ev.netSendBytes),
      netRecvBytes: int64(ev.netRecvBytes),
    ))

  else:
    discard  # Unknown event type — skip.

  return 0  # Continue processing.

# ---------------------------------------------------------------------------
# Capability detection
# ---------------------------------------------------------------------------

proc detectNativeBPFCapability*(bpfObjectPath: string): NativeBPFCapability =
  ## Probes whether native BPF monitoring is available by attempting to
  ## open, load, and briefly attach the BPF programs.
  ## Immediately tears down after the check.
  if not fileExists(bpfObjectPath):
    return nbpfNoObject

  let obj = bpfObjectOpenFile(bpfObjectPath.cstring, nil)
  if obj == nil:
    return nbpfLoadFailed

  let loadRc = bpfObjectLoad(obj)
  if loadRc != 0:
    bpfObjectClose(obj)
    return nbpfLoadFailed

  # Try attaching the simplest program (sched_process_exit) as a smoke test.
  let prog = bpfObjectFindProgramByName(obj, "handle_sched_exit")
  if prog == nil:
    bpfObjectClose(obj)
    return nbpfLoadFailed

  let link = bpfProgramAttach(prog)
  if link == nil:
    bpfObjectClose(obj)
    return nbpfAttachFailed

  # Success — clean up.
  discard bpfLinkDestroy(link)
  bpfObjectClose(obj)
  return nbpfAvailable

# ---------------------------------------------------------------------------
# Monitor lifecycle
# ---------------------------------------------------------------------------

proc startNativeMonitor*(rootPid: int,
    bpfObjectPath: string): NativeBPFMonitor =
  ## Starts native BPF monitoring for the given root PID.
  ##
  ## Opens the BPF object, loads programs, attaches to tracepoints,
  ## seeds the PID filter map, and creates the ring buffer consumer.
  ##
  ## Raises ``OSError`` if any step fails.
  result = NativeBPFMonitor(
    rootPid: rootPid,
    running: false,
    bpfObjectPath: bpfObjectPath,
    pendingStarts: @[],
    pendingExits: @[],
    pendingMetrics: @[],
    pendingEnvs: @[],
    execAccum: initTable[int, NativeExecAccumulator](),
    knownEnvIds: initTable[string, bool](),
    links: @[],
  )

  # Open and load BPF object.
  result.bpfObj = bpfObjectOpenFile(bpfObjectPath.cstring, nil)
  if result.bpfObj == nil:
    raise newException(OSError,
      "Failed to open BPF object: " & bpfObjectPath)

  let loadRc = bpfObjectLoad(result.bpfObj)
  if loadRc != 0:
    let msg = libbpfError(loadRc)
    bpfObjectClose(result.bpfObj)
    result.bpfObj = nil
    raise newException(OSError,
      "Failed to load BPF programs: " & msg)

  # Attach all programs.
  let programs = [
    ("handle_execve_enter", "syscalls", "sys_enter_execve"),
    ("handle_execve_exit", "syscalls", "sys_exit_execve"),
    ("handle_sched_exit", "sched", "sched_process_exit"),
  ]

  for (funcName, category, tpName) in programs:
    let prog = bpfObjectFindProgramByName(result.bpfObj, funcName.cstring)
    if prog == nil:
      raise newException(OSError,
        "BPF program not found: " & funcName)

    let link = bpfProgramAttachTracepoint(prog,
      category.cstring, tpName.cstring)
    if link == nil:
      raise newException(OSError,
        fmt"Failed to attach {funcName} to {category}/{tpName}")
    result.links.add(link)

  # Seed the root PID in the process_tracked map.
  let trackedMap = bpfObjectFindMapByName(result.bpfObj, "process_tracked")
  if trackedMap == nil:
    raise newException(OSError, "BPF map 'process_tracked' not found")

  let mapFd = bpfMapFd(trackedMap)
  var pidKey = uint32(rootPid)
  var tracked: uint8 = 1
  let updateRc = bpfMapUpdateElem(mapFd, addr pidKey, addr tracked, 0)
  if updateRc != 0:
    raise newException(OSError,
      "Failed to seed root PID in process_tracked map")

  # Create ring buffer consumer.
  let eventsMap = bpfObjectFindMapByName(result.bpfObj, "events")
  if eventsMap == nil:
    raise newException(OSError, "BPF map 'events' not found")

  let eventsFd = bpfMapFd(eventsMap)
  result.ringBuf = ringBufferNew(eventsFd, ringBufferCallback,
    addr result, nil)
  if result.ringBuf == nil:
    raise newException(OSError, "Failed to create ring buffer consumer")

  result.running = true

proc pollNativeEvents*(monitor: var NativeBPFMonitor, timeoutMs: int = 0) =
  ## Polls the BPF ring buffer for new events.
  ##
  ## Any events found are appended to the monitor's pending buffers
  ## (pendingStarts, pendingExits, pendingMetrics, pendingEnvs).
  ##
  ## ``timeoutMs``: 0 for non-blocking, >0 for timeout in ms, -1 to block.
  if not monitor.running and monitor.ringBuf == nil:
    return

  # ringBufferPoll invokes ringBufferCallback for each event.
  discard ringBufferPoll(monitor.ringBuf, cint(timeoutMs))

proc hasPendingEvents*(monitor: NativeBPFMonitor): bool =
  ## Returns true if there are any unprocessed events.
  monitor.pendingStarts.len > 0 or
    monitor.pendingExits.len > 0 or
    monitor.pendingMetrics.len > 0 or
    monitor.pendingEnvs.len > 0

proc clearPendingEvents*(monitor: var NativeBPFMonitor) =
  ## Clears all pending event buffers after they've been flushed.
  monitor.pendingStarts.setLen(0)
  monitor.pendingExits.setLen(0)
  monitor.pendingMetrics.setLen(0)
  monitor.pendingEnvs.setLen(0)

proc flushEvents*(monitor: var NativeBPFMonitor, client: ApiClient,
                  token: string, runId: string) =
  ## POSTs all pending process events to the backend in a single batch,
  ## then clears the buffers.
  ##
  ## Silently ignores API errors to avoid disrupting the main exec loop.
  if not hasPendingEvents(monitor):
    return

  try:
    reportProcessEvents(client, token, runId,
                        monitor.pendingStarts,
                        monitor.pendingExits,
                        monitor.pendingMetrics,
                        monitor.pendingEnvs)
  except CIApiError as e:
    echo fmt"Warning: failed to report process events: {e.msg}"
  except CatchableError as e:
    echo fmt"Warning: failed to report process events: {e.msg}"

  clearPendingEvents(monitor)

proc stopNativeMonitor*(monitor: var NativeBPFMonitor) =
  ## Stops BPF monitoring and releases all resources.
  ##
  ## Does a final poll to drain any remaining events, then destroys
  ## the ring buffer, detaches programs, and closes the BPF object.
  monitor.running = false

  # Final drain — non-blocking poll to capture any events in the buffer.
  if monitor.ringBuf != nil:
    discard ringBufferPoll(monitor.ringBuf, 0)
    ringBufferFree(monitor.ringBuf)
    monitor.ringBuf = nil

  # Detach all tracepoint programs.
  for link in monitor.links:
    discard bpfLinkDestroy(link)
  monitor.links.setLen(0)

  # Close the BPF object (releases maps, programs, etc).
  if monitor.bpfObj != nil:
    bpfObjectClose(monitor.bpfObj)
    monitor.bpfObj = nil

# ---------------------------------------------------------------------------
# Default BPF object path
# ---------------------------------------------------------------------------

proc defaultBpfObjectPath*(): string =
  ## Returns the expected path to monitor.bpf.o.
  ## Checks (in order):
  ##   1. CODETRACER_BPF_OBJECT environment variable
  ##   2. $CODETRACER_PREFIX/share/monitor.bpf.o
  ##   3. <exe-dir>/../share/monitor.bpf.o (relative to the ct binary)
  ##   4. <repo-root>/src/build-debug-repro/share/monitor.bpf.o
  ##   5. /usr/local/lib/codetracer/monitor.bpf.o
  ##      (installed by ct install --bpf)
  result = getEnv("CODETRACER_BPF_OBJECT")
  if result.len > 0 and fileExists(result):
    return result

  let prefix = getEnv("CODETRACER_PREFIX")
  if prefix.len > 0:
    result = prefix / "share" / "monitor.bpf.o"
    if fileExists(result):
      return result

  # Relative to the running binary: <exe-dir>/../share/monitor.bpf.o.
  # This handles installed layouts (AppImage, /usr/local prefix).
  let exeDir = getAppDir()
  result = exeDir.parentDir / "share" / "monitor.bpf.o"
  if fileExists(result):
    return result

  # Fallback: relative to repo root (dev builds).
  let repoRoot = getEnv("CODETRACER_REPO_ROOT_PATH")
  if repoRoot.len > 0:
    result = repoRoot / "src" / "build-debug-repro" / "share" / "monitor.bpf.o"
    if fileExists(result):
      return result

  # Last resort: system-wide install path set by `ct install --bpf`.
  const systemInstallPath = "/usr/local/lib/codetracer/monitor.bpf.o"
  if fileExists(systemInstallPath):
    return systemInstallPath

  return ""

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc initTestNativeMonitor*(rootPid: int = 100): NativeBPFMonitor =
  ## Creates a NativeBPFMonitor with initialized accumulators but no BPF.
  ## Used by unit tests to exercise the ring buffer callback logic without
  ## needing actual kernel BPF support.
  result = NativeBPFMonitor(
    rootPid: rootPid,
    running: true,
    bpfObjectPath: "",
    bpfObj: nil,
    ringBuf: nil,
    links: @[],
    pendingStarts: @[],
    pendingExits: @[],
    pendingMetrics: @[],
    pendingEnvs: @[],
    execAccum: initTable[int, NativeExecAccumulator](),
    knownEnvIds: initTable[string, bool](),
  )

proc testRingBufferCallback*(monitor: var NativeBPFMonitor,
    data: pointer, size: csize_t): cint =
  ## Test wrapper for ringBufferCallback that passes the monitor pointer.
  ringBufferCallback(addr monitor, data, size)
