import std/[json, options, os, osproc, sequtils, strutils, tables, unittest]

import contracts
import ct_test
import discovery
import frameworks/ruby_common
import frameworks/ruby_minitest
import frameworks/ruby_rspec

const
  RspecRootSelector = "spec/calculator_spec.rb:9"
  RspecAdditionSelector = "spec/calculator_spec.rb:10"
  RspecPositiveSelector = "spec/calculator_spec.rb:11"
  RspecAddsSelector = "spec/calculator_spec.rb:12"
  RspecSharedSelector = "spec/calculator_spec.rb:28"
  RspecSharedExampleSelector = "spec/calculator_spec.rb:29"
  MinitestClassSelector = "test/calculator_test.rb::CalculatorTest"
  MinitestAddsSelector = "CalculatorTest#test_adds_numbers"
  MinitestZeroSelector = "CalculatorTest#test_handles_zero"
  MinitestStringSelector = "StringFormattingTest#test_upcases"

proc rspecRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/ruby_rspec_project"

proc minitestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/ruby_minitest_project"

proc rspecSample(): string =
  rspecRoot() / "spec/calculator_spec.rb"

proc minitestSample(): string =
  minitestRoot() / "test/calculator_test.rb"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc catalogProviderIds(response: DiscoverResponse): seq[string] =
  response.catalogs.mapIt(it.provider.id)

proc allMessages(response: DiscoverResponse): string =
  for diagnostic in response.diagnostics:
    result.add diagnostic.message & "\n"
  for catalog in response.catalogs:
    for diagnostic in catalog.diagnostics:
      result.add diagnostic.message & "\n"

proc ensureRubyBundle(projectRoot: string) =
  let bundleExe = bundleExecutable()
  if bundleExe.len == 0:
    checkpoint(
      "bundle executable is required for Ruby fixture integration tests")
  check bundleExe.len > 0

  let bundleRoot = getTempDir() / "ct-ruby-fixture-bundles" /
      splitPath(projectRoot).tail
  createDir(bundleRoot)
  putEnv("BUNDLE_PATH", bundleRoot)
  putEnv("BUNDLE_APP_CONFIG", bundleRoot / ".bundle")

  let checkResult = execCmdEx(quoteShell(bundleExe) & " check",
      workingDir = projectRoot)
  if checkResult.exitCode == 0:
    return

  let installResult = execCmdEx(quoteShell(bundleExe) & " install",
      workingDir = projectRoot)
  if installResult.exitCode != 0:
    checkpoint(installResult.output)
  check installResult.exitCode == 0

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc outputContains(events: seq[TestEvent]; needle: string): bool =
  for event in events:
    if event.output.contains(needle) or event.message.contains(needle):
      return true

proc compileCtTestBinary(name: string): string =
  let binary = getTempDir() / (name & "-" & $getCurrentProcessId())
  let compile = execCmdEx(
    "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/" & name &
    " -o:" & quoteShell(binary) & " src/ct_test/ct_test.nim",
    options = {poUsePath},
    workingDir = getCurrentDir())
  if compile.exitCode != 0:
    checkpoint(compile.output)
  check compile.exitCode == 0
  if fileExists(binary):
    binary
  else:
    binary & ".out"

proc firstTrace(events: seq[TestEvent]): TraceMetadata =
  for event in events:
    if event.trace.isSome:
      return event.trace.get
  raise newException(ValueError, "missing trace metadata")

proc checkSuccessfulRun(result: ProviderResult[seq[TestEvent]]) =
  if result.diagnostics.len > 0:
    checkpoint($result.diagnostics)
    checkpoint($result.value)
  check result.diagnostics.len == 0
  check result.value.eventsOfKind(tekRunStarted).len == 1
  check result.value.eventsOfKind(tekTestStarted).len == 1
  check result.value.eventsOfKind(tekOutput).len == 1
  check result.value.eventsOfKind(tekTestFinished).len == 1
  check result.value.eventsOfKind(tekRunFinished).len == 1
  check result.value.eventsOfKind(tekTestFinished)[0].status.get == tsPassed
  for event in result.value:
    check event.validateEvent.valid

