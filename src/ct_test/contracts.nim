import std/[json, options, strutils, tables]

const
  TestCatalogSchemaVersion* = 1
  TestEventSchemaVersion* = 1

type
  TestItemKind* = enum
    tikSuite = "suite"
    tikCase = "case"
    tikParameterizedCase = "parameterized-case"

  DiagnosticSeverity* = enum
    dsInfo = "info"
    dsWarning = "warning"
    dsError = "error"

  LocationSourceKind* = enum
    lskExternal = "external"
    lskFramework = "framework"
    lskLsp = "lsp"
    lskTreeSitter = "tree-sitter"
    lskParser = "parser"
    lskPattern = "pattern"
    lskFallback = "fallback"

  LocationConfidence* = enum
    lcExact = "exact"
    lcHigh = "high"
    lcMedium = "medium"
    lcLow = "low"
    lcUnknown = "unknown"

  TestRunMode* = enum
    trmRun = "run"
    trmRecord = "record"

  TestScopeKind* = enum
    tskProject = "project"
    tskFile = "file"
    tskSingle = "single"

  TestResultStatus* = enum
    tsPassed = "passed"
    tsFailed = "failed"
    tsSkipped = "skipped"
    tsErrored = "errored"

  TestEventKind* = enum
    tekDiscoveryStarted = "discovery-started"
    tekDiscoveryFinished = "discovery-finished"
    tekRunStarted = "run-started"
    tekRecordStarted = "record-started"
    tekTestStarted = "test-started"
    tekOutput = "output"
    tekFailure = "failure"
    tekCancellation = "cancellation"
    tekTestFinished = "test-finished"
    tekRecordingCreated = "recording-created"
    tekRecordFinished = "record-finished"
    tekRunFinished = "run-finished"
    tekDiagnostic = "diagnostic"

  SourceRange* = object
    startLine*: int
    startColumn*: int
    endLine*: int
    endColumn*: int

  LocationProvenance* = object
    source*: LocationSourceKind
    detail*: string
    confidence*: LocationConfidence

  TestCapabilities* = object
    canDiscoverProject*: bool
    canDiscoverFile*: bool
    canLocateTests*: bool
    canRunProject*: bool
    canRunFile*: bool
    canRunSingle*: bool
    canRecordProject*: bool
    canRecordFile*: bool
    canRecordSingle*: bool
    canCapturePerTestOutput*: bool
    canMapTraceEntryPoints*: bool
    emitsStructuredEvents*: bool

  TestProviderInfo* = object
    id*: string
    language*: string
    framework*: string
    displayName*: string
    version*: string
    capabilities*: TestCapabilities

  TestDiagnostic* = object
    severity*: DiagnosticSeverity
    message*: string
    file*: string
    range*: Option[SourceRange]

  TestItem* = object
    id*: string
    providerId*: string
    language*: string
    framework*: string
    name*: string
    kind*: TestItemKind
    file*: string
    range*: SourceRange
    selector*: string
    parentId*: string
    tags*: seq[string]
    location*: LocationProvenance
    stale*: bool
    staleReason*: string

  TestCatalog* = object
    schemaVersion*: int
    provider*: TestProviderInfo
    items*: seq[TestItem]
    diagnostics*: seq[TestDiagnostic]

  TraceMetadata* = object
    traceId*: string
    recordingId*: string
    path*: string
    backend*: string
    entryPoint*: string
    metadata*: Table[string, string]

  TestEvent* = object
    schemaVersion*: int
    kind*: TestEventKind
    providerId*: string
    runId*: string
    testId*: string
    status*: Option[TestResultStatus]
    message*: string
    output*: string
    durationMs*: int
    trace*: Option[TraceMetadata]
    diagnostic*: Option[TestDiagnostic]

  TestScope* = object
    kind*: TestScopeKind
    projectRoot*: string
    file*: string
    testId*: string
    selector*: string

  TestCommandTemplates* = object
    discoverProject*: string
    discoverFile*: string
    runProject*: string
    runFile*: string
    runSingle*: string
    recordProject*: string
    recordFile*: string
    recordSingle*: string

  LocationSource* = object
    kind*: LocationSourceKind
    command*: string
    grammar*: string
    pattern*: string
    producesExactRanges*: bool
    priority*: int

  AdapterManifest* = object
    id*: string
    language*: string
    framework*: string
    displayName*: string
    supportedVersions*: seq[string]
    fileGlobs*: seq[string]
    projectMarkers*: seq[string]
    commandTemplates*: TestCommandTemplates
    locationSources*: seq[LocationSource]
    capabilities*: TestCapabilities

  ValidationResult* = object
    valid*: bool
    errors*: seq[string]

  ProviderResult*[T] = object
    diagnostics*: seq[TestDiagnostic]
    value*: T

  TestProvider* = object
    info*: TestProviderInfo
    detect*: proc(projectRoot: string): ProviderResult[bool] {.gcsafe.}
    discoverProject*: proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.}
    discoverFile*: proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.}
    locateTests*: proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.}
    run*: proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.}
    record*: proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.}
    parseEvent*: proc(raw: string): ProviderResult[TestEvent] {.gcsafe.}
    mapTraceEntryPoints*: proc(catalog: TestCatalog; traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.}

