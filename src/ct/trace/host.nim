import
  std / [ options, strformat, strutils, osproc, os, json, uri, httpclient ],
  ../../common/[ types, trace_index, paths, lang ],
  storage_and_import,
  ctfs_sources,
  source_paths,
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
  LOCAL_STORAGE_PROTOCOL = "local-storage"
  REPLAY_PROBLEM_MARKER = "CODETRACER_REPLAY_PROBLEM"

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
    # M-REC-2: ``traceId`` is the local *recording_id* (UUIDv7 string),
    # NOT the OTel W3C trace_id in ``HostStartCoordinates`` above.  The
    # identifier-name disambiguation (rename to ``recordingId``) is M-REC-3
    # scope; here we only flip the type.
    traceId*: string
    start*: HostStartCoordinates

  StorageProtocolOptions* = object
    baseUrl*: string
    tenantId*: string
    token*: string
    protocol*: string

proc okResult(value: int): IdleTimeoutResult =
  IdleTimeoutResult(ok: true, value: value, error: "")

proc errResult(message: string): IdleTimeoutResult =
  IdleTimeoutResult(ok: false, value: 0, error: message)

proc isStorageFailureMessage(message: string): bool =
  ## Keep this classifier aligned with the local-storage CTFS read errors below.
  ## ReplayAgent treats REPLAY_PROBLEM_MARKER as the stable bridge contract; this
  ## text classifier is a narrow fallback until ct host carries typed failures.
  let lower = message.toLowerAscii()
  lower.contains("storage read failed") or
    lower.contains("storage protocol error") or
    lower.contains("no readable ctfs shard replica") or
    (lower.contains("failed to load local manifest") and
      lower.contains("/trace-storage")) or
    (lower.contains("no such file or directory") and
      lower.contains("/trace-storage"))

proc replayProblemJson(code, title, detail: string): string =
  $(%*{
    "type": "about:blank",
    "title": title,
    "status": 424,
    "detail": detail,
    "code": code
  })

proc emitReplayProblemForHostFailure(message: string) =
  if isStorageFailureMessage(message):
    echo REPLAY_PROBLEM_MARKER, " ", replayProblemJson(
      "storage_failure",
      "Storage failure",
      "Replay storage objects could not be read from any available replica.")
    flushFile(stdout)

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

proc normalizedForCompare(path: string): string =
  path.replace('\\', '/').strip(leading = false, trailing = true, chars = {'/'})

proc pathInside(path, root: string): bool =
  let normalizedPath = normalizedForCompare(path)
  let normalizedRoot = normalizedForCompare(root)
  normalizedPath == normalizedRoot or normalizedPath.startsWith(normalizedRoot & "/")

proc dropFilesPrefix(path: string): string =
  let normalized = path.replace('\\', '/')
  if normalized.startsWith("files/"):
    normalized["files/".len .. ^1]
  else:
    normalized

proc safeFileExists(path: string): bool =
  try:
    fileExists(path)
  except OSError:
    false

proc materializeImportedTracePath(tempDir, sourcePath, payloadPath: string): bool =
  if payloadPath.len == 0 or payloadPath.startsWith(".."):
    return false

  let targetPath = tempDir / "files" / payloadPath
  let payloadFileName = sourcePath.extractFilename
  let effectiveSourcePath =
    if safeFileExists(sourcePath):
      sourcePath
    elif payloadFileName in ["trace.bin", "trace.json"] and
        safeFileExists(tempDir / payloadFileName):
      tempDir / payloadFileName
    else:
      sourcePath

  if safeFileExists(effectiveSourcePath) and
      normalizedForCompare(effectiveSourcePath) != normalizedForCompare(targetPath):
    try:
      createDir(targetPath.parentDir)
      copyFile(effectiveSourcePath, targetPath)
    except CatchableError as e:
      echo fmt"WARNING: trying to copy trace path {effectiveSourcePath} error: ", e.msg
      echo "  skipping copying that file"

  safeFileExists(targetPath)

