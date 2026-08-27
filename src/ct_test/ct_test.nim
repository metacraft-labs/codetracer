import std/[json, nativesockets, os, strutils, tables]

import contracts
import discovery
import run_orchestration
import certificate
import certificate_issuance
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
  "usage: ct-test test (" &
  "discover (--workspace <path> | --file <path>) [--json] " &
  "[--scope auto|vcs|walk|unscoped] [--unscoped] " &
  "| run --workspace <path> [--file <f>] [--partition file:<path>] " &
  "[--threads N] [--json] [--summary <path>] " &
  "[--certificate <path>] [--no-certificate] " &
  "[--sign-key <path> --key-id <id>]); " &
  "a passing run issues a test certificate (schema " & CertificateSchema &
  ", framework " & CtTestFramework & ") in the run summary, and writes it to " &
  "`--certificate <path>` when one is given; signing is OPTIONAL and OFF " &
  "unless `--sign-key` is passed; " &
  "discovery is scoped to the workspace's own files by default — " &
  "`--scope` (or the CT_TEST_SCOPE environment variable) selects the rule, " &
  "and `--unscoped` is shorthand for `--scope unscoped`, which INCLUDES " &
  "vendored and ignored trees"

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
    certificatePath: string      ## optional path to write the certificate to
    noCertificate: bool          ## suppress issuance entirely
    signKeyPath: string          ## OpenSSH ed25519 private key; empty ⇒ unsigned
    keyId: string                ## which key signed, for a consumer's key store
    errors: seq[string]

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
    of "--certificate":
      if i + 1 >= args.len: result.errors.add "missing value for --certificate"
      else: result.certificatePath = args[i + 1]; inc i
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
  var arr = newJArray()
  for m in messages: arr.add %m
  echo (%*{
    "total": 0, "executed": 0, "skipped_by_partition": 0,
    "passed": 0, "failed": 0, "wall_time_ms": 0, "threads": 0,
    "errors": arr
  }).pretty
  1

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

proc certificateReport(issuance: Issuance; writtenTo, writeError: string): JsonNode =
  ## The ``certificate`` object attached to every run summary.
  ##
  ## Present whether or not a certificate was issued: "no certificate, and
  ## here is why, and here is what would change that" is the report a producer
  ## owes its user, and silence is what makes a withholding producer unusable.
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
    result["commit"] = %issuance.vcs.commit
    result["clean"] = %issuance.vcs.clean
    result["untracked"] = %issuance.vcs.untracked
  elif issuance.vcs.probed:
    result["vcs_undetermined_reason"] = %issuance.vcs.undeterminedReason
  if issuance.issued:
    result["signed"] = %issuance.certificate.isSigned
    result["document"] = %issuance.document
    if writtenTo.len > 0:
      result["written_to"] = %writtenTo
    if writeError.len > 0:
      result["write_error"] = %writeError
  else:
    result["withheld_reason"] = %($issuance.reason)
    result["message"] = %issuance.message
    result["remedy"] = %issuance.remedy

proc runRun(args: seq[string]; registry: var ProviderRegistry;
    cache: DiscoveryCache): int =
  ## ``ct-test test run`` — discover, enumerate, partition-filter, run in
  ## parallel, and emit the aggregated JSON summary. Returns a non-zero exit
  ## code when any executed test failed (or on argument/partition errors).
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
      keyId: opts.keyId))
  let summary = outcome.summary
  var summaryJson = summaryToJson(summary)

  if not opts.noCertificate:
    let issuance = outcome.issuance
    var writtenTo, writeError: string
    if issuance.issued and opts.certificatePath.len > 0:
      try:
        let parent = parentDir(opts.certificatePath)
        if parent.len > 0:
          createDir(parent)
        writeFile(opts.certificatePath, issuance.document)
        writtenTo = opts.certificatePath
      except CatchableError as err:
        writeError = err.msg
    summaryJson["certificate"] = certificateReport(issuance, writtenTo, writeError)

    if not issuance.issued:
      # stderr, so a machine consumer parsing the summary on stdout is
      # unaffected while a human is told, in one place, what happened and what
      # to do about it.
      stderr.writeLine "ct test: no certificate issued — " & issuance.message
      stderr.writeLine "ct test: " & issuance.remedy
    elif writeError.len > 0:
      stderr.writeLine "ct test: certificate issued but not written to " &
                       opts.certificatePath & ": " & writeError

  echo summaryJson.pretty
  if opts.summaryPath.len > 0:
    createDir(parentDir(opts.summaryPath))
    writeFile(opts.summaryPath, summaryJson.pretty)
  runExitCode(summary)

proc runCtTest*(args: seq[string]; registry: ProviderRegistry;
    cache: DiscoveryCache): int =
  ## CLI entry point. Dispatches the ``test <verb>`` surface; ``discover`` and
  ## ``run`` are implemented. Unknown verbs produce a usage diagnostic.
  if args.len >= 2 and args[0] == "test" and args[1] == "discover":
    return runDiscover(if args.len > 2: args[2 .. ^1] else: @[], registry, cache)
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
    # `--mm:refc` for the rest of CodeTracer's sake, so `ct test run` would
    # crash where `ct test discover` (single-threaded) works fine. Refuse with
    # the machine-readable error envelope every other `run` failure uses,
    # rather than handing the caller a core dump. Compiled out entirely on
    # ORC/ARC builds, which is what the standalone `ct-test` binary is.
    when not defined(gcOrc) and not defined(gcArc):
      return emitRunError(@[
        "`test run` requires an ORC/ARC build: this binary was compiled with " &
        "--mm:refc, whose per-thread heaps make the parallel runner unsafe. " &
        "Use the standalone `ct-test` binary (built --mm:orc) for runs; " &
        "`test discover` is supported here."])
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
