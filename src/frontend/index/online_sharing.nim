import
  std / [ async, jsffi, json, options, strutils, sequtils ],
  results,
  traces,
  electron_vars,
  ../[ types ],
  ../lib/[ jslib, electron_lib ],
  ../../common/[ paths ],
  # `parseArtifactKind` — the ONE way a kind enters from untrusted input. Read
  # from `ct upload`'s stdout, this is untrusted input like any other, and a
  # `getStr("recording")` default here would be the same fallback-not-validator
  # mistake `Artifact-Store.md` §8 defect 10 records. The module is pure and
  # compiles on the JavaScript backend, which is why it can be imported here.
  ../../ct/online_sharing/[ artifact ]

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
        # AS-2: `ct upload`'s machine-readable result is the LAST non-empty
        # line, and it is reachable now — `uploadTrace` used to end every path
        # in `quit(...)`, so this branch parsed whatever narration happened to
        # be last (`Artifact-Store.md` §8 defect 2).  Scanning back for the
        # last non-empty line rather than indexing `[^2]` is what keeps this
        # working whether or not the command's final `echo` ends in a newline.
        var lastLine = ""
        for line in result.splitLines():
          if line.strip().len > 0:
            lastLine = line.strip()
        var uploadData = UploadedTraceData()
        try:
          let parsed = parseJson(lastLine)
          # No default kind. An absent or unrecognised token leaves `kind`
          # empty, which reads as "the result did not say", rather than
          # labelling somebody's review dataset a recording.
          let declaredKind = parseArtifactKind($parsed{"kind"}.getStr(""))
          uploadData = UploadedTraceData(
            artifactId: $parsed{"artifactId"}.getStr(""),
            kind: if declaredKind.isSome:
                    kindSpec(declaredKind.get).wireToken
                  else: "",
            shareUrl: $parsed{"shareUrl"}.getStr("")
          )
        except CatchableError:
          # The command succeeded but said nothing machine-readable. Reported
          # as an empty result rather than crashing the IPC handler, which is
          # what an unguarded `parseJson` here used to do.
          discard
        mainWindow.webContents.send("CODETRACER::upload-trace-file-received", js{
          "argId": cstring(response.trace.program & ":" & $response.trace.recordingId),
          "value": uploadData
        })
      else:
        mainWindow.webContents.send("CODETRACER::uploaded-trace-file-received", js{
          "argId": cstring(response.trace.program & ":" & $response.trace.recordingId),
          "value": UploadedTraceData(shareUrl: "Errored")
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