proc normalizeImportedTracePaths(tempDir: string) =
  ## Local manifest imports copy companion files into a transient trace folder.
  ## Make trace_paths.json point at the self-contained files/ payload so the
  ## imported trace remains browsable after the manifest temp directory is gone.
  let tracePathsPath = tempDir / "trace_paths.json"
  if not fileExists(tracePathsPath):
    writeFile(tracePathsPath, "[]")
    return

  var rawPaths: seq[string] = @[]
  try:
    let tracePathsJson = parseJson(readFile(tracePathsPath))
    if tracePathsJson.kind == JArray:
      for pathNode in tracePathsJson:
        if pathNode.kind == JString:
          rawPaths.add(pathNode.getStr())
  except CatchableError as e:
    echo "WARNING: failed to parse trace_paths.json for local import: ", e.msg
    return

  var normalizedPaths: seq[string] = @[]
  for rawPath in rawPaths:
    if rawPath.len == 0:
      continue

    let rawFileName = rawPath.replace('\\', '/').extractFilename
    if rawFileName in ["trace.bin", "trace.json"] and safeFileExists(tempDir / rawFileName):
      normalizedPaths.add(rawFileName)
      continue

    var sourcePath = rawPath
    var payloadPath = rawPath
    if isAbsoluteTracePath(rawPath):
      if pathInside(rawPath, tempDir):
        payloadPath = dropFilesPrefix(relativePath(rawPath, tempDir))
      else:
        payloadPath = tracePayloadRelativePath(rawPath, "")
    else:
      sourcePath = tempDir / rawPath
      payloadPath = dropFilesPrefix(rawPath)

    if materializeImportedTracePath(tempDir, sourcePath, payloadPath):
      normalizedPaths.add(payloadPath.replace('\\', '/'))
    else:
      normalizedPaths.add(rawPath)

  writeFile(tracePathsPath, $(%normalizedPaths))

proc importCtFile(ctFilePath: string): string =
  ## M-REC-2: returns the recording_id (UUIDv7 string) of the imported
  ## trace.  Previously returned an ``int`` from the legacy ``trace.id``.
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

  # Create minimal trace_db_metadata.json so importTrace can read it
  # (only if enrichment or a prior recording step did not already produce one).
  if not fileExists(tempDir / "trace_db_metadata.json"):
    let metaJson = %*{
      "program": "imported",
      "args": newJArray(),
      "workdir": tempDir,
      "lang": "c"
    }
    writeFile(tempDir / "trace_db_metadata.json", $metaJson)

  let ctfsSourcesExtracted = materializeCtfsSources(tempDir / "trace.ct", tempDir)
  if ctfsSourcesExtracted:
    echo "ct host: extracted CTFS source metadata"

  if not fileExists(tempDir / "trace_paths.json"):
    writeFile(tempDir / "trace_paths.json", "[]")

  normalizeImportedTracePaths(tempDir)

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


proc importTraceFolder(traceFolderPath: string): string =
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

  normalizeImportedTracePaths(fullPath)

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
  ## Resolve `path` to a directory holding a CTFS materialized trace, or to
  ## the `.ct` container itself when the user passes the file path directly.
  ## Materialized traces are CTFS-only: any folder must contain at least one
  ## `*.ct` file (legacy `trace_metadata.json`/`trace.bin`/`trace.json`
  ## sidecar bundles are no longer accepted).
  if path.len == 0:
    return ""
  let fullPath = try:
      expandFilename(expandTilde(path))
    except OSError:
      expandTilde(path)
  let isDir = try:
      dirExists(fullPath)
    except OSError:
      false
  let isFile = try:
      fileExists(fullPath)
    except OSError:
      false

  proc dirHasCtFile(dir: string): bool =
    for entry in walkDir(dir):
      if entry.kind == pcFile and entry.path.endsWith(".ct"):
        return true
    false

  if isDir:
    if dirHasCtFile(fullPath):
      return fullPath
    for entry in walkDir(fullPath):
      if entry.kind in {pcDir, pcLinkToDir} and dirHasCtFile(entry.path):
        return entry.path
  elif isFile and fullPath.endsWith(".ct"):
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

