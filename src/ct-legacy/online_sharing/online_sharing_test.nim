import std/[ unittest, os, strutils, options ]
import ./[ upload, download, delete ]
import ../../common/config
import ../trace/shell

let conf = loadConfig(folder=getCurrentDir(), inTest=false)

suite "Trace Sharing Commands":

  # At least one trace recording needs to be present
  test "Upload, download, delete trace":
    echo "Uploading"
    let traceId = 0
    let trace = findTraceForArgs(none(string), some(traceId), none(string))
    if trace.isNil:
      echo "ERROR: can't find trace in local database"
      quit(1)
    let info = uploadTrace(trace, conf)

    check info.controlId.len > 0
    check info.downloadKey.len > 0

    echo "\nDownloading"
    let (fileId, password) = extractInfoFromKey(info.downloadKey, conf)
    let newId = downloadTrace(fileId, info.downloadKey, password, conf)
    echo "Downloaded trace ID: ", newId
    check newId >= 0

    echo "Deleting"
    deleteRemoteFile(traceId, info.controlId, conf)
    expect Exception:
      discard downloadTrace(fileId, info.downloadKey, password, conf)
