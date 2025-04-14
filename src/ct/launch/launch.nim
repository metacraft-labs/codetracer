import
  std / [os, strutils ],
  ../../common/[ paths, types, intel_fix, install_utils ],
  ../utilities/[ git ],
  ../cli/[ logging, list, help, build],
  ../online_sharing/[ upload, download, delete ],
  ../trace/[ replay, record, run, metadata ],
  ../codetracerconf,
  ../version,
  ../globals,
  electron,
  results,
  backends

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
      let rootDir = when defined(withTup): getGitTopLevel(".") & "/" else: linksPath & "/"

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
    of StartupCommand.version:
      echo "CodeTracer ", when defined(debug): "debug " else: "", CodeTracerVersionStr
    of StartupCommand.console:
      # similar to replay
      notSupportedCommand($conf.cmd)
    of StartupCommand.upload:
      # similar to replay/console
      uploadCommand(
        conf.uploadLastTraceMatchingPattern,
        conf.uploadTraceId,
        conf.uploadTraceFolder,
        replayInteractive)
    of StartupCommand.download:
      downloadTraceCommand(conf.traceDownloadKey)
    of StartupCommand.cmdDelete:
      deleteTraceCommand(conf.traceId, conf.controlId)
      # eventually enable?
      # downloadCommand(conf.traceRegistryId)
    of StartupCommand.build:
      build(conf.buildProgramPath, conf.buildOutputPath)
    of StartupCommand.record:
      discard record(conf.recordLang, conf.recordOutputFolder, conf.recordExportFile, conf.recordLang, conf.recordProgram, conf.recordArgs)
    of StartupCommand.run:
      run(conf.runTracePathOrId, conf.runArgs)
    of StartupCommand.start_core:
      startCore(conf.coreTraceArg, conf.coreCallerPid, conf.coreInTest)
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
