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
## ``certificate_local_store_test.nim`` justifies — which reports a pass for
## the test it is handed and, for one fixture file, edits a tracked file while
## it runs. Discovery, orchestration, issuance and the exit status are the
## shipped code.
##
## A run that issues PUBLISHES to the user's local certificate store, so this
## suite points ``TEST_CERTIFICATES_DIR`` (and the system root) at scratch
## directories before anything runs: no case may write the real store.

import std/[json, options, os, osproc, posix, streams, strutils, unittest]

import contracts
import certificate
import certificate_issuance
import certificate_verify_cli
import ct_test
import discovery
import run_orchestration
import ../common/ct_state_dir

const
  DefaultHookOutputDirForTest = ".ct" / "review"
    ## `agent_cli.DefaultHookOutputDir`, the end-of-turn hook's default
    ## dataset directory (that module is not importable from this lane).
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

let storeScratch = getTempDir() / "ct-test-cert-cli" /
                   ("store-" & $getCurrentProcessId())
removeDir(storeScratch)
putEnv("TEST_CERTIFICATES_DIR", storeScratch / "user-root")
putEnv("TEST_CERTIFICATES_SYSTEM_DIR", storeScratch / "system")

proc storeFileCount(): int =
  if dirExists(storeScratch / "user-root"):
    for path in walkDirRec(storeScratch / "user-root"):
      inc result

