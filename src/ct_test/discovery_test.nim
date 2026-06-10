import std/[json, os, osproc, strutils, tables, unittest]

import contracts
import discovery

proc writeFixture(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc makeWorkspace(name: string): string =
  let root = getTempDir() / ("ct-test-m1-" & name & "-" & $getCurrentProcessId())
  if dirExists(root):
    removeDir(root)
  createDir(root)
  writeFixture(root / "ct-test.fake", "enabled\n")
  root

proc fakeFile(root, name: string; markerLine = 2): string =
  let path = root / name
  var lines: seq[string] = @[]
  for i in 1 .. markerLine:
    if i == markerLine:
      lines.add "# CT_TEST_FAKE " & name
    else:
      lines.add "setup " & $i
  writeFixture(path, lines.join("\n") & "\n")
  path

proc m1Registry(counters: FakeProviderCounters): ProviderRegistry =
  newFakeProviderRegistry(counters)

proc messages(response: DiscoverResponse): string =
  result = ""
  for diagnostic in response.diagnostics:
    result.add diagnostic.message & "\n"
  for catalog in response.catalogs:
    for diagnostic in catalog.diagnostics:
      result.add diagnostic.message & "\n"

suite "ct-test M1 discovery skeleton":
  test "discover --file returns one file catalog without full workspace scan":
    let root = makeWorkspace("file-only")
    defer: removeDir(root)
    let selected = fakeFile(root, "tests/selected.fake", markerLine = 3)
    discard fakeFile(root, "tests/other.fake", markerLine = 5)
    let
      counters = newFakeProviderCounters()
      registry = m1Registry(counters)
      cache = newDiscoveryCache()
      request = DiscoverRequest(
        scope: dskFile,
        workspaceRoot: root,
        file: selected,
        jsonOutput: true)
      response = discover(request, registry, cache)

    check discoverExitCode(response) == 0
    check response.schemaVersion == 1
    check response.catalogs.len == 1
    check response.catalogs[0].items.len == 1
    check response.catalogs[0].items[0].file == "tests/selected.fake"
    check response.catalogs[0].items[0].range.startLine == 3
    check counters.discoverProjectCalls == 0
    check counters.discoverFileCalls.len == 1
    check counters.discoverFileCalls[normalizedPath(absolutePath(selected))] == 1

  test "cache invalidates one changed source file/provider entry":
    let root = makeWorkspace("cache")
    defer: removeDir(root)
    let
      first = fakeFile(root, "tests/first.fake", markerLine = 2)
      second = fakeFile(root, "tests/second.fake", markerLine = 4)
      counters = newFakeProviderCounters()
      registry = m1Registry(counters)
      cache = newDiscoveryCache()

    for file in [first, second, first, second]:
      let response = discover(
        DiscoverRequest(scope: dskFile, workspaceRoot: root, file: file, jsonOutput: true),
        registry,
        cache)
      check discoverExitCode(response) == 0

    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 1
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 1
    check cache.stats.hits == 2
    check cache.stats.misses == 2

    writeFixture(first, "# CT_TEST_FAKE changed\nbody\n")
    let changed = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: first, jsonOutput: true),
      registry,
      cache)
    let unchanged = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: second, jsonOutput: true),
      registry,
      cache)

    check discoverExitCode(changed) == 0
    check discoverExitCode(unchanged) == 0
    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 2
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 1
    check cache.stats.invalidations == 1

  test "cache invalidates one changed config/provider entry":
    let root = makeWorkspace("config-cache")
    defer: removeDir(root)
    let
      first = fakeFile(root, "tests/first.fake", markerLine = 2)
      second = fakeFile(root, "tests/second.fake", markerLine = 4)
      counters = newFakeProviderCounters()
      registry = m1Registry(counters)
      cache = newDiscoveryCache()

    for file in [first, second, first, second]:
      let response = discover(
        DiscoverRequest(scope: dskFile, workspaceRoot: root, file: file, jsonOutput: true),
        registry,
        cache)
      check discoverExitCode(response) == 0

    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 1
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 1
    check cache.stats.hits == 2
    check cache.stats.misses == 2

    writeFixture(root / "ct-test.fake", "enabled\nconfig changed\n")
    let firstAfterConfigChange = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: first, jsonOutput: true),
      registry,
      cache)
    let secondAfterConfigChange = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: second, jsonOutput: true),
      registry,
      cache)

    check discoverExitCode(firstAfterConfigChange) == 0
    check discoverExitCode(secondAfterConfigChange) == 0
    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 2
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 2
    check cache.stats.invalidations == 2

  test "discover --workspace aggregates supported catalogs and unsupported diagnostics":
    let root = makeWorkspace("workspace")
    defer: removeDir(root)
    discard fakeFile(root, "tests/a.fake", markerLine = 1)
    discard fakeFile(root, "tests/b.fake", markerLine = 2)
    let response = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root, jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    check response.catalogs[0].items.len == 2
    check response.catalogs[0].provider.id == "m1-fake"
    check messages(response).contains("unsupported provider")
    check response.catalogs[0].validateCatalog.valid

  test "CLI JSON output is valid for workspace and file discovery argv":
    let root = makeWorkspace("cli")
    defer: removeDir(root)
    let selected = fakeFile(root, "tests/cli.fake", markerLine = 2)
    let binary = getTempDir() / ("ct-test-m1-cli-" & $getCurrentProcessId())
    let compile = execCmdEx(
      "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/ct-test-m1-cli -o:" &
        quoteShell(binary) & " src/ct_test/ct_test.nim",
      options = {poUsePath},
      workingDir = getCurrentDir())
    check compile.exitCode == 0
    if compile.exitCode != 0:
      checkpoint(compile.output)
    let executable =
      if fileExists(binary):
        binary
      else:
        binary & ".out"
    let fileOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", selected, "--json"],
      options = {poUsePath},
      workingDir = root)
    let fileNode = parseJson(fileOutput)

    check fileNode["schemaVersion"].getInt == 1
    check fileNode["workspaceRoot"].getStr == root
    check fileNode["catalogs"].len == 1
    check fileNode["catalogs"][0]["schemaVersion"].getInt == TestCatalogSchemaVersion
    check fileNode["catalogs"][0]["items"][0]["file"].getStr == "tests/cli.fake"

    let workspaceOutput = execProcess(
      executable,
      args = @["test", "discover", "--workspace", root, "--json"],
      options = {poUsePath})
    let workspaceNode = parseJson(workspaceOutput)

    check workspaceNode["schemaVersion"].getInt == 1
    check workspaceNode["workspaceRoot"].getStr == root
    check workspaceNode["catalogs"].len == 1
    check workspaceNode["catalogs"][0]["items"].len == 1

  test "invalid workspace and file requests produce clear diagnostics":
    let root = makeWorkspace("invalid")
    defer: removeDir(root)
    let missingFile = root / "missing.fake"
    let fileResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: missingFile, jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())
    let workspaceResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root / "missing", jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())
    let noProviderResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root, jsonOutput: true),
      emptyProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(fileResponse) == 1
    check messages(fileResponse).contains("invalid file")
    check discoverExitCode(workspaceResponse) == 1
    check messages(workspaceResponse).contains("invalid workspace")
    check discoverExitCode(noProviderResponse) == 1
    check messages(noProviderResponse).contains("no supported test providers")
