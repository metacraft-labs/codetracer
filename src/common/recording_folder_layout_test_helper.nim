## Subprocess helper for ``recording_folder_layout_test.nim`` (M-REC-7).
##
## Each scenario runs in a fresh ``XDG_DATA_HOME`` so ``paths.app`` /
## ``codetracerTraceDir`` resolve to a tmpdir.  The helper drives the
## actual recorder-side helpers (``paths.recordingFolder``,
## ``trace_index.newID`` / ``recordTrace`` / ``find`` / ``all``) the
## same way ``db_backend_record.record`` does, but without spawning a
## real language recorder — the contract under test is the folder
## naming convention, which is independent of which recorder produced
## the bytes inside the folder.
##
## Prints ``PASS`` on success, ``FAIL: <msg>`` and non-zero exit on
## failure.  Usage: ``recording_folder_layout_test_helper <scenario>``.

import std/[os, strutils]

import paths
import recording_id
import types
import lang
import trace_index

proc fail(msg: string) =
  echo "FAIL: ", msg
  quit(1)

proc expectCanonicalUuidV7(id: string) =
  ## Surface a clear error if ``newID`` ever returns something that
  ## fails the canonical-form validator; the rest of the M-REC-7
  ## contract assumes the id matches the on-disk folder name byte-for-byte.
  if id.len != UuidV7TextLen:
    fail("expected canonical 36-char UUIDv7 id; got len=" & $id.len &
         " value=" & id)
  if not recording_id.isCanonicalUuidV7(id):
    fail("expected canonical UUIDv7; got " & id)

proc scenarioRecordingFolderHelper() =
  ## Direct unit-level check on ``paths.recordingFolder``.  Asserts:
  ##  - the helper appends the id as a bare path component (no
  ##    ``trace-`` / ``trace_`` prefix, no integer suffix),
  ##  - the parent dir matches the ``baseDir`` argument,
  ##  - empty ids are rejected with an assertion (callers must mint a
  ##    UUIDv7 first).
  let baseDir = getTempDir() / "ct-rec-folder-helper-base"
  removeDir(baseDir)
  createDir(baseDir)
  defer: removeDir(baseDir)

  const syntheticId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  let folder = paths.recordingFolder(baseDir, syntheticId)

  if folder.parentDir != baseDir:
    fail("recordingFolder parent mismatch: got " & folder.parentDir &
         " expected " & baseDir)
  let last = folder.lastPathPart
  if last != syntheticId:
    fail("recordingFolder last component should equal the recording_id; " &
         "got " & last & " expected " & syntheticId)
  # Defensive: any reintroduced ``trace-`` / ``trace_`` prefix is the
  # exact regression M-REC-7 forbids.  Match both the pre-M-REC-2 form
  # (``trace_<int>``) and the M-REC-2..M-REC-6 transitional form
  # (``trace-<uuid>``).
  if last.startsWith("trace-") or last.startsWith("trace_"):
    fail("recordingFolder leaks legacy prefix in folder name: " & last)

  # Empty id must be rejected — callers must mint a UUIDv7 first.
  var rejected = false
  try:
    discard paths.recordingFolder(baseDir, "")
  except AssertionDefect:
    rejected = true
  if not rejected:
    fail("recordingFolder accepted empty recording_id; the assert is " &
         "load-bearing for keeping siblings from colliding at <baseDir>/")

  echo "PASS"

proc simulateRecording(): tuple[id: string, folder: string, trace: Trace] =
  ## Replay the exact sequence ``db_backend_record.record`` performs
  ## up to the moment the recorder process is started:
  ##  1. Mint a fresh recording id via ``trace_index.newID``.
  ##  2. Construct the output folder via ``paths.recordingFolder``.
  ##  3. ``createDir`` the folder.
  ##  4. Drop a trivial ``trace.ct`` placeholder so the folder shape
  ##     matches the post-M-REC-1.5 expectation (single ``.ct`` per
  ##     recording).  We do not exercise CTFS serialisation — the
  ##     contract under test is the folder name, not the bytes inside.
  ##  5. ``recordTrace`` writes the DB row so ``find``/``all`` can see it.
  let id = trace_index.newID(test = false)
  expectCanonicalUuidV7(id)

  let folder = paths.recordingFolder(codetracerTraceDir, id)
  createDir(folder)

  # Sentinel file so an inspection ``ls <folder>`` shows a recording-shaped
  # directory.  The bytes are irrelevant for M-REC-7's contract; they only
  # need to exist so the folder is not empty.
  writeFile(folder / "trace.ct", "M-REC-7 placeholder CTFS container\n")

  let trace = trace_index.recordTrace(
    id,
    program = "/tmp/simulated-program",
    args = @["--demo"],
    compileCommand = "",
    env = "",
    workdir = "/tmp",
    lang = LangNoir,
    sourceFolders = "",
    lowLevelFolder = "",
    outputFolder = folder,
    test = false,
    imported = false,
    shellID = -1,
    rrPid = 0,
    exitCode = 0,
    calltrace = true,
    calltraceMode = CalltraceMode.FullRecord)
  (id, folder, trace)

