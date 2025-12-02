import
  std/[ json, os, osproc, strutils ],
  ../../common/[ paths, types, intel_fix, install_utils ],
  ../utilities/[ git ],
  ../cli/[ logging, list, help, build],
  ../online_sharing/[ upload, download, delete, remote ],
  ../trace/[ replay, record, run, metadata, host, import_command ],
  ../codetracerconf,
  ../globals,
  ../stylus/[deploy, record, arb_node_utils],
  backends,
  electron,
  results,
  json_serialization

proc eventuallyWrapElectron*: bool =
  if getEnv("CODETRACER_WRAP_ELECTRON", "") == "1":
    var args: seq[string] = @[]
    for i in 1 .. paramCount():
      args.add(paramStr(i))
    wrapElectron(args)
    true
  else:
    false

proc runInitial*(conf: CodetracerConf) =
  # TODO should this be here?
  workaroundIntelECoreProblem()

  case conf.cmd:
    of StartupCommand.install:
      let rootDir = when defined(withTup):
          let gitTopLevelResult = getGitTopLevel(".")
          if gitTopLevelResult.isOk:
            gitTopLevelResult.value & "/"
          else:
            raise newException(ValueError, "no valid git root: " & gitTopLevelResult.error)
        else:
          linksPath & "/"

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

      if conf.installCtOnPath:
        echo "About to install on PATH"
        let status = installCodetracerOnPath(codetracerExe)
        if status.isErr:
          echo "Failed to install CodeTracer: " & status.error
          quit 1

      when defined(linux):
        if conf.installCtDesktopFile:
          installCodetracerDesktopFile(linksPath, rootDir, codetracerExe)

      quit(0)

    of StartupCommand.replay:
      let shouldRestart = replay(
        conf.lastTraceMatchingPattern,
        conf.replayTraceId,
        conf.replayTraceFolder,
        replayInteractive
      )
      if shouldRestart:
        quit(RESTART_EXIT_CODE)
    of StartupCommand.noCommand:
      let workdir = codetracerInstallDir

      # sometimes things like "--no-sandbox" are useful e.g. for now for
      # experimenting with appimage
      # let optionalElectronArgs = getEnv("CODETRACER_ELECTRON_ARGS", "").splitWhitespace()
      discard launchElectron()
      # var processUI = startProcess(
      #   electronExe,
      #   workingDir = workdir,
      #   args = @[electronIndexPath].concat(optionalElectronArgs),
      #   options={poParentStreams})
      # electronPid = processUI.processID
      # echo "status code:", waitForExit(processUI)
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
        conf.hostIdleTimeout)
    of StartupCommand.`import`:
      importCommand(
        conf.importTraceZipPath,
        conf.importOutputPath)
    of StartupCommand.upload:
      # similar to replay/console
      uploadCommand(
        conf.uploadLastTraceMatchingPattern,
        conf.uploadTraceId,
        conf.uploadTraceFolder,
        replayInteractive,
        conf.uploadOrg)
    of StartupCommand.download:
      downloadTraceCommand(conf.traceDownloadUrl)
    of StartupCommand.login:
      loginCommand(conf.loginDefaultOrg)
    of StartupCommand.`set-default-org`:
      setDefaultOrg(conf.setDefaultOrgName)
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
        conf.recordAddress, conf.recordSocket,
        conf.recordWithDiff, conf.recordStoreTraceFolderForPid, conf.recordUpload,
        conf.recordProgram, conf.recordArgs)
    of StartupCommand.`record-test`:
      recordTest(
        conf.recordTestTestName, conf.recordTestPath,
        conf.recordTestLine, conf.recordTestColumn,
        conf.recordTestWithDiff, conf.recordTestStoreTraceFolderForPid)
    of StartupCommand.run:
      run(conf.runTracePathOrId, conf.runArgs)
    of StartupCommand.remote:
      quit(runCtRemote(conf.remoteArgs))
    of StartupCommand.arb:
      case conf.arbCommand:
      of ArbCommand.noCommand:
        echo "No subcommand provded!"
        quit 1
      of ArbCommand.explorer:
        # Launch CodeTracer in arb explorer mode
        discard launchElectron(mode = ElectronLaunchMode.ArbExplorer)
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
    of StartupCommand.`index-diff`:
      indexDiff(conf.indexDiffTracePath)
    # of StartupCommand.host:
    #   host(
    #     conf.hostPort,
    #     conf.hostBackendSocketPort, conf.hostFrontendSocketPort,
    #     conf.hostFrontendSocketParameters, conf.hostTraceArg)
    # of StartupCommand.`import`:
    #   importCommand(conf.importTraceZipPath, conf.importOutputPath)
    # of StartupCommand.`import-db-trace`:
    #   discard importDbTrace(conf.importDbTracePath, NO_TRACE_ID)
    # of StartupCommand.summary:
    #   replaySummary(conf.summaryTraceId, conf.summaryOutputFolder)
    # of StartupCommand.`report-bug`:
    #   sendBugReportAndLogsCommand(conf.title, conf.description, conf.pid, conf.confirmSend)
    of StartupCommand.electron:
      wrapElectron(conf.electronArgs)
    of StartupCommand.`trace-metadata`:
      traceMetadata(
        conf.traceMetadataIdArg, conf.traceMetadataPathArg,
        conf.traceMetadataProgramArg, conf.traceMetadataRecordPidArg,
        conf.traceMetadataRecent,
        conf.traceMetadataRecentLimit,
        conf.traceMetadataTest)
    of StartupCommand.start_backend:
      startBackend(conf.backendKind, conf.isStdio, conf.socketPath)
