import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import native_m11_common
import ../process_exec

type
  SmartHarnessRecordMode* = enum
    shrmRecordFile
    shrmFuelBytecode
    shrmUnsupported

  SmartHarnessSpec* = object
    providerId*: string
    language*: string
    framework*: string
    displayName*: string
    recorderRepo*: string
    recorderBinary*: string
    envCommand*: string
    fixtureRoots*: seq[string]
    fixtureExtensions*: seq[string]
    ignoredPathFragments*: seq[string]
    preferredFixtureNames*: seq[string]
    recordMode*: SmartHarnessRecordMode
    stableTestCommand*: string
    dependencies*: seq[string]
    requiredTools*: seq[string]
    nixPackages*: seq[string]
    limitations*: string

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc hasExtension(spec: SmartHarnessSpec; path: string): bool =
  let ext = splitFile(path).ext.toLowerAscii
  for candidate in spec.fixtureExtensions:
    if ext == candidate.toLowerAscii:
      return true
  false

proc isIgnored(spec: SmartHarnessSpec; path: string): bool =
  let normalized = path.replace("\\", "/")
  for fragment in spec.ignoredPathFragments:
    if fragment.len > 0 and fragment in normalized:
      return true
  false

proc findRecorderRepo*(spec: SmartHarnessSpec; projectRoot: string): string =
  ## Locate ``spec.recorderRepo`` **inside the workspace root the caller
  ## named**, or report that it is not there.
  ##
  ## Two forms are recognised, and they are the two the recorder harnesses are
  ## for:
  ##
  ## * ``projectRoot`` *is* the recorder repo — ``ct test --workspace
  ##   codetracer-cairo-recorder``; and
  ## * ``projectRoot`` *contains* it as a sibling checkout — ``ct test
  ##   --workspace <multi-repo workspace>``, the invocation the M13 research
  ##   note describes ("catalog integration for sibling recorder repositories
  ##   present in the workspace") and the one ``m13_smart_contract_harnesses_
  ##   test.nim`` exercises.
  ##
  ## **Two former search seeds are deliberately gone.**
  ##
  ## ``getCurrentDir()`` used to seed the search, so which sibling repos a
  ## provider found depended on the directory the shell happened to be in.
  ## The same ``--workspace`` and the same binary discovered 1 catalog / 11
  ## items from ``$HOME`` and 15 catalogs / 341 items from a checkout inside
  ## the multi-repo workspace — 330 fixtures belonging to repositories the
  ## caller never named. A suite whose contents cannot be predicted from the
  ## command line is not a suite, and the working directory names nothing the
  ## caller asked for.
  ##
  ## The walk up through ``projectRoot``'s *ancestors* was deterministic, but
  ## escaped the workspace in the same way: with ``--workspace codetracer`` it
  ## reached the sibling recorder repos one level up and enumerated their
  ## fixtures as tests of *this* workspace. Those units are unusable in both
  ## directions — ``run_orchestration.scopeForItem`` resolves an item's file
  ## against the workspace root, so a fixture living in another repository is
  ## handed to the recorder under a path that does not exist, and
  ## ``certificate_issuance.targetOfUnit`` refuses to attest a file the
  ## workspace does not contain. Discovery now applies the rule attestation
  ## already applied, instead of contradicting it.
  ##
  ## Callers who want a sibling's fixtures still have an exact, deterministic
  ## way to ask: name the workspace that contains it.
  if projectRoot.len == 0:
    return ""
  let root = normalizedPath(absolutePath(projectRoot))
  if splitPath(root).tail == spec.recorderRepo and dirExists(root):
    return root
  let nested = root / spec.recorderRepo
  if dirExists(nested):
    return nested
  ""

proc isExecutableCandidate(path: string): bool =
  if not fileExists(path):
    return false
  when defined(windows):
    true
  else:
    let permissions = getFilePermissions(path)
    fpUserExec in permissions or fpGroupExec in permissions or
      fpOthersExec in permissions

