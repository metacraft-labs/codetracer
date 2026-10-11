import std/[json, nativesockets, os, strutils, tables]

import contracts
import discovery
import run_orchestration
import certificate
import certificate_issuance
import certificate_local_store
import certificate_verify_cli
import ct_test_delegate
import frameworks/ada_fallback
import frameworks/assembly_fallback
import frameworks/crystal_spec
import frameworks/cpp_catch2
import frameworks/cpp_ctest
import frameworks/cpp_gtest
import frameworks/d_unittest
import frameworks/fortran_fallback
import frameworks/go_test
import frameworks/js_jest
import frameworks/js_node_test
import frameworks/js_playwright
import frameworks/js_vitest
import frameworks/julia_fallback
import frameworks/lean_fallback
import frameworks/nim_unittest
import frameworks/noir_nargo
import frameworks/odin_fallback
import frameworks/pascal_fallback
import frameworks/python_pytest
import frameworks/python_unittest
import frameworks/rust_libtest
import frameworks/ruby_minitest
import frameworks/ruby_rspec
import frameworks/v_fallback
import frameworks/smart_contract_harnesses

proc newDefaultProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[
    newNimUnittestM1Provider(),
    newPythonPytestM1Provider(),
    newPythonUnittestM1Provider(),
    newRustLibtestM1Provider(),
    newNoirNargoM1Provider(),
    newCppGTestM1Provider(),
    newCppCatch2M1Provider(),
    newCppCTestM1Provider(),
    newGoTestM1Provider(),
    newDUnittestM1Provider(),
    newCrystalSpecM1Provider(),
    newJsJestM1Provider(),
    newJsVitestM1Provider(),
    newJsNodeTestM1Provider(),
    newJsPlaywrightM1Provider(),
    newRubyRspecM1Provider(),
    newRubyMinitestM1Provider(),
    newPascalFallbackM1Provider(),
    newFortranFallbackM1Provider(),
    newAdaFallbackM1Provider(),
    newOdinFallbackM1Provider(),
    newVFallbackM1Provider(),
    newLeanFallbackM1Provider(),
    newJuliaFallbackM1Provider(),
    newAssemblyFallbackM1Provider()
  ] & newSmartContractHarnessM13Providers())

