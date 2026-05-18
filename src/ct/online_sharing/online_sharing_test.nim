import std/[ unittest, os, strutils, options ]
import ./[ upload, download, delete ]
import ../../common/config
import ../trace/shell

let conf = loadConfig(folder=getCurrentDir(), inTest=false)

suite "Trace Sharing Commands":

  # At least one trace recording needs to be present
  test "Upload, download, delete trace":
    echo "Uploading"
    # M-REC-8: ``recordingId`` is a UUIDv7 recording-id string.  This
    # test is not part of any automated test runner (no Tupfile /
    # justfile reference); the placeholder below keeps it compilable.
    let recordingId = ""
    let trace = findTraceForArgs(none(string), some(recordingId), none(string))
    if trace.isNil:
      echo "ERROR: can't find trace in local database"
      quit(1)
    let info = uploadTrace(trace, conf)

    check info.controlId.len > 0
    check info.downloadKey.len > 0

    echo "\nDownloading"
    let (fileId, password) = extractInfoFromKey(info.downloadKey, conf)
    let newId = downloadTrace(fileId, info.downloadKey, password, conf)
    echo "Downloaded recording id: ", newId
    # M-REC-8: id is a UUIDv7 string now; check it's non-empty.
    check newId.len > 0

    echo "Deleting"
    deleteRemoteFile(recordingId, info.controlId, conf)
    expect Exception:
      discard downloadTrace(fileId, info.downloadKey, password, conf)
