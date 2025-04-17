import std/[ os, httpclient, net, strformat, uri ]
import ../utilities/env
import ../../common/[ config, trace_index ]

proc deleteRemoteFile(id: int, controlId: string, config: Config) {.raises: [ValueError, LibraryError, SslError, Exception].} =
  let test = false
  var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))

  try:
    discard client.getContent(fmt"{parseUri(config.`base-url`) / config.`delete-api`}?ControlId={controlId}")

    updateField(id, "remoteShareDownloadKey", "", test)
    updateField(id, "remoteShareControlId", "", test)
    updateField(id, "remoteShareExpireTime", -1, test)
  except CatchableError as e:
    raise newException(ValueError, "error: Can't delete trace")
  finally:
    client.close()

  quit(0)


proc deleteTraceCommand*(id: int, controlId: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.`trace-sharing-enabled`:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  try:
    deleteRemoteFile(id, controlId, config)
  except CatchableError as e:
    echo e.msg
    quit(1)

  quit(0)
