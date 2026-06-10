## Headless tests for M14 ct-test durable run store.
##
## Compile and run:
##   nim c -r src/ct_test/run_store_test.nim

import std/[options, os, strutils, tables, unittest]

import contracts
import run_store

const
  ProviderId = "nim-unittest"
  Workspace = "/repo"
  FileA = "tests/test_alpha.nim"

proc tempRoot(name: string): string =
  result = getTempDir() / ("codetracer-m14-" & name & "-" &
      $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc capabilities(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: true,
    canRecordProject: true,
    canRecordFile: true,
    canRecordSingle: true,
    canCapturePerTestOutput: true,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: true)

proc providerInfo(version = "m14-fixture"): TestProviderInfo =
  TestProviderInfo(
    id: ProviderId,
    language: "nim",
    framework: "std/unittest",
    displayName: "Nim unittest",
    version: version,
    capabilities: capabilities())

proc sourceRange(line: int): SourceRange =
  SourceRange(startLine: line, startColumn: 3, endLine: line, endColumn: 24)

proc item(selector = "tests/test_alpha.nim::alpha"; stale = false): TestItem =
  TestItem(
    id: makeTestItemId(ProviderId, "nim", "std/unittest", FileA, selector),
    providerId: ProviderId,
    language: "nim",
    framework: "std/unittest",
    name: "alpha",
    kind: tikCase,
    file: FileA,
    range: sourceRange(12),
    selector: selector,
    parentId: "",
    tags: @[],
    location: LocationProvenance(
      source: lskParser,
      detail: "M14 fixture",
      confidence: lcHigh),
    stale: stale,
    staleReason: if stale: "not present in latest catalog" else: "")

proc trace(path: string): TraceMetadata =
  TraceMetadata(
    traceId: "trace-1",
    recordingId: "recording-1",
    path: path,
    backend: "db-backend",
    entryPoint: "alpha",
    metadata: initTable[string, string]())

proc event(kind: TestEventKind; testId: string;
    runId = "run-1";
    status = none(TestResultStatus);
    output = "";
    durationMs = 0;
    traceValue = none(TraceMetadata)): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: ProviderId,
    runId: runId,
    testId: testId,
    status: status,
    message: "",
    output: output,
    durationMs: durationMs,
    trace: traceValue,
    diagnostic: none(TestDiagnostic))