proc scenarioSimulatedRecording() =
  ## End-to-end deliverable #1: assert the folder name on disk is the
  ## bare UUIDv7, sitting directly under ``codetracerTraceDir``.
  let (id, folder, trace) = simulateRecording()

  if not dirExists(folder):
    fail("expected recording folder to exist at " & folder)
  if folder.parentDir != codetracerTraceDir:
    fail("folder must sit directly under codetracerTraceDir; got parent " &
         folder.parentDir & " expected " & codetracerTraceDir)
  if folder.lastPathPart != id:
    fail("folder name must equal recording_id; got " &
         folder.lastPathPart & " expected " & id)

  # Defensive against any future regression that reintroduces the prefix.
  let basename = folder.lastPathPart
  if basename.startsWith("trace-") or basename.startsWith("trace_"):
    fail("recorder regression: folder name still has the legacy prefix: " &
         basename)

  # The DB row must agree with the on-disk path.  This is what the
  # frontend reads (``trace.outputFolder``); a mismatch here means the
  # frontend opens a stale folder.
  if trace.recordingId != id:
    fail("DB row recording_id mismatch: got " & trace.recordingId &
         " expected " & id)
  if trace.outputFolder != folder:
    fail("DB row output_folder mismatch: got " & trace.outputFolder &
         " expected " & folder)

  # And the placeholder ``.ct`` we wrote must be inside.
  if not fileExists(folder / "trace.ct"):
    fail("placeholder trace.ct missing under " & folder)

  echo "PASS"

proc scenarioListFindsBareUuid() =
  ## End-to-end deliverable #2 (list side): ``ct list`` iterates
  ## ``trace_index.all`` and prints each row's ``outputFolder``.  The
  ## contract under test is that the row returned for our simulated
  ## recording carries the bare-UUID path verbatim.
  let (id, folder, _) = simulateRecording()
  let traces = trace_index.all(test = false)
  if traces.len < 1:
    fail("trace_index.all returned no rows; expected at least one")

  var matched = false
  for trace in traces:
    if trace.recordingId == id:
      matched = true
      if trace.outputFolder != folder:
        fail("trace_index.all returned wrong output_folder for " & id &
             ": got " & trace.outputFolder & " expected " & folder)
      if trace.outputFolder.lastPathPart != id:
        fail("trace_index.all returned non-bare-UUID folder for " & id &
             ": " & trace.outputFolder)
  if not matched:
    fail("trace_index.all did not return our recording_id " & id)

  echo "PASS"

proc scenarioReplayByRecordingId() =
  ## End-to-end deliverable #2 (replay side): ``ct replay <recording_id>``
  ## resolves the id via ``trace_index.find`` → ``trace.outputFolder``
  ## → ``launchElectron``.  Assert that ``find`` returns a row whose
  ## ``outputFolder`` is the bare-UUID directory created by the
  ## simulated recording — no reconstruction from a ``trace-<id>``
  ## template anywhere along the way.
  let (id, folder, _) = simulateRecording()
  let found = trace_index.find(id, test = false)
  if found.isNil:
    fail("trace_index.find returned nil for freshly recorded id " & id)
  if found.recordingId != id:
    fail("trace_index.find returned wrong recording_id: got " &
         found.recordingId & " expected " & id)
  if found.outputFolder != folder:
    fail("trace_index.find returned wrong output_folder: got " &
         found.outputFolder & " expected " & folder)
  if found.outputFolder.lastPathPart != id:
    fail("trace_index.find returned non-bare-UUID folder for " & id &
         ": " & found.outputFolder)

  # The folder must really be on disk where ``find`` says it is —
  # otherwise replay would crash when the renderer tries to load
  # ``trace.outputFolder / "files"``.
  if not dirExists(found.outputFolder):
    fail("trace_index.find returned a folder that does not exist on " &
         "disk: " & found.outputFolder)
  if not fileExists(found.outputFolder / "trace.ct"):
    fail("trace_index.find returned a folder without a trace.ct: " &
         found.outputFolder)

  echo "PASS"

when isMainModule:
  if paramCount() < 1:
    fail("usage: recording_folder_layout_test_helper <scenario>")
  case paramStr(1)
  of "recording-folder-helper": scenarioRecordingFolderHelper()
  of "simulated-recording": scenarioSimulatedRecording()
  of "list-finds-bare-uuid": scenarioListFindsBareUuid()
  of "replay-by-recording-id": scenarioReplayByRecordingId()
  else:
    fail("unknown scenario: " & paramStr(1))
