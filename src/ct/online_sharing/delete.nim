import std/[ os, httpclient, net, strformat, uri ]
import ../utilities/types
import ../../common/[ config, trace_index ]

proc deleteRemoteFile*(id: string, controlId: string, config: Config) {.raises: [ValueError, Exception].} =
  ## M-REC-2: ``id`` is now a UUIDv7 recording-id.  The column names
  ## in ``updateField`` track the new schema (``remote_share_*``
  ## snake_case) per parent spec §5.
  let test = false
  let client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))

  try:
    discard client.getContent(fmt"{parseUri(config.traceSharing.baseUrl) / config.traceSharing.deleteApi}?ControlId={controlId}")

    updateField(id, "remote_share_download_key", "", test)
    updateField(id, "remote_share_control_id", "", test)
    updateField(id, "remote_share_expire_time", -1, test)
  except CatchableError as e:
    raise newException(ValueError, "error: Can't delete trace")
  finally:
    client.close()

proc deleteTraceCommand*(id: string, controlId: string) =
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
