## Launching a target UNDER hot code reload, from CodeTracer.
##
## Milestone: `codetracer-specs/Marketing/Home-Demo-Screencast.milestones.org`,
## H6. Authority for the behaviour: `Marketing/The-Flame-Demo-Spec.md` §2.5,
## "How the flame client is started — the launch model".
##
## WHY THIS MODULE EXISTS, and why it is not a convenience wrapper around the
## apply-edit command. The HCR transport must exist while the target is being
## launched, but its ownership differs by platform:
##
##   1. On Linux the agent dials out once, at process start, so the coordinator
##      must already be listening: coordinator first, target second.
##   2. On Windows the agent is the named-pipe server and its endpoint contains
##      the target PID: target first, coordinator second. The target loads the
##      canonical agent DLL from `REPRO_HCR_AGENT_DLL` during startup.
##   3. **Attaching to an already-running target is out of scope** (§2.5). This
##      path owns both process creation and the complete HCR session lifetime.
##
## Until this module existed the SHELL HARNESS played the launcher's part: H5's
## gate started `hcr_patch_driver --session` itself, started the engine with
## `REPRO_HCR_AGENT_SOCKET` pointing at it, waited for the session's `ready`
## file and only then let the product publish edits into a session somebody else
## had opened. The product consumed a session; it could not create one.
##
## WHAT IT DOES NOT DECIDE. Exactly as with `ipc_utils.onHcrApplyEdit`, nothing
## here forms an opinion about an EDIT. This module owns the session's
## lifetime — transport established, target and coordinator connected, ready,
## torn down — and the apply-edit command owns everything about what an edit
## means.
##
## EVERY FAILURE IS NAMED AND BOUNDED. Configuration, process startup,
## transport negotiation and target-lifetime failures each have their own
## status string and sentence; every wait has a deadline. A hot-reload tool
## whose target silently failed to start is indistinguishable, from the screen,
## from one that started it and changed nothing — the same confusion
## `onHcrApplyEdit` is written to avoid, one layer further out.
##
## PLATFORM. Both production transports are implemented here. The launch record
## names which one was used and the order it requires, so a gate can assert the
## platform's real process topology instead of treating one platform's order as
## universal.

import
  std / [ async, jsffi, os ],
  electron_vars, config, launch_config,
  ../lib/[ jslib ],
  ../../common/[ ct_logging, paths ]

# ---------------------------------------------------------------------------
# Node bindings.
#
# Deliberately small and explicit rather than a typed `fs`/`child_process`
# facade: every one of these is used in a place where the FAILURE is the
# interesting case, and a binding that swallows it into `undefined` would be
# the wrong shape here.
# ---------------------------------------------------------------------------

var jsProcess {.importc: "process", nodecl.}: JsObject
var jsDate {.importc: "Date", nodecl.}: JsObject
  ## Bound as VARIABLES rather than as zero-argument `importjs` routines:
  ## `importjs` on a routine requires a pattern, and `process.pid` has no
  ## argument to place one in.

proc nodePid(): int = cast[int](jsProcess.pid)
proc nowMs(): float = cast[float](jsDate.now())
proc fsExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc fsMkdirp(path: cstring) {.importjs:
  "require('fs').mkdirSync(#, {recursive: true})".}
proc fsRmTree(path: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}
proc fsWriteText(path: cstring, content: cstring) {.importjs:
  "require('fs').writeFileSync(#, #)".}
proc fsOpenAppend(path: cstring): int {.importjs:
  "require('fs').openSync(#, 'a')".}
proc fsCloseQuietly(fd: int) {.importjs:
  "(function(f){ try { require('fs').closeSync(f); } catch (e) {} })(#)".}
proc fsTail(path: cstring, limit: int): cstring {.importjs: """
  ((function(p, n){
    try { var s = require('fs').readFileSync(p, 'utf8'); return s.slice(-n); }
    catch (e) { return ''; }
  })(#, #))
""".}
  ## The last `n` characters of a log, or `""`. Used only to put a target's own
  ## last words into the message the user reads, which is the difference between
  ## "the program you launched exited immediately" and a sentence they can act
  ## on.

proc jsonText(value: JsObject): cstring {.importjs: "JSON.stringify(#, null, 2)".}
proc newJsArray: JsObject {.importjs: "([])".}
proc pushJs(arr: JsObject, value: cstring) {.importjs: "#.push(#)".}
proc envCopy(source: JsObject): JsObject {.importjs: "Object.assign({}, #)".}
proc envSet(env: JsObject, key: cstring, value: cstring) {.importjs:
  "(#[#] = #)".}