suite "ct test run certificate CLI":

  test "the usage text documents the certificate surface":
    ## A flag that decides whether an attestation is produced, or signed, and
    ## appears in no usage text is a flag nobody finds when they need it.
    let usage = ctTestUsageMessage()
    # 2026-10-10 (CTC-3e): `--certificate <path>` was removed (CTC-3 operator
    # decision 9); a run always publishes to the local certificate store.
    check "--certificate <path>" notin usage
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

  test "--no-certificate writes nothing to the local store":
    ## The case above, on a run that WOULD issue: a passing fixture test in
    ## a real repository. Without the flag it publishes one record; with it
    ## the local store stays absent and no `written_to` appears.
    let workspace = scratchDir("no-certificate-store")
    createDir(workspace / "tests")
    writeFile(workspace / FixtureTestFile, "adds\n")
    git(workspace, ["init", "--initial-branch=main", "."])
    git(workspace, ["config", "user.email", "ct-test@example.invalid"])
    git(workspace, ["config", "user.name", "ct test suite"])
    git(workspace, ["config", "commit.gpgsign", "false"])
    git(workspace, ["add", "-A"])
    git(workspace, ["commit", "-m", "initial"])
    removeDir(storeScratch)
    let summaryPath = scratchDir("no-certificate-store-summary") / "s.json"
    check runCtTest(@["test", "run", "--workspace", workspace, "--threads",
                      "1", "--summary", summaryPath, "--no-certificate"],
                    fixtureRegistry(), newDiscoveryCache()) == 0
    let suppressed = parseJson(readFile(summaryPath))
    check not suppressed.hasKey("certificate")
    check "written_to" notin $suppressed
    check not dirExists(storeScratch / "user-root")
    check storeFileCount() == 0
    check not dirExists(workspace / ".ct")
    # The control: the same run without the flag does publish.
    check runCtTest(@["test", "run", "--workspace", workspace, "--threads",
                      "1", "--summary", summaryPath],
                    fixtureRegistry(), newDiscoveryCache()) == 0
    let report = parseJson(readFile(summaryPath)){"certificate"}
    check report{"issued"}.getBool
    check report{"written_to"}.getStr.startsWith(storeScratch / "user-root")
    check storeFileCount() == 1

  test "--certificate is no longer accepted":
    ## Removed (CTC-3 operator decision 9), and NOT silently ignored: a script
    ## relying on it must find out. It is an unknown-flag usage error like any
    ## other — non-zero, the message names the flag — that runs no tests and
    ## writes nothing at the path it named.
    let workspace = scratchDir("certificate-flag")
    createDir(workspace / "tests")
    writeFile(workspace / FixtureTestFile, "adds\n")
    git(workspace, ["init", "--initial-branch=main", "."])
    git(workspace, ["config", "user.email", "ct-test@example.invalid"])
    git(workspace, ["config", "user.name", "ct test suite"])
    git(workspace, ["config", "commit.gpgsign", "false"])
    git(workspace, ["add", "-A"])
    git(workspace, ["commit", "-m", "initial"])
    let target = scratchDir("certificate-flag-out") / "run.toml"
    removeDir(storeScratch)
    let provider = fixtureRegistry()
    let summaryPath = scratchDir("certificate-flag-summary") / "s.json"
    # The error envelope is printed on stdout (and each message on stderr);
    # stdout is redirected to a file around the call so the case can read it.
    let captured = scratchDir("certificate-flag-stdout") / "stdout.json"
    flushFile(stdout)
    let saved = dup(1)
    let sink = posix.open(captured.cstring, O_WRONLY or O_CREAT or O_TRUNC,
                          0o600)
    discard dup2(sink, 1)
    let code = runCtTest(@["test", "run", "--workspace", workspace,
                           "--threads", "1", "--summary", summaryPath,
                           "--certificate", target],
                         provider, newDiscoveryCache())
    flushFile(stdout)
    discard dup2(saved, 1)
    discard posix.close(sink)
    discard posix.close(saved)
    let envelope = parseJson(readFile(captured))
    checkpoint $envelope
    check "unknown run argument: --certificate" in $envelope{"errors"}
    check code != 0
    check code == ExitTestsFailed
    # Rejected before discovery: nothing dispatched, nothing executed.
    check envelope{"dispatched"}.getInt == 0
    check envelope{"executed"}.getInt == 0
    check not fileExists(target)
    check not fileExists(summaryPath)
    check storeFileCount() == 0

  test "CodeTracer's own .ct/ state never makes a certificate untracked":
    ## Regression guard. Until CTC-3e the certificate store under `.ct/`
    ## wrote `.ct/.gitignore` as a side effect, and every other writer of
    ## `.ct/` relied on it. The store left the workspace; `ct agent
    ## end-of-turn` still writes `.ct/review` (and the documented workflow
    ## records into `.ct/runs`). Those writers now guard `.ct/` themselves
    ## through `ct_state_dir.guardCtStateWrite` — the call `ct review
    ## collect` and `ct record -o` make before their subprocess writes (the
    ## end-to-end hook run is asserted in `src/tests/cli/agent_cli_test.nim`).
    proc freshRepository(name: string): string =
      result = scratchDir(name)
      createDir(result / "tests")
      writeFile(result / FixtureTestFile, "adds\n")
      git(result, ["init", "--initial-branch=main", "."])
      git(result, ["config", "user.email", "ct-test@example.invalid"])
      git(result, ["config", "user.name", "ct test suite"])
      git(result, ["config", "commit.gpgsign", "false"])
      git(result, ["add", "-A"])
      git(result, ["commit", "-m", "initial"])

    proc porcelain(workspace: string): string =
      let (output, code) = execCmdEx(
        "git status --porcelain=v1 --untracked-files=normal",
        workingDir = workspace)
      check code == 0
      output

    proc issuedUntracked(workspace, name: string): JsonNode =
      let summaryPath = scratchDir(name & "-summary") / "s.json"
      check runCtTest(@["test", "run", "--workspace", workspace, "--threads",
                        "1", "--summary", summaryPath],
                      fixtureRegistry(), newDiscoveryCache()) == 0
      let report = parseJson(readFile(summaryPath)){"certificate"}
      checkpoint name & ": " & $report
      check report{"issued"}.getBool
      report{"untracked"}

    # `ct test run` itself leaves nothing under `.ct/`, nor anything else
    # untracked, and the certificate it issues says so.
    let tested = freshRepository("ct-dir-after-test-run")
    check not issuedUntracked(tested, "after-test-run").getBool(true)
    check porcelain(tested) == ""
    check not dirExists(tested / ".ct")
    check not issuedUntracked(tested, "after-second-test-run").getBool(true)

    # The end-of-turn hook's writes, through the guard its collector calls.
    let hooked = freshRepository("ct-dir-after-end-of-turn")
    for target in [hooked / DefaultHookOutputDirForTest,
                   hooked / ".ct" / "runs" / "run-1"]:
      check guardCtStateWrite(target) == ""
      createDir(target)
      writeFile(target / "review.json", "{}\n")
    check fileExists(hooked / ".ct" / CtStateIgnoreFileName)
    check porcelain(hooked) == ""
    check not issuedUntracked(hooked, "after-end-of-turn").getBool(true)

    # The control: the same writes WITHOUT the guard are what flipped it.
    let unguarded = freshRepository("ct-dir-unguarded")
    createDir(unguarded / DefaultHookOutputDirForTest)
    writeFile(unguarded / DefaultHookOutputDirForTest / "review.json", "{}\n")
    check porcelain(unguarded) != ""
    check issuedUntracked(unguarded, "unguarded").getBool(false)

    # A user's own `.ct/.gitignore` is theirs: never replaced.
    let own = freshRepository("ct-dir-own-ignore")
    createDir(own / ".ct")
    writeFile(own / ".ct" / CtStateIgnoreFileName, "review/\n")
    check guardCtStateWrite(own / ".ct" / "review") == ""
    check readFile(own / ".ct" / CtStateIgnoreFileName) == "review/\n"
    # Paths outside `.ct/` are not touched; a `*.ct` container is not `.ct/`.
    check guardCtStateWrite(own / "out" / "trace.ct") == ""
    check not dirExists(own / "out")

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

