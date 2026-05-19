## CI command implementations for ``ct ci``.
##
## Each public proc corresponds to one CI subcommand. They orchestrate
## API calls (via ``ci_api_client``), local state management (via
## ``ci_state``), and child-process execution with log streaming.

import std/[options, os, osproc, posix, streams,
            strformat, strutils, times]
import ../online_sharing/[api_client, remote_config]
import ci_state, ci_api_client, bpf_monitor
when defined(linux):
  import bpf_monitor_native

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

const
  LogFlushIntervalMs = 500
  LogFlushMaxLines = 100
  CancelPollIntervalMs = 10_000
  TermGracePeriodMs = 5_000

proc resolveToken*(cliToken: Option[string]): string =
  ## Resolves the CI token from (in priority order):
  ## 1. CLI ``--token`` flag
  ## 2. ``CODETRACER_TOKEN`` environment variable
  ## 3. Stored bearer token from ``remote.config``
  ##
  ## Raises ``ValueError`` if no token can be found.
  if cliToken.isSome and cliToken.get.len > 0:
    return cliToken.get
  let envToken = getEnv("CODETRACER_TOKEN", "")
  if envToken.len > 0:
    return envToken
  # Fall back to the stored bearer token from login.
  let rc = initRemoteConfig()
  let stored = rc.readConfigValue(BearerTokenKey)
  if stored.len > 0:
    return stored
  raise newException(ValueError,
    "No CI token found. Set CODETRACER_TOKEN or pass --token, or login with 'ct login'.")

proc resolveBaseUrl*(cliBaseUrl: Option[string]): string =
  ## Resolves the base URL from the CLI flag, env var, config, or default.
  let rc = initRemoteConfig()
  rc.resolveBaseRemoteUrl(cliBaseUrl.get(""))

proc detectGitInfo(dir: string): tuple[repo, commit, branch: string] =
  ## Auto-detects git repository URL, HEAD commit SHA, and branch name
  ## from the current working directory. Returns empty strings on failure.
  let gitExe = findExe("git")
  if gitExe.len == 0:
    return ("", "", "")

  proc runGit(args: seq[string]): string =
    try:
      let cmd = startProcess(gitExe, args = args, workingDir = dir,
                             options = {poStdErrToStdOut})
      let output = cmd.outputStream.readAll().strip()
      let exitCode = waitForExit(cmd)
      if exitCode == 0:
        return output
    except CatchableError:
      discard
    return ""

  result.repo = runGit(@["remote", "get-url", "origin"])
  result.commit = runGit(@["rev-parse", "HEAD"])
  result.branch = runGit(@["rev-parse", "--abbrev-ref", "HEAD"])

proc isoTimestamp(): string =
  ## Returns the current UTC time in ISO 8601 format for log timestamps.
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc inferStatus(exitCode: int): string =
  ## Maps a child process exit code to a CI run status string.
  if exitCode == 0: "passed" else: "failed"

# ---------------------------------------------------------------------------
# Command: start
# ---------------------------------------------------------------------------

proc ciStartCommand*(token, baseUrl: string,
                     repo, commit, branch, baseCommit,
                     label: Option[string],
                     monitorProcesses: bool) =
  ## Creates a new CI run via the API and writes the state file.
  ## Auto-detects repo/commit/branch from the local git repo if not specified.
  if hasActiveRun():
    echo "Warning: overwriting existing active CI run."
    clearState()

  let git = detectGitInfo(getCurrentDir())
  let req = CreateRunRequest(
    repositoryUrl: repo.get(git.repo),
    commitSha: commit.get(git.commit),
    branchName: branch.get(git.branch),
    baseCommitSha: baseCommit.get(""),
    label: label.get(""),
    processMonitoring: monitorProcesses,
  )

  var client = initApiClient(baseUrl)
  defer: client.close()

  let resp = createRun(client, token, req)
  startRun(client, token, resp.id)

  let state = CIRunState(
    runId: resp.id,
    tenantId: resp.tenantId,
    baseUrl: baseUrl,
    token: token,
    sequenceCounter: 0,
  )
  saveState(state)
  echo fmt"CI run created: {resp.id}"