proc envDelete(env: JsObject, key: cstring) {.importjs: "(delete #[#])".}
proc spawnChild(command: cstring, args: JsObject, options: JsObject): JsObject {.
  importjs: "require('child_process').spawn(#, #, #)".}
proc childPid(child: JsObject): int {.importjs: "(#.pid || 0)".}
proc childHasExited(child: JsObject): bool {.importjs: "(#.exitCode !== null)".}
proc childExitCode(child: JsObject): int {.importjs: """
  ((function(c){
    return (c.exitCode === null || c.exitCode === undefined) ? -1 : c.exitCode;
  })(#))
""".}
proc onChildExit(child: JsObject, callback: proc(code: JsObject, signal: JsObject)) {.
  importjs: "#.on('exit', #)".}
proc onChildError(child: JsObject, callback: proc(error: JsObject)) {.
  importjs: "#.on('error', #)".}
proc killChild(child: JsObject) {.importjs: """
  (function(c){ try { if (c.exitCode === null) { c.kill('SIGTERM'); } } catch (e) {} })(#)
""".}
proc errorText(error: JsObject): cstring {.importjs: """
  ((function(e){ return (e && e.message) ? String(e.message) : String(e); })(#))
""".}
proc processPlatform(): cstring = cast[cstring](jsProcess.platform)

# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

type
  HcrSessionPhase* = enum
    ## Where a launch is. The names are written into the launch record and are
    ## the vocabulary the UI shows, so they are not free to drift.
    hcrIdle = "idle"
    hcrCoordinatorStarting = "coordinator-starting"
    hcrCoordinatorListening = "coordinator-listening"
    hcrTargetLaunching = "target-launching"
    hcrWaitingForAgent = "waiting-for-agent"
    hcrReady = "ready"
    hcrFailed = "failed"
    hcrTargetExited = "target-exited"

  HcrSession = ref object
    ## The one live launch. There is deliberately at most ONE: a second session
    ## would be a second coordinator, and the product would have no way to say
    ## which of them owns a given edit.
    phase: HcrSessionPhase
    configName: string
    configSource: string
    program: string
    programArgs: seq[cstring]
    sessionDir: string
    socketPath: string
    platform: string
    transport: string
    startupOrder: string
    applyEditCommand: string
    applyEditInterpreter: string
    coordinator: JsObject
    target: JsObject
    coordinatorPid: int
    targetPid: int
    coordinatorStartedAtMs: float
    coordinatorListeningAtMs: float
    coordinatorConnectedAtMs: float
    targetStartedAtMs: float
    readyAtMs: float
    targetExitCode: int
    targetExited: bool
    coordinatorExited: bool
    targetSpawnError: string
    failureStatus: string
    failureMessage: string
    record: string
      ## Path of `hcr-launch.json`, the product's own account of this launch.

var activeSession: HcrSession = nil

const
  LaunchRecordName = "hcr-launch.json"
  DefaultCoordinatorListenTimeoutMs = 15_000
  DefaultReadyTimeoutMs = 60_000
  DefaultIdleTimeoutMs = 1_800_000
    ## How long the coordinator will hold an idle session open. Long, on
    ## purpose: the session is a person typing, and a coordinator that gave up
    ## after two minutes of thought would take the target's only agent
    ## connection with it.
  DefaultAgentSocketEnv = "REPRO_HCR_AGENT_SOCKET"
  PollIntervalMs = 50
  CoordinatorShutdownTimeoutMs = 20_000

proc activeHcrSessionDir*(): cstring =
  ## The session dir of a READY session opened by this process, or `""`.
  ##
  ## Only `hcrReady` answers. A session that is still starting has no
  ## negotiated connection, and one that has failed or whose target has exited
  ## has no connection at all — publishing into either would produce a refusal
  ## about protocol state in place of the real reason.
  if activeSession.isNil or activeSession.phase != hcrReady:
    cstring""
  else:
    cstring(activeSession.sessionDir)

proc activeHcrApplyEditCommand*(): cstring =
  ## The apply-edit command the LAUNCH CONFIGURATION named, or `""`.
  if activeSession.isNil or activeSession.phase != hcrReady:
    cstring""
  else:
    cstring(activeSession.applyEditCommand)

proc activeHcrApplyEditInterpreter*(): cstring =
  if activeSession.isNil or activeSession.phase != hcrReady:
    cstring""
  else:
    cstring(activeSession.applyEditInterpreter)