proc ctTestUsageMessage*(): string =
  ## The ``ct-test`` command-line surface, as one line.
  ##
  ## Exported so the surface can be asserted on directly: ``--scope`` and
  ## ``--unscoped`` decide which files discovery is even allowed to look at,
  ## and a flag with that much authority that appears in no usage text is a
  ## flag nobody finds when they need it.
  ##
  ## The same argument covers the exit status, which is why it is listed here.
  ## ``run`` answers with three of them, and the third is the one a reader has
  ## no way to guess: ``0`` a test ran and every one passed, ``1`` a test ran
  ## and one did not, ``2`` **no test ran at all**. Two is not a variant of
  ## one — a suite that failed told you something, and a suite that never
  ## executed told you nothing while looking identical to success. That is the
  ## whole reason it has its own code, so a script branching on ``$?`` can act
  ## on the difference instead of inferring it from the summary.
  "usage: ct-test test (" &
  "discover (--workspace <path> | --file <path>) [--json] " &
  "[--scope auto|vcs|walk|unscoped] [--unscoped] " &
  "| run --workspace <path> [--file <f>] [--partition file:<path>] " &
  "[--threads N] [--json] [--summary <path>] " &
  "[--no-certificate] [--untracked reads|strict] " &
  "[--sign-key <path> --key-id <id>] " &
  "| verify (--staged | --worktree | --commit <rev>) [--workspace <path>] " &
  "[--targets <t>[,<t>...]] [--platform <p>[,<p>...]] [--json]); " &
  "a passing run issues a test certificate (schema " & CertificateSchema &
  ", framework " & CtTestFramework & ") in the run summary and PUBLISHES it " &
  "to your local certificate store — `$TEST_CERTIFICATES_DIR` when it is an " &
  "absolute path, else `$XDG_STATE_HOME/test-certificates` " &
  "(`~/.local/state/test-certificates`) on Linux, " &
  "`~/Library/Application Support/test-certificates` on macOS, " &
  "`%LOCALAPPDATA%\\test-certificates` on Windows — at `v1/<algorithm>/" &
  "<digest>/<payload sha256>.toml`, keyed by the content it attests, which " &
  "is where CodeTracer's status bar looks; nothing is written into the " &
  "repository, and the store keeps the newest " & $DefaultRetention &
  " contents plus HEAD's; to get a certificate as a file, copy it out of " &
  "the store; " &
  "a certificate is bound to the CONTENT of the tracked files as the tests " &
  "ran against them (`vcs.content`, computed before and after the run; " &
  "`vcs.base` names HEAD and is informational only), so a modified working " &
  "tree is certified as it is, with no need to commit first, and a commit " &
  "that records exactly the tested content is covered with no second run; " &
  "it is withheld, saying why and what to do, when tracked files change " &
  "during the run or when the tree has no content id (unmerged entries, " &
  "assume-unchanged or skip-worktree entries git does not look at, a " &
  "submodule with uncommitted changes), and for untracked files as the " &
  "untracked mode says — `--untracked`, else `[certificate] untracked` in " &
  "the workspace's `.codetracer/test.toml`, else `reads`: `reads` withholds " &
  "only when a read set the run captured shows a test read an untracked " &
  "file (`test run` captures none today, so it issues with " &
  "`untracked = true` and the summary says no read set was captured), " &
  "`strict` withholds whenever an untracked, non-ignored file exists; an " &
  "unknown `--untracked` value is an error before any test runs; an " &
  "unusable `.codetracer/test.toml` is reported before the tests run, " &
  "which still run, and the certificate is withheld; withholding never " &
  "changes the exit status; " &
  "`--no-certificate` suppresses issuance entirely, so nothing is written; " &
  "signing is OPTIONAL and OFF " &
  "unless `--sign-key` is passed; " &
  "discovery is scoped to the workspace's own files by default — " &
  "`--scope` (or the CT_TEST_SCOPE environment variable) selects the rule, " &
  "and `--unscoped` is shorthand for `--scope unscoped`, which INCLUDES " &
  "vendored and ignored trees; " &
  "`run` exits 0 when a test ran and all passed, 1 when a test ran and one " &
  "did not, and 2 when NO test ran at all — a run that executed nothing is " &
  "not a passing run, and the stderr verdict says which of the four causes " &
  "it was; " &
  "`verify` asks whether the certificates in the local certificate store " &
  "(both roots) cover ONE state — `--staged` (the index being committed, " &
  "exactly the tree a commit will record, including inside a pre-commit " &
  "hook), `--worktree` (the tracked files as they are) or `--commit <rev>` " &
  "— evaluating only framework " & CtTestFramework & " records (others are " &
  "reported as ignored) for this platform (`--platform` overrides) and, as " &
  "targets, `--targets` when given, else `[certificate] targets` in the " &
  "workspace's committed `.codetracer/test.toml` as that state has it, else " &
  "every target `discover` reports that can run here; coverage is the " &
  "union of every matching certificate; it exits 0 covered, 1 not covered " &
  "(its one stderr line says whether NO certificate was found for that " &
  "content or records were found and none matched), 2 could not decide " &
  "(a state with no content id, a record it cannot evaluate, an unreadable " &
  "store or `.codetracer/test.toml`); " &
  "as an OPTIONAL pre-commit gate it is one line, `" & PreCommitHookCommand &
  "`, placed LAST in `.git/hooks/pre-commit`: it is the early answer, not " &
  "the enforcement point (`git commit --no-verify` skips it), and it must " &
  "run after every hook step that rewrites staged content, because a step " &
  "that stages a rewrite after it produces a commit the gate never saw"

proc errorResponse(message: string): DiscoverResponse =
  DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion,
    workspaceRoot: "",
    file: "",
    catalogs: @[],
    diagnostics: @[diagnostic(dsError, message)])

proc runDiscover(args: seq[string]; registry: ProviderRegistry;
    cache: DiscoveryCache): int =
  ## ``ct-test test discover`` — enumerate tests and print the catalog JSON.
  let parsed = parseDiscoverArgs(args)
  var response: DiscoverResponse
  if parsed.diagnostics.len > 0:
    response = DiscoverResponse(
      schemaVersion: DiscoverSchemaVersion,
      workspaceRoot: parsed.value.workspaceRoot,
      file: parsed.value.file,
      catalogs: @[],
      diagnostics: parsed.diagnostics)
  else:
    response = discover(parsed.value, registry, cache)
  echo responseToJson(response).pretty
  discoverExitCode(response)

