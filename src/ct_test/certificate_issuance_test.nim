## Issuance suite for `ct test` certificates.
##
## Covers the producer half of the CTC-1 verification list — a passing run
## issues a well-formed certificate, a failing run issues none, targets are
## sorted and deduplicated in the *signed* payload, commands keep execution
## order, no interface signs a caller-supplied record — and CTC-3d's: the
## certificate binds the CONTENT of the tracked files, computed before and
## after the run, so a modified working tree certifies, a commit of the tested
## content is covered with no second run, an edit during the run withholds,
## and the states with no content id are refused, each with its remedy.
##
## HOW A RUN IS PRODUCED HERE — read this before adding a case
## -----------------------------------------------------------
## Every run goes through the real ``runAndAttest``: real discovery response →
## real ``enumerateRunUnits`` → real worker pool → real event aggregation →
## real ``probeVcs`` against a real git repository, before and after the run.
## Only the leaf ``TestProvider.run`` is supplied by this file, exactly as a
## language adapter supplies one, and it decides what to do from the scope's
## selector so the workers stay stateless.
##
## **There is deliberately no helper that hands the issuance path a result.**
## An earlier version of this suite had one — a ``passingRun`` that called the
## then-exported ``recordUnitResult`` with fabricated "test finished, passed"
## events — and it was a working forgery of a signed certificate for tests that
## never ran, institutionalised in the test file, which is why nothing here
## noticed. If a new case seems to need such a helper, that is the signal that
## the API has regrown the hole, not that the helper should come back.
##
## MOCKING POLICY (CLAUDE.md requires every mock to be justified here)
## -------------------------------------------------------------------
## One seam, and it is narrow: the in-process fixture provider above. A
## fixture, not a mock of a collaborator: nothing inside the orchestration or
## the issuance path is stubbed out, and no toolchain is needed for the suite
## to be deterministic. Some fixture tests write files in the workspace while
## they run, which is how an edit during the run is produced deterministically.
##
## There is NO git seam any more. The VCS probe used to take an injectable
## runner, and that was a way for a caller to answer git itself and have the
## answer signed into ``base`` and ``untracked``. Every VCS case here uses real
## git: a corrupt index for git failing, and ``IssuanceOptions.
## gitCaptureLimit`` (which can only make an answer incomplete, never change
## it) for an answer cut at the capture bound.
##
## ENVIRONMENT
## -----------
## ``getTempDir()`` MUST NOT be inside a git repository, or the "not a
## repository" cases would find the enclosing one. The fixture helper checks
## that and fails with an actionable message rather than mis-asserting. Scratch
## directories are removed once the suite has run.

import std/[options, os, osproc, streams, strutils, times, unittest]

import contracts
import certificate
import certificate_content_id
import certificate_content_id_native
import certificate_issuance
import certificate_signature
import certificate_verification
import discovery
import run_orchestration

# ---------------------------------------------------------------------------
# In-process fixture provider
# ---------------------------------------------------------------------------

const
  FixtureProviderId = "fixture-cert"
  FixtureLanguage = "fixture"
  FixtureFramework = "inproc"

type FixtureOutcome = enum
  ## What the fixture provider reports for a unit. ``foSkip`` is the shape a
  ## real provider produces for rspec `pending`, a Playwright `skipped`, or a
  ## `@unittest.skip`; ``foSilent`` is a provider that finished no test at all.
  foPass = "pass"
  foFail = "fail"
  foSkip = "skip"
  foSilent = "silent"
  foForeign = "foreign"
    ## A finished PASS whose event ``testId`` names a unit the provider was
    ## never asked to run. Real providers routinely emit event ids that do not
    ## equal ``item.id``; this is the sharpest version of that.
  foEditTracked = "edit-tracked"
    ## A PASS from a test that appends a line to the tracked ``a.txt`` while
    ## it runs: an edit that lands during the run, deterministically.
  foEditAndRevert = "edit-and-revert"
    ## A PASS from a test that rewrites ``a.txt`` and then restores its bytes.
  foWriteIgnored = "write-ignored"
    ## A PASS from a test that writes ``build/output.log``, an ignored file.
  foRemoveTracked = "remove-tracked"
    ## A PASS from a test that deletes ``a.txt`` while it runs.
  foRemoveUntracked = "remove-untracked"
    ## A PASS from a test that deletes the untracked ``scratch.log`` while it
    ## runs: untracked files present when the run started and gone at its end.

const
  EditedDuringRun = "edited during the run\n"

proc fixtureInfo(): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    displayName: "In-process certificate fixture provider",
    version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      canRecordProject: false, canRecordFile: false, canRecordSingle: false,
      canCapturePerTestOutput: true, canMapTraceEntryPoints: false,
      emitsStructuredEvents: true))

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## The leaf a real language adapter would supply. The outcome is decoded from
  ## the selector so a worker needs no shared state; the event shape is what a
  ## provider returns after parsing its subprocess output.
  ##
  ## Note that the provider is HONEST in every arm, including ``foSkip``: it
  ## reports exactly what happened. Anything wrong that comes out of a skip is
  ## manufactured downstream, in the fold under test.
  # Decoded from the selector so the worker stays stateless, and DERIVED FROM
  # THE ENUM rather than restated as a chain of branches. `fixtureItem` builds
  # the selector as `… & "::" & $outcome`, so this is the exact inverse and a
  # new enum value is dispatched the moment it exists.
  #
  # The hand-written chain this replaces silently mapped anything it did not
  # recognise to `foPass`: `foForeign` was added without a branch, so the case
  # meant to exercise it exercised nothing and passed. An exhaustive `case`
  # would not have helped — the mapping runs string→enum, and a missing branch
  # is not a compile error in that direction. Only the red-before caught it.
  var outcome = foPass
  for value in FixtureOutcome:
    if scope.selector.endsWith("::" & $value):
      outcome = value
  result = ProviderResult[seq[TestEvent]](diagnostics: @[], value: @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekRunStarted,
              providerId: FixtureProviderId, runId: scope.testId)])
  # What the test does to the workspace while it runs.
  let tracked = scope.projectRoot / "a.txt"
  case outcome
  of foEditTracked:
    writeFile(tracked, readFile(tracked) & EditedDuringRun)
  of foEditAndRevert:
    let original = readFile(tracked)
    writeFile(tracked, original & EditedDuringRun)
    writeFile(tracked, original)
  of foRemoveTracked:
    removeFile(tracked)
  of foRemoveUntracked:
    removeFile(scope.projectRoot / "scratch.log")
  of foWriteIgnored:
    createDir(scope.projectRoot / "build")
    writeFile(scope.projectRoot / "build" / "output.log", "a test's output\n")
  else:
    discard
  if outcome == foSilent:
    # A provider that started and produced no finished test — a crashed
    # harness, a missing toolchain. It reports a diagnostic and no verdict.
    result.diagnostics = @[diagnostic(dsError, "fixture produced no result")]
    return
  let status =
    case outcome
    of foFail: tsFailed
    of foSkip: tsSkipped
    else: tsPassed
  # The id the provider puts on its OWN events. `foForeign` names a unit that
  # was never scheduled; every real provider's ids differ from `item.id` too,
  # just less dramatically.
  let eventTestId =
    if outcome == foForeign: "a-unit-that-was-never-scheduled"
    else: scope.testId
  result.value.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
    providerId: FixtureProviderId, runId: scope.testId, testId: eventTestId)
  result.value.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
    providerId: FixtureProviderId, runId: scope.testId,
    testId: eventTestId, status: some(status), durationMs: 1)
  result.value.add TestEvent(
    schemaVersion: TestEventSchemaVersion, kind: tekRunFinished,
    providerId: FixtureProviderId, runId: scope.testId)

proc fixtureRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo())
  provider.run = fixtureRun
  ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @[])])

proc fixtureItem(file, name: string; outcome = foPass): TestItem =
  let selector = file & "::" & name & "::" & $outcome
  TestItem(
    id: makeTestItemId(FixtureProviderId, FixtureLanguage, FixtureFramework,
                       file, selector),
    providerId: FixtureProviderId,
    language: FixtureLanguage,
    framework: FixtureFramework,
    name: name,
    kind: tikCase,
    file: file,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: selector,
    tags: @["fixture"],
    location: LocationProvenance(source: lskPattern,
      detail: "in-process fixture", confidence: lcHigh))

proc fixtureResponse(workspaceRoot: string; items: seq[TestItem]): DiscoverResponse =
  DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion,
    workspaceRoot: workspaceRoot,
    file: "",
    catalogs: @[TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: fixtureInfo(), items: items, diagnostics: @[])],
    diagnostics: @[])

