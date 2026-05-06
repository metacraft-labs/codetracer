import
  std / [ options, strformat, strutils, osproc, os, json, uri ],
  ../../common/[ types, trace_index, paths, lang ],
  storage_and_import,
  ctfs_sources,
  ../online_sharing/mcr_enrichment


# hosts a codetracer server that can be accessed in the browser
# codetracer host --port <port>
#        [--backend-socket-port <port>]
#        [--frontend-socket <port>]
#        [--frontend-socket-parameters <parameters>]
#        [--trace-path <path-to-.ct-file-or-trace-folder>]
#        <trace-id>/<trace-folder>

const
  DEFAULT_SOCKET_PORT: int = 5_000
  DEFAULT_IDLE_TIMEOUT_MS = 10 * 60 * 1_000
  IDLE_TIMEOUT_DISABLED = -1

type
  IdleTimeoutResult* = object
    ok*: bool
    value*: int
    error*: string

  HostStartCoordinates* = object
    traceId*: string
    spanId*: string
    geid*: string
    wallTimeUnixNs*: string
    monotonicTimeNs*: string
    materializedArtifactKey*: string
    materializedMomentId*: string

  HostResolvedTrace* = object
    traceId*: int
    start*: HostStartCoordinates

proc okResult(value: int): IdleTimeoutResult =
  IdleTimeoutResult(ok: true, value: value, error: "")

proc errResult(message: string): IdleTimeoutResult =
  IdleTimeoutResult(ok: false, value: 0, error: message)

proc parseIdleTimeoutMs*(raw: string): IdleTimeoutResult =
  ## Parse a human-friendly duration string into milliseconds.
  ## Supports suffixes: ms, s, m, h. Empty => default. 0/never/off => disabled.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return okResult(DEFAULT_IDLE_TIMEOUT_MS)

  let lower = trimmed.toLowerAscii()
  if lower in ["never", "off"]:
    return okResult(IDLE_TIMEOUT_DISABLED)

  var multiplier = 1_000
  var numberPart = lower
  if lower.endsWith("ms"):
    numberPart = lower[0 .. ^3]
    multiplier = 1
  elif lower.endsWith("s"):
    numberPart = lower[0 .. ^2]
    multiplier = 1_000
  elif lower.endsWith("m"):
    numberPart = lower[0 .. ^2]
    multiplier = 60_000
  elif lower.endsWith("h"):
    numberPart = lower[0 .. ^2]
    multiplier = 60 * 60 * 1_000

  var base = 0
  try:
    base = parseInt(numberPart)
  except CatchableError:
    return errResult(fmt"invalid idle timeout value: {raw}")

  if base < 0:
    return errResult(fmt"idle timeout must be non-negative: {raw}")
  if base == 0:
    return okResult(IDLE_TIMEOUT_DISABLED)

  return okResult(base * multiplier)

proc copyDirContents(srcDir, destDir: string) =
  ## Recursively copy all contents of srcDir into destDir.
  ## Creates destDir if it does not exist.
  createDir(destDir)
  for entry in walkDir(srcDir):
    let destPath = destDir / entry.path.extractFilename
    case entry.kind
    of pcFile, pcLinkToFile:
      copyFile(entry.path, destPath)
    of pcDir, pcLinkToDir:
      copyDirContents(entry.path, destPath)

