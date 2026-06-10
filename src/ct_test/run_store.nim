## Durable local ct-test run/result store.
##
## Schema v1 is intentionally a single JSON file next to optional output logs.
## Records are keyed by catalog item id plus an environment fingerprint so the
## editor can answer "last result" and "open last trace" after a fresh
## ViewModel/session without mixing results from different toolchains.

import std/[json, options, strutils, tables, times]

when not defined(js):
  import std/os

import contracts

const
  RunStoreSchemaVersion* = 1
  DefaultRetentionDays* = 14

type
  TestExplorerStatusCompat* = enum
    tescIdle = "idle"
    tescRunning = "running"
    tescRecording = "recording"
    tescPassed = "passed"
    tescFailed = "failed"
    tescSkipped = "skipped"
    tescErrored = "errored"
    tescCancelled = "cancelled"

  RunRetentionState* = enum
    rrsRetained = "retained"
    rrsPinned = "pinned"
    rrsExpired = "expired"

  RunRecord* = object
    schemaVersion*: int
    catalogItemId*: string
    environmentFingerprint*: string
    providerId*: string
    selector*: string
    file*: string
    name*: string
    stale*: bool
    staleReason*: string
    status*: TestExplorerStatusCompat
    outputLogPath*: string
    outputTail*: string
    durationMs*: int
    trace*: Option[TraceMetadata]
    createdAtUnix*: int64
    updatedAtUnix*: int64
    pinned*: bool
    retentionState*: RunRetentionState
    expiresAtUnix*: int64

  RunStoreCleanupReport* = object
    removedRecords*: int
    removedRecordingPaths*: seq[string]
    removedLogPaths*: seq[string]
    preservedPinned*: seq[string]
    diagnostics*: seq[TestDiagnostic]

  CiArtifactImportReport* = object
    importedEvents*: int
    diagnostics*: seq[TestDiagnostic]

  LocalRunStore* = ref object
    root*: string
    dbPath*: string
    retentionDays*: int
    records*: Table[string, RunRecord]

proc `$`*(state: RunRetentionState): string =
  case state
  of rrsRetained: "retained"
  of rrsPinned: "pinned"
  of rrsExpired: "expired"

proc `$`*(status: TestExplorerStatusCompat): string =
  case status
  of tescIdle: "idle"
  of tescRunning: "running"
  of tescRecording: "recording"
  of tescPassed: "passed"
  of tescFailed: "failed"
  of tescSkipped: "skipped"
  of tescErrored: "errored"
  of tescCancelled: "cancelled"

proc parseRetentionState(raw: string): RunRetentionState =
  for value in RunRetentionState:
    if $value == raw:
      return value
  rrsRetained

proc parseCompatStatus(raw: string): TestExplorerStatusCompat =
  for value in TestExplorerStatusCompat:
    if $value == raw:
      return value
  tescIdle

proc diagnostic(severity: DiagnosticSeverity; message: string;
    file = ""): TestDiagnostic =
  TestDiagnostic(
    severity: severity,
    message: message,
    file: file,
    range: none(SourceRange))

proc nowUnix*(): int64 =
  now().toTime.toUnix

proc runRecordKey*(catalogItemId, environmentFingerprint: string): string =
  catalogItemId & "\n" & environmentFingerprint

proc defaultRunStoreRoot*(): string =
  when defined(js):
    ""
  else:
    getEnv("CODETRACER_TEST_RUN_STORE",
      getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state") /
        "codetracer" / "ct-test")

proc defaultEnvironmentFingerprint*(workspaceRoot: string;
                                    provider: TestProviderInfo): string =
  when defined(js):
    let normalizedWorkspace = workspaceRoot
  else:
    let normalizedWorkspace = workspaceRoot.normalizedPath
  [
    "schema=v1",
    "os=" & hostOS,
    "cpu=" & hostCPU,
    "workspace=" & normalizedWorkspace,
    "provider=" & provider.id,
    "language=" & provider.language,
    "framework=" & provider.framework,
    "providerVersion=" & provider.version
  ].join(";")

