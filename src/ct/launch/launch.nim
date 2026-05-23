import
  std/[ json, options, os, osproc, strutils ],
  ../../common/[ paths, types, intel_fix, install_utils,
                trace_index, install_progress ],
  ../utilities/[ git ],
  ../cli/[ logging, list, help, build, print_trace],
  ../online_sharing/[ upload, download, delete, remote,
                      activate_command, check_license_command, remote_config ],
  ../trace/[ replay, record, run, metadata, host, import_command ],
  ../ci/[ ci_commands ],
  ../codetracerconf,
  ../globals,
  ../stylus/[deploy, record, arb_node_utils],
  backends,
  electron,
  recording_id_env,
  results,
  json_serialization

when defined(linux):
  import ../../common/bpf_install

proc unescapeEnvValue(s: string): string =
  ## Unescape common escape sequences in .env file values.
  ## Handles: \n, \r, \t, \\, \", \'
  ## Also strips surrounding quotes if present.
  var value = s
  # Strip surrounding quotes if present
  if value.len >= 2:
    if (value[0] == '"' and value[^1] == '"') or
        (value[0] == '\'' and value[^1] == '\''):
      value = value[1 ..< ^1]

  result = newStringOfCap(value.len)
  var i = 0
  while i < value.len:
    if value[i] == '\\' and i + 1 < value.len:
      case value[i + 1]
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of '\\': result.add('\\')
      of '"': result.add('"')
      of '\'': result.add('\'')
      else:
        # Unknown escape, keep as-is
        result.add(value[i])
        result.add(value[i + 1])
      i += 2
    else:
      result.add(value[i])
      i += 1

proc loadEnvFiles(
    envFiles: seq[string],
    nullSeparated: bool,
    deleteAfterLoad: bool) =
  ## Load environment variables from files in order.
  ## nullSeparated: if true, entries are separated
  ## by null bytes (from 'env -0'); if false, entries
  ## are newline-separated KEY=VALUE lines with
  ## escape sequences.
  ## deleteAfterLoad: if true, delete the file after
  ## loading.
  ## Later files override earlier ones.
  for envFile in envFiles:
    if not fileExists(envFile):
      continue
    try:
      if nullSeparated:
        let content = readFile(envFile)
        for entry in content.split('\0'):
          if entry.len == 0:
            continue
          let eqPos = entry.find('=')
          if eqPos > 0:
            let key = entry[0 ..< eqPos]
            let value = entry[eqPos + 1 .. ^1]
            putEnv(key, value)
      else:
        for line in lines(envFile):
          let trimmed = line.strip()
          # Skip empty lines and comments
          if trimmed.len == 0 or trimmed.startsWith("#"):
            continue
          let eqPos = trimmed.find('=')
          if eqPos > 0:
            let key = trimmed[0 ..< eqPos]
            let value = unescapeEnvValue(trimmed[eqPos + 1 .. ^1])
            putEnv(key, value)
    finally:
      if deleteAfterLoad:
        try:
          removeFile(envFile)
        except CatchableError:
          discard