type
  RunOptions = object
    ## Parsed ``ct-test test run`` arguments.
    workspaceRoot: string
    file: string
    partitionArg: string         ## raw ``--partition`` value (e.g. ``file:…``)
    threads: int                 ## 0 ⇒ REPRO_TEST_THREADS / CPU count
    jsonOutput: bool
    summaryPath: string          ## optional path to also write the summary to
    noCertificate: bool          ## suppress issuance entirely
    signKeyPath: string          ## OpenSSH ed25519 private key; empty ⇒ unsigned
    keyId: string                ## which key signed, for a consumer's key store
    untrackedGiven: bool         ## ``--untracked`` was passed (CTC-3g)
    untracked: UntrackedMode     ## its value; wins over the configuration
    errors: seq[string]

proc parseUntrackedMode(value: string; into: var RunOptions) =
  ## ``--untracked reads|strict`` (CTC-3g). An unknown value is an error
  ## before anything runs, never a silently chosen mode.
  for mode in UntrackedMode:
    if value == $mode:
      into.untrackedGiven = true
      into.untracked = mode
      return
  into.errors.add "invalid --untracked value '" & value & "': expected " &
    "\"reads\" (withhold only when a captured read set shows a test read " &
    "an untracked file) or \"strict\" (withhold on any untracked, " &
    "non-ignored file)"

proc parseRunArgs(args: seq[string]): RunOptions =
  ## Parse the ``test run`` argument vector:
  ## ``--workspace <root> [--file <f>] [--partition file:<path>]``
  ## ``[--threads N] [--json] [--summary <path>]``.
  result = RunOptions(threads: 0, jsonOutput: false, errors: @[])
  var i = 0
  while i < args.len:
    case args[i]
    of "--workspace":
      if i + 1 >= args.len: result.errors.add "missing value for --workspace"
      else: result.workspaceRoot = args[i + 1]; inc i
    of "--file":
      if i + 1 >= args.len: result.errors.add "missing value for --file"
      else: result.file = args[i + 1]; inc i
    of "--partition":
      if i + 1 >= args.len: result.errors.add "missing value for --partition"
      else: result.partitionArg = args[i + 1]; inc i
    of "--threads":
      if i + 1 >= args.len:
        result.errors.add "missing value for --threads"
      else:
        try: result.threads = parseInt(args[i + 1].strip())
        except ValueError: result.errors.add "invalid --threads value: " & args[i + 1]
        inc i
    of "--summary":
      if i + 1 >= args.len: result.errors.add "missing value for --summary"
      else: result.summaryPath = args[i + 1]; inc i
    of "--no-certificate":
      result.noCertificate = true
    of "--sign-key":
      if i + 1 >= args.len: result.errors.add "missing value for --sign-key"
      else: result.signKeyPath = args[i + 1]; inc i
    of "--key-id":
      if i + 1 >= args.len: result.errors.add "missing value for --key-id"
      else: result.keyId = args[i + 1]; inc i
    of "--json":
      result.jsonOutput = true
    of "--untracked":
      if i + 1 >= args.len: result.errors.add "missing value for --untracked"
      else:
        parseUntrackedMode(args[i + 1], result)
        inc i
    else:
      if args[i].startsWith("--untracked="):
        parseUntrackedMode(args[i]["--untracked=".len .. ^1], result)
      else:
        result.errors.add "unknown run argument: " & args[i]
    inc i
  if result.workspaceRoot.len == 0:
    result.errors.add "missing required --workspace <path>"
  if result.signKeyPath.len > 0 and result.keyId.len == 0:
    # A signed certificate whose key a consumer cannot resolve is a
    # certificate nobody can check (Verification.md §3.1), so refuse the
    # combination up front rather than issuing one.
    result.errors.add "--sign-key requires --key-id <id>"
  if result.keyId.len > 0 and result.signKeyPath.len == 0:
    result.errors.add "--key-id requires --sign-key <path>"