proc ensureStoreDirs(store: LocalRunStore) =
  when not defined(js):
    createDir(store.root)
    createDir(store.root / "logs")

proc toJson*(record: RunRecord): JsonNode =
  result = %*{
    "schemaVersion": record.schemaVersion,
    "catalogItemId": record.catalogItemId,
    "environmentFingerprint": record.environmentFingerprint,
    "providerId": record.providerId,
    "selector": record.selector,
    "file": record.file,
    "name": record.name,
    "stale": record.stale,
    "staleReason": record.staleReason,
    "status": $record.status,
    "outputLogPath": record.outputLogPath,
    "outputTail": record.outputTail,
    "durationMs": record.durationMs,
    "createdAtUnix": record.createdAtUnix,
    "updatedAtUnix": record.updatedAtUnix,
    "pinned": record.pinned,
    "retentionState": $record.retentionState,
    "expiresAtUnix": record.expiresAtUnix
  }
  if record.trace.isSome:
    result["trace"] = record.trace.get.toJson
  else:
    result["trace"] = newJNull()

proc runRecordFromJson*(node: JsonNode): RunRecord =
  result = RunRecord(
    schemaVersion: node{"schemaVersion"}.getInt(RunStoreSchemaVersion),
    catalogItemId: node{"catalogItemId"}.getStr(""),
    environmentFingerprint: node{"environmentFingerprint"}.getStr(""),
    providerId: node{"providerId"}.getStr(""),
    selector: node{"selector"}.getStr(""),
    file: node{"file"}.getStr(""),
    name: node{"name"}.getStr(""),
    stale: node{"stale"}.getBool(false),
    staleReason: node{"staleReason"}.getStr(""),
    status: parseCompatStatus(node{"status"}.getStr("idle")),
    outputLogPath: node{"outputLogPath"}.getStr(""),
    outputTail: node{"outputTail"}.getStr(""),
    durationMs: node{"durationMs"}.getInt(0),
    trace: none(TraceMetadata),
    createdAtUnix: node{"createdAtUnix"}.getBiggestInt(0),
    updatedAtUnix: node{"updatedAtUnix"}.getBiggestInt(0),
    pinned: node{"pinned"}.getBool(false),
    retentionState: parseRetentionState(node{"retentionState"}.getStr(
        "retained")),
    expiresAtUnix: node{"expiresAtUnix"}.getBiggestInt(0))
  if node.hasKey("trace") and node["trace"].kind != JNull:
    result.trace = some(traceMetadataFromJson(node["trace"]))

proc save*(store: LocalRunStore) =
  when not defined(js):
    store.ensureStoreDirs()
    var records = newJArray()
    for _, record in store.records:
      records.add record.toJson
    writeFile(store.dbPath, $(%*{
      "schemaVersion": RunStoreSchemaVersion,
      "records": records
    }))

proc load*(store: LocalRunStore) =
  store.records = initTable[string, RunRecord]()
  when not defined(js):
    if not fileExists(store.dbPath):
      return
    let node = parseJson(readFile(store.dbPath))
    if node{"schemaVersion"}.getInt(0) != RunStoreSchemaVersion:
      return
    for item in node{"records"}.items:
      let record = runRecordFromJson(item)
      if record.catalogItemId.len > 0 and
          record.environmentFingerprint.len > 0:
        store.records[runRecordKey(record.catalogItemId,
          record.environmentFingerprint)] = record

proc openLocalRunStore*(root = defaultRunStoreRoot();
                        retentionDays = DefaultRetentionDays): LocalRunStore =
  when defined(js):
    let dbPath = ""
  else:
    let dbPath = root / "runs.json"
  result = LocalRunStore(
    root: root,
    dbPath: dbPath,
    retentionDays: retentionDays,
    records: initTable[string, RunRecord]())
  result.ensureStoreDirs()
  result.load()

