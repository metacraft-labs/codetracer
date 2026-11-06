## Filesystem lookup shared by headless recording suites.

import std/[os, strutils]
import ../../common/ct_home

proc findCtFile(dir: string): string =
  ## Return the path to the first ``.ct`` file in ``dir``, or "" if none.
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    if path.endsWith(".ct"):
      return path
  return ""

proc isUsableTraceDir*(dir: string): bool =
  ## Return true if ``dir`` contains a trace format that the replay-server
  ## can open via the DAP stdio protocol and that works with
  ## HeadlessDebugSession.
  ##
  ## Supported formats:
  ##   - ``trace.bin`` — DB-based materialized trace (used by Noir, Wasm, and
  ##     older Python/Ruby recorders)
  ##   - ``rr/`` subdirectory — rr-based trace replayed via ct-native-replay
  ##     (used by Nim, Rust, C, etc.)
  ##   - CTFS ``.ct`` files — CTFS containers produced by Python, Ruby, and
  ##     other recorders.  The replay-server auto-detects the format and emits
  ##     the same ``stopped``/``ct/complete-move`` DAP events as DB traces.
  if fileExists(dir / "trace.bin"):
    return true
  if dirExists(dir / "rr"):
    return true
  if findCtFile(dir).len > 0:
    return true
  return false

proc traceDirForRecordingId*(idStr: string): string =
  let baseDir = ctDataDir()
  let bareDir = baseDir / idStr
  if dirExists(bareDir):
    return bareDir
  let legacyDir = baseDir / ("trace-" & idStr)
  if dirExists(legacyDir):
    return legacyDir
  bareDir

proc findExistingTrace*(programPattern: string): string =
  ## Search the active CodeTracer data directory for a pre-recorded trace whose
  ## directory name matches ``programPattern``.
  ##
  ## M-REC-1.5: trace metadata lives in the CTFS ``meta.dat`` inside
  ## ``trace.ct``; the legacy sidecar JSONs that this helper used to
  ## inspect are retired.  As a lightweight fallback the heuristic
  ## matches against the directory name (recorders name the directory
  ## after the program).  Re-record if a finer match is needed.
  let baseDir = ctDataDir()
  if not dirExists(baseDir):
    return ""
  for kind, path in walkDir(baseDir):
    if kind != pcDir:
      continue
    if not isUsableTraceDir(path):
      continue
    let dirname = path.extractFilename()
    if programPattern in dirname:
      return path
  return ""

type RecordingArtifactError* = object of CatchableError
  ## A successful recorder violated its output/artifact contract. Availability
  ## handlers catch IO/OSError only, so this must remain a distinct failure.

proc recordingDirFromOutput*(output: string): string =
  ## Resolve the identifier emitted by a successful `ct record` invocation.
  ## Missing output/artifacts are contract failures, not recorder availability:
  ## callers must never turn these errors into skipped tests or fallback traces.
  for line in output.splitLines():
    if line.startsWith("recordingId:"):
      let idStr = line[("recordingId:").len..^1].strip()
      if idStr.len == 0:
        raise newException(RecordingArtifactError,
          "ct record succeeded but recordingId is empty: " & output)
      let traceDir = traceDirForRecordingId(idStr)
      if not dirExists(traceDir):
        raise newException(RecordingArtifactError,
          "ct record succeeded but recording " & idStr &
          " was not found at " & traceDir & ": " & output)
      if not isUsableTraceDir(traceDir):
        raise newException(RecordingArtifactError,
          "ct record succeeded but recording at " & traceDir &
          " uses an unrecognized format. Expected trace.bin, rr/, or a .ct file.")
      return traceDir
  raise newException(RecordingArtifactError,
    "ct record succeeded but recordingId is missing from output: " & output)
