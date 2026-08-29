## Tests for workspace/file discovery, the discovery cache, workspace scoping
## and the workspace-containment bound (discovery.nim).
##
## WHAT IS REAL AND WHAT IS MOCKED — read this before adding a case
## ----------------------------------------------------------------
## Everything about the workspace is real: real directories on the real
## filesystem, real files, the real `git ls-files` inventory where a case sets
## up a repository, and the real `discover` entry point end to end. Several
## cases additionally spawn the real CLI binary and parse its real JSON.
##
## What is faked is only the *provider*, and only where the behaviour under
## test is a property discovery must hold **whatever a provider does**:
##
## * `m1Registry` wraps `discovery.newFakeProviderRegistry`, which is not a
##   test double at all — it is the shipped M1 `.fake` reference provider,
##   walking the real workspace and parsing real fixture files. The only thing
##   added here is a `FakeProviderCounters` recorder, so the cache tests can
##   assert *how many times* discovery called into a provider; that count is
##   the behaviour under test and is not observable from a provider's result.
## * `emptyFileProviderRegistry` — a provider returning an empty catalog, with
##   or without diagnostics. Discovery's rule ("omit empty catalogs, but never
##   omit one carrying an error") is about the aggregation, and pinning it to
##   whichever shipped provider happens to return nothing today would make the
##   guard depend on that provider's fixtures rather than on the rule.
## * `escapingRegistry` — a provider that reports item paths verbatim,
##   including paths outside the workspace root. `boundToWorkspace` exists to
##   make "a workspace discovery reports only the tests that workspace
##   contains" a property of discovery rather than of each provider's good
##   behaviour, so the guard must be driven by a provider that misbehaves.
##   No shipped provider can be made to: `smart_contract_common.harnessItem`
##   was the one that escaped, and it is now bounded to the named root, while
##   every other provider spells `item.file` against the project root — either
##   `relativePath(file, root)` or a fixed root-relative constant
##   (`cpp_ctest`) — neither of which can leave it. The bound is also
##   unreachable from outside the module (`boundToWorkspace` is private, and
##   `discover` takes a registry), so there is no non-mock route to the drop
##   path at all.
##
## No provider *result* is faked into an assertion: every expected catalog and
## diagnostic below is what the real code produced from the real tree.

import std/[algorithm, json, os, osproc, sequtils, strutils, tables, unittest]

import contracts
import discovery
import process_exec

proc writeFixture(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc makeWorkspace(name: string): string =
  let root = getTempDir() / (
    "ct-test-m1-" & name & "-" & $getCurrentProcessId())
  if dirExists(root):
    removeDir(root)
  createDir(root)
  writeFixture(root / "ct-test.fake", "enabled\n")
  # Return the canonical path. On macOS getTempDir() lives under the
  # /var -> /private/var symlink, and the CLI infers workspaceRoot from
  # getCurrentDir() (which resolves symlinks); an unresolved root would then
  # mismatch the CLI's JSON output. Canonicalising here keeps every
  # root-relative comparison consistent with what the spawned CLI sees.
  expandFilename(root)

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

proc testCapabilities(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: false,
    canRunFile: false,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: true)

proc testProviderInfo(id: string): TestProviderInfo =
  TestProviderInfo(
    id: id,
    language: "fake",
    framework: "fixture",
    displayName: id,
    version: "m1",
    capabilities: testCapabilities())

proc emptyCatalog(info: TestProviderInfo): TestCatalog =
  TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: info,
    items: @[],
    diagnostics: @[])

