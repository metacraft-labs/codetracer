import std/[algorithm, os, sequtils, strutils, tables, unittest]

import contracts
import ct_test
import discovery
import release_gate

proc providerIds(registry: ProviderRegistry): seq[string] =
  registry.providers.mapIt(it.provider.info.id)

proc gateProviderIds(): seq[string] =
  ProviderGateEntries.mapIt(it.providerId)

proc readExisting(path: string): string =
  if not fileExists(path):
    raise newException(IOError, "missing required file: " & path)
  readFile(path)

proc sourceBundle(entry: ProviderGateEntry): string =
  result.add readExisting(entry.providerTest)
  for path in entry.sourceFiles:
    result.add "\n"
    result.add readExisting(path)

proc fixtureJsonFiles(root: string): seq[string] =
  if not dirExists(root):
    return @[]
  for path in walkDirRec(root):
    if path.endsWith(".json"):
      result.add path

proc checkNoHardSkips(path: string) =
  let text = readExisting(path)
  check "test.skip(" notin text
  check "test.skip \"" notin text
  check ".skip(" notin text
  check "skip()" notin text
  check ".only(" notin text

suite "ct-test M16 release gate":
  test "release_gate_checks_all_declared_capabilities":
    let registry = newDefaultProviderRegistry()
    let registryIds = registry.providerIds.sorted
    let gateIds = gateProviderIds().sorted

    check registryIds == gateIds
    check TestCatalogSchemaVersion == DiscoverSchemaVersion

    let generated = supportMatrixMarkdown(registry)
    check fileExists(SupportMatrixPath)
    check readFile(SupportMatrixPath).strip(leading = false) ==
      generated.strip(leading = false)

    for jsonPath in fixtureJsonFiles("src/ct_test/fixtures"):
      let text = readFile(jsonPath)
      if text.contains("\"schemaVersion\""):
        check text.contains("\"schemaVersion\": " & $TestCatalogSchemaVersion)

    let byProvider = gateEntryByProvider()
    for info in registry.providerInfoSorted:
      checkpoint(info.id)
      check byProvider.hasKey(info.id)
      let entry = byProvider[info.id]
      check fileExists(entry.researchDoc)
      check fileExists(entry.providerTest)
      for source in entry.sourceFiles:
        check fileExists(source)
      if not entry.heavy:
        check dirExists(entry.fixturePath)
      else:
        check entry.providerTest.contains("m13_smart_contract")

      let bundle = sourceBundle(entry)
      for capability in capabilityNames(info.capabilities):
        checkpoint(info.id & " capability " & capability)
        let fieldName = case capability
          of "discover-project": "canDiscoverProject"
          of "discover-file": "canDiscoverFile"
          of "locate-tests": "canLocateTests"
          of "run-project": "canRunProject"
          of "run-file": "canRunFile"
          of "run-single": "canRunSingle"
          of "record-project": "canRecordProject"
          of "record-file": "canRecordFile"
          of "record-single": "canRecordSingle"
          of "per-test-output": "canCapturePerTestOutput"
          of "trace-entry-map": "canMapTraceEntryPoints"
          of "structured-events": "emitsStructuredEvents"
          else: capability
        check bundle.contains(fieldName) or bundle.contains(capability)

      if info.capabilities.claimsRecord:
        check bundle.contains("recordResult") or
          bundle.contains("record_trace_artifacts") or
          bundle.contains("recordCommand(")
        check bundle.contains("tekRecordingCreated")
        check bundle.contains("non-empty .ct artifact") or
          bundle.contains("getFileSize") or
          bundle.contains("recordedArtifactPath")

    for corePath in CoreViewModelGateTests:
      checkpoint(corePath)
      check fileExists(corePath)
      checkNoHardSkips(corePath)

  test "no_mock_only_gui_test_features":
    for entry in GuiActionGateEntries:
      checkpoint(entry.action)
      check fileExists(entry.mockCoverage)
      let mockText = readExisting(entry.mockCoverage)
      check mockText.contains(entry.action) or
        mockText.contains(entry.visibleSurface) or
        (entry.unsupportedDiagnostic.len > 0 and
          mockText.contains(entry.unsupportedDiagnostic))

      if entry.nonMockCoverage.len > 0:
        check fileExists(entry.nonMockCoverage)
        check entry.nonMockCoverage != entry.mockCoverage
        let nonMockText = readExisting(entry.nonMockCoverage)
        check "mock-only" notin nonMockText.toLowerAscii
      else:
        check entry.unsupportedDiagnostic.len > 0
        check mockText.contains(entry.unsupportedDiagnostic)
