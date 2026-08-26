## NEVER RUN, ALWAYS COMPILED.
##
## This suite performs a LIVE upload / download round-trip against the
## production sharing service, so no automated runner may execute it. It used to
## say "not part of any automated test runner" and stop there -- and with
## nothing looking at it at all it rotted into a file that did not compile
## (``findTraceForArgs`` matched no current signature, and ``extractInfoFromKey``
## no longer existed).
##
## So it is now COMPILE-CHECKED, by `just test-online-sharing-compile`
## (lane `online-sharing-live` in ci/lib/test-lane-files.sh, which runs the
## shared runner with --compile-only). A compile is the weakest check that
## would have caught the rot, and it costs seconds.
##
## AS-2 brought the call sites back up to date (`Artifact-Store.md` §8, defect
## 5), which is what turned this lane green. Three of them had to change, and
## each change is a fact about the current API rather than a spelling fix:
##
## * ``uploadTrace`` now **returns** its result instead of ending every path in
##   ``quit(...)`` (§8 defect 2), so a caller — this suite included — can look
##   at what happened.
## * ``UploadedInfo`` carries an ``artifactId`` and a ``shareUrl`` rather than a
##   ``fileId`` that held one of two namespaces (§8 defect 11) and a
##   ``downloadKey`` nothing assigned (§8 defect 3). ``ct download`` takes the
##   share link, so the round trip is upload → link → download with no
##   key-decoding step in between; ``extractInfoFromKey`` is gone because the
##   thing it decoded is gone.
## * ``deleteRemoteFile`` reaches a *different* service from the ``/api/v1/``
##   family (`Artifact-Store.md` §1, correction 3) and its ``controlId`` comes
##   from the local trace row rather than from an upload result, so the delete
##   leg reads it from there.

import std/[ unittest, os, strutils, options ]
import ./[ upload, download, delete ]
# `UploadedInfo` and the `ArtifactKind` its `kind` field names.
import ../utilities/types
import ../../common/config
import ../trace/shell

let conf = loadConfig(folder=getCurrentDir(), inTest=false)

suite "Artifact sharing round-trip (LIVE — never run automatically)":

  # At least one trace recording needs to be present.
  test "upload a recording, download it back from its link, then delete it":
    echo "Uploading"
    # M-REC-8: ``recordingId`` is a UUIDv7 recording-id string.  The
    # placeholder below keeps the shape obvious; a real run needs a real id.
    let recordingId = ""
    let trace = findTraceForArgs(none(string), some(recordingId), none(string))
    if trace.isNil:
      echo "ERROR: can't find trace in local database"
      quit(1)

    let info = uploadTrace(trace, none(string))
    check info.exitCode == 0
    check info.kind == akRecording
    check info.artifactId.len > 0
    # A link is issued only when the service named the artifact back; the
    # sliced recording path does not get one (see `upload.nim`), so this is
    # the single-file expectation.
    check info.shareUrl.len > 0

    echo "\nDownloading"
    let newId = downloadTrace(info.shareUrl)
    echo "Downloaded recording id: ", newId
    check newId.len > 0

    echo "Deleting"
    deleteRemoteFile($trace.recordingId, $trace.controlId, conf)
    expect Exception:
      discard downloadTrace(info.shareUrl)