proc emitRunError(messages: seq[string]): int =
  ## Print a partition/argument error as a summary-shaped JSON document with an
  ## ``errors`` field so machine consumers always parse one schema.
  ##
  ## The key set tracks ``summaryToJson`` exactly — including ``verdict`` — so
  ## "one schema" stays true rather than being merely asserted in a comment.
  ## Exit ``ExitTestsFailed`` rather than ``ExitNothingExecuted``: the run never
  ## started, so this is a failure of the *invocation*, and reporting it as
  ## "the run executed nothing" would point an operator at their workspace when
  ## the problem is their command line (which the ``errors`` array names).
  var arr = newJArray()
  for m in messages: arr.add %m
  echo (%*{
    "total": 0, "dispatched": 0, "executed": 0, "skipped": 0,
    "skipped_by_partition": 0, "passed": 0, "failed": 0, "unrunnable": 0,
    "wall_time_ms": 0, "threads": 0, "verdict": $rvFailed,
    "errors": arr
  }).pretty
  for m in messages:
    stderr.writeLine "ct test: " & m
  ExitTestsFailed

proc invocationArgv(args: seq[string]): seq[string] =
  ## The command this process is executing, as an argument vector.
  ##
  ## ``argv[0]`` is the binary's own name (``ct`` or ``ct-test``) rather than
  ## its full path, so the record is reproducible on another machine; the rest
  ## is the vector this CLI was handed, verbatim. Producers MUST record what
  ## was actually run, not a normalised or idealised form (Standard.md §3.3),
  ## so nothing here rewrites, reorders or drops an argument — secret
  ## redaction, which the same section asks for, happens in
  ## ``recordExecutedCommand``.
  var program = "ct-test"
  try:
    program = getAppFilename().lastPathPart
  except OSError:
    discard
  if program.len == 0:
    program = "ct-test"
  @[program] & args

proc issuerIdentity(): string =
  ## Free-form identification of the issuing component. **Informational, and
  ## explicitly not a trust input** (Standard.md §3.1) — which is why a
  ## hostname that cannot be read degrades to a constant rather than blocking
  ## issuance.
  try:
    "ct-test@" & getHostname()
  except CatchableError:
    "ct-test"

proc certificateReport(issuance: Issuance;
                       writtenTo, writeError: string;
                       pruneErrors: seq[string]): JsonNode =
  ## The ``certificate`` object attached to every run summary.
  ##
  ## Present whether or not a certificate was issued: "no certificate, and
  ## here is why, and here is what would change that" is the report a producer
  ## owes its user, and silence is what makes a withholding producer unusable.
  ##
  ## ``written_to`` is the full path of the record in the user's local
  ## certificate store (``certificate_local_store``); nothing is ever written
  ## inside the repository, so there is no store notice to give (the
  ## ``store_notice`` field CTC-2 had is gone with the workspace store).
  # `vcs` is TRI-state, not a boolean. A run that failed its own gate (no tests
  # executed, tests failed) never reaches git at all, and reporting that as
  # "could not determine the repository state" would send an operator after a
  # VCS problem that does not exist.
  let vcsState =
    if not issuance.vcs.probed: "not-probed"
    elif issuance.vcs.determined: "determined"
    else: "undetermined"
  result = %*{
    "schema": CertificateSchema,
    "framework": CtTestFramework,
    "issued": issuance.issued,
    "vcs": vcsState
  }
  if issuance.vcs.determined:
    # The binding is `content`; `base` is informational and absent on an
    # unborn branch. `content_before` appears only when it differs, which is
    # the evidence behind `wrContentChanged`.
    if issuance.vcs.content.len > 0:
      result["content"] = %issuance.vcs.content
    if issuance.vcs.contentBefore.len > 0 and
       issuance.vcs.contentBefore != issuance.vcs.content:
      result["content_before"] = %issuance.vcs.contentBefore
    if issuance.vcs.noContentId.len > 0:
      var conditions = newJArray()
      for state in issuance.vcs.noContentId:
        conditions.add %*{"condition": $state.condition, "paths": state.paths}
      result["no_content_id"] = conditions
    result["untracked"] = %issuance.vcs.untracked
    if issuance.vcs.untrackedPaths.len > 0:
      result["untracked_paths"] = %issuance.vcs.untrackedPaths
    if issuance.vcs.base.len > 0:
      result["base"] = %issuance.vcs.base
  elif issuance.vcs.probed:
    result["vcs_undetermined_reason"] = %issuance.vcs.undeterminedReason
  if issuance.reason != wrAttestationDisabled:
    # CTC-3g: the mode in force, and whether the run had a read set to judge
    # untracked files by. Stated, not implied: in the default mode a run
    # with no read set issues, and the summary says why it could not judge.
    result["untracked_mode"] = %($issuance.untracked.mode)
    result["read_set"] =
      %(if issuance.untracked.readSetCaptured: "captured" else: "not-captured")
    if issuance.untracked.note.len > 0:
      result["untracked_note"] = %issuance.untracked.note
    if issuance.reason == wrUntrackedInput:
      result["untracked_inputs"] = %issuance.untracked.offending
  if issuance.issued:
    result["signed"] = %issuance.certificate.isSigned
    result["document"] = %issuance.document
    if writtenTo.len > 0:
      result["written_to"] = %writtenTo
    if writeError.len > 0:
      result["write_error"] = %writeError
    if pruneErrors.len > 0:
      result["prune_errors"] = %pruneErrors
  else:
    result["withheld_reason"] = %($issuance.reason)
    result["message"] = %issuance.message
    result["remedy"] = %issuance.remedy