proc readStorageProtocolOptions(
    baseUrl, tenantId, token, protocol: string): StorageProtocolOptions =
  result.baseUrl =
    if baseUrl.len > 0: baseUrl
    else: getEnv("CODETRACER_STORAGE_BASE_URL", "")
  result.tenantId =
    if tenantId.len > 0: tenantId
    else: getEnv("CODETRACER_STORAGE_TENANT_ID", "")
  result.token =
    if token.len > 0: token
    else: getEnv("CODETRACER_STORAGE_REPLAY_TOKEN", "")
  result.protocol =
    if protocol.len > 0: protocol
    else: getEnv("CODETRACER_STORAGE_PROTOCOL", LOCAL_STORAGE_PROTOCOL)
  result.protocol = result.protocol.strip().toLowerAscii()
  if result.protocol != LOCAL_STORAGE_PROTOCOL:
    raise newException(ValueError,
      "unsupported storage protocol: " & result.protocol &
      " (supported: " & LOCAL_STORAGE_PROTOCOL & ")")
  result.baseUrl = result.baseUrl.strip(leading = false, trailing = true, chars = {'/'})

proc isRetainedObject(node: JsonNode): bool =
  let dataState = node.jsonString(["data_state", "dataState", "retentionStatus", "retention_status"])
  dataState.len == 0 or dataState in ["retained", "available"]

proc isUploadedObject(node: JsonNode): bool =
  let upload = node.jsonString(["upload", "uploadCompletionState", "upload_completion_state"])
  upload.len == 0 or upload in ["uploaded", "complete"]

proc requireReadableObject(node: JsonNode, label: string) =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, label & " is missing")
  if not node.isUploadedObject():
    raise newException(ValueError, label & " is not uploaded yet")
  if not node.isRetainedObject():
    raise newException(ValueError, label & " is expired or deleted")

proc objectKeyFromReference(reference: string): string =
  if reference.len == 0:
    return ""
  if reference.startsWith("http://") or reference.startsWith("https://"):
    return reference
  try:
    let parsed = parseUri(reference)
    if parsed.scheme.len > 0:
      return parsed.path.strip(leading = true, trailing = false, chars = {'/'})
  except CatchableError:
    discard
  reference.strip(leading = true, trailing = false, chars = {'/'})

proc storageObjectUrl(obj: JsonNode, options: StorageProtocolOptions): string =
  let uriValue = obj.jsonString(["uri"])
  if uriValue.startsWith("http://") or uriValue.startsWith("https://"):
    return uriValue

  if options.baseUrl.len == 0:
    raise newException(ValueError,
      "storage object requires --storage-base-url or CODETRACER_STORAGE_BASE_URL")
  if options.tenantId.len == 0:
    raise newException(ValueError,
      "storage object requires --storage-tenant-id or CODETRACER_STORAGE_TENANT_ID")

  let objectKey = objectKeyFromReference(
    if uriValue.len > 0: uriValue
    else: obj.jsonString(["objectKey", "object_key", "artifactKey", "artifact_key", "object_id", "path"]))
  if objectKey.len == 0:
    raise newException(ValueError, "storage object has no object key or URI")

  let serverId =
    if obj.hasKey("storageServerId"): obj.jsonString(["storageServerId"])
    elif obj.hasKey("storage_server_id"): obj.jsonString(["storage_server_id"])
    elif obj.hasKey("placement") and obj["placement"].kind == JObject:
      obj["placement"].jsonString(["server_id", "serverId"])
    else:
      ""
  let encodedKey = encodeUrl(objectKey)
  if serverId.len > 0:
    fmt"{options.baseUrl}/api/v1/observability/storage-policy/tenants/{options.tenantId}/{options.protocol}/servers/{serverId}/objects/{encodedKey}"
  else:
    fmt"{options.baseUrl}/api/v1/observability/storage-policy/tenants/{options.tenantId}/{options.protocol}/objects/{encodedKey}"

