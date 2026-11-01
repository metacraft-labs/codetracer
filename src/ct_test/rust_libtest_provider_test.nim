## The Rust libtest provider's discovery, command and execution contract.
##
## NO MOCKS. The execution regressions create dependency-free Cargo crates in
## scratch directories and run their real libtest harnesses through the shipped
## provider/process bridge. Their event streams are reduced by the production
## `summarize` routine, so an empty provider result cannot masquerade as a pass,
## and the end-to-end cases drive `ct test run` itself through to its
## certificate. They need `cargo` on PATH and fail, rather than skip, without it.
##
## A run that issues PUBLISHES to the user's local certificate store, so this
## suite points `TEST_CERTIFICATES_DIR` (and the system root) at a scratch
## directory before anything runs.

import std/[algorithm, json, options, os, osproc, sequtils, strutils, unittest]

import certificate_issuance
import contracts
import ct_test
import discovery
import frameworks/rust_libtest
import run_orchestration

let certificateScratch = getTempDir() /
  ("ct-rust-libtest-certs-" & $getCurrentProcessId())
removeDir(certificateScratch)
putEnv("TEST_CERTIFICATES_DIR", certificateScratch / "user-root")
putEnv("TEST_CERTIFICATES_SYSTEM_DIR", certificateScratch / "system")

proc rustRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/rust_libtest_project"

proc libFile(): string =
  rustRoot() / "src/lib.rs"

proc nestedFile(): string =
  rustRoot() / "src/nested.rs"

proc integrationFile(): string =
  rustRoot() / "tests/integration_sample.rs"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc catalogProviderIds(node: JsonNode): seq[string] =
  for catalog in node["catalogs"].getElems:
    result.add catalog["provider"]["id"].getStr

proc jsonCatalogByProvider(node: JsonNode; providerId: string): JsonNode =
  for catalog in node["catalogs"].getElems:
    if catalog["provider"]["id"].getStr == providerId:
      return catalog
  raise newException(ValueError, "missing provider catalog: " & providerId)

proc jsonItemByName(catalog: JsonNode; name: string): JsonNode =
  for item in catalog["items"].getElems:
    if item["name"].getStr == name:
      return item
  raise newException(ValueError, "missing JSON item: " & name)

proc allMessages(response: DiscoverResponse): string =
  for diagnostic in response.diagnostics:
    result.add diagnostic.message & "\n"
  for catalog in response.catalogs:
    for diagnostic in catalog.diagnostics:
      result.add diagnostic.message & "\n"

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

const
  PackageName = "ct-rust-libtest-case"
  PassingTestModule = """
#[cfg(test)]
mod tests {
    #[test]
    fn passes() {
        assert_eq!(2 + 3, 5);
    }
}
"""
  FailingTestModule = """
#[cfg(test)]
mod tests {
    #[test]
    fn fails() {
        assert_eq!(2 + 3, 6);
    }
}
"""
  # Discovery reads source text and finds this test; rustc never compiles it
  # on a non-Windows host, so an exact run of it matches nothing and exits 0.
  # On Windows the same case needs the opposite gate.
  UncompiledTestModule = """
#[cfg(test)]
mod tests {
    #[cfg(""" & (when defined(windows): "unix" else: "windows") & """)]
    #[test]
    fn passes() {
        assert_eq!(2 + 3, 5);
    }
}
"""