# ---------------------------------------------------------------------------
# Command: attach
# ---------------------------------------------------------------------------

proc ciAttachCommand*(token, baseUrl: string, runId: string) =
  ## Validates the run exists on the server, transitions it to Running,
  ## and writes the local state file.
  if hasActiveRun():
    echo "Warning: overwriting existing active CI run."
    clearState()

  var client = initApiClient(baseUrl)
  defer: client.close()

  # Validate the run exists by fetching its status.
  let status = getRunStatus(client, token, runId)
  echo fmt"Attaching to run {runId} (current status: {status.status})"

  # Transition to Running if it's not already.
  if status.status != "Running":
    startRun(client, token, runId)

  let state = CIRunState(
    runId: runId,
    tenantId: "",  # Not returned by getRunStatus; not needed for subsequent calls.
    baseUrl: baseUrl,
    token: token,
    sequenceCounter: 0,
  )
  saveState(state)
  echo fmt"Attached to CI run: {runId}"

# ---------------------------------------------------------------------------
# Command: exec
# ---------------------------------------------------------------------------

proc ciExecCommand*(token, baseUrl: string, program: string,
                    args: seq[string], record: bool,
                    monitorProcesses: bool = false): int =
  ## Spawns a child process, captures stdout/stderr, and streams log lines
  ## to the CI backend. Returns the child's exit code.
  ##
  ## - Buffers lines and flushes every 500ms or 100 lines.
  ## - Polls for cancellation every 10 seconds.
  ## - On cancellation: SIGTERM, wait 5s, then SIGKILL.
  ## - The ``record`` flag is reserved for future ``ct record`` wrapping.
  ## - When ``monitorProcesses`` is true, spawns bpftrace to capture the
  ##   child's process tree and streams events to the backend.
  var state = loadState()
  var client = initApiClient(baseUrl)
  defer: client.close()

  # Spawn the child process.
  let actualProgram = if record: "ct" else: program
  let actualArgs = if record: @["record", program] & args else: args

  let process = startProcess(actualProgram, args = actualArgs,
                             options = {poUsePath, poStdErrToStdOut})
  let pid = processID(process)
  let startTime = epochTime()

  # -- BPF process monitoring setup ----------------------------------------
  # Two backends are available: native libbpf (preferred, no subprocess) and
  # bpftrace (legacy subprocess fallback). The native backend requires
  # CAP_BPF capabilities on the ct binary and a compiled monitor.bpf.o file.
  var bpfMon: BPFMonitor
  when defined(linux):
    var nativeMon: NativeBPFMonitor
  var bpfActive = false
  var useNativeBpf = false

  if monitorProcesses:
    # Try the native libbpf backend first (Linux only).
    when defined(linux):
      let objPath = defaultBpfObjectPath()
      if objPath.len > 0:
        let nativeCap = detectNativeBPFCapability(objPath)
        if nativeCap == nbpfAvailable:
          try:
            nativeMon = startNativeMonitor(pid, objPath)
            useNativeBpf = true
            bpfActive = true
            echo fmt"Native BPF process monitor started (root PID: {pid})"
          except OSError as e:
            echo fmt"Warning: native BPF failed: {e.msg}. Trying bpftrace fallback..."

    # Fall back to the bpftrace subprocess backend.
    if not bpfActive:
      let cap = detectBPFCapability()
      case cap
      of bpfAvailable:
        let scriptPath = findBPFTraceScript()
        if scriptPath.len == 0:
          echo "Warning: bpftrace-collection.bt script not found. Process monitoring disabled."
        else:
          try:
            bpfMon = startMonitor(pid, scriptPath)
            bpfActive = true
            echo fmt"BPF process monitor started via bpftrace (root PID: {pid})"
          except OSError as e:
            echo fmt"Warning: failed to start bpftrace: {e.msg}. Process monitoring disabled."
          except CatchableError as e:
            echo fmt"Warning: failed to start bpftrace: {e.msg}. Process monitoring disabled."
      of bpfNoBinary:
        echo "Warning: bpftrace not found in PATH. Process monitoring disabled."
      of bpfNoPermission:
        echo "Warning: passwordless sudo for bpftrace unavailable. Process monitoring disabled."
      of bpfUnsupported:
        echo "Warning: BPF not supported on this system. Process monitoring disabled."

  var lastBpfPollTime = epochTime()

  var buffer: seq[LogLine] = @[]
  var lastFlushTime = epochTime()
  var lastCancelCheckTime = epochTime()
  var cancelled = false

  proc flushBuffer(isFinal: bool) =
    if buffer.len == 0 and not isFinal:
      return
    state.sequenceCounter += 1
    try:
      appendLogs(client, token, state.runId, buffer, state.sequenceCounter,
                 isFinal)
    except CIApiError as e:
      # Log the error but don't abort -- best effort streaming.
      echo fmt"Warning: failed to stream logs (seq {state.sequenceCounter}): {e.msg}"
    buffer.setLen(0)
    lastFlushTime = epochTime()
    # Persist sequence counter so recovery is possible.
    saveState(state)

  proc checkCancellation() =
    ## Polls the server to see if the run has been cancelled.
    try:
      let runStatus = getRunStatus(client, token, state.runId)
      if runStatus.status == "Cancelled":
        cancelled = true
    except CIApiError:
      # Ignore poll failures -- we'll retry next interval.
      discard
    lastCancelCheckTime = epochTime()

  proc pollAndFlushBpf() =
    ## Polls the active BPF backend for new events and flushes them.
    if not bpfActive:
      return
    if useNativeBpf:
      when defined(linux):
        pollNativeEvents(nativeMon)
        if hasPendingEvents(nativeMon):
          flushEvents(nativeMon, client, token, state.runId)
    else:
      pollEvents(bpfMon)
      if hasPendingEvents(bpfMon):
        flushEvents(bpfMon, client, token, state.runId)
    lastBpfPollTime = epochTime()

  # Read child output line by line.
  let outputStream = outputStream(process)
  while true:
    # Check if it's time to poll for cancellation.
    if epochTime() - lastCancelCheckTime >= (CancelPollIntervalMs.float / 1000.0):
      checkCancellation()
      if cancelled:
        # Send SIGTERM, wait, then SIGKILL.
        echo "Run cancelled by server. Terminating child process..."
        when defined(posix):
          discard posix.kill(pid.cint, SIGTERM)
          sleep(TermGracePeriodMs)
          if running(process):
            discard posix.kill(pid.cint, SIGKILL)
        else:
          # Windows: posix.kill / SIGKILL are not available. Use std/osproc
          # which routes to TerminateProcess on Windows. There is no
          # equivalent of the SIGTERM grace period — TerminateProcess is
          # the only force-kill primitive available.
          terminate(process)
        break

    if outputStream.atEnd():
      break

    var line: string
    try:
      # readLine returns false at EOF.
      if not outputStream.readLine(line):
        break
    except IOError:
      break

    # Echo locally so the user sees output in real time.
    echo line

    buffer.add(LogLine(
      timestamp: isoTimestamp(),
      stream: "stdout",
      text: line,
    ))

    # Flush if buffer is full or timeout elapsed.
    let now = epochTime()
    if buffer.len >= LogFlushMaxLines or
       (now - lastFlushTime) >= (LogFlushIntervalMs.float / 1000.0):
      flushBuffer(isFinal = false)

    # Poll BPF events approximately every second alongside log flushes.
    if bpfActive and (now - lastBpfPollTime) >= 1.0:
      pollAndFlushBpf()

  # Wait for the child to exit.
  let exitCode = waitForExit(process)
  close(process)
  let durationSeconds = epochTime() - startTime

  # Final flush with remaining lines.
  flushBuffer(isFinal = true)

  # -- BPF cleanup ---------------------------------------------------------
  if bpfActive:
    if useNativeBpf:
      when defined(linux):
        stopNativeMonitor(nativeMon)
        if hasPendingEvents(nativeMon):
          flushEvents(nativeMon, client, token, state.runId)
    else:
      stopMonitor(bpfMon)
      if hasPendingEvents(bpfMon):
        flushEvents(bpfMon, client, token, state.runId)
    echo "BPF process monitor stopped."

  if cancelled:
    echo "Child process terminated due to cancellation."
  else:
    echo fmt"Command exited with code {exitCode} in {durationSeconds:.1f}s"

  return exitCode

