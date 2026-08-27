## Issuing a test certificate from a `ct test` run.
##
## Implements the producer half of the vendor-neutral test-certificate
## standard (workspace sibling ``test-certificates-spec/``) for
## ``framework = "ct-test"``.
##
## ============================================================================
## THE RULE THIS MODULE EXISTS TO ENFORCE
## ============================================================================
##
## Standard.md §6.2, quoted in full because it is the single rule that makes a
## `ct test` certificate worth anything:
##
##   *A conforming producer MUST make a signature obtainable **only** as a
##   consequence of having actually executed the attested commands. It MUST NOT
##   expose any interface that signs a caller-supplied record.*
##
## The shape that satisfies it is narrow, and worth stating as a rule of thumb:
## **a routine that runs the tests does not take the results as arguments.**
## So there is exactly one exported route to a signature, ``runAndAttest``, and
## it *is* the run: it drives the worker pool itself and reads the outcome from
## the event streams the providers returned inside that call.
##
## What a caller supplies and what it cannot
## -----------------------------------------
##
## | Caller supplies | Derived inside the run, unforgeable by the caller |
## |---|---|
## | which tests to run (a ``DiscoverResponse``) | ``result`` — from ``tekTestFinished`` events the providers emitted, counting only tests that actually ran |
## | the partition allow-list, the thread count | ``platform`` — the host triple; a producer MUST NOT claim a platform it did not run on |
## | the ``argv`` it was invoked with | ``targets`` — the files of the units that actually ran a test, inside the workspace |
## | the issuer label and signing configuration | the ``[certificate.vcs]`` field values — read out of real git, never accepted as arguments |
##
## The last row wants one qualification, because an earlier version of this
## comment overstated it: the vcs *field values* are unforgeable, but the
## *choice of which repository is probed* is the caller's — ``probeVcs`` probes
## the workspace root it is handed. Through the CLI that is moot, since
## ``--workspace`` drives discovery and the probe alike.
##
## The private half is what keeps that table true:
##
## 1. ``signCanonicalPayload`` — the only routine in this repository that
##    produces a certificate signature — is **not exported**, so no importer
##    can name it. ``certificate_issuance_test.nim`` asserts that with a
##    ``compiles()`` check that must stay false.
##
## 2. ``AttestedRun`` and *all four* of its mutators are **not exported**
##    either. This is the correction to an earlier design in which they were:
##    private *fields* stop an importer naming a field, but they do not stop it
##    filling one through an exported mutator, and ``recordUnitResult`` took a
##    caller-supplied ``seq[TestEvent]``. A forger could therefore hand it
##    "test finished, passed" events for a test that never ran and receive a
##    genuine, ``ssh-keygen``-valid signature. The record and its mutators are
##    now reachable only from ``runAndAttest``, which fills them from
##    ``runUnits``' own output.
##
## 3. ``certificate.nim`` — which anyone may call with an arbitrary record,
##    because rendering a payload is a harmless and useful thing to do —
##    cannot sign at all, and nothing it imports can reach a signing primitive.
##
## The residual seam, stated plainly
## ---------------------------------
##
## A caller may install its own ``TestProvider`` in the registry, and a
## provider's ``run`` proc is by construction the thing that produces results.
## A caller that registers a provider reporting passes it never ran will get a
## certificate for them. That is not a "sign this blob" interface — it is the
## caller having *replaced the test framework* — and it is the same
## self-attestation question Verification.md §3.2 leaves to the deployment:
## how much a signature is worth depends on whether the tested code can reach
## the signing key, expressed through which keys a consumer registered. It is
## recorded here rather than papered over, because the previous version of this
## comment claimed a guarantee the code did not have.
##
## Two more things this does not stop, named so the claim is complete rather
## than merely confident: ``cast`` can reinterpret a layout-identical shadow
## object into an ``AttestedRun``, and anyone who can edit this file can do
## anything at all. Neither is an *interface the producer exposes* — the first
## is unsafe by construction and the second is not a boundary — but a
## guarantee that quietly omitted them would be overstating itself in the same
## way again.
##
## ============================================================================
## WHAT IS DELIBERATELY NOT HERE
## ============================================================================
##
## * **Path scoping** (``vcs.paths``, Standard.md §3.2.1). `ct test` is one of
##   the few frameworks that *could* bound its test input set, but the standard
##   forbids scoping unless the bound is trustworthy, and a scope excluding a
##   file the tests actually read yields a certificate that is formally clean
##   and substantively false. It gets its own milestone.
##
## * **The modified-worktree form** (``vcs.worktree``, Standard.md §3.2.2). The
##   standard's guidance is that the clean-tree certificate is the normal
##   output, and `ct test`'s incremental testing makes "run, commit, re-run"
##   nearly free — committing changes no file content, so the second run
##   re-runs nothing. Until the worktree form lands, a dirty tree is reported
##   **honestly** (``clean = false``) and the certificate is **withheld**,
##   because a ``clean = false`` record with no ``worktree`` table identifies
##   no state at all and MUST be rejected by any verifier.