proc scratchCargoTree(name: string;
    files: openArray[(string, string)]): string =
  ## A scratch directory holding exactly `files`, manifests included, for the
  ## layouts a single generated `[package]` cannot express.
  require findExe("cargo").len > 0
  result = getTempDir() / ("ct-rust-libtest-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  for (path, content) in files:
    createDir(parentDir(result / path))
    writeFile(result / path, content)

proc scratchCargoProject(name: string;
    sources: openArray[(string, string)]): string =
  ## A real Cargo package with no registry dependencies and the given source
  ## files. Keeping these apart from the discovery corpus avoids compiling that
  ## corpus's async development dependencies and its deliberately failing
  ## integration test.
  result = scratchCargoTree(name, @[("Cargo.toml", """
[package]
name = """ & "\"" & PackageName & "\"" & """

version = "0.1.0"
edition = "2021"
""")] & @sources)

proc cargoListedTests(project: string): seq[string] =
  ## Every test name Cargo's own binaries list for the whole workspace, doc
  ## tests included, sorted. This is the ground truth discovery must equal:
  ## it is read from `cargo test -- --list`, not from anything the provider
  ## computes. A test binary prints `<name>: test` per test
  ## (https://doc.rust-lang.org/rustc/tests/index.html#--list).
  let (output, code) = execCmdEx(
    "cargo test --workspace -- --list", workingDir = project)
  if code != 0:
    checkpoint(output)
  require code == 0
  for line in output.splitLines:
    if line.endsWith(": test"):
      result.add line[0 ..< line.len - ": test".len]
  result.sort(system.cmp[string])

proc discoverWorkspace(project: string): DiscoverResponse =
  ## Workspace discovery through the default registry, as `ct test run` does.
  discover(
    DiscoverRequest(scope: dskWorkspace, workspaceRoot: project,
      jsonOutput: true),
    newDefaultProviderRegistry(), newDiscoveryCache())

proc rustCatalog(response: DiscoverResponse): TestCatalog =
  for catalog in response.catalogs:
    if catalog.provider.id == RustLibtestProviderId:
      return catalog
  raise newException(ValueError, "no rust-libtest catalog")

proc sortedSelectors(catalog: TestCatalog): seq[string] =
  result = catalog.selectors
  result.sort(system.cmp[string])

proc runItem(project: string; item: TestItem):
    ProviderResult[seq[TestEvent]] =
  ## Run one item exactly as `run_orchestration.scopeForItem` dispatches it.
  newRustLibtestM1Provider().provider.run(TestScope(
    kind: tskSingle,
    projectRoot: project,
    file: project / item.file,
    testId: item.id,
    selector: item.selector))

proc finishedStatus(runResult: ProviderResult[seq[TestEvent]]):
    TestResultStatus =
  let finished = runResult.value.eventsOfKind(tekTestFinished)
  require finished.len == 1
  finished[0].status.get

proc git(repo: string; args: openArray[string]) =
  let (output, code) = execCmdEx(
    "git " & quoteShellCommand(args), workingDir = repo)
  if code != 0:
    checkpoint(output)
  require code == 0

proc committed(project: string): string =
  ## Commit `project`, as the issue's "committed, no untracked file" requires.
  ## Cargo's build directory is ignored as any real project ignores it.
  result = project
  writeFile(project / ".gitignore", "target\n")
  git(project, ["init", "--initial-branch=main", "."])
  git(project, ["config", "user.email", "ct-test@example.invalid"])
  git(project, ["config", "user.name", "ct test suite"])
  git(project, ["config", "commit.gpgsign", "false"])
  git(project, ["add", "-A"])
  git(project, ["commit", "-m", "initial"])

proc runSingle(project, relativeFile, selector: string):
    ProviderResult[seq[TestEvent]] =
  ## Run one discovered test the way the orchestrator dispatches it: the
  ## selector comes from discovery, so a wrong one fails here too.
  let
    file = project / relativeFile
    item = rustFileCatalog(project, file).value.itemBySelector(selector)
  newRustLibtestM1Provider().provider.run(TestScope(
    kind: tskSingle,
    projectRoot: project,
    file: file,
    testId: item.id,
    selector: item.selector))

proc runCli(project: string): tuple[code: int; summary: JsonNode] =
  ## The real `ct test run` entry point and default registry on `project`,
  ## read back through `--summary` as a machine consumer reads a run.
  let path = project / "ct-summary.json"
  result.code = runCtTest(
    @["test", "run", "--workspace", project, "--summary", path,
      "--threads", "1"],
    newDefaultProviderRegistry(), newDiscoveryCache())
  require fileExists(path)
  result.summary = parseJson(readFile(path))

proc singleUnitRunResult(
    runResult: ProviderResult[seq[TestEvent]]): TestRunResult =
  ## Feed the provider's actual events to the production counter. The issue is
  ## specifically that dispatch succeeded but no `tekTestFinished` reached
  ## this reducer, so re-counting the events inside the test would test a
  ## different implementation.
  TestRunResult(
    totalDiscovered: 1,
    skippedByPartition: 0,
    dispatchedUnits: 1,
    threads: 1,
    wallTimeMs: 0,
    outcomes: @[RunUnitOutcome(
      providerId: RustLibtestProviderId,
      testId: "unit-1",
      unrunnable: false,
      events: runResult.value,
      diagnostics: runResult.diagnostics)])

proc compileCtTestBinary(name: string): string =
  let binary = getTempDir() / (name & "-" & $getCurrentProcessId())
  let compile = execCmdEx(
    "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/" &
      name & " -o:" & quoteShell(binary) & " src/ct_test/ct_test.nim",
    options = {poUsePath},
    workingDir = getCurrentDir())
  if compile.exitCode != 0:
    checkpoint(compile.output)
  check compile.exitCode == 0
  if fileExists(binary):
    binary
  else:
    binary & ".out"

suite "ct-test M6 Rust libtest provider":
  test "detects Cargo projects and Rust files":
    check hasCargoToml(rustRoot())
    check isRustFile(libFile())
    check isCargoRustTestFile(rustRoot(), libFile())
    check isCargoRustTestFile(rustRoot(), integrationFile())

    let detected = newRustLibtestM1Provider().provider.detect(rustRoot())
    check detected.value
    check detected.diagnostics.len == 0

  test "discovers unit tests with module selectors and source ranges":
    let catalog = rustFileCatalog(rustRoot(), libFile()).value
    check catalog.provider.id == "rust-libtest"
    check catalog.provider.framework == "libtest/cargo-test"
    check catalog.provider.capabilities.canDiscoverFile
    check catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let plain = catalog.itemBySelector("tests::unit_adds")
    check plain.kind == tikCase
    check plain.range.startLine == 24
    check plain.range.startColumn == 1
    check plain.range.endLine == 25
    check plain.range.endColumn == 16

    let ignored = catalog.itemBySelector("tests::ignored_unit")
    check ignored.range.startLine == 30
    check "ignore" in ignored.tags

    let tokio = catalog.itemBySelector("tests::tokio_async_unit")
    check tokio.range.startLine == 35
    check tokio.range.endLine == 36
    check "tokio" in tokio.tags

    let nested = catalog.itemBySelector("tests::inner::nested_unit")
    check nested.range.startLine == 41
    check nested.range.endLine == 42

    let asyncStd = catalog.itemBySelector("tests::inner::async_std_nested")
    check asyncStd.range.startLine == 46
    check asyncStd.range.endLine == 47
    check "async-std" in asyncStd.tags

    let allSelectors = catalog.selectors
    check "tests::fake_from_raw_string" notin allSelectors
    check "tests::fake_from_line_comment" notin allSelectors
    check "tests::fake_from_block_comment" notin allSelectors
    check catalog.items.len == 5

  test "discovers file module tests with source path module prefixes":
    let catalog = rustFileCatalog(rustRoot(), nestedFile()).value
    let item = catalog.itemBySelector(
      "nested::nested_file_tests::nested_file_unit")
    check item.file == "src/nested.rs"
    check item.range.startLine == 3
    check item.range.endLine == 4
    check catalog.items.len == 1
    check catalog.validateCatalog.valid

  test "discovers integration tests without file-name selector prefix":
    let catalog = rustFileCatalog(rustRoot(), integrationFile()).value
    check catalog.itemBySelector("integration_smoke").range.startLine == 5
    check catalog.itemBySelector("failing_integration").range.startLine == 10
    check catalog.itemBySelector("api::nested_integration").
      range.startLine == 16
    check "fake_without_attr" notin catalog.selectors.join("\n")
    check catalog.items.len == 3
    check catalog.validateCatalog.valid

  test "project discovery aggregates src and integration test files":
    # Source and `cargo metadata` only: reconciling would compile the corpus,
    # and with it the async runtimes it names, from the registry. The
    # reconciled route is covered on dependency-free crates below.
    let response = discover(
      DiscoverRequest(
        scope: dskWorkspace,
        workspaceRoot: rustRoot(),
        jsonOutput: true),
      newRustLibtestProviderRegistry(reconcile = false),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    let catalog = response.catalogs[0]
    check catalog.provider.id == "rust-libtest"
    check catalog.itemBySelector("tests::unit_adds").file == "src/lib.rs"
    check catalog.itemBySelector(
      "nested::nested_file_tests::nested_file_unit").file == "src/nested.rs"
    check catalog.itemBySelector("integration_smoke").file ==
      "tests/integration_sample.rs"
    check catalog.items.len == 9
    check catalog.validateCatalog.valid

  test "default CLI JSON uses schema version and Rust provider id":
    let executable = compileCtTestBinary("ct-test-m6-cli")
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", integrationFile(), "--json"],
      options = {poUsePath},
      workingDir = rustRoot())
    let node = parseJson(output)
    check node["schemaVersion"].getInt == 1
    let providerIds = node.catalogProviderIds
    check "smart-wasm" notin providerIds
    check providerIds.allIt(not it.contains("fake"))
    check node["catalogs"].len == 1
    let catalog = node.jsonCatalogByProvider("rust-libtest")
    check catalog["schemaVersion"].getInt == 1
    check catalog["provider"]["id"].getStr == "rust-libtest"
    let item = catalog.jsonItemByName("integration_smoke")
    check item["file"].getStr == "tests/integration_sample.rs"
    check item["name"].getStr == "integration_smoke"

  test "a dependency-free passing Cargo test reports a finished pass":
    ## Regression for
    ## 2026-10-30-ct-test-run-rust-libtest-reports-no-finished-test.md.
    ## Before the fix the provider advertised `canRunSingle` but returned only
    ## a warning diagnostic, so this real passing test produced no
    ## `tekTestFinished`: `executed = 0`, verdict `nothing-executed`, exit 2.
    let project = scratchCargoProject("lib-pass",
      {"src/lib.rs": PassingTestModule})
    defer: removeDir(project)
    let
      file = project / "src/lib.rs"
      item = rustFileCatalog(project, file).value.
        itemBySelector("tests::passes")
      runResult = runSingle(project, "src/lib.rs", "tests::passes")

    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekFailure).len == 0
    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get == tsPassed
      check finished[0].testId == item.id
    for event in runResult.value:
      check event.validateEvent.valid

    let summary = summarize(singleUnitRunResult(runResult))
    check summary.executed == 1
    check summary.passed == 1
    check summary.failed == 0
    check summary.runVerdict == rvPassed
    check summary.runExitCode == ExitRunPassed
    check summary.runVerdict != rvNothingExecuted
    check summary.runExitCode != ExitNothingExecuted

  test "tests in every Cargo target layout pass under their own target":
    ## `--lib` for everything made a passing `src/main.rs` test a failure
    ## (Cargo refuses `--lib` without a library) and left `tests/<x>/main.rs`
    ## running no test at all. `src/bin` also carried a selector no binary
    ## prints. Each layout must reach exactly one real pass.
    for (name, relativeFile, selector, sources) in [
        ("bin-main", "src/main.rs", "tests::passes",
         @[("src/main.rs", "fn main() {}\n" & PassingTestModule)]),
        ("bin-module", "src/helpers.rs", "helpers::tests::passes",
         @[("src/main.rs", "mod helpers;\nfn main() {}\n"),
           ("src/helpers.rs", PassingTestModule)]),
        ("bin-file", "src/bin/tool.rs", "tests::passes",
         @[("src/lib.rs", "pub fn lib() {}\n"),
           ("src/bin/tool.rs", "fn main() {}\n" & PassingTestModule)]),
        ("bin-dir", "src/bin/tool/sub.rs", "sub::tests::passes",
         @[("src/lib.rs", "pub fn lib() {}\n"),
           ("src/bin/tool/main.rs", "mod sub;\nfn main() {}\n"),
           ("src/bin/tool/sub.rs", PassingTestModule)]),
        ("it-main", "tests/it/main.rs", "passes",
         @[("src/lib.rs", "pub fn lib() {}\n"),
           ("tests/it/main.rs", "#[test]\nfn passes() {}\n")]),
        ("it-module", "tests/it/sub.rs", "sub::passes",
         @[("src/lib.rs", "pub fn lib() {}\n"),
           ("tests/it/main.rs", "mod sub;\n"),
           ("tests/it/sub.rs", "#[test]\nfn passes() {}\n")])]:
      checkpoint(name)
      let project = scratchCargoProject(name, sources)
      defer: removeDir(project)
      let
        runResult = runSingle(project, relativeFile, selector)
        finished = runResult.value.eventsOfKind(tekTestFinished)
        summary = summarize(singleUnitRunResult(runResult))
      checkpoint($runResult.diagnostics)
      check finished.len == 1
      check summary.executed == 1
      check summary.passed == 1
      check summary.runVerdict == rvPassed

  test "a discovered test cargo never compiled does not pass":
    ## `cargo test -- <selector> --exact` exits 0 with `running 0 tests` here,
    ## so an exit-code verdict certifies a test that did not run.
    let project = scratchCargoProject("uncompiled",
      {"src/lib.rs": UncompiledTestModule})
    defer: removeDir(project)
    let
      runResult = runSingle(project, "src/lib.rs", "tests::passes")
      finished = runResult.value.eventsOfKind(tekTestFinished)
      closing = runResult.value.eventsOfKind(tekRunFinished)
      summary = summarize(singleUnitRunResult(runResult))
    require finished.len == 1
    check finished[0].status.get == tsSkipped
    check finished[0].message.contains("tests::passes")
    require closing.len == 1
    check closing[0].status.get == tsSkipped
    for event in runResult.value:
      check event.validateEvent.valid
    require runResult.diagnostics.len == 1
    check runResult.diagnostics[0].severity == dsWarning
    check runResult.diagnostics[0].message.contains("tests::passes")
    check runResult.diagnostics[0].file.endsWith("src/lib.rs")
    check summary.executed == 0
    check summary.skipped == 1
    check summary.runVerdict == rvNothingExecuted
    check summary.runExitCode == ExitNothingExecuted

  test "a harness-free target has no summary and does not pass":
    ## A `harness = false` target ignores the selector and prints no libtest
    ## summary, so exit 0 says nothing about the discovered test.
    let project = scratchCargoProject("no-harness",
      {"tests/custom.rs": "#[test]\nfn passes() {}\nfn main() {}\n"})
    defer: removeDir(project)
    writeFile(project / "Cargo.toml", readFile(project / "Cargo.toml") & """

[[test]]
name = "custom"
path = "tests/custom.rs"
harness = false
""")
    let finished = runSingle(project, "tests/custom.rs", "passes").value.
      eventsOfKind(tekTestFinished)
    require finished.len == 1
    check finished[0].status.get == tsSkipped

  test "a failing Cargo test is a failure, never a skip":
    let project = scratchCargoProject("lib-fail",
      {"src/lib.rs": FailingTestModule})
    defer: removeDir(project)
    let
      runResult = runSingle(project, "src/lib.rs", "tests::fails")
      finished = runResult.value.eventsOfKind(tekTestFinished)
      summary = summarize(singleUnitRunResult(runResult))
    require finished.len == 1
    check finished[0].status.get == tsFailed
    check summary.failed == 1
    check summary.runVerdict == rvFailed
    check summary.runExitCode == ExitTestsFailed

  test "file and project scopes obey the same evidence rule":
    let
      passing = scratchCargoProject("scope-pass",
        {"src/lib.rs": PassingTestModule})
      gated = scratchCargoProject("scope-gated",
        {"src/lib.rs": UncompiledTestModule})
    defer:
      removeDir(passing)
      removeDir(gated)
    let provider = newRustLibtestM1Provider().provider
    for (kind, expectedPass, expectedGated) in [
        (tskFile, tsPassed, tsSkipped), (tskProject, tsPassed, tsSkipped)]:
      for (project, expected) in [(passing, expectedPass), (gated, expectedGated)]:
        let finished = provider.run(TestScope(
          kind: kind, projectRoot: project, file: project / "src/lib.rs",
          testId: "unit")).value.eventsOfKind(tekTestFinished)
        require finished.len == 1
        check finished[0].status.get == expected

  test "ct test run on a committed passing crate issues a certificate":
    ## The issue's own observation, end to end: exit 2 and `wrNoTestsExecuted`
    ## on a dependency-free project with one passing test.
    let project = committed(scratchCargoProject("cli-pass",
      {"src/lib.rs": PassingTestModule}))
    defer: removeDir(project)
    let (code, summary) = runCli(project)
    checkpoint($summary)
    check code == ExitRunPassed
    check summary["total"].getInt == 1
    check summary["executed"].getInt == 1
    check summary["passed"].getInt == 1
    check summary["verdict"].getStr == $rvPassed
    check summary["certificate"]["issued"].getBool

  test "ct test run on a committed failing crate withholds as failed":
    let project = committed(scratchCargoProject("cli-fail",
      {"src/lib.rs": FailingTestModule}))
    defer: removeDir(project)
    let (code, summary) = runCli(project)
    checkpoint($summary)
    check code == ExitTestsFailed
    check summary["executed"].getInt == 1
    check summary["failed"].getInt == 1
    check summary["verdict"].getStr == $rvFailed
    check not summary["certificate"]["issued"].getBool
    check summary["certificate"]["withheld_reason"].getStr == $wrTestsFailed

  test "ct test run withholds for a test cargo never compiled":
    let project = committed(scratchCargoProject("cli-uncompiled",
      {"src/lib.rs": UncompiledTestModule}))
    defer: removeDir(project)
    let (code, summary) = runCli(project)
    checkpoint($summary)
    check code == ExitNothingExecuted
    check summary["executed"].getInt == 0
    check summary["skipped"].getInt == 1
    check summary["verdict"].getStr == $rvNothingExecuted
    check not summary["certificate"]["issued"].getBool
    check summary["certificate"]["withheld_reason"].getStr ==
      $wrNoTestsExecuted

  test "libtest's summary is read per binary and tolerates colour":
    const
      ok = "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; " &
        "1 filtered out; finished in 0.00s"
      none = "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; " &
        "3 filtered out; finished in 0.00s"
      coloured = "test result: \e[32mok\e[0m. 1 passed; 0 failed; " &
        "0 ignored; 0 measured; 0 filtered out; finished in 0.00s"
    check libtestPassedCount(ok) == 2
    check libtestPassedCount(none) == 0
    check libtestPassedCount(coloured) == 1
    check libtestPassedCount(ok & "\n" & none & "\r\n" & coloured) == 3
    check libtestPassedCount("") == 0
    check libtestPassedCount("   Compiling x v0.1.0\nrunning 0 tests\n") == 0
    # A line that only mentions passing is not a summary, and a summary whose
    # count cannot be read is evidence of nothing.
    check libtestPassedCount("12 passed; 0 failed") == 0
    check libtestPassedCount("test result: ok. many passed; 0 failed") == 0
    check libtestPassedCount("test result: ok. " & repeat('9', 40) &
      " passed;") == 0

  test "every source layout selects the Cargo target that compiles it":
    let
      withLib = scratchCargoProject("layout-lib", {
        "src/lib.rs": "", "src/main.rs": "", "src/util.rs": "",
        "src/bin/tool.rs": "", "src/bin/dir/main.rs": "",
        "src/bin/dir/sub.rs": "", "tests/flat.rs": "", "tests/it/main.rs": "",
        "tests/it/sub.rs": "", "tests/common/mod.rs": ""})
      binOnly = scratchCargoProject("layout-bin", {
        "src/main.rs": "", "src/util.rs": ""})
      declaredLib = scratchCargoProject("layout-declared", {
        "src/custom.rs": "", "src/util.rs": ""})
    defer:
      removeDir(withLib)
      removeDir(binOnly)
      removeDir(declaredLib)
    writeFile(declaredLib / "Cargo.toml",
      readFile(declaredLib / "Cargo.toml") & "\n[lib]\npath = \"src/custom.rs\"\n")

    proc targetOf(project, relativeFile: string): seq[string] =
      let file = project / relativeFile
      result = buildRustCommand(project, file, "", rcsFile)[2 .. ^1]
      # Both scopes must agree: a single test runs in its file's target.
      check buildRustCommand(project, file, "sel", rcsSingle) ==
        @["cargo", "test"] & result & @["--", "sel", "--exact",
          "--include-ignored"]

    check targetOf(withLib, "src/lib.rs") == @["--lib"]
    check targetOf(withLib, "src/util.rs") == @["--lib"]
    check targetOf(withLib, "src/main.rs") == @["--bin", PackageName]
    check targetOf(withLib, "src/bin/tool.rs") == @["--bin", "tool"]
    check targetOf(withLib, "src/bin/dir/main.rs") == @["--bin", "dir"]
    check targetOf(withLib, "src/bin/dir/sub.rs") == @["--bin", "dir"]
    check targetOf(withLib, "tests/flat.rs") == @["--test", "flat"]
    check targetOf(withLib, "tests/it/main.rs") == @["--test", "it"]
    check targetOf(withLib, "tests/it/sub.rs") == @["--test", "it"]
    # `tests/common/` has no `main.rs`, so it is no target to name.
    check targetOf(withLib, "tests/common/mod.rs") == @["--lib"]
    check targetOf(binOnly, "src/main.rs") == @["--bin", PackageName]
    check targetOf(binOnly, "src/util.rs") == @["--bin", PackageName]
    check targetOf(declaredLib, "src/util.rs") == @["--lib"]

  test "without Cargo's target list the path conventions still decide":
    ## The Nix-fallback route has no `cargo` to ask before the command runs.
    let
      project = scratchCargoProject("layout-unknown", {
        "src/lib.rs": "", "src/main.rs": "", "src/bin/tool.rs": "",
        "tests/flat.rs": ""})
      unknown = CargoLayout()
    defer: removeDir(project)
    proc targetOf(relativeFile: string): seq[string] =
      buildRustCommand(project, project / relativeFile, "", rcsFile,
        unknown)[2 .. ^1]
    check targetOf("src/lib.rs") == @["--lib"]
    check targetOf("src/main.rs") == @["--bins"]
    check targetOf("src/bin/tool.rs") == @["--bin", "tool"]
    check targetOf("tests/flat.rs") == @["--test", "flat"]

  test "Cargo's layout survives a warning beside it and refuses garbage":
    let project = scratchCargoProject("layout-parse", {"src/lib.rs": ""})
    defer: removeDir(project)
    let
      manifest = project / "Cargo.toml"
      document = $(%*{
        "packages": [{"name": "p", "manifest_path": manifest, "targets": [{
          "name": "p", "kind": ["lib"], "src_path": project / "src/lib.rs"}]}],
        "workspace_members": ["p"]})
      layout = parseCargoLayout(
        "warning: unused manifest key: x\n" & document, project)
    check layout.known
    require layout.packages.len == 1
    check layout.packages[0].name == "p"
    check layout.workspaceMembers == 1
    check layout.packages[0].targets.len == 1
    # Cargo's defaults stand in for flags an older Cargo leaves out.
    check layout.packages[0].targets[0].test
    check layout.packages[0].targets[0].edition == "2015"
    check not parseCargoLayout("", project).known
    check not parseCargoLayout("{not json", project).known
    check not parseCargoLayout("{}", project).known
    # Another package's document says nothing about this one.
    check not parseCargoLayout(document.replace(manifest, "/elsewhere/C.toml"),
      project).known

  test "a manifest-renamed target runs under its declared name":
    ## The file name is not the target name here, so a path-derived `--bin` or
    ## `--test` is refused by Cargo and a passing test reports failed.
    for (name, section, file, source, selector) in [
        ("renamed-bin", "[[bin]]\nname = \"renamed\"\n", "src/bin/tool.rs",
         "fn main() {}\n" & PassingTestModule, "tests::passes"),
        ("renamed-test", "[[test]]\nname = \"api\"\n", "tests/api_tests.rs",
         "#[test]\nfn passes() {}\n", "passes")]:
      checkpoint(name)
      let project = scratchCargoProject(name, {
        "src/lib.rs": "pub fn lib() {}\n", file: source})
      defer: removeDir(project)
      writeFile(project / "Cargo.toml", readFile(project / "Cargo.toml") &
        "\n" & section & "path = \"" & file & "\"\n")
      check summarize(singleUnitRunResult(
        runSingle(project, file, selector))).runVerdict == rvPassed

  test "another binary's same-named test is not this file's pass":
    ## `--bins` ran both binaries: `other` passed `tests::passes`, and the pass
    ## was credited to the `src/main.rs` test rustc never compiled.
    let project = scratchCargoProject("bins-same-name", {
      "src/main.rs": "fn main() {}\n" & UncompiledTestModule,
      "src/bin/other.rs": "fn main() {}\n" & PassingTestModule})
    defer: removeDir(project)
    let finished = runSingle(project, "src/main.rs", "tests::passes").value.
      eventsOfKind(tekTestFinished)
    require finished.len == 1
    check finished[0].status.get == tsSkipped

  test "default-members cannot redirect a run to another package":
    let project = scratchCargoProject("default-members", {
      "src/lib.rs": UncompiledTestModule,
      "crates/a/Cargo.toml": """
[package]
name = "a"
version = "0.1.0"
edition = "2021"
""",
      "crates/a/src/lib.rs": PassingTestModule})
    defer: removeDir(project)
    writeFile(project / "Cargo.toml", readFile(project / "Cargo.toml") & """

[workspace]
members = ["crates/a"]
default-members = ["crates/a"]
""")
    let finished = runSingle(project, "src/lib.rs", "tests::passes").value.
      eventsOfKind(tekTestFinished)
    require finished.len == 1
    check finished[0].status.get == tsSkipped

  test "a summary the project printed itself attests nothing":
    ## Each of these prints `test result: ok. 9 passed;` beside a test that
    ## never ran: rustc quoting a source comment, a build script's warning, and
    ## a `harness = false` main ignoring the selector.
    const FakeSummary = "test result: ok. 9 passed; 0 failed;"
    let
      quoted = scratchCargoProject("fake-quoted", {
        "src/lib.rs": "pub fn f() { let unused = 1; /* " & FakeSummary &
          " */ }\n" & UncompiledTestModule})
      warned = scratchCargoProject("fake-warned", {
        "src/lib.rs": UncompiledTestModule,
        "build.rs": "fn main() { println!(\"cargo:warning=" & FakeSummary &
          "\"); }\n"})
      harnessFree = scratchCargoProject("fake-harness", {
        "src/lib.rs": "pub fn f() {}\n",
        "tests/custom.rs": "#[test]\nfn never_runs() { panic!(); }\n" &
          "fn main() { println!(\"" & FakeSummary & "\"); }\n"})
    defer:
      removeDir(quoted)
      removeDir(warned)
      removeDir(harnessFree)
    writeFile(harnessFree / "Cargo.toml",
      readFile(harnessFree / "Cargo.toml") &
      "\n[[test]]\nname = \"custom\"\npath = \"tests/custom.rs\"\n" &
      "harness = false\n")
    for (project, file, selector) in [
        (quoted, "src/lib.rs", "tests::passes"),
        (warned, "src/lib.rs", "tests::passes"),
        (harnessFree, "tests/custom.rs", "never_runs")]:
      checkpoint(project)
      let finished = runSingle(project, file, selector).value.
        eventsOfKind(tekTestFinished)
      require finished.len == 1
      check finished[0].status.get == tsSkipped

  test "a target whose required features are off is skipped, not failed":
    ## Cargo refuses to build it with exit 101, so nothing ran. That is the
    ## target-level form of a `cfg(feature)` test and must not fail the run.
    let project = scratchCargoProject("required-features", {
      "src/lib.rs": "pub fn lib() {}\n",
      "tests/needs.rs": "#[test]\nfn passes() {}\n"})
    defer: removeDir(project)
    writeFile(project / "Cargo.toml", readFile(project / "Cargo.toml") & """

[features]
extra = []

[[test]]
name = "needs"
path = "tests/needs.rs"
required-features = ["extra"]
""")
    let
      runResult = runSingle(project, "tests/needs.rs", "passes")
      finished = runResult.value.eventsOfKind(tekTestFinished)
    require finished.len == 1
    check finished[0].status.get == tsSkipped
    check runResult.value.eventsOfKind(tekFailure).len == 0
    require runResult.diagnostics.len == 1
    check runResult.diagnostics[0].severity == dsWarning
    check summarize(singleUnitRunResult(runResult)).failed == 0
    # Any other refusal, and a test quoting the text, stays a failure.
    check not cargoRefusedForFeatures("error: no test target named `needs`")
    check not cargoRefusedForFeatures("  | requires the features: `x`")

  test "a selected test's result line is required and read exactly":
    check libtestRanSelector("test tests::passes ... ok", "tests::passes")
    check libtestRanSelector("test tests::p - should panic ... ok", "tests::p")
    # A test writing to the real stdout splits libtest's line.
    check libtestRanSelector("test tests::p ... noise\nok\n", "tests::p")
    check not libtestRanSelector("test tests::passes ... ok", "tests::pass")
    check not libtestRanSelector("  | test tests::p ... ok", "tests::p")
    check not libtestRanSelector("", "tests::p")
    check libtestPassedCount("warning: x: test result: ok. 9 passed;") == 0
    check libtestPassedCount("3 | // test result: ok. 9 passed;") == 0

  test "selectors start at the crate root of the file's own target":
    # A file is compiled only when a `mod` declaration reaches it, so the
    # directory target declares both of its modules.
    let project = scratchCargoProject("selectors", {
      "src/bin/tool.rs": PassingTestModule,
      "src/bin/dir/main.rs": "mod sub;\nmod deep;\n" & PassingTestModule,
      "src/bin/dir/sub.rs": PassingTestModule,
      "src/bin/dir/deep/mod.rs": PassingTestModule,
      "tests/it/main.rs": "mod sub;\n#[test]\nfn passes() {}\n",
      "tests/it/sub.rs": "#[test]\nfn passes() {}\n"})
    defer: removeDir(project)
    proc selectors(relativeFile: string): seq[string] =
      rustFileCatalog(project, project / relativeFile).value.selectors
    check selectors("src/bin/tool.rs") == @["tests::passes"]
    check selectors("src/bin/dir/main.rs") == @["tests::passes"]
    check selectors("src/bin/dir/sub.rs") == @["sub::tests::passes"]
    check selectors("src/bin/dir/deep/mod.rs") == @["deep::tests::passes"]
    check selectors("tests/it/main.rs") == @["passes"]
    check selectors("tests/it/sub.rs") == @["sub::passes"]

  test "rust_libtest_reconciles_source_and_binary_names":
    ## Regression for
    ## 2026-11-01-rust-libtest-discovery-omits-or-misnames-valid-tests.md, its
    ## first group: selectors derived from the file path named no compiled
    ## test, so these units ran nothing and reported skipped. A `[lib]` and a
    ## `[[bin]]` with custom paths, a module only a binary includes (in a
    ## crate that also has a library), a `#[path]` module, raw identifiers, a
    ## brace hidden between two lifetimes, and a one-line test. Discovery must
    ## equal what Cargo's own binaries list, and every unit must really pass.
    let project = committed(scratchCargoTree("reconcile", {
      "Cargo.toml": """
[package]
name = "ct-rust-reconcile"
version = "0.1.0"
edition = "2021"

[lib]
path = "lib/root.rs"

[[bin]]
name = "tool"
path = "app/tool.rs"
""",
      "lib/root.rs": """
mod sub;
#[path = "extra/paths.rs"]
mod renamed;
#[test] fn one_line() {}
#[test]
fn r#try() {}
#[test]
fn r#plain() {}
mod r#match {
    #[test]
    fn inside() {}
}
""",
      "lib/sub.rs": """
pub struct Holder<'a> { pub value: &'a u8 }
#[cfg(test)]
mod tests {
    #[test]
    fn after_lifetimes() {}
}
""",
      "lib/extra/paths.rs": "#[test]\nfn via_path_attribute() {}\n",
      "app/tool.rs": "mod only_tool;\nfn main() {}\n",
      "app/only_tool.rs": "#[test]\nfn in_tool() {}\n",
      "src/main.rs": "mod helpers;\nfn main() {}\n",
      "src/helpers.rs": PassingTestModule}))
    defer: removeDir(project)
    let listed = cargoListedTests(project)
    check "r#try" in listed
    check "plain" in listed
    check "one_line" in listed
    check "renamed::via_path_attribute" in listed
    check "only_tool::in_tool" in listed
    check "helpers::tests::passes" in listed
    let response = discoverWorkspace(project)
    checkpoint(allMessages(response))
    let catalog = response.rustCatalog
    check catalog.sortedSelectors == listed
    check catalog.validateCatalog.valid
    # A file's own catalog agrees with the project's, without compiling.
    check rustFileCatalog(project, project / "src/helpers.rs").value.
      selectors == @["helpers::tests::passes"]
    check rustFileCatalog(project, project / "lib/root.rs").value.
      selectors == @["one_line", "r#try", "plain", "r#match::inside"]

    let (code, summary) = runCli(project)
    checkpoint($summary)
    check code == ExitRunPassed
    check summary["total"].getInt == listed.len
    check summary["executed"].getInt == listed.len
    check summary["passed"].getInt == listed.len
    check summary["certificate"]["issued"].getBool

  test "a raw identifier keeps r# only where the crate's edition reserves it":
    ## libtest prints `r#try` in a 2018+ crate and `try` in a 2015 one, where
    ## `try` is no keyword; `r#match` everywhere, and never `r#plain`.
    let project = scratchCargoTree("raw-2015", {
      "Cargo.toml": "[package]\nname = \"raw\"\nversion = \"0.1.0\"\n" &
        "edition = \"2015\"\n",
      "src/lib.rs": "#[test]\nfn r#try() {}\n#[test]\nfn r#match() {}\n" &
        "#[test]\nfn r#plain() {}\n"})
    defer: removeDir(project)
    check rustFileCatalog(project, project / "src/lib.rs").value.selectors ==
      @["try", "r#match", "plain"]
    check cargoListedTests(project) == @["plain", "r#match", "try"]

  test "virtual workspace members are discovered and run":
    ## Regression for the issue's second group: a root `Cargo.toml` holding
    ## only `[workspace]` has no `src/`, so discovery found nothing at all and
    ## `ct test run` had no unit to execute for either member.
    let project = committed(scratchCargoTree("virtual", {
      "Cargo.toml": "[workspace]\nmembers = [\"crates/a\", \"crates/b\"]\n" &
        "resolver = \"2\"\n",
      "crates/a/Cargo.toml": "[package]\nname = \"a\"\nversion = \"0.1.0\"\n" &
        "edition = \"2021\"\n",
      "crates/a/src/lib.rs": PassingTestModule,
      "crates/b/Cargo.toml": "[package]\nname = \"b\"\nversion = \"0.1.0\"\n" &
        "edition = \"2015\"\n",
      "crates/b/src/lib.rs": "#[test]\nfn r#try() {}\n",
      "crates/b/tests/flat.rs": "#[test]\nfn flat() {}\n"}))
    defer: removeDir(project)
    let listed = cargoListedTests(project)
    check listed == @["flat", "tests::passes", "try"]
    let catalog = discoverWorkspace(project).rustCatalog
    check catalog.sortedSelectors == listed
    check catalog.itemBySelector("tests::passes").file == "crates/a/src/lib.rs"
    check catalog.itemBySelector("flat").file == "crates/b/tests/flat.rs"
    let (code, summary) = runCli(project)
    checkpoint($summary)
    check code == ExitRunPassed
    check summary["executed"].getInt == 3
    check summary["passed"].getInt == 3
    check summary["certificate"]["issued"].getBool

  test "doc tests are discovered at their fence and judged on their own line":
    ## Regression for the issue's second group: doc tests were never units,
    ## so a certificate could silently omit them. rustdoc splits a filter on
    ## whitespace, so a unit runs its file's doc tests and must report only
    ## its own result line: the failing sibling may not fail the passing one.
    let project = committed(scratchCargoTree("doctests", {
      "Cargo.toml": "[package]\nname = \"docs\"\nversion = \"0.1.0\"\n" &
        "edition = \"2021\"\n",
      "src/lib.rs": """
//! ```
//! assert_eq!(docs::answer(), 42);
//! ```

/// ```
/// assert_eq!(docs::answer(), 42);
/// ```
///
/// ```compile_fail
/// let x: u8 = "not a number";
/// ```
///
/// ```ignore
/// this is not rust
/// ```
pub fn answer() -> i32 { 42 }

/// ```
/// assert_eq!(docs::answer(), 41);
/// ```
pub fn wrong() {}
"""}))
    defer: removeDir(project)
    let listed = cargoListedTests(project)
    check listed == @["src/lib.rs - (line 1)", "src/lib.rs - answer (line 13)",
      "src/lib.rs - answer (line 5)", "src/lib.rs - answer (line 9)",
      "src/lib.rs - wrong (line 18)"]
    let catalog = discoverWorkspace(project).rustCatalog
    check catalog.sortedSelectors == listed
    check catalog.validateCatalog.valid
    let fence = catalog.itemBySelector("src/lib.rs - answer (line 5)")
    check fence.file == "src/lib.rs"
    check fence.range.startLine == 5
    check "doctest" in fence.tags
    for (selector, expected) in [
        ("src/lib.rs - (line 1)", tsPassed),
        ("src/lib.rs - answer (line 5)", tsPassed),
        ("src/lib.rs - answer (line 9)", tsPassed),
        ("src/lib.rs - answer (line 13)", tsSkipped),
        ("src/lib.rs - wrong (line 18)", tsFailed)]:
      checkpoint(selector)
      let runResult = runItem(project, catalog.itemBySelector(selector))
      check runResult.finishedStatus == expected
      for event in runResult.value:
        check event.validateEvent.valid

  test "a test only a macro expands is reported, never silently omitted":
    ## The binary lists it, but no source line declares it, so discovery
    ## cannot place it in a file. It must say so where a reader looks.
    let project = scratchCargoProject("macro-made", {"src/lib.rs": """
macro_rules! make_test { ($name:ident) => { #[test] fn $name() {} }; }
make_test!(made_by_macro);
#[test]
fn written() {}
"""})
    defer: removeDir(project)
    let response = discoverWorkspace(project)
    check response.rustCatalog.selectors == @["written"]
    check "made_by_macro" in allMessages(response)

  test "command construction is explicit and recording remains unsupported":
    let unitSelector = rustFileCatalog(rustRoot(), libFile()).value.
      itemBySelector("tests::unit_adds").selector
    let integrationSelector = rustFileCatalog(rustRoot(), integrationFile()).
      value.itemBySelector("api::nested_integration").selector

    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsProject) ==
      @["cargo", "test"]
    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsFile) ==
      @["cargo", "test", "--lib"]
    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsSingle) ==
      @["cargo", "test", "--lib", "--", "tests::unit_adds", "--exact",
        "--include-ignored"]
    check buildRustCommand(rustRoot(), integrationFile(), integrationSelector,
        rcsFile) ==
      @["cargo", "test", "--test", "integration_sample"]
    check buildRustCommand(rustRoot(), integrationFile(), integrationSelector,
        rcsSingle) ==
      @["cargo", "test", "--test", "integration_sample", "--",
        "api::nested_integration", "--exact", "--include-ignored"]

    let provider = newRustLibtestM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: rustRoot(),
      file: libFile(),
      selector: unitSelector))
    check recordResult.value.len == 0
    check recordResult.diagnostics.len == 1
    check recordResult.diagnostics[0].message.contains("not wired in M6")

  test "default registry leaves Nim and Python providers intact":
    let nimRoot = getCurrentDir() / "src/ct_test/fixtures/nim_unittest_project"
    let nimFile = nimRoot / "tests/test_sample.nim"
    let pyRoot = getCurrentDir() / "src/ct_test/fixtures/python_pytest_project"
    let pyFile = pyRoot / "tests/test_sample.py"

    let nimResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: nimRoot, file: nimFile,
        jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    let pyResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: pyRoot, file: pyFile,
        jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(nimResponse) == 0
    check nimResponse.catalogs[0].provider.id == "nim-unittest"
    check allMessages(nimResponse).contains("rust-libtest did not detect")
    check discoverExitCode(pyResponse) == 0
    check pyResponse.catalogs[0].provider.id == "python-pytest"