proc untrackedWorkspace(name: string; config = ""; editing = false): string =
  ## A real repository holding the fixture test, a tracked `notes.txt` and,
  ## when given, a COMMITTED `.codetracer/test.toml`; then an untracked
  ## scratch file. With ``editing`` the fixture test appends to `notes.txt`
  ## while it runs, so an unchanged `notes.txt` proves that no test ran.
  result = scratchDir(name)
  createDir(result / "tests")
  writeFile(result / FixtureTestFile,
            if editing: "adds\n" & EditingMarker & "\n" else: "adds\n")
  writeFile(result / "notes.txt", "notes\n")
  if config.len > 0:
    createDir(result / ".codetracer")
    writeFile(result / ".codetracer" / "test.toml", config)
  git(result, ["init", "--initial-branch=main", "."])
  git(result, ["config", "user.email", "ct-test@example.invalid"])
  git(result, ["config", "user.name", "ct test suite"])
  git(result, ["config", "commit.gpgsign", "false"])
  git(result, ["add", "-A"])
  git(result, ["commit", "-m", "initial"])
  writeFile(result / "scratch.log", "untracked\n")

proc runFixture(workspace, name: string; extra: seq[string] = @[]):
    tuple[exitCode: int; report: JsonNode] =
  ## `ct test run` through the shipped CLI over the fixture provider, with
  ## the summary read back from `--summary`. `report` is nil when the run was
  ## refused before it ran (no summary is written then).
  let summaryPath = scratchDir(name & "-summary") / "summary.json"
  result.exitCode = runCtTest(
    @["test", "run", "--workspace", workspace, "--threads", "1",
      "--summary", summaryPath] & extra, fixtureRegistry(), newDiscoveryCache())
  if fileExists(summaryPath):
    result.report = parseJson(readFile(summaryPath)){"certificate"}
    checkpoint name & ": " & $result.report

const StrictConfig = "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                     "untracked = \"strict\"\n"

