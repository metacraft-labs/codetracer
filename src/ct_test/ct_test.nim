import std/[json, os, strutils]

import contracts
import discovery
import run_orchestration
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
    of "--json":
      result.jsonOutput = true
    else:
      result.errors.add "unknown run argument: " & args[i]
    inc i
  if result.workspaceRoot.len == 0:
    result.errors.add "missing required --workspace <path>"

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
  let units = enumerateRunUnits(response, registry)
  let runResult = runUnits(registry, units, partition, opts.threads)
  let summary = summarize(runResult)
  let summaryJson = summaryToJson(summary)

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
    var mutableRegistry = registry
    return runRun(if args.len > 2: args[2 .. ^1] else: @[], mutableRegistry, cache)
  let response = errorResponse(
    "usage: ct-test test (discover (--workspace <path> | --file <path>) --json " &
    "| run --workspace <path> [--file <f>] [--partition file:<path>] " &
    "[--threads N] [--json] [--summary <path>])")
  echo responseToJson(response).pretty
  discoverExitCode(response)

when isMainModule:
  let
    registry = newDefaultProviderRegistry()
    cache = newDiscoveryCache()
  quit(runCtTest(commandLineParams(), registry, cache))