import std/[options, os, strutils, tables, times]

import contracts
import certificate
import discovery
import process_exec
import run_orchestration
import workspace_scope

const
  CtTestFramework* = "ct-test"
    ## This producer's ``framework`` identifier. Two frameworks MUST NOT claim
    ## the same identifier, and identifiers are matched by exact string
    ## equality (Standard.md §4).

  RedactedArgument* = "[redacted]"
    ## Producers SHOULD redact values that would leak secrets, replacing the
    ## **value** rather than removing the argument so the shape of the command
    ## survives (Standard.md §3.3).

type
  GitCommandRunner* = proc(argv: seq[string]; cwd: string): CapturedRun {.closure, gcsafe.}
    ## How the VCS probe reaches git.
    ##
    ## Injectable so the failure modes that decide *whether a certificate may
    ## be issued at all* can be tested. Two of them cannot be produced against
    ## a real repository at test speed — a `git status` whose output exceeds
    ## the process capture bound, and a git that exits non-zero for an
    ## environmental reason — and both MUST withhold rather than guess. Every
    ## other case in the suite uses a real git repository in a temporary
    ## directory against the default runner.

  VcsProbe* = object
    ## What the producer could establish about the repository state.
    ##
    ## ``determined`` is the field the whole feature turns on. A producer MUST
    ## NOT issue ``clean = true`` when it did not check, and if it cannot
    ## determine cleanliness it MUST NOT issue a certificate at all
    ## (Standard.md §3.2) — a guess here invalidates everything downstream.
    ## So ``determined = false`` is never quietly converted into a default; it
    ## withholds.
    probed*: bool
      ## Whether the probe was *reached* at all. Distinct from ``determined``:
      ## a run that failed its own gate (no tests executed, tests failed) never
      ## touches git, and reporting that as "could not determine the repository
      ## state" would send an operator after a VCS problem that does not exist.
    determined*: bool
    undeterminedReason*: string
      ## Empty when ``determined``. Otherwise says what could not be
      ## established, in terms an operator can act on.
    repo*: string
    commit*: string
    clean*: bool
      ## ``true`` when no *tracked* file differed from ``commit``.
    untracked*: bool
      ## ``true`` when untracked files were present. Reported separately from
      ## ``clean`` because they mean different things: a modified tracked file
      ## means the tests ran against something other than ``commit``, while
      ## untracked files usually mean scratch work — but can mean a file the
      ## build picked up (Standard.md §3.2).

  WithheldReason* = enum
    ## Why a certificate was not issued. Every value except ``wrNone`` carries
    ## a message and a remedy, because "no certificate" with no explanation is
    ## the failure mode that makes a producer unusable.
    wrNone
    wrAttestationDisabled
    wrRunNotConcluded
    wrNoTestsExecuted
    wrTestsFailed
    wrNoTargets
    wrNoCommands
    wrVcsUndeterminable
    wrWorktreeDirty
    wrSigningFailed
    wrRecordNotRenderable

  Issuance* = object
    ## The outcome of asking a concluded run for a certificate.
    ##
    ## ``vcs`` is populated whether or not a certificate was issued, so a
    ## withheld run still reports the truth it established — in particular
    ## ``clean = false`` — rather than reporting nothing.
    issued*: bool
    certificate*: TestCertificate
    document*: string
      ## The rendered certificate. Empty when withheld.
    reason*: WithheldReason
    message*: string
      ## What happened. Empty when issued.
    remedy*: string
      ## What would make this run issuable. Empty when issued.
    vcs*: VcsProbe

  IssuanceOptions* = object
    ## Everything about issuance that is a deployment choice rather than a
    ## property of the run. Nothing here can make a false claim about
    ## *execution*: there is no field for the result, the platform or the
    ## targets.
    disabled*: bool
      ## Skip attestation entirely (`--no-certificate`). Reported as a
      ## withholding with its own reason so the summary never simply goes
      ## quiet.
    issuer*: string
      ## Free-form identification of the issuing component. Informational, and
      ## explicitly **not a trust input** (Standard.md §3.1).
    signingKeyPath*: string
      ## Path to an OpenSSH ed25519 private key. **Empty means unsigned, and
      ## unsigned is the default**: an unsigned certificate is well-formed
      ## (Standard.md §6), and it carries no protection against forgery, which
      ## a consumer that requires signatures must decide about for itself.
    keyId*: string
      ## Identifies the signing key to a consumer's key store. Required
      ## whenever ``signingKeyPath`` is set — a signed certificate a verifier
      ## cannot resolve a key for is a certificate nobody can check.
    issuedAt*: string
      ## Overrides the timestamp. Empty means "now, UTC, ``Z``". Present so a
      ## test can pin the payload bytes; production leaves it empty.
    gitRunner*: GitCommandRunner
      ## ``nil`` means the default runner.

  AttestedRunOutcome* = object
    ## Everything ``runAndAttest`` produced: the run, its summary, and the
    ## attestation (issued or withheld). The three travel together because the
    ## attestation is a *by-product* of the run and is meaningless apart from
    ## it.
    runResult*: TestRunResult
    summary*: TestRunSummary
    issuance*: Issuance

