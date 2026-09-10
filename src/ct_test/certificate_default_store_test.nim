## CTC-2 — where `ct test` publishes a certificate, and what that costs the
## next run.
##
## CTC-1 wrote a certificate nowhere unless `--certificate <path>` said where,
## and flagged the placement as this milestone's foot-gun: a record written
## inside the workspace is a file the NEXT run's VCS probe sees. This suite is
## the proof that the placement chosen for it does not do that — and the
## control that shows the guard is load-bearing rather than decorative.
##
## The chain is real end to end. Every case drives the shipped CLI entry point
## (`ct_test.runCtTest`, the same proc `ct test run` reaches) against a real git
## repository in a temporary directory: real discovery, the real worker pool,
## the real `probeVcs` shelling out to real git, the real `issueCertificate`,
## the real publish, and — for the end-to-end case — the real
## `readCertificateStore` over the real filesystem and the SHIPPED status-bar
## evaluator deciding the verdict.
##
## MOCKING POLICY (CLAUDE.md requires every mock to be justified here)
## -------------------------------------------------------------------
## Two seams, both narrow, and neither is inside the subject:
##
## * **The in-process fixture provider.** A `ct test` run needs a provider that
##   can actually RUN something, and every shipped provider needs a language
##   toolchain that CI may or may not have — which would make this suite's
##   subject "is node installed" rather than "where does the record land". The
##   fixture supplies exactly what a language adapter supplies: `detect`,
##   `discoverProject` and `run`. Nothing in discovery, orchestration, issuance
##   or publication is stubbed, and the provider is honest — it reports a pass
##   for a test it really was asked to run. This is the same seam, for the same
##   reason, that `certificate_issuance_test.nim` justifies.
##
## * **The indicator's fact reader, in the end-to-end case only.** The status
##   bar gathers its facts through the platform facade, which needs a Platform
##   installed and therefore belongs to the ViewModel lanes; the facade half is
##   covered by `src/tests/gui/tests/status-bar/certificate_indicator_native_test.nim`
##   against a real repository. Here the two facts the facade would supply —
##   the commit and whether the tree is clean — are read from the SAME real git
##   repository with the same two commands, and everything downstream of them
##   (the store discovery, the reader, the verifier, the evaluator) is the
##   shipped code. What this case exists to prove is that what `ct test` WROTE
##   is what the indicator FINDS, and no facade is involved in that.
##
## ENVIRONMENT
## -----------
## `getTempDir()` MUST NOT be inside a git repository: the repositories below
## would otherwise find the enclosing one and the cleanliness assertions would
## be about this checkout rather than about the fixture. Asserted, loudly, in
## the first case.

import std/[exitprocs, json, options, os, osproc, streams, strutils, unittest]

import contracts
import certificate
import certificate_default_store
import certificate_issuance
import certificate_store
import ct_test
import discovery
import process_exec

# The status-bar evaluator, imported by path because it lives in the front end.
# It is host-free by construction (SB-1 moved the signature primitive out for
# exactly this reason), so a native suite can drive it directly — which is what
# makes the end-to-end case below possible without a Platform.
import ../frontend/viewmodel/viewmodels/certificate_indicator_vm

# ---------------------------------------------------------------------------
# Countable assertions. `[OK]` counts test BLOCKS, and a block that asserts
# nothing prints one too, so the lane cannot score this file unless it says how
# many checks it ran (`ci/lib/run-nim-test-lane.sh`).
# ---------------------------------------------------------------------------
var checksRun = 0

template ck(condition: untyped) =
  inc checksRun
  check condition

# ---------------------------------------------------------------------------
# The in-process fixture provider
# ---------------------------------------------------------------------------

const
  FixtureProviderId = "fixture-default-store"
  FixtureLanguage = "fixture"
  FixtureFramework = "inproc"
  FixtureTestFile = "tests/calc_test.fixture"

proc fixtureInfo(): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    displayName: "In-process default-store fixture provider",
    version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      canRecordProject: false, canRecordFile: false, canRecordSingle: false,
      canCapturePerTestOutput: true, canMapTraceEntryPoints: false,
      emitsStructuredEvents: true))