proc runRun(args: seq[string]; registry: var ProviderRegistry;
    cache: DiscoveryCache): int =
  ## ``ct-test test run`` — discover, enumerate, partition-filter, run in
  ## parallel, and emit the aggregated JSON summary.
  ##
  ## The exit status distinguishes three outcomes (``run_orchestration``'s
  ## ``RunVerdict``): ``0`` tests ran and all passed; ``1`` tests ran and at
  ## least one failed, or the invocation itself was rejected; ``2`` **no test
  ## executed at all**, which is not a success and must never again be reported
  ## as one.
  let opts = parseRunArgs(args)
  if opts.errors.len > 0:
    return emitRunError(opts.errors)

  # Parse the partition allow-list up front so a bad file fails fast.
  var partition = emptyPartition()
  if opts.partitionArg.len > 0:
    try:
      partition = parsePartitionArg(opts.partitionArg)
    except ValueError as err:
      return emitRunError(@[err.msg])

  # The untracked-files mode (CTC-3g), resolved BEFORE any test runs, so an
  # unusable `.codetracer/test.toml` is reported up front. It does not stop
  # the run: the file decides only whether a certificate may be issued, so
  # the tests run, the exit status is theirs, and the certificate is withheld
  # (`wrUntrackedModeUnresolved`) rather than issued under a mode nobody
  # chose. `--no-certificate` means attestation reads nothing, this
  # configuration included.
  var untrackedMode = umReads
  var untrackedModeProblem = ""
  if not opts.noCertificate:
    let resolved = resolveUntrackedMode(opts.workspaceRoot,
                                        opts.untrackedGiven, opts.untracked)
    if resolved.ok:
      untrackedMode = resolved.mode
    else:
      untrackedModeProblem = resolved.problem
      stderr.writeLine "ct test: warning — " & resolved.problem &
        "; the tests will run, but no certificate will be issued"

  # Discover the candidate tests via the providers (workspace- or file-scoped).
  let request =
    if opts.file.len > 0:
      DiscoverRequest(scope: dskFile, workspaceRoot: opts.workspaceRoot,
        file: opts.file, jsonOutput: opts.jsonOutput)
    else:
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: opts.workspaceRoot,
        jsonOutput: opts.jsonOutput)
  let response = discover(request, registry, cache)
  if discoverExitCode(response) != 0:
    var messages: seq[string] = @[]
    for d in response.diagnostics:
      if d.severity == dsError:
        messages.add d.message
    return emitRunError(messages)

  # Enumerate → filter → run in parallel → aggregate.
  # ---- Run, and attest as a by-product of running --------------------------
  # `runAndAttest` IS the run: it drives the worker pool and reads the outcome
  # from the providers' own event streams. There is no way to hand it a result
  # (Standard.md §6.2), which is why this call replaced a `runUnits` here plus
  # a separate issuance step that took the events back as arguments.
  # Withholding never changes the exit code — the tests ran either way, and
  # only the claim about them is withheld.
  let outcome = runAndAttest(
    registry, response, partition, opts.threads,
    [invocationArgv(@["test", "run"] & args)],
    IssuanceOptions(
      disabled: opts.noCertificate,
      issuer: issuerIdentity(),
      signingKeyPath: opts.signKeyPath,
      keyId: opts.keyId,
      untrackedMode: untrackedMode,
      untrackedModeProblem: untrackedModeProblem))
  let summary = outcome.summary
  var summaryJson = summaryToJson(summary)

  # ---- The units nothing could run ----------------------------------------
  # Surfaced as machine-readable `errors` (aggregated per provider, not one
  # line per unit) so "333 tests were discovered and none of them can be run
  # here" is a fact the summary states rather than an absence a reader has to
  # infer from `executed == 0`.
  let refused = unrunnableByProvider(outcome.runResult)
  if refused.len > 0:
    var arr = newJArray()
    for entry in refused:
      arr.add %("provider '" & entry.providerId & "' cannot run " &
                $entry.units & " of the units dispatched to it, so they were " &
                "discovered but never executed")
    summaryJson["errors"] = arr

  if not opts.noCertificate:
    let issuance = outcome.issuance
    var writtenTo, writeError: string
    var pruneErrors: seq[string]
    if issuance.issued:
      # THE LOCAL CERTIFICATE STORE, always (Transport.md §2): the user root,
      # keyed by the content the record attests. Never the repository — a
      # certificate in the working tree would change the content it attests —
      # and never a path the caller names: `--certificate <path>` was removed
      # (CTC-3e). A user who wants a file copies it out of the store.
      let published = publishToLocalStore(
        nativeCertificateStoreRoots(), response.workspaceRoot,
        issuance.document)
      if published.written:
        writtenTo = published.path
      writeError = published.error
      pruneErrors = published.pruned.errors
    summaryJson["certificate"] =
      certificateReport(issuance, writtenTo, writeError, pruneErrors)
    if untrackedModeProblem.len > 0:
      # No mode was in force, whichever gate withheld first: say so rather
      # than report the default nobody chose.
      summaryJson["certificate"]["untracked_mode"] = %"unresolved"
      summaryJson["certificate"]["untracked_mode_problem"] =
        %untrackedModeProblem
      for key in ["read_set", "untracked_note"]:
        if summaryJson["certificate"].hasKey(key):
          summaryJson["certificate"].delete(key)

    if not issuance.issued:
      # stderr, so a machine consumer parsing the summary on stdout is
      # unaffected while a human is told, in one place, what happened and what
      # to do about it.
      stderr.writeLine "ct test: no certificate issued — " & issuance.message
      stderr.writeLine "ct test: " & issuance.remedy
    else:
      if writeError.len > 0:
        stderr.writeLine "ct test: certificate issued but not written to " &
                         "the local certificate store: " & writeError
      for problem in pruneErrors:
        # Not a failure: pruning is a matter of disk space (Transport.md §2.5).
        stderr.writeLine "ct test: warning — the certificate store could " &
                         "not be pruned: " & problem

  echo summaryJson.pretty
  if opts.summaryPath.len > 0:
    createDir(parentDir(opts.summaryPath))
    writeFile(opts.summaryPath, summaryJson.pretty)

  # ---- Say why, in the same breath as saying so ----------------------------
  # An exit code that changes from 0 to non-zero with no explanation is worse
  # than the bug it fixes. Every non-zero verdict prints its message and its
  # remedy on stderr — always, including under `--no-certificate`, because the
  # verdict is a property of the RUN and the certificate's withholding notice
  # (which is about the *claim*) can be switched off independently.
  #
  # Note the two are now consistent by construction rather than by coincidence:
  # `runVerdict` and `issueCertificate` both count only tests that finished
  # passed/failed/errored, so a run can no longer exit 0 while its certificate
  # is withheld for `wrNoTestsExecuted`.
  let verdict = runVerdictReport(summary)
  if verdict.message.len > 0:
    # The verdict and the exit status are named in the line itself. A run can
    # print *two* stderr paragraphs — the certificate's withholding notice and
    # this one — and they are about different things (what the producer will
    # claim, vs. what the run itself concluded), so each has to say which it
    # is or the second reads as a duplicate of the first.
    stderr.writeLine "ct test: run verdict: " & $summary.runVerdict &
                     " (exit " & $runExitCode(summary) & ") — " & verdict.message
    stderr.writeLine "ct test: " & verdict.remedy
  else:
    let notice = unrunnableNotice(summary)
    if notice.len > 0:
      stderr.writeLine "ct test: warning — " & notice

  runExitCode(summary)

