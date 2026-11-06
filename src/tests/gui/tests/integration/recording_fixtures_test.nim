## Exercise the actual shared fixture lookup on real scratch directories.
## No recorder or replay adapter is mocked: this tests the filesystem boundary
## after `ct record` has published a recording identifier.
import std/[os, strutils, unittest]
import ../../../../frontend/test_support/recording_fixtures
import ../../../../common/ct_home

suite "Headless recording fixture lookup":
  test "recording id resolves within CODETRACER_HOME data":
    let expected = ctDataDir() / "fixture-recording-id"
    createDir(expected)
    defer: removeDir(expected)
    check traceDirForRecordingId("fixture-recording-id") == expected

  test "existing usable recording is found inside CODETRACER_HOME":
    let expected = ctDataDir() / "fixture-program-recording"
    createDir(expected)
    writeFile(expected / "trace.ct", "fixture")
    defer: removeDir(expected)
    check findExistingTrace("fixture-program") == expected

  test "legacy trace prefix resolves within CODETRACER_HOME":
    let expected = ctDataDir() / "trace-fixture-legacy-id"
    createDir(expected)
    defer: removeDir(expected)
    check traceDirForRecordingId("fixture-legacy-id") == expected

  test "successful recorder missing artifact fails outside availability catches":
    try:
      discard recordingDirFromOutput("recordingId:missing-fixture-id\n")
      check false
    except IOError, OSError:
      check false # The callers would turn this into an unavailable-recorder skip.
    except RecordingArtifactError as error:
      check "missing-fixture-id" in error.msg
      check ctDataDir() / "missing-fixture-id" in error.msg
      check "not found" in error.msg

  test "successful recorder missing id fails outside availability catches":
    try:
      discard recordingDirFromOutput("recording completed without an identifier\n")
      check false
    except IOError, OSError:
      check false
    except RecordingArtifactError as error:
      check "recordingId" in error.msg
      check "missing" in error.msg

  test "successful recorder output resolves its published id":
    let expected = ctDataDir() / "fixture-output-id"
    createDir(expected)
    writeFile(expected / "trace.ct", "fixture")
    defer: removeDir(expected)
    check recordingDirFromOutput("recorder progress\nrecordingId: fixture-output-id \n") == expected

  test "empty recording id does not identify the data root":
    createDir(ctDataDir())
    expect RecordingArtifactError:
      discard recordingDirFromOutput("recordingId:   \n")

  test "successful recorder with an unusable artifact cannot skip":
    let expected = ctDataDir() / "fixture-unusable-id"
    createDir(expected)
    defer: removeDir(expected)
    try:
      discard recordingDirFromOutput("recordingId:fixture-unusable-id\n")
      check false
    except IOError, OSError:
      check false
    except RecordingArtifactError as error:
      check expected in error.msg
      check "unrecognized format" in error.msg