proc ok*(): ValidationResult =
  ValidationResult(valid: true, errors: @[])

proc fail*(errors: seq[string]): ValidationResult =
  ValidationResult(valid: errors.len == 0, errors: errors)

proc addError(errors: var seq[string]; message: string) =
  errors.add message

proc enumToJson[T: enum](value: T): JsonNode =
  %($value)

proc parseEnumValue[T: enum](raw, field: string): T =
  for value in T:
    if $value == raw:
      return value
  raise newException(ValueError, "invalid " & field & ": " & raw)

proc fieldString(node: JsonNode; name: string; default = ""): string =
  if node.hasKey(name) and node[name].kind != JNull:
    node[name].getStr
  else:
    default

proc fieldInt(node: JsonNode; name: string; default = 0): int =
  if node.hasKey(name) and node[name].kind != JNull:
    node[name].getInt
  else:
    default

proc fieldBool(node: JsonNode; name: string; default = false): bool =
  if node.hasKey(name) and node[name].kind != JNull:
    node[name].getBool
  else:
    default

proc toJson*(range: SourceRange): JsonNode =
  %*{
    "startLine": range.startLine,
    "startColumn": range.startColumn,
    "endLine": range.endLine,
    "endColumn": range.endColumn
  }

proc sourceRangeFromJson*(node: JsonNode): SourceRange =
  SourceRange(
    startLine: node.fieldInt("startLine"),
    startColumn: node.fieldInt("startColumn"),
    endLine: node.fieldInt("endLine"),
    endColumn: node.fieldInt("endColumn"))

proc toJson*(location: LocationProvenance): JsonNode =
  %*{
    "source": location.source.enumToJson,
    "detail": location.detail,
    "confidence": location.confidence.enumToJson
  }

proc locationProvenanceFromJson*(node: JsonNode): LocationProvenance =
  LocationProvenance(
    source: parseEnumValue[LocationSourceKind](node.fieldString("source"), "location source"),
    detail: node.fieldString("detail"),
    confidence: parseEnumValue[LocationConfidence](node.fieldString("confidence"), "location confidence"))

proc toJson*(capabilities: TestCapabilities): JsonNode =
  %*{
    "canDiscoverProject": capabilities.canDiscoverProject,
    "canDiscoverFile": capabilities.canDiscoverFile,
    "canLocateTests": capabilities.canLocateTests,
    "canRunProject": capabilities.canRunProject,
    "canRunFile": capabilities.canRunFile,
    "canRunSingle": capabilities.canRunSingle,
    "canRecordProject": capabilities.canRecordProject,
    "canRecordFile": capabilities.canRecordFile,
    "canRecordSingle": capabilities.canRecordSingle,
    "canCapturePerTestOutput": capabilities.canCapturePerTestOutput,
    "canMapTraceEntryPoints": capabilities.canMapTraceEntryPoints,
    "emitsStructuredEvents": capabilities.emitsStructuredEvents
  }