# ---------------------------------------------------------------------------
# Command: finish
# ---------------------------------------------------------------------------

proc ciFinishCommand*(token, baseUrl: string,
                      statusOverride: Option[string],
                      exitCode: int = 0,
                      durationSeconds: float = 0.0) =
  ## Completes the current CI run and clears the state file.
  ## Uses the provided status override, or infers from the exit code.
  let state = loadState()
  var client = initApiClient(baseUrl)
  defer: client.close()

  let status = if statusOverride.isSome and statusOverride.get.len > 0:
      statusOverride.get
    else:
      inferStatus(exitCode)

  completeRun(client, token, state.runId, status, exitCode, durationSeconds)
  clearState()
  echo fmt"CI run {state.runId} completed with status: {status}"

# ---------------------------------------------------------------------------
# Command: run (all-in-one)
# ---------------------------------------------------------------------------

proc ciRunCommand*(token, baseUrl: string,
                   repo, commit, branch, baseCommit,
                   label: Option[string],
                   monitorProcesses: bool,
                   record: bool,
                   program: string, args: seq[string]) =
  ## All-in-one command: start + exec + finish.
  ## On exec failure, still calls finish with the appropriate error status.
  let startTime = epochTime()

  # Start the run.
  ciStartCommand(token, baseUrl, repo, commit, branch, baseCommit, label,
                 monitorProcesses)

  # Execute the command.
  var exitCode = 1
  try:
    exitCode = ciExecCommand(token, baseUrl, program, args, record,
                             monitorProcesses)
  except CatchableError as e:
    echo fmt"Error during exec: {e.msg}"
    exitCode = 1

  # Finish the run.
  let durationSeconds = epochTime() - startTime
  try:
    ciFinishCommand(token, baseUrl, none(string), exitCode, durationSeconds)
  except CatchableError as e:
    echo fmt"Error finishing run: {e.msg}"

  if exitCode != 0:
    quit(exitCode)