proc importCtFile(ctFilePath: string): int =
  ## Import a standalone .ct file by creating a minimal trace folder
  ## around it and importing into the database.
  ##
  ## Copies the entire parent directory contents (not just the .ct file)
  ## so that companion files such as `binaries/` and source files are
  ## preserved. After copying, MCR trace enrichment is attempted via
  ## `ct-mcr export --portable` (best-effort — skipped when ct-mcr is
  ## not available).
  ##
  ## Returns the assigned trace ID.
  let tempDir = getTempDir() / "ct-host-" & $getCurrentProcessId()
  createDir(tempDir)

  # Copy the entire source directory into the temp folder so that
  # companion artifacts (binaries/, source files, etc.) are available
  # for enrichment and import.
  let sourceDir = ctFilePath.parentDir
  copyDirContents(sourceDir, tempDir)

  # Ensure the .ct file is named trace.ct for the import machinery.
  let ctFileName = ctFilePath.extractFilename
  if ctFileName != "trace.ct":
    let copiedCtPath = tempDir / ctFileName
    if fileExists(copiedCtPath):
      moveFile(copiedCtPath, tempDir / "trace.ct")

  # Attempt MCR trace enrichment (adds binaries and debug symbols to the
  # .ct container). This is best-effort: if ct-mcr is not found or the
  # file is not an MCR trace, we continue without enrichment.
  let enriched = enrichMcrTraceIfNeeded(tempDir)
  if enriched:
    echo "ct host: MCR trace enriched with portable binaries/symbols"

  let mcrVisualReplay = findCtFileInFolder(tempDir).len > 0

  # Create minimal trace_db_metadata.json so importTrace can read it
  # (only if enrichment or a prior recording step did not already produce one).
  # MCR CTFS containers can be extracted into a gfx_stream by ct-mcr, so mark
  # them as visual replay capable even before extraction has happened.
  if not fileExists(tempDir / "trace_db_metadata.json"):
    let metaJson = %*{
      "program": "imported",
      "args": newJArray(),
      "workdir": tempDir,
      "lang": "c",
      "visualReplay": mcrVisualReplay
    }
    writeFile(tempDir / "trace_db_metadata.json", $metaJson)
  elif mcrVisualReplay:
    try:
      let metaPath = tempDir / "trace_db_metadata.json"
      var metaJson = parseJson(readFile(metaPath))
      metaJson["visualReplay"] = %true
      writeFile(metaPath, $metaJson)
    except CatchableError:
      discard

  let ctfsSourcesExtracted = materializeCtfsSources(tempDir / "trace.ct", tempDir)
  if ctfsSourcesExtracted:
    echo "ct host: extracted CTFS source metadata"

  if not fileExists(tempDir / "trace_paths.json"):
    writeFile(tempDir / "trace_paths.json", "[]")

  # Copy source files into files/ subdirectory if not already present.
  # This mirrors the layout expected by the frontend for source display.
  if not dirExists(tempDir / "files"):
    for entry in walkDir(tempDir):
      if entry.kind == pcFile:
        let ext = entry.path.splitFile.ext.toLowerAscii
        if ext in [".c", ".cpp", ".h", ".hpp", ".rs", ".py", ".rb", ".nim", ".js", ".ts"]:
          let filesDir = tempDir / "files" / sourceDir.strip(chars = {'/'})
          createDir(filesDir)
          copyFile(entry.path, filesDir / entry.path.extractFilename)

  let trace = importTrace(
    tempDir,
    NO_TRACE_ID,
    NO_PID,
    LangUnknown,
    traceKind = "rr")
  if trace.isNil:
    echo "ct host: error: failed to import trace from ", ctFilePath
    quit(1)

  let importedCtPath = $trace.outputFolder / "trace.ct"
  if fileExists(tempDir / "trace.ct") and not fileExists(importedCtPath):
    copyFile(tempDir / "trace.ct", importedCtPath)

  result = trace.id