proc sendSessionStatus(phase: HcrSessionPhase, status: cstring, message: cstring,
                       remedy: cstring = cstring"") =
  ## Tell the renderer where the session is.
  ##
  ## `status` is the NAMED outcome and is shown verbatim in the live-edit
  ## panel's status line, beside the apply-edit command's own names. The panel
  ## is the persistent surface — notifications auto-dismiss, which is
  ## `Verification-Harness-Traps.md` §21 — so a launch that failed while the
  ## user was looking elsewhere is still readable afterwards.
  if mainWindow.isNil:
    return
  mainWindow.webContents.send "CODETRACER::hcr-session-status", js{
    phase: cstring($phase),
    status: status,
    message: message,
    remedy: remedy}

proc writeLaunchRecord(session: HcrSession) =
  ## Write (or rewrite) `hcr-launch.json`.
  ##
  ## THIS FILE IS THE PRODUCT'S CLAIM THAT IT DID THE LAUNCHING, and it exists
  ## because "a flame is running and edits reach it" is satisfied equally well
  ## by a flame somebody else started. It records the launcher's OWN pid, the
  ## two child pids, and the two timestamps that pin the ordering the wire
  ## requires. A gate can then check the target's parent against `launcherPid`
  ## and refuse a run in which a harness played the launcher's part.
  ##
  ## Rewritten at every phase transition rather than once at the end: a launch
  ## that failed is exactly the case where the file must exist, and a record
  ## written only on success would be absent in every interesting run.
  if session.record.len == 0:
    return
  let args = newJsArray()
  for arg in session.programArgs:
    pushJs(args, arg)
  let record = js{
    schemaId: cstring"codetracer.hcr.launch-record.v1",
    launchedBy: cstring"codetracer",
    launcherPid: nodePid(),
    phase: cstring($session.phase),
    configName: cstring(session.configName),
    configSource: cstring(session.configSource),
    program: cstring(session.program),
    platform: cstring(session.platform),
    transport: cstring(session.transport),
    startupOrder: cstring(session.startupOrder),
    sessionDir: cstring(session.sessionDir),
    socket: cstring(session.socketPath),
    applyEditCommand: cstring(session.applyEditCommand),
    coordinatorPid: session.coordinatorPid,
    coordinatorStartedAtMs: session.coordinatorStartedAtMs,
    coordinatorListeningAtMs: session.coordinatorListeningAtMs,
    coordinatorConnectedAtMs: session.coordinatorConnectedAtMs,
    targetPid: session.targetPid,
    targetStartedAtMs: session.targetStartedAtMs,
    targetExited: session.targetExited,
    targetExitCode: session.targetExitCode,
    readyAtMs: session.readyAtMs,
    failureStatus: cstring(session.failureStatus),
    failureMessage: cstring(session.failureMessage),
    args: args}
  try:
    fsWriteText(cstring(session.record), jsonText(record))
  except:
    errorPrint "hcr_launch: could not write the launch record: ",
      getCurrentExceptionMsg()

proc fail(session: HcrSession, status: string, message: string,
          remedy: string = "") =
  ## Record and surface a named launch failure, and stop.
  session.phase = hcrFailed
  session.failureStatus = status
  session.failureMessage = message
  writeLaunchRecord(session)
  errorPrint "hcr_launch: ", status, ": ", message
  sendSessionStatus(hcrFailed, cstring(status), cstring(message), cstring(remedy))

proc shutDownSession(session: HcrSession) {.async.} =
  ## Close the coordinator and let go of the session.
  ##
  ## `stop` first, then a bounded wait, then `SIGTERM`. The file is how the
  ## driver ends a session CLEANLY — it writes `session.json`, the summary a
  ## gate reads to learn how many patches went down the connection — and a
  ## coordinator killed before it writes that file has destroyed the evidence
  ## of its own session.
  if session.isNil or session.coordinator.isNil:
    return
  if not session.coordinatorExited:
    try:
      fsWriteText(cstring(session.sessionDir / "stop"), cstring"")
    except:
      discard
    let deadline = nowMs() + float(CoordinatorShutdownTimeoutMs)
    while not session.coordinatorExited and nowMs() < deadline:
      if childHasExited(session.coordinator):
        session.coordinatorExited = true
        break
      await wait(PollIntervalMs)
    if not session.coordinatorExited:
      infoPrint "hcr_launch: the coordinator did not exit after `stop`; terminating it"
      killChild(session.coordinator)

