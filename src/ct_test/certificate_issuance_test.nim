## Issuance suite for `ct test` certificates.
##
## Covers the producer half of the CTC-1 verification list: a passing run
## issues a well-formed certificate, a failing run issues none, a dirty tree is
## reported honestly, targets are sorted and deduplicated in the *signed*
## payload, commands keep execution order, no interface signs a caller-supplied
## record, and "commit, then re-run" reaches a clean-tree certificate without
## re-running any test.
##
## HOW A RUN IS PRODUCED HERE — read this before adding a case
## -----------------------------------------------------------
## Every run goes through the real ``runAndAttest``: real discovery response →
## real ``enumerateRunUnits`` → real worker pool → real event aggregation →
## real ``probeVcs`` against a real git repository. Only the leaf
## ``TestProvider.run`` is supplied by this file, exactly as a language adapter
## supplies one, and it decides pass/fail from the scope's selector so the
## workers stay stateless.
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
## Two seams, both narrow:
##
## * The in-process fixture provider above. A fixture, not a mock of a
##   collaborator: nothing inside the orchestration or the issuance path is
##   stubbed out, and no toolchain is needed for the suite to be deterministic.
##
## * ``IssuanceOptions.gitRunner``, and only for the two failure modes that
##   decide whether a certificate may be issued at all and cannot be produced
##   against a real repository at test speed: a ``git status`` whose output
##   exceeds the subprocess capture bound (the listing is then a prefix,
##   indistinguishable from a complete short answer, and accepting it is
##   exactly the guess Standard.md §3.2 forbids), and a ``git`` that exits
##   non-zero for an environmental reason. Both MUST withhold. Every other VCS
##   case uses real git through the default runner.
##
## ENVIRONMENT
## -----------
## ``getTempDir()`` MUST NOT be inside a git repository, or the "not a
## repository" cases would find the enclosing one. The fixture helper checks
## that and fails with an actionable message rather than mis-asserting. Scratch
## directories are removed on exit.

import std/[exitprocs, options, os, osproc, streams, strutils, tables,
            unittest]

import results
import contracts
import certificate
import certificate_issuance
import certificate_verification
import discovery
import process_exec
import run_orchestration
import incremental/engine
import incremental/catalog

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