proc fetchStorageObject(obj: JsonNode, options: StorageProtocolOptions, label: string): string =
  requireReadableObject(obj, label)
  let url = storageObjectUrl(obj, options)
  echo "ct host: fetching ", label, " from storage: ", url
  var client = newHttpClient()
  defer: client.close()
  if options.token.len > 0:
    client.headers = newHttpHeaders({"Authorization": "Bearer " & options.token})
  try:
    let response = client.request(url, httpMethod = HttpGet)
    if response.code != Http200:
      raise newException(ValueError,
        fmt"{label} storage read failed: HTTP {response.status} from {url}")
    response.body
  except CatchableError as e:
    raise newException(ValueError, fmt"{label} storage protocol error: {e.msg}")

proc writeStorageObjectToTemp(
    obj: JsonNode, options: StorageProtocolOptions, label, suffix: string): string =
  let tempDir = getTempDir() / "ct-host-storage-" & $getCurrentProcessId()
  createDir(tempDir)
  result = tempDir / (label.replace(" ", "-") & suffix)
  writeFile(result, fetchStorageObject(obj, options, label))

proc checkedRelativeStoragePath(obj: JsonNode, label: string): string =
  let raw = block:
    let value = obj.jsonString(["relativePath", "relative_path", "payloadPath", "payload_path", "name"])
    if value.len > 0: value else: obj.jsonString(["path"])
  if raw.len == 0 or isAbsolute(raw):
    raise newException(ValueError, label & " has invalid relative path")
  result = raw.replace('\\', '/').strip(leading = true, trailing = false, chars = {'/'})
  if result.len == 0 or result.startsWith("../") or result == ".." or result.contains("/../"):
    raise newException(ValueError, label & " has invalid relative path")

proc fetchStorageSupportFiles(
    owner: JsonNode, options: StorageProtocolOptions, tempDir: string) =
  let supportFiles = owner.jsonField(["supportFiles", "support_files", "companionFiles", "companion_files"])
  if supportFiles.isNil:
    return
  if supportFiles.kind != JArray:
    raise newException(ValueError, "storage support files must be an array")

  for item in supportFiles:
    if item.kind != JObject:
      raise newException(ValueError, "storage support file entry must be an object")
    let relative = checkedRelativeStoragePath(item, "storage support file")
    let target = tempDir / relative
    createDir(target.parentDir)
    writeFile(target, fetchStorageObject(item, options, "storage support file " & relative))

proc writeStorageObjectToTempWithSupport(
    obj: JsonNode,
    supportOwner: JsonNode,
    options: StorageProtocolOptions,
    label,
    suffix: string): string =
  let tempDir = getTempDir() / "ct-host-storage-" & $getCurrentProcessId()
  createDir(tempDir)
  fetchStorageSupportFiles(supportOwner, options, tempDir)
  result = tempDir / (label.replace(" ", "-") & suffix)
  writeFile(result, fetchStorageObject(obj, options, label))

proc materializedPayloadFileName(obj: JsonNode): string =
  let raw = block:
    let relative = obj.jsonString(["relativePath", "relative_path", "payloadPath", "payload_path", "name"])
    if relative.len > 0: relative
    else: obj.jsonString(["objectKey", "object_key", "artifactKey", "artifact_key", "uri", "path", "object_id"])
  let fileName = raw.replace('\\', '/').splitFile.name & raw.replace('\\', '/').splitFile.ext
  if fileName in ["trace.bin", "trace.json"]:
    return fileName
  if raw.endsWith(".ct"):
    return "materialized.ct"
  "trace.bin"

proc materializePayloadTracePathAliases(tempDir, payloadPath: string) =
  let tracePathsPath = tempDir / "trace_paths.json"
  if not fileExists(tracePathsPath):
    return

  let payloadFileName = payloadPath.extractFilename
  var tracePaths: JsonNode
  try:
    tracePaths = parseJson(readFile(tracePathsPath))
  except CatchableError as e:
    echo "WARNING: failed to parse trace_paths.json for materialized payload aliases: ", e.msg
    return

  if tracePaths.kind != JArray:
    return

  for pathNode in tracePaths:
    if pathNode.kind != JString:
      continue
    let rawPath = pathNode.getStr()
    if rawPath.len == 0:
      continue

    let normalized = rawPath.replace('\\', '/')
    if normalized.extractFilename != payloadFileName:
      continue

    let targetPath =
      if isAbsoluteTracePath(normalized): normalized
      else: tempDir / normalized
    if fileExists(targetPath):
      continue

    try:
      createDir(targetPath.parentDir)
      copyFile(payloadPath, targetPath)
    except CatchableError as e:
      echo fmt"WARNING: failed to materialize payload trace path alias {normalized}: ", e.msg

