## NEVER RUN, ALWAYS COMPILED.
##
## This suite performs a LIVE upload / download / delete round-trip against the
## production sharing service, so no automated runner may execute it. It used to
## say "not part of any automated test runner" and stop there -- and with
## nothing looking at it at all it rotted into a file that does not compile
## (``findTraceForArgs`` below matches no current signature, and
## ``extractInfoFromKey`` no longer exists).
##
## So it is now COMPILE-CHECKED, by `just test-online-sharing-compile`
## (lane `online-sharing-live` in ci/lib/test-lane-files.sh, which runs the
## shared runner with --compile-only). A compile is the weakest check that
## would have caught the rot, and it costs seconds. The lane is red until the
## call sites below are brought up to date.

import std/[ unittest, os, strutils, options ]
import ./[ upload, download, delete ]
import ../../common/config
import ../trace/shell

let conf = loadConfig(folder=getCurrentDir(), inTest=false)

suite "Trace Sharing Commands":

  # At least one trace recording needs to be present
  test "Upload, download, delete trace":
    echo "Uploading"
    # M-REC-8: ``recordingId`` is a UUIDv7 recording-id string.  The
    # placeholder below keeps the shape obvious; a real run needs a real id.
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