addExitProc proc() =
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
    check read.cert.vcs.commit == headCommit(repo)
    check read.cert.vcs.clean
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

  test "a dirty tree yields clean = false, honestly reported":
    let repo = committedRepo("dirty")
    writeFile(repo / "a.txt", "modified\n")

    let probe = probeVcs(repo)
    checkpoint probe.undeterminedReason
    check probe.probed
    check probe.determined
    # Honesty first: the probe says clean = false rather than defaulting.
    check not probe.clean

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    check not issuance.issued
    check issuance.reason == wrWorktreeDirty
    # The withheld report still carries the truth it established.
    check issuance.vcs.probed
    check issuance.vcs.determined
    check not issuance.vcs.clean
    check "clean = false" in issuance.message
    # Actionable: the remedy is the workflow the standard recommends, and it
    # says why the second run is cheap (Standard.md §3.2.2).
    check "commit" in issuance.remedy
    check "re-runs nothing" in issuance.remedy

    # And the deferral is enforced, not merely intended: a `clean = false`
    # record with no worktree table has no canonical form at all, so the
    # dishonest certificate cannot even be rendered.
    let dishonest = TestCertificate(
      schema: CertificateSchema, framework: CtTestFramework, project: "example",
      platform: "linux/amd64", targets: @["t"], result: "passed",
      issuedAt: "2026-06-23T10:14:33Z", issuer: "ct-test",
      vcs: VcsState(repo: "example", commit: "abc", clean: false,
                    untracked: false, worktree: none(WorktreeClaim)),
      commands: @[@["ct", "test"]])
    expect CertificateError:
      discard canonicalPayload(dishonest)

  test "untracked files are reported separately from cleanliness":
    ## `clean` and `untracked` mean different things and both must be honest
    ## (Standard.md §3.2): untracked scratch work does not stop issuance, but
    ## it must not be silently reported as absent either.
    let repo = committedRepo("untracked")
    writeFile(repo / "scratch.log", "not tracked\n")

    let probe = probeVcs(repo)
    check probe.determined
    check probe.clean
    check probe.untracked

    let issuance = attest(repo, passingItems(), unsignedOptions()).issuance
    check issuance.issued
    check issuance.certificate.vcs.untracked
    check "untracked = true" in issuance.document

  test "a producer that cannot determine cleanliness issues nothing":
    ## Standard.md §3.2: a producer MUST NOT issue `clean = true` when it did
    ## not check, and if it cannot determine cleanliness it MUST NOT issue at
    ## all. Four ways of not being able to tell, each withholding.
    let notARepo = scratchDir("not-a-repo")
    let outsideProbe = probeVcs(notARepo)
    check outsideProbe.probed
    check not outsideProbe.determined
    check "not inside a git repository" in outsideProbe.undeterminedReason
    let outside = attest(notARepo, passingItems(), unsignedOptions()).issuance
    check not outside.issued
    check outside.reason == wrVcsUndeterminable
    check "must not issue at all" in outside.remedy

    let unborn = scratchDir("unborn-head")
    initRepo(unborn)
    writeFile(unborn / "a.txt", "content\n")
    let unbornProbe = probeVcs(unborn)
    check not unbornProbe.determined
    check "no commits yet" in unbornProbe.undeterminedReason
    check not attest(unborn, passingItems(), unsignedOptions()).issuance.issued

    # A truncated `git status` is a PREFIX of the real answer and is
    # indistinguishable from a complete short one, so treating it as an answer
    # is precisely the guess the standard forbids. See the mocking policy at
    # the top of this file for why this branch is reached through the seam.
    let repo = committedRepo("undeterminable")
    let truncatingGit = proc(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
      if argv.len > 1 and argv[1] == "status":
        CapturedRun(output: "", exitCode: 0, outputBytes: 1_000_000,
                    truncated: true)
      else:
        defaultGitRunner(argv, cwd)
    var truncatedOptions = unsignedOptions()
    truncatedOptions.gitRunner = truncatingGit
    let truncated = attest(repo, passingItems(), truncatedOptions).issuance
    check not truncated.issued
    check truncated.reason == wrVcsUndeterminable
    check "capture bound" in truncated.message

    let failingGit = proc(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
      if argv.len > 1 and argv[1] == "status":
        CapturedRun(output: "fatal: detected dubious ownership", exitCode: 128)
      else:
        defaultGitRunner(argv, cwd)
    var failingOptions = unsignedOptions()
    failingOptions.gitRunner = failingGit
    let failed = attest(repo, passingItems(), failingOptions).issuance
    check not failed.issued
    check failed.reason == wrVcsUndeterminable
    check "dubious ownership" in failed.message

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
      "defaultGitRunner",       # runs git; cannot sign
      "probeVcs",               # reads repository state
      "runAndAttest"]           # the ONLY route to a signature — and it runs
                                # the tests itself, so it takes no results

  test "re-running after a commit re-runs no tests and issues a clean-tree certificate":
    ## The workflow Standard.md §3.2.2 recommends, and the reason it is cheap:
    ## committing changes no file content, so a framework with content-based
    ## incremental testing finds every per-test hash unchanged and re-runs
    ## nothing. This exercises the real incremental engine and a real git
    ## repository together, because the claim is about how the two interact.
    let repo = committedRepo("commit-then-certify")
    createDir(repo / "src")
    let sourcePath = repo / "src" / "calc.nim"
    writeFile(sourcePath, "proc add(a, b: int): int = a + b\n")
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-m", "add calc"], repo)

    const testId = "tests/calc_test.nim::add"
    let cachePath = repo / ".ct-incremental" / "cache.json"

    proc contentHash(): string =
      ## Stands in for the catalog's compile-time deep hash, using the engine's
      ## own hasher over the real file. What matters for this case is the one
      ## property it shares with the real hash: it is derived from **file
      ## content** and from nothing else.
      deepHash(@[("add", readFile(sourcePath))])

    # First run: the tree is dirty — the file has been edited, not committed.
    writeFile(sourcePath,
              "proc add(a, b: int): int = a + b\nproc sub(a, b: int): int = a - b\n")
    var cache = initCache(cachePath)
    cache.recordBodyHash(testId, contentHash())
    let saved = saveCache(cache)
    checkpoint (if saved.isErr: saved.error else: "")
    require saved.isOk

    let beforeCommit = probeVcs(repo)
    check beforeCommit.determined
    check not beforeCommit.clean
    let withheldRun = attest(
      repo, passingItems(["tests/calc_test.nim"]), unsignedOptions()).issuance
    check not withheldRun.issued
    check withheldRun.reason == wrWorktreeDirty

    # Commit. No file content changes; only git's index and refs do.
    let contentBefore = readFile(sourcePath)
    let hashBefore = contentHash()
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-m", "add sub"], repo)
    check readFile(sourcePath) == contentBefore
    check contentHash() == hashBefore

    # The second run re-runs NOTHING: every per-test hash is unchanged.
    let reloaded = loadCache(cachePath)
    require reloaded.isOk
    var catalog = initBodyHashCatalog()
    catalog.entries[testId] = contentHash()
    let decision = decideByCatalog(testId, catalog, reloaded.get)
    checkpoint "decision after commit: " & $decision.kind
    check decision.kind == idSkipUnchanged
    check not isRerun(decision)

    # The skip is not vacuous: editing the file — which a commit does not do —
    # flips the same comparison to a re-run.
    writeFile(sourcePath, contentBefore & "proc mul(a, b: int): int = a * b\n")
    var editedCatalog = initBodyHashCatalog()
    editedCatalog.entries[testId] = contentHash()
    check isRerun(decideByCatalog(testId, editedCatalog, reloaded.get))
    writeFile(sourcePath, contentBefore)

    # And the certificate it can now issue is the clean-tree form.
    let afterCommit = probeVcs(repo)
    check afterCommit.determined
    check afterCommit.clean
    check afterCommit.commit == headCommit(repo)
    check afterCommit.commit != beforeCommit.commit

    let issuance = attest(
      repo, passingItems(["tests/calc_test.nim"]), unsignedOptions()).issuance
    checkpoint issuance.message & " / " & issuance.remedy
    check issuance.issued
    check issuance.certificate.vcs.clean
    check issuance.certificate.vcs.worktree.isNone
    check issuance.certificate.vcs.commit == headCommit(repo)

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
