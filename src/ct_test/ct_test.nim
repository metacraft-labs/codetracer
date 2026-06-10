import std/[json, os]

import contracts
import discovery
import frameworks/js_jest
import frameworks/js_node_test
import frameworks/js_playwright
import frameworks/js_vitest
import frameworks/nim_unittest
import frameworks/python_pytest
import frameworks/python_unittest
import frameworks/rust_libtest
import frameworks/ruby_minitest
import frameworks/ruby_rspec

proc newDefaultProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[
    newNimUnittestM1Provider(),
    newPythonPytestM1Provider(),
    newPythonUnittestM1Provider(),
    newRustLibtestM1Provider(),
    newJsJestM1Provider(),
    newJsVitestM1Provider(),
    newJsNodeTestM1Provider(),
    newJsPlaywrightM1Provider(),
    newRubyRspecM1Provider(),
    newRubyMinitestM1Provider()
  ])

proc errorResponse(message: string): DiscoverResponse =
  DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion,
    workspaceRoot: "",
    file: "",
    catalogs: @[],
    diagnostics: @[diagnostic(dsError, message)])

proc runCtTest*(args: seq[string]; registry: ProviderRegistry;
    cache: DiscoveryCache): int =
  var response: DiscoverResponse
  if args.len < 2 or args[0] != "test" or args[1] != "discover":
    response = errorResponse(
      "usage: ct-test test discover " &
      "(--workspace <path> | --file <path>) --json")
  else:
    let discoverArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    let parsed = parseDiscoverArgs(discoverArgs)
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

when isMainModule:
  let
    registry = newDefaultProviderRegistry()
    cache = newDiscoveryCache()
  quit(runCtTest(commandLineParams(), registry, cache))