proc isWithinDir(path, dir: string): bool =
  if path.len == 0 or dir.len == 0:
    return false
  let
    absoluteCandidate = normalizedPath(absolutePath(path)).replace("\\", "/")
    absoluteDir = normalizedPath(absolutePath(dir)).replace("\\", "/")
  absoluteCandidate == absoluteDir or
    absoluteCandidate.startsWith(absoluteDir & "/")

proc recorderHelpLooksReal(spec: SmartHarnessSpec; command: string): bool =
  if not command.isExecutableCandidate:
    return false
  let help = execCapturedShell(commandLine(@[command, "--help"]))
  if help.exitCode != 0:
    return false
  let output = help.output.toLowerAscii
  output.contains("codetracer") and output.contains("record") and
    output.contains(spec.recorderBinary.toLowerAscii)

proc trustedRecorderCommand(spec: SmartHarnessSpec; projectRoot,
    command: string): bool =
  let repo = spec.findRecorderRepo(projectRoot)
  if repo.len > 0 and command.isWithinDir(repo / "target"):
    return true
  spec.recorderHelpLooksReal(command)

proc configuredRecorderCommand*(spec: SmartHarnessSpec;
    projectRoot: string): seq[string] =
  let configured = getEnv(spec.envCommand, "")
  if configured.len > 0:
    if spec.trustedRecorderCommand(projectRoot, configured):
      return @[configured]
    return @[]
  let onPath = findExe(spec.recorderBinary)
  if onPath.len > 0 and spec.trustedRecorderCommand(projectRoot, onPath):
    return @[onPath]
  let repo = spec.findRecorderRepo(projectRoot)
  if repo.len > 0:
    for candidate in [
      repo / "target" / "debug" / spec.recorderBinary,
      repo / "target" / "release" / spec.recorderBinary
    ]:
      if candidate.isExecutableCandidate:
        return @[candidate]
  @[]

proc canInvokeRecorder*(spec: SmartHarnessSpec; projectRoot: string): bool =
  proc toolsAvailable(spec: SmartHarnessSpec): bool =
    for tool in spec.requiredTools:
      if findExe(tool).len == 0:
        return spec.nixPackages.len > 0 and findExe("nix-shell").len > 0
    true

  spec.recordMode != shrmUnsupported and
    spec.configuredRecorderCommand(projectRoot).len > 0 and toolsAvailable(spec)

proc providerCapabilities*(spec: SmartHarnessSpec;
    projectRoot: string): TestCapabilities =
  let canRecord = spec.canInvokeRecorder(projectRoot)
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: false,
    canRunFile: canRecord,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: canRecord,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: canRecord,
    emitsStructuredEvents: false)

proc providerInfo*(spec: SmartHarnessSpec; projectRoot = ""): TestProviderInfo =
  TestProviderInfo(
    id: spec.providerId,
    language: spec.language,
    framework: spec.framework,
    displayName: spec.displayName,
    version: "m13",
    capabilities: providerCapabilities(spec, projectRoot))

proc fixtureFiles*(spec: SmartHarnessSpec; projectRoot: string): seq[string] =
  let repo = spec.findRecorderRepo(projectRoot)
  if repo.len == 0:
    return @[]
  for fixtureRoot in spec.fixtureRoots:
    let root = repo / fixtureRoot
    if not dirExists(root):
      continue
    for path in walkWorkspaceFiles(root):
      if fileExists(path) and spec.hasExtension(path) and
          not spec.isIgnored(path):
        result.add path
  result.sort(proc(a, b: string): int =
    proc rank(path: string; names: seq[string]): int =
      let base = splitFile(path).name & splitFile(path).ext
      for i, name in names:
        if base == name or path.replace("\\", "/").endsWith(name):
          return i
      names.len + 1
    let ra = rank(a, spec.preferredFixtureNames)
    let rb = rank(b, spec.preferredFixtureNames)
    if ra != rb: cmp(ra, rb) else: cmp(a, b))

