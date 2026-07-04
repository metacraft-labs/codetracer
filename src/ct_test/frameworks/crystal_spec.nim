import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import native_m11_common
import ../process_exec

const
  CrystalSpecProviderId* = "crystal-spec"
  CrystalSpecFramework* = "crystal spec"
  CrystalSpecVersion* = "m11"
  CrystalNixPackages* = ["crystal"]

type
  CrystalCommandScope* = enum
    ccsProject
    ccsFile
    ccsSingle

  CrystalDeclKind* = enum
    cdkSuite
    cdkCase

  CrystalSpecDecl* = object
    kind*: CrystalDeclKind
    name*: string
    selector*: string
    parentSelector*: string
    line*: int
    column*: int
    endColumn*: int

  SuiteFrame = object
    name: string
    selector: string
    closeDepth: int

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isCrystalSpecFile*(path: string): bool =
  fileExists(path) and path.endsWith("_spec.cr")

proc crystalFiles*(projectRoot: string): seq[string]

proc hasCrystalProject*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  if fileExists(projectRoot / "shard.yml"):
    return true
  crystalFiles(projectRoot).len > 0

proc crystalFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith("lib/") or rel.startsWith(".git/"):
      continue
    if isCrystalSpecFile(path):
      result.add path
  result.sort(system.cmp[string])

proc firstQuotedArgument(line: string; startAt: int): tuple[value: string;
    endPos: int] =
  var i = startAt
  while i < line.len and line[i] in {' ', '\t', '('}:
    inc i
  if i >= line.len or line[i] != '"':
    return ("", i)
  inc i
  while i < line.len:
    if line[i] == '\\':
      inc i
      if i < line.len:
        result.value.add line[i]
        inc i
      continue
    if line[i] == '"':
      result.endPos = i + 1
      return
    result.value.add line[i]
    inc i
  result.endPos = i

proc startsWithKeyword(stripped, keyword: string): bool =
  stripped == keyword or stripped.startsWith(keyword & " ") or
    stripped.startsWith(keyword & "(")

proc startsWithEnd(stripped: string): bool =
  stripped == "end" or stripped.startsWith("end ")

proc adjustDepth(stripped: string; depth: var int) =
  if startsWithEnd(stripped):
    depth = max(0, depth - 1)
  for opener in ["describe", "context", "it"]:
    if startsWithKeyword(stripped, opener) and stripped.contains("do"):
      inc depth

proc parseCrystalSpecDeclarations*(projectRoot, filePath, content: string): seq[
    CrystalSpecDecl] =
  let relative = normalizedRelative(projectRoot, filePath)
  var
    suites: seq[SuiteFrame] = @[]
    depth = 0
    lineNo = 0
  for rawLine in content.splitLines:
    inc lineNo
    let stripped = rawLine.strip
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    if startsWithEnd(stripped):
      depth = max(0, depth - 1)
      while suites.len > 0 and suites[^1].closeDepth > depth:
        discard suites.pop()
      continue
    for keyword in ["describe", "context", "it"]:
      if startsWithKeyword(stripped, keyword):
        let parsed = firstQuotedArgument(stripped, keyword.len)
        if parsed.value.len == 0:
          continue
        let
          isSuite = keyword in ["describe", "context"]
          selector = relative & ":" & $lineNo
          parentSelector = if suites.len > 0: suites[^1].selector else: ""
          column = rawLine.find(keyword) + 1
        result.add CrystalSpecDecl(
          kind: if isSuite: cdkSuite else: cdkCase,
          name: parsed.value,
          selector: selector,
          parentSelector: parentSelector,
          line: lineNo,
          column: max(1, column),
          endColumn: max(1, column + keyword.len + parsed.value.len))
        if isSuite:
          suites.add SuiteFrame(name: parsed.value, selector: selector,
              closeDepth: depth + 1)
        break
    adjustDepth(stripped, depth)

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: true,
    canRecordProject: false,
    canRecordFile: true,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: CrystalSpecProviderId,
    language: "crystal",
    framework: CrystalSpecFramework,
    displayName: "Crystal spec",
    version: CrystalSpecVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: CrystalSpecDecl; idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == cdkSuite: tikSuite else: tikCase,
    file: relative,
    range: SourceRange(startLine: decl.line, startColumn: decl.column,
        endLine: decl.line, endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: idsBySelector.getOrDefault(decl.parentSelector, ""),
    tags: if decl.kind == cdkSuite: @["crystal", "spec", "suite"] else:
      @["crystal", "spec"],
    location: LocationProvenance(source: lskParser,
        detail: "M11 lightweight Crystal spec parser for describe/context/it",
        confidence: lcMedium),
    stale: false,
    staleReason: "")