proc checkSuccessfulRecording(
    result: ProviderResult[seq[TestEvent]];
    item: TestItem;
    expectedEntryPoint: string) =
  if result.diagnostics.len > 0:
    checkpoint($result.diagnostics)
    checkpoint($result.value)
  check result.diagnostics.len == 0
  check result.value.eventsOfKind(tekRecordStarted).len == 1
  check result.value.eventsOfKind(tekTestStarted).len == 1
  check result.value.eventsOfKind(tekOutput).len == 1
  check result.value.eventsOfKind(tekRecordingCreated).len == 1
  check result.value.eventsOfKind(tekTestFinished).len == 1
  check result.value.eventsOfKind(tekRecordFinished).len == 1
  check result.value.eventsOfKind(tekRecordFinished)[0].status.get == tsPassed

  let trace = result.value.firstTrace
  check trace.backend == "ruby"
  check trace.entryPoint == expectedEntryPoint
  check trace.metadata["frameworkSelector"] == item.selector
  check trace.metadata["catalogTestId"] == item.id
  check parseInt(trace.metadata["artifactSize"]) > 0
  let artifacts = toSeq(walkFiles(trace.path / "*.ct"))
  check artifacts.len == 1
  check getFileSize(artifacts[0]) > 0
  for event in result.value:
    check event.validateEvent.valid

proc withEnvValue(name, value: string; body: proc()) =
  let
    hadValue = existsEnv(name)
    oldValue = getEnv(name)
  putEnv(name, value)
  try:
    body()
  finally:
    if hadValue:
      putEnv(name, oldValue)
    else:
      delEnv(name)

proc withoutEnvValue(name: string; body: proc()) =
  let
    hadValue = existsEnv(name)
    oldValue = getEnv(name)
  delEnv(name)
  try:
    body()
  finally:
    if hadValue:
      putEnv(name, oldValue)