proc capabilitiesFromJson*(node: JsonNode): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: node.fieldBool("canDiscoverProject"),
    canDiscoverFile: node.fieldBool("canDiscoverFile"),
    canLocateTests: node.fieldBool("canLocateTests"),
    canRunProject: node.fieldBool("canRunProject"),
    canRunFile: node.fieldBool("canRunFile"),
    canRunSingle: node.fieldBool("canRunSingle"),
    canRecordProject: node.fieldBool("canRecordProject"),
    canRecordFile: node.fieldBool("canRecordFile"),
    canRecordSingle: node.fieldBool("canRecordSingle"),
    canCapturePerTestOutput: node.fieldBool("canCapturePerTestOutput"),
    canMapTraceEntryPoints: node.fieldBool("canMapTraceEntryPoints"),
    emitsStructuredEvents: node.fieldBool("emitsStructuredEvents"))

proc toJson*(provider: TestProviderInfo): JsonNode =
  %*{
    "id": provider.id,
    "language": provider.language,
    "framework": provider.framework,
    "displayName": provider.displayName,
    "version": provider.version,
    "capabilities": provider.capabilities.toJson
  }

proc providerInfoFromJson*(node: JsonNode): TestProviderInfo =
  TestProviderInfo(
    id: node.fieldString("id"),
    language: node.fieldString("language"),
    framework: node.fieldString("framework"),
    displayName: node.fieldString("displayName"),
    version: node.fieldString("version"),
    capabilities: capabilitiesFromJson(node["capabilities"]))

proc toJson*(diagnostic: TestDiagnostic): JsonNode =
  result = %*{
    "severity": diagnostic.severity.enumToJson,
    "message": diagnostic.message,
    "file": diagnostic.file
  }
  if diagnostic.range.isSome:
    result["range"] = diagnostic.range.get.toJson
  else:
    result["range"] = newJNull()

proc diagnosticFromJson*(node: JsonNode): TestDiagnostic =
  result = TestDiagnostic(
    severity: parseEnumValue[DiagnosticSeverity](node.fieldString("severity"), "diagnostic severity"),
    message: node.fieldString("message"),
    file: node.fieldString("file"),
    range: none(SourceRange))
  if node.hasKey("range") and node["range"].kind != JNull:
    result.range = some(sourceRangeFromJson(node["range"]))

proc toJson*(item: TestItem): JsonNode =
  %*{
    "id": item.id,
    "providerId": item.providerId,
    "language": item.language,
    "framework": item.framework,
    "name": item.name,
    "kind": item.kind.enumToJson,
    "file": item.file,
    "range": item.range.toJson,
    "selector": item.selector,
    "parentId": item.parentId,
    "tags": item.tags,
    "location": item.location.toJson,
    "stale": item.stale,
    "staleReason": item.staleReason
  }

proc testItemFromJson*(node: JsonNode): TestItem =
  var tags: seq[string] = @[]
  if node.hasKey("tags"):
    for tag in node["tags"]:
      tags.add tag.getStr
  TestItem(
    id: node.fieldString("id"),
    providerId: node.fieldString("providerId"),
    language: node.fieldString("language"),
    framework: node.fieldString("framework"),
    name: node.fieldString("name"),
    kind: parseEnumValue[TestItemKind](node.fieldString("kind"), "test item kind"),
    file: node.fieldString("file"),
    range: sourceRangeFromJson(node["range"]),
    selector: node.fieldString("selector"),
    parentId: node.fieldString("parentId"),
    tags: tags,
    location: locationProvenanceFromJson(node["location"]),
    stale: node.fieldBool("stale"),
    staleReason: node.fieldString("staleReason"))

proc toJson*(catalog: TestCatalog): JsonNode =
  var items = newJArray()
  var diagnostics = newJArray()
  for item in catalog.items:
    items.add item.toJson
  for diagnostic in catalog.diagnostics:
    diagnostics.add diagnostic.toJson
  %*{
    "schemaVersion": catalog.schemaVersion,
    "provider": catalog.provider.toJson,
    "items": items,
    "diagnostics": diagnostics
  }