suite "ct test run: the untracked-files mode (CTC-3g)":

  test "the untracked mode is read from .codetracer/test.toml":
    ## `untracked = "strict"` in the committed file selects strict mode with
    ## no flag; `--untracked=reads` overrides it; an unknown value is a named
    ## configuration error reported before any test runs, and no certificate
    ## is written (the tests still run).
    let strict = untrackedWorkspace("untracked-config-strict", StrictConfig)
    let before = storeFileCount()
    let fromFile = runFixture(strict, "config-strict")
    check fromFile.exitCode == 0          # withholding never changes it
    check not fromFile.report{"issued"}.getBool
    check fromFile.report{"withheld_reason"}.getStr == $wrUntrackedInput
    check fromFile.report{"untracked_mode"}.getStr == "strict"
    check fromFile.report{"untracked_inputs"}.getElems.len == 1
    check fromFile.report{"untracked_inputs"}[0].getStr == "scratch.log"
    check "scratch.log" in fromFile.report{"message"}.getStr
    check "git add" in fromFile.report{"remedy"}.getStr
    check storeFileCount() == before      # withheld: nothing published

    # The command line wins, in both spellings.
    for (spelling, name) in [(@["--untracked=reads"], "flag-equals"),
                             (@["--untracked", "reads"], "flag-separate")]:
      let overridden = runFixture(strict, name, spelling)
      check overridden.exitCode == 0
      check overridden.report{"issued"}.getBool
      check overridden.report{"untracked_mode"}.getStr == "reads"
      check overridden.report{"untracked"}.getBool
      check overridden.report{"read_set"}.getStr == "not-captured"
      check "no read set was captured" in
            overridden.report{"untracked_note"}.getStr
    check storeFileCount() > before

    # And the flag can select strict over a file that says nothing.
    let silent = untrackedWorkspace("untracked-config-none")
    let byFlag = runFixture(silent, "flag-strict", @["--untracked=strict"])
    check byFlag.report{"withheld_reason"}.getStr == $wrUntrackedInput
    check byFlag.report{"untracked_mode"}.getStr == "strict"
    let byDefault = runFixture(silent, "default")
    check byDefault.report{"issued"}.getBool
    check byDefault.report{"untracked_mode"}.getStr == "reads"

    # An unknown value in the file: reported before the tests run, which
    # still run with their own exit status; the certificate is withheld, naming the file and the value, and
    # nothing is published. A broken configuration decides the claim, never
    # whether the tests run.
    const LenientConfig = "schema = \"codetracer.test.v1\"\n" &
                          "[certificate]\nuntracked = \"lenient\"\n"
    let storeBefore = storeFileCount()
    let still = untrackedWorkspace("untracked-config-unknown-still",
                                   LenientConfig)
    let unresolved = runFixture(still, "config-unknown")
    check unresolved.exitCode == 0
    check not unresolved.report.isNil
    check not unresolved.report{"issued"}.getBool
    check unresolved.report{"withheld_reason"}.getStr ==
          $wrUntrackedModeUnresolved
    check unresolved.report{"untracked_mode"}.getStr == "unresolved"
    check not unresolved.report.hasKey("read_set")
    check ".codetracer/test.toml" in unresolved.report{"message"}.getStr
    check "lenient" in unresolved.report{"message"}.getStr
    check "--untracked" in unresolved.report{"remedy"}.getStr
    check ".codetracer/test.toml" in
          unresolved.report{"untracked_mode_problem"}.getStr
    # The tests did run: this fixture's test edits notes.txt (which then
    # withholds for changed content first; the mode is still reported as
    # unresolved, never as a default nobody chose).
    let unknown = untrackedWorkspace("untracked-config-unknown",
                                     LenientConfig, editing = true)
    let ranAnyway = runFixture(unknown, "config-unknown-editing")
    check ranAnyway.exitCode == 0
    check readFile(unknown / "notes.txt") != "notes\n"
    check ranAnyway.report{"untracked_mode"}.getStr == "unresolved"
    check storeFileCount() == storeBefore
    writeFile(unknown / "notes.txt", "notes\n")
    let resolved = resolveUntrackedMode(unknown, false, umReads)
    check not resolved.ok
    check ".codetracer/test.toml" in resolved.problem
    check "lenient" in resolved.problem
    check "no untracked-files mode is assumed" in resolved.problem
    # The flag makes the file unnecessary, as `verify --targets` does: the
    # mode is the flag's, and the file is not consulted.
    let flagged = runFixture(unknown, "config-unknown-flag",
                             @["--untracked=strict"])
    check flagged.exitCode == 0
    check not flagged.report.isNil
    check flagged.report{"untracked_mode"}.getStr == "strict"
    check not flagged.report.hasKey("untracked_mode_problem")
    check readFile(unknown / "notes.txt") != "notes\n"

    # An unknown value on the command line is a usage error, like any bad
    # flag value: exit 1 before anything runs.
    let editingStrict = untrackedWorkspace("untracked-flag-unknown",
                                           StrictConfig, editing = true)
    let badFlag = runFixture(editingStrict, "flag-unknown",
                             @["--untracked=lenient"])
    check badFlag.exitCode == 1
    check badFlag.report.isNil
    check readFile(editingStrict / "notes.txt") == "notes\n"

    # The file is read from the working tree, the state a run certifies: an
    # uncommitted edit to it is what applies.
    createDir(silent / ".codetracer")
    writeFile(silent / ".codetracer" / "test.toml", StrictConfig)
    let edited = resolveUntrackedMode(silent, false, umReads)
    check edited.ok
    check edited.mode == umStrict
    check edited.source == usConfiguration
    check edited.file == ".codetracer/test.toml"

    # `--no-certificate` reads no configuration at all.
    check runCtTest(@["test", "run", "--workspace", unknown, "--threads", "1",
                      "--no-certificate"], fixtureRegistry(),
                    newDiscoveryCache()) == 0

  test "the usage text documents the untracked mode":
    let usage = ctTestUsageMessage()
    check "--untracked reads|strict" in usage
    check "[certificate] untracked" in usage
    check "no read set was captured" in usage

# Module level, not an exit hook (see 5175da85f).
try: removeDir(storeScratch)
except CatchableError: discard