proc retentionExpiry(updatedAtUnix: int64; retentionDays: int): int64 =
  updatedAtUnix + int64(max(1, retentionDays)) * 24'i64 * 60'i64 * 60'i64

proc safeFileComponent(value: string): string =
  result = value
  for ch in ['/', '\\', ':', '\n', '\r', '\t', ' ']:
    result = result.replace($ch, "_")
  if result.len > 180:
    result = result[0 ..< 180]
  if result.len == 0:
    result = "run"

proc upsertCatalogItem*(store: LocalRunStore; item: TestItem;
                        environmentFingerprint: string;
                        timestamp = nowUnix()): RunRecord =
  let key = runRecordKey(item.id, environmentFingerprint)
  result = store.records.getOrDefault(key, RunRecord(
    schemaVersion: RunStoreSchemaVersion,
    catalogItemId: item.id,
    environmentFingerprint: environmentFingerprint,
    status: tescIdle,
    createdAtUnix: timestamp,
    updatedAtUnix: timestamp,
    retentionState: rrsRetained,
    expiresAtUnix: retentionExpiry(timestamp, store.retentionDays),
    trace: none(TraceMetadata)))
  result.providerId = item.providerId
  result.selector = item.selector
  result.file = item.file
  result.name = item.name
  result.stale = item.stale
  result.staleReason = item.staleReason
  result.updatedAtUnix = max(result.updatedAtUnix, timestamp)
  if result.pinned:
    result.retentionState = rrsPinned
  elif result.retentionState != rrsExpired:
    result.retentionState = rrsRetained
  if result.expiresAtUnix == 0:
    result.expiresAtUnix = retentionExpiry(result.updatedAtUnix,
        store.retentionDays)
  store.records[key] = result
  store.save()

proc getLastResult*(store: LocalRunStore; catalogItemId,
                    environmentFingerprint: string): Option[RunRecord] =
  let key = runRecordKey(catalogItemId, environmentFingerprint)
  if store.records.hasKey(key):
    some(store.records[key])
  else:
    none(RunRecord)

proc getLastTrace*(store: LocalRunStore; catalogItemId,
    environmentFingerprint: string): Option[TraceMetadata] =
  let record = store.getLastResult(catalogItemId, environmentFingerprint)
  if record.isSome:
    record.get.trace
  else:
    none(TraceMetadata)

proc recordOutput(store: LocalRunStore; record: var RunRecord; output: string) =
  if output.len == 0:
    return
  record.outputTail = output
  when not defined(js):
    store.ensureStoreDirs()
    if record.outputLogPath.len == 0:
      record.outputLogPath = store.root / "logs" /
        (safeFileComponent(record.catalogItemId & "-" &
          record.environmentFingerprint) & ".log")
    writeFile(record.outputLogPath,
      if fileExists(record.outputLogPath): readFile(record.outputLogPath) & output
      else: output)

proc updateFromEvent*(store: LocalRunStore; event: TestEvent;
                      environmentFingerprint: string;
                      timestamp = nowUnix()) =
  if event.testId.len == 0 or environmentFingerprint.len == 0:
    return
  let key = runRecordKey(event.testId, environmentFingerprint)
  var record = store.records.getOrDefault(key, RunRecord(
    schemaVersion: RunStoreSchemaVersion,
    catalogItemId: event.testId,
    environmentFingerprint: environmentFingerprint,
    providerId: event.providerId,
    status: tescIdle,
    createdAtUnix: timestamp,
    trace: none(TraceMetadata)))
  record.providerId = if event.providerId.len >
      0: event.providerId else: record.providerId
  record.updatedAtUnix = timestamp
  record.expiresAtUnix = retentionExpiry(timestamp, store.retentionDays)
  case event.kind
  of tekRunStarted, tekTestStarted:
    record.status = tescRunning
  of tekRecordStarted:
    record.status = tescRecording
  of tekOutput:
    store.recordOutput(record, event.output)
  of tekFailure:
    record.status = tescFailed
  of tekCancellation:
    record.status = tescCancelled
  of tekTestFinished, tekRunFinished, tekRecordFinished:
    if event.status.isSome:
      case event.status.get
      of tsPassed: record.status = tescPassed
      of tsFailed: record.status = tescFailed
      of tsSkipped: record.status = tescSkipped
      of tsErrored: record.status = tescErrored
    record.durationMs = event.durationMs
    if event.trace.isSome:
      record.trace = event.trace
  of tekRecordingCreated:
    if event.trace.isSome:
      record.trace = event.trace
  else:
    discard
  if record.pinned:
    record.retentionState = rrsPinned
  else:
    record.retentionState = rrsRetained
  store.records[key] = record
  store.save()