proc fixtureItem(): TestItem =
  TestItem(
    id: makeTestItemId(FixtureProviderId, FixtureLanguage, FixtureFramework,
                       FixtureTestFile, FixtureTestFile & "::adds"),
    providerId: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    name: "adds",
    kind: tikCase,
    file: FixtureTestFile,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: FixtureTestFile & "::adds",
    tags: @["fixture"],
    location: LocationProvenance(source: lskPattern,
      detail: "in-process fixture", confidence: lcHigh))

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## The leaf a language adapter supplies: it reports a pass for the test it
  ## was handed, which is what a real provider does after parsing its
  ## subprocess output.
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekRunStarted,
              providerId: FixtureProviderId, runId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId, status: some(tsPassed), durationMs: 1),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekRunFinished,
              providerId: FixtureProviderId, runId: scope.testId)])

proc fixtureDetect(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
  ProviderResult[bool](diagnostics: @[],
                       value: fileExists(projectRoot / FixtureTestFile))

proc fixtureDiscoverProject(projectRoot: string):
    ProviderResult[TestCatalog] {.gcsafe.} =
  ProviderResult[TestCatalog](diagnostics: @[], value: TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: fixtureInfo(),
    items: (if fileExists(projectRoot / FixtureTestFile): @[fixtureItem()]
            else: @[]),
    diagnostics: @[]))

proc fixtureRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo())
  provider.detect = fixtureDetect
  provider.discoverProject = fixtureDiscoverProject
  provider.run = fixtureRun
  ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @[])])

# ---------------------------------------------------------------------------
# Real repositories, in a temporary directory
# ---------------------------------------------------------------------------

let scratchRoot = getTempDir() / "ct-cert-default-store-" &
                  $getCurrentProcessId()