proc crystalFileCatalog*(projectRoot, filePath: string): ProviderResult[
    TestCatalog] =
  let info = providerInfo()
  if not isCrystalSpecFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "not a Crystal *_spec.cr source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
  for decl in parseCrystalSpecDeclarations(projectRoot, filePath,
      readFile(filePath)):
    let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
    idsBySelector[item.selector] = item.id
    items.add item
  ProviderResult[TestCatalog](diagnostics: @[],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in crystalFiles(projectRoot):
    let fileResult = crystalFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc buildCrystalCommand*(projectRoot, filePath, selector: string;
    scope: CrystalCommandScope): seq[string] =
  result = @["crystal", "spec", "--no-color"]
  case scope
  of ccsProject:
    discard
  of ccsFile:
    result.add normalizedRelative(projectRoot, filePath)
  of ccsSingle:
    result.add selector

proc crystalStringLiteral(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '\\':
      result.add "\\\\"
    of '"':
      result.add "\\\""
    else:
      result.add ch
  result.add "\""

proc runCrystal(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  let commandScope =
    case scope.kind
    of tskProject: ccsProject
    of tskFile: ccsFile
    of tskSingle: ccsSingle
  runCommand(CrystalSpecProviderId, scope, buildCrystalCommand(
      scope.projectRoot, scope.file, scope.selector, commandScope),
      @CrystalNixPackages)

proc recordCrystal(scope: TestScope): ProviderResult[seq[
    TestEvent]] {.gcsafe.} =
  if scope.kind != tskFile:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          "Crystal M11 recording supports file-level spec scopes only; " &
          "single specs use line selectors for run-only support",
          scope.file)],
      value: @[])
  {.cast(gcsafe).}:
    let
      buildRoot = getTempDir() / ("ct-m11-crystal-build-" &
          $getCurrentProcessId() & "-" & $epochTime().int & "-" & $cpuTime())
      runner = buildRoot / "spec-runner"
      wrapper = buildRoot / "ct_m11_spec_wrapper.cr"
      requirePath = normalizedRelative(scope.projectRoot, scope.file).
          changeFileExt("")
      buildArgs = block:
        var args = @["crystal", "build", "--debug"]
        when defined(macosx):
          args.add "-Devloop=libevent"
        args.add @["-o", runner, wrapper]
        args
      crystalPath = scope.projectRoot & (
          if getEnv("CRYSTAL_PATH", "").len > 0:
            ":" & getEnv("CRYSTAL_PATH")
          else:
            "")
      buildCommand = "env CRYSTAL_PATH=" & quoteShell(crystalPath) & " " &
          commandWithNixFallback(buildArgs, @CrystalNixPackages)
    createDir(buildRoot)
    writeFile(wrapper, "at_exit { |status| LibC._exit(status) }\n" &
        "require " & crystalStringLiteral(requirePath) & "\n")
    let build = execCapturedShell(buildCommand, cwd = scope.projectRoot)
    if build.exitCode != 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Crystal spec runner build failed with exit code " &
            $build.exitCode, scope.file)],
        value: @[event(tekFailure, CrystalSpecProviderId,
            CrystalSpecProviderId & ":record-build:" & scope.selector,
            if scope.testId.len > 0: scope.testId else: scope.selector,
            some(tsFailed), "Crystal spec runner build failed",
            build.output)])
    recordCommand(CrystalSpecProviderId, scope, @[runner], @[],
        normalizedRelative(scope.projectRoot, scope.file))

proc newCrystalSpecM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    {.cast(gcsafe).}:
      ProviderResult[bool](diagnostics: @[],
          value: hasCrystalProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    crystalFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = crystalFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = runCrystal
  provider.record = recordCrystal
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(CrystalSpecProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @["shard.yml"])

proc newCrystalSpecProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newCrystalSpecM1Provider()])