proc writeMaterializedStorageArtifactToTemp(
    obj: JsonNode,
    supportOwner: JsonNode,
    options: StorageProtocolOptions,
    label: string): string =
  let tempDir = getTempDir() / "ct-host-storage-" & $getCurrentProcessId()
  createDir(tempDir)
  fetchStorageSupportFiles(supportOwner, options, tempDir)
  result = tempDir / materializedPayloadFileName(obj)
  writeFile(result, fetchStorageObject(obj, options, label))
  materializePayloadTracePathAliases(tempDir, result)

proc importMaterializedStorageObject(
    obj: JsonNode,
    options: StorageProtocolOptions,
    label: string,
    supportOwner: JsonNode = nil): string =
  let reference = obj.jsonString(["objectKey", "object_key", "artifactKey", "artifact_key", "uri", "path", "object_id"])
  let owner = if supportOwner.isNil: obj else: supportOwner
  let path =
    if reference.endsWith(".ct"):
      writeStorageObjectToTemp(obj, options, label, ".ct")
    else:
      writeMaterializedStorageArtifactToTemp(obj, owner, options, label)
  let traceFolder = findMaterializedTraceFolder(path)
  if traceFolder.len == 0:
    raise newException(ValueError,
      label & " is not a hostable CodeTracer trace folder or .ct artifact")
  if traceFolder.endsWith(".ct"):
    importCtFile(traceFolder)
  else:
    importTraceFolder(traceFolder)