proc emptyFileProviderRegistry(id: string; diagnostics: seq[
    TestDiagnostic]): ProviderRegistry =
  let info = testProviderInfo(id)
  var provider = TestProvider(info: info)
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[], value: true)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    ProviderResult[TestCatalog](
      diagnostics: diagnostics,
      value: emptyCatalog(info))
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    ProviderResult[TestCatalog](diagnostics: @[], value: emptyCatalog(info))
  ProviderRegistry(providers: @[M1Provider(provider: provider,
      relevantConfigFiles: @[])])

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
    check counters.discoverFileCalls[
      normalizedPath(absolutePath(selected))] == 1

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
        DiscoverRequest(scope: dskFile, workspaceRoot: root, file: file,
            jsonOutput: true),
        registry,
        cache)
      check discoverExitCode(response) == 0

    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 1
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 1
    check cache.stats.hits == 2
    check cache.stats.misses == 2

    writeFixture(first, "# CT_TEST_FAKE changed\nbody\n")
    let changed = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: first,
          jsonOutput: true),
      registry,
      cache)
    let unchanged = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: second,
          jsonOutput: true),
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
        DiscoverRequest(scope: dskFile, workspaceRoot: root, file: file,
            jsonOutput: true),
        registry,
        cache)
      check discoverExitCode(response) == 0

    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 1
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 1
    check cache.stats.hits == 2
    check cache.stats.misses == 2

    writeFixture(root / "ct-test.fake", "enabled\nconfig changed\n")
    let firstAfterConfigChange = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: first,
          jsonOutput: true),
      registry,
      cache)
    let secondAfterConfigChange = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: second,
          jsonOutput: true),
      registry,
      cache)

    check discoverExitCode(firstAfterConfigChange) == 0
    check discoverExitCode(secondAfterConfigChange) == 0
    check counters.discoverFileCalls[normalizedPath(absolutePath(first))] == 2
    check counters.discoverFileCalls[normalizedPath(absolutePath(second))] == 2
    check cache.stats.invalidations == 2

  test "discover --workspace aggregates supported catalogs and diagnostics":
    let root = makeWorkspace("workspace")
    defer: removeDir(root)
    discard fakeFile(root, "tests/a.fake", markerLine = 1)
    discard fakeFile(root, "tests/b.fake", markerLine = 2)
    let response = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
          jsonOutput: true),
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
    # Write the throwaway CLI inside src/ct_test so its compile inherits
    # src/ct_test/nim.cfg: the frameworks reached transitively through
    # ``ct_test`` now depend on runquota_process, and that cfg supplies its
    # paths. A temp-dir main would miss the cfg and fail to find the dependency.
    let
      fakeMain = "src" / "ct_test" /
        ("fake_ct_test_main_" & $getCurrentProcessId() & ".nim")
      binary = getTempDir() / ("ct-test-m1-cli-" & $getCurrentProcessId())
    defer: removeFile(fakeMain)
    writeFixture(fakeMain, """
import std/os

import ct_test
import discovery

let counters = newFakeProviderCounters()
quit(runCtTest(
  commandLineParams(),
  newFakeProviderRegistry(counters),
  newDiscoveryCache()))
""")
    let compile = execCmdEx(
      "nim c --hints:off --warnings:off --path:src/ct_test " &
        "--nimcache:/tmp/ct-nim-cache/ct-test-m1-cli -o:" &
        quoteShell(binary) & " " & quoteShell(fakeMain),
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
    check fileNode["catalogs"][0]["schemaVersion"].getInt ==
      TestCatalogSchemaVersion
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

  test "file discovery omits empty catalogs without diagnostics":
    let root = makeWorkspace("empty-file")
    defer: removeDir(root)
    let selected = root / "tests/empty.fake"
    writeFixture(selected, "no tests here\n")
    let response = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: selected,
          jsonOutput: true),
      emptyFileProviderRegistry("empty-provider", @[]),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 0
    check response.diagnostics.len == 0

  test "file discovery keeps provider errors for empty catalogs and cache hits":
    let root = makeWorkspace("empty-error")
    defer: removeDir(root)
    let selected = root / "tests/error.fake"
    writeFixture(selected, "broken tests\n")
    let cache = newDiscoveryCache()
    let registry = emptyFileProviderRegistry("error-provider", @[
      diagnostic(dsError, "provider parser failed", selected)])
    let first = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: selected,
          jsonOutput: true),
      registry,
      cache)
    let second = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: selected,
          jsonOutput: true),
      registry,
      cache)

    check discoverExitCode(first) == 1
    check discoverExitCode(second) == 1
    check first.catalogs.len == 0
    check second.catalogs.len == 0
    check messages(first).contains("provider parser failed")
    check messages(second).contains("provider parser failed")

  test "workspace discovery excludes vendored subtrees and honours --scope":
    ## Scoping regression guard.
    ##
    ## `ct test discover --workspace` used to hand every provider an
    ## unrestricted `walkDirRec`, so a workspace that keeps vendored upstream
    ## source trees in-tree had all of them enumerated as if they were its own
    ## tests. On one real consumer that was 45,256 of 53,322 catalog items.
    ##
    ## The fixture reproduces the three shapes that produced those items:
    ##   * `references/upstream/` — a nested VCS checkout (vendored source);
    ##   * `node_modules/dep/`    — a package-manager dependency tree; and
    ##   * `tests/own.fake`       — the workspace's actual test.
    ## Only the last may appear in the catalog. The final leg re-runs the same
    ## fixture with `--scope unscoped` and asserts the vendored items come
    ## back: without it, an assertion that "the catalog has 1 item" would also
    ## pass if discovery had simply stopped working.
    let root = makeWorkspace("vendored")
    defer: removeDir(root)
    discard fakeFile(root, "tests/own.fake", markerLine = 1)
    # A vendored upstream checkout that the workspace does NOT gitignore, so
    # its own `.git` is the only thing marking the boundary. This is the
    # backstop case on purpose: in the workspace the 45,256-item measurement
    # came from, the `references/` trees ARE gitignored and `git ls-files`
    # never mentioned them, so `.gitignore` did the excluding there and the
    # nested-VCS rule never fired. It is covered here because it is the case
    # `.gitignore` cannot cover, not because it is the common one.
    createDir(root / "references" / "upstream" / ".git")
    discard fakeFile(root, "references/upstream/tests/vendored.fake",
      markerLine = 1)
    discard fakeFile(root, "references/upstream/lib/deep/also_vendored.fake",
      markerLine = 1)
    # A dependency tree with no VCS metadata at all — caught by name.
    discard fakeFile(root, "node_modules/dep/dep_test.fake", markerLine = 1)

    let scoped = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
          jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())

    check discoverExitCode(scoped) == 0
    check scoped.catalogs.len == 1
    var scopedFiles: seq[string] = @[]
    for item in scoped.catalogs[0].items:
      scopedFiles.add item.file
    check scopedFiles == @["tests/own.fake"]
    for path in scopedFiles:
      check not path.startsWith("references/")
      check not path.startsWith("node_modules/")
    # The exclusion must be *reported*, not silent: a caller reconciling this
    # catalog against another runner has to be able to see what was dropped.
    let scopeMessages = messages(scoped)
    check scopeMessages.contains("discovery scope:")
    check scopeMessages.contains("references/upstream")
    check scopeMessages.contains("node_modules")

    let unscoped = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
          jsonOutput: true, scopeMode: wsmUnscoped),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())

    check discoverExitCode(unscoped) == 0
    check unscoped.catalogs.len == 1
    var unscopedFiles: seq[string] = @[]
    for item in unscoped.catalogs[0].items:
      unscopedFiles.add item.file
    unscopedFiles.sort(system.cmp[string])
    check unscopedFiles == @[
      "node_modules/dep/dep_test.fake",
      "references/upstream/lib/deep/also_vendored.fake",
      "references/upstream/tests/vendored.fake",
      "tests/own.fake"]

  test "workspace discovery honours the workspace's own VCS ignore rules":
    ## The scoping rule deliberately does not invent a ct_test-specific ignore
    ## file: it asks the workspace what it already considers its own, via
    ## `git ls-files --cached --others --exclude-standard`. That buys the full
    ## `.gitignore` chain (including nested files and negations) and — the
    ## property this case pins — keeps *untracked but not ignored* files, so a
    ## test written seconds ago is still discovered.
    let root = makeWorkspace("vcs-ignore")
    defer: removeDir(root)
    let gitInit = execCmdEx("git init -q .", options = {poUsePath},
      workingDir = root)
    if gitInit.exitCode != 0:
      skip()
    else:
      writeFixture(root / ".gitignore", "generated/\n*.tmp.fake\n")
      discard fakeFile(root, "tests/tracked.fake", markerLine = 1)
      discard fakeFile(root, "tests/untracked_but_visible.fake", markerLine = 1)
      discard fakeFile(root, "generated/machine_written.fake", markerLine = 1)
      discard fakeFile(root, "tests/scratch.tmp.fake", markerLine = 1)
      # A dependency tree the workspace forgot to gitignore. The VCS inventory
      # would happily list it (untracked, not ignored), so the built-in
      # `VendorDirNames` prune has to apply to git-listed paths too — not only
      # to the filesystem-walk fallback.
      discard fakeFile(root, "node_modules/dep/vcs_dep.fake", markerLine = 1)
      # Track only one of them: the others must still be classified correctly
      # from their ignore status alone.
      discard execCmdEx("git add tests/tracked.fake", options = {poUsePath},
        workingDir = root)

      let response = discover(
        DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
            jsonOutput: true),
        m1Registry(newFakeProviderCounters()),
        newDiscoveryCache())

      check discoverExitCode(response) == 0
      check response.catalogs.len == 1
      var files: seq[string] = @[]
      for item in response.catalogs[0].items:
        files.add item.file
      files.sort(system.cmp[string])
      check files == @[
        "tests/tracked.fake", "tests/untracked_but_visible.fake"]
      check messages(response).contains("vcs-inventory")

  test "invalid workspace and file requests produce clear diagnostics":
    let root = makeWorkspace("invalid")
    defer: removeDir(root)
    let missingFile = root / "missing.fake"
    let fileResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: root, file: missingFile,
          jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())
    let workspaceResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root / "missing",
          jsonOutput: true),
      m1Registry(newFakeProviderCounters()),
      newDiscoveryCache())
    let noProviderResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
          jsonOutput: true),
      emptyProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(fileResponse) == 1
    check messages(fileResponse).contains("invalid file")
    check discoverExitCode(workspaceResponse) == 1
    check messages(workspaceResponse).contains("invalid workspace")
    check discoverExitCode(noProviderResponse) == 1
    check messages(noProviderResponse).contains("no supported test providers")