proc testCatalogFromJson*(node: JsonNode): TestCatalog =
  result = TestCatalog(
    schemaVersion: node.fieldInt("schemaVersion"),
    provider: providerInfoFromJson(node["provider"]),
    items: @[],
    diagnostics: @[])
  for item in node["items"]:
    result.items.add testItemFromJson(item)
  for diagnostic in node["diagnostics"]:
    result.diagnostics.add diagnosticFromJson(diagnostic)

proc toJson*(trace: TraceMetadata): JsonNode =
  var metadata = newJObject()
  for key, value in trace.metadata:
    metadata[key] = %value
  %*{
    "traceId": trace.traceId,
    "recordingId": trace.recordingId,
    "path": trace.path,
    "backend": trace.backend,
    "entryPoint": trace.entryPoint,
    "metadata": metadata
  }

proc traceMetadataFromJson*(node: JsonNode): TraceMetadata =
  result = TraceMetadata(
    traceId: node.fieldString("traceId"),
    recordingId: node.fieldString("recordingId"),
    path: node.fieldString("path"),
    backend: node.fieldString("backend"),
    entryPoint: node.fieldString("entryPoint"),
    metadata: initTable[string, string]())
  if node.hasKey("metadata") and node["metadata"].kind == JObject:
    for key, value in node["metadata"]:
      result.metadata[key] = value.getStr

proc toJson*(event: TestEvent): JsonNode =
  result = %*{
    "schemaVersion": event.schemaVersion,
    "kind": event.kind.enumToJson,
    "providerId": event.providerId,
    "runId": event.runId,
    "testId": event.testId,
    "message": event.message,
    "output": event.output,
    "durationMs": event.durationMs
  }
  if event.status.isSome:
    result["status"] = event.status.get.enumToJson
  else:
    result["status"] = newJNull()
  if event.trace.isSome:
    result["trace"] = event.trace.get.toJson
  else:
    result["trace"] = newJNull()
  if event.diagnostic.isSome:
    result["diagnostic"] = event.diagnostic.get.toJson
  else:
    result["diagnostic"] = newJNull()

proc testEventFromJson*(node: JsonNode): TestEvent =
  result = TestEvent(
    schemaVersion: node.fieldInt("schemaVersion"),
    kind: parseEnumValue[TestEventKind](node.fieldString("kind"), "test event kind"),
    providerId: node.fieldString("providerId"),
    runId: node.fieldString("runId"),
    testId: node.fieldString("testId"),
    status: none(TestResultStatus),
    message: node.fieldString("message"),
    output: node.fieldString("output"),
    durationMs: node.fieldInt("durationMs"),
    trace: none(TraceMetadata),
    diagnostic: none(TestDiagnostic))
  if node.hasKey("status") and node["status"].kind != JNull:
    result.status = some(parseEnumValue[TestResultStatus](node["status"].getStr, "test status"))
  if node.hasKey("trace") and node["trace"].kind != JNull:
    result.trace = some(traceMetadataFromJson(node["trace"]))
  if node.hasKey("diagnostic") and node["diagnostic"].kind != JNull:
    result.diagnostic = some(diagnosticFromJson(node["diagnostic"]))

proc normalizeIdComponent*(value: string): string =
  result = value.strip.toLowerAscii
  result = result.replace("\\", "/")
  result = result.replace(" ", "-")
  result = result.replace("\t", "-")
  while "--" in result:
    result = result.replace("--", "-")

proc makeTestItemId*(providerId, language, framework, file, selector: string): string =
  [
    normalizeIdComponent(providerId),
    normalizeIdComponent(language),
    normalizeIdComponent(framework),
    normalizeIdComponent(file)
  ].join("/") & "::" & normalizeIdComponent(selector)

proc validateSourceRange*(range: SourceRange): ValidationResult =
  var errors: seq[string] = @[]
  if range.startLine < 1:
    errors.addError "source range startLine must be 1-based"
  if range.startColumn < 1:
    errors.addError "source range startColumn must be 1-based"
  if range.endLine < 1:
    errors.addError "source range endLine must be 1-based"
  if range.endColumn < 1:
    errors.addError "source range endColumn must be 1-based"
  if range.endLine < range.startLine:
    errors.addError "source range endLine must not precede startLine"
  if range.endLine == range.startLine and range.endColumn < range.startColumn:
    errors.addError "source range endColumn must not precede startColumn on the same line"
  fail(errors)