proc run(cmd: string; args: openArray[string]; cwd: string):
    tuple[output: string; code: int] =
  var p = startProcess(cmd, workingDir = cwd, args = @args,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc scratchDir(name: string): string =
  result = scratchRoot / name
  removeDir(result)
  createDir(result)

proc gitStatus(repo: string): string =
  run("git", ["status", "--porcelain=v1", "--untracked-files=normal"],
      repo).output.strip()

proc headCommit(repo: string): string =
  run("git", ["rev-parse", "HEAD"], repo).output.strip()

proc committedRepo(name: string): string =
  ## A repository holding exactly one fixture test file, committed, with
  ## nothing else in it — the "project using no reprobuild at all" CTC-2's
  ## end-to-end proof is about. Note there is deliberately **no `.gitignore`**:
  ## whatever keeps the store from dirtying the tree has to come from the
  ## producer, not from the fixture.
  result = scratchDir(name)
  createDir(result / "tests")
  writeFile(result / FixtureTestFile, "adds\n")
  discard run("git", ["init", "--initial-branch=main", "."], result)
  discard run("git", ["config", "user.email", "ctc2@example.invalid"], result)
  discard run("git", ["config", "user.name", "ctc2 suite"], result)
  discard run("git", ["config", "commit.gpgsign", "false"], result)
  discard run("git", ["add", "-A"], result)
  discard run("git", ["commit", "-m", "initial"], result)

proc summaryPathFor(name: string): string =
  ## OUTSIDE the workspace, deliberately. A summary written inside it would be
  ## an untracked file of the suite's own making, and the very property these
  ## cases measure is whether the run leaves the tree undisturbed.
  scratchRoot / "summaries" / name & ".json"

proc runCli(repo, name: string; extra: seq[string] = @[]):
    tuple[code: int; summary: JsonNode] =
  ## One `ct test run`, through the shipped CLI entry point.
  let path = summaryPathFor(name)
  createDir(parentDir(path))
  removeFile(path)
  let code = runCtTest(
    @["test", "run", "--workspace", repo, "--threads", "1",
      "--summary", path] & extra,
    fixtureRegistry(), newDiscoveryCache())
  var summary = newJObject()
  if fileExists(path):
    summary = parseJson(readFile(path))
  (code, summary)

proc publishedRecord(repo: string): string =
  defaultCertificatePath(repo, currentPlatform())

proc indicatorFor(repo: string): CertificateIndicatorModel =
  ## The shipped status-bar evaluator, over the real store on disk. See the
  ## mocking-policy note in the header for what is and is not supplied here.
  evaluateCertificateIndicator(CertificateIndicatorFacts(
    store: readCertificateStore(nativeStoreAccess(), repo),
    vcs: WorkspaceVcsState(
      known: true,
      repo: repo.lastPathPart,
      commit: headCommit(repo),
      clean: gitStatus(repo).len == 0,
      treeKnown: false,
      tree: ""),
    platform: currentPlatform(),
    signatureVerifier: nil))

# ---------------------------------------------------------------------------
# Git runners, for the answers a real repository cannot produce
#
# `publishCertificate` takes an injectable runner for the same reason
# `probeVcs` does, and these are the answers that seam exists for: a git that
# exits neither 0 nor 1 (absent from PATH, refusing, not a repository) cannot
# be arranged against a real checkout at test speed. They decide nothing about
# the certificate — the runner is consulted only for `check-ignore`.
# ---------------------------------------------------------------------------
var seenArgv: seq[string] = @[]

proc ignoredRunner(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
  ## `git check-ignore` exit 0 — the path IS ignored.
  CapturedRun(output: "", exitCode: 0)

proc notIgnoredRunner(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
  ## exit 1 — NOT ignored, which includes the already-tracked case.
  CapturedRun(output: "", exitCode: 1)

proc muteRunner(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
  ## Anything else — here 128, git's "fatal:" exit. The question was not
  ## answered, and an unanswered question is not a finding.
  {.cast(gcsafe).}:
    seenArgv = argv
  CapturedRun(output: "fatal: not a git repository", exitCode: 128)

addExitProc proc() =
  try: removeDir(scratchRoot)
  except CatchableError: discard

# ---------------------------------------------------------------------------

suite "CTC-2: the default certificate store":

  test "the temporary directory is outside any git repository":
    ## A precondition, asserted once and loudly: inside a repository every
    ## cleanliness assertion below would be about this checkout instead of
    ## about the fixture.
    let probe = scratchDir("environment-check")
    let toplevel = run("git", ["rev-parse", "--show-toplevel"], probe)
    if toplevel.code == 0:
      echo "TMPDIR is inside a git repository (", toplevel.output.strip(), ")."
      echo "Set TMPDIR to a directory outside any repository and re-run."
    ck toplevel.code != 0

  test "a passing run publishes into the workspace store with no flag at all":
    ## CTC-2's first job: `ct test` writes to `.ct/certificates` BY DEFAULT,
    ## not only where `--certificate <path>` points. The store directory is the
    ## one `certificate_store` discovers, which is what makes the indicator
    ## find it without a second convention.
    let repo = committedRepo("published")
    let (code, summary) = runCli(repo, "published")
    ck code == 0

    ck summary.hasKey("certificate")
    let report = summary{"certificate"}
    checkpoint $report
    ck report{"issued"}.getBool
    ck report{"framework"}.getStr == CtTestFramework
    ck report{"clean"}.getBool
    ck report.hasKey("written_to")
    ck report{"written_to"}.getStr == defaultCertificateRelativePath(
      currentPlatform())

    # The file is really there, is really a certificate, and really describes
    # this repository at this commit.
    ck fileExists(publishedRecord(repo))
    let read = readCertificate(readFile(publishedRecord(repo)))
    checkpoint read.detail
    ck read.status == crsOk
    ck read.cert.framework == CtTestFramework
    ck read.cert.vcs.commit == headCommit(repo)
    ck read.cert.vcs.clean
    ck read.cert.targets == @[FixtureTestFile]

  test "the published record does not dirty the tree, and the next run certifies":
    ## THE CASE CTC-1 FLAGGED IN ADVANCE. A record written inside the workspace
    ## is a file `git status` can see, and a producer whose own output changes
    ## the answer it reports about the user's tree has broken the thing it was
    ## measuring: `untracked = true` on every run after the first, and — once
    ## the store is tracked — `clean = false` and a permanent withholding.
    ##
    ## So the assertion is not "the first run works". It is that the SECOND
    ## consecutive run, with the first run's record on disk, still sees a clean
    ## tree with no untracked files and still issues.
    let repo = committedRepo("consecutive")
    ck gitStatus(repo) == ""

    let first = runCli(repo, "consecutive-1")
    ck first.code == 0
    ck first.summary{"certificate"}{"issued"}.getBool

    # The tree is byte-for-byte as clean as before the run, as GIT sees it —
    # which is the only opinion that matters, because `probeVcs` is a reader of
    # `git status` and nothing else.
    checkpoint "git status after run 1: '" & gitStatus(repo) & "'"
    ck gitStatus(repo) == ""

    let second = runCli(repo, "consecutive-2")
    ck second.code == 0
    let report = second.summary{"certificate"}
    checkpoint $report
    ck report{"issued"}.getBool
    ck report{"vcs"}.getStr == "determined"
    # Both halves. `clean = false` would have WITHHELD; `untracked = true`
    # would have been issued but would have recorded the producer's own
    # bookkeeping as scratch work in the user's tree.
    ck report{"clean"}.getBool
    ck report{"untracked"}.getBool == false
    ck report{"commit"}.getStr == headCommit(repo)

    # And the second record replaces the first rather than accumulating beside
    # it: the file is named for the platform, so a store cannot grow one file
    # per run.
    var records = 0
    for kind, path in walkDir(repo / CtTestStoreDir):
      if kind in {pcFile, pcLinkToFile} and path.endsWith(".toml"):
        inc records
    ck records == 1

    # A third run, for the same reason the second exists: a guard that holds
    # once and then rots would pass the case above.
    let third = runCli(repo, "consecutive-3")
    ck third.code == 0
    ck third.summary{"certificate"}{"issued"}.getBool
    ck third.summary{"certificate"}{"clean"}.getBool
    ck gitStatus(repo) == ""

  test "a reprobuild-free project reads certified after ct test":
    ## CTC-2's end-to-end proof, and the reason the standard was extracted from
    ## reprobuild in the first place: a project using **no reprobuild at all**
    ## runs `ct test`, and CodeTracer's status bar reports it as certified.
    ##
    ## Nothing here writes a certificate by hand. The record under evaluation
    ## is the one the run above published, discovered by the shipped
    ## `readCertificateStore` over the real filesystem and judged by the
    ## shipped `evaluateCertificateIndicator`.
    let repo = committedRepo("no-reprobuild")
    let (code, _) = runCli(repo, "no-reprobuild")
    ck code == 0

    # There is no reprobuild anywhere in this project, and the indicator still
    # has something to read.
    ck not dirExists(repo / ReprobuildStoreDir)
    ck not dirExists(repo / ".repro")

    let model = indicatorFor(repo)
    checkpoint $model.state & " — " & model.summary & " (" &
               model.certificateName & ")"
    ck model.state == cisCertified
    ck model.label == CertifiedLabel
    ck model.certificateName ==
      defaultCertificateRelativePath(currentPlatform())
    ck model.remedy == ""

    # THE CONTROL: commit something, and the same store no longer covers the
    # tree. Without this the case above would pass for an evaluator that says
    # "certified" whenever it finds a file.
    writeFile(repo / "extra.txt", "later\n")
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-m", "move on"], repo)
    let moved = indicatorFor(repo)
    checkpoint "after a commit: " & $moved.state
    ck moved.state == cisWasCertified

    # And running again re-certifies, which is the loop a user actually lives
    # in — and it is the consecutive-run property again, reached from the
    # consumer's side rather than from the producer's.
    let again = runCli(repo, "no-reprobuild-2")
    ck again.code == 0
    ck indicatorFor(repo).state == cisCertified

  test "the store is invisible to git because git was told to ignore it":
    ## The mechanism, named rather than inferred from the case above. `ct test`
    ## writes `.ct/.gitignore` containing `*`, which matches every entry in the
    ## directory INCLUDING itself — so nothing has to be committed for the
    ## guard to hold, and `git status` reports the directory not at all.
    let repo = committedRepo("ignored")
    discard runCli(repo, "ignored")
    let guard = repo / WorkspaceStateDir / StoreIgnoreFileName
    ck fileExists(guard)
    ck "*" in readFile(guard)
    # git's own opinion, which is the one that decides: both the record and the
    # guard file are ignored.
    ck run("git", ["check-ignore", "-q", "--",
                   defaultCertificateRelativePath(currentPlatform())],
           repo).code == 0
    ck run("git", ["check-ignore", "-q", "--",
                   WorkspaceStateDir & "/" & StoreIgnoreFileName], repo).code == 0
    ck gitStatus(repo) == ""

  test "the ignore guard is written once and never overwritten":
    ## The guard is the producer touching a file the user owns, so the rule is
    ## narrow: create it when it is absent, and never rewrite it. A workspace
    ## that put its own rules in `.ct/.gitignore` meant them, and a producer
    ## that replaced them would be editing a user's configuration to make its
    ## own life easier.
    ##
    ## Driven through `publishCertificate` directly rather than through the CLI,
    ## because what is under test is the publish contract — every field of
    ## `PublishOutcome` — and a run is a slower way to reach it.
    let repo = committedRepo("guard-once")
    let first = publishCertificate(repo, "linux/amd64", "first\n")
    ck first.written
    ck first.error == ""
    ck first.ignoreGuardCreated
    ck first.ignoreGuardError == ""
    ck first.path == CtTestStoreDir & "/linux-amd64.toml"
    let guard = readFile(repo / WorkspaceStateDir / StoreIgnoreFileName)

    let second = publishCertificate(repo, "linux/amd64", "second\n")
    ck second.written
    ck not second.ignoreGuardCreated
    ck readFile(repo / WorkspaceStateDir / StoreIgnoreFileName) == guard
    # And the record itself IS replaced, which is the other half of "one record
    # per platform": the store does not grow a file per run.
    ck readFile(defaultCertificatePath(repo, "linux/amd64")) == "second\n"

  test "a store git does not ignore is reported, not silently accepted":
    ## The control that makes the case above mean something, and the case the
    ## guard CANNOT fix: `.gitignore` has no effect on a path that is already
    ## tracked, and a workspace that committed its store before this existed
    ## stays in the loop CTC-1 warned about. It is detected and named instead.
    ##
    ## Here the workspace already has a `.ct/.gitignore` of its own that does
    ## not cover the store — the shape a user produces by writing one comment
    ## into the file — so the producer leaves it alone (it is the user's
    ## configuration) and reports what it costs.
    let repo = committedRepo("not-ignored")
    createDir(repo / WorkspaceStateDir)
    writeFile(repo / WorkspaceStateDir / StoreIgnoreFileName,
              "# mine, and it covers nothing\n")
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-m", "own ignore rules"], repo)

    let (code, summary) = runCli(repo, "not-ignored")
    ck code == 0
    let report = summary{"certificate"}
    checkpoint $report
    ck report{"issued"}.getBool
    ck report.hasKey("store_notice")
    let notice = report{"store_notice"}.getStr
    checkpoint notice
    ck notice.len > 0
    ck ".gitignore" in notice
    # The user's own file was not overwritten.
    ck readFile(repo / WorkspaceStateDir / StoreIgnoreFileName) ==
       "# mine, and it covers nothing\n"

    # And the notice is TRUE rather than cautious: the tree really is dirty
    # now, and the next run really does record it.
    checkpoint "git status: '" & gitStatus(repo) & "'"
    ck gitStatus(repo) != ""
    let second = runCli(repo, "not-ignored-2")
    ck second.summary{"certificate"}{"issued"}.getBool
    ck second.summary{"certificate"}{"untracked"}.getBool

  test "--certificate <path> still writes exactly where it is told":
    ## The explicit path is an override, not an addition: a caller who names a
    ## destination gets that destination and nothing else, which is what keeps
    ## `--certificate` usable for writing a record OUTSIDE the repository.
    let repo = committedRepo("explicit")
    let target = scratchRoot / "explicit-out" / "run.toml"
    let (code, summary) = runCli(repo, "explicit",
                                 @["--certificate", target])
    ck code == 0
    ck summary{"certificate"}{"issued"}.getBool
    ck summary{"certificate"}{"written_to"}.getStr == target
    ck fileExists(target)
    ck readCertificate(readFile(target)).status == crsOk
    # Nothing was written into the workspace, so the tree is untouched.
    ck not dirExists(repo / WorkspaceStateDir)
    ck gitStatus(repo) == ""

  test "a withheld run publishes nothing":
    ## A producer claims only what it ran, and the default destination must not
    ## turn that rule into "write something anyway". A dirty tree withholds
    ## (the modified-worktree form is deferred), and the store must stay empty.
    let repo = committedRepo("withheld")
    writeFile(repo / FixtureTestFile, "adds, differently\n")
    let (code, summary) = runCli(repo, "withheld")
    ck code == 0                      # the tests still ran and still passed
    let report = summary["certificate"]
    checkpoint $report
    ck report{"issued"}.getBool == false
    ck report{"withheld_reason"}.getStr == $wrWorktreeDirty
    ck not report.hasKey("written_to")
    ck not fileExists(publishedRecord(repo))
    ck not dirExists(repo / CtTestStoreDir)

  test "the usage text says where a run publishes by default":
    ## A destination nobody can find in `--help` is a destination a user
    ## discovers by accident. The same argument the flags themselves are
    ## documented under (`certificate_cli_test.nim`), applied to the behaviour
    ## that now happens with no flag at all.
    let usage = ctTestUsageMessage()
    ck CtTestStoreDir in usage
    ck WorkspaceStateDir & "/.gitignore" in usage
    ck "--certificate <path>" in usage
    ck "--no-certificate" in usage

  test "the file name is derived from the platform and cannot escape the store":
    ## `linux/amd64` names one record per platform, which is the shape
    ## Transport.md §2 describes. The sanitisation is a whitelist rather than a
    ## separator swap because a file name decides where a write lands, and a
    ## platform string is not a place to start trusting input.
    ck certificateFileName("linux/amd64") == "linux-amd64.toml"
    ck certificateFileName("macos/arm64") == "macos-arm64.toml"
    ck certificateFileName("../../etc/passwd") == "------etc-passwd.toml"
    ck certificateFileName("") == UnknownPlatformFileStem & ".toml"
    ck certificateFileName("...") == UnknownPlatformFileStem & ".toml"
    ck '/' notin certificateFileName("a/b/c")
    ck defaultCertificateRelativePath("linux/amd64") ==
      CtTestStoreDir & "/linux-amd64.toml"

  test "a git that could not answer produces no notice, because a guess is not a finding":
    ## The third arm of `check-ignore`'s three-way reading, which the two cases
    ## above cannot reach: exit 0 is "ignored" and exit 1 is "not ignored", but
    ## ANYTHING ELSE means git did not answer — no git on PATH, not a
    ## repository, a refusal. That must produce no notice at all. Warning about
    ## a state that was never established is the same guess this producer
    ## refuses everywhere else, and it would send a user to `git rm --cached`
    ## a path nobody established was tracked.
    ##
    ## All three arms are asserted here, so the reading cannot collapse in
    ## either direction: a build that treated "could not answer" as a finding,
    ## and one that treated "not ignored" as silence, both redden this case.
    let repo = committedRepo("check-ignore-arms")
    ck publishCertificate(repo, "linux/amd64", "doc\n",
                          GitCommandRunner(ignoredRunner)).notIgnoredNotice ==
       ""
    ck publishCertificate(repo, "linux/amd64", "doc\n",
                          GitCommandRunner(notIgnoredRunner))
       .notIgnoredNotice.len > 0

    let mute = publishCertificate(repo, "linux/amd64", "doc\n",
                                  GitCommandRunner(muteRunner))
    checkpoint "notice after an unanswerable check-ignore: '" &
               mute.notIgnoredNotice & "'"
    ck mute.notIgnoredNotice == ""
    # The record is published either way. A question git could not answer is a
    # reason to say nothing, never a reason to withhold the file.
    ck mute.written
    ck mute.error == ""
    # And the question really was asked, about the path just written.
    checkpoint $seenArgv
    ck seenArgv == @["git", "check-ignore", "-q", "--",
                     defaultCertificateRelativePath("linux/amd64")]

  test "a record that could not be written is reported, never claimed as published":
    ## Publishing is the last step of a run that already happened, so a store
    ## that cannot be written must not change the run's verdict or its exit
    ## code — and must not be reported as a publication either. `written_to`
    ## names a file that exists; `write_error` says why there is none. A
    ## producer that reported the write it did not do would put a path in the
    ## summary that nothing can read.
    let repo = committedRepo("unwritable")
    discard runCli(repo, "unwritable-1")
    ck fileExists(publishedRecord(repo))

    # The record is REMOVED before the store is made read-only: an existing
    # file stays writable through a read-only parent directory, so leaving it
    # in place would test nothing. What is blocked here is the CREATE.
    removeFile(publishedRecord(repo))
    setFilePermissions(repo / CtTestStoreDir, {fpUserRead, fpUserExec})
    try:
      let (code, summary) = runCli(repo, "unwritable-2")
      let report = summary{"certificate"}
      checkpoint $report
      ck code == 0                    # the tests ran, and they passed
      ck report{"issued"}.getBool     # and the certificate is still issued
      ck report.hasKey("write_error")
      ck report{"write_error"}.getStr.len > 0
      ck not report.hasKey("written_to")
      ck not fileExists(publishedRecord(repo))
    finally:
      # Restored unconditionally, so the exit-time cleanup can remove the tree
      # even when an assertion above fails.
      setFilePermissions(repo / CtTestStoreDir,
                         {fpUserRead, fpUserWrite, fpUserExec})

echo "CHECKS: ", checksRun
