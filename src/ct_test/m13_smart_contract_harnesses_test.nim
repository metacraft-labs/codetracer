import std/[options, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/smart_contract_common
import frameworks/smart_contract_harnesses

proc workspaceRoot(): string =
  getCurrentDir().parentDir

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc firstFixture(spec: SmartHarnessSpec): string =
  let fixtures = spec.fixtureFiles(workspaceRoot())
  if fixtures.len == 0:
    return ""
  fixtures[0]

proc clearRecorderEnv(spec: SmartHarnessSpec) =
  putEnv(spec.envCommand, "")

proc firstCreatedTrace(events: seq[TestEvent]): Option[TraceMetadata] =
  for event in events:
    if event.kind == tekRecordingCreated and event.trace.isSome:
      return event.trace
  none(TraceMetadata)

proc recordedArtifactPath(trace: TraceMetadata): string =
  let direct = trace.path / trace.recordingId
  if fileExists(direct):
    return direct
  let ct = trace.path / (trace.recordingId & ".ct")
  if fileExists(ct):
    return ct
  ""

suite "ct-test M13 harness discovery is bounded and deterministic":
  ## Discovery must answer with the tests the *named* workspace contains, and
  ## must answer the same way twice. It did neither: `findRecorderRepo` seeded
  ## its search with `getCurrentDir()` and walked up through `projectRoot`'s
  ## ancestors, so the same `--workspace` yielded 1 catalog / 11 items from
  ## `$HOME` and 15 catalogs / 341 items from a checkout inside the multi-repo
  ## workspace — the 330 extras being fixtures of sibling repositories the
  ## caller never named, which nothing downstream could run or attest.

  proc unrelatedRoot(name: string): string =
    ## A workspace that is nobody's recorder repo and contains none: the shape
    ## of `--workspace /some/project` typed by a user who has a CodeTracer
    ## checkout somewhere else on the same disk.
    result = getTempDir() / ("ct-m13-unrelated-" & name & "-" &
      $getCurrentProcessId())
    createDir(result / "spec")
    writeFile(result / "spec" / "a_spec.rb", "# not a recorder repo\n")

  test "recorder repo resolution ignores the process working directory":
    let elsewhere = unrelatedRoot("cwd")
    defer: removeDir(elsewhere)
    let originalDir = getCurrentDir()
    defer: setCurrentDir(originalDir)
    let root = workspaceRoot()
    var resolved = 0
    for spec in smartHarnessSpecs():
      let fromRepoDir = spec.findRecorderRepo(root)
      # The answer may not change with the shell's directory …
      setCurrentDir(elsewhere)
      check spec.findRecorderRepo(root) == fromRepoDir
      setCurrentDir(originalDir)
      if fromRepoDir.len > 0:
        inc resolved
        check isInsideWorkspace(root, fromRepoDir)
      # … and a workspace that contains no recorder repo may not acquire one
      # from wherever the process happens to be standing.
      check spec.findRecorderRepo(elsewhere) == ""
      setCurrentDir(elsewhere)
      check spec.findRecorderRepo(elsewhere) == ""
      setCurrentDir(originalDir)
      # No project root at all resolves to nothing, deterministically. This is
      # the value `newSmartHarnessProvider` stores in the registry; it used to
      # be read out of the working directory.
      check spec.findRecorderRepo("") == ""
    checkpoint("recorder repos resolved from the workspace root: " & $resolved)

  test "fixture discovery never leaves the workspace root":
    let elsewhere = unrelatedRoot("fixtures")
    defer: removeDir(elsewhere)
    let root = workspaceRoot()
    for spec in smartHarnessSpecs():
      clearRecorderEnv(spec)
      let provider = newSmartHarnessProvider(spec)
      # Nothing is discovered for a workspace with no recorder repo in it …
      check not provider.provider.detect(elsewhere).value
      check spec.fixtureFiles(elsewhere).len == 0
      check provider.provider.discoverProject(elsewhere).value.items.len == 0
      # … and a fixture of *another* repository is not a test of this one,
      # even when the caller names the file explicitly.
      let fixture = spec.firstFixture()
      if fixture.len > 0:
        check provider.provider.discoverFile(elsewhere, fixture).value.items.len == 0
      # Whatever IS discovered lies inside the root that was named.
      for path in spec.fixtureFiles(root):
        check isInsideWorkspace(root, path)

  test "catalog item paths are workspace-relative and resolve":
    ## `run_orchestration.scopeForItem` builds the path the recorder is invoked
    ## on as `workspaceRoot / item.file`, and `certificate_issuance` names that
    ## same relative path as what the run covered. A repo-relative spelling
    ## made both false: the recorder was handed a path that does not exist, and
    ## a certificate would have claimed `test-programs/…` of a repository with
    ## no such file.
    let root = workspaceRoot()
    for spec in smartHarnessSpecs():
      clearRecorderEnv(spec)
      let catalog = newSmartHarnessProvider(spec).provider.discoverProject(
          root).value
      for item in catalog.items:
        check not isAbsolute(item.file)
        check not item.file.startsWith("../")
        checkpoint(spec.providerId & " item file: " & item.file)
        check fileExists(root / item.file)

suite "ct-test M13 smart-contract and VM recorder harnesses":
  test "provider registry includes every M13 harness provider":
    let registry = newDefaultProviderRegistry()
    let providerIds = registry.providers.mapIt(it.provider.info.id)
    for spec in smartHarnessSpecs():
      check spec.providerId in providerIds

  test "sibling recorder repositories are detected":
    for spec in smartHarnessSpecs():
      clearRecorderEnv(spec)
      let provider = newSmartHarnessProvider(spec)
      let detected = provider.provider.detect(workspaceRoot())
      check detected.value

      let catalog = provider.provider.discoverProject(workspaceRoot()).value
      checkpoint(spec.providerId & " items=" & $catalog.items.len)
      check catalog.provider.id == spec.providerId
      check catalog.provider.capabilities.canDiscoverProject
      check catalog.provider.capabilities.canDiscoverFile
      check catalog.provider.capabilities.canLocateTests
      check not catalog.provider.capabilities.canRunSingle
      check not catalog.provider.capabilities.canRecordSingle
      check catalog.diagnostics.len >= 1
      check catalog.validateCatalog.valid
      if spec.recordMode == shrmUnsupported:
        check not catalog.provider.capabilities.canRecordFile
      elif spec.configuredRecorderCommand(workspaceRoot()).len > 0:
        check catalog.provider.capabilities.canRunFile
        check catalog.provider.capabilities.canRecordFile
      else:
        check not catalog.provider.capabilities.canRunFile
        check not catalog.provider.capabilities.canRecordFile
        check catalog.diagnostics.anyIt(it.message.contains(spec.envCommand))

      if spec.fixtureFiles(workspaceRoot()).len > 0:
        check catalog.items.len > 0
        let fixture = spec.firstFixture()
        let fileCatalog = provider.provider.discoverFile(workspaceRoot(),
            fixture).value
        check fileCatalog.items.len == 1
        check catalog.itemBySelector(fileCatalog.items[0].selector).id ==
          fileCatalog.items[0].id

  test "unavailable recorders return precise diagnostics":
    for spec in smartHarnessSpecs():
      clearRecorderEnv(spec)
      if spec.recordMode == shrmUnsupported:
        continue
      let fixture = spec.firstFixture()
      if fixture.len == 0:
        continue
      let provider = newSmartHarnessProvider(spec)
      let catalog = provider.provider.discoverFile(workspaceRoot(),
          fixture).value
      let item = catalog.items[0]
      if catalog.provider.capabilities.canRecordFile:
        check spec.configuredRecorderCommand(workspaceRoot()).len > 0
        continue
      check not catalog.provider.capabilities.canRunFile
      let recordResult = provider.provider.record(TestScope(kind: tskFile,
          projectRoot: workspaceRoot(), file: fixture, selector: item.selector,
          testId: item.id))
      check recordResult.value.len == 0
      check recordResult.diagnostics.len == 1
      check recordResult.diagnostics[0].message.contains(spec.recorderBinary)
      check recordResult.diagnostics[0].message.contains(spec.envCommand)

  test "invalid configured recorder command disables record":
    let nonExecutable = getTempDir() / ("ct-m13-non-executable-" &
      $getCurrentProcessId())
    writeFile(nonExecutable, "not executable\n")
    let fakeRecorder = getTempDir() / ("ct-m13-fake-recorder-" &
      $getCurrentProcessId())
    writeFile(fakeRecorder,
      "#!/bin/sh\nmkdir -p \"$5\"\nprintf fake > \"$5/fake.ct\"\n")
    setFilePermissions(fakeRecorder, {fpUserExec, fpUserRead, fpUserWrite})
    for spec in smartHarnessSpecs():
      if spec.recordMode == shrmUnsupported:
        continue
      let fixture = spec.firstFixture()
      if fixture.len == 0:
        continue
      for configured in [getTempDir() / "ct-m13-missing-recorder",
          nonExecutable, fakeRecorder]:
        putEnv(spec.envCommand, configured)
        let provider = newSmartHarnessProvider(spec)
        let catalog = provider.provider.discoverFile(workspaceRoot(),
            fixture).value
        check not catalog.provider.capabilities.canRunFile
        check not catalog.provider.capabilities.canRecordFile
        let item = catalog.items[0]
        let recordResult = provider.provider.record(TestScope(kind: tskFile,
            projectRoot: workspaceRoot(), file: fixture,
                selector: item.selector,
            testId: item.id))
        check recordResult.value.len == 0
        check recordResult.diagnostics.len == 1
        check recordResult.diagnostics[0].message.contains(spec.recorderBinary)
        check recordResult.diagnostics[0].message.contains(spec.envCommand)

  test "smart_contract_harnesses_record_trace_artifacts":
    var available = 0
    var unavailable = 0
    for spec in smartHarnessSpecs():
      clearRecorderEnv(spec)
      if spec.recordMode == shrmUnsupported:
        continue
      let fixture = spec.firstFixture()
      if fixture.len == 0:
        continue
      let provider = newSmartHarnessProvider(spec)
      let catalog = provider.provider.discoverFile(workspaceRoot(),
          fixture).value
      let item = catalog.items[0]
      if spec.configuredRecorderCommand(workspaceRoot()).len == 0:
        inc unavailable
        check not catalog.provider.capabilities.canRunFile
        check not catalog.provider.capabilities.canRecordFile
        check catalog.diagnostics.anyIt(
          it.message.contains(spec.recorderBinary) and
          it.message.contains(spec.envCommand))
        continue

      inc available
      check catalog.provider.capabilities.canRunFile
      check catalog.provider.capabilities.canRecordFile
      let recordResult = provider.provider.record(TestScope(kind: tskFile,
          projectRoot: workspaceRoot(), file: fixture, selector: item.selector,
          testId: item.id))
      if recordResult.diagnostics.len > 0:
        checkpoint(spec.providerId & " diagnostics: " &
            $recordResult.diagnostics)
        checkpoint(spec.providerId & " events: " & $recordResult.value)
      check recordResult.diagnostics.len == 0
      let trace = recordResult.value.firstCreatedTrace()
      check trace.isSome
      if trace.isSome:
        let artifact = trace.get.recordedArtifactPath()
        checkpoint(spec.providerId & " artifact: " & artifact)
        check artifact.len > 0
        if artifact.len > 0:
          check fileExists(artifact)
          check getFileSize(artifact) > 0
      for event in recordResult.value:
        check event.validateEvent.valid
    checkpoint("locally available M13 recorder binaries: " & $available)
    checkpoint("locally unavailable M13 recorder binaries: " & $unavailable)

  test "default CLI JSON discovers an M13 catalog item":
    let binary = getTempDir() / ("ct-test-m13-cli-" & $getCurrentProcessId())
    let compile = execCmdEx(
      "nim c --hints:off --warnings:off " &
      "--nimcache:/tmp/ct-nim-cache/ct-test-m13-cli " &
      "-o:" & quoteShell(binary) & " src/ct_test/ct_test.nim",
      options = {poUsePath},
      workingDir = getCurrentDir())
    if compile.exitCode != 0:
      checkpoint(compile.output)
    check compile.exitCode == 0
    let fixture = cairoSpec().firstFixture()
    if fixture.len == 0:
      skip()
    else:
      # `--workspace` is passed explicitly, and must be: the recorder repo is
      # located inside the workspace the caller names, never inferred from the
      # directory this test process happens to be running in. Without it the
      # CLI defaults the root to the current directory (the `codetracer`
      # checkout), which does not contain `codetracer-cairo-recorder` — so
      # there is nothing to discover, and that is the correct answer.
      let output = execProcess(binary,
        args = @["test", "discover", "--workspace", workspaceRoot(),
                 "--file", fixture, "--json"],
        options = {poUsePath},
        workingDir = getCurrentDir())
      check output.contains("\"id\": \"smart-cairo\"")
      check output.contains("\"selector\"")

      let unbounded = execProcess(binary,
        args = @["test", "discover", "--file", fixture, "--json"],
        options = {poUsePath},
        workingDir = getCurrentDir())
      check not unbounded.contains("\"id\": \"smart-cairo\"")