proc validateCapabilities*(capabilities: TestCapabilities): ValidationResult =
  var errors: seq[string] = @[]
  if capabilities.canRunSingle and not capabilities.canDiscoverFile and
      not capabilities.canLocateTests:
    errors.addError "single-test execution requires file discovery or location support"
  if capabilities.canRecordSingle and not capabilities.canRunSingle:
    errors.addError "single-test recording requires single-test execution"
  if capabilities.canRecordFile and not capabilities.canRunFile:
    errors.addError "file recording requires file execution"
  if capabilities.canRecordProject and not capabilities.canRunProject:
    errors.addError "project recording requires project execution"
  if capabilities.canMapTraceEntryPoints and not (
      capabilities.canRecordSingle or capabilities.canRecordFile or
      capabilities.canRecordProject):
    errors.addError "trace entry-point mapping requires at least one recording capability"
  fail(errors)

proc validateTestItemId*(id: string): ValidationResult =
  var errors: seq[string] = @[]
  if id.len == 0:
    errors.addError "test item id must not be empty"
  if id.contains(" "):
    errors.addError "test item id must not contain spaces"
  let separator = id.find("::")
  if separator < 1 or separator + 2 >= id.len:
    errors.addError "test item id must contain a provider/file prefix and selector separated by ::"
  fail(errors)

proc validateTestItem*(item: TestItem): ValidationResult =
  var errors: seq[string] = @[]
  for error in validateTestItemId(item.id).errors:
    errors.addError error
  for error in validateSourceRange(item.range).errors:
    errors.addError item.id & ": " & error
  if item.providerId.len == 0:
    errors.addError item.id & ": providerId must not be empty"
  if item.language.len == 0:
    errors.addError item.id & ": language must not be empty"
  if item.framework.len == 0:
    errors.addError item.id & ": framework must not be empty"
  if item.file.len == 0:
    errors.addError item.id & ": file must not be empty"
  if item.selector.len == 0:
    errors.addError item.id & ": selector must not be empty"
  if item.staleReason.len > 0 and not item.stale:
    errors.addError item.id & ": staleReason requires stale=true"
  fail(errors)

proc validateCatalog*(catalog: TestCatalog): ValidationResult =
  var errors: seq[string] = @[]
  if catalog.schemaVersion != TestCatalogSchemaVersion:
    errors.addError "unsupported catalog schemaVersion: " & $catalog.schemaVersion
  if catalog.provider.id.len == 0:
    errors.addError "provider id must not be empty"
  for error in validateCapabilities(catalog.provider.capabilities).errors:
    errors.addError "provider capabilities: " & error
  var seen = initTable[string, bool]()
  for item in catalog.items:
    for error in validateTestItem(item).errors:
      errors.addError error
    if item.providerId != catalog.provider.id:
      errors.addError item.id & ": item providerId does not match catalog provider"
    if seen.hasKey(item.id):
      errors.addError "duplicate test item id: " & item.id
    seen[item.id] = true
  fail(errors)

proc validateEvent*(event: TestEvent): ValidationResult =
  var errors: seq[string] = @[]
  if event.schemaVersion != TestEventSchemaVersion:
    errors.addError "unsupported event schemaVersion: " & $event.schemaVersion
  if event.providerId.len == 0:
    errors.addError "event providerId must not be empty"
  if event.runId.len == 0:
    errors.addError "event runId must not be empty"
  case event.kind
  of tekTestFinished:
    if event.testId.len == 0:
      errors.addError "test-finished event requires testId"
    if event.status.isNone:
      errors.addError "test-finished event requires status"
  of tekOutput:
    if event.testId.len == 0:
      errors.addError "output event requires testId"
    if event.output.len == 0:
      errors.addError "output event requires output"
  of tekFailure:
    if event.message.len == 0 and event.diagnostic.isNone:
      errors.addError "failure event requires message or diagnostic"
  of tekCancellation:
    if event.message.len == 0:
      errors.addError "cancellation event requires message"
  of tekRecordingCreated:
    if event.testId.len == 0:
      errors.addError "recording-created event requires testId"
    if event.trace.isNone:
      errors.addError "recording-created event requires trace metadata"
  of tekRecordFinished:
    if event.testId.len == 0:
      errors.addError "record-finished event requires testId"
    if event.status.isNone:
      errors.addError "record-finished event requires status"
  else:
    discard
  fail(errors)