proc importTraceFolder(traceFolderPath: string): int =
  ## Import a trace folder into the database.
  ## The folder should contain trace_metadata.json or trace_db_metadata.json.
  ##
  ## If the folder contains an MCR trace (.ct file with CTFS magic),
  ## enrichment via `ct-mcr export --portable` is attempted first
  ## (best-effort).
  ##
  ## Returns the assigned trace ID.
  let fullPath = expandFilename(expandTilde(traceFolderPath))

  # Attempt MCR trace enrichment before import. This adds binaries and
  # debug symbols to the .ct container in-place. Best-effort: if ct-mcr
  # is not found or the folder has no MCR trace, this is a no-op.
  let enriched = enrichMcrTraceIfNeeded(fullPath)
  if enriched:
    echo "ct host: MCR trace enriched with portable binaries/symbols"

  let traceKind =
    if fileExists(fullPath / "trace_metadata.json"):
      "db"
    else:
      # Replay trace imports (RR/TTD) carry trace_db_metadata.json.
      "rr"

  let metaFile = if traceKind == "db":
      fullPath / "trace_metadata.json"
    else:
      fullPath / "trace_db_metadata.json"
  if not fileExists(metaFile):
    # For MCR trace folders that lack metadata, create a minimal one
    # so the import can proceed.
    if findCtFileInFolder(fullPath).len > 0:
      let metaJson = %*{
        "program": "imported",
        "args": newJArray(),
        "workdir": fullPath,
        "lang": "c"
      }
      writeFile(fullPath / "trace_db_metadata.json", $metaJson)
      if not fileExists(fullPath / "trace_paths.json"):
        writeFile(fullPath / "trace_paths.json", "[]")
    else:
      echo "ct host: error: trace folder missing metadata file: ", metaFile
      quit(1)

  let trace = importTrace(
    fullPath,
    NO_TRACE_ID,
    NO_PID,
    LangUnknown,
    traceKind = traceKind)
  if trace.isNil:
    echo "ct host: error: failed to import trace from folder ", traceFolderPath
    quit(1)

  result = trace.id

proc jsonField(node: JsonNode, names: openArray[string]): JsonNode =
  if node.isNil or node.kind != JObject:
    return nil
  for name in names:
    if node.hasKey(name) and node[name].kind != JNull:
      return node[name]
  nil

proc jsonString(node: JsonNode, names: openArray[string]): string =
  let field = node.jsonField(names)
  if field.isNil:
    return ""
  case field.kind
  of JString:
    field.getStr()
  of JInt:
    $field.getInt()
  else:
    ""

proc firstObject(node: JsonNode, names: openArray[string]): JsonNode =
  let field = node.jsonField(names)
  if field.isNil or field.kind != JArray or field.len == 0 or field[0].kind != JObject:
    return nil
  field[0]

proc fileUriToPath(value: string): string =
  if value.startsWith("file://"):
    try:
      return decodeUrl(parseUri(value).path)
    except CatchableError:
      return value["file://".len .. ^1]
  value

proc inferStorageRoot(manifestPath: string, manifestKey: string): string =
  let envRoot = getEnv("CODETRACER_LOCAL_STORAGE_ROOT", "")
  if envRoot.len > 0:
    return expandFilename(expandTilde(envRoot))
  if manifestKey.len > 0:
    let fullPath = expandFilename(expandTilde(manifestPath))
    let normalizedFull = fullPath.replace('\\', '/')
    let normalizedKey = manifestKey.replace('\\', '/')
    if normalizedFull.endsWith(normalizedKey):
      let rootLen = normalizedFull.len - normalizedKey.len
      if rootLen > 0:
        return normalizedFull[0 ..< rootLen]
  manifestPath.parentDir

proc resolveLocalReference(reference, manifestPath, manifestKey: string): string =
  let local = fileUriToPath(reference)
  if local.len == 0:
    return ""
  if isAbsolute(local):
    return expandFilename(expandTilde(local))
  let root = inferStorageRoot(manifestPath, manifestKey)
  let rooted = root / local
  if fileExists(rooted) or dirExists(rooted):
    return rooted
  manifestPath.parentDir / local

proc findMaterializedTraceFolder(path: string): string =
  let fullPath = expandFilename(expandTilde(path))
  if dirExists(fullPath):
    if fileExists(fullPath / "trace_metadata.json"):
      return fullPath
    for entry in walkDir(fullPath):
      if entry.kind in {pcDir, pcLinkToDir} and fileExists(entry.path / "trace_metadata.json"):
        return entry.path
  elif fileExists(fullPath):
    let parent = fullPath.parentDir
    if fullPath.extractFilename in ["trace.json", "trace.bin"] and
        fileExists(parent / "trace_metadata.json"):
      return parent
    if fullPath.endsWith(".ct"):
      return fullPath
  ""

