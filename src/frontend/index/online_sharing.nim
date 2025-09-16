import
  std / [ async, jsffi, json, strutils, sequtils ],
  results,
  traces,
  electron_vars,
  ../[ types, lib ],
  ../../common/[ paths ]

proc onUploadTraceFile*(sender: JsObject, response: UploadTraceArg) =
  runUploadWithStreaming(
    codetracerExe.cstring,
    @[
      j"upload",
      j"--trace-folder=" & response.trace.outputFolder
    ],
    onData = proc(data: string) =
      let jsonLine = parseJson(data.split("\n")[^2].strip())
      if jsonLine.hasKey("progress"):
        mainWindow.webContents.send("CODETRACER::upload-trace-progress",
        UploadProgress(
          id: response.trace.id,
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
          "argId": j(response.trace.program & ":" & $response.trace.id),
          "value": uploadData
        })
      else:
        mainWindow.webContents.send("CODETRACER::uploaded-trace-file-received", js{
          "argId": j(response.trace.program & ":" & $response.trace.id),
          "value": UploadedTraceData(downloadKey: "Errored")
        })
  )

proc onDownloadTraceFile*(sender: js, response: jsobject(downloadKey = seq[cstring])) {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[j"download"].concat(response.downloadKey)
  )

  if res.isOk:
    let traceId = parseInt($res.v.trim())
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
    mainWindow.webContents.send "CODETRACER::successful-download"
  else:
    mainWindow.webContents.send "CODETRACER::failed-download",
      js{errorMessage: cstring"codetracer server down or wrong download key"}

proc onDeleteOnlineTraceFile*(sender: js, response: DeleteTraceArg) {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[
      j"cmdDelete",
      j"--trace-id=" & $response.traceId,
      j"--control-id=" & response.controlId
    ]
  )

  mainWindow.webContents.send(
    "CODETRACER::delete-online-trace-file-received",
    js{
      "argId": j($response.traceId & ":" & response.controlId),
      "value": res.isOk
    }
  )

proc onSendBugReportAndLogs*(sender: js, response: BugReportArg) {.async.} =
  let process = await runProcess(
    codetracerExe.cstring,
    @[j"report-bug",
      j"--title=" & response.title,
      j"--description=" & response.description,
      j($callerProcessPid),
      j"--confirm-send=0"]
  )