proc setPinned*(store: LocalRunStore; catalogItemId,
    environmentFingerprint: string; pinned: bool) =
  let key = runRecordKey(catalogItemId, environmentFingerprint)
  if not store.records.hasKey(key):
    return
  var record = store.records[key]
  record.pinned = pinned
  record.retentionState = if pinned: rrsPinned else: rrsRetained
  store.records[key] = record
  store.save()

proc removePath(path: string; report: var RunStoreCleanupReport;
    isRecording: bool) =
  when not defined(js):
    if path.len == 0 or not (fileExists(path) or dirExists(path)):
      return
    try:
      if dirExists(path):
        removeDir(path)
      else:
        removeFile(path)
      if isRecording:
        report.removedRecordingPaths.add path
      else:
        report.removedLogPaths.add path
    except OSError as err:
      report.diagnostics.add diagnostic(dsWarning,
        "could not remove expired ct-test artifact " & path & ": " & err.msg)

proc cleanupExpired*(store: LocalRunStore; nowUnixValue = nowUnix()):
    RunStoreCleanupReport =
  var kept = initTable[string, RunRecord]()
  var pinnedRecordingPaths = initTable[string, bool]()
  for _, record in store.records:
    if record.pinned and record.trace.isSome:
      pinnedRecordingPaths[record.trace.get.path] = true

  for key, record in store.records:
    if record.pinned:
      kept[key] = record
      if record.trace.isSome:
        result.preservedPinned.add record.trace.get.path
      continue
    if record.expiresAtUnix > 0 and record.expiresAtUnix <= nowUnixValue:
      var expired = record
      expired.retentionState = rrsExpired
      if expired.trace.isSome:
        let tracePath = expired.trace.get.path
        if pinnedRecordingPaths.hasKey(tracePath):
          result.preservedPinned.add tracePath
        else:
          removePath(tracePath, result, true)
      removePath(expired.outputLogPath, result, false)
      inc result.removedRecords
    else:
      kept[key] = record
  store.records = kept
  store.save()

proc importCiArtifactEvents*(store: LocalRunStore; path,
    environmentFingerprint: string; timestamp = nowUnix()):
    CiArtifactImportReport =
  ## Import newline-delimited ct-test TestEvent JSON artifacts. Broader CI
  ## formats should be normalized to this contract before import.
  when defined(js):
    result.diagnostics.add diagnostic(dsWarning,
      "ct-test CI artifact import is unavailable in the browser", path)
  else:
    if not fileExists(path):
      result.diagnostics.add diagnostic(dsError,
        "ct-test CI artifact not found: " & path, path)
      return
    for line in readFile(path).splitLines:
      let stripped = line.strip
      if stripped.len == 0:
        continue
      try:
        let event = eventFromJsonLine(stripped)
        store.updateFromEvent(event, environmentFingerprint, timestamp)
        inc result.importedEvents
      except CatchableError as err:
        result.diagnostics.add diagnostic(dsWarning,
          "unsupported ct-test CI artifact line: " & err.msg, path)