suite "ct-test workspace scoping guards":
  test "a truncated VCS inventory is refused rather than used short":
    ## Silent-truncation guard.
    ##
    ## `execCaptured` bounds how much of a child's output it keeps. `git
    ## ls-files -z` emits paths in sorted order, so a cut inventory is not a
    ## random sample — it is the alphabet with a contiguous tail missing, and
    ## nothing in the output says so. Using it would report a plausible,
    ## short, WRONG file set; refusing it costs only a fallback to the walk.
    ##
    ## Tested by lowering the bound, not by materialising the ~280,000 files
    ## it would take to overrun the 16 MiB default: the guard is about the
    ## bound being hit, and which number it is makes no difference to it.
    let root = makeWorkspace("truncated-inventory")
    defer: removeDir(root)
    let gitInit = execCmdEx("git init -q .", options = {poUsePath},
      workingDir = root)
    if gitInit.exitCode != 0:
      skip()
    else:
      discard fakeFile(root, "tests/first.fake", markerLine = 1)
      discard fakeFile(root, "tests/second.fake", markerLine = 1)

      # Baseline: with the real bound the inventory is used, so the assertions
      # below cannot pass by discovery simply having stopped working.
      clearVcsInventoryCaptureLimit()
      invalidateWorkspaceScopes()
      let intact = workspaceScope(root)
      check intact.source == wssVcsInventory

      setVcsInventoryCaptureLimit(4)
      defer: clearVcsInventoryCaptureLimit()
      invalidateWorkspaceScopes()
      let truncated = workspaceScope(root)
      # `auto` widens to the pruning walk — a rule that cannot silently lose a
      # tail — and says why.
      check truncated.source == wssFilesystemWalk
      check truncated.notes.join("\n").contains("capture bound")
      var walkedNames: seq[string] = @[]
      for path in truncated.files:
        walkedNames.add extractFilename(path)
      check "first.fake" in walkedNames
      check "second.fake" in walkedNames

  test "`--scope vcs` errors on a truncated inventory and names the flag":
    ## Two things at once, because they are the same diagnostic:
    ##   * `vcs` means "the inventory or nothing", so an unusable inventory is
    ##     an error rather than a quiet widening to a different rule; and
    ##   * the message must name the surface the mode actually came from. It
    ##     used to blame `CT_TEST_SCOPE` even when `--scope` was what was used,
    ##     sending readers to look for an environment variable nobody set.
    let root = makeWorkspace("vcs-truncated")
    defer: removeDir(root)
    let gitInit = execCmdEx("git init -q .", options = {poUsePath},
      workingDir = root)
    if gitInit.exitCode != 0:
      skip()
    else:
      discard fakeFile(root, "tests/only.fake", markerLine = 1)
      setVcsInventoryCaptureLimit(4)
      defer:
        clearVcsInventoryCaptureLimit()
        clearWorkspaceScopeMode()
      let response = discover(
        DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
            jsonOutput: true, scopeMode: wsmVcs),
        m1Registry(newFakeProviderCounters()),
        newDiscoveryCache())
      let text = messages(response)
      check text.contains("--scope vcs was requested")
      check not text.contains("CT_TEST_SCOPE=vcs was requested")
      check text.contains("capture bound")
      check text.contains("unavailable")

  test "execCaptured reports truncation instead of hiding it":
    ## The guard above is only possible because `CapturedRun` surfaces the
    ## truth. Pin the primitive too: `output` is the retained TAIL (runquota
    ## keeps the newest bytes so a failed command's terminal diagnostic
    ## survives the bound), `outputBytes` is the real length, and `truncated`
    ## says which.
    const payload = "0123456789"
    let full = execCaptured(@["printf", "%s", payload])
    if full.exitCode != 0:
      skip()
    else:
      check full.output == payload
      check full.outputBytes == uint64(payload.len)
      check not full.truncated

      let cut = execCaptured(@["printf", "%s", payload], captureLimit = 4)
      # runquota's bounded capture retains the NEWEST bytes (the tail), not the
      # prefix, so a truncated diagnostic keeps its terminal line. For a 10-byte
      # payload bounded to 4 the retained bytes are the last four, "6789".
      check cut.output == payload[payload.len - 4 ..< payload.len]
      check cut.outputBytes == uint64(payload.len)
      check cut.truncated

