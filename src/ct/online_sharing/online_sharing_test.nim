import std/[ unittest, os, strutils, options, json ]
import ./[ upload, download, delete ]
import ../../common/config
import ../trace/shell
from stew / byteutils import toBytes
import streams, nimcrypto, zip/zipfiles, std/[ enumerate, terminal, options, sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang ]
from stew / byteutils import toBytes
import ../utilities/[ env, encryption, zip, language_detection ]
import ../trace/storage_and_import, ../globals

let conf = loadConfig(folder=getCurrentDir(), inTest=false)

proc runUploadCommand*(traceId: int): UploadedInfo {.raises: [CatchableError, Exception].} =
  let trace = findTraceForArgs(none(string), some(traceId), none(string))
  let info = uploadTrace(trace, conf)
  return info

proc runDownloadTrace*(downloadKey: string): int {.raises: [CatchableError, Exception].} =
  let stringSplit = downloadKey.split("//")
  if stringSplit.len() != 3:
    echo "error: Invalid download key! Should be <program_name>//<file_id>//<encryption_password>"
    quit(1)

  let fileId = stringSplit[1]
  let passwordHex = stringSplit[2]

  var password: array[32, byte]
  hexToBytes(passwordHex, password)

  let newId = downloadTrace(fileId, downloadKey, password, conf)
  echo "Downloaded trace ID: ", newId
  return newId

proc runDeleteTrace*(id: int, controlId: string) {.raises: [CatchableError, Exception].} =
  if not conf.traceSharingEnabled:
    raise newException(ValueError, TRACE_SHARING_DISABLED_ERROR_MESSAGE)
  deleteRemoteFile(id, controlId, conf)

suite "Trace Sharing Commands":

  test "Upload, download, delete trace":
    let info = runUploadCommand(0)
    check info.controlId.len > 0
    check info.downloadKey.len > 0

    let newId = runDownloadTrace(info.downloadKey)
    check newId >= 0

    runDeleteTrace(0, info.controlId)