proc teardownAfterTargetExit(session: HcrSession) {.async.} =
  ## The target is gone; the session it owned is over.
  ##
  ## A session outliving its target is not merely untidy: the coordinator holds
  ## a transport endpoint with no target behind it, and the next edit typed into
  ## the panel would be published into it and answered — by a state machine talking
  ## to a closed connection — rather than refused. So the session dir is
  ## released here, which is what makes the next edit say "no session" instead.
  await shutDownSession(session)
  session.phase = hcrTargetExited
  writeLaunchRecord(session)
  if activeSession == session:
    activeSession = nil
  sendSessionStatus(hcrTargetExited, cstring"session-closed",
    cstring("the program you launched exited with code " &
      $session.targetExitCode & "; the live-edit session is closed. Launch it " &
      "again to edit it live."))

proc resolveHcrLaunchConfig(name: string, configs: seq[LaunchConfig],
                            platform: string):
    LaunchConfig =
  ## The configuration to launch: the one NAMED, or the first HCR-capable one.
  ##
  ## A named configuration that exists but carries no `hcr` block is NOT
  ## silently skipped in favour of another — the caller asked for that one, and
  ## answering with a different program would be the worst possible response to
  ## a typo.
  result = nil
  for config in configs:
    if name.len > 0:
      if $config.name == name:
        return config
    elif not config.hcr.isNil and
        (config.hcr.platform.len == 0 or $config.hcr.platform == platform):
      return config