proc selectedSegment(segments: JsonNode, start: HostStartCoordinates): JsonNode =
  let requestedGeid = parseUintOrZero(start.geid)
  for segment in segments:
    if segment.kind != JObject:
      continue
    if requestedGeid > 0:
      let geidStart = parseUintOrZero(segment.jsonString(["geid_start", "geidStart", "startGeid"]))
      let geidEnd = parseUintOrZero(segment.jsonString(["geid_end", "geidEnd", "endGeid"]))
      if requestedGeid >= geidStart and (geidEnd == 0'u64 or requestedGeid <= geidEnd):
        return segment
    elif result.isNil:
      result = segment
  if result.isNil and segments.len > 0:
    result = segments[0]

proc importShardedSegment(
    segment: JsonNode, options: StorageProtocolOptions): string =
  if segment.isNil:
    raise newException(ValueError, "sharded_split_ctfs manifest has no selected segment")
  let shards = segment.jsonField(["shards"])
  if shards.isNil or shards.kind != JArray or shards.len == 0:
    raise newException(ValueError, "selected sharded_split_ctfs segment has no shards")

  var bytes = ""
  for shard in shards:
    let replicas = shard.jsonField(["replicas"])
    if replicas.isNil or replicas.kind != JArray or replicas.len == 0:
      raise newException(ValueError, "selected sharded_split_ctfs shard has no replicas")
    var lastError = ""
    var read = false
    for replica in replicas:
      try:
        bytes.add(fetchStorageObject(replica, options, "CTFS shard replica"))
        read = true
        break
      except CatchableError as e:
        lastError = e.msg
        echo "ct host: CTFS shard replica read failed; trying next replica: ", lastError
    if not read:
      raise newException(ValueError, "no readable CTFS shard replica: " & lastError)

  let tempDir = getTempDir() / "ct-host-storage-" & $getCurrentProcessId()
  createDir(tempDir)
  fetchStorageSupportFiles(segment, options, tempDir)
  let path = tempDir / "sharded-segment.ct"
  writeFile(path, bytes)
  importCtFile(path)

proc resolveSharedManifest(
    manifestPath: string,
    manifest: JsonNode,
    storageOptions: StorageProtocolOptions): HostResolvedTrace =
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
    if path.len > 0 and fileExists(path):
      result.traceId = importCtFile(path)
    else:
      let storagePath = writeStorageObjectToTemp(fileNode, storageOptions, "single CTFS file", ".ct")
      result.traceId = importCtFile(storagePath)
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
    if path.len > 0 and fileExists(path):
      echo "ct host: selected split_ctfs segment: ", path
      result.traceId = importCtFile(path)
    else:
      let storagePath = writeStorageObjectToTempWithSupport(fileNode, selected, storageOptions, "split CTFS segment", ".ct")
      echo "ct host: selected split_ctfs segment: ", storagePath
      result.traceId = importCtFile(storagePath)
    result.start = start
  of "materialized_artifact":
    let artifactNode = source.jsonField(["artifact"])
    if artifactNode.isNil:
      raise newException(ValueError, "materialized_artifact manifest missing artifact")
    let path = resolveLocalReference(artifactNode.jsonString(["uri", "path", "object_id"]), manifestPath, manifestKey)
    let traceFolder = findMaterializedTraceFolder(path)
    if traceFolder.len == 0:
      result.traceId = importMaterializedStorageObject(artifactNode, storageOptions, "materialized artifact", source)
    elif traceFolder.endsWith(".ct"):
      result.traceId = importCtFile(traceFolder)
    else:
      result.traceId = importTraceFolder(traceFolder)
    result.start = readReplayStart(source.jsonField(["replay_start", "replayStart"]))
    if result.start.traceId.len == 0 and result.start.materializedMomentId.len == 0:
      result.start = manifestStart
    result.start.materializedArtifactKey = artifactNode.jsonString(["object_id", "uri", "path"])
  of "sharded_split_ctfs":
    let segments = source.jsonField(["segments"])
    if segments.isNil or segments.kind != JArray or segments.len == 0:
      raise newException(ValueError, "sharded_split_ctfs manifest missing segments")
    var start = readReplayStart(source.jsonField(["replay_start", "replayStart"]))
    if start.traceId.len == 0 and start.geid.len == 0:
      start = manifestStart
    result.traceId = importShardedSegment(selectedSegment(segments, start), storageOptions)
    result.start = start
  else:
    raise newException(ValueError, "unsupported shared manifest source kind: " & kind)

proc resolveRecordingManifest(
    manifestPath: string,
    manifest: JsonNode,
    storageOptions: StorageProtocolOptions): HostResolvedTrace =
  let kind = manifest.jsonString(["kind"])
  let manifestKey = manifest.jsonString(["manifestS3Key", "manifest_s3_key"])
  if manifest.jsonString(["uploadCompletionState", "upload_completion_state"]) notin ["", "complete"]:
    raise newException(ValueError, "recording manifest is not complete")
  if manifest.jsonString(["retentionStatus", "retention_status"]) in ["missing", "expired"]:
    raise newException(ValueError, "recording manifest is missing or expired")
  case kind
  of "mcr_slices":
    let shardedSegments = manifest.jsonField(["shardedMcrSegments", "sharded_mcr_segments"])
    if not shardedSegments.isNil and shardedSegments.kind == JArray and shardedSegments.len > 0:
      result.traceId = importShardedSegment(selectedSegment(shardedSegments, readReplayStart(manifest.jsonField(["replayStart", "replay_start"]))), storageOptions)
    else:
      let slice = manifest.firstObject(["mcrSlices", "mcr_slices"])
      if slice.isNil:
        raise newException(ValueError, "mcr_slices manifest has no retained slices")
      requireReadableObject(slice, "MCR slice")
      let path = resolveLocalReference(slice.jsonString(["sliceKey", "slice_key"]), manifestPath, manifestKey)
      if path.len > 0 and fileExists(path):
        result.traceId = importCtFile(path)
      else:
        let obj = %*{
          "objectKey": slice.jsonString(["sliceKey", "slice_key"]),
          "uploadCompletionState": slice.jsonString(["uploadCompletionState", "upload_completion_state"]),
          "retentionStatus": slice.jsonString(["retentionStatus", "retention_status"])
        }
        result.traceId = importCtFile(writeStorageObjectToTemp(obj, storageOptions, "MCR slice", ".ct"))
    result.start = readReplayStart(manifest.jsonField(["replayStart", "replay_start"]))
  of "materialized_trace":
    let artifact = manifest.firstObject(["materializedTraceArtifacts", "materialized_trace_artifacts"])
    if artifact.isNil:
      raise newException(ValueError, "materialized_trace manifest has no local artifacts")
    let path = resolveLocalReference(artifact.jsonString(["artifactKey", "artifact_key"]), manifestPath, manifestKey)
    let traceFolder = findMaterializedTraceFolder(path)
    if traceFolder.len == 0:
      result.traceId = importMaterializedStorageObject(artifact, storageOptions, "materialized artifact")
    elif traceFolder.endsWith(".ct"):
      result.traceId = importCtFile(traceFolder)
    else:
      result.traceId = importTraceFolder(traceFolder)
    result.start = readReplayStart(artifact.jsonField(["replayStart", "replay_start"]))
    if result.start.materializedMomentId.len == 0:
      result.start = readReplayStart(manifest.jsonField(["replayStart", "replay_start"]))
    result.start.materializedArtifactKey = artifact.jsonString(["artifactKey", "artifact_key"])
  else:
    raise newException(ValueError, "unsupported recording manifest kind: " & kind)

proc importLocalManifest(
    manifestPath: string,
    storageOptions: StorageProtocolOptions = StorageProtocolOptions()): HostResolvedTrace =
  let fullPath = expandFilename(expandTilde(manifestPath))
  let manifest = parseJson(readFile(fullPath))
  if manifest.jsonString(["schema"]) == "codetracer.trace-storage.v1":
    result = resolveSharedManifest(fullPath, manifest, storageOptions)
  else:
    result = resolveRecordingManifest(fullPath, manifest, storageOptions)
  applyReplayStartEnv(result.start)
  echo "ct host: loaded local manifest: ", fullPath
  flushFile(stdout)


proc hostCommand*(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string,
    idleTimeoutRaw: string,
    tracePath: string = "",
    manifestPath: string = "",
    storageBaseUrl: string = "",
    storageTenantId: string = "",
    storageToken: string = "",
    storageProtocol: string = "") =

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
  # M-REC-2: traceId is the recording_id (UUIDv7 string); empty string
  # sentinel replaces the legacy -1.
  var traceId = ""
  let envIdleTimeout = getEnv("CODETRACER_HOST_IDLE_TIMEOUT", "")
  let parsedIdleTimeout = parseIdleTimeoutMs(
    if idleTimeoutRaw.len > 0: idleTimeoutRaw else: envIdleTimeout)
  if not parsedIdleTimeout.ok:
    echo "ct host: error: ", parsedIdleTimeout.error
    quit(1)
  let idleTimeoutMs = parsedIdleTimeout.value
  var storageOptions: StorageProtocolOptions
  try:
    storageOptions = readStorageProtocolOptions(
      storageBaseUrl, storageTenantId, storageToken, storageProtocol)
  except CatchableError as e:
    echo "ct host: error: ", e.msg
    quit(1)

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
      let resolved = importLocalManifest(localManifestPath, storageOptions)
      traceId = resolved.traceId
      echo "ct host: imported manifest trace as trace id ", traceId
      flushFile(stdout)
    except CatchableError as e:
      emitReplayProblemForHostFailure(e.msg)
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
    # M-REC-2: ``traceArg`` may be either a recording_id (36-char UUIDv7
    # string) or a folder path.  We use the UUIDv7 hyphen positions as a
    # cheap shape check: anything else is treated as a folder.
    if traceArg.len == 36 and traceArg[8] == '-' and traceArg[13] == '-' and
        traceArg[18] == '-' and traceArg[23] == '-':
      traceId = traceArg
    else:
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
