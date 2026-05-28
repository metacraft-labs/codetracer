## User-facing collaboration diagnostics export.

import std/[json, os, strutils]

import ./[codec, snapshot, types]

type
  CollabDiagnosticExportResult* = object
    outputDir*: string
    protocolLogPath*: string
    snapshotPath*: string
    manifestPath*: string
    artifactPaths*: seq[string]

const
  ProtocolLogFile* = "protocol.log"
  SharedSessionSnapshotFile* = "SharedSessionSnapshot.json"
  DiagnosticManifestFile* = "manifest.json"

proc safeArtifactName(name: string): string =
  result = ""
  for ch in name:
    if ch.isAlphaNumeric or ch in {'-', '_', '.'}:
      result.add ch
    else:
      result.add '_'
  if result.len == 0:
    result = "collab-diagnostics"

proc exportCollabDiagnostics*(outputRoot: string;
                              testName: string;
                              protocolLog: openArray[string];
                              snapshot: SharedSessionSnapshot;
                              policy = defaultSnapshotRetentionPolicy()):
                              CollabDiagnosticExportResult =
  let root = if outputRoot.len == 0: getTempDir() else: outputRoot
  let dir = root / safeArtifactName(testName)
  createDir(dir)

  let protocolPath = dir / ProtocolLogFile
  let snapshotPath = dir / SharedSessionSnapshotFile
  let manifestPath = dir / DiagnosticManifestFile

  writeFile(protocolPath, protocolLog.join("\n") & "\n")
  writeFile(snapshotPath, pretty(snapshot.toJson))
  writeFile(manifestPath, pretty(%*{
    "testName": testName,
    "artifacts": [
      ProtocolLogFile,
      SharedSessionSnapshotFile,
    ],
    "privacy": {
      "protocolLog": "operation ids, statuses, peer labels, and reducer reasons only",
      "snapshot": "SharedSessionViewState JSON; trace source text and debug payload args are not added by this exporter",
      "retention": "local failure artifacts; CI retention is owned by the test runner artifact policy",
    },
    "retentionPolicy": policy.toJson,
  }))

  CollabDiagnosticExportResult(
    outputDir: dir,
    protocolLogPath: protocolPath,
    snapshotPath: snapshotPath,
    manifestPath: manifestPath,
    artifactPaths: @[protocolPath, snapshotPath, manifestPath],
  )