suite "ct-test workspace containment":
  ## A workspace discovery answers "which tests does THIS workspace have?".
  ## An item naming a file outside the named root is not a narrow answer, it
  ## is a wrong one: `run_orchestration.scopeForItem` resolves item paths
  ## against that same root (so the provider is invoked on a path that does
  ## not exist) and `certificate_issuance.targetOfUnit` refuses to attest a
  ## file the workspace does not contain. Discovery used to have no bound at
  ## all, which is how the M13 recorder harnesses came to report 330 fixtures
  ## belonging to sibling repositories the caller never named.

  proc escapingItem(providerId, file: string): TestItem =
    TestItem(
      id: makeTestItemId(providerId, "fake", "fixture", file, file),
      providerId: providerId,
      language: "fake",
      framework: "fixture",
      name: lastPathPart(file),
      kind: tikCase,
      file: file,
      range: SourceRange(startLine: 1, startColumn: 1, endLine: 1,
          endColumn: 1),
      selector: file,
      parentId: "",
      tags: @[],
      location: LocationProvenance(source: lskPattern, detail: "fixture",
          confidence: lcLow),
      stale: false,
      staleReason: "")

  proc escapingRegistry(id: string; files: seq[string]): ProviderRegistry =
    ## A provider that reports the given item paths verbatim, whatever they
    ## are. Mocked deliberately: no shipped provider can be made to escape on
    ## demand now that `findRecorderRepo` is bounded, and the guard has to be
    ## pinned against the escape it exists to stop, not against the one
    ## provider that used to produce it.
    let info = testProviderInfo(id)
    var provider = TestProvider(info: info)
    provider.detect = proc(projectRoot: string): ProviderResult[
        bool] {.gcsafe.} =
      ProviderResult[bool](diagnostics: @[], value: true)
    provider.discoverProject = proc(projectRoot: string): ProviderResult[
        TestCatalog] {.gcsafe.} =
      var catalog = emptyCatalog(info)
      for file in files:
        catalog.items.add escapingItem(id, file)
      ProviderResult[TestCatalog](diagnostics: @[], value: catalog)
    provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
        TestCatalog] {.gcsafe.} =
      ProviderResult[TestCatalog](diagnostics: @[], value: emptyCatalog(info))
    ProviderRegistry(providers: @[M1Provider(provider: provider,
        relevantConfigFiles: @[])])

  test "workspace discovery drops items outside the workspace root":
    let root = makeWorkspace("containment")
    let outside = expandFilename(getTempDir())
    let response = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: root),
      escapingRegistry("escaper", @[
        "inside/a_test.fake",                    # kept
        "../outside/b_test.fake",                # escapes upward
        "sub/../../outside/c_test.fake",         # escapes through an interior ..
        outside / "d_test.fake",                 # absolute, outside
        "sub/../inside/e_test.fake"              # interior .., resolves inside
      ]),
      newDiscoveryCache())
    check response.catalogs.len == 1
    let kept = response.catalogs[0].items.mapIt(it.file)
    check kept == @["inside/a_test.fake", "sub/../inside/e_test.fake"]
    let text = messages(response)
    check text.contains("outside the workspace root")
    check text.contains("3 test item(s)")
    removeDir(root)

  test "a workspace-relative path is the same question attestation asks":
    ## `workspaceRelativePath` is shared with `certificate_issuance` precisely
    ## so the two cannot drift: whatever discovery keeps is exactly what a
    ## certificate is able to name.
    let root = makeWorkspace("containment-shared")
    check workspaceRelativePath(root, "spec/a_test.rb") == "spec/a_test.rb"
    check workspaceRelativePath(root, root / "spec/a_test.rb") ==
      "spec/a_test.rb"
    check workspaceRelativePath(root, "../elsewhere/a_test.rb") == ""
    check workspaceRelativePath(root, "sub/../../elsewhere/a_test.rb") == ""
    # A sibling directory sharing a name prefix is not "inside".
    check workspaceRelativePath(root, root & "-other/a_test.rb") == ""
    check isInsideWorkspace(root, "spec/a_test.rb")
    check not isInsideWorkspace(root, "../elsewhere/a_test.rb")
    removeDir(root)