const DefaultInvocation = @[@["ct", "test", "run", "--workspace", "."]]

proc attest(workspaceRoot: string;
            items: seq[TestItem];
            options: IssuanceOptions;
            invocations: seq[seq[string]] = DefaultInvocation): AttestedRunOutcome =
  ## Drive a whole run through the exported entry point. Note what is NOT here:
  ## no results are passed in, because ``runAndAttest`` produces them.
  var registry = fixtureRegistry()
  runAndAttest(registry, fixtureResponse(workspaceRoot, items),
               emptyPartition(), 1, invocations, options)

# ---------------------------------------------------------------------------
# Scratch fixtures
# ---------------------------------------------------------------------------

let scratchRoot = getTempDir() / "ct-test-cert-suite-" & $getCurrentProcessId()

proc run(cmd: string; args: openArray[string]; cwd: string): tuple[output: string; code: int] =
  ## Run a real command for fixture setup. ``std/osproc`` rather than the
  ## ct_test process bridge because this is scaffolding, not the code under
  ## test — the bridge is exercised by the code under test itself.
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

proc initRepo(dir: string) =
  ## A real git repository with deterministic identity, so `git commit` works
  ## on a machine with no global git config.
  discard run("git", ["init", "--initial-branch=main", "."], dir)
  discard run("git", ["config", "user.email", "ct-test@example.invalid"], dir)
  discard run("git", ["config", "user.name", "ct test suite"], dir)
  discard run("git", ["config", "commit.gpgsign", "false"], dir)

proc committedRepo(name: string): string =
  result = scratchDir(name)
  initRepo(result)
  writeFile(result / "a.txt", "content\n")
  discard run("git", ["add", "-A"], result)
  discard run("git", ["commit", "-m", "initial"], result)

proc headCommit(dir: string): string =
  run("git", ["rev-parse", "HEAD"], dir).output.strip()

proc headTree(dir: string): string =
  run("git", ["rev-parse", "HEAD^{tree}"], dir).output.strip()

proc git(dir: string; args: varargs[string]): string =
  ## A git command for fixture setup that must succeed.
  let (output, code) = run("git", args, dir)
  doAssert code == 0, "git " & args.join(" ") & " failed in " & dir & ":\n" &
                      output
  output.strip()

proc workingTreeId(dir: string;
                   algorithm = caGitTreeSha1): string =
  ## W, computed independently of the producer by the content-id recipe.
  let computed = computeContentId(nativeContentIdHost(), dir,
                                  workingTreeState(), algorithm)
  doAssert computed.outcome == cioComputed, computed.reason
  computed.id

proc commitOracle(repo, revision: string): ContentOracle =
  ## The content of ``revision`` — what a consumer evaluating that commit
  ## computes (Content-Id.md §5), here with CTC-3b's recipe.
  result = proc(algorithm: string; paths: seq[string]): ContentAnswer
      {.closure.} =
    let (known, parsed) = lookupAlgorithm(algorithm)
    if not known:
      return ContentAnswer(computed: false, reason: "unknown algorithm")
    let computed = computeContentId(nativeContentIdHost(), repo,
                                    commitState(revision), parsed, paths)
    if computed.outcome == cioComputed:
      ContentAnswer(computed: true, id: computed.id)
    else:
      ContentAnswer(computed: false, reason: computed.reason)

proc coverageOf(repo, document: string; revision = "HEAD"): VerificationReport =
  ## Does the certificate ``document`` cover ``revision``? Evaluated by the
  ## shipped verifier, against the content of that commit's tree, with no
  ## `ct test` run involved.
  let read = readCertificate(document)
  doAssert read.status == crsOk, read.detail
  verifyCertificates(
    EvaluatedState(repo: repo.lastPathPart,
                   content: commitOracle(repo, revision)),
    Requirement(frameworksImplemented: @[CtTestFramework],
                framework: CtTestFramework, targets: read.cert.targets,
                platforms: @[currentPlatform()]),
    [CandidateCertificate(name: "issued.toml", text: document)], KeyStore())

proc generateSigningKey(name: string): string =
  let dir = scratchDir(name)
  result = dir / "signing-key"
  let generated = run("ssh-keygen",
    ["-t", "ed25519", "-N", "", "-C", "ct-test suite", "-f", result], dir)
  doAssert generated.code == 0, generated.output

proc unsignedOptions(issuedAt = "2026-06-23T10:14:33Z"): IssuanceOptions =
  IssuanceOptions(issuer: "ct-test@suite", issuedAt: issuedAt)

const OneTest = @["tests/a_test.nim"]

proc passingItems(files: openArray[string] = OneTest): seq[TestItem] =
  result = @[]
  for i, file in files:
    result.add fixtureItem(file, "case" & $i, foPass)

proc removeScratchRoot() =
  ## Remove every scratch directory this run created. Called at module level
  ## once the suite has run — deliberately NOT from an exit hook.
  ## ``scratchRoot`` is a module-level ``let``: under ORC its destructor runs
  ## at the end of the module's top-level code, which is BEFORE exit hooks
  ## run, so an ``addExitProc`` closure reading it would be reading freed
  ## memory and handing whatever had reused it to ``removeDir``.
  try: removeDir(scratchRoot)
  except CatchableError: discard

# ---------------------------------------------------------------------------