# ---------------------------------------------------------------------------
# Platform identification
# ---------------------------------------------------------------------------

proc currentPlatform*(): string =
  ## The platform the tests executed on, as ``os/arch`` (Standard.md §3.1).
  ##
  ## A certificate covers exactly the platform that ran the tests, and a
  ## producer MUST NOT claim a platform it did not run on (Standard.md §8) —
  ## so this reports the *host* triple, has no override, and is called by
  ## ``runAndAttest`` rather than passed in.
  let os =
    when defined(macosx): "macos"
    elif defined(windows): "windows"
    elif defined(linux): "linux"
    else: hostOS
  os & "/" & hostCPU

# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------

const secretMarkers = [
  "token", "secret", "password", "passwd", "apikey", "api-key", "api_key",
  "credential", "private-key", "private_key", "auth",
  # `--sign-key` names the certificate SIGNING key's path. It is not a secret
  # itself, but publishing it in every certificate the key signs hands a reader
  # the exact filesystem location of the private key — in a document whose
  # whole purpose is to be distributed. `key-id`, by contrast, is meant to be
  # public: a consumer resolves it against a key store, so it must survive.
  "sign-key", "sign_key", "signing-key", "signing_key", "keyfile", "key-file"]

proc looksSecret(flag: string): bool =
  let lowered = flag.toLowerAscii()
  for marker in secretMarkers:
    if marker in lowered:
      return true
  false

proc redactSecrets*(argv: openArray[string]): seq[string] =
  ## Replace values that would leak secrets with ``[redacted]``, keeping the
  ## argument itself so the shape of the command survives (Standard.md §3.3).
  ##
  ## Both spellings are handled: ``--token VALUE`` (the next element) and
  ## ``--token=VALUE`` (the tail of this one). The match is a substring test on
  ## a lowercased flag name, which over-redacts rather than under-redacts —
  ## the right direction to err in, since a redacted certificate is merely
  ## less informative while a leaked one is a disclosure.
  result = @[]
  var redactNext = false
  for arg in argv:
    if redactNext:
      result.add RedactedArgument
      redactNext = false
      continue
    if arg.startsWith("-"):
      let eq = arg.find('=')
      if eq > 0:
        if looksSecret(arg[0 ..< eq]):
          result.add arg[0 ..< eq] & "=" & RedactedArgument
        else:
          result.add arg
      else:
        result.add arg
        if looksSecret(arg):
          redactNext = true
    else:
      result.add arg

# ---------------------------------------------------------------------------
# The VCS probe
# ---------------------------------------------------------------------------

proc defaultGitRunner*(argv: seq[string]; cwd: string): CapturedRun {.gcsafe.} =
  ## Run git through the shared process bridge, so certificate issuance goes
  ## through the same launch/capture path as every other ct_test subprocess.
  execCaptured(argv, cwd = cwd)

proc undetermined(reason: string): VcsProbe =
  VcsProbe(probed: true, determined: false, undeterminedReason: reason)