proc isFixtureFile(spec: SmartHarnessSpec; projectRoot,
    filePath: string): bool =
  let repo = spec.findRecorderRepo(projectRoot)
  if repo.len == 0 or not fileExists(filePath) or
      not spec.hasExtension(filePath) or spec.isIgnored(filePath):
    return false
  for fixtureRoot in spec.fixtureRoots:
    if filePath.isWithinDir(repo / fixtureRoot):
      return true
  false

proc harnessItem(spec: SmartHarnessSpec; projectRoot,
    filePath: string): TestItem =
  ## One catalog item for one fixture file.
  ##
  ## ``file`` is relative to the **workspace root**, not to the recorder repo.
  ## Every consumer of ``item.file`` resolves it against the workspace root —
  ## ``run_orchestration.scopeForItem`` to build the absolute path the recorder
  ## is invoked on, ``certificate_issuance.targetOfUnit`` to name what the run
  ## covered — so a repo-relative spelling was not merely a different
  ## convention: with any workspace root other than the recorder repo itself it
  ## pointed at a file that does not exist, and would have had a certificate
  ## claim coverage of ``test-programs/cairo/flow_test.cairo`` in a repository
  ## containing no such path. Since ``findRecorderRepo`` now resolves only
  ## inside the workspace root, this spelling can no longer escape it either.
  let
    info = providerInfo(spec, projectRoot)
    relative = normalizedRelative(projectRoot, filePath)
    selector = relative
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: splitFile(filePath).name,
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1,
        endColumn: 1),
    selector: selector,
    parentId: "",
    tags: @[spec.language, "m13-smart-contract-harness", "recorder-fixture"],
    location: LocationProvenance(source: lskExternal,
        detail: spec.recorderRepo & " " & spec.stableTestCommand,
        confidence: lcHigh),
    stale: false,
    staleReason: "")

proc catalogDiagnostics(spec: SmartHarnessSpec; projectRoot,
    filePath: string): seq[TestDiagnostic] =
  result.add diagnostic(dsInfo, spec.limitations, filePath)
  if spec.recordMode == shrmUnsupported:
    result.add diagnostic(dsWarning,
      spec.displayName & " has no CodeTracer recorder CLI harness in this " &
      "workspace; catalog discovery is informational only.",
      filePath)
  elif spec.configuredRecorderCommand(projectRoot).len == 0:
    result.add diagnostic(dsWarning,
      spec.displayName & " recording is unavailable: " & spec.recorderBinary &
      " was not found on PATH or in " & spec.recorderRepo &
      "/target/{debug,release}. Set " & spec.envCommand &
      " to an executable recorder binary.",
      filePath)
  else:
    for tool in spec.requiredTools:
      if findExe(tool).len == 0:
        if spec.nixPackages.len == 0 or findExe("nix-shell").len == 0:
          result.add diagnostic(dsWarning,
            spec.displayName & " recording is unavailable: required tool " &
            tool & " was not found on PATH.",
            filePath)
          return

proc smartHarnessProjectCatalog*(spec: SmartHarnessSpec;
    projectRoot: string): ProviderResult[TestCatalog] =
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: providerInfo(spec, projectRoot), items: @[], diagnostics: @[])
  for path in spec.fixtureFiles(projectRoot):
    catalog.items.add harnessItem(spec, projectRoot, path)
  catalog.diagnostics = catalogDiagnostics(spec, projectRoot, projectRoot)
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc smartHarnessFileCatalog*(spec: SmartHarnessSpec; projectRoot,
    filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo(spec, projectRoot)
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  if spec.isFixtureFile(projectRoot, filePath):
    catalog.items.add harnessItem(spec, projectRoot, filePath)
  catalog.diagnostics = catalogDiagnostics(spec, projectRoot, filePath)
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc unsupportedDiagnostic(spec: SmartHarnessSpec; scope: TestScope;
    action: string): ProviderResult[seq[TestEvent]] =
  let message =
    if spec.recordMode == shrmUnsupported:
      spec.displayName & " cannot " & action &
        ": no CodeTracer recorder CLI harness is present for this repository."
    else:
      spec.displayName & " cannot " & action & ": " & spec.recorderBinary &
        " was not found. Build the recorder repo or set " & spec.envCommand &
        " to an executable recorder binary."
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsError, message, scope.file)],
    value: @[])

