## BPFTrace-based process tree monitor for CI runs.
##
## Spawns ``bpftrace`` with the ``bpftrace-collection.bt`` script to capture
## process lifecycle events (exec, exit, interval metrics) for the monitored
## process tree. Parsed events are accumulated in batches and flushed to the
## Monolith backend via ``ci_api_client.reportProcessEvents``.
##
## The monitor is strictly optional: if bpftrace is unavailable or sudo
## cannot be used without a password, the monitor degrades gracefully and
## the CI run proceeds without process monitoring.
##
## BPFTrace JSON output format (from ``bpftrace -f json``):
##   ``{"type": "printf", "data": "EXEC;BEGIN;1234;5678;1234567890;/bin/bash"}``
##
## Event types parsed:
## - ``EXEC`` -- multi-part process start (BEGIN, CGROUP, DIR, ARGV, ENVP, END)
## - ``EXIT`` -- single-line process exit with cumulative resource totals
## - ``INTV`` -- periodic interval metrics (CPU, MEM, NETR, NETW, DSKR, DSKW, LE, END)
##
## For the exact field layout, see ``BPFParseConstants.cs`` in the EventSourcing repo
## and the ``bpftrace-collection.bt`` script.

import std/[algorithm, json, os, osproc, posix, streams,
            strformat, strutils, tables, times]
import nimcrypto/[sha2, hash]
import ../online_sharing/api_client
import ci_api_client
import ../../common/bpf_install

# Re-export the process event types defined in ci_api_client so that
# callers can import them from either module.
export ci_api_client.ProcessStartEvent
export ci_api_client.ProcessExitEvent
export ci_api_client.ProcessMetricsEvent
export ci_api_client.ProcessEnvironment

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  BPFCapability* = enum
    ## Result of probing the host for BPFTrace support.
    bpfAvailable      ## bpftrace found and passwordless sudo works
    bpfNoBinary       ## bpftrace not in PATH
    bpfNoPermission   ## sudo -n bpftrace test failed
    bpfUnsupported    ## other failure (e.g. kernel too old)

  ExecAccumulator = object
    ## Accumulates EXEC sub-events until END is received.
    pid: int
    parentPid: int
    timestampNs: int64
    binaryPath: string
    cgroupParts: seq[string]   # reversed order from bpftrace
    dirParts: seq[string]      # reversed order from bpftrace
    argvParts: seq[string]
    envpParts: seq[string]

  IntervalAccumulator = object
    ## Accumulates INTV sub-events for a single interval window until END.
    cpuByPid: Table[int, int64]
    memByPid: Table[int, int64]
    netRecvByPid: Table[int, int64]
    netSendByPid: Table[int, int64]
    diskReadByPid: Table[int, int64]
    diskWriteByPid: Table[int, int64]
    lastEventPids: Table[int, bool]

  BPFMonitor* = object
    ## Handle for the running bpftrace subprocess and its event buffers.
    process*: Process           ## bpftrace subprocess
    rootPid*: int               ## PID of the monitored child process tree root
    running*: bool
    scriptPath*: string         ## path to bpftrace-collection.bt
    pendingStarts*: seq[ProcessStartEvent]
    pendingExits*: seq[ProcessExitEvent]
    pendingMetrics*: seq[ProcessMetricsEvent]
    pendingEnvs*: seq[ProcessEnvironment]
    # Internal accumulators
    execAccum: Table[int, ExecAccumulator]
    intervalAccum: IntervalAccumulator
    # Track known environment hashes to avoid re-sending duplicates.
    knownEnvIds: Table[string, bool]
    # File descriptor and partial-line buffer for non-blocking reads.
    pipeFd: cint
    readBuf: string

# ---------------------------------------------------------------------------
# Nanosecond timestamp helpers
# ---------------------------------------------------------------------------

