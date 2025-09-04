import
  std / [ async, jsffi, strutils, sequtils ],
  ../../[ trace_metadata, index_config, config, types, lib ],
  electron_vars,
  results,
  files,
  ../../../common/[ ct_logging, paths ]


let
  CT_DEBUG_INSTANCE_PATH_BASE*: cstring = cstring(codetracerTmpPath) & cstring"/ct_instance_"

proc loadExistingRecord*(traceId: int) {.async.} =
  debugPrint "[info]: load existing record with ID: ", $traceId
  let trace = await electron_vars.app.findTraceWithCodetracer(traceId)
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild

  if not data.trace.isNil:
    debugPrint "index: init debugger"
    discard initDebugger(mainWindow, data.trace, data.config, Helpers())

  debugPrint "index: init frontend"
  mainWindow.webContents.send(
    "CODETRACER::init",
    js{
      home: paths.home.cstring,
      config: data.config,
      layout: data.layout,
      helpers: data.helpers,
      startOptions: data.startOptions,
      bypass: true})

  if not data.trace.isNil:
    debugPrint "index: loading trace in mainWindow"
    await data.loadTrace(mainWindow, data.trace, data.config, data.helpers)

  try:
    let instanceClient = await startSocket(CT_DEBUG_INSTANCE_PATH_BASE & cstring($callerProcessPid))
    instanceClient.on(cstring"data") do (data: cstring):
      let outputLine = data.trim.parseJsInt
      debugPrint "index: ===> output line ", outputLine
      mainWindow.webContents.send cstring"CODETRACER::output-jump-from-shell-ui", outputLine
  except:
    debugPrint "warning: exception when starting instance client:"
    debugPrint "  that's ok, if this was not started from shell-ui!"

proc prepareForLoadingTrace*(traceId: int, pid: int) {.async.} =
  callerProcessPid = pid
  # TODO: use type/function for this
  let packet = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/start-replay",
    "arguments": [cstring"db-backend"]
  }
  backendManagerSocket.write(packet)

proc replayTx(txHash: cstring, pid: int): Future[(cstring, int)] {.async.} =
  callerProcessPid = pid
  let outputResult = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"arb", cstring"replay", txHash]
  )
  var output = cstring""
  if outputResult.isOk:
    output = outputResult.value
    let lines = output.split(jsNl)
    if lines.len > 1:
      let traceIdLine = $lines[^2]
      # probably because we print `traceId:<traceId>\n` : so the last line is ''
      #   and traceId is in the second last line
      if traceIdLine.startsWith("traceId:"):
        let traceId = traceIdLine[("traceId:").len .. ^1].parseInt
        return (output, traceId)
  else:
    output = JSON.stringify(outputResult.error)
  return (output, NO_INDEX)

proc onLoadRecentTrace*(sender: js, response: jsobject(traceId=int)) {.async.} =
  await prepareForLoadingTrace(response.traceId, nodeProcess.pid.to(int))
  await loadExistingRecord(response.traceId)

proc onLoadRecentTransaction*(sender: js, response: jsobject(txHash=cstring)) {.async.} =
  let (rawOutputOrError, traceId) = await replayTx(response.txHash, nodeProcess.pid.to(int))
  if traceId != NO_INDEX:
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
  else:
    # TODO: process notifications in welcome screen, or a different kind of error handler for this case
    # currently not working in frontend, because no status component for now in welcome screen
    # sendNotification(NotificationKind.NotificationError, "couldn't record trace for the transaction")
    echo ""
    echo ""
    echo "ERROR: couldn't record trace for transaction:"
    echo "==========="
    echo "(raw output or error):"
    echo rawOutputOrError
    echo "(end of raw output or error)"
    echo "==========="
    quit(1)

proc onLoadTraceByRecordProcessId*(sender: js, pid: int) {.async.} =
  let trace = await electron_vars.app.findTraceByRecordProcessId(pid)
  await prepareForLoadingTrace(trace.id, pid)
  await loadExistingRecord(trace.id)

proc onStopRecordingProcess*(sender: js, response: js) {.async.} =
  if not data.recordProcess.isNil:
    if data.recordProcess.kill():
      data.recordProcess = nil
    else:
      warnPrint "Unable to stop recording process"
  else:
    warnPrint "There is not any recording process"

proc onOpenLocalTrace*(sender: js, response: js) {.async.} =
  let selection = await selectDir(j"Select Trace Output Folder", codetracerTraceDir)
  if selection.len == 0:
    errorPrint "no folder selected"
  else:
    # selectDir tries to return a folder with a trailing slash
    let trace = await electron_vars.app.findByPath(selection)
    if not trace.isNil:
      mainWindow.webContents.send "CODETRACER::loading-trace",
        js{trace: trace}
      await prepareForLoadingTrace(trace.id, nodeProcess.pid.to(int))
      await loadExistingRecord(trace.id)
    else:
      errorPrint "There is no record at given path."

proc onNewRecord*(sender: js, response: jsobject(args=seq[cstring], options=JsObject)) {.async.}=
  let processResult = await startProcess(
    codetracerExe,
    @[j"record"].concat(response.args),
    response.options)

  if processResult.isOk:
    data.recordProcess = processResult.value
    let error = await waitProcessResult(processResult.value)

    if error.isNil:
      debugPrint "recorded successfully"
      mainWindow.webContents.send "CODETRACER::successful-record"
      await onLoadTraceByRecordProcessId(nil, processResult.value.pid)
    else:
      errorPrint "record error: ", error
      if not data.recordProcess.isNil:
        mainWindow.webContents.send "CODETRACER::failed-record",
          js{errorMessage: cstring"codetracer record command failed"}

  else:
    errorPrint "record start process error: ", processResult.error
    let errorSpecificText = if not processResult.error.isNil: cast[cstring](processResult.error.code) else: cstring""
    let errorText = cstring"record start process error: " & errorSpecificText
    mainWindow.webContents.send "CODETRACER::failed-record",
      js{errorMessage: errorText}