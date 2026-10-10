## The `ct test run` command-line surface for certificates.
##
## Complements ``certificate_issuance_test.nim``, which exercises issuance as a
## library. This suite drives the real CLI entry point — ``runCtTest`` with the
## default provider registry — so the wiring between a run and its attestation
## is covered end to end rather than only at the seam.
##
## NO MOCKS. The workspaces are real directories with real git repositories,
## and the run really runs. The workspace deliberately contains a Nim
## ``std/unittest`` file, whose provider discovers but cannot *run* tests
## (``canRunProject: false``), so the run produces no finished-test events on
## any machine, with no toolchain or language runtime involved. That makes the
## withheld path — the one an operator meets most often, and the one whose
## message has to be actionable — deterministic in CI.
##
## The summary is read back from ``--summary <path>`` rather than from stdout,
## which is also the documented way a machine consumer reads a run.
##
## ONE SEAM, for one case: "withholding an attestation does not change the
## run's exit code" has to reach every withholding reason, and all but one of
## them are decided only after a test has PASSED, which no shipped provider
## can do here without a language toolchain. That case therefore also drives
## the same CLI entry point with an in-process fixture provider — the seam
## ``certificate_default_store_test.nim`` justifies — which reports a pass for
## the test it is handed and, for one fixture file, edits a tracked file while
## it runs. Discovery, orchestration, issuance and the exit status are the
## shipped code.

import std/[json, options, os, osproc, streams, strutils, unittest]

import contracts
import certificate
import certificate_issuance
import ct_test
import discovery
import run_orchestration

const
  FixtureProviderId = "fixture-cli"
  FixtureTestFile = "tests/calc_test.fixture"
  EditingMarker = "edit a tracked file while running"

proc fixtureInfo(): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId, language: "fixture", framework: "inproc",
    displayName: "In-process CLI fixture provider", version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      canCapturePerTestOutput: true, emitsStructuredEvents: true))

proc fixtureItem(): TestItem =
  TestItem(
    id: makeTestItemId(FixtureProviderId, "fixture", "inproc",
                       FixtureTestFile, FixtureTestFile & "::adds"),
    providerId: FixtureProviderId, language: "fixture", framework: "inproc",
    name: "adds", kind: tikCase, file: FixtureTestFile,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: FixtureTestFile & "::adds", tags: @["fixture"],
    location: LocationProvenance(source: lskPattern,
      detail: "in-process fixture", confidence: lcHigh))

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Reports a pass for the test it was handed. When the test file asks for
  ## it, the test first appends to the tracked `notes.txt`: an edit during
  ## the run.
  let testFile = scope.projectRoot / FixtureTestFile
  if fileExists(testFile) and EditingMarker in readFile(testFile):
    let notes = scope.projectRoot / "notes.txt"
    writeFile(notes, readFile(notes) & "edited during the run\n")
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId, status: some(tsPassed), durationMs: 1)])

proc fixtureDetect(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
  ProviderResult[bool](value: fileExists(projectRoot / FixtureTestFile))

proc fixtureDiscoverProject(projectRoot: string):
    ProviderResult[TestCatalog] {.gcsafe.} =
  ProviderResult[TestCatalog](value: TestCatalog(
    schemaVersion: TestCatalogSchemaVersion, provider: fixtureInfo(),
    items: (if fileExists(projectRoot / FixtureTestFile): @[fixtureItem()]
            else: @[])))

proc fixtureRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo())
  provider.detect = fixtureDetect
  provider.discoverProject = fixtureDiscoverProject
  provider.run = fixtureRun
  ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @[])])

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-test-cert-cli" / name & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc git(dir: string; args: openArray[string]) =
  var p = startProcess("git", workingDir = dir, args = @args,
                       options = {poUsePath, poStdErrToStdOut})
  discard p.outputStream.readAll()
  discard p.waitForExit()
  p.close()

proc committedWorkspace(name: string): string =
  ## A real repository holding one discoverable-but-unrunnable Nim suite.
  result = scratchDir(name)
  createDir(result / "tests")
  writeFile(result / "tests" / "calc_test.nim", """
import std/unittest

suite "calc":
  test "adds":
    check 1 + 1 == 2
""")
  git(result, ["init", "--initial-branch=main", "."])
  git(result, ["config", "user.email", "ct-test@example.invalid"])
  git(result, ["config", "user.name", "ct test suite"])
  git(result, ["config", "commit.gpgsign", "false"])
  git(result, ["add", "-A"])
  git(result, ["commit", "-m", "initial"])

proc runCli(args: seq[string]): int =
  runCtTest(args, newDefaultProviderRegistry(), newDiscoveryCache())

suite "ct test run certificate CLI":

  test "the usage text documents the certificate surface":
    ## A flag that decides whether an attestation is produced, or signed, and
    ## appears in no usage text is a flag nobody finds when they need it.
    let usage = ctTestUsageMessage()
    check "--certificate <path>" in usage
    check "--no-certificate" in usage
    check "--sign-key" in usage
    check "--key-id" in usage
    check CertificateSchema in usage
    check CtTestFramework in usage
    # The binding is content, and the text no longer tells anyone to commit
    # before testing.
    check "CONTENT of the tracked files" in usage
    check "no need to commit first" in usage
    check "no second run" in usage
    check "commit your changes" notin usage
    # Signing is OPTIONAL and OFF by default, and the usage text has to say so:
    # an unsigned certificate is well-formed (Standard.md §6), and a user who
    # believes signing is automatic has a false idea of what they hold.
    check "OFF" in usage

  test "the usage text documents every exit status run can answer with":
    ## Same argument as the flags above, applied to the surface a script reads
    ## instead of a human.  `2` is the one a reader cannot guess: a run that
    ## executed nothing is not a passing run, and before it had its own code it
    ## was indistinguishable from success.  Someone branching on `$?` has to be
    ## able to find that out from `--help` rather than by discovering it in
    ## production.
    let usage = ctTestUsageMessage()
    check "exits 0" in usage
    check "1 when" in usage
    check "2 when" in usage
    # The distinction itself, not merely the digits: a usage text that lists
    # three numbers without saying that nothing-ran differs from all-passed
    # documents the mechanism and hides the meaning.
    check "NO test ran" in usage

  test "a signing key without a key id is refused before anything runs":
    ## A signed certificate whose ``key_id`` a consumer cannot resolve against
    ## its key store is one nobody can check (Verification.md §3.1), so the
    ## combination is rejected up front rather than producing one.
    let workspace = committedWorkspace("missing-key-id")
    check runCli(@["test", "run", "--workspace", workspace,
                   "--sign-key", "/nonexistent/key"]) != 0
    check runCli(@["test", "run", "--workspace", workspace,
                   "--key-id", "orphan"]) != 0

  test "a run that finishes no test withholds, and says what would change that":
    let workspace = committedWorkspace("withheld")
    let summaryPath = workspace / "summary.json"
    discard runCli(@["test", "run", "--workspace", workspace,
                     "--summary", summaryPath, "--threads", "1"])
    require fileExists(summaryPath)
    let summary = parseJson(readFile(summaryPath))
    require summary.hasKey("certificate")
    let report = summary["certificate"]

    check report["issued"].getBool == false
    check report["schema"].getStr == CertificateSchema
    check report["framework"].getStr == CtTestFramework
    check report["withheld_reason"].getStr == $wrNoTestsExecuted
    # Tri-state, not a boolean: this run failed its own gate and never reached
    # git, which is a different report from a probe that ran and could not
    # decide — and sends the operator somewhere different.
    check report["vcs"].getStr == "not-probed"
    check not report.hasKey("vcs_undetermined_reason")
    # Actionable: both halves are present and non-empty. "No certificate" with
    # no explanation is what makes a withholding producer unusable.
    check report["message"].getStr.len > 0
    check report["remedy"].getStr.len > 0
    # And nothing was written where a certificate would have gone.
    check not fileExists(workspace / "certificate.toml")

  test "--no-certificate suppresses attestation entirely":
    let workspace = committedWorkspace("suppressed")
    let summaryPath = workspace / "summary.json"
    discard runCli(@["test", "run", "--workspace", workspace,
                     "--summary", summaryPath, "--threads", "1",
                     "--no-certificate"])
    require fileExists(summaryPath)
    check not parseJson(readFile(summaryPath)).hasKey("certificate")

  test "withholding an attestation does not change the run's exit code":
    ## The tests still ran. Withholding is a statement about what the producer
    ## will *claim*, never a verdict on the code under test.
    let workspace = committedWorkspace("exit-code")
    let withCertificate = runCli(@["test", "run", "--workspace", workspace,
                                   "--threads", "1"])
    let withoutCertificate = runCli(@["test", "run", "--workspace", workspace,
                                      "--threads", "1", "--no-certificate"])
    check withCertificate == withoutCertificate

    # EVERY reason decided after the tests passed, each produced for real:
    # the run exits 0 with or without attestation, and the summary names the
    # reason it withheld for.
    proc fixtureWorkspace(name: string; testFile = "adds\n"): string =
      result = scratchDir(name)
      createDir(result / "tests")
      writeFile(result / FixtureTestFile, testFile)
      writeFile(result / "notes.txt", "notes\n")
      git(result, ["init", "--initial-branch=main", "."])
      git(result, ["config", "user.email", "ct-test@example.invalid"])
      git(result, ["config", "user.name", "ct test suite"])
      git(result, ["config", "commit.gpgsign", "false"])
      git(result, ["add", "-A"])
      git(result, ["commit", "-m", "initial"])

    proc exitCodes(workspace, name: string): tuple[attested, disabled: int;
                                                   reason: string;
                                                   report: JsonNode] =
      let summaryPath = scratchDir(name & "-summary") / "summary.json"
      result.attested = runCtTest(
        @["test", "run", "--workspace", workspace, "--threads", "1",
          "--summary", summaryPath], fixtureRegistry(), newDiscoveryCache())
      let report = parseJson(readFile(summaryPath)){"certificate"}
      result.report = report
      checkpoint name & ": " & $report
      result.reason =
        if report{"issued"}.getBool: $wrNone
        else: report{"withheld_reason"}.getStr
      result.disabled = runCtTest(
        @["test", "run", "--workspace", workspace, "--threads", "1",
          "--no-certificate"], fixtureRegistry(), newDiscoveryCache())

    let issued = fixtureWorkspace("exit-issued")
    writeFile(issued / "notes.txt", "a tracked edit\n")

    let changed = fixtureWorkspace("exit-content-changed",
                                   "adds\n" & EditingMarker & "\n")

    let unmerged = fixtureWorkspace("exit-unmerged")
    git(unmerged, ["checkout", "-q", "-b", "theirs"])
    writeFile(unmerged / "notes.txt", "theirs\n")
    git(unmerged, ["commit", "-q", "-a", "-m", "theirs"])
    git(unmerged, ["checkout", "-q", "main"])
    writeFile(unmerged / "notes.txt", "ours\n")
    git(unmerged, ["commit", "-q", "-a", "-m", "ours"])
    git(unmerged, ["merge", "-q", "theirs"])

    let hidden = fixtureWorkspace("exit-index-hides")
    git(hidden, ["update-index", "--assume-unchanged", "notes.txt"])
    writeFile(hidden / "notes.txt", "behind git's back\n")

    let dependency = fixtureWorkspace("exit-submodule-dep")
    let parent = fixtureWorkspace("exit-submodule")
    git(parent, ["-c", "protocol.file.allow=always", "submodule", "add", "-q",
                 dependency, "vendor/dep"])
    git(parent, ["commit", "-q", "-m", "add dependency"])
    writeFile(parent / "vendor" / "dep" / "notes.txt", "patched\n")

    let outside = scratchDir("exit-not-a-repo")
    createDir(outside / "tests")
    writeFile(outside / FixtureTestFile, "adds\n")

    for (workspace, name, expected) in [
        (issued, "issued", wrNone),
        (changed, "content-changed", wrContentChanged),
        (unmerged, "unmerged", wrUnmergedEntries),
        (hidden, "index-hides", wrIndexHidesWorktree),
        (parent, "submodule", wrSubmoduleModified),
        (outside, "not-a-repo", wrVcsUndeterminable)]:
      let codes = exitCodes(workspace, name)
      check codes.reason == $expected
      check codes.attested == 0
      check codes.attested == codes.disabled
      # The summary carries the evidence for the reason, not only its name.
      case expected
      of wrContentChanged:
        check codes.report{"content_before"}.getStr.len > 0
        check codes.report{"content_before"}.getStr !=
              codes.report{"content"}.getStr
      of wrUnmergedEntries, wrIndexHidesWorktree, wrSubmoduleModified:
        check codes.report{"no_content_id"}.len > 0
        check not codes.report.hasKey("content")
      of wrNone:
        check not codes.report.hasKey("content_before")
        check codes.report{"base"}.getStr.len > 0
      else:
        discard
      if expected != wrNone:
        check codes.report{"remedy"}.getStr.len > 0

  test "a run that executed no test does not exit 0":
    ## **The exit code and the attestation must not contradict each other.**
    ## This workspace's only suite is a Nim ``std/unittest`` file whose
    ## provider declares ``canRun* = false``, so nothing executes. The
    ## certificate path has always refused to attest such a run
    ## (``wrNoTestsExecuted``) — while the exit code said 0, which is the whole
    ## defect: one half of the same binary called the run fine and the other
    ## half said nothing happened.
    let workspace = committedWorkspace("nothing-executed-exit")
    let summaryPath = workspace / "summary.json"
    let code = runCli(@["test", "run", "--workspace", workspace,
                        "--summary", summaryPath, "--threads", "1"])
    check code == ExitNothingExecuted
    check code != 0

    require fileExists(summaryPath)
    let summary = parseJson(readFile(summaryPath))
    # `executed` counts TESTS that finished, so it is 0 even though units were
    # dispatched. `dispatched` carries the count `executed` used to report.
    check summary["executed"].getInt == 0
    check summary["passed"].getInt == 0
    check summary["failed"].getInt == 0
    check summary["dispatched"].getInt > 0
    check summary["verdict"].getStr == $rvNothingExecuted
    # The units nothing could run are named, per provider, in the summary
    # itself rather than left to be inferred from `executed == 0`.
    check summary["unrunnable"].getInt > 0
    require summary.hasKey("errors")
    check summary["errors"].len > 0
    var mentionsNim = false
    for entry in summary["errors"]:
      if "nim-unittest" in entry.getStr:
        mentionsNim = true
    check mentionsNim
    # And the verdict agrees with the attestation, which is the invariant the
    # defect broke. Guarded with `hasKey` rather than indexed blind: `[]`
    # raises on a missing key and `{}` yields nil, and neither makes a good
    # failure report.
    require summary.hasKey("certificate")
    require summary["certificate"].hasKey("withheld_reason")
    check summary["certificate"]["withheld_reason"].getStr == $wrNoTestsExecuted

  test "the nothing-executed exit code survives --no-certificate":
    ## The verdict is a property of the RUN, so switching attestation off must
    ## not switch the honest exit status off with it.
    let workspace = committedWorkspace("nothing-executed-nocert")
    check runCli(@["test", "run", "--workspace", workspace, "--threads", "1",
                   "--no-certificate"]) == ExitNothingExecuted

  test "a workspace outside a repository reports the probe ran and could not tell":
    ## The mirror of the case above: here the probe DOES run, and its verdict
    ## is "undetermined" with a reason, rather than "not-probed".
    let workspace = scratchDir("undeterminable-cli")
    createDir(workspace / "tests")
    writeFile(workspace / "tests" / "calc_test.nim", """
import std/unittest

suite "calc":
  test "adds":
    check 1 + 1 == 2
""")
    let probe = probeVcs(workspace)
    check probe.probed
    check not probe.determined
    check "not inside a git repository" in probe.undeterminedReason

  test "an unattestable workspace reports why, outside a repository":
    ## The same run in a directory that is not a git repository withholds for a
    ## different reason, and says so — a producer that cannot determine
    ## cleanliness MUST NOT issue at all (Standard.md §3.2).
    let workspace = scratchDir("no-repo")
    createDir(workspace / "tests")
    writeFile(workspace / "tests" / "calc_test.nim", """
import std/unittest

suite "calc":
  test "adds":
    check 1 + 1 == 2
""")
    let probe = probeVcs(workspace)
    check not probe.determined
    check "not inside a git repository" in probe.undeterminedReason