proc runInitial*(conf: CodetracerConf) =
  # TODO should this be here?
  workaroundIntelECoreProblem()

  # Load environment variables from env files.
  # This is needed when CodeTracer is launched via macOS 'open' command,
  # which doesn't preserve the shell environment.
  # Temporary files are loaded first (and deleted), then persistent files.
  # Later files override earlier ones within each category.
  if conf.tmpEnv0Files.len > 0:
    loadEnvFiles(
      conf.tmpEnv0Files,
      nullSeparated = true, deleteAfterLoad = true)
  if conf.tmpEnvFiles.len > 0:
    loadEnvFiles(
      conf.tmpEnvFiles,
      nullSeparated = false, deleteAfterLoad = true)
  if conf.env0Files.len > 0:
    loadEnvFiles(conf.env0Files, nullSeparated = true, deleteAfterLoad = false)
  if conf.envFiles.len > 0:
    loadEnvFiles(conf.envFiles, nullSeparated = false, deleteAfterLoad = false)

  # Change to the specified working directory if provided.
  # This is needed when CodeTracer is launched via macOS 'open' command,
  # which starts the app with cwd=/ instead of the user's current directory.
  if conf.cwd.isSome:
    setCurrentDir(conf.cwd.get)

  case conf.cmd:
    of StartupCommand.install:
      let rootDir = when defined(withTup):
          let gitTopLevelResult = getGitTopLevel(".")
          if gitTopLevelResult.isOk:
            gitTopLevelResult.value & "/"
          else:
            raise newException(
              ValueError,
              "no valid git root: " &
              gitTopLevelResult.error)
        else:
          codetracerPrefix & "/"

      when defined(macosx):
        let
          appDir = getAppDir()
          parentDir = appDir.parentDir
          inBundle = appDir.endsWith("/bin") and parentDir.endsWith("/MacOS")
          appLocation = if inBundle:
            # Skip over the Contents directory
            parentDir.parentDir.parentDir
          else:
            getAppFilename()
          appLocationFile = appInstallFsLocationPath()

        try:
          createDir appLocationFile.parentDir
        except CatchableError as err:
          echo "Failed to create directory for app location file: " & err.msg
          quit 1

        try:
          writeFile appLocationFile, appLocation
        except CatchableError as err:
          echo "Failed to create the app location file: " & err.msg
          quit 1

      let reporter = newInstallReporter(conf.installJson)

      # Step 1: PATH setup (all platforms, non-privileged).
      if conf.installCtOnPath:
        reporter.report(stepPath, statusStarted, "Adding ct to PATH")
        let status = installCodetracerOnPath(codetracerExe)
        if status.isErr:
          reporter.report(
            stepPath, statusFailed,
            "Failed to install on PATH: " &
            status.error, fatal = true)
          quit 1
        reporter.report(stepPath, statusCompleted, "Added ct to PATH")
      else:
        reporter.report(stepPath, statusSkipped, "PATH setup skipped")

      # Step 2: Desktop file (Linux only, non-privileged).
      when defined(linux):
        if conf.installCtDesktopFile:
          reporter.report(stepDesktop, statusStarted, "Installing desktop file")
          installCodetracerDesktopFile(codetracerPrefix, rootDir, codetracerExe)
          reporter.report(
            stepDesktop, statusCompleted,
            "Desktop file installed")
        else:
          reporter.report(
            stepDesktop, statusSkipped,
            "Desktop file setup skipped")

        # Step 3: BPF capabilities (Linux only, requires sudo).
        if conf.installBpf:
          if isNixManagedBpf():
            reporter.report(
              stepBpf, statusSkipped,
              "BPF is managed by the Nix package")
          else:
            reporter.report(
              stepBpf, statusStarted,
              "Setting up BPF process monitoring")
            let bpfResult = installBpfSupport()
            if bpfResult.isErr:
              reporter.report(
                stepBpf, statusFailed,
                "BPF setup failed: " &
                bpfResult.error)
            else:
              reporter.report(
                stepBpf, statusCompleted,
                "BPF process monitoring set up")
        else:
          reporter.report(stepBpf, statusSkipped, "BPF setup skipped")

      # Step 4: Agent Harbor (all platforms, requires root for Linux).
      if conf.installAgentHarbor:
        reporter.report(
          stepAgentHarbor, statusStarted,
          "Installing Agent Harbor")
        let ahResult = installAgentHarbor()
        if ahResult.isErr:
          reporter.report(stepAgentHarbor, statusFailed, ahResult.error)
        else:
          reporter.report(
          stepAgentHarbor, statusCompleted,
          "Agent Harbor installed")
      else:
        reporter.report(
          stepAgentHarbor, statusSkipped,
          "Agent Harbor installation skipped")

      quit(0)

    of StartupCommand.replay:
      # Resolve the effective new-trace policy:
      # CLI flags override the config setting.
      let replayPolicy =
        if conf.newTab: "tab"
        elif conf.newWindow: "window"
        else: "" # empty = defer to config/default
      replay(
        conf.lastTraceMatchingPattern,
        conf.replayRecordingId,
        conf.replayTraceFolder,
        replayInteractive,
        newTracePolicy = replayPolicy,
        inspect = conf.inspect,
        remoteDebuggingPort = conf.remoteDebuggingPort,
        remoteDebuggingPipe = conf.remoteDebuggingPipe,
      )
    of StartupCommand.noCommand:
      # When ct is launched with no subcommand, show the welcome screen.
      # If --deepreview is provided, open the deepreview view instead.
      # Playwright launches the ct binary directly and passes the trace to
      # the Electron index process via CODETRACER_RECORDING_ID. In that case we
      # must not force --welcome-screen, or the renderer never enters replay
      # mode and GUI tests time out before the first real window.
      #
      # M-REC-6: env var renamed from ``CODETRACER_TRACE_ID`` to
      # ``CODETRACER_RECORDING_ID`` (UUIDv7 recording-id string).  Setting
      # both at once is a configuration error (the legacy name is gone,
      # not aliased): fail loudly rather than silently picking one.
      # Guard logic lives in ``recording_id_env`` so the launch path and
      # ``launch_env_var_test`` share a single source of truth.
      refuseLegacyRecordingIdEnv(proc (msg: string) = errorMessage(msg))
      var frontendArgs: seq[string] = @[]
      if conf.deepreview.len > 0:
        frontendArgs.add("--deepreview")
        frontendArgs.add(conf.deepreview)
      elif getEnv("CODETRACER_RECORDING_ID", "").len == 0:
        frontendArgs.add("--welcome-screen")
      launchElectron(
        args = frontendArgs,
        inspect = conf.inspect,
        remoteDebuggingPort = conf.remoteDebuggingPort,
        remoteDebuggingPipe = conf.remoteDebuggingPipe)
    # of StartupCommand.ruby:
    #   runCompilerProcess(
    #     "ruby",
    #     conf.rubyArgs)
    # of StartupCommand.python:
    #   notSupportedCommand(conf.cmd)
    # of StartupCommand.lua:
    #   notSupportedCommand(conf.cmd)
    # of StartupCommand.nim:
    #   notSupportedCommand(conf.cmd)
    of StartupCommand.list:
      listCommand(conf.listTarget, conf.listFormat)
    of StartupCommand.print:
      let printOpts = PrintOptions(
        path: conf.printPath,
        filter: conf.printFilter.get(""),
        function: conf.printFunction.get(""),
        limit: conf.printLimit.get(0),
        format: conf.printFormat.get("text"),
        verify: conf.printVerify.get(false),
        follow: conf.printFollow.get(false),
      )
      runPrint(printOpts)
    of StartupCommand.help:
      displayHelp()
    of StartupCommand.console:
      # similar to replay
      notSupportedCommand($conf.cmd)
    of StartupCommand.host:
      hostCommand(
        conf.hostPort,
        conf.hostBackendSocketPort, conf.hostFrontendSocketPort,
        conf.hostFrontendSocketParameters, conf.hostTraceArg,
        conf.hostIdleTimeout,
        conf.hostTracePath,
        conf.hostManifestPath,
        conf.hostStorageBaseUrl,
        conf.hostStorageTenantId,
        conf.hostStorageToken,
        conf.hostStorageProtocol)
    of StartupCommand.`import`:
      importCommand(
        conf.importTraceZipPath,
        conf.importOutputPath)
    of StartupCommand.upload:
      # similar to replay/console
      uploadCommand(
        conf.uploadLastTraceMatchingPattern,
        conf.uploadRecordingId,
        conf.uploadTraceFolder,
        replayInteractive,
        conf.uploadOrg,
        conf.uploadToken,
        conf.uploadBaseUrl,
        conf.uploadNoPortable,
        conf.uploadNoSplitUpload)
    of StartupCommand.download:
      downloadTraceCommand(conf.traceDownloadUrl,
        conf.downloadToken,
        conf.downloadBaseUrl)
    of StartupCommand.login:
      loginCommand(conf.loginDefaultOrg, conf.loginBaseUrl)
    of StartupCommand.`set-default-org`:
      setDefaultOrg(conf.setDefaultOrgName)
    of StartupCommand.`get-default-org`:
      getDefaultOrg()
    of StartupCommand.activate:
      let rc = initRemoteConfig()
      activateCommand(rc,
        conf.activateToken.get(""),
        conf.activateBaseUrl.get(""))
    of StartupCommand.`check-license`:
      let rc = initRemoteConfig()
      checkLicenseCommand(rc,
        conf.checkLicenseToken.get(""),
        conf.checkLicenseBaseUrl.get(""))
    # of StartupCommand.cmdDelete:
    #   deleteTraceCommand(conf.traceId, conf.controlId)
    #   # eventually enable?
    #   # downloadCommand(conf.traceRegistryId)
    of StartupCommand.build:
      discard build(conf.buildProgramPath, conf.buildOutputPath)
    of StartupCommand.record:
      discard record(
        conf.recordLang, conf.recordOutputFolder,
        conf.recordExportFile, conf.recordStylusTrace,
        conf.recordAddress, conf.recordSocket, conf.recordBackend,
        conf.recordWithDiff,
        conf.recordStoreTraceFolderForPid,
        conf.recordUpload,
        conf.recordProgram, conf.recordArgs)
    of StartupCommand.`record-test`:
      recordTest(
        conf.recordTestTestName, conf.recordTestPath,
        conf.recordTestLine, conf.recordTestColumn,
        conf.recordTestWithDiff, conf.recordTestStoreTraceFolderForPid)
    of StartupCommand.run:
      # Resolve the effective new-trace policy:
      # CLI flags override the config setting.
      let runPolicy =
        if conf.newTab: "tab"
        elif conf.newWindow: "window"
        else: "" # empty = defer to config/default
      run(conf.runTracePathOrId, conf.runArgs,
          newTracePolicy = runPolicy)
    of StartupCommand.remote:
      quit(runCtRemote(conf.remoteArgs))
    of StartupCommand.arb:
      case conf.arbCommand:
      of ArbCommand.noCommand:
        echo "No subcommand provded!"
        quit 1
      of ArbCommand.explorer:
        # Launch CodeTracer in arb explorer mode
        launchElectron(
          mode = ElectronLaunchMode.ArbExplorer,
          inspect = conf.inspect,
          remoteDebuggingPort = conf.remoteDebuggingPort,
          remoteDebuggingPipe = conf.remoteDebuggingPipe)
      of ArbCommand.record:
        discard recordStylus(conf.arbRecordTransaction)
      of ArbCommand.replay:
        replayStylus(conf.arbReplayTransaction)
      of ArbCommand.deploy:
        deployStylus()
      of ArbCommand.listRecentTx:
        let transactions = getTrackableTransactions()
        let res = Json.encode(transactions)
        echo res
    of StartupCommand.ci:
      let token = resolveToken(conf.ciToken)
      let baseUrl = resolveBaseUrl(conf.ciBaseUrl)
      case conf.ciCommand:
      of CICommand.noCommand:
        echo "No CI subcommand specified. Use 'ct ci --help' for usage."
        quit(1)
      of CICommand.start:
        ciStartCommand(
          token, baseUrl,
          conf.ciStartRepo, conf.ciStartCommit,
          conf.ciStartBranch, conf.ciStartBaseCommit,
          conf.ciStartLabel,
          conf.ciStartMonitorProcesses)
      of CICommand.attach:
        ciAttachCommand(token, baseUrl, conf.ciAttachRunId)
      of CICommand.exec:
        let exitCode = ciExecCommand(
          token, baseUrl,
          conf.ciExecProgram,
          conf.ciExecArgs, conf.ciExecRecord,
          conf.ciExecMonitorProcesses)
        if exitCode != 0:
          quit(exitCode)
      of CICommand.finish:
        ciFinishCommand(token, baseUrl, conf.ciFinishStatus)
      of CICommand.run:
        ciRunCommand(
          token, baseUrl,
          conf.ciRunRepo, conf.ciRunCommit,
          conf.ciRunBranch, conf.ciRunBaseCommit,
          conf.ciRunLabel,
          conf.ciRunMonitorProcesses,
          conf.ciRunRecord,
          conf.ciRunProgram, conf.ciRunArgs)
      of CICommand.log:
        ciLogCommand(token, baseUrl, conf.ciLogMessage)
      of CICommand.status:
        ciStatusCommand(token, baseUrl)
      of CICommand.cancel:
        ciCancelCommand(token, baseUrl)
    of StartupCommand.`index-diff`:
      indexDiff(conf.indexDiffTracePath)
    of StartupCommand.edit:
      let absPath = absolutePath(conf.editPath)
      if not fileExists(absPath) and not dirExists(absPath):
        errorMessage "Path does not exist: " & absPath
        quit(1)
      # Track folder in recent folders if it's a directory
      if dirExists(absPath):
        trace_index.addRecentFolder(absPath, test = false)
      launchElectron(
        args = @["edit", absPath],
        inspect = conf.inspect,
        remoteDebuggingPort = conf.remoteDebuggingPort,
        remoteDebuggingPipe = conf.remoteDebuggingPipe)
    # of StartupCommand.host:
    #   host(
    #     conf.hostPort,
    #     conf.hostBackendSocketPort, conf.hostFrontendSocketPort,
    #     conf.hostFrontendSocketParameters, conf.hostTraceArg)
    # of StartupCommand.`import`:
    #   importCommand(conf.importTraceZipPath, conf.importOutputPath)
    # of StartupCommand.`import-db-trace`:
    #   discard importDbTrace(conf.importDbTracePath, NO_RECORDING_ID)
    # of StartupCommand.summary:
    #   replaySummary(conf.summaryTraceId, conf.summaryOutputFolder)
    # of StartupCommand.`report-bug`:
    #   sendBugReportAndLogsCommand(
    #     conf.title, conf.description,
    #     conf.pid, conf.confirmSend)
    of StartupCommand.electron:
      # Collect electron debug flags if provided
      var electronArgs: seq[string] = @[]
      if conf.inspect.isSome:
        electronArgs.add("--inspect=" & conf.inspect.get)
      if conf.remoteDebuggingPort.isSome:
        electronArgs.add(
          "--remote-debugging-port=" &
          conf.remoteDebuggingPort.get)
      # conf.electronAppArgs: command-specific restOfArgs (app arguments)
      wrapElectron(electronArgs, conf.electronAppArgs)
    of StartupCommand.`trace-metadata`:
      traceMetadata(
        conf.recordingMetadataIdArg, conf.traceMetadataPathArg,
        conf.traceMetadataProgramArg, conf.traceMetadataRecordPidArg,
        conf.traceMetadataRecent,
        conf.traceMetadataRecentFolders,
        conf.traceMetadataAddRecentFolder,
        conf.traceMetadataRecentLimit,
        conf.traceMetadataTest)
    of StartupCommand.start_backend:
      startBackend(conf.backendKind, conf.isStdio, conf.socketPath)