proc probeVcs*(workspaceRoot: string;
               runner: GitCommandRunner = nil): VcsProbe =
  ## Establish ``repo``, ``commit``, ``clean`` and ``untracked`` for
  ## ``workspaceRoot`` — or report, precisely, that it could not.
  ##
  ## Every failure path here returns ``determined = false``. None of them
  ## returns a default: Standard.md §3.2 forbids issuing ``clean = true``
  ## without having checked, and the only safe behaviour when the check itself
  ## did not answer is to withhold.
  ##
  ## This always shells out to real git, and no caller-supplied value reaches
  ## ``[certificate.vcs]``: the commit and the cleanliness are read out of the
  ## repository, never accepted as arguments.
  ##
  ## Be precise about the scope of that, though — **the field values are
  ## unforgeable; the choice of which repository is probed is not.** This
  ## probes the ``workspaceRoot`` it is given, and an in-process caller picks
  ## that root. Through the CLI the question does not arise, because
  ## ``--workspace`` drives discovery and this probe alike, so the tests that
  ## ran and the repository that was probed are the same tree.
  let git = if runner == nil: GitCommandRunner(defaultGitRunner) else: runner

  let toplevel = git(@["git", "rev-parse", "--show-toplevel"], workspaceRoot)
  if toplevel.exitCode != 0:
    return undetermined(
      "'" & workspaceRoot & "' is not inside a git repository, so there is " &
      "no commit to attest and no way to establish whether the tree was clean")
  let repoRoot = toplevel.output.strip()
  if repoRoot.len == 0:
    return undetermined("git reported no repository root for '" & workspaceRoot & "'")

  let head = git(@["git", "rev-parse", "HEAD"], repoRoot)
  if head.exitCode != 0:
    return undetermined(
      "the repository at '" & repoRoot & "' has no commits yet, so there is " &
      "no commit the tested state can be expressed relative to")
  let commit = head.output.strip()
  if commit.len == 0:
    return undetermined("git reported an empty HEAD commit for '" & repoRoot & "'")

  # `--porcelain=v1` pins the output format across git versions; `-z` is
  # deliberately NOT used, because NUL-separated records make the truncation
  # check below harder to reason about and paths are only classified here, not
  # consumed.
  let status = git(
    @["git", "status", "--porcelain=v1", "--untracked-files=normal"], repoRoot)
  if status.exitCode != 0:
    return undetermined(
      "`git status` failed in '" & repoRoot & "' (exit " & $status.exitCode &
      "), so cleanliness could not be determined: " & status.output.strip())
  if status.timedOut:
    return undetermined(
      "`git status` timed out in '" & repoRoot &
      "', so cleanliness could not be determined")
  if status.truncated:
    # A truncated status listing is indistinguishable from a complete short
    # one, so treating it as an answer would be exactly the guess §3.2 forbids.
    return undetermined(
      "`git status` produced more output than the capture bound allows (" &
      $status.outputBytes & " bytes), so the listing is a prefix and " &
      "cleanliness could not be determined")

  result = VcsProbe(
    probed: true,
    determined: true,
    repo: repoRoot.lastPathPart,
    commit: commit,
    clean: true,
    untracked: false)
  for rawLine in status.output.splitLines():
    if rawLine.len < 2:
      continue
    if rawLine.startsWith("??"):
      result.untracked = true
    else:
      result.clean = false

# ---------------------------------------------------------------------------
# The attested run — PRIVATE from here down to `runAndAttest`
# ---------------------------------------------------------------------------

type
  AttestedRun = object
    ## Evidence that a run happened, accumulated as it happens.
    ##
    ## **Neither the type nor any of its mutators is exported.** Making only
    ## the *fields* private was not enough and is the defect this design
    ## replaces: an exported mutator that fills a private field is a way to
    ## fill it, and ``recordUnitResult`` accepted a caller-supplied event
    ## stream. Nothing outside this module can now construct, populate or
    ## conclude one, so the only way an ``AttestedRun`` reaches
    ## ``issueCertificate`` is the path ``runAndAttest`` walks.
    workspaceRoot: string
    project: string
    platform: string
    commands: seq[seq[string]]
    targets: seq[string]
    executed: int
      ## Tests that actually RAN — passed, failed or errored. A skipped test is
      ## not one of them; see ``recordUnitResult``.
      ##
      ## ``run_orchestration.summarize`` derives ``TestRunSummary.executed`` by
      ## the identical rule, and ``runVerdict`` refuses to exit 0 when it is
      ## zero. That is not duplication for its own sake — this counter must
      ## stay derived from the events *inside* ``runAndAttest`` (§6.2: a
      ## producer must not accept a caller-supplied result), so it cannot read
      ## the summary. What it must do is agree with it, and it does: the two
      ## used to differ, and the run that exposed it exited 0 while withholding
      ## for ``wrNoTestsExecuted``.
    passed: int
    failed: int
    skipped: int
      ## Counted only so the withheld message can say *why* nothing executed.
      ## It is never evidence.
    concluded: bool

proc beginAttestedRun(workspaceRoot, project, platform: string): AttestedRun =
  AttestedRun(
    workspaceRoot: workspaceRoot,
    project: project,
    platform: platform,
    commands: @[],
    targets: @[],
    concluded: false)

proc recordExecutedCommand(run: var AttestedRun; argv: openArray[string]) =
  ## Append a command **as executed**, in execution order.
  ##
  ## Producers MUST record what was actually run, not a normalised or idealised
  ## form (Standard.md §3.3); the only transformation applied is secret
  ## redaction, which the same section asks for. Order is part of the claim and
  ## is never sorted (Canonical-Payload.md §2 rule 6).
  if argv.len == 0:
    return
  run.commands.add redactSecrets(argv)

