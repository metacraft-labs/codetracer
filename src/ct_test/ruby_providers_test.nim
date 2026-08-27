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

proc withCurrentDir(dir: string; body: proc()) =
  let old = getCurrentDir()
  setCurrentDir(dir)
  try:
    body()
  finally:
    setCurrentDir(old)

proc pathWithout(executable: string): string =
  ## The current ``PATH`` with every directory that provides ``executable``
  ## removed.
  ##
  ## A resolution test has to pin the *order* of the fallbacks, which means
  ## knowing the recorder is not reachable by an earlier one — and
  ## ``scripts/detect-siblings.sh`` puts a real ``codetracer-ruby-recorder`` on
  ## ``PATH`` in the dev shell. Rebuilding ``PATH`` from scratch would hide it
  ## but would also take ``ruby`` and ``sh`` away from the command under test;
  ## prepending a directory cannot remove anything. Subtracting exactly the
  ## providers of one name leaves the rest of the environment intact.
  var kept: seq[string] = @[]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0 and fileExists(dir / executable):
      continue
    kept.add dir
  kept.join($PathSep)

proc writeExecutable(path, contents: string) =
  createDir(path.parentDir)
  writeFile(path, contents)
  setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite})

proc diagnosticText(runResult: ProviderResult[seq[TestEvent]]): string =
  var parts: seq[string] = @[]
  for item in runResult.diagnostics:
    parts.add $item.severity & ": " & item.message
  parts.join("\n")