proc applyReplayStartEnv(start: HostStartCoordinates) =
  if start.traceId.len > 0:
    putEnv("CODETRACER_START_TRACE_ID", start.traceId)
  if start.spanId.len > 0:
    putEnv("CODETRACER_START_SPAN_ID", start.spanId)
  if start.geid.len > 0:
    putEnv("CODETRACER_START_GEID", start.geid)
  if start.wallTimeUnixNs.len > 0:
    putEnv("CODETRACER_START_WALL_TIME_UNIX_NS", start.wallTimeUnixNs)
  if start.monotonicTimeNs.len > 0:
    putEnv("CODETRACER_START_MONOTONIC_TIME_NS", start.monotonicTimeNs)
  if start.materializedArtifactKey.len > 0:
    putEnv("CODETRACER_START_MATERIALIZED_ARTIFACT_KEY", start.materializedArtifactKey)
  if start.materializedMomentId.len > 0:
    putEnv("CODETRACER_START_MATERIALIZED_MOMENT_ID", start.materializedMomentId)

proc readReplayStart(node: JsonNode): HostStartCoordinates =
  if node.isNil or node.kind != JObject:
    return
  result.traceId = node.jsonString(["trace_id", "traceId"])
  result.spanId = node.jsonString(["span_id", "spanId"])
  result.geid = node.jsonString(["geid", "startGeid"])
  result.wallTimeUnixNs = node.jsonString(["wall_time_unix_ns", "wallTimeUnixNs", "timestamp_unix_nanos"])
  result.monotonicTimeNs = node.jsonString(["monotonic_time_ns", "monotonicTimeNs"])
  result.materializedMomentId = node.jsonString(["moment_id", "momentId", "materializedMomentId"])

proc parseUintOrZero(value: string): uint64 =
  if value.len == 0:
    return 0'u64
  try:
    parseBiggestInt(value).uint64
  except CatchableError:
    0'u64