proc recordUnitResult(run: var AttestedRun; target: string;
                      events: openArray[TestEvent]) =
  ## Fold one executed unit's event stream into the run record.
  ##
  ## The events arrive from ``runUnits`` inside ``runAndAttest`` — never from
  ## an importer, which is the whole reason this is private. The counters are
  ## derived here from ``tekTestFinished`` events rather than accepted from a
  ## summary, so the gate in ``issueCertificate`` is standing on the providers'
  ## own output.
  ##
  ## **A SKIPPED TEST IS NOT EVIDENCE**, and this is the one place that has to
  ## know it. A skip means the provider honestly reported that no assertion
  ## ran — rspec `pending`, a Playwright `skipped`, a `@unittest.skip`. Folding
  ## it in as a finished test was a false claim manufactured *here*, not by any
  ## provider: the gate in ``issueCertificate`` is "executed > 0 and failed
  ## == 0", which a skip satisfies, so an all-skipped run issued
  ## ``result = "passed"`` and a mixed run added the skipped file to
  ## ``targets`` — a coverage claim for a file that executed nothing, which
  ## Standard.md §8 forbids in as many words: *producers MUST NOT claim targets
  ## that did not run*.
  ##
  ## So a skip contributes **nothing**: it does not mark the unit as having
  ## run, does not reach ``executed``, and above all does not add the unit's
  ## target. It is counted separately only so the withheld message can explain
  ## an otherwise baffling "no tests executed" to someone who just watched a
  ## suite report skips.
  ##
  ## **THE GUARANTEE IS ONLY AS FINE-GRAINED AS THE PROVIDER'S REPORTING**, and
  ## saying otherwise would overstate it. This fold refuses every ``tsSkipped``
  ## it is given; whether it is *given* one is the provider's decision, and
  ## **three shipped providers report skips per test on their run path**:
  ##
  ## * ``js-playwright`` — ``js_playwright.nim:497`` sets
  ##   ``provider.run = runPlaywright``; ``:431`` builds the command with
  ##   ``--reporter=json`` (``:84``) and parses it through
  ##   ``parsePlaywrightResultsJson`` → ``collectResultEvents`` (``:305``) →
  ##   ``statusFromPlaywright`` (``:258``), mapping ``"skipped"`` (``:263``).
  ## * ``ruby-rspec`` — ``ruby_rspec.nim:121`` sets
  ##   ``provider.run = runRubyCommand(…, rfkRSpec, …)``, which asks for
  ##   ``--format json --out <path>`` (``ruby_common.buildRubyCommand``) and
  ##   decides status in ``parseRspecJsonResults`` → ``statusFromRspec``,
  ##   mapping rspec's ``pending``. rspec exits 0 when every example is
  ##   pending, so this had to stop being an exit-code decision before an
  ##   all-pending suite could report anything but a pass.
  ## * ``js-node-test`` — ``js_node_test.nim:126`` sets
  ##   ``provider.run = runNodeTestCommand``, which parses node's TAP stream in
  ##   ``js_common.parseNodeTapResults``. ``node --test`` with every test
  ##   skipped prints ``# pass 0 / # skipped 2`` and **exits 0**, so the same
  ##   argument applies.
  ##
  ## The remaining providers still derive a whole file's status from a single
  ## subprocess **exit code**, and a skip is invisible to them: ``cpp_common``
  ## (cpp-gtest, cpp-catch2, cpp-ctest), ``native_m11_common`` (go-test,
  ## d-unittest, crystal-spec), ``m12_fallback_common`` (pascal, fortran, ada,
  ## odin, v, lean, julia, assembly), ``smart_contract_common`` (the M13
  ## harnesses), and ``ruby_common``'s minitest branch — minitest has no
  ## machine-readable reporter in the sense rspec's ``--format json`` is one,
  ## so it shares ``runRubyCommand``'s exit-code fallback rather than its JSON
  ## path. For those, a certificate can still name a file in which nothing ran.
  ## Closing it needs per-test reporting in each provider, not a change here.
  ##
  ## The registry's other providers are not on that list and are not a gap
  ## either, because they never report a finished test at all: ``js-jest`` and
  ## ``js-vitest`` wire ``provider.run`` to ``js_common.unsupportedRun``, and
  ## ``python-pytest``, ``python-unittest``, ``nim-unittest`` and
  ## ``rust-libtest`` wire it to their own not-implemented stub. All of them
  ## return a diagnostic and an empty event seq, so this fold sees no
  ## ``tekTestFinished`` and claims no target for them.
  ##
  ## **Do not check this with a grep for ``tsSkipped``.** A token search answers
  ## "which files mention it", not "which providers can emit it from ``run``" —
  ## which is how an earlier version of this comment came to claim rspec while
  ## the mapping it pointed at was on no run path at all. Follow
  ## ``provider.run`` to the proc that decides status.
  ##
  ## **A target is attributed to the SCHEDULED unit, never to an event's
  ## ``testId``, and that indirection is deliberate rather than incidental.**
  ## ``run_orchestration.runUnitOutcome`` stamps ``RunUnitOutcome.testId`` with
  ## ``unit.item.id`` and never reads it back out of an event, so the file this
  ## claims is the file the runner dispatched. Events carry the *provider's
  ## own* naming: ``ruby_common`` takes ``testId`` from rspec's
  ## ``example{"id"}`` (``./spec/x_spec.rb[1:1]``), which can never equal
  ## ``makeTestItemId(...)``. Requiring the two to match would therefore
  ## attribute nothing at all for every real provider — the rule has to be
  ## "what we asked it to run", not "what it says it ran".
  ##
  ## The consequence worth being explicit about: a provider whose events name a
  ## *different* unit still gets only its own dispatched file claimed. It
  ## cannot reach across and add a target for a unit it was not given. What it
  ## can do is lie about its own file, which is the caller-registered-provider
  ## seam in the module header and not something this fold can adjudicate.
  ##
  ## The three statuses that DO count all mean a test genuinely ran:
  ## ``tsPassed``, ``tsFailed`` and ``tsErrored`` (which started and blew up,
  ## and lands in ``failed``, so it withholds). ``tekTestFinished`` carrying no
  ## status, and every other event kind, are ignored — a unit whose provider
  ## produced no finished test at all therefore contributes no target, which is
  ## an honest partial claim rather than a silent gap (Standard.md §8:
  ## partial coverage is normal).
  var ran = false
  for event in events:
    if event.kind != tekTestFinished:
      continue
    if event.status.isNone:
      continue
    case event.status.get
    of tsPassed:
      ran = true
      inc run.executed
      inc run.passed
    of tsFailed, tsErrored:
      ran = true
      inc run.executed
      inc run.failed
    of tsSkipped:
      inc run.skipped
  if ran and target.len > 0:
    run.targets.add target