proc rspecScratchProject(
    name, specFileName, specSource: string;
    rspecOptions = ""): string =
  ## Materialise a throwaway rspec project for one test.
  ##
  ## The Gemfile and Gemfile.lock are copied verbatim from
  ## ``fixtures/ruby_rspec_project``, so once ``ensureRubyBundle(rspecRoot())``
  ## has installed that bundle (and pointed ``BUNDLE_PATH`` at it) this project
  ## resolves against the same gems with no second install and no network.
  ##
  ## Scratch rather than a checked-in fixture on purpose: the workspace-scope
  ## discovery assertions above pin ``ruby_rspec_project``'s exact item count,
  ## so a new spec file dropped in there would break a test that has nothing to
  ## do with skips.
  result = getTempDir() / (name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "spec")
  copyFile(rspecRoot() / "Gemfile", result / "Gemfile")
  copyFile(rspecRoot() / "Gemfile.lock", result / "Gemfile.lock")
  if rspecOptions.len > 0:
    writeFile(result / ".rspec", rspecOptions)
  writeFile(result / "spec" / specFileName, specSource)

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

  test "recorder resolution is anchored to the workspace, not the cwd":
    ## REGRESSION. ``rubyRecorderCommandPrefix`` took no arguments and searched
    ## two directories the caller never named: ``getCurrentDir().parentDir``
    ## and ``currentSourcePath()``'s fifth parent. Measured against the pre-fix
    ## binary, one workspace, one environment, varying only the cwd:
    ##
    ##   cwd beside the workspace  → the workspace's own recorder
    ##   cwd = $HOME               → the recorder beside the SOURCE TREE this
    ##                               binary was compiled from
    ##
    ## The second answer is deterministic and still wrong: it names a
    ## repository chosen at compile time on the build machine. It is also why
    ## Ruby resolution appeared to work where the otherwise identical
    ## JavaScript resolution did not, which made one defect look like two.
    ##
    ## The recorder here is a stub. Whether it can record is a different
    ## question, asked by the recording tests; this one is about which binary
    ## is chosen and what that choice is allowed to depend on.
    if rubyExecutable().len == 0:
      checkpoint("ruby is required for recorder-resolution coverage")
    check rubyExecutable().len > 0

    let
      sandbox = getTempDir() / ("ct-ruby-recorder-anchor-" &
        $getCurrentProcessId())
      workspace = sandbox / "workspace"
      recorderRepo = workspace / "codetracer-ruby-recorder"
      bareWorkspace = sandbox / "bare-workspace"
      elsewhere = sandbox / "elsewhere"
      workspaceCli = recorderRepo / "gems" / "codetracer-ruby-recorder" /
        "bin" / "codetracer-ruby-recorder"
      pathDir = sandbox / "path-bin"
      pathCli = pathDir / "codetracer-ruby-recorder"
      configuredCli = pathDir / "configured-recorder"
      expected = @[rubyExecutable(), workspaceCli]
    removeDir(sandbox)
    for dir in [workspace, bareWorkspace, elsewhere, pathDir]:
      createDir(dir)
    defer: removeDir(sandbox)
    writeExecutable(workspaceCli, "#!/bin/sh\nexit 1\n")
    writeExecutable(pathCli, "#!/bin/sh\nexit 1\n")
    writeExecutable(configuredCli, "#!/bin/sh\nexit 1\n")

    # The recorder must not be reachable by a fallback other than the one each
    # case is about; the dev shell puts a real one on PATH.
    let neutralPath = pathWithout("codetracer-ruby-recorder")

    withEnvValue("PATH", neutralPath):
      withoutEnvValue("CODETRACER_RUBY_RECORDER_PATH"):
        # THE REGRESSION: one workspace, one answer, from every cwd.
        for cwd in [elsewhere, sandbox, getCurrentDir()]:
          withCurrentDir(cwd):
            checkpoint("cwd=" & cwd)
            check rubyRecorderCommandPrefix(workspace) == expected
            # The workspace root may also BE the recorder checkout
            # (`ct test --workspace codetracer-ruby-recorder`).
            check rubyRecorderCommandPrefix(recorderRepo) == expected
            # A workspace that does not contain it resolves to nothing rather
            # than borrowing a recorder from somewhere the caller never named.
            check rubyRecorderCommandPrefix(bareWorkspace).len == 0
            check rubyRecorderCommandPrefix("").len == 0

    # PRECEDENCE, unchanged by the anchoring: an explicit path outranks
    # everything, and the workspace checkout outranks PATH (a recorder shipped
    # with the workspace matches the Gemfile the tests were written against).
    # Asserted from a cwd whose parent holds no recorder, so a pass cannot come
    # from the removed fallback.
    withCurrentDir(elsewhere):
      withEnvValue("PATH", pathDir & PathSep & neutralPath):
        withEnvValue("CODETRACER_RUBY_RECORDER_PATH", configuredCli):
          check rubyRecorderCommandPrefix(workspace) == @[configuredCli]
        withoutEnvValue("CODETRACER_RUBY_RECORDER_PATH"):
          check rubyRecorderCommandPrefix(workspace) == expected
          check rubyRecorderCommandPrefix(bareWorkspace) == @[pathCli]

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
    let parsed = parseRspecJsonResults("ruby-rspec", "run-1", $rspecJson)
    check parsed.usable
    check parsed.reason.len == 0
    let events = parsed.events
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

  test "RSpec reports a pending example as skipped rather than as a pass":
    ## THE REGRESSION. rspec exits 0 for a suite in which every example is
    ## `pending`, and the provider's only status source was that exit code, so
    ## an all-pending file reported `tsPassed` — which
    ## `certificate_issuance.recordUnitResult` then counted as an executed test
    ## and claimed as a covered target. Measured through the shipped
    ## `ct-test test run` CLI on exactly this suite, before the fix:
    ##
    ##   executed 3, passed 3, skipped 0, verdict "passed", exit 0
    ##   certificate ISSUED, targets = ["spec/pending_spec.rb"]
    ##
    ## after:
    ##
    ##   executed 0, skipped 4, verdict "nothing-executed", exit 2
    ##   certificate WITHHELD (wrNoTestsExecuted), no target claimed
    ##
    ## A skip must land on `tsSkipped` and NOT on `tsFailed`: the point is that
    ## skips stop being claimed as passes, not that they start reddening
    ## suites, so this asserts the run carries no failure and no diagnostic
    ## either.
    ensureRubyBundle(rspecRoot())
    let project = rspecScratchProject("ct-rspec-pending", "pending_spec.rb", """
RSpec.describe "all pending" do
  it "is skipped", skip: "not implemented yet" do
    expect(1).to eq(2)
  end

  it "is also skipped", skip: "still not implemented" do
    expect(1).to eq(3)
  end
end
""")
    defer: removeDir(project)

    let provider = newRubyRspecM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "spec" / "pending_spec.rb",
      selector: "spec/pending_spec.rb"))

    if runResult.diagnostics.len > 0:
      checkpoint(runResult.diagnosticText)
    check runResult.diagnostics.len == 0

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 2
    for event in finished:
      check event.status.get == tsSkipped
    check runResult.value.eventsOfKind(tekFailure).len == 0
    check runResult.value.eventsOfKind(tekRunFinished).len == 1
    for event in runResult.value.eventsOfKind(tekRunFinished):
      check event.status.get == tsSkipped

    # `--format json --out FILE` alone would have silenced rspec's terminal
    # output entirely; the explicit `--format progress` beside it is what keeps
    # this line in the captured stream.
    check runResult.value.outputContains("2 examples, 0 failures, 2 pending")
    for event in runResult.value:
      check event.validateEvent.valid

  test "RSpec still reports a real failure as a failure":
    ## The counterpart to the test above, and the reason it is a separate case:
    ## routing status through rspec's JSON must not turn failures into skips
    ## either. A file with one passing and one failing example must report
    ## exactly that, with the failure's message carried on a `tekFailure`.
    ensureRubyBundle(rspecRoot())
    let project = rspecScratchProject("ct-rspec-mixed", "mixed_spec.rb", """
RSpec.describe "mixed" do
  it "passes" do
    expect(1 + 1).to eq(2)
  end

  it "fails" do
    expect(1).to eq(2)
  end

  it "is skipped", skip: "not implemented yet" do
    expect(1).to eq(3)
  end
end
""")
    defer: removeDir(project)

    let provider = newRubyRspecM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "spec" / "mixed_spec.rb",
      selector: "spec/mixed_spec.rb"))

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 3
    var passed, failed, skipped = 0
    for event in finished:
      case event.status.get(tsErrored)
      of tsPassed: inc passed
      of tsFailed, tsErrored: inc failed
      of tsSkipped: inc skipped
    check passed == 1
    check failed == 1
    check skipped == 1
    check runResult.value.eventsOfKind(tekFailure).len == 1
    check runResult.diagnostics.len == 1
    check runResult.diagnosticText.contains(
      "rspec reported at least one failing example")
    for event in runResult.value:
      check event.validateEvent.valid

  test "an rspec run that writes no JSON falls back to its exit code and says so":
    ## The fallback must survive, and must be AUDIBLE. An invalid option in
    ## `.rspec` makes rspec abort during option parsing, before any formatter
    ## exists, so nothing is ever written to the `--out` path — the same shape
    ## as a signal, a bundler failure or a crash in `spec_helper`. The path
    ## itself was created (exclusively) before rspec was launched, so what is
    ## left behind is an EMPTY file rather than no file at all; both spellings
    ## of the reason start "rspec wrote no JSON results to", which is what this
    ## asserts.
    ##
    ## What the provider owes its caller here is a result, not silence: the
    ## exit code still decides (so the aborted run is reported as failed), and
    ## a warning names the reason so a run that quietly regressed onto the
    ## exit-code path cannot be mistaken for a per-test one.
    ensureRubyBundle(rspecRoot())
    let project = rspecScratchProject("ct-rspec-no-json", "ok_spec.rb", """
RSpec.describe "fine" do
  it "passes" do
    expect(1).to eq(1)
  end
end
""", rspecOptions = "--totally-not-an-rspec-option\n")
    defer: removeDir(project)

    let provider = newRubyRspecM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "spec" / "ok_spec.rb",
      selector: "spec/ok_spec.rb"))

    let messages = runResult.diagnosticText
    checkpoint(messages)
    check messages.contains("falling back to rspec's exit code")
    check messages.contains("rspec wrote no JSON results to")
    check messages.contains("Ruby test execution failed with exit code")

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    for event in finished:
      check event.status.get == tsFailed
    for event in runResult.value:
      check event.validateEvent.valid

  test "rspec's unexplained non-zero exit is reported rather than swallowed":
    ## A spec file that fails to LOAD: rspec writes a perfectly well-formed
    ## JSON document whose `examples` array is empty, and exits 1. The document
    ## is usable — it truthfully says nothing ran — so no test event is
    ## emitted and no target can be claimed; but an exit code the example list
    ## does not explain must still be reported as an error rather than
    ## disappearing behind "no failing example".
    ensureRubyBundle(rspecRoot())
    let project = rspecScratchProject("ct-rspec-load-error",
      "broken_spec.rb", "this is not ruby (((\n")
    defer: removeDir(project)

    let provider = newRubyRspecM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "spec" / "broken_spec.rb",
      selector: "spec/broken_spec.rb"))

    let messages = runResult.diagnosticText
    checkpoint(messages)
    check messages.contains("reported no failing example")
    check runResult.value.eventsOfKind(tekTestFinished).len == 0

  test "rspec's command asks for JSON results without silencing the terminal":
    ## `--out` binds to the `--format` immediately before it, so the argument
    ## order here is load-bearing: `--format progress` keeps a human-readable
    ## stream on stdout (rspec installs its default formatter only when NO
    ## formatter has been configured, and a file-bound one counts), and
    ## `--format json --out PATH` puts the machine-readable document where the
    ## provider can read it.
    ##
    ## Minitest is handed the same argument and must ignore it: there is no
    ## minitest equivalent, and the point of the shared proc is that adding one
    ## for rspec did not fork it.
    let jsonOut = "/tmp/ct-test-rspec-results.json"
    check buildRubyCommand(rfkRSpec, rspecRoot(), rspecSample(),
        RspecAddsSelector, rcsFile, jsonOut) == @[
          "bundle", "exec", "rspec", "spec/calculator_spec.rb",
          "--format", "progress", "--format", "json", "--out", jsonOut]
    check buildRubyCommand(rfkRSpec, rspecRoot(), rspecSample(),
        RspecAddsSelector, rcsSingle, jsonOut) == @[
          "bundle", "exec", "rspec", RspecAddsSelector,
          "--format", "progress", "--format", "json", "--out", jsonOut]
    check buildRubyCommand(rfkMinitest, minitestRoot(), minitestSample(),
        MinitestAddsSelector, rcsFile, jsonOut) == @[
          "bundle", "exec", "ruby", "-Itest", "test/calculator_test.rb"]

  test "an unusable rspec JSON document is refused rather than read as empty":
    ## "No events" must never be produced by a document that could not be read:
    ## an empty `events` seq with `usable = true` means *rspec matched no
    ## example*, which withholds a certificate, and reporting a parse failure
    ## that way would withhold one for the wrong reason and hide the real
    ## problem. Each refusal carries its own reason, because the caller turns
    ## it into the diagnostic an operator reads.
    let malformed = parseRspecJsonResults("ruby-rspec", "run-1", "{not json")
    check not malformed.usable
    check malformed.reason.contains("could not be parsed")

    let notAnObject = parseRspecJsonResults("ruby-rspec", "run-1", "[1, 2]")
    check not notAnObject.usable
    check notAnObject.reason.contains("not a JSON object")

    let noExamples = parseRspecJsonResults("ruby-rspec", "run-1",
      """{"version": "3.13.6"}""")
    check not noExamples.usable
    check noExamples.reason.contains("no `examples` array")

    # An EMPTY array is the opposite case: a usable answer meaning nothing ran.
    let noneMatched = parseRspecJsonResults("ruby-rspec", "run-1",
      """{"examples": []}""")
    check noneMatched.usable
    check noneMatched.events.len == 0

    # An example rspec could not name gets the scheduled unit's id, because
    # `validateEvent` rejects a test-finished event with an empty testId.
    let unnamed = parseRspecJsonResults("ruby-rspec", "run-1",
      """{"examples": [{"status": "passed"}]}""", fallbackTestId = "unit-7")
    check unnamed.usable
    check unnamed.events.len == 1
    for event in unnamed.events:
      check event.testId == "unit-7"
      check event.validateEvent.valid

    # …and with nothing to fall back to, the document is refused rather than
    # yielding an invalid event.
    let unattributable = parseRspecJsonResults("ruby-rspec", "run-1",
      """{"examples": [{"status": "passed"}]}""")
    check not unattributable.usable
    check unattributable.reason.contains("could not be attributed")

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