proc ctArtifacts(root: string): seq[string] =
  if not dirExists(root):
    return @[]
  for path in walkDirRec(root):
    if fileExists(path) and splitFile(path).ext == ".ct":
      result.add path
  result.sort(system.cmp[string])

proc nonEmptyTraceArtifacts(root: string): seq[string] =
  for path in ctArtifacts(root):
    if getFileSize(path) > 0:
      result.add path
  result.sort(system.cmp[string])

proc recordArgs(spec: SmartHarnessSpec; scope: TestScope;
    outDir: string): seq[string] =
  let recorder = spec.configuredRecorderCommand(scope.projectRoot)
  case spec.recordMode
  of shrmRecordFile:
    recorder & @["record", scope.file, "--out-dir", outDir]
  of shrmFuelBytecode:
    recorder & @["record", "--bytecode", scope.file, "--out-dir", outDir]
  of shrmUnsupported:
    @[]

proc missingRequiredTools(spec: SmartHarnessSpec): seq[string] =
  for tool in spec.requiredTools:
    if findExe(tool).len == 0:
      result.add tool

proc recordCommand(spec: SmartHarnessSpec; args: seq[string]): string =
  let direct = commandLine(args)
  if spec.missingRequiredTools.len == 0:
    return direct
  if spec.nixPackages.len > 0 and findExe("nix-shell").len > 0:
    var wrapped = @["nix-shell", "-p"] & spec.nixPackages & @["--run", direct]
    return commandLine(wrapped)
  direct

