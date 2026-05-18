import std/[ os, httpclient, net, strformat, uri ]
import ../utilities/types
import ../../common/[ config, trace_index ]

proc deleteRemoteFile*(id: string, controlId: string, config: Config) {.raises: [ValueError, Exception].} =
  ## M-REC-2 / M-REC-8: ``id`` is the UUIDv7 ``recording_id`` of the
  ## locally stored copy of the trace whose remote-share columns we are
  ## clearing.  ``controlId`` is the server-issued access token used to
  ## authenticate the remote delete; the two ids live in distinct
  ## namespaces (see parent spec §6.7).  The column names in
  ## ``updateField`` track the post-M-REC-2 schema (``remote_share_*``
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