proc launchUnderHcr(configName: string) {.async.} =
  ## Start the target and coordinator in the transport's required order, then
  ## open the live-edit session.
  ##
  ## The whole sequence is here, in order, because the ORDER is the feature.
  if not activeSession.isNil and activeSession.phase == hcrReady:
    sendSessionStatus(hcrReady, cstring"session-already-open",
      cstring("a live-edit session is already open against pid " &
        $activeSession.targetPid & " (" & activeSession.program &
        "); close that program before launching another."))
    return

  let platform = $processPlatform()
  if platform != "linux" and platform != "win32":
    sendSessionStatus(hcrFailed, cstring"hcr-launch-unsupported-platform",
      cstring("launching a target under hot code reload is implemented for " &
        "Linux and Windows; this host reports " & platform & "."))
    return

  # --- 1. the configuration ------------------------------------------------
  #
  # `data.workspaceFolder` first, and `data.startOptions.folder` as the
  # fallback. THE FALLBACK IS NOT BELT-AND-BRACES; it is load-bearing, and the
  # reason is a defect in the startup path that is worth recording rather than
  # papering over:
  #
  #   `index/startup.nim`'s `init` takes `dataArg: var ServerData` and
  #   immediately does `var data = dataArg`, with a comment asserting that "on
  #   the JS backend, ServerData is a reference type, so mutations propagate
  #   back". It is not a reference type — it is an `object` — and Nim's JS
  #   backend emits `nimCopy` for that assignment. So the edit branch's
  #   `data.workspaceFolder = folder` writes to a COPY, and the global stays
  #   `nil` for the whole session. Measured here on 2026-09-16: a
  #   `ct edit <folder>` launch reported `hcr-no-workspace-folder` with the
  #   folder plainly open on screen.
  #
  #   The mode-switch path (`index/traces.nim`'s `onInitEditMode`) assigns the
  #   global directly and is unaffected, which is why the same folder opened
  #   from the Welcome screen behaves differently from the same folder opened
  #   from the command line. `onRecordWithLaunchConfig` reads the same field and
  #   has the same hole.
  #
  # Fixing `init` is a one-line change with a wide blast radius — the field also
  # decides how `loadTrace` categorises the filesystem tree and what
  # `pathContentRootFor` resolves — so it is reported rather than made here, and
  # this module reads the start options, which are never copied.
  var workspaceFolder =
    if data.workspaceFolder.isNil: "" else: $data.workspaceFolder
  # Only in EDIT mode: outside it `startOptions.folder` is the process's cwd,
  # and reading a `.vscode/launch.json` that happens to be sitting in whatever
  # directory the application was started from is not "the project's launch
  # configuration" — it is a different project's.
  if workspaceFolder.len == 0 and data.startOptions.edit and
      not data.startOptions.folder.isNil:
    workspaceFolder = $data.startOptions.folder
  if workspaceFolder.len == 0:
    sendSessionStatus(hcrFailed, cstring"hcr-no-workspace-folder",
      cstring("no project folder is open, so there is no .vscode/launch.json " &
        "to read the HCR launch configuration from. Open the project folder " &
        "first (File > Open Folder)."))
    return
  let configSource = workspaceFolder / ".vscode" / "launch.json"
  let configs = getLaunchConfigsForWorkspace(cstring(workspaceFolder))
  let config = resolveHcrLaunchConfig(configName, configs, platform)
  if config.isNil:
    if configName.len > 0:
      sendSessionStatus(hcrFailed, cstring"hcr-launch-configuration-not-found",
        cstring("no launch configuration named `" & configName & "` exists in " &
          configSource & " (" & $configs.len & " launch configuration(s) read)."))
    else:
      sendSessionStatus(hcrFailed, cstring"hcr-no-launch-configuration",
        cstring("no launch configuration with an `hcr` block was found in " &
          configSource & " (" & $configs.len & " launch configuration(s) read). " &
          "Add an `hcr` object naming `coordinator` and `targetSymbol` to the " &
          "configuration that starts the program you want to edit live."))
    return
  if config.hcr.isNil:
    sendSessionStatus(hcrFailed, cstring"hcr-launch-configuration-not-hcr",
      cstring("the launch configuration `" & $config.name & "` in " &
        configSource & " has no `hcr` block, so it cannot be started under " &
        "hot code reload."))
    return

  let settings = config.hcr
  if settings.platform.len > 0 and $settings.platform != platform:
    sendSessionStatus(hcrFailed,
      cstring"hcr-launch-configuration-platform-mismatch",
      cstring("the launch configuration `" & $config.name & "` is for " &
        $settings.platform & ", but CodeTracer is running on " & platform & "."))
    return
  if settings.coordinator.len == 0 or settings.targetSymbol.len == 0:
    sendSessionStatus(hcrFailed, cstring"hcr-launch-configuration-incomplete",
      cstring("the `hcr` block of `" & $config.name & "` in " & configSource &
        " must name both `coordinator` (the HCR patch driver) and " &
        "`targetSymbol` (the function patches are published into)."))
    return
  if platform == "win32" and (settings.agentDll.len == 0 or
      settings.targetImage.len == 0 or settings.targetPdb.len == 0 or
      settings.firstInstructionLength <= 0):
    sendSessionStatus(hcrFailed, cstring"hcr-launch-configuration-incomplete",
      cstring("the Windows `hcr` block of `" & $config.name & "` in " &
        configSource & " must name `agentDll`, `targetImage`, `targetPdb` " &
        "and a positive `firstInstructionLength`."))
    return
  if not fsExists(settings.coordinator):
    sendSessionStatus(hcrFailed, cstring"hcr-coordinator-missing",
      cstring("the HCR coordinator named by `" & $config.name &
        "` does not exist: " & $settings.coordinator))
    return
  if not fsExists(config.program):
    sendSessionStatus(hcrFailed, cstring"hcr-target-program-missing",
      cstring("the program named by `" & $config.name & "` does not exist: " &
        $config.program))
    return
  if platform == "win32":
    for required in [
        (name: "agent DLL", path: settings.agentDll),
        (name: "target image", path: settings.targetImage),
        (name: "target PDB", path: settings.targetPdb)]:
      if not fsExists(required.path):
        sendSessionStatus(hcrFailed, cstring"hcr-windows-input-missing",
          cstring("the Windows HCR " & required.name & " named by `" &
            $config.name & "` does not exist: " & $required.path))
        return

  # --- 2. the session directory --------------------------------------------
  var sessionDir = $settings.sessionDir
  if sessionDir.len == 0:
    sessionDir = $codetracerTmpPath / "hcr-live-edit" / $nodePid()
  try:
    # A session dir carrying a PREVIOUS run's `ready` would be read as this
    # run's, and the launch would report a session that had never negotiated.
    fsRmTree(cstring(sessionDir))
    fsMkdirp(cstring(sessionDir))
  except:
    sendSessionStatus(hcrFailed, cstring"hcr-session-dir-unusable",
      cstring("could not prepare the live-edit session directory " &
        sessionDir & ": " & getCurrentExceptionMsg()))
    return

  # AF_UNIX paths are capped at 108 bytes IN THE KERNEL, and a socket named
  # after a deep project path crosses it with a failure that names neither the
  # cause nor the remedy. So Linux uses the system temp dir. Windows fills this
  # in after process creation because the named-pipe endpoint contains the PID.
  var socketPath =
    if platform == "linux": "/tmp/ct-hcr-" & $nodePid() & ".sock"
    else: ""
  let transport =
    if platform == "linux": "unix-dialout"
    else: "windows-pid-named-pipe"
  let startupOrder =
    if platform == "linux": "coordinator-first"
    else: "target-first"

  let session = HcrSession(
    phase: (if platform == "linux": hcrCoordinatorStarting
            else: hcrTargetLaunching),
    configName: $config.name,
    configSource: configSource,
    program: $config.program,
    programArgs: config.args,
    sessionDir: sessionDir,
    socketPath: socketPath,
    platform: platform,
    transport: transport,
    startupOrder: startupOrder,
    applyEditCommand: $settings.applyEditCommand,
    applyEditInterpreter: $settings.applyEditInterpreter,
    coordinatorPid: 0,
    targetPid: 0,
    targetExitCode: -1,
    record: sessionDir / LaunchRecordName)
  activeSession = session
  writeLaunchRecord(session)

  # --- 3. prepare both children --------------------------------------------
  let coordinatorLog = sessionDir / "coordinator.log"
  let targetLog = sessionDir / "target.log"
  let targetArgs = newJsArray()
  for arg in config.args:
    pushJs(targetArgs, arg)
  let targetEnv = envCopy(jsProcess.env)
  for pair in config.env:
    envSet(targetEnv, pair.key, pair.value)
  let socketEnvName =
    if settings.agentSocketEnv.len > 0: $settings.agentSocketEnv
    else: DefaultAgentSocketEnv
  if platform == "linux":
    envSet(targetEnv, cstring(socketEnvName), cstring(socketPath))
    envDelete(targetEnv, cstring"REPRO_HCR_AGENT_DLL")
  else:
    envSet(targetEnv, cstring"REPRO_HCR_AGENT_DLL", settings.agentDll)
    envDelete(targetEnv, cstring(socketEnvName))
  # The session dir the panel publishes into is this process's business, not
  # the target's; leaving an inherited one in the target's environment would be
  # a second, stale answer to a question only one of them should answer.
  envDelete(targetEnv, cstring"CODETRACER_HCR_SESSION_DIR")

  var coordinator: JsObject
  var target: JsObject
  var coordinatorFd = -1
  var targetFd = -1

  proc startCoordinator(coordinatorArgs: JsObject): bool =
    sendSessionStatus(hcrCoordinatorStarting, cstring"launching",
      cstring("starting the HCR coordinator for `" & $config.name & "`…"))
    session.phase = hcrCoordinatorStarting
    coordinatorFd = fsOpenAppend(cstring(coordinatorLog))
    session.coordinatorStartedAtMs = nowMs()
    try:
      coordinator = spawnChild(settings.coordinator, coordinatorArgs, js{
        cwd: config.cwd,
        stdio: @[cstring"ignore".toJs, coordinatorFd.toJs,
          coordinatorFd.toJs]})
    except:
      fsCloseQuietly(coordinatorFd)
      session.fail("hcr-coordinator-failed",
        "the HCR coordinator could not be started (" & $settings.coordinator &
          "): " & getCurrentExceptionMsg())
      return false
    session.coordinator = coordinator
    session.coordinatorPid = childPid(coordinator)
    onChildError(coordinator) do (error: JsObject):
      session.coordinatorExited = true
    onChildExit(coordinator) do (code: JsObject, signal: JsObject):
      session.coordinatorExited = true
    writeLaunchRecord(session)
    true

  proc startTarget(): bool =
    sendSessionStatus(hcrTargetLaunching, cstring"launching",
      cstring("starting " & $config.program & " with its HCR agent…"))
    session.phase = hcrTargetLaunching
    targetFd = fsOpenAppend(cstring(targetLog))
    session.targetStartedAtMs = nowMs()
    try:
      target = spawnChild(config.program, targetArgs, js{
        cwd: config.cwd,
        env: targetEnv,
        stdio: @[cstring"ignore".toJs, targetFd.toJs, targetFd.toJs]})
    except:
      fsCloseQuietly(targetFd)
      session.fail("hcr-target-launch-failed",
        "could not start " & $config.program & ": " & getCurrentExceptionMsg())
      return false
    session.target = target
    session.targetPid = childPid(target)
    onChildError(target) do (error: JsObject):
      session.targetSpawnError = $errorText(error)
      session.targetExited = true
    onChildExit(target) do (code: JsObject, signal: JsObject):
      session.targetExited = true
      session.targetExitCode = childExitCode(target)
      if session.phase == hcrReady:
        # The only path where the session is torn down by the TARGET rather
        # than by a failure: it ran, it was edited, it finished.
        discard teardownAfterTargetExit(session)
    writeLaunchRecord(session)
    true

  let coordinatorArgs = newJsArray()
  if platform == "linux":
    # Linux coordinator FIRST: the target's agent dials this socket once.
    pushJs(coordinatorArgs, cstring"--socket")
    pushJs(coordinatorArgs, cstring(socketPath))
  else:
    # Windows target FIRST: the target's agent owns a PID-keyed named pipe.
    if not startTarget():
      activeSession = nil
      return
    if session.targetPid <= 0:
      session.fail("hcr-target-launch-failed",
        "the Windows target started without publishing a process id")
      killChild(target)
      fsCloseQuietly(targetFd)
      activeSession = nil
      return
    socketPath = "\\\\.\\pipe\\repro-hcr-" & $session.targetPid
    session.socketPath = socketPath
    writeLaunchRecord(session)
    pushJs(coordinatorArgs, cstring"--pid")
    pushJs(coordinatorArgs, cstring($session.targetPid))
    pushJs(coordinatorArgs, cstring"--target-image")
    pushJs(coordinatorArgs, settings.targetImage)
    pushJs(coordinatorArgs, cstring"--target-pdb")
    pushJs(coordinatorArgs, settings.targetPdb)
    pushJs(coordinatorArgs, cstring"--first-instruction-length")
    pushJs(coordinatorArgs, cstring($settings.firstInstructionLength))

  pushJs(coordinatorArgs, cstring"--target-symbol")
  pushJs(coordinatorArgs, settings.targetSymbol)
  pushJs(coordinatorArgs, cstring"--session")
  pushJs(coordinatorArgs, cstring"--session-dir")
  pushJs(coordinatorArgs, cstring(sessionDir))
  pushJs(coordinatorArgs, cstring"--session-idle-timeout-ms")
  pushJs(coordinatorArgs, cstring($(
    if settings.idleTimeoutMs > 0: settings.idleTimeoutMs
    else: DefaultIdleTimeoutMs)))

  if not startCoordinator(coordinatorArgs):
    if platform == "win32" and not target.isNil:
      killChild(target)
      fsCloseQuietly(targetFd)
    activeSession = nil
    return

  if platform == "linux":
    # The coordinator is listening when its SOCKET EXISTS — which is the very
    # thing the target will dial — rather than when a line appears in its log.
    let listenDeadline = nowMs() + float(
      if settings.coordinatorListenTimeoutMs > 0:
        settings.coordinatorListenTimeoutMs
      else: DefaultCoordinatorListenTimeoutMs)
    var listening = false
    while nowMs() < listenDeadline:
      if fsExists(cstring(socketPath)):
        listening = true
        break
      if session.coordinatorExited:
        break
      await wait(PollIntervalMs)
    fsCloseQuietly(coordinatorFd)
    if not listening:
      let tail = $fsTail(cstring(coordinatorLog), 600)
      # A Linux target is deliberately NOT launched here: it would spend its
      # only dial-out on nothing and could never be edited afterwards.
      if session.coordinatorExited:
        session.fail("hcr-coordinator-failed",
          "the HCR coordinator exited before it began listening on " &
            socketPath & ". Its last output was: " & tail)
      else:
        session.fail("hcr-coordinator-not-listening",
          "the HCR coordinator did not create its socket " & socketPath &
            " within " & $int(listenDeadline - session.coordinatorStartedAtMs) &
            " ms. Its last output was: " & tail)
      killChild(coordinator)
      activeSession = nil
      return
    session.coordinatorListeningAtMs = nowMs()
    session.phase = hcrCoordinatorListening
    writeLaunchRecord(session)
    if not startTarget():
      await shutDownSession(session)
      activeSession = nil
      return

  infoPrint "hcr_launch: launched ", $config.program, " as pid ",
    $session.targetPid, " with ", transport, " coordinator pid ",
    $session.coordinatorPid

  # --- 5. the handshake ----------------------------------------------------
  # `ready` is written by the driver AFTER the handshake, not after the accept.
  # Treating a connected socket as a session would send the first edit into a
  # session that had not negotiated, which the state machine refuses — a
  # self-inflicted failure that reads like a broken agent.
  sendSessionStatus(hcrWaitingForAgent, cstring"launching",
    cstring(if platform == "linux":
      "waiting for the in-target HCR agent to dial the coordinator…"
    else:
      "waiting for the HCR coordinator to connect to the target's named pipe…"))
  session.phase = hcrWaitingForAgent
  writeLaunchRecord(session)
  let readyPath = sessionDir / "ready"
  let readyDeadline = nowMs() + float(
    if settings.readyTimeoutMs > 0: settings.readyTimeoutMs
    else: DefaultReadyTimeoutMs)
  var ready = false
  while nowMs() < readyDeadline:
    if fsExists(cstring(readyPath)):
      ready = true
      break
    if session.targetExited:
      break
    if session.coordinatorExited:
      break
    await wait(PollIntervalMs)
  fsCloseQuietly(targetFd)
  fsCloseQuietly(coordinatorFd)

  if ready:
    session.readyAtMs = nowMs()
    session.coordinatorConnectedAtMs = session.readyAtMs
    session.phase = hcrReady
    writeLaunchRecord(session)
    sendSessionStatus(hcrReady, cstring"session-ready",
      cstring("live-edit session open against " & $config.program & " (pid " &
        $session.targetPid & "). Type an edit — no rebuild, no restart."))
    return

  # Four ways not to be ready, and they are told apart rather than folded into
  # "the session did not start". Each names the thing that did not happen and
  # the process it did not happen in.
  if session.targetExited:
    let tail = $fsTail(cstring(targetLog), 600)
    if session.targetSpawnError.len > 0:
      session.fail("hcr-target-launch-failed",
        "could not start " & $config.program & ": " & session.targetSpawnError)
    else:
      session.fail("hcr-target-exited-early",
        "the program you launched (" & $config.program & ", pid " &
          $session.targetPid & ") exited with code " & $session.targetExitCode &
          " before its HCR agent finished connecting, so there is nothing to " &
          "edit. Its last output was: " & tail)
  elif session.coordinatorExited:
    let tail = $fsTail(cstring(coordinatorLog), 600)
    if platform == "win32":
      session.fail("hcr-coordinator-failed",
        "the Windows HCR coordinator exited before it connected to the " &
          "target's named pipe " & socketPath & ". Its last output was: " & tail)
    else:
      session.fail("hcr-coordinator-exited",
        "the HCR coordinator exited while waiting for the target's agent. Its " &
          "last output was: " & tail)
  else:
    # The target is ALIVE and the platform transport did not negotiate. This is
    # the case a bounded wait exists for; waiting longer only looks like work.
    session.fail("hcr-agent-never-dialled",
      "the program you launched (" & $config.program & ", pid " &
        $session.targetPid & ") is running but its HCR agent never connected " &
        "through " & socketPath & ". This will not resolve on its own.",
      "check that the program was built with the patchable HCR profile and " &
        (if platform == "linux": "that it reads " & socketEnvName & "."
         else: "that `agentDll` names its canonical Windows HCR agent."))
  killChild(target)
  await shutDownSession(session)
  activeSession = nil

