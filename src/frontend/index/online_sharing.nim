import
  std / [ async, jsffi, json, strutils, sequtils ],
  results,
  traces,
  electron_vars,
  ../[ types ],
  ../lib/[ jslib, electron_lib ],
  ../../common/[ paths ]

when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):


  proc runUploadWithStreaming(
      path: cstring,
      args: seq[cstring],
      onData: proc(data: string),
      onDone: proc(success: bool, result: string)
  ) =
    setupLdLibraryPath()

    let process = nodeStartProcess.spawn(path, args)
    process.stdout.setEncoding("utf8")

    var fullOutput = ""

    process.stdout.toJs.on("data", proc(data: cstring) =
      let str = $data
      fullOutput.add(str)
      onData(str)
    )

    process.stderr.toJs.on("data", proc(err: cstring) =
      echo "[stderr]: ", err
      fullOutput.add($err)
    )

    process.toJs.on("exit", proc(code: int, _: cstring) =
      onDone(code == 0, fullOutput)
    )

  proc runProcess*(path: cstring, args: seq[cstring]): Future[JsObject] {.async.} =
    let processStart = await startProcess(path, args)
    if not processStart.isOk:
      return processStart.error
    return await waitProcessResult(processStart.value)

proc onUploadTraceFile*(sender: JsObject, response: UploadTraceArg) =
  runUploadWithStreaming(
    codetracerExe.cstring,
    @[
      cstring"upload",
      cstring"--trace-folder=" & response.trace.outputFolder
    ],
    onData = proc(data: string) =
      let jsonLine = parseJson(data.split("\n")[^2].strip())
      if jsonLine.hasKey("progress"):
        mainWindow.webContents.send("CODETRACER::upload-trace-progress",
        UploadProgress(
          id: response.trace.recordingId,
          progress: jsonLine["progress"].getInt(),
          msg: jsonLine["message"].getStr("")
        )),
    onDone = proc(success: bool, result: string) =
      if success:
        let lines = result.splitLines()
        let lastLine = lines[^2]
        let parsed = parseJson(lastLine)
        let uploadData = UploadedTraceData(
          downloadKey: $parsed["downloadKey"].getStr(""),
          controlId: $parsed["controlId"].getStr(""),
          expireTime: $parsed["storedUntilEpochSeconds"].getInt()
        )
        mainWindow.webContents.send("CODETRACER::upload-trace-file-received", js{
          "argId": cstring(response.trace.program & ":" & $response.trace.recordingId),
          "value": uploadData
        })
      else:
        mainWindow.webContents.send("CODETRACER::uploaded-trace-file-received", js{
          "argId": cstring(response.trace.program & ":" & $response.trace.recordingId),
          "value": UploadedTraceData(downloadKey: "Errored")
        })
  )

proc onDownloadTraceFile*(sender: js, response: jsobject(downloadKey = seq[cstring])) {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"download"].concat(response.downloadKey)
  )

  if res.isOk:
    # M-REC-3: ``ct download`` prints the UUIDv7 recording-id of the
    # imported trace on stdout (one line).  Take it verbatim.
    let recordingId = cstring(($res.value).strip())
    await prepareForLoadingTrace(recordingId, nodeProcess.pid.to(int))
    await loadExistingRecord(recordingId)
    mainWindow.webContents.send "CODETRACER::successful-download"
  else:
    mainWindow.webContents.send "CODETRACER::failed-download",
      js{errorMessage: cstring"codetracer server down or wrong download key"}

proc onDeleteOnlineTraceFile*(sender: js, response: DeleteTraceArg) {.async.} =
  # M-REC-8: forward the UUIDv7 ``recording_id`` via ``--id=`` (the
  # consistent recording-id flag name across ``ct upload`` / ``ct
  # replay`` / ``ct trace-metadata`` per M-REC-6).  ``cmdDelete`` is
  # currently commented out in ``codetracerconf.nim``; this wiring is
  # kept in place so that re-enabling the subcommand only needs the
  # conf edit.
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[
      cstring"cmdDelete",
      cstring"--id=" & $response.recordingId,
      cstring"--control-id=" & response.controlId
    ]
  )

  mainWindow.webContents.send(
    "CODETRACER::delete-online-trace-file-received",
    js{
      "argId": cstring($response.recordingId & ":" & response.controlId),
      "value": res.isOk
    }
  )

proc onSendBugReportAndLogs*(sender: js, response: BugReportArg) {.async.} =
  let process = await runProcess(
    codetracerExe.cstring,
    @[cstring"report-bug",
      cstring"--title=" & response.title,
      cstring"--description=" & response.description,
      cstring($callerProcessPid),
      cstring"--confirm-send=0"]
  )