# ---------------------------------------------------------------------------
# Command: log
# ---------------------------------------------------------------------------

proc ciLogCommand*(token, baseUrl: string, message: string) =
  ## Appends a single manual log line to the active CI run.
  var state = loadState()
  var client = initApiClient(baseUrl)
  defer: client.close()

  state.sequenceCounter += 1
  let lines = @[LogLine(
    timestamp: isoTimestamp(),
    stream: "manual",
    text: message,
  )]
  appendLogs(client, token, state.runId, lines, state.sequenceCounter,
             isFinal = false)
  saveState(state)
  echo "Log line appended."

# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------

proc ciStatusCommand*(token, baseUrl: string) =
  ## Prints the current run status from both local state and the server.
  var client = initApiClient(baseUrl)
  defer: client.close()

  if hasActiveRun():
    let state = loadState()
    echo fmt"Local state: run {state.runId} (seq: {state.sequenceCounter})"
    try:
      let status = getRunStatus(client, token, state.runId)
      echo fmt"Server status: {status.status}"
      if status.label.len > 0:
        echo fmt"Label: {status.label}"
      if status.repositoryUrl.len > 0:
        echo fmt"Repository: {status.repositoryUrl}"
      if status.commitSha.len > 0:
        echo fmt"Commit: {status.commitSha}"
      if status.branchName.len > 0:
        echo fmt"Branch: {status.branchName}"
    except CIApiError as e:
      echo fmt"Failed to fetch server status: {e.msg}"
  else:
    echo "No active CI run."

# ---------------------------------------------------------------------------
# Command: cancel
# ---------------------------------------------------------------------------

proc ciCancelCommand*(token, baseUrl: string) =
  ## Requests cancellation of the active CI run via the API.
  let state = loadState()
  var client = initApiClient(baseUrl)
  defer: client.close()

  cancelRun(client, token, state.runId)
  echo fmt"Cancellation requested for run {state.runId}."
  # Note: we do NOT clear state here. The exec loop will detect
  # the Cancelled status and terminate the child process.
