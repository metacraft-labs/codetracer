import std/[ os, httpclient, net, strformat, uri ]
import ../utilities/types
import ../../common/[ config, trace_index ]

proc deleteRemoteFile*(id: int, controlId: string, config: Config) {.raises: [ValueError, Exception].} =
  let test = false
  let client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))

  try:
    discard client.getContent(fmt"{parseUri(config.traceSharing.baseUrl) / config.traceSharing.deleteApi}?ControlId={controlId}")

    updateField(id, "remoteShareDownloadKey", "", test)
    updateField(id, "remoteShareControlId", "", test)
    updateField(id, "remoteShareExpireTime", -1, test)
  except CatchableError as e:
    raise newException(ValueError, "error: Can't delete trace")
  finally:
    client.close()

proc deleteTraceCommand*(id: int, controlId: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharing.enabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  try:
    deleteRemoteFile(id, controlId, config)
  except CatchableError as e:
    echo e.msg
    quit(1)

  quit(0)