proc concludeAttestedRun(run: var AttestedRun) =
  run.concluded = true

# ---------------------------------------------------------------------------
# Signing — PRIVATE, and the module header explains why
# ---------------------------------------------------------------------------

proc signCanonicalPayload(payload, keyPath: string):
    tuple[ok: bool; value: string; error: string] =
  ## Produce a detached OpenSSH ed25519 signature over ``payload`` under the
  ## ``test-certificate-v1`` namespace (Standard.md §6.1).
  ##
  ## **NOT EXPORTED, AND MUST NEVER BE — nor wrapped by any exported ``proc``,
  ## ``template`` or ``macro``.** This is the only routine in CodeTracer that
  ## produces a certificate signature. Exposing it, by any of those three
  ## spellings, would be precisely the "sign this blob" interface
  ## Standard.md §6.2 forbids and would make every certificate this producer
  ## has ever issued worthless. Its single call site is ``issueCertificate``,
  ## below, past the gate that requires a concluded, fully-passing run.
  ##
  ## Domain separation is not optional: without the namespace, a signature a
  ## developer obtained for another purpose (OpenSSH uses ``git`` for commit
  ## and tag signing) replays as a certificate signature over identical bytes.
  let workDir = getTempDir() / "ct-test-cert-" & $getCurrentProcessId() &
                "-" & $epochTime()
  try:
    createDir(workDir)
  except OSError as err:
    return (false, "", "could not create a signing work directory: " & err.msg)
  defer:
    try: removeDir(workDir)
    except OSError: discard

  let payloadPath = workDir / "payload"
  try:
    writeFile(payloadPath, payload)
  except IOError as err:
    return (false, "", "could not stage the payload for signing: " & err.msg)

  # `ssh-keygen -Y sign` writes `<file>.sig` beside its input.
  let signRun = execCaptured(@[
    "ssh-keygen", "-Y", "sign", "-f", keyPath, "-n", SignatureNamespace,
    payloadPath], cwd = workDir)
  if signRun.exitCode != 0:
    return (false, "", "ssh-keygen -Y sign failed (exit " &
            $signRun.exitCode & "): " & signRun.output.strip())

  var armored: string
  try:
    armored = readFile(payloadPath & ".sig")
  except IOError as err:
    return (false, "", "ssh-keygen produced no signature file: " & err.msg)

  # The field carries the raw blob, base64, on one line; ssh-keygen writes the
  # armored PEM-like form. Converting between the two is pure framing
  # (Standard.md §6.1).
  var body = ""
  for line in armored.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    if trimmed.startsWith("-----"): continue
    body.add trimmed
  if body.len == 0:
    return (false, "", "ssh-keygen produced an empty signature")
  (true, body, "")

# ---------------------------------------------------------------------------
# Issuance — PRIVATE; reachable only from `runAndAttest`
# ---------------------------------------------------------------------------

proc withheld(reason: WithheldReason; message, remedy: string;
              vcs: VcsProbe): Issuance =
  Issuance(issued: false, reason: reason, message: message, remedy: remedy,
           vcs: vcs)