suite "ct-test durable run store M14":

  test "persists_last_result_and_last_trace_by_environment_fingerprint":
    let root = tempRoot("persist")
    let store = openLocalRunStore(root)
    let testItem = item()
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    let otherEnv = defaultEnvironmentFingerprint(
      Workspace, providerInfo("other"))
    let traceDir = root / "trace-alpha"
    createDir(traceDir)

    discard store.upsertCatalogItem(testItem, env, timestamp = 100)
    store.updateFromEvent(event(tekOutput, testItem.id,
        output = "alpha stdout\n"),
      env, timestamp = 101)
    store.updateFromEvent(event(tekTestFinished, testItem.id,
      status = some(tsPassed),
      durationMs = 42,
      traceValue = some(trace(traceDir))), env, timestamp = 102)

    let reopened = openLocalRunStore(root)
    let record = reopened.getLastResult(testItem.id, env)
    check record.isSome
    check record.get.status == tescPassed
    check record.get.durationMs == 42
    check record.get.outputTail == "alpha stdout\n"
    check reopened.getLastTrace(testItem.id, env).get.path == traceDir
    check reopened.getLastResult(testItem.id, otherEnv).isNone

  test "retention_cleanup_removes_expired_unpinned_recordings_and_logs":
    let root = tempRoot("retention")
    let store = openLocalRunStore(root, retentionDays = 1)
    let testItem = item()
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    let traceDir = root / "expired-trace"
    createDir(traceDir)

    discard store.upsertCatalogItem(testItem, env, timestamp = 10)
    store.updateFromEvent(event(tekOutput, testItem.id, output = "old log"),
      env, timestamp = 11)
    store.updateFromEvent(event(tekRecordingCreated, testItem.id,
      traceValue = some(trace(traceDir))), env, timestamp = 12)
    let record = store.getLastResult(testItem.id, env).get

    let report = store.cleanupExpired(nowUnixValue = 12 + 2 * 24 * 60 * 60)

    check report.removedRecords == 1
    check traceDir in report.removedRecordingPaths
    check record.outputLogPath in report.removedLogPaths
    check not dirExists(traceDir)
    check not fileExists(record.outputLogPath)
    check store.getLastResult(testItem.id, env).isNone

  test "retention_cleanup_preserves_user_pinned_recordings":
    let root = tempRoot("pinned")
    let store = openLocalRunStore(root, retentionDays = 1)
    let testItem = item()
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    let traceDir = root / "pinned-trace"
    createDir(traceDir)

    discard store.upsertCatalogItem(testItem, env, timestamp = 10)
    store.updateFromEvent(event(tekRecordingCreated, testItem.id,
      traceValue = some(trace(traceDir))), env, timestamp = 12)
    store.setPinned(testItem.id, env, true)

    let report = store.cleanupExpired(nowUnixValue = 12 + 2 * 24 * 60 * 60)

    check report.removedRecords == 0
    check traceDir in report.preservedPinned
    check dirExists(traceDir)
    check store.getLastResult(testItem.id, env).get.retentionState ==
      rrsPinned

  test "retention_cleanup_keeps_recording_paths_used_by_pinned_records":
    let root = tempRoot("shared-pinned")
    let store = openLocalRunStore(root, retentionDays = 1)
    let pinnedItem = item("tests/test_alpha.nim::pinned")
    let expiredItem = item("tests/test_alpha.nim::expired")
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    let traceDir = root / "shared-trace"
    createDir(traceDir)

    discard store.upsertCatalogItem(pinnedItem, env, timestamp = 10)
    store.updateFromEvent(event(tekRecordingCreated, pinnedItem.id,
      traceValue = some(trace(traceDir))), env, timestamp = 12)
    store.setPinned(pinnedItem.id, env, true)
    discard store.upsertCatalogItem(expiredItem, env, timestamp = 10)
    store.updateFromEvent(event(tekRecordingCreated, expiredItem.id,
      traceValue = some(trace(traceDir))), env, timestamp = 12)

    let report = store.cleanupExpired(nowUnixValue = 12 + 2 * 24 * 60 * 60)

    check report.removedRecords == 1
    check traceDir notin report.removedRecordingPaths
    check traceDir in report.preservedPinned
    check dirExists(traceDir)
    check store.getLastResult(pinnedItem.id, env).isSome
    check store.getLastResult(expiredItem.id, env).isNone

  test "ci_artifact_import_accepts_ct_test_json_event_lines":
    let root = tempRoot("ci-import")
    let store = openLocalRunStore(root)
    let testItem = item()
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    let artifact = root / "events.jsonl"
    let traceDir = root / "ci-trace"
    createDir(traceDir)
    writeFile(artifact,
      event(tekTestFinished, testItem.id,
        status = some(tsFailed),
        durationMs = 9,
        traceValue = some(trace(traceDir))).eventToJsonLine & "\n")

    let report = store.importCiArtifactEvents(artifact, env, timestamp = 20)

    check report.importedEvents == 1
    check report.diagnostics.len == 0
    check store.getLastResult(testItem.id, env).get.status == tescFailed
    check store.getLastTrace(testItem.id, env).get.path == traceDir

  test "ci_artifact_import_reports_unsupported_lines":
    let root = tempRoot("ci-unsupported")
    let store = openLocalRunStore(root)
    let artifact = root / "bad-events.jsonl"
    writeFile(artifact, """{"not":"a ct-test event"}""" & "\n")

    let report = store.importCiArtifactEvents(artifact, "env")

    check report.importedEvents == 0
    check report.diagnostics.len == 1
    check "unsupported ct-test CI artifact line" in
      report.diagnostics[0].message