proc validateLocationSource*(source: LocationSource): ValidationResult =
  var errors: seq[string] = @[]
  if source.priority < 0:
    errors.addError "location source priority must be non-negative"
  case source.kind
  of lskExternal, lskFramework, lskLsp:
    if source.command.len == 0:
      errors.addError $source.kind & " location source requires a command"
  of lskTreeSitter:
    if source.grammar.len == 0:
      errors.addError "tree-sitter location source requires a grammar"
  of lskParser:
    if source.grammar.len == 0 and source.command.len == 0:
      errors.addError "parser location source requires a grammar or command"
  of lskPattern, lskFallback:
    if source.pattern.len == 0:
      errors.addError $source.kind & " location source requires a pattern"
  fail(errors)

proc validateManifest*(manifest: AdapterManifest): ValidationResult =
  var errors: seq[string] = @[]
  if manifest.id.len == 0:
    errors.addError "manifest id must not be empty"
  if manifest.language.len == 0:
    errors.addError "manifest language must not be empty"
  if manifest.framework.len == 0:
    errors.addError "manifest framework must not be empty"
  for error in validateCapabilities(manifest.capabilities).errors:
    errors.addError "manifest capabilities: " & error
  if manifest.locationSources.len == 0:
    errors.addError "manifest must declare at least one location source"
  if manifest.capabilities.canDiscoverProject and
      manifest.commandTemplates.discoverProject.len == 0:
    errors.addError "manifest discoverProject capability requires discoverProject command"
  if manifest.capabilities.canDiscoverFile and
      manifest.commandTemplates.discoverFile.len == 0:
    errors.addError "manifest discoverFile capability requires discoverFile command"
  if manifest.capabilities.canRunProject and
      manifest.commandTemplates.runProject.len == 0:
    errors.addError "manifest runProject capability requires runProject command"
  if manifest.capabilities.canRunFile and
      manifest.commandTemplates.runFile.len == 0:
    errors.addError "manifest runFile capability requires runFile command"
  if manifest.capabilities.canRunSingle and
      manifest.commandTemplates.runSingle.len == 0:
    errors.addError "manifest runSingle capability requires runSingle command"
  if manifest.capabilities.canRecordProject and
      manifest.commandTemplates.recordProject.len == 0:
    errors.addError "manifest recordProject capability requires recordProject command"
  if manifest.capabilities.canRecordFile and
      manifest.commandTemplates.recordFile.len == 0:
    errors.addError "manifest recordFile capability requires recordFile command"
  if manifest.capabilities.canRecordSingle and
      manifest.commandTemplates.recordSingle.len == 0:
    errors.addError "manifest recordSingle capability requires recordSingle command"

  var exactAuthoritativeCount = 0
  var priorities = initTable[int, LocationSourceKind]()
  for source in manifest.locationSources:
    for error in validateLocationSource(source).errors:
      errors.addError "location source " & $source.kind & ": " & error
    if source.producesExactRanges and source.kind in {lskExternal, lskFramework, lskLsp}:
      inc exactAuthoritativeCount
    if priorities.hasKey(source.priority):
      errors.addError "location source priority " & $source.priority & " is ambiguous between " &
        $priorities[source.priority] & " and " & $source.kind
    else:
      priorities[source.priority] = source.kind
  if exactAuthoritativeCount > 1:
    errors.addError "manifest must choose a single exact authoritative location source"
  fail(errors)

proc eventToJsonLine*(event: TestEvent): string =
  $event.toJson

proc eventFromJsonLine*(line: string): TestEvent =
  testEventFromJson(parseJson(line))

proc successful*[T](value: T; diagnostics: seq[TestDiagnostic] = @[]): ProviderResult[T] =
  ProviderResult[T](diagnostics: diagnostics, value: value)
