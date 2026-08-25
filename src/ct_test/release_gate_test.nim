import std/[algorithm, os, osproc, sequtils, strutils, tables, unittest]

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

proc laneFilesFor(lane: string): seq[string] =
  ## Ask `ci/lib/test-lane-files.sh` what a lane ACTUALLY runs, rather than
  ## pattern-matching the shell that computes it.
  ##
  ## A plain `proc` is correct here because it only COMPUTES. Nothing in it
  ## calls `check`: `std/unittest`'s `check` needs `testStatusIMPL` in scope to
  ## mark a case failed, and inside a `proc` there is none, so a failing
  ## `check` prints its message, sets `programResult` and lets the case report
  ## `[OK]`. That is the first defect variant this campaign found; the
  ## assertions live in the `template` below for exactly that reason.
  let (output, exitCode) = execCmdEx(
    "bash -c 'source ci/lib/test-lane-files.sh && test_lane_files " & lane & "'")
  if exitCode != 0:
    raise newException(IOError,
      "could not resolve lane '" & lane & "': " & output)
  for line in output.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add trimmed

template checkCliLaneCovers(gateTests: untyped) =
  ## Assert that `src/tests/cli` is actually REACHED by a lane, end to end.
  ##
  ## A `template`, not a `proc`, and that distinction is load-bearing: `check`
  ## only marks a case failed where `testStatusIMPL` is in scope, which is
  ## inside a `test` body. A template is inlined into that body; a proc is not,
  ## and every `check` in it would print-but-not-fail. Measured on this very
  ## helper with the recipe/runner link severed: as a proc, 5 OK / 0 FAILED; as
  ## a template, 2 OK / 3 FAILED.
  ##
  ## What it replaced: `justfile.contains("find src/tests/cli -name '*_test.nim'")`
  ## — a literal match on the glob's text, which pinned WHERE the glob was
  ## written rather than THAT the directory is covered. The glob now lives in
  ## `ci/lib/test-lane-files.sh`, so that string moved and three gate cases went
  ## red without a single test losing coverage.
  ##
  ## The replacement pins two links and then ASKS for the third rather than
  ## grepping for it:
  ##   1. the recipe exists and delegates to the shared runner (justfile text —
  ##      there is nothing else to interrogate there);
  ##   2. the lane, actually executed, lists every gate file by path. This is
  ##      immune to how the lane spells its glob (quoting style, `find` vs a
  ##      helper, one pattern or three), which a third pinned literal was not.
  check fileExists("justfile")
  let justfileText = readExisting("justfile")
  check justfileText.contains("test-cli-record:")
  check justfileText.contains("run-nim-test-lane.sh cli-record")

  let laneSet = laneFilesFor("cli-record")
  # A lane that resolves to nothing would make every membership check below
  # vacuously... false, actually — but say it out loud anyway, because an empty
  # lane is a different bug from a missing file and deserves its own message.
  check laneSet.len > 0
  for gatePath in gateTests:
    checkpoint(gatePath)
    check laneSet.contains(gatePath)

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

  test "cli_record_gate_tests_exist_and_are_registered":
    # Same gate contract as CoreViewModelGateTests, for the `ct record`
    # dispatch lane: the files must exist and must not be skip-disabled.
    for cliPath in CliRecordGateTests:
      checkpoint(cliPath)
      check fileExists(cliPath)
      checkNoHardSkips(cliPath)

    # ... and a gate entry with no runner is the "registered in only one place
    # runs nowhere" failure this repo has hit repeatedly, so the lane that
    # reaches these files is asserted here rather than assumed.
    checkCliLaneCovers(CliRecordGateTests)

  test "cli_review_gate_tests_exist_and_are_registered":
    # RV-1: the `ct review` CLI lane.  Same contract as the record lane, and
    # deliberately the same runner — `test-cli-record`'s glob covers the whole
    # of `src/tests/cli` — so the "registered in only one place runs nowhere"
    # failure cannot recur here either.
    for cliPath in CliReviewGateTests:
      checkpoint(cliPath)
      check fileExists(cliPath)
      checkNoHardSkips(cliPath)

    checkCliLaneCovers(CliReviewGateTests)

  test "cli_agent_gate_tests_exist_and_are_registered":
    # RV-7: the `ct agent` CLI lane, on the same runner as the two above.
    for cliPath in CliAgentGateTests:
      checkpoint(cliPath)
      check fileExists(cliPath)
      checkNoHardSkips(cliPath)

    checkCliLaneCovers(CliAgentGateTests)

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