suite "ct test certificate issuance":

  test "the temporary directory is outside any git repository":
    ## A precondition, asserted once and loudly. Inside a repository the
    ## "not a git repository" cases below would find the enclosing one and
    ## assert the opposite of what they mean.
    let probe = scratchDir("environment-check")
    let toplevel = run("git", ["rev-parse", "--show-toplevel"], probe)
    if toplevel.code == 0:
      echo "TMPDIR is inside a git repository (", toplevel.output.strip(), ")."
      echo "Set TMPDIR to a directory outside any repository and re-run."
    check toplevel.code != 0

  test "a passing run issues a well-formed certificate":
    let repo = committedRepo("passing")
    let outcome = attest(repo, passingItems(), unsignedOptions())
    check outcome.summary.passed == 1
    check outcome.summary.failed == 0

    let issuance = outcome.issuance
    checkpoint issuance.message & " / " & issuance.remedy
    check issuance.issued
    check issuance.reason == wrNone

    # Well-formed means: it reads back as a valid v1 record, and the canonical
    # payload reconstructed from the parsed fields is byte-identical to what
    # was written — the property Canonical-Payload.md §5 turns on.
    let read = readCertificate(issuance.document)
    checkpoint read.detail
    check read.status == crsOk
    check canonicalPayload(read.cert) == canonicalPayload(issuance.certificate)

    check read.cert.schema == CertificateSchema
    check read.cert.framework == CtTestFramework
    check read.cert.result == "passed"
    check read.cert.platform == currentPlatform()
    check read.cert.vcs.content == "git-tree-sha1:" & headTree(repo)
    check read.cert.vcs.base == headCommit(repo)
    check not read.cert.vcs.untracked
    check read.cert.targets == OneTest
    check read.cert.commands == DefaultInvocation
    # Unsigned is the default, and an unsigned certificate is well-formed
    # (Standard.md §6). The key is omitted entirely rather than emitted empty.
    check not read.cert.isSigned
    check "key_id" notin issuance.document

  test "a failing run issues none":
    let repo = committedRepo("failing")
    let outcome = attest(repo, @[
      fixtureItem("tests/a_test.nim", "ok", foPass),
      fixtureItem("tests/b_test.nim", "broken", foFail)],
      unsignedOptions())
    check outcome.summary.passed == 1
    check outcome.summary.failed == 1

    let issuance = outcome.issuance
    check not issuance.issued
    check issuance.reason == wrTestsFailed
    check issuance.document.len == 0
    check "did not pass" in issuance.message
    check issuance.remedy.len > 0
    check "passed" in issuance.remedy
    # A gate-1 withholding never touched git, and says so rather than looking
    # like a probe that ran and could not decide.
    check not issuance.vcs.probed

  test "a run whose every test was skipped issues none":
    ## A skipped test runs no assertion, so there is nothing for
    ## `result = "passed"` to be true about. The gate is "executed > 0 and
    ## failed == 0", and folding a skip into `executed` satisfied it: an
    ## all-skipped run issued a signed certificate claiming `passed`.
    ##
    ## This shape is not exotic and is not caller-induced — it comes out of the
    ## DEFAULT registry through the shipped CLI, and has been reproduced there:
    ## an all-`pending` rspec suite and an all-skipped `node --test` file both
    ## used to exit 0 and issue a certificate claiming the file as a covered
    ## target, because those two providers read only a subprocess exit code and
    ## both runners exit 0 for an all-skipped suite. `ruby_common.nim` now maps
    ## rspec `pending` to `tsSkipped` on its run path, `js_common.nim` maps
    ## node:test's TAP `# SKIP` / `# TODO`, and `js_playwright.nim` maps
    ## `skipped`; all three are honest in doing so, and this fold is what makes
    ## the honesty count for something.
    let repo = committedRepo("all-skipped")
    var options = unsignedOptions()
    options.signingKeyPath = generateSigningKey("all-skipped-key")
    options.keyId = "ct-test-suite-key"

    let outcome = attest(repo, @[
      fixtureItem("tests/a_test.rb", "pending one", foSkip),
      fixtureItem("tests/b_test.rb", "pending two", foSkip)], options)
    # The run itself reports the skips honestly: nothing passed, nothing failed.
    check outcome.summary.passed == 0
    check outcome.summary.failed == 0

    let issuance = outcome.issuance
    check not issuance.issued
    check issuance.reason == wrNoTestsExecuted
    check issuance.document.len == 0
    check issuance.certificate.signature.value.len == 0
    # The message has to name the skips, or "no tests executed" is baffling to
    # someone who just watched the suite report two of them.
    check "skipped" in issuance.message
    check "not evidence" in issuance.remedy
    check not issuance.vcs.probed

  test "a skipped test is never claimed as a covered target":
    ## The case that will actually happen: every real suite has skips. The
    ## run legitimately issues on the strength of the tests that ran — but a
    ## file whose only test was skipped executed nothing, and naming it in
    ## `targets` is a coverage claim Standard.md §8 forbids in as many words:
    ## *producers MUST NOT claim targets that did not run*.
    let repo = committedRepo("mixed-skip")
    let outcome = attest(repo, @[
      fixtureItem("spec/payments_spec.rb", "charges a card", foPass),
      fixtureItem("spec/audit_spec.rb", "writes an audit row", foSkip)],
      unsignedOptions())
    check outcome.summary.passed == 1
    check outcome.summary.failed == 0

    let issuance = outcome.issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.certificate.targets == @["spec/payments_spec.rb"]
    check "spec/audit_spec.rb" notin issuance.document
    check issuance.certificate.result == "passed"

    # A file with both a passing and a skipped test IS claimed — one of its
    # tests ran. The rule is about what executed, not about what was skipped.
    let both = attest(repo, @[
      fixtureItem("spec/payments_spec.rb", "charges a card", foPass),
      fixtureItem("spec/payments_spec.rb", "refunds", foSkip)],
      unsignedOptions()).issuance
    require both.issued
    check both.certificate.targets == @["spec/payments_spec.rb"]

  test "a unit whose provider finished no test is not claimed either":
    ## A provider that errored, or found no toolchain, reports a diagnostic and
    ## no verdict. Nothing ran there, so nothing is claimed — an honest partial
    ## claim rather than a silent gap (Standard.md §8: partial coverage is
    ## normal).
    let repo = committedRepo("silent-unit")
    let issuance = attest(repo, @[
      fixtureItem("tests/ok_test.nim", "runs", foPass),
      fixtureItem("tests/broken_test.nim", "never reports", foSilent)],
      unsignedOptions()).issuance
    require issuance.issued
    check issuance.certificate.targets == @["tests/ok_test.nim"]
    check "tests/broken_test.nim" notin issuance.document

  test "the claimed target is the scheduled unit's file, not an event's testId":
    ## Attribution runs through ``RunUnitOutcome.testId``, which
    ## ``run_orchestration.runUnitOutcome`` stamps with ``unit.item.id`` and
    ## never reads back out of an event. That indirection looks accidental
    ## reading ``runUnitOutcome`` cold, and it is load-bearing: every real
    ## provider's event ids differ from ``item.id`` — ``ruby_common`` takes
    ## ``testId`` from rspec's ``example{"id"}`` (``./spec/x_spec.rb[1:1]``),
    ## which can never equal ``makeTestItemId(...)`` — so requiring a match
    ## would attribute nothing at all, for anyone.
    let repo = committedRepo("foreign-test-id")
    let issuance = attest(repo, @[
      fixtureItem("tests/dispatched_test.rb", "reports someone else's id",
                  foForeign)], unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    # The file the runner DISPATCHED is claimed...
    check issuance.certificate.targets == @["tests/dispatched_test.rb"]
    # ...and the id the provider invented reaches the certificate nowhere.
    check "a-unit-that-was-never-scheduled" notin issuance.document

    # The sharper shape: a provider whose events name another unit cannot
    # reach across and add a target for a unit it was not given. Only the two
    # files actually dispatched are claimed, and the skipped one is still not.
    let reaching = attest(repo, @[
      fixtureItem("tests/dispatched_test.rb", "lies about its id", foForeign),
      fixtureItem("tests/other_test.rb", "runs honestly", foPass),
      fixtureItem("tests/pending_test.rb", "is skipped", foSkip)],
      unsignedOptions()).issuance
    require reaching.issued
    check reaching.certificate.targets ==
          @["tests/dispatched_test.rb", "tests/other_test.rb"]
    check "tests/pending_test.rb" notin reaching.document

  test "a test outside the workspace is not bound to the workspace's commit":
    ## `[certificate.vcs]` describes the repository at the workspace root, so
    ## naming a file that repository does not contain would be a record that is
    ## formally clean and substantively false — a real, passing test bound to a
    ## commit that says nothing about it. Declining to claim it is safe in the
    ## other direction.
    ##
    ## Discovery only ever produces workspace-relative paths, so this is
    ## unreachable through the CLI; it is guarded because an in-process caller
    ## can supply an absolute one.
    let repo = committedRepo("outside-workspace")
    let elsewhere = scratchDir("elsewhere")
    createDir(elsewhere / "tests")
    let outsideItem = fixtureItem(elsewhere / "tests" / "calc.test.js", "adds",
                                  foPass)
    let issuance = attest(repo, @[outsideItem], unsignedOptions()).issuance
    check not issuance.issued
    # The test really ran and really passed; there is simply no target this
    # repository can honestly claim, so there is nothing to certify.
    check issuance.reason == wrNoTargets

    # And alongside a test that IS in the workspace, only the latter is claimed.
    let mixed = attest(repo, @[
      outsideItem, fixtureItem("tests/inside_test.js", "adds", foPass)],
      unsignedOptions()).issuance
    require mixed.issued
    check mixed.certificate.targets == @["tests/inside_test.js"]
    check ".." notin mixed.document

  test "containment is decided after resolving the path, not by how it is spelled":
    ## The lexical test this replaced — `file == ".." or startsWith("../")` —
    ## asked how a path was *written*. Three shapes disagree with how it
    ## *resolves*, and one of them costs a legitimate test its target.
    let repo = committedRepo("containment")
    createDir(repo / "sub")
    createDir(repo / "tests")

    # (a) An interior `..` that ESCAPES the root. Spelled with no leading
    # "../", so the lexical test claimed it.
    let escaping = attest(repo, @[
      fixtureItem("sub/../../outside/tests/o.rb", "escapes", foPass)],
      unsignedOptions()).issuance
    check not escaping.issued
    check escaping.reason == wrNoTargets

    # (b) An interior `..` that resolves back INSIDE. Claimed either way — but
    # it must be claimed under its NORMALIZED name, or the same file reaches
    # `targets` under two spellings and deduplication cannot see they are one.
    let winding = attest(repo, @[
      fixtureItem("sub/../tests/t.rb", "winds", foPass),
      fixtureItem("tests/t.rb", "direct", foPass)], unsignedOptions()).issuance
    require winding.issued
    # Both units record the SAME normalized spelling — which is exactly what
    # lets the serializer's deduplication see they are one file. Unnormalized,
    # the payload would carry the file twice under two names.
    check winding.certificate.targets == @["tests/t.rb", "tests/t.rb"]
    check "targets = [\"tests/t.rb\"]\n" in winding.document
    check ".." notin winding.document

    # (c) A SYMLINKED workspace root, reached by an absolute path through the
    # real directory. The lexical test computed "../<real>/tests/o.rb" and
    # withheld — a real, passing test losing the target it earned.
    let linkedRoot = scratchRoot / "containment-link"
    removeFile(linkedRoot)
    createSymlink(repo, linkedRoot)
    let throughReal = attest(linkedRoot, @[
      fixtureItem(repo / "tests" / "t.rb", "through the real path", foPass)],
      unsignedOptions()).issuance
    checkpoint throughReal.message & " / " & throughReal.remedy
    require throughReal.issued
    check throughReal.certificate.targets == @["tests/t.rb"]

    # (d) The prefix boundary: a sibling directory sharing a name prefix with
    # the root is outside it, which a bare `startsWith` would accept.
    let sibling = scratchDir("containment-sibling")
    createDir(sibling / "tests")
    let siblingRun = attest(repo, @[
      fixtureItem(sibling / "tests" / "t.rb", "sibling", foPass)],
      unsignedOptions()).issuance
    check not siblingRun.issued
    check siblingRun.reason == wrNoTargets

  test "a run that executed nothing issues none":
    let repo = committedRepo("empty-run")
    let issuance = attest(repo, @[], unsignedOptions()).issuance
    check not issuance.issued
    check issuance.reason == wrNoTestsExecuted
    check issuance.remedy.len > 0
    check not issuance.vcs.probed

  test "a modified working tree certifies before any commit":
    ## Standard.md §3.2.2: the certificate binds the CONTENT of the tracked
    ## files, so modifications relative to HEAD are simply part of it. A
    ## tracked edit, an added (staged) file and a deleted file are all issued,
    ## with `base` naming HEAD for information only.
    let repo = committedRepo("modified")
    writeFile(repo / "b.txt", "second\n")
    writeFile(repo / "c.txt", "third\n")
    discard git(repo, "add", "b.txt", "c.txt")
    discard git(repo, "commit", "-m", "more files")
    let head = headCommit(repo)
    writeFile(repo / "a.txt", "modified\n")          # a tracked edit
    writeFile(repo / "new.txt", "added\n")           # an added file
    discard git(repo, "add", "new.txt")
    removeFile(repo / "c.txt")                       # a deleted file
    let expected = workingTreeId(repo)
    check expected != "git-tree-sha1:" & headTree(repo)

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.reason == wrNone
    check issuance.certificate.vcs.content == expected
    check issuance.vcs.content == expected
    check issuance.vcs.contentBefore == expected
    check issuance.certificate.vcs.base == head
    check not issuance.certificate.vcs.untracked
    check "base = \"" & head & "\"" in issuance.document
    # The withholding this replaces is gone from every corner of the report.
    for text in [issuance.message, issuance.remedy, issuance.document]:
      check "WorktreeDirty" notin text
      check "commit your changes" notin text
    check not compiles(wrWorktreeDirty)
    # The record is what was tested: a commit of exactly this content would
    # have this tree, which the next case proves through the verifier.
    let read = readCertificate(issuance.document)
    require read.status == crsOk
    check read.cert.vcs.content == expected

  test "a commit of the tested content is covered without a second run":
    ## The workflow Standard.md §3.2.2 recommends: test, then commit. The
    ## certificate issued on the modified tree covers the commit that records
    ## that content — evaluated by the shipped verifier against the content
    ## of `HEAD^{tree}`, with NO `ct test` run between the commit and the
    ## check.
    let repo = committedRepo("test-then-commit")
    writeFile(repo / "b.txt", "untouched\n")
    discard git(repo, "add", "b.txt")
    discard git(repo, "commit", "-m", "b")
    writeFile(repo / "a.txt", "first change\n")
    writeFile(repo / "b.txt", "second change\n")
    let tested = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint tested.message & " / " & tested.remedy
    require tested.issued
    let base = headCommit(repo)

    # Before the commit, HEAD is not what was tested.
    check coverageOf(repo, tested.document).outcome == ocNotCovered

    discard git(repo, "commit", "-a", "-m", "both changes")
    check headCommit(repo) != base
    check tested.certificate.vcs.content == "git-tree-sha1:" & headTree(repo)
    let covered = coverageOf(repo, tested.document)
    checkpoint covered.reason
    check covered.outcome == ocCovered
    # base names the commit the work started on, not the one covered — and
    # does not stop it being covered.
    check tested.certificate.vcs.base == base

    # CONTROL: an amended message records the same tree, so it is covered.
    discard git(repo, "commit", "--amend", "-m", "both changes, reworded")
    check coverageOf(repo, tested.document).outcome == ocCovered

    # CONTROL: committing only ONE of the two tested changes (partial
    # staging) records content that was never tested as a whole.
    let partial = committedRepo("test-then-partial-commit")
    writeFile(partial / "b.txt", "untouched\n")
    discard git(partial, "add", "b.txt")
    discard git(partial, "commit", "-m", "b")
    writeFile(partial / "a.txt", "first change\n")
    writeFile(partial / "b.txt", "second change\n")
    let partialRun = attest(partial, passingItems(), unsignedOptions()).issuance
    require partialRun.issued
    discard git(partial, "commit", "-m", "only a", "--", "a.txt")
    let partialReport = coverageOf(partial, partialRun.document)
    checkpoint partialReport.reason
    check partialReport.outcome == ocNotCovered
    check partialReport.rejected.len == 1
    # ...and committing the rest afterwards is covered again, still with no
    # second run.
    discard git(partial, "commit", "-a", "-m", "and b")
    check coverageOf(partial, partialRun.document).outcome == ocCovered

    # CONTROL: rebasing the tested commit onto a commit that changes ANOTHER
    # file gives a tree the tests never saw.
    let rebased = committedRepo("test-then-rebase")
    let start = headCommit(rebased)
    discard git(rebased, "checkout", "-q", "-b", "upstream")
    writeFile(rebased / "other.txt", "upstream work\n")
    discard git(rebased, "add", "other.txt")
    discard git(rebased, "commit", "-m", "upstream")
    discard git(rebased, "checkout", "-q", "main")
    check headCommit(rebased) == start
    writeFile(rebased / "a.txt", "my change\n")
    let rebasedRun = attest(rebased, passingItems(), unsignedOptions()).issuance
    require rebasedRun.issued
    discard git(rebased, "commit", "-a", "-m", "mine")
    check coverageOf(rebased, rebasedRun.document).outcome == ocCovered
    discard git(rebased, "rebase", "-q", "upstream")
    check coverageOf(rebased, rebasedRun.document).outcome == ocNotCovered

  test "an edit during the run withholds":
    ## Standard.md §3.2: the content id is computed before AND after the run,
    ## and a producer MUST NOT issue when they differ. The fixture test
    ## appends to the tracked `a.txt` while it runs.
    let repo = committedRepo("edit-during-run")
    writeFile(repo / ".gitignore", "build/\n")
    discard git(repo, "add", ".gitignore")
    discard git(repo, "commit", "-m", "ignore build output")
    let before = workingTreeId(repo)

    let outcome = attest(repo, @[
      fixtureItem("tests/a_test.nim", "edits a tracked file", foEditTracked)],
      unsignedOptions())
    # The test itself passed; only the claim is withheld.
    check outcome.summary.passed == 1
    let issuance = outcome.issuance
    checkpoint issuance.message & " / " & issuance.remedy
    check not issuance.issued
    check issuance.reason == wrContentChanged
    check issuance.document.len == 0
    check "changed while the tests ran" in issuance.message
    check before in issuance.message
    check "before `ct test`" in issuance.remedy
    # THE CONTROL that the after-id is taken AFTER the run rather than copied
    # from the before-id: the report carries both, the before-id is the state
    # the run started from, and the after-id is the edited state as it is now.
    check readFile(repo / "a.txt").endsWith(EditedDuringRun)
    check issuance.vcs.contentBefore == before
    check issuance.vcs.content == workingTreeId(repo)
    check issuance.vcs.content != before

    # The same test writing an IGNORED file changes no tracked content, and
    # issues.
    let ignored = committedRepo("ignored-write-during-run")
    writeFile(ignored / ".gitignore", "build/\n")
    discard git(ignored, "add", ".gitignore")
    discard git(ignored, "commit", "-m", "ignore build output")
    let ignoredRun = attest(ignored, @[
      fixtureItem("tests/a_test.nim", "writes build output", foWriteIgnored)],
      unsignedOptions()).issuance
    checkpoint ignoredRun.message & " / " & ignoredRun.remedy
    require ignoredRun.issued
    check fileExists(ignored / "build" / "output.log")
    check not ignoredRun.certificate.vcs.untracked
    check ignoredRun.certificate.vcs.content ==
          "git-tree-sha1:" & headTree(ignored)

    # An edit reverted before the run concludes leaves the content as it was:
    # the comparison is of content, not of whether anything was touched.
    let reverted = committedRepo("edit-and-revert-during-run")
    let revertedRun = attest(reverted, @[
      fixtureItem("tests/a_test.nim", "edits and restores", foEditAndRevert)],
      unsignedOptions()).issuance
    checkpoint revertedRun.message & " / " & revertedRun.remedy
    require revertedRun.issued
    check revertedRun.certificate.vcs.content ==
          "git-tree-sha1:" & headTree(reverted)

  test "states with no content id are refused":
    ## Content-Id.md §3: a producer MUST NOT issue when the index has unmerged
    ## entries, when git has been told not to look at a present file, or when
    ## a submodule has modified content. Each withholds with its own reason
    ## and a remedy naming the paths; each control (the condition cleared)
    ## issues.

    # Unmerged entries, from a real conflicting merge.
    let merge = committedRepo("refuse-unmerged")
    discard git(merge, "checkout", "-q", "-b", "theirs")
    writeFile(merge / "a.txt", "theirs\n")
    discard git(merge, "commit", "-q", "-a", "-m", "theirs")
    discard git(merge, "checkout", "-q", "main")
    writeFile(merge / "a.txt", "ours\n")
    discard git(merge, "commit", "-q", "-a", "-m", "ours")
    check run("git", ["merge", "-q", "theirs"], merge).code != 0
    let unmerged = attest(merge, passingItems(), unsignedOptions()).issuance
    checkpoint unmerged.message & " / " & unmerged.remedy
    check not unmerged.issued
    check unmerged.reason == wrUnmergedEntries
    check "unmerged" in unmerged.message
    check "a.txt" in unmerged.message
    check "resolve the merge" in unmerged.remedy
    check "a.txt" in unmerged.remedy
    check unmerged.vcs.noContentId.len == 1
    check unmerged.vcs.noContentId[0].condition == ncUnmergedEntries
    check unmerged.vcs.content.len == 0
    writeFile(merge / "a.txt", "resolved\n")
    discard git(merge, "add", "a.txt")
    check attest(merge, passingItems(), unsignedOptions()).issuance.issued

    # assume-unchanged on an edited file: git would hash the indexed bytes
    # while the tests read the edited ones.
    let assumed = committedRepo("refuse-assume-unchanged")
    discard git(assumed, "update-index", "--assume-unchanged", "a.txt")
    writeFile(assumed / "a.txt", "edited behind git's back\n")
    let hidden = attest(assumed, passingItems(), unsignedOptions()).issuance
    checkpoint hidden.message & " / " & hidden.remedy
    check not hidden.issued
    check hidden.reason == wrIndexHidesWorktree
    check "assume-unchanged" in hidden.message
    check "git update-index --no-assume-unchanged -- a.txt" in hidden.remedy
    discard git(assumed, "update-index", "--no-assume-unchanged", "a.txt")
    let cleared = attest(assumed, passingItems(), unsignedOptions()).issuance
    require cleared.issued
    check cleared.certificate.vcs.content == workingTreeId(assumed)
    check cleared.certificate.vcs.content != "git-tree-sha1:" & headTree(assumed)

    # skip-worktree with the file present.
    let skipped = committedRepo("refuse-skip-worktree")
    discard git(skipped, "update-index", "--skip-worktree", "a.txt")
    writeFile(skipped / "a.txt", "present and different\n")
    let skip = attest(skipped, passingItems(), unsignedOptions()).issuance
    checkpoint skip.message & " / " & skip.remedy
    check not skip.issued
    check skip.reason == wrIndexHidesWorktree
    check "skip-worktree" in skip.message
    check "git update-index --no-skip-worktree -- a.txt" in skip.remedy
    # The condition is refused when it held at the START of the run, even
    # if a test cleared it before the end: here the test deletes the file a
    # skip-worktree entry hid, so only the state before the run had no
    # content id. It is reported as that condition, not as a content change.
    let atStart = attest(skipped, @[
      fixtureItem("tests/a_test.nim", "removes a.txt", foRemoveTracked)],
      unsignedOptions()).issuance
    checkpoint atStart.message & " / " & atStart.remedy
    check not atStart.issued
    check atStart.reason == wrIndexHidesWorktree
    check "when the run started" in atStart.message
    check not fileExists(skipped / "a.txt")
    # Control: skip-worktree with the file ABSENT is a sparse checkout, which
    # has a content id (the indexed entry), and issues.
    let sparse = attest(skipped, passingItems(), unsignedOptions()).issuance
    checkpoint sparse.message & " / " & sparse.remedy
    require sparse.issued
    check sparse.certificate.vcs.content == "git-tree-sha1:" & headTree(skipped)

    # A submodule with an uncommitted edit.
    let dependency = committedRepo("refuse-submodule-dep")
    let parent = committedRepo("refuse-submodule")
    discard git(parent, "-c", "protocol.file.allow=always", "submodule", "add",
                "-q", dependency, "vendor/dep")
    discard git(parent, "commit", "-q", "-m", "add dependency")
    writeFile(parent / "vendor" / "dep" / "a.txt", "patched in place\n")
    let modified = attest(parent, passingItems(), unsignedOptions()).issuance
    checkpoint modified.message & " / " & modified.remedy
    check not modified.issued
    check modified.reason == wrSubmoduleModified
    check "vendor/dep" in modified.message
    check "commit or revert the changes inside the submodule" in modified.remedy
    check "git -C vendor/dep status" in modified.remedy
    discard git(parent / "vendor" / "dep", "checkout", "--", "a.txt")
    let reverted = attest(parent, passingItems(), unsignedOptions()).issuance
    checkpoint reverted.message & " / " & reverted.remedy
    require reverted.issued
    check reverted.certificate.vcs.content == "git-tree-sha1:" & headTree(parent)

    # None of the refusals is reported as "could not determine": each state
    # WAS determined, and has no content id.
    for refused in [unmerged, hidden, skip, modified]:
      check refused.vcs.probed
      check refused.vcs.determined
      check refused.vcs.noContentId.len > 0
      check refused.document.len == 0

  test "the first commit of a repository is certifiable":
    ## Standard.md §3.2.3: `base` is omitted, never emitted empty, when there
    ## is no commit to name — the first commit is certified on top of nothing.
    let repo = scratchDir("unborn-branch")
    initRepo(repo)
    writeFile(repo / "a.txt", "content\n")
    discard git(repo, "add", "a.txt")
    check run("git", ["rev-parse", "--verify", "-q", "HEAD"], repo).code != 0

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.vcs.base == ""
    check issuance.certificate.vcs.base == ""
    check "\nbase =" notin issuance.document
    check "base = \"\"" notin issuance.document
    check issuance.certificate.vcs.content == workingTreeId(repo)
    let read = readCertificate(issuance.document)
    check read.status == crsOk

    # And the first commit is covered by it, with no second run.
    discard git(repo, "commit", "-q", "-m", "first")
    check issuance.certificate.vcs.content == "git-tree-sha1:" & headTree(repo)
    check coverageOf(repo, issuance.document).outcome == ocCovered

  test "a SHA-256 repository issues git-tree-sha256":
    ## Content-Id.md §4: the algorithm follows the repository's object format.
    let repo = scratchDir("sha256-repo")
    discard git(repo, "init", "-q", "--object-format=sha256",
                "--initial-branch=main", ".")
    discard git(repo, "config", "user.email", "ct-test@example.invalid")
    discard git(repo, "config", "user.name", "ct test suite")
    discard git(repo, "config", "commit.gpgsign", "false")
    writeFile(repo / "a.txt", "content\n")
    discard git(repo, "add", "a.txt")
    discard git(repo, "commit", "-q", "-m", "initial")
    writeFile(repo / "a.txt", "modified\n")

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    let content = issuance.certificate.vcs.content
    check content.startsWith("git-tree-sha256:")
    check content.len == "git-tree-sha256:".len + 64
    check content == workingTreeId(repo, caGitTreeSha256)
    check issuance.certificate.vcs.base.len == 64

    discard git(repo, "commit", "-q", "-a", "-m", "modified")
    check content == "git-tree-sha256:" & headTree(repo)
    check coverageOf(repo, issuance.document).outcome == ocCovered

  test "a clean-tree run issues the content HEAD records":
    ## The record carries the content id of the tested files — on a clean
    ## tree exactly the tree HEAD records — and HEAD only as the
    ## informational `base`. Nothing in it names a commit as the binding.
    let repo = committedRepo("content-of-head")
    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.vcs.content == "git-tree-sha1:" & headTree(repo)
    check issuance.certificate.vcs.content == "git-tree-sha1:" & headTree(repo)
    check issuance.certificate.vcs.base == headCommit(repo)
    check issuance.certificate.vcs.paths.len == 0
    # The revised key order, and nothing of the earlier draft.
    let vcsTable = issuance.document.split("[certificate.vcs]\n")[1].split("\n\n")[0]
    check vcsTable == "repo = \"" & repo.lastPathPart & "\"\n" &
      "content = \"git-tree-sha1:" & headTree(repo) & "\"\n" &
      "untracked = false\n" &
      "base = \"" & headCommit(repo) & "\""
    for earlier in ["commit =", "clean =", "worktree"]:
      check earlier notin issuance.document

  test "untracked files are reported and are outside the content":
    ## Standard.md §3.2: `untracked` files are not part of `content`, and are
    ## reported honestly. An untracked scratch file yields untracked = true
    ## and the SAME content as the run without it, in the default untracked
    ## mode. (Withholding when a run is known to have READ an untracked file
    ## needs a read set, and this run path captures none: CTC-3g's cases
    ## below.)
    let repo = committedRepo("untracked")
    writeFile(repo / "a.txt", "a tracked edit\n")
    let without = attest(repo, passingItems(), unsignedOptions()).issuance
    require without.issued
    check not without.certificate.vcs.untracked

    writeFile(repo / "scratch.log", "not tracked\n")
    createDir(repo / "notes")
    writeFile(repo / "notes" / "todo.md", "not tracked either\n")
    let probe = probeVcs(repo)
    check probe.determined
    check probe.untracked
    check probe.content == without.certificate.vcs.content

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.certificate.vcs.untracked
    check "untracked = true" in issuance.document
    check issuance.certificate.vcs.content == without.certificate.vcs.content

    # An ignored file is neither content nor untracked.
    removeFile(repo / "scratch.log")
    removeDir(repo / "notes")
    writeFile(repo / ".git" / "info" / "exclude", "*.tmp\n")
    writeFile(repo / "cache.tmp", "ignored\n")
    let ignored = attest(repo, passingItems(), unsignedOptions()).issuance
    require ignored.issued
    check not ignored.certificate.vcs.untracked
    check ignored.certificate.vcs.content == without.certificate.vcs.content

  test "strict mode withholds on any untracked file in scope":
    ## CTC-3g, operator decision 5: `strict` withholds whenever an untracked,
    ## non-ignored file exists in scope (the whole repository), naming them,
    ## and needs no read set. An ignored file does not withhold; the default
    ## mode issues the same run with untracked = true.
    let repo = committedRepo("untracked-strict")
    writeFile(repo / "a.txt", "a tracked edit\n")
    var strict = unsignedOptions()
    strict.untrackedMode = umStrict

    # Control: with no untracked file, strict mode issues exactly what the
    # default does.
    let clean = attest(repo, passingItems(), strict).issuance
    checkpoint clean.message
    require clean.issued
    check not clean.certificate.vcs.untracked
    check clean.untracked.mode == umStrict
    check clean.untracked.offending.len == 0
    let content = clean.certificate.vcs.content
    check content == workingTreeId(repo)

    writeFile(repo / "scratch.log", "not tracked\n")
    createDir(repo / "notes")
    writeFile(repo / "notes" / "todo.md", "not tracked either\n")
    let withheld = attest(repo, passingItems(), strict).issuance
    check not withheld.issued
    check withheld.reason == wrUntrackedInput
    check withheld.document.len == 0
    # Named: the file, and the untracked directory as git lists it.
    check withheld.untracked.offending == @["notes/", "scratch.log"]
    check "scratch.log" in withheld.message
    check "notes/" in withheld.message
    check "strict" in withheld.message
    check "git add" in withheld.remedy
    check ".gitignore" in withheld.remedy
    # The evidence is still reported: the content, unchanged by the files.
    check withheld.vcs.determined
    check withheld.vcs.untracked
    check withheld.vcs.content == content
    check withheld.vcs.untrackedPaths == @["notes/", "scratch.log"]

    # The default mode issues the SAME state, reporting untracked = true.
    let default = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint default.message
    require default.issued
    check default.untracked.mode == umReads
    check default.certificate.vcs.untracked
    check default.certificate.vcs.content == content

    # An ignored file is neither content nor untracked, so strict issues.
    removeFile(repo / "scratch.log")
    removeDir(repo / "notes")
    writeFile(repo / ".git" / "info" / "exclude", "*.tmp\nbuild/\n")
    writeFile(repo / "cache.tmp", "ignored\n")
    createDir(repo / "build")
    writeFile(repo / "build" / "out.o", "ignored too\n")
    let ignored = attest(repo, passingItems(), strict).issuance
    checkpoint ignored.message
    require ignored.issued
    check not ignored.certificate.vcs.untracked
    check ignored.certificate.vcs.content == content

    # An untracked file present only when the run STARTED was present during
    # it: strict withholds for it too.
    writeFile(repo / "scratch.log", "removed by the test\n")
    let removed = attest(repo,
      @[fixtureItem("tests/a_test.nim", "case0", foRemoveUntracked)],
      strict).issuance
    check not fileExists(repo / "scratch.log")
    check not removed.issued
    check removed.reason == wrUntrackedInput
    check removed.untracked.offending == @["scratch.log"]

  test "the default mode issues with untracked reported when no read set was captured":
    ## CTC-3g: `test run` captures no read set, so in the default mode an
    ## untracked file cannot be judged. The run issues — never guessing which
    ## files were read — the record carries untracked = true, and the report
    ## says that no read set was captured.
    let repo = committedRepo("untracked-no-read-set")
    let without = attest(repo, passingItems(), unsignedOptions()).issuance
    require without.issued
    check not without.untracked.readSetCaptured
    # Nothing to judge, so nothing to say.
    check without.untracked.note.len == 0

    writeFile(repo / "fixture-input.txt", "untracked input\n")
    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message
    require issuance.issued
    check issuance.untracked.mode == umReads
    check not issuance.untracked.withhold
    check not issuance.untracked.readSetCaptured
    check issuance.untracked.offending.len == 0
    check "no read set was captured" in issuance.untracked.note
    check NoReadSetOnRunPath in issuance.untracked.note
    check "could not be judged" in issuance.untracked.note
    check issuance.certificate.vcs.untracked
    check "untracked = true" in issuance.document
    check issuance.vcs.untrackedPaths == @["fixture-input.txt"]
    # The untracked file is outside the content: the same id as without it.
    check issuance.certificate.vcs.content == without.certificate.vcs.content

  test "untracked files present only when the run started are reported":
    ## Standard.md §3.2: `untracked` says whether untracked files were present
    ## when the commands executed. A file present when the first test was
    ## dispatched was present while the run executed, even if a test deleted
    ## it before the last one concluded, so the record says `true` although
    ## the state after the run has none.
    let repo = committedRepo("untracked-removed-during-run")
    writeFile(repo / "scratch.log", "not tracked\n")
    check probeVcs(repo).untracked
    let issuance = attest(repo, @[
      fixtureItem("tests/a_test.nim", "removes scratch.log", foRemoveUntracked)],
      unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check not fileExists(repo / "scratch.log")
    check not probeVcs(repo).untracked
    check issuance.vcs.untracked
    check issuance.certificate.vcs.untracked
    check "untracked = true" in issuance.document
    check issuance.certificate.vcs.content == "git-tree-sha1:" & headTree(repo)

  test "a run does not rewrite the user's index":
    ## The probe reads the user's index through `git status`, which by
    ## default refreshes stale stat information and writes the index back.
    ## `GIT_OPTIONAL_LOCKS=0` turns that off: a run is read-only with respect
    ## to the index, byte for byte and by modification time.
    let repo = committedRepo("index-untouched")
    # Stale stat data with unchanged bytes: exactly what a refresh rewrites.
    setLastModificationTime(repo / "a.txt", fromUnix(1_600_000_000))
    let indexPath = repo / ".git" / "index"
    let bytesBefore = readFile(indexPath)
    let mtimeBefore = getLastModificationTime(indexPath)
    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check readFile(indexPath) == bytesBefore
    check getLastModificationTime(indexPath) == mtimeBefore
    # CONTROL: the same `git status` without the variable does rewrite it,
    # so the assertions above can fail.
    discard git(repo, "status", "--porcelain=v1")
    check readFile(indexPath) != bytesBefore

  test "a submodule with only untracked files is not refused":
    ## Content-Id.md §3 refuses a submodule with MODIFIED content. Untracked
    ## files inside a submodule change nothing its gitlink describes, so the
    ## run issues, with the content HEAD records.
    let dependency = committedRepo("submodule-untracked-dep")
    let parent = committedRepo("submodule-untracked")
    discard git(parent, "-c", "protocol.file.allow=always", "submodule", "add",
                "-q", dependency, "vendor/dep")
    discard git(parent, "commit", "-q", "-m", "add dependency")
    writeFile(parent / "vendor" / "dep" / "scratch.log", "untracked\n")
    let issuance = attest(parent, passingItems(), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.vcs.noContentId.len == 0
    check issuance.certificate.vcs.content == "git-tree-sha1:" & headTree(parent)

  test "a producer that cannot determine the repository state issues nothing":
    ## Standard.md §3.2: a producer MUST NOT issue a binding it did not
    ## establish, and if it cannot establish one it MUST NOT issue at all.
    ## Three ways of not being able to tell, each withholding, all against
    ## real git.
    let notARepo = scratchDir("not-a-repo")
    let outsideProbe = probeVcs(notARepo)
    check outsideProbe.probed
    check not outsideProbe.determined
    check "not inside a git repository" in outsideProbe.undeterminedReason
    let outside = attest(notARepo, passingItems(), unsignedOptions()).issuance
    check not outside.issued
    check outside.reason == wrVcsUndeterminable
    check "must not issue at all" in outside.remedy
    check "not inside a git repository" in outside.message

    # An answer cut at the capture bound is a PREFIX of the real one and is
    # indistinguishable from a complete short answer, so treating it as an
    # answer is precisely the guess the standard forbids. Many untracked
    # files make `git status` outgrow a small bound.
    let repo = committedRepo("undeterminable")
    for i in 0 ..< 40:
      writeFile(repo / ("untracked-file-with-a-long-name-" & $i & ".txt"), "x\n")
    var truncatedOptions = unsignedOptions()
    truncatedOptions.gitCaptureLimit = 512
    let truncated = attest(repo, passingItems(), truncatedOptions).issuance
    checkpoint truncated.message
    check not truncated.issued
    check truncated.reason == wrVcsUndeterminable
    check "capture bound" in truncated.message
    # The control: the same repository with the default bound issues.
    check attest(repo, passingItems(), unsignedOptions()).issuance.issued

    # A git that fails: a corrupt index makes every git call that reads it
    # exit non-zero.
    let broken = committedRepo("corrupt-index")
    writeFile(broken / ".git" / "index", "this is not an index\n")
    let failed = attest(broken, passingItems(), unsignedOptions()).issuance
    checkpoint failed.message
    check not failed.issued
    check failed.reason == wrVcsUndeterminable
    check "failed (exit" in failed.message

  test "targets are sorted and deduplicated in the signed payload":
    let repo = committedRepo("targets")
    var options = unsignedOptions()
    options.signingKeyPath = generateSigningKey("targets-key")
    options.keyId = "ct-test-suite-key"

    # Deliberately unsorted, with two cases in one file (a duplicate target),
    # and with one pair whose difference lies in an escapable character — the
    # case where sorting the escaped rendering and sorting the raw bytes
    # disagree.
    let issuance = attest(repo, @[
      fixtureItem("tests/z_test.nim", "one"),
      fixtureItem("tests/a_test.nim", "two"),
      fixtureItem("tests/z_test.nim", "three"),
      fixtureItem("tests/m\ttest.nim", "four"),
      fixtureItem("tests/m!test.nim", "five")], options).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    require issuance.issued
    check issuance.certificate.isSigned
    check issuance.certificate.signature.algorithm == SignatureAlgorithm

    let payload = canonicalPayload(issuance.certificate)
    check "targets = [\"tests/a_test.nim\", \"tests/m\\ttest.nim\", " &
          "\"tests/m!test.nim\", \"tests/z_test.nim\"]\n" in payload
    # The duplicate is gone: four distinct targets from five executed units.
    check payload.count("tests/z_test.nim") == 1

    # The signature is over THAT payload — the sorted, deduplicated one.
    let publicKey = readFile(options.signingKeyPath & ".pub").strip()
    let good = verifyDetachedSignature(
      payload, publicKey, issuance.certificate.signature.value)
    checkpoint good.detail
    check good.check == scValid

    # And not over a payload whose targets kept their run order, which is the
    # whole point of sorting: an identical claim must not depend on the order
    # the scheduler happened to produce.
    let unsortedPayload = payload.replace(
      "targets = [\"tests/a_test.nim\", \"tests/m\\ttest.nim\", " &
      "\"tests/m!test.nim\", \"tests/z_test.nim\"]",
      "targets = [\"tests/z_test.nim\", \"tests/a_test.nim\", " &
      "\"tests/m\\ttest.nim\", \"tests/m!test.nim\"]")
    check unsortedPayload != payload
    check verifyDetachedSignature(unsortedPayload, publicKey,
      issuance.certificate.signature.value).check == scInvalid

  test "commands are recorded in execution order":
    let repo = committedRepo("commands")
    let issuance = attest(repo, passingItems(), unsignedOptions(), @[
      @["ct", "test", "run", "--workspace", ".", "--file", "tests/a_test.nim"],
      @["ct", "test", "run", "--workspace", ".", "--file", "tests/b_test.nim"],
      @["ct", "test", "run", "--workspace", "."]]).issuance
    require issuance.issued

    let read = readCertificate(issuance.document)
    require read.status == crsOk
    check read.cert.commands.len == 3
    check read.cert.commands[0][^1] == "tests/a_test.nim"
    check read.cert.commands[1][^1] == "tests/b_test.nim"
    check read.cert.commands[2][^1] == "."

    # Order is part of the claim and is never sorted, unlike targets — the two
    # rules live side by side in Canonical-Payload.md §2 rule 7 and §3.
    let firstAt = issuance.document.find("tests/a_test.nim")
    let secondAt = issuance.document.find("tests/b_test.nim")
    check firstAt >= 0
    check secondAt > firstAt

  test "secret-looking argument values are redacted, keeping the command shape":
    ## Standard.md §3.3: producers SHOULD replace the value rather than remove
    ## the argument, so a reader can still see what shape the command had.
    check redactSecrets(["ct", "test", "--token", "hunter2", "--json"]) ==
          @["ct", "test", "--token", RedactedArgument, "--json"]
    check redactSecrets(["ct", "--api-key=abc123", "run"]) ==
          @["ct", "--api-key=" & RedactedArgument, "run"]
    check redactSecrets(["ct", "test", "--workspace", "/srv/repo"]) ==
          @["ct", "test", "--workspace", "/srv/repo"]
    # `--sign-key` names the private key that signs the very certificate the
    # argv is published in. `--key-id` is meant to be public — a consumer
    # resolves it against a key store — so it must survive.
    check redactSecrets(["ct", "test", "--sign-key", "/home/me/.ssh/ct",
                         "--key-id", "ct-2026-q3"]) ==
          @["ct", "test", "--sign-key", RedactedArgument,
            "--key-id", "ct-2026-q3"]
    check redactSecrets(["ct", "--signing-key=/home/me/.ssh/ct"]) ==
          @["ct", "--signing-key=" & RedactedArgument]

  test "a signed certificate does not publish the path of the key that signed it":
    let repo = committedRepo("no-key-leak")
    var options = unsignedOptions()
    options.signingKeyPath = generateSigningKey("leak-key")
    options.keyId = "ct-test-suite-key"
    let issuance = attest(repo, passingItems(), options, @[
      @["ct", "test", "run", "--workspace", ".",
        "--sign-key", options.signingKeyPath, "--key-id", "ct-test-suite-key"]
    ]).issuance
    require issuance.issued
    check options.signingKeyPath notin issuance.document
    check RedactedArgument in issuance.document
    # The key id is not a secret and stays legible, or nobody can check it.
    check "ct-test-suite-key" in issuance.document

  test "no interface signs a caller-supplied record":
    ## Standard.md §6.2 — the single rule that makes every `ct test`
    ## certificate worth anything. Enforced structurally, and asserted here at
    ## four levels.
    ##
    ## 1. COMPILE TIME, THE SIGNING ROUTINE. Private to
    ##    `certificate_issuance`, so no importer can name it. This `compiles`
    ##    check must stay false forever.
    check not compiles(signCanonicalPayload("payload", "/dev/null"))
    check not compiles(certificate_issuance.signCanonicalPayload("p", "/dev/null"))

    ## 2. COMPILE TIME, THE BUILDER. The record AND every one of its mutators
    ##    are private too. Private *fields* alone were not enough: an exported
    ##    mutator that fills a private field is a way to fill it, and the
    ##    earlier `recordUnitResult` took a caller-supplied event stream. The
    ##    block below is that forgery, verbatim — it produced a genuine,
    ##    `ssh-keygen -Y verify`-valid signature for a test that never ran.
    ##
    ##    A `compiles()` check is VACUOUSLY true whenever its expression fails
    ##    to compile for any reason at all, including a typo, so the positive
    ##    controls come first and prove this harness can still say `true` for
    ##    both an ordinary call and the block form.
    check compiles(probeVcs("/tmp"))
    check compiles((block:
      let probe = probeVcs("/tmp")
      probe.determined))
    check not compiles(AttestedRun())
    check not compiles(beginAttestedRun("/tmp", "project", "linux/amd64"))
    check not compiles((block:
      var forged = beginAttestedRun("/tmp", "project", "linux/amd64")
      forged.recordExecutedCommand(["ct", "test", "run", "--workspace", "."])
      forged.recordUnitResult("tests/never_ran_test.nim", @[TestEvent(
        schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
        testId: "never-ran", status: some(tsPassed))])
      forged.concludeAttestedRun()
      issueCertificate(forged, unsignedOptions())))

    ## 3. THE GATE. The one exported route runs the tests itself, so a
    ##    signature is a consequence of having executed them. A configured
    ##    signing key does not change that: a failing run gets nothing, and the
    ##    returned record carries no signature value at all.
    let repo = committedRepo("no-sign-blob")
    var options = unsignedOptions()
    options.signingKeyPath = generateSigningKey("no-sign-blob-key")
    options.keyId = "ct-test-suite-key"
    let refused = attest(repo, @[
      fixtureItem("tests/a_test.nim", "broken", foFail)],
      options).issuance
    check not refused.issued
    check refused.reason == wrTestsFailed
    check refused.document.len == 0
    check refused.certificate.signature.value.len == 0

    ## 4. THE SOURCE. Nothing outside the private routine invokes the signing
    ##    primitive, and the module that anyone may hand an arbitrary record to
    ##    cannot reach it at all. A source-level assertion rather than a
    ##    behavioural one, because the property being defended is "there is no
    ##    such symbol", which a behavioural test cannot observe.
    let sourceDir = currentSourcePath().parentDir
    var signingSites: seq[string] = @[]
    for kind, path in walkDir(sourceDir):
      if kind != pcFile or not path.endsWith(".nim"):
        continue
      if "-Y\", \"sign\"" in readFile(path):
        signingSites.add path.lastPathPart
    check signingSites == @["certificate_issuance.nim"]
    check "-Y\", \"sign\"" notin readFile(sourceDir / "certificate.nim")
    check "-Y\", \"sign\"" notin
          readFile(sourceDir / "certificate_verification.nim")

  test "no caller-supplied value reaches content, untracked or base":
    ## CTC-1's guarantee, extended to the content binding: the vcs field
    ## values are read out of real git inside `runAndAttest`, before and after
    ## the run, and a caller has no field, parameter or seam through which to
    ## supply them — nor a content-id host or git runner that would answer
    ## for git.
    ##
    ## Positive controls first, so a `compiles()` that is false for an
    ## unrelated reason cannot pass vacuously.
    check compiles(IssuanceOptions(issuer: "x", gitCaptureLimit: 1))
    check compiles(probeVcs("/tmp", 1))
    for field in ["content", "contentBefore", "untracked", "base", "repo",
                  "paths", "vcs", "probe", "before", "gitRunner", "host",
                  "contentHost", "contentId"]:
      checkpoint field
      var named = false
      for name, _ in IssuanceOptions().fieldPairs:
        if name == field:
          named = true
      check not named
    # The whole set of options is the reviewed one: each is a deployment
    # choice or can only make issuance fail.
    var optionNames: seq[string]
    for name, _ in IssuanceOptions().fieldPairs:
      optionNames.add name
    check optionNames == @["disabled", "issuer", "signingKeyPath", "keyId",
                           "issuedAt", "untrackedMode", "untrackedModeProblem",
                           "gitCaptureLimit"]
    # CTC-3g: the read set is the run's own. No option carries one, and the
    # one in a run record is private.
    check not compiles(IssuanceOptions(readSet: ReadSet(captured: true)))
    check not compiles((block:
      var forged = beginAttestedRun("/tmp", "project", "linux/amd64")
      forged.readSet = ReadSet(captured: true)
      forged))
    check not compiles(IssuanceOptions(gitRunner: nil))
    check not compiles(IssuanceOptions(content: "git-tree-sha1:00"))
    check not compiles(IssuanceOptions(base: "00"))
    check not compiles(IssuanceOptions(untracked: false))
    # No route accepts a probe, a content id or a host: `runAndAttest`'s six
    # parameters are the run's, and the before-state lives in the private
    # `AttestedRun`.
    var registry = fixtureRegistry()
    let response = fixtureResponse("/tmp", @[])
    check compiles(runAndAttest(registry, response, emptyPartition(), 1,
                                DefaultInvocation, unsignedOptions()))
    check not compiles(runAndAttest(registry, response, emptyPartition(), 1,
                                    DefaultInvocation, unsignedOptions(),
                                    VcsProbe(determined: true)))
    check not compiles(runAndAttest(registry, response, emptyPartition(), 1,
                                    DefaultInvocation, unsignedOptions(),
                                    nativeContentIdHost()))
    check not compiles((block:
      var forged = beginAttestedRun("/tmp", "project", "linux/amd64")
      forged.before = VcsProbe(determined: true, content: "git-tree-sha1:00")
      forged))

    # THE SOURCE: the issuance module computes content ids only through the
    # native host, and builds that host in exactly one place.
    let source = readFile(currentSourcePath().parentDir / "certificate_issuance.nim")
    check source.count("nativeContentIdHost(") == 1
    check source.count("computeContentId(") == 1
    check "gitRunner" notin source

    # BEHAVIOURALLY: what is issued is what real git says, field by field.
    let repo = committedRepo("no-caller-values")
    writeFile(repo / "a.txt", "edited\n")
    writeFile(repo / "scratch.txt", "untracked\n")
    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    require issuance.issued
    check issuance.certificate.vcs.content == workingTreeId(repo)
    check issuance.certificate.vcs.untracked
    check issuance.certificate.vcs.base == headCommit(repo)
    check issuance.certificate.vcs.repo == repo.lastPathPart

  test "the exported surface of the issuance module is the reviewed one":
    ## A companion to the case above, aimed at the change that would break it:
    ## someone adding a convenient exported helper that reaches the signing
    ## routine. Any new export fails here and has to be justified in this list,
    ## which is the review the rule deserves.
    ##
    ## `template` and `macro` are scanned alongside `proc`, and that is not
    ## hypothetical: a `proc`-only version of this guard stayed green while
    ## `template signAnyBlob*(payload, keyPath) = signCanonicalPayload(...)`
    ## handed another module the signing primitive with caller-supplied bytes.
    let source = readFile(currentSourcePath().parentDir / "certificate_issuance.nim")
    var exported: seq[string] = @[]
    for line in source.splitLines():
      var rest = ""
      for keyword in ["proc ", "func ", "template ", "macro ", "iterator ",
                      "converter ", "method "]:
        if line.startsWith(keyword):
          rest = line[keyword.len .. ^1]
          break
      if rest.len == 0:
        continue
      let star = rest.find('*')
      let paren = rest.find('(')
      if star < 0 or (paren >= 0 and star > paren):
        continue
      exported.add rest[0 ..< star]
    check exported == @[
      "currentPlatform",        # host os/arch; reads nothing, signs nothing
      "redactSecrets",          # pure string transformation
      # 2026-10-10 (CTC-3e): `defaultGitRunner` removed. It existed only for
      # the workspace store's `git check-ignore` report, which went with that
      # store; the local certificate store is outside the repository.
      "probeVcs",               # reads repository state
      # 2026-10-11 (CTC-3g): two pure helpers of the untracked-files rule.
      # Neither runs a test nor reaches the signing routine, and neither can
      # put a read set into a run: that field is private to `AttestedRun`.
      "readSetFromProjection",  # reads a capture's projection file
      "judgeUntracked",         # a decision over values
      "runAndAttest"]           # the ONLY route to a signature — and it runs
                                # the tests itself, so it takes no results

  test "attestation can be disabled without changing what ran":
    let repo = committedRepo("disabled")
    var options = unsignedOptions()
    options.disabled = true
    let outcome = attest(repo, passingItems(), options)
    check outcome.summary.passed == 1
    check not outcome.issuance.issued
    check outcome.issuance.reason == wrAttestationDisabled
    check outcome.issuance.remedy.len > 0
    check not outcome.issuance.vcs.probed

removeScratchRoot()