proc killSessionChildrenOnExit(callback: proc()) {.importjs:
  "process.on('exit', #)".}

killSessionChildrenOnExit(proc () =
  ## THE TWO CHILDREN DO NOT OUTLIVE THIS PROCESS.
  ##
  ## Both are ordinary children, so nothing reaps them if CodeTracer is closed
  ## with a session open — the flame keeps rendering to a log nobody reads and
  ## the coordinator keeps holding a transport endpoint with no target. Node's
  ## `exit`
  ## handler may only do synchronous work, and `kill` is synchronous, so this is
  ## the one place the cleanup fits.
  ##
  ## Deliberately NOT a graceful `stop` file: by `exit` there is no event loop
  ## left to wait for the coordinator to write its summary, and a handler that
  ## pretended otherwise would just be a slower kill.
  if not activeSession.isNil:
    if not activeSession.target.isNil:
      killChild(activeSession.target)
    if not activeSession.coordinator.isNil:
      killChild(activeSession.coordinator))

proc onHcrLaunchTarget*(sender: js, response: js) {.async.} =
  ## `CODETRACER::hcr-launch-target` — launch the configured target under HCR.
  ##
  ## `response.name` optionally names a launch configuration; without it the
  ## first HCR-capable configuration in the project's `.vscode/launch.json` is
  ## used.
  var name = ""
  if not response.isNil and not response.name.isNil:
    name = $cast[cstring](response.name)
  await launchUnderHcr(name)