proc resolveSharedManifest(manifestPath: string, manifest: JsonNode): HostResolvedTrace =
  let source = manifest.jsonField(["source"])
  if source.isNil or source.kind != JObject:
    raise newException(ValueError, "shared manifest missing source")
  let kind = source.jsonString(["kind"])
  let manifestKey = manifest.jsonString(["manifestS3Key", "manifest_s3_key"])
  let manifestStart = readReplayStart(manifest.jsonField(["replay_start", "replayStart"]))

  case kind
  of "single_ctfs":
    let fileNode = source.jsonField(["file"])
    if fileNode.isNil:
      raise newException(ValueError, "single_ctfs manifest missing file")
    let path = resolveLocalReference(fileNode.jsonString(["uri", "path", "object_id"]), manifestPath, manifestKey)
    if path.len == 0 or not fileExists(path):
      raise newException(ValueError, "single_ctfs local file not found: " & path)
    result.traceId = importCtFile(path)
    result.start = readReplayStart(source.jsonField(["replay_start", "replayStart"]))
    if result.start.traceId.len == 0 and result.start.geid.len == 0:
      result.start = manifestStart
  of "split_ctfs":
    let segments = source.jsonField(["segments"])
    if segments.isNil or segments.kind != JArray or segments.len == 0:
      raise newException(ValueError, "split_ctfs manifest missing segments")
    var start = readReplayStart(source.jsonField(["replay_start", "replayStart"]))
    if start.traceId.len == 0 and start.geid.len == 0:
      start = manifestStart
    let requestedGeid = parseUintOrZero(start.geid)
    var selected: JsonNode = nil
    for segment in segments:
      if segment.kind != JObject:
        continue
      if requestedGeid > 0:
        let geidStart = parseUintOrZero(segment.jsonString(["geid_start", "geidStart", "startGeid"]))
        let geidEnd = parseUintOrZero(segment.jsonString(["geid_end", "geidEnd", "endGeid"]))
        if requestedGeid >= geidStart and (geidEnd == 0'u64 or requestedGeid <= geidEnd):
          selected = segment
          break
      elif selected.isNil:
        selected = segment
    if selected.isNil:
      selected = segments[0]
    let fileNode = selected.jsonField(["file"])
    let path = resolveLocalReference(fileNode.jsonString(["uri", "path", "object_id"]), manifestPath, manifestKey)
    if path.len == 0 or not fileExists(path):
      raise newException(ValueError, "split_ctfs selected local file not found: " & path)
    result.traceId = importCtFile(path)
    result.start = start
  of "materialized_artifact":
    let artifactNode = source.jsonField(["artifact"])
    if artifactNode.isNil:
      raise newException(ValueError, "materialized_artifact manifest missing artifact")
    let path = resolveLocalReference(artifactNode.jsonString(["uri", "path", "object_id"]), manifestPath, manifestKey)
    let traceFolder = findMaterializedTraceFolder(path)
    if traceFolder.len == 0:
      raise newException(ValueError,
        "materialized artifact is not a hostable CodeTracer trace folder yet: " & path)
    if traceFolder.endsWith(".ct"):
      result.traceId = importCtFile(traceFolder)
    else:
      result.traceId = importTraceFolder(traceFolder)
    result.start = readReplayStart(source.jsonField(["replay_start", "replayStart"]))
    if result.start.traceId.len == 0 and result.start.materializedMomentId.len == 0:
      result.start = manifestStart
    result.start.materializedArtifactKey = artifactNode.jsonString(["object_id", "uri", "path"])
  of "sharded_split_ctfs":
    raise newException(ValueError, "local sharded_split_ctfs manifests are not supported until storage protocol support")
  else:
    raise newException(ValueError, "unsupported shared manifest source kind: " & kind)

proc resolveRecordingManifest(manifestPath: string, manifest: JsonNode): HostResolvedTrace =
  let kind = manifest.jsonString(["kind"])
  let manifestKey = manifest.jsonString(["manifestS3Key", "manifest_s3_key"])
  case kind
  of "mcr_slices":
    let slice = manifest.firstObject(["mcrSlices", "mcr_slices"])
    if slice.isNil:
      raise newException(ValueError, "mcr_slices manifest has no retained local slices")
    let path = resolveLocalReference(slice.jsonString(["sliceKey", "slice_key"]), manifestPath, manifestKey)
    if path.len == 0 or not fileExists(path):
      raise newException(ValueError, "local MCR slice not found: " & path)
    result.traceId = importCtFile(path)
    result.start = readReplayStart(manifest.jsonField(["replayStart", "replay_start"]))
  of "materialized_trace":
    let artifact = manifest.firstObject(["materializedTraceArtifacts", "materialized_trace_artifacts"])
    if artifact.isNil:
      raise newException(ValueError, "materialized_trace manifest has no local artifacts")
    let path = resolveLocalReference(artifact.jsonString(["artifactKey", "artifact_key"]), manifestPath, manifestKey)
    let traceFolder = findMaterializedTraceFolder(path)
    if traceFolder.len == 0:
      raise newException(ValueError,
        "materialized artifact is not a hostable CodeTracer trace folder yet: " & path)
    if traceFolder.endsWith(".ct"):
      result.traceId = importCtFile(traceFolder)
    else:
      result.traceId = importTraceFolder(traceFolder)
    result.start = readReplayStart(artifact.jsonField(["replayStart", "replay_start"]))
    if result.start.materializedMomentId.len == 0:
      result.start = readReplayStart(manifest.jsonField(["replayStart", "replay_start"]))
    result.start.materializedArtifactKey = artifact.jsonString(["artifactKey", "artifact_key"])
  else:
    raise newException(ValueError, "unsupported recording manifest kind: " & kind)

proc importLocalManifest(manifestPath: string): HostResolvedTrace =
  let fullPath = expandFilename(expandTilde(manifestPath))
  let manifest = parseJson(readFile(fullPath))
  if manifest.jsonString(["schema"]) == "codetracer.trace-storage.v1":
    result = resolveSharedManifest(fullPath, manifest)
  else:
    result = resolveRecordingManifest(fullPath, manifest)
  applyReplayStartEnv(result.start)
  echo "ct host: loaded local manifest: ", fullPath


proc hostCommand*(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string,
    idleTimeoutRaw: string,
    tracePath: string = "",
    manifestPath: string = "") =

  putEnv("NODE_PATH", nodeModulesPath)
  putEnv("CODETRACER_PREFIX", codetracerPrefix)

  let isSetBackendSocketPort = backendSocketPort.isSome
  let isSetFrontendSocketPort = frontendSocketPort.isSome
  let backendSocketPort = if backendSocketPort.isSome:
      backendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  let frontendSocketPort = if frontendSocketPort.isSome:
      frontendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  var traceId = -1
  let envIdleTimeout = getEnv("CODETRACER_HOST_IDLE_TIMEOUT", "")
  let parsedIdleTimeout = parseIdleTimeoutMs(
    if idleTimeoutRaw.len > 0: idleTimeoutRaw else: envIdleTimeout)
  if not parsedIdleTimeout.ok:
    echo "ct host: error: ", parsedIdleTimeout.error
    quit(1)
  let idleTimeoutMs = parsedIdleTimeout.value

  if port < 0:
    echo fmt"ct host: error: no valid port specified: {port}"
    quit(1)

  if isSetBackendSocketPort and not isSetFrontendSocketPort or
      not isSetBackendSocketPort and isSetFrontendSocketPort:
    echo "ct host: error: pass either both backend and frontend port or neither"
    quit(1)

  let localManifestPath =
    if manifestPath.len > 0:
      manifestPath
    elif tracePath.len > 0 and fileExists(tracePath) and tracePath.endsWith(".json"):
      tracePath
    elif getEnv("CODETRACER_LOCAL_MANIFEST_PATH", "").len > 0:
      getEnv("CODETRACER_LOCAL_MANIFEST_PATH")
    else:
      ""

  if localManifestPath.len > 0:
    try:
      let resolved = importLocalManifest(localManifestPath)
      traceId = resolved.traceId
      echo "ct host: imported manifest trace as trace id ", traceId
    except CatchableError as e:
      echo "ct host: error: failed to load local manifest: ", e.msg
      quit(1)
  elif tracePath.len > 0:
    # --trace-path provided: auto-import the trace before hosting.
    if fileExists(tracePath) and tracePath.endsWith(".ct"):
      echo "ct host: importing .ct file: ", tracePath
      traceId = importCtFile(tracePath)
      echo "ct host: imported as trace id ", traceId
    elif dirExists(tracePath):
      echo "ct host: importing trace folder: ", tracePath
      traceId = importTraceFolder(tracePath)
      echo "ct host: imported as trace id ", traceId
    else:
      echo "ct host: error: --trace-path not found: ", tracePath
      quit(1)
  elif traceArg.len > 0:
    try:
      traceId = traceArg.parseInt
    except CatchableError:
      # probably traceId is a folder
      # TODO don't depend on db?
      let traceFolder = traceArg
      var traceFolderFullPath = ""
      try:
        traceFolderFullPath = expandFilename(expandTilde(traceFolder))
      except OsError as e:
        echo "ct host error: folder os error: ", e.msg
        quit(1)
      var trace = trace_index.findByPath(traceFolderFullPath, test=false)
      if trace.isNil:
        trace = trace_index.findByPath(traceFolderFullPath & "/", test=false)
        if trace.isNil:
          echo "ct host error: trace not found: maybe you should import it first"
          quit(1)
      traceId = trace.id
  else:
    echo "ct host: error: no trace specified. " &
      "Provide a trace ID or folder as a positional argument, " &
      "or use --trace-path to auto-import a .ct file or trace folder."
    quit(1)

  let callerPid = getCurrentProcessId()
  echo "server index ", codetracerExeDir
  var process = startProcess(
    nodeExe,
    workingDir = codetracerInstallDir,
    args = @[
      codetracerExeDir / "server_index.js",
      $traceId,
      "--port",
      $port,
      "--frontend-socket-port",
      $frontendSocketPort,
      "--frontend-socket-parameters",
      frontendSocketParameters,
      # "--backend-socket-host",
      # backendSocketHost,
      "--backend-socket-port",
      $backendSocketPort,
      "--caller-pid",
      $callerPid,
      "--idle-timeout-ms",
      $idleTimeoutMs
    ],
    options={poParentStreams})
  var electronPid = process.processID
  echo "status code:", waitForExit(process)