proc runRecorderCommand(spec: SmartHarnessSpec; scope: TestScope;
    mode: TestRunMode): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if scope.kind != tskFile:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            spec.displayName & " M13 harness supports file-level fixtures only",
            scope.file)],
        value: @[])
    if not spec.canInvokeRecorder(scope.projectRoot):
      return unsupportedDiagnostic(spec, scope,
        if mode == trmRecord: "record fixtures" else: "run fixture smoke")

    let
      providerId = spec.providerId
      outputRoot = getTempDir() / ("ct-m13-" & providerId & "-" &
          $getCurrentProcessId() & "-" & $epochTime().int & "-" & $cpuTime())
      args = spec.recordArgs(scope, outputRoot)
      command = spec.recordCommand(args)
      runId = providerId & ":" & $mode & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    createDir(outputRoot)

    var events = @[
      event(if mode == trmRecord: tekRecordStarted else: tekRunStarted,
        providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    let started = epochTime()
    let outcome = execCapturedShell(command, cwd = spec.findRecorderRepo(scope.projectRoot))
    let duration = int((epochTime() - started) * 1000)
    if outcome.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = outcome.output, durationMs = duration)
    if outcome.exitCode != 0:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "recorder command exited with " & $outcome.exitCode, outcome.output,
          durationMs = duration)
      events.add event(if mode == trmRecord: tekRecordFinished else:
          tekRunFinished,
          providerId, runId, testId, some(tsFailed), "failed",
          durationMs = duration)
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "recorder command failed with exit code " & $outcome.exitCode,
            scope.file)],
        value: events)

    let artifacts = nonEmptyTraceArtifacts(outputRoot)
    if artifacts.len == 0:
      events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
          "recorder did not produce a non-empty .ct artifact",
          outcome.output, durationMs = duration)
      events.add event(if mode == trmRecord: tekRecordFinished else:
          tekRunFinished,
          providerId, runId, testId, some(tsErrored), "errored",
          durationMs = duration)
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "recorder did not produce a non-empty .ct artifact",
            scope.file)],
        value: events)

    var metadata = initTable[string, string]()
    metadata["frameworkSelector"] = scope.selector
    metadata["catalogTestId"] = testId
    metadata["recordCommand"] = command
    metadata["artifactSize"] = $getFileSize(artifacts[0])
    metadata["recorderRepo"] = spec.recorderRepo
    let trace = TraceMetadata(
      traceId: splitFile(artifacts[0]).name,
      recordingId: splitFile(artifacts[0]).name,
      path: parentDir(artifacts[0]),
      backend: spec.framework,
      entryPoint: scope.selector,
      metadata: metadata)
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: tekRecordingCreated, providerId: providerId, runId: runId,
        testId: testId, status: none(TestResultStatus), message: "recorded",
        output: "", durationMs: duration, trace: some(trace),
        diagnostic: none(TestDiagnostic))
    events.add event(tekTestFinished, providerId, runId, testId,
        some(tsPassed), "passed", durationMs = duration)
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: if mode == trmRecord: tekRecordFinished else: tekRunFinished,
        providerId: providerId, runId: runId, testId: testId,
        status: some(tsPassed), message: "passed", output: "",
        durationMs: duration, trace: some(trace),
        diagnostic: none(TestDiagnostic))
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc newSmartHarnessProvider*(spec: SmartHarnessSpec): M1Provider =
  ## KNOWN GAP — the registry-stored capabilities are computed with no project
  ## root, and dispatch is gated on them.
  ##
  ## ``providerInfo(spec)`` defaults ``projectRoot`` to ``""``, so the
  ## ``canRunFile``/``canRecordFile`` stored on the provider can only see the
  ## two root-independent ways to reach a recorder: ``<SPEC>_CMD`` and
  ## ``PATH``. ``runRecorderCommand`` re-resolves from ``scope.projectRoot``
  ## and additionally accepts ``<repo>/target/{debug,release}/<binary>`` —
  ## the location ``just build-siblings`` actually produces, and one nothing
  ## in this tree exports as either env var or ``PATH`` entry.
  ##
  ## So a workspace whose recorder was built but never installed yields a
  ## catalog that correctly advertises ``canRunFile: true`` (computed with the
  ## real root) while ``run_orchestration.runUnitOutcome`` consults the stored
  ## value, finds ``false``, and marks every unit *unrunnable* without ever
  ## invoking the provider that would have recorded it.
  ##
  ## Closing it needs a project-root-aware capability hook that the
  ## ``TestProvider`` interface does not have: the registry is built once,
  ## before any workspace is known, and is caller-supplied (a library consumer
  ## may install its own providers), so it cannot simply be rebuilt per run.
  ## Gating dispatch on the *catalog's* capabilities instead would contradict
  ## ``run_orchestration_test``'s "a provider that declares it cannot run is
  ## never dispatched to", which deliberately makes the registered provider the
  ## authority. Left as-is rather than half-fixed — but note it is now at least
  ## *deterministic*: before ``findRecorderRepo`` stopped consulting the
  ## working directory, the stored value additionally varied with where the
  ## shell happened to be.
  var provider = TestProvider(info: providerInfo(spec))
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[],
      value: spec.findRecorderRepo(projectRoot).len > 0)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    smartHarnessProjectCatalog(spec, projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    smartHarnessFileCatalog(spec, projectRoot, file)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    ProviderResult[seq[TestItem]](
      diagnostics: @[],
      value: smartHarnessFileCatalog(spec, projectRoot, file).value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    runRecorderCommand(spec, scope, trmRun)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    runRecorderCommand(spec, scope, trmRecord)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(spec.providerId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @[
      spec.recorderRepo / "README.md",
      spec.recorderRepo / "Justfile",
      spec.recorderRepo / "Cargo.toml"])
