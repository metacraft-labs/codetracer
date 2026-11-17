## The fixture cache's whole-entry rule (`ct_stages.isWholeCachedRecording`):
## an entry `ct record` has not finished, or one that names its program under
## a `.partial` staging folder (the stage recorded there before it recorded in
## place) or at a path that is gone, is absent, and the next run records again.
## Run by `ci/test/scenarios.sh stage-test`.
import std/[os, unittest]
import ./ct_stages

suite "the fixture cache's whole entries":
  let root = getTempDir() / "ct-stage-cache-test-" & $getCurrentProcessId()
  setup:
    removeDir(root)
    createDir(root)
  teardown:
    removeDir(root)

  test "a recording with no marker is whole; with the in-progress marker it is absent":
    let dest = root / "rec-scenario"
    createDir(dest / "rr")           # a shape isUsableTraceDir accepts
    check isWholeCachedRecording(dest)
    writeFile(recordingIncompleteMarker(dest), "in progress")
    check not isWholeCachedRecording(dest)
    removeFile(recordingIncompleteMarker(dest))
    check isWholeCachedRecording(dest)

  test "a program under a .partial folder, or gone, is stale; one that exists is not":
    let staged = root / "rec-scenario.partial"
    createDir(staged)
    writeFile(staged / "prog", "")
    check staleRecordedProgram(staged / "prog")          # exists, but staged
    check staleRecordedProgram(root / "gone" / "prog")   # absolute, missing
    let kept = root / "rec-scenario"
    createDir(kept)
    writeFile(kept / "prog", "")
    check not staleRecordedProgram(kept / "prog")
    check not staleRecordedProgram("")