proc utcNowZ(): string =
  ## RFC 3339, UTC, in the ``Z`` spelling.
  ##
  ## The same instant spells as both ``Z`` and ``+00:00``; those are different
  ## bytes and therefore different signatures, and the standard requires ``Z``
  ## (Canonical-Payload.md §2 rule 10).
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc issueCertificate(run: AttestedRun; options: IssuanceOptions): Issuance =
  ## Issue a certificate for a concluded run — or withhold one, saying why and
  ## what would make it issuable.
  ##
  ## **The tests still ran.** Withholding an attestation is not a test failure
  ## and never changes a run's exit code; it means the producer will not claim
  ## something it could not establish (Standard.md §3.2).
  ##
  ## Private, and takes a type nothing outside this module can build, so the
  ## signature below is reachable only from ``runAndAttest``.
  if not run.concluded:
    return withheld(wrRunNotConcluded,
      "the run was not concluded, so there is nothing to attest",
      "conclude the run before asking for a certificate; this is a programming " &
      "error rather than an operator one",
      VcsProbe())

  # ---- Gate 1: the run itself -------------------------------------------
  # A certificate says "these commands ran and passed". Every branch below is
  # a case where that sentence would be false. None of them probes git, and
  # the returned `VcsProbe` says so (`probed = false`) rather than looking like
  # a probe that ran and failed.
  if run.executed == 0:
    # THE ALL-SKIPPED RUN IS WITHHELD, DELIBERATELY. A suite whose every test
    # was skipped ran no assertion, so there is nothing for `result = "passed"`
    # to be true about — and `wrNoTestsExecuted`'s own wording is already the
    # honest answer: a certificate covering nothing supports no claim. The
    # alternative, issuing with an empty `targets`, is not even expressible:
    # `targets = []` is not a payload this standard defines
    # (Canonical-Payload.md §3).
    #
    # The message distinguishes the two ways of executing nothing, because
    # "no tests executed" is baffling to someone who just watched a suite
    # report skips and would send them looking for a discovery bug.
    if run.skipped > 0:
      return withheld(wrNoTestsExecuted,
        "no test executed: all " & $run.skipped &
        " that finished were skipped, so the run attests nothing",
        "a skipped test runs no assertion and is not evidence, so it can " &
        "neither be counted nor claimed as a covered target; un-skip at " &
        "least one test, or narrow the run to a suite that actually executes",
        VcsProbe())
    return withheld(wrNoTestsExecuted,
      "no tests executed, so the run attests nothing",
      "check the workspace and any --partition allow-list: a certificate " &
      "covering nothing supports no claim",
      VcsProbe())
  if run.failed > 0:
    return withheld(wrTestsFailed,
      $run.failed & " of " & $run.executed & " executed tests did not pass",
      "fix the failing tests and re-run; `result = \"passed\"` is the only " &
      "value that supports a positive claim",
      VcsProbe())
  if run.targets.len == 0:
    return withheld(wrNoTargets,
      "the run produced no identifiable targets",
      "a certificate covering no target supports no claim; this usually means " &
      "the discovered tests carried no file to attribute coverage to",
      VcsProbe())
  if run.commands.len == 0:
    return withheld(wrNoCommands,
      "no command was recorded for the run",
      "a certificate recording no command asserts nothing; this is a " &
      "programming error in the run path rather than an operator one",
      VcsProbe())

  # ---- Gate 2: the VCS binding ------------------------------------------
  # The commit is the whole binding: a certificate that names a commit and
  # attests the tree was clean has transitively bound every committed input the
  # framework depends on (Standard.md §2).
  let vcs = probeVcs(run.workspaceRoot, options.gitRunner)
  if not vcs.determined:
    return withheld(wrVcsUndeterminable,
      "the repository state could not be determined: " & vcs.undeterminedReason,
      "run the tests inside a git repository that has at least one commit, " &
      "with `git status` working; a producer that cannot determine " &
      "cleanliness must not issue at all, because a wrong `clean` invalidates " &
      "everything downstream",
      vcs)
  if not vcs.clean:
    # Reported honestly — `vcs.clean` is false in the returned probe — and
    # withheld, because the modified-worktree form that would be REQUIRED to
    # accompany `clean = false` is deferred (see the module header).
    return withheld(wrWorktreeDirty,
      "tracked files differ from " & vcs.commit &
      ", so the tests did not run against that commit (clean = false)",
      "commit your changes and run `ct test` again: committing changes no " &
      "file content, so the incremental runner re-runs nothing and the " &
      "second run is a hash comparison rather than a second suite",
      vcs)

  # ---- The record --------------------------------------------------------
  var cert = TestCertificate(
    schema: CertificateSchema,
    framework: CtTestFramework,
    project: run.project,
    platform: run.platform,
    targets: run.targets,
    result: "passed",
    issuedAt: if options.issuedAt.len > 0: options.issuedAt else: utcNowZ(),
    issuer: if options.issuer.len > 0: options.issuer else: "ct-test",
    vcs: VcsState(
      repo: vcs.repo,
      commit: vcs.commit,
      paths: @[],          # whole-repository claim; scoping is deferred
      clean: true,
      untracked: vcs.untracked,
      worktree: none(WorktreeClaim)),
    commands: run.commands)

  # ---- Signing — OPTIONAL, and OFF unless a key was configured -----------
  if options.signingKeyPath.len > 0:
    if options.keyId.len == 0:
      return withheld(wrSigningFailed,
        "a signing key was configured but no key id was given",
        "pass a key id alongside the key: a consumer resolves `key_id` " &
        "against its registered-key store, and a signed certificate with no " &
        "key id is one nobody can check",
        vcs)
    cert.keyId = options.keyId
    var payload: string
    try:
      payload = canonicalPayload(cert)
    except CertificateError as err:
      return withheld(wrRecordNotRenderable,
        "the record has no canonical form: " & err.msg,
        "this is a defect in the producer; report it with the run's summary",
        vcs)
    let signed = signCanonicalPayload(payload, options.signingKeyPath)
    if not signed.ok:
      return withheld(wrSigningFailed,
        "the certificate could not be signed: " & signed.error,
        "check that the signing key exists and is an OpenSSH private key, and " &
        "that `ssh-keygen` is on PATH; signing is optional, so removing the " &
        "key configuration issues a well-formed unsigned certificate instead",
        vcs)
    cert.signature = CertificateSignature(
      algorithm: SignatureAlgorithm, value: signed.value)

  var document: string
  try:
    document = renderCertificate(cert)
  except CertificateError as err:
    return withheld(wrRecordNotRenderable,
      "the record has no canonical form: " & err.msg,
      "this is a defect in the producer; report it with the run's summary",
      vcs)

  Issuance(issued: true, certificate: cert, document: document,
           reason: wrNone, vcs: vcs)