const
  ## TAI offset relative to UTC (37 leap seconds as of 2024).
  ## bpftrace uses ``nsecs(sw_tai)`` which is TAI-based.
  ## We approximate by subtracting the leap-second offset to get
  ## a Unix-epoch nanosecond timestamp.
  TaiLeapSecondsNs = 37_000_000_000'i64

proc nsToIso8601*(ns: int64): string =
  ## Converts a TAI nanosecond timestamp to an ISO 8601 UTC string.
  ## The conversion subtracts the known TAI-UTC leap second offset.
  let unixNs = ns - TaiLeapSecondsNs
  let secs = unixNs div 1_000_000_000
  let millis = (unixNs mod 1_000_000_000) div 1_000_000
  let dt = fromUnix(secs).utc()
  dt.format("yyyy-MM-dd'T'HH:mm:ss") & fmt".{millis:03d}Z"

# ---------------------------------------------------------------------------
# Environment hashing
# ---------------------------------------------------------------------------

proc computeEnvId*(envVars: seq[tuple[key: string, value: string]]): string =
  ## Computes a SHA-256 hex digest of the sorted environment variables.
  ## Matches the content-addressing scheme used by the backend.
  var sorted = envVars
  sorted.sort(proc(a, b: tuple[key: string, value: string]): int = cmp(a.key, b.key))
  var ctx: sha256
  ctx.init()
  for kv in sorted:
    let line = kv.key & "=" & kv.value & "\n"
    ctx.update(line)
  let digest = ctx.finish()
  ctx.clear()
  result = $digest

# ---------------------------------------------------------------------------
# BPF capability detection
# ---------------------------------------------------------------------------

proc findBpftrace(): string =
  ## Locate the best bpftrace binary using the priority from bpf_install:
  ## nix wrapper > local install with capabilities > system (with sudo).
  ## Returns an empty string if no bpftrace binary is found.
  let path = getBpftracePath()
  if path.len > 0:
    return path
  return ""

proc detectBPFCapability*(): BPFCapability =
  ## Checks if bpftrace is available and can be used for process monitoring.
  ##
  ## Priority order:
  ## 1. NixOS wrapper or local capabilities-aware install -- test without sudo
  ## 2. System bpftrace -- test with passwordless sudo
  ##
  ## Returns ``bpfAvailable`` if bpftrace can run, ``bpfNoBinary`` if not
  ## found, ``bpfNoPermission`` if sudo is required but unavailable, or
  ## ``bpfUnsupported`` on unexpected failures.
  let bpftracePath = findBpftrace()
  if bpftracePath.len == 0:
    return bpfNoBinary

  # If using nix wrapper or local install with capabilities, test without sudo.
  if isNixManagedBpf() or isLocalBpfInstalled():
    try:
      let testCmd = startProcess(bpftracePath,
                                 args = @["-e", "BEGIN { exit(); }"],
                                 options = {poStdErrToStdOut, poUsePath})
      let exitCode = waitForExit(testCmd)
      close(testCmd)
      if exitCode == 0:
        return bpfAvailable
      # Fall through to sudo check if capabilities-based run failed.
    except CatchableError:
      discard

  # Try with passwordless sudo as a fallback.
  try:
    let testCmd = startProcess("sudo",
                               args = @["-n", bpftracePath, "-e",
                                        "BEGIN { exit(); }"],
                               options = {poStdErrToStdOut, poUsePath})
    let exitCode = waitForExit(testCmd)
    close(testCmd)
    if exitCode == 0:
      return bpfAvailable
    else:
      return bpfNoPermission
  except OSError:
    return bpfUnsupported
  except CatchableError:
    return bpfUnsupported

# ---------------------------------------------------------------------------
# Script location
# ---------------------------------------------------------------------------