proc refcRunRefusal*(lookup: CtTestLookup): string =
  ## Why a refc build will not run `test run`, and where it looked for the
  ## `ct-test` it would otherwise have handed the run to.
  "`test run` needs the `ct-test` runner, which is built --mm:orc and ships " &
  "beside `ct`: this binary was compiled with --mm:refc, whose per-thread " &
  "heaps make the parallel runner unsafe, and it found no `ct-test` to hand " &
  "the run to (" & describeCtTestLookup(lookup) & "). Reinstall CodeTracer, " &
  "or put `ct-test` on PATH; `test discover` and `test verify` work here."

proc runCtTest*(args: seq[string]; registry: ProviderRegistry;
    cache: DiscoveryCache): int =
  ## CLI entry point. Dispatches the ``test <verb>`` surface; ``discover``,
  ## ``run`` and ``verify`` are implemented. Unknown verbs produce a usage
  ## diagnostic.
  if args.len >= 2 and args[0] == "test" and args[1] == "discover":
    return runDiscover(if args.len > 2: args[2 .. ^1] else: @[], registry, cache)
  if args.len >= 2 and args[0] == "test" and args[1] == "verify":
    # Single-threaded (discovery at most), so unlike `run` it is safe on the
    # `ct` binary's refc build.
    return runVerify(if args.len > 2: args[2 .. ^1] else: @[], registry, cache)
  if args.len >= 2 and args[0] == "test" and args[1] == "run":
    # `run` executes the discovered tests on a worker pool
    # (``run_orchestration.runUnits``), and the workers share the
    # ``RunUnit``/``TestItem`` sequences with the spawning thread. Nim's refc
    # collector gives every thread a PRIVATE heap, so that sharing is
    # undefined behaviour: a refc build of this source SIGSEGVs inside the
    # worker loop on the very first run, before a single result exists.
    # ORC/ARC share one heap, so the workers run and a summary is produced.
    #
    # ORC/ARC alone were once not enough either: worker-allocated results used
    # to be freed after the workers had been joined, which aborted the process
    # in the allocator once the worker count was high enough — after a
    # correct-looking summary had already been printed. That is fixed at the
    # source in ``run_orchestration.runUnits`` (see its ``ResultHandoff``
    # type); no thread-count cap is involved, and `run` is expected to exit 0
    # at any ``--threads`` value on ORC/ARC. What this branch is about is refc
    # producing no results at all.
    #
    # This is not hypothetical — the `ct` binary embeds this CLI and is built
    # `--mm:refc` for the rest of CodeTracer's sake. `ct` therefore never runs
    # tests itself: `src/ct/codetracer.nim` hands `test run` to the ORC-built
    # `ct-test` that every package ships beside it (`ct_test_delegate.nim`),
    # BEFORE this procedure is reached. Arriving here on a refc build means no
    # `ct-test` was found, so refuse with the machine-readable error envelope
    # every other `run` failure uses, naming the places the lookup tried,
    # rather than handing the caller a core dump. Compiled out entirely on
    # ORC/ARC builds, which is what `ct-test` is — so `ct-test` can never
    # delegate, to itself or to anything else.
    when not defined(gcOrc) and not defined(gcArc):
      return emitRunError(@[refcRunRefusal(locateCtTest())])
    else:
      var mutableRegistry = registry
      return runRun(if args.len > 2: args[2 .. ^1] else: @[], mutableRegistry, cache)
  let response = errorResponse(ctTestUsageMessage())
  echo responseToJson(response).pretty
  discoverExitCode(response)

proc runCtTestCli*(args: seq[string]): int =
  ## Convenience entry point for embedders that do not want to own the
  ## provider registry or the discovery cache.
  ##
  ## ``runCtTest`` above deliberately takes both as parameters so a library
  ## consumer can install a reduced/extended provider set and share a warm
  ## cache across invocations. The two callers that just want "the default
  ## ct_test CLI, please" — the standalone ``ct-test`` binary below and the
  ## ``ct test discover|run`` route in ``src/ct/codetracer.nim`` — would
  ## otherwise each duplicate the same two-line construction, so it lives
  ## here once. ``args`` is the full ``test <verb> …`` vector, exactly as
  ## ``runCtTest`` expects it.
  let
    registry = newDefaultProviderRegistry()
    cache = newDiscoveryCache()
  runCtTest(args, registry, cache)

when isMainModule:
  quit(runCtTestCli(commandLineParams()))