# ---------------------------------------------------------------------------
# The one exported route to a certificate
# ---------------------------------------------------------------------------

proc targetOfUnit(workspaceRoot: string; unit: RunUnit): string =
  ## What a certificate claims coverage of, for one executed unit.
  ##
  ## `ct test`'s targets are the **test files** that ran: coarse enough to
  ## stay readable in a certificate, fine enough to say something, and stable
  ## across runs — unlike a per-test id, which changes whenever a test is
  ## renamed. Paths are repo-relative with ``/`` separators so a certificate
  ## issued on one machine reads the same on another.
  ##
  ## A unit whose file lies **outside** the workspace root yields no target.
  ## `[certificate.vcs]` describes the repository at that root, so naming a
  ## file the repository does not contain would produce a record that is
  ## formally clean and substantively false — a real, passing test bound to a
  ## commit that says nothing about it. Declining to claim it is safe in the
  ## other direction: a certificate covers exactly the targets it names, and
  ## partial coverage is normal (Standard.md §8).
  ##
  ## The containment test itself is ``workspace_scope.workspaceRelativePath``
  ## — resolved rather than spelled, and shared with discovery so the two
  ## cannot disagree about which files belong to the workspace. It used to
  ## live here alone, which is how discovery came to enumerate sibling
  ## repositories that this proc then refused to attest: the run reported
  ## hundreds of units and the certificate could claim none of them. Read that
  ## proc for the three spelling cases the resolution exists to get right.
  workspaceRelativePath(workspaceRoot, unit.item.file)

proc runAndAttest*(registry: var ProviderRegistry;
                   response: DiscoverResponse;
                   partition: PartitionSpec;
                   threads: int;
                   invocations: openArray[seq[string]];
                   options: IssuanceOptions): AttestedRunOutcome =
  ## Run the discovered tests and attest the result — **the only exported
  ## route in CodeTracer from which a certificate signature can be reached.**
  ##
  ## It takes no results, because it produces them: ``runUnits`` is called
  ## here, and the pass/fail counters, the targets and the platform are all
  ## read out of what came back. A caller can decide *what to run*
  ## (``response``, ``partition``, ``threads``) and can describe *how it was
  ## invoked* (``invocations`` — the argument vectors of the session, in
  ## execution order, recorded verbatim apart from secret redaction, because
  ## only the caller knows them), but it has no way to say how the run turned
  ## out. See the module header for
  ## the residual seam — a caller may register its own provider — and why that
  ## is a different question from the one Standard.md §6.2 asks.
  ##
  ## Returns the run, its summary and the attestation together. Attestation
  ## never affects the run: the tests execute identically whether a certificate
  ## is issued, withheld, or disabled outright.
  let units = enumerateRunUnits(response, registry)
  result.runResult = runUnits(registry, units, partition, threads)
  result.summary = summarize(result.runResult)

  if options.disabled:
    result.issuance = withheld(wrAttestationDisabled,
      "attestation was disabled for this run",
      "drop --no-certificate to have the run attested",
      VcsProbe())
    return

  var run = beginAttestedRun(
    response.workspaceRoot, response.workspaceRoot.lastPathPart,
    currentPlatform())
  for argv in invocations:
    run.recordExecutedCommand(argv)

  var targetOfTest = initTable[string, string]()
  for unit in units:
    targetOfTest[unit.item.id] = targetOfUnit(response.workspaceRoot, unit)
  for outcome in result.runResult.outcomes:
    run.recordUnitResult(
      targetOfTest.getOrDefault(outcome.testId, ""), outcome.events)
  run.concludeAttestedRun()

  result.issuance = issueCertificate(run, options)