proc findBPFTraceScript*(): string =
  ## Locates the bpftrace-collection.bt script.
  ##
  ## Search order:
  ## 1. ``CODETRACER_BPFTRACE_SCRIPT`` environment variable
  ## 2. Relative to the ct binary: ``../share/codetracer/bpftrace-collection.bt``
  ## 3. Development fallback: ``../../codetracer-ci/apps/EventSourcing/EventSourcing.Host/bpftrace-collection.bt``
  ##    (relative to the ct binary's grandparent, i.e. the workspace root)
  ##
  ## Returns an empty string if not found.
  let envPath = getEnv("CODETRACER_BPFTRACE_SCRIPT", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath

  # Relative to the ct binary (installed layout).
  let ctBin = getAppFilename()
  let shareScript = ctBin.parentDir.parentDir / "share" / "codetracer" /
                    "bpftrace-collection.bt"
  if fileExists(shareScript):
    return shareScript

  # Development layout: workspace root contains codetracer/ and codetracer-ci/ side by side.
  # The ct binary is typically at src/build-debug/bin/ct, so we walk up to the repo root.
  let repoRoot = ctBin.parentDir.parentDir.parentDir  # src/build-debug/bin -> src/build-debug -> src -> repo
  let devScript = repoRoot.parentDir / "codetracer-ci" / "apps" /
                  "EventSourcing" / "EventSourcing.Host" / "bpftrace-collection.bt"
  if fileExists(devScript):
    return devScript

  return ""

# ---------------------------------------------------------------------------
# Monitor lifecycle
# ---------------------------------------------------------------------------

proc initTestMonitor*(): BPFMonitor =
  ## Creates a BPFMonitor with initialized accumulators but no subprocess.
  ## Used by unit tests to exercise the parsing logic without needing bpftrace.
  result.rootPid = 0
  result.running = false
  result.execAccum = initTable[int, ExecAccumulator]()
  result.intervalAccum = IntervalAccumulator(
    cpuByPid: initTable[int, int64](),
    memByPid: initTable[int, int64](),
    netRecvByPid: initTable[int, int64](),
    netSendByPid: initTable[int, int64](),
    diskReadByPid: initTable[int, int64](),
    diskWriteByPid: initTable[int, int64](),
    lastEventPids: initTable[int, bool](),
  )
  result.knownEnvIds = initTable[string, bool]()

proc startMonitor*(rootPid: int, scriptPath: string): BPFMonitor =
  ## Spawns bpftrace to monitor the process tree rooted at ``rootPid``.
  ##
  ## The script receives the root PID as ``$1`` and uses it to auto-exit
  ## when that process terminates. Output is JSON-formatted (``-f json``)
  ## with no buffering (``-B none``).
  ##
  ## Raises ``OSError`` if the bpftrace process cannot be started.
  result.rootPid = rootPid
  result.scriptPath = scriptPath
  result.execAccum = initTable[int, ExecAccumulator]()
  result.intervalAccum = IntervalAccumulator(
    cpuByPid: initTable[int, int64](),
    memByPid: initTable[int, int64](),
    netRecvByPid: initTable[int, int64](),
    netSendByPid: initTable[int, int64](),
    diskReadByPid: initTable[int, int64](),
    diskWriteByPid: initTable[int, int64](),
    lastEventPids: initTable[int, bool](),
  )
  result.knownEnvIds = initTable[string, bool]()

  # Use the capabilities-aware bpftrace path when available,
  # falling back to sudo for the raw system binary.
  let bpftracePath = findBpftrace()
  let useSudo = not (isNixManagedBpf() or isLocalBpfInstalled())

  if useSudo:
    result.process = startProcess("sudo",
      args = @[bpftracePath, "-f", "json", "-B", "none", scriptPath, $rootPid],
      options = {poUsePath, poStdErrToStdOut})
  else:
    result.process = startProcess(bpftracePath,
      args = @["-f", "json", "-B", "none", scriptPath, $rootPid],
      options = {poUsePath, poStdErrToStdOut})
  result.running = true

  # Set the stdout pipe to non-blocking mode so that ``pollEvents`` can
  # return immediately when no data is available.
  result.pipeFd = cint(outputHandle(result.process))
  when defined(posix):
    let flags = fcntl(result.pipeFd, F_GETFL)
    discard fcntl(result.pipeFd, F_SETFL, flags or O_NONBLOCK)
  # On Windows, bpftrace is unavailable, so this code path is effectively
  # dead — the monitor degrades gracefully. The fcntl/F_GETFL/O_NONBLOCK
  # symbols come from `std/posix`, which only exposes them on POSIX
  # systems. Pipe non-blocking on Windows would use SetNamedPipeHandleState,
  # but there is no Windows BPF analogue to drive, so we skip the setup.

# ---------------------------------------------------------------------------
# Event parsing
# ---------------------------------------------------------------------------

proc parseExecEvent(monitor: var BPFMonitor, splits: seq[string]) =
  ## Handles EXEC sub-events. Accumulates parts until END, then emits
  ## a complete ``ProcessStartEvent``.
  if splits.len < 3:
    return

  let eventType = splits[1]  # BEGIN, CGROUP, DIR, ARGV, ENVP, END

  if eventType == "BEGIN":
    # EXEC;BEGIN;pid;ppid;timestamp_ns;binary_path
    if splits.len < 6:
      return
    let pid = parseInt(splits[2])
    let ppid = parseInt(splits[3])
    let tsNs = parseBiggestInt(splits[4])
    let binaryPath = splits[5..^1].join(";")  # binary path may contain semicolons (unlikely but safe)
    monitor.execAccum[pid] = ExecAccumulator(
      pid: pid,
      parentPid: ppid,
      timestampNs: tsNs,
      binaryPath: binaryPath,
    )

  elif eventType == "END":
    # EXEC;END;pid
    if splits.len < 3:
      return
    let pid = parseInt(splits[2])
    if pid notin monitor.execAccum:
      return
    let accum = monitor.execAccum[pid]
    monitor.execAccum.del(pid)

    # Build the working directory by reversing the directory parts
    # (bpftrace walks from the leaf to root).
    var workDir = ""
    for i in countdown(accum.dirParts.high, 0):
      workDir &= "/" & accum.dirParts[i]
    if workDir.len == 0:
      workDir = "/"

    # Build the command line from argv parts.
    let cmdLine = accum.argvParts.join(" ")

    # Build environment and compute content-addressed ID.
    var envVars: seq[tuple[key: string, value: string]] = @[]
    var envId = ""
    if accum.envpParts.len > 0:
      for envLine in accum.envpParts:
        let eqPos = envLine.find('=')
        if eqPos > 0:
          envVars.add((key: envLine[0..<eqPos], value: envLine[eqPos+1..^1]))
      envId = computeEnvId(envVars)

      # Only send environment if we haven't sent it before.
      if envId notin monitor.knownEnvIds:
        monitor.knownEnvIds[envId] = true
        monitor.pendingEnvs.add(ProcessEnvironment(
          id: envId,
          variables: envVars,
        ))

    monitor.pendingStarts.add(ProcessStartEvent(
      pid: accum.pid,
      parentPid: accum.parentPid,
      binaryPath: accum.binaryPath,
      commandLine: cmdLine,
      workingDirectory: workDir,
      environmentId: envId,
      startedAt: nsToIso8601(accum.timestampNs),
    ))

  elif eventType == "CGROUP":
    # EXEC;CGROUP;pid;d;ld;cgroup_part
    if splits.len < 6:
      return
    let pid = parseInt(splits[2])
    if pid notin monitor.execAccum:
      return
    let cgroupPart = splits[5..^1].join(";")
    monitor.execAccum[pid].cgroupParts.add(cgroupPart)

  elif eventType == "DIR":
    # EXEC;DIR;pid;d;ld;dir_part
    if splits.len < 6:
      return
    let pid = parseInt(splits[2])
    if pid notin monitor.execAccum:
      return
    let dirPart = splits[5..^1].join(";")
    monitor.execAccum[pid].dirParts.add(dirPart)

  elif eventType == "ARGV":
    # EXEC;ARGV;pid;d;ld;argv_part
    if splits.len < 6:
      return
    let pid = parseInt(splits[2])
    if pid notin monitor.execAccum:
      return
    let argvPart = splits[5..^1].join(";")
    monitor.execAccum[pid].argvParts.add(argvPart)

  elif eventType == "ENVP":
    # EXEC;ENVP;pid;d;ld;envp_part
    if splits.len < 6:
      return
    let pid = parseInt(splits[2])
    if pid notin monitor.execAccum:
      return
    let envpPart = splits[5..^1].join(";")
    monitor.execAccum[pid].envpParts.add(envpPart)

proc parseExitEvent(monitor: var BPFMonitor, splits: seq[string]) =
  ## Parses a single EXIT line.
  ## Format: EXIT;pid;timestamp_ns;exit_code;max_mem;net_recv;net_send;disk_read;disk_write;cpu_time;execve_return_code
  ## Indices (from BPFParseConstants.Exit):
  ##   [0]=EXIT, [1]=pid, [2]=timestamp_ns, [3]=exit_code, [4]=max_mem,
  ##   [5]=net_recv, [6]=net_send, [7]=disk_read, [8]=disk_write,
  ##   [9]=cpu_time, [10]=execve_return_code
  if splits.len < 10:
    return
  let pid = parseInt(splits[1])
  let tsNs = parseBiggestInt(splits[2])
  let exitCode = parseInt(splits[3])
  let maxMem = parseBiggestInt(splits[4])
  let netRecv = parseBiggestInt(splits[5])
  let netSend = parseBiggestInt(splits[6])
  let diskRead = parseBiggestInt(splits[7])
  let diskWrite = parseBiggestInt(splits[8])
  let cpuTime = parseBiggestInt(splits[9])

  monitor.pendingExits.add(ProcessExitEvent(
    pid: pid,
    exitCode: exitCode,
    exitedAt: nsToIso8601(tsNs),
    maxMemoryBytes: maxMem,
    totalNetRecvBytes: netRecv,
    totalNetSendBytes: netSend,
    totalDiskReadBytes: diskRead,
    totalDiskWriteBytes: diskWrite,
    cpuTimeNs: cpuTime,
  ))

proc parseIntervalEvent(monitor: var BPFMonitor, splits: seq[string]) =
  ## Parses INTV sub-events. Accumulates per-PID metrics until INTV;END,
  ## then emits ``ProcessMetricsEvent`` objects for each observed PID.
  ## Format: INTV;subtype;pid;value;
  ## Indices (from BPFParseConstants.Interval):
  ##   [0]=INTV, [1]=subtype, [2]=pid, [3]=value
  if splits.len < 4:
    return

  let subType = splits[1]

  if subType == "END":
    # INTV;END;0;timestamp_ns
    let tsNs = parseBiggestInt(splits[3])
    let timestamp = nsToIso8601(tsNs)

    # Collect all PIDs that had any metric in this interval window.
    var allPids: Table[int, bool]
    for pid in monitor.intervalAccum.cpuByPid.keys: allPids[pid] = true
    for pid in monitor.intervalAccum.memByPid.keys: allPids[pid] = true
    for pid in monitor.intervalAccum.netRecvByPid.keys: allPids[pid] = true
    for pid in monitor.intervalAccum.netSendByPid.keys: allPids[pid] = true
    for pid in monitor.intervalAccum.diskReadByPid.keys: allPids[pid] = true
    for pid in monitor.intervalAccum.diskWriteByPid.keys: allPids[pid] = true

    for pid in allPids.keys:
      # Skip PIDs that only appeared in the "last event" set (process already exited).
      if pid in monitor.intervalAccum.lastEventPids and
         pid notin monitor.intervalAccum.cpuByPid and
         pid notin monitor.intervalAccum.memByPid:
        continue

      let cpuNs = monitor.intervalAccum.cpuByPid.getOrDefault(pid, 0)
      # Convert CPU nanoseconds to a percentage relative to the 500ms interval.
      # 500ms = 500_000_000 ns.  cpuPercent = (cpuNs / 500_000_000) * 100
      let cpuPercent = if cpuNs > 0: (cpuNs.float / 500_000_000.0) * 100.0 else: 0.0

      monitor.pendingMetrics.add(ProcessMetricsEvent(
        pid: pid,
        timestamp: timestamp,
        cpuPercent: cpuPercent,
        memoryBytes: monitor.intervalAccum.memByPid.getOrDefault(pid, 0),
        diskReadBytes: monitor.intervalAccum.diskReadByPid.getOrDefault(pid, 0),
        diskWriteBytes: monitor.intervalAccum.diskWriteByPid.getOrDefault(pid, 0),
        netSendBytes: monitor.intervalAccum.netSendByPid.getOrDefault(pid, 0),
        netRecvBytes: monitor.intervalAccum.netRecvByPid.getOrDefault(pid, 0),
      ))

    # Reset accumulators for the next interval.
    monitor.intervalAccum.cpuByPid.clear()
    monitor.intervalAccum.memByPid.clear()
    monitor.intervalAccum.netRecvByPid.clear()
    monitor.intervalAccum.netSendByPid.clear()
    monitor.intervalAccum.diskReadByPid.clear()
    monitor.intervalAccum.diskWriteByPid.clear()
    monitor.intervalAccum.lastEventPids.clear()
    return

  # Non-END sub-events: merge the value into the accumulator.
  let pid = parseInt(splits[2])
  let value = parseBiggestInt(splits[3])

  case subType
  of "CPU":
    monitor.intervalAccum.cpuByPid[pid] = value
  of "MEM":
    monitor.intervalAccum.memByPid[pid] = value
  of "NETR":
    monitor.intervalAccum.netRecvByPid[pid] = value
  of "NETW":
    monitor.intervalAccum.netSendByPid[pid] = value
  of "DSKR":
    monitor.intervalAccum.diskReadByPid[pid] = value
  of "DSKW":
    monitor.intervalAccum.diskWriteByPid[pid] = value
  of "LE":
    monitor.intervalAccum.lastEventPids[pid] = true
  else:
    discard

proc parseBpfLine*(monitor: var BPFMonitor, line: string) =
  ## Parses a single JSON line from bpftrace's ``-f json`` output.
  ## Dispatches to the appropriate event parser based on the data prefix.
  ##
  ## Expected format: ``{"type": "printf", "data": "EVENT;..."}``
  if not line.startsWith("{\"type\":") and not line.startsWith("{\"type\": "):
    return

  var dataStr: string
  try:
    let node = parseJson(line)
    if node{"type"}.getStr("") != "printf":
      return
    dataStr = node{"data"}.getStr("")
  except JsonParsingError:
    return

  if dataStr.len == 0:
    return

  let splits = dataStr.split(';')
  if splits.len < 2:
    return

  let eventName = splits[0]
  case eventName
  of "EXEC":
    parseExecEvent(monitor, splits)
  of "EXIT":
    parseExitEvent(monitor, splits)
  of "INTV":
    parseIntervalEvent(monitor, splits)
  else:
    # WRITE, READ events are not needed for process monitoring;
    # they are handled by the EventSourcing service for log capture.
    discard

# ---------------------------------------------------------------------------
# Polling and flushing
# ---------------------------------------------------------------------------

proc pollEvents*(monitor: var BPFMonitor) =
  ## Reads all available JSON lines from the bpftrace stdout stream.
  ## Non-blocking: returns immediately when no more data is available
  ## (the pipe FD was set to O_NONBLOCK in ``startMonitor``).
  ## Parsed events are accumulated in the ``pending*`` buffers.
  if not monitor.running:
    return

  when defined(posix):
    # Read raw bytes from the non-blocking pipe and split into lines.
    # Any partial trailing line is kept in ``readBuf`` for the next call.
    var buf: array[4096, char]
    while true:
      let n = posix.read(monitor.pipeFd, addr buf[0], buf.len)
      if n > 0:
        for i in 0 ..< n:
          if buf[i] == '\n':
            if monitor.readBuf.len > 0:
              try:
                parseBpfLine(monitor, monitor.readBuf)
              except CatchableError as e:
                echo fmt"Warning: failed to parse bpftrace line: {e.msg}"
              monitor.readBuf.setLen(0)
          else:
            monitor.readBuf.add(buf[i])
      elif n == 0:
        # EOF -- pipe closed (bpftrace exited).
        # Process any remaining partial line.
        if monitor.readBuf.len > 0:
          try:
            parseBpfLine(monitor, monitor.readBuf)
          except CatchableError:
            discard
          monitor.readBuf.setLen(0)
        monitor.running = false
        break
      else:
        # n < 0: check errno
        let err = errno
        if err == EAGAIN or err == EWOULDBLOCK:
          # No data available right now -- return without blocking.
          break
        else:
          # Unexpected error -- treat as pipe closed.
          monitor.running = false
          break
  else:
    # Windows: bpftrace is not available. `startMonitor` would have failed
    # earlier in `findBpftrace`/the spawn step, but we keep the no-op so
    # the surrounding ci_commands code can call `pollEvents` unconditionally.
    monitor.running = false

proc hasPendingEvents*(monitor: BPFMonitor): bool =
  ## Returns true if there are any buffered events waiting to be flushed.
  monitor.pendingStarts.len > 0 or
    monitor.pendingExits.len > 0 or
    monitor.pendingMetrics.len > 0 or
    monitor.pendingEnvs.len > 0

proc flushEvents*(monitor: var BPFMonitor, client: ApiClient, token: string,
                  runId: string) =
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

  monitor.pendingStarts.setLen(0)
  monitor.pendingExits.setLen(0)
  monitor.pendingMetrics.setLen(0)
  monitor.pendingEnvs.setLen(0)

proc stopMonitor*(monitor: var BPFMonitor) =
  ## Terminates the bpftrace subprocess and drains any remaining output.
  ##
  ## Sends SIGTERM first, waits briefly, then SIGKILL if still running.
  ## Does NOT flush events -- the caller should flush after stopping.
  if not monitor.running:
    return

  when defined(posix):
    let pid = processID(monitor.process)
    # bpftrace runs under sudo, so we need to kill via sudo as well.
    try:
      discard posix.kill(pid.cint, SIGTERM)
    except CatchableError:
      discard

    # Give bpftrace a short grace period to flush its output.
    sleep(500)

    if running(monitor.process):
      try:
        discard posix.kill(pid.cint, SIGKILL)
      except CatchableError:
        discard

    # Switch the pipe back to blocking mode so we can drain all remaining
    # output before the process exits.
    let flags = fcntl(monitor.pipeFd, F_GETFL)
    discard fcntl(monitor.pipeFd, F_SETFL, flags and (not O_NONBLOCK))
  else:
    # Windows: posix.kill / SIGTERM / SIGKILL / fcntl are unavailable.
    # `std/osproc.terminate` routes to TerminateProcess on Windows, which
    # is the only force-kill primitive available. There is no equivalent
    # of the SIGTERM grace period.
    try:
      terminate(monitor.process)
    except CatchableError:
      discard

  # Drain remaining output using the blocking stream.
  try:
    let stream = outputStream(monitor.process)
    while not stream.atEnd():
      var line: string
      if not stream.readLine(line):
        break
      if line.len > 0:
        try:
          parseBpfLine(monitor, line)
        except CatchableError:
          discard
  except CatchableError:
    discard

  discard waitForExit(monitor.process)
  close(monitor.process)
  monitor.running = false