suite "ct-test M9 Ruby RSpec and Minitest providers":
  test "RSpec detects project and discovers nested examples with source ranges":
    check hasRspecProject(rspecRoot())
    check not hasMinitestProject(rspecRoot())

    let catalog = rspecFileCatalog(rspecRoot(), rspecSample()).value
    check catalog.provider.id == "ruby-rspec"
    check catalog.provider.framework == "rspec"
    check catalog.provider.capabilities.canRunSingle
    check catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let root = catalog.itemBySelector(RspecRootSelector)
    let addition = catalog.itemBySelector(RspecAdditionSelector)
    let positive = catalog.itemBySelector(RspecPositiveSelector)
    let adds = catalog.itemBySelector(RspecAddsSelector)
    let shared = catalog.itemBySelector(RspecSharedSelector)
    let sharedExample = catalog.itemBySelector(RspecSharedExampleSelector)

    check root.kind == tikSuite
    check root.range.startLine == 9
    check addition.parentId == root.id
    check positive.parentId == addition.id
    check adds.kind == tikCase
    check adds.range.startLine == 12
    check adds.parentId == positive.id
    check shared.kind == tikSuite
    check "shared-example" in shared.tags
    check sharedExample.parentId == shared.id

    let allSelectors = catalog.selectors
    check "spec/calculator_spec.rb:38" notin allSelectors
    check "spec/calculator_spec.rb:39" notin allSelectors
    check catalog.items.len == 9

  test "Minitest detects project and discovers classes and test methods":
    check hasMinitestProject(minitestRoot())
    check not hasRspecProject(minitestRoot())

    let catalog = minitestFileCatalog(minitestRoot(), minitestSample()).value
    check catalog.provider.id == "ruby-minitest"
    check catalog.provider.framework == "minitest"
    check catalog.provider.capabilities.canRunSingle
    check catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let klass = catalog.itemBySelector(MinitestClassSelector)
    let adds = catalog.itemBySelector(MinitestAddsSelector)
    let zero = catalog.itemBySelector(MinitestZeroSelector)
    let stringCase = catalog.itemBySelector(MinitestStringSelector)
    check klass.kind == tikSuite
    check klass.range.startLine == 3
    check adds.kind == tikCase
    check adds.range.startLine == 4
    check adds.parentId == klass.id
    check zero.range.startLine == 8
    check stringCase.range.startLine == 14
    check "test_from_string" notin catalog.selectors.join("\n")
    check "test_from_comment" notin catalog.selectors.join("\n")
    check catalog.items.len == 5

  test "project discovery aggregates Ruby files":
    let rspecResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: rspecRoot(),
          jsonOutput: true),
      newRubyRspecProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(rspecResponse) == 0
    check rspecResponse.catalogs.len == 1
    check rspecResponse.catalogs[0].itemBySelector(RspecAddsSelector).file ==
      "spec/calculator_spec.rb"
    check rspecResponse.catalogs[0].itemBySelector(
        "spec/more_spec.rb:4").file ==
      "spec/more_spec.rb"
    check rspecResponse.catalogs[0].items.len == 11

    let minitestResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: minitestRoot(),
          jsonOutput: true),
      newRubyMinitestProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(minitestResponse) == 0
    check minitestResponse.catalogs.len == 1
    check minitestResponse.catalogs[0].itemBySelector(
        MinitestAddsSelector).file ==
      "test/calculator_test.rb"
    check minitestResponse.catalogs[0].itemBySelector(
        "MoreRubyTest#test_more_method").file ==
      "test/more_test.rb"
    check minitestResponse.catalogs[0].items.len == 7

  test "default registry selects matching Ruby provider":
    let rspecResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: rspecRoot(),
          file: rspecSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(rspecResponse) == 0
    check "ruby-rspec" in rspecResponse.catalogProviderIds
    check "ruby-minitest" notin rspecResponse.catalogProviderIds

    let minitestResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: minitestRoot(),
          file: minitestSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(minitestResponse) == 0
    check "ruby-minitest" in minitestResponse.catalogProviderIds
    check "ruby-rspec" notin minitestResponse.catalogProviderIds

  test "command construction is explicit for project file and single scopes":
    check buildRubyCommand(rfkRSpec, rspecRoot(), rspecSample(),
        RspecAddsSelector, rcsProject) == @["bundle", "exec", "rspec"]
    check buildRubyCommand(rfkRSpec, rspecRoot(), rspecSample(),
        RspecAddsSelector, rcsFile) == @[
          "bundle", "exec", "rspec", "spec/calculator_spec.rb"]
    check buildRubyCommand(rfkRSpec, rspecRoot(), rspecSample(),
        RspecAddsSelector, rcsSingle) == @[
          "bundle", "exec", "rspec", RspecAddsSelector]

    check buildRubyCommand(rfkMinitest, minitestRoot(), minitestSample(),
        MinitestAddsSelector, rcsProject) == @[
          "bundle", "exec", "ruby", "-Itest", "-e",
          "Dir['test/**/*_test.rb'].sort.each { |f| require_relative f }"]
    check buildRubyCommand(rfkMinitest, minitestRoot(), minitestSample(),
        MinitestAddsSelector, rcsFile) == @[
          "bundle", "exec", "ruby", "-Itest", "test/calculator_test.rb"]
    check buildRubyCommand(rfkMinitest, minitestRoot(), minitestSample(),
        MinitestAddsSelector, rcsSingle) == @[
          "bundle", "exec", "ruby", "-Itest", "test/calculator_test.rb",
          "--name", "/CalculatorTest#test_adds_numbers$/"]

  test "recorder resolution prefers explicit path then workspace sibling":
    let
      siblingCli = getCurrentDir().parentDir / "codetracer-ruby-recorder" /
        "gems" / "codetracer-ruby-recorder" / "bin" /
        "codetracer-ruby-recorder"
      fakeDir = getTempDir() / ("ct-ruby-fake-recorder-" &
        $getCurrentProcessId())
      fakeCli = fakeDir / "codetracer-ruby-recorder"
      configuredCli = fakeDir / "configured-recorder"
      oldPath = getEnv("PATH")
    createDir(fakeDir)
    writeFile(fakeCli, "#!/bin/sh\nexit 1\n")
    writeFile(configuredCli, "#!/bin/sh\nexit 1\n")
    setFilePermissions(fakeCli, {fpUserExec, fpUserRead, fpUserWrite})
    setFilePermissions(configuredCli, {fpUserExec, fpUserRead, fpUserWrite})

    withEnvValue("PATH", fakeDir & PathSep & oldPath):
      withEnvValue("CODETRACER_RUBY_RECORDER_PATH", configuredCli):
        check rubyRecorderCommandPrefix() == @[configuredCli]

      withoutEnvValue("CODETRACER_RUBY_RECORDER_PATH"):
        if fileExists(siblingCli):
          check rubyRecorderCommandPrefix() == @[rubyExecutable(), siblingCli]
        else:
          check rubyRecorderCommandPrefix() == @[fakeCli]

    if fileExists(siblingCli):
      let oldCwd = getCurrentDir()
      setCurrentDir(getTempDir())
      try:
        withEnvValue("PATH", fakeDir & PathSep & oldPath):
          withoutEnvValue("CODETRACER_RUBY_RECORDER_PATH"):
            check rubyRecorderCommandPrefix() == @[rubyExecutable(), siblingCli]
      finally:
        setCurrentDir(oldCwd)

  test "recording failure diagnostics include command cwd out dir and no-output marker":
    if findExe("ruby").len == 0:
      checkpoint("Ruby is required for recording failure diagnostics coverage")
    else:
      let
        fakeDir = getTempDir() / ("ct-ruby-silent-recorder-" &
          $getCurrentProcessId())
        recorder = fakeDir / "codetracer-ruby-recorder"
      createDir(fakeDir)
      writeFile(recorder, "#!/bin/sh\nexit 7\n")
      setFilePermissions(recorder, {fpUserExec, fpUserRead, fpUserWrite})

      let
        catalog = minitestFileCatalog(minitestRoot(), minitestSample()).value
        item = catalog.itemBySelector(MinitestAddsSelector)
        provider = newRubyMinitestM1Provider()
        scope = TestScope(
          kind: tskSingle,
          projectRoot: minitestRoot(),
          file: minitestSample(),
          testId: item.id,
          selector: item.selector)

      withEnvValue("CODETRACER_RUBY_RECORDER_PATH", recorder):
        let result = provider.provider.record(scope)
        check result.diagnostics.len == 1
        check result.diagnostics[0].message.contains("recorderCommand: " &
          quoteShell(recorder))
        check result.diagnostics[0].message.contains("cwd: " & minitestRoot())
        check result.diagnostics[0].message.contains("outDir: ")
        check result.diagnostics[0].message.contains("exitStatus: 7")
        check result.diagnostics[0].message.contains(
          "<no stdout/stderr captured>")
        check result.value.eventsOfKind(tekFailure).len == 1
        check result.value.eventsOfKind(tekFailure)[0].output.contains(
          "<no stdout/stderr captured>")

  test "Ruby result parsers map RSpec JSON and Minitest summary statuses":
    let rspecJson = %*{
      "examples": [
        {
          "id": "./spec/calculator_spec.rb[1:1:1]",
          "full_description": "RubySliceCalculator addition adds numbers",
          "status": "passed",
          "run_time": 0.012
        },
        {
          "id": "./spec/calculator_spec.rb[1:1:2]",
          "full_description": "RubySliceCalculator pending case",
          "status": "pending",
          "run_time": 0.0
        }
      ]
    }
    let events = parseRspecJsonResults("ruby-rspec", "run-1", $rspecJson)
    check events.len == 2
    check events[0].status.get == tsPassed
    check events[0].durationMs == 12
    check events[1].status.get == tsSkipped

    let minitestPassed = parseMinitestSummary(
      "ruby-minitest",
      "run-2",
      MinitestAddsSelector,
      "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips")
    let minitestFailed = parseMinitestSummary(
      "ruby-minitest",
      "run-3",
      MinitestAddsSelector,
      "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips")
    check minitestPassed.status.get == tsPassed
    check minitestFailed.status.get == tsFailed

  test "RSpec runs one real nested example through bundle exec rspec":
    ensureRubyBundle(rspecRoot())
    let catalog = rspecFileCatalog(rspecRoot(), rspecSample()).value
    let nested = catalog.itemBySelector(RspecAddsSelector)
    let provider = newRubyRspecM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskSingle,
      projectRoot: rspecRoot(),
      file: rspecSample(),
      testId: nested.id,
      selector: nested.selector))

    checkSuccessfulRun(runResult)
    check runResult.value.outputContains("1 example, 0 failures")

  test "Minitest runs one real test method through bundle exec ruby":
    ensureRubyBundle(minitestRoot())
    let catalog = minitestFileCatalog(minitestRoot(), minitestSample()).value
    let item = catalog.itemBySelector(MinitestAddsSelector)
    let provider = newRubyMinitestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskSingle,
      projectRoot: minitestRoot(),
      file: minitestSample(),
      testId: item.id,
      selector: item.selector))

    checkSuccessfulRun(runResult)
    check runResult.value.outputContains(
      "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips")

  test "RSpec records one real nested example to non-empty CTFS":
    ensureRubyBundle(rspecRoot())
    let catalog = rspecFileCatalog(rspecRoot(), rspecSample()).value
    let nested = catalog.itemBySelector(RspecAddsSelector)
    let provider = newRubyRspecM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: rspecRoot(),
      file: rspecSample(),
      testId: nested.id,
      selector: nested.selector))

    checkSuccessfulRecording(recordResult, nested, "spec/calculator_spec.rb")
    check recordResult.value.outputContains("1 example, 0 failures")

    let mapped = mapTraceByCatalogId("ruby-rspec", catalog,
      @[recordResult.value.firstTrace]).value
    check mapped.hasKey(nested.id)
    check mapped[nested.id].metadata["frameworkSelector"] == nested.selector
    check mapped[nested.id].metadata["catalogTestId"] == nested.id

  test "Minitest records one real test method to non-empty CTFS":
    ensureRubyBundle(minitestRoot())
    let catalog = minitestFileCatalog(minitestRoot(), minitestSample()).value
    let item = catalog.itemBySelector(MinitestAddsSelector)
    let provider = newRubyMinitestM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: minitestRoot(),
      file: minitestSample(),
      testId: item.id,
      selector: item.selector))

    checkSuccessfulRecording(recordResult, item, "test/calculator_test.rb")
    check recordResult.value.outputContains(
      "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips")

    let mapped = mapTraceByCatalogId("ruby-minitest", catalog,
      @[recordResult.value.firstTrace]).value
    check mapped.hasKey(item.id)
    check mapped[item.id].metadata["frameworkSelector"] == item.selector
    check mapped[item.id].metadata["catalogTestId"] == item.id

  test "run and record report honest diagnostics without Ruby runtime":
    let catalog = rspecFileCatalog(rspecRoot(), rspecSample()).value
    let nested = catalog.itemBySelector(RspecAddsSelector)
    let provider = newRubyRspecM1Provider()
    let scope = TestScope(
      kind: tskSingle,
      projectRoot: rspecRoot(),
      file: rspecSample(),
      testId: nested.id,
      selector: nested.selector)
    let runResult = provider.provider.run(scope)
    let recordResult = provider.provider.record(scope)
    if findExe("ruby").len == 0:
      check runResult.value.len == 0
      check recordResult.value.len == 0
      check runResult.diagnostics[0].message.contains("Ruby is required")
      check recordResult.diagnostics[0].message.contains("Ruby is required")
    else:
      check runResult.value.len > 0 or runResult.diagnostics.len > 0
      check recordResult.value.len > 0 or recordResult.diagnostics.len > 0

  test "CLI JSON includes Ruby provider catalog":
    let executable = compileCtTestBinary("ct-test-m9-ruby-cli")
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", rspecSample(), "--json"],
      options = {poUsePath},
      workingDir = rspecRoot())
    let node = parseJson(output)
    check node["schemaVersion"].getInt == 1
    check node["catalogs"].len == 1
    check node["catalogs"][0]["provider"]["id"].getStr == "ruby-rspec"
    check node["catalogs"][0]["items"][0]["file"].getStr ==
      "spec/calculator_spec.rb"
