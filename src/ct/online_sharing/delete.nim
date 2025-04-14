proc deleteRemoteFile(controlId: string, config: Config) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  # <enabled case>:

  let test = false
  var exitCode = 0

  var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
  
  try:
    discard client.getContent(fmt"{parseUri(config.baseUrl) / config.deleteApi}?ControlId={controlId}")
    
    updateField(id, "remoteShareDownloadId", "", test)
    updateField(id, "remoteShareControlId", "", test)
    updateField(id, "remoteShareExpireTime", -1, test)
    exitCode = 0
  except CatchableError as e:
    echo fmt"error: can't delete trace {e.msg}"
    exitCode = 1
  finally:
    client.close()

  quit(exitCode)


proc deleteTraceCommand*(id: int, controlId: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  # <enabled case>:

  let test = false
  var exitCode = 0

  var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
  
  try:
    discard client.getContent(fmt"{parseUri(config.baseUrl) / config.deleteApi}?ControlId={controlId}")
    
    updateField(id, "remoteShareDownloadId", "", test)
    updateField(id, "remoteShareControlId", "", test)
    updateField(id, "remoteShareExpireTime", -1, test)
    exitCode = 0
  except CatchableError as e:
    echo fmt"error: can't delete trace {e.msg}"
    exitCode = 1
  finally:
    client.close()

  quit(exitCode)
