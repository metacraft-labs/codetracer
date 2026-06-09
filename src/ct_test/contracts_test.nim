import std/[options, tables, unittest]

import contracts

proc baseCapabilities(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: true,
    canRecordProject: true,
    canRecordFile: true,
    canRecordSingle: true,
    canCapturePerTestOutput: true,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: true)

proc providerInfo(id, language, framework: string): TestProviderInfo =
  TestProviderInfo(
    id: id,
    language: language,
    framework: framework,
    displayName: framework,
    version: "0",
    capabilities: baseCapabilities())

proc item(
    providerId, language, framework, file, selector, name: string;
    line: int;
    source = lskFramework;
    confidence = lcExact): TestItem =
  TestItem(
    id: makeTestItemId(providerId, language, framework, file, selector),
    providerId: providerId,
    language: language,
    framework: framework,
    name: name,
    kind: tikCase,
    file: file,
    range: SourceRange(
      startLine: line,
      startColumn: 1,
      endLine: line,
      endColumn: 20),
    selector: selector,
    parentId: "",
    tags: @[],
    location: LocationProvenance(
      source: source,
      detail: "native discovery",
      confidence: confidence))

proc catalog(provider: TestProviderInfo; items: seq[TestItem]): TestCatalog =
  TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: provider,
    items: items,
    diagnostics: @[])

suite "ct-test M0 contracts":
  test "catalog fixtures for supported language styles validate":
    let fixtures = @[
      catalog(
        providerInfo("nim-unittest", "nim", "unittest"),
        @[item("nim-unittest", "nim", "unittest", "tests/test_math.nim", "suite math/test adds", "test adds", 12)]),
      catalog(
        providerInfo("python-pytest", "python", "pytest"),
        @[item("python-pytest", "python", "pytest", "tests/test_math.py", "test_math.py::test_adds", "test_adds", 5)]),
      catalog(
        providerInfo("rust-libtest", "rust", "libtest"),
        @[item("rust-libtest", "rust", "libtest", "src/lib.rs", "math::tests::adds", "adds", 34)]),
      catalog(
        providerInfo("cpp-gtest", "c++", "gtest"),
        @[item("cpp-gtest", "c++", "gtest", "tests/math_test.cpp", "MathTest.Adds", "Adds", 18)])
    ]

    for fixture in fixtures:
      let validation = fixture.validateCatalog
      checkpoint($validation.errors)
      check validation.valid
      check validation.errors.len == 0

  test "item IDs remain stable when discovery order changes":
    let firstOrder = @[
      item("python-pytest", "python", "pytest", "tests/test_math.py", "test_math.py::test_adds", "test_adds", 5),
      item("python-pytest", "python", "pytest", "tests/test_math.py", "test_math.py::test_subtracts", "test_subtracts", 9)
    ]
    let secondOrder = @[firstOrder[1], firstOrder[0]]

    check firstOrder[0].id == secondOrder[1].id
    check firstOrder[1].id == secondOrder[0].id
    check firstOrder[0].id != firstOrder[1].id
    check validateTestItemId(firstOrder[0].id).valid

  test "recording-created and test-finished events round-trip with trace metadata":
    var metadata = initTable[string, string]()
    metadata["frameworkSelector"] = "test_math.py::test_adds"
    metadata["recordCommand"] = "ct test record --test test_math.py::test_adds"
    let trace = TraceMetadata(
      traceId: "trace-1",
      recordingId: "rec-1",
      path: "/tmp/codetracer/rec-1",
      backend: "python",
      entryPoint: "tests/test_math.py:5",
      metadata: metadata)
    let events = @[
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekRecordingCreated,
        providerId: "python-pytest",
        runId: "run-1",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: none(TestResultStatus),
        message: "recorded",
        output: "",
        durationMs: 123,
        trace: some(trace),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekTestFinished,
        providerId: "python-pytest",
        runId: "run-1",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: some(tsPassed),
        message: "passed",
        output: "assertions: 1",
        durationMs: 125,
        trace: some(trace),
        diagnostic: none(TestDiagnostic))
    ]

    for event in events:
      check event.validateEvent.valid
      let decoded = eventFromJsonLine(eventToJsonLine(event))
      check decoded.kind == event.kind
      check decoded.providerId == event.providerId
      check decoded.runId == event.runId
      check decoded.testId == event.testId
      check decoded.durationMs == event.durationMs
      check decoded.trace.isSome
      check decoded.trace.get.recordingId == "rec-1"
      check decoded.trace.get.path == "/tmp/codetracer/rec-1"
      check decoded.trace.get.metadata["frameworkSelector"] == "test_math.py::test_adds"
    let finished = eventFromJsonLine(eventToJsonLine(events[1]))
    check finished.status == some(tsPassed)
    check finished.output == "assertions: 1"

  test "run and record lifecycle events validate and round-trip":
    let diagnostic = TestDiagnostic(
      severity: dsError,
      message: "pytest exited before producing a result",
      file: "tests/test_math.py",
      range: none(SourceRange))
    let events = @[
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekDiscoveryStarted,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "",
        status: none(TestResultStatus),
        message: "discovering",
        output: "",
        durationMs: 0,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekDiscoveryFinished,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "",
        status: none(TestResultStatus),
        message: "2 tests",
        output: "",
        durationMs: 11,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekRunStarted,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "",
        status: none(TestResultStatus),
        message: "running",
        output: "",
        durationMs: 0,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekRecordStarted,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: none(TestResultStatus),
        message: "recording",
        output: "",
        durationMs: 0,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekTestStarted,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: none(TestResultStatus),
        message: "started",
        output: "",
        durationMs: 0,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekOutput,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: none(TestResultStatus),
        message: "stdout",
        output: "captured stdout",
        durationMs: 4,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekFailure,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: some(tsErrored),
        message: "",
        output: "",
        durationMs: 7,
        trace: none(TraceMetadata),
        diagnostic: some(diagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekCancellation,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_subtracts",
        status: none(TestResultStatus),
        message: "cancelled by user",
        output: "",
        durationMs: 8,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekRecordFinished,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "python-pytest/python/pytest/tests/test_math.py::test_math.py::test_adds",
        status: some(tsErrored),
        message: "record failed",
        output: "",
        durationMs: 10,
        trace: none(TraceMetadata),
        diagnostic: some(diagnostic)),
      TestEvent(
        schemaVersion: TestEventSchemaVersion,
        kind: tekRunFinished,
        providerId: "python-pytest",
        runId: "run-2",
        testId: "",
        status: some(tsErrored),
        message: "finished",
        output: "",
        durationMs: 12,
        trace: none(TraceMetadata),
        diagnostic: none(TestDiagnostic))
    ]

    for event in events:
      checkpoint($event.kind)
      check event.validateEvent.valid
      let decoded = eventFromJsonLine(eventToJsonLine(event))
      check decoded.kind == event.kind
      check decoded.providerId == event.providerId
      check decoded.runId == event.runId
      check decoded.testId == event.testId
      check decoded.output == event.output
      check decoded.status == event.status

    var invalidOutput = events[5]
    invalidOutput.output = ""
    check not invalidOutput.validateEvent.valid

    var invalidCancellation = events[7]
    invalidCancellation.message = ""
    check not invalidCancellation.validateEvent.valid

    var invalidRecordFinished = events[8]
    invalidRecordFinished.status = none(TestResultStatus)
    check not invalidRecordFinished.validateEvent.valid

  test "manifest location-source validation rejects invalid and ambiguous config":
    let validManifest = AdapterManifest(
      id: "python-pytest",
      language: "python",
      framework: "pytest",
      displayName: "pytest",
      supportedVersions: @["7", "8"],
      fileGlobs: @["test_*.py", "*_test.py"],
      projectMarkers: @["pytest.ini", "pyproject.toml"],
      commandTemplates: TestCommandTemplates(
        discoverProject: "pytest --collect-only --quiet",
        discoverFile: "pytest --collect-only --quiet {file}",
        runProject: "pytest",
        runFile: "pytest {file}",
        runSingle: "pytest {selector}",
        recordProject: "ct record -- pytest",
        recordFile: "ct record -- pytest {file}",
        recordSingle: "ct record -- pytest {selector}"),
      locationSources: @[
        LocationSource(
          kind: lskFramework,
          command: "pytest --collect-only",
          grammar: "",
          pattern: "",
          producesExactRanges: true,
          priority: 0),
        LocationSource(
          kind: lskTreeSitter,
          command: "",
          grammar: "python",
          pattern: "",
          producesExactRanges: false,
          priority: 1)
      ],
      capabilities: baseCapabilities())

    check validManifest.validateManifest.valid

    var noSources = validManifest
    noSources.locationSources = @[]
    check not noSources.validateManifest.valid

    var ambiguousPriority = validManifest
    ambiguousPriority.locationSources[1].priority = 0
    let ambiguousPriorityValidation = ambiguousPriority.validateManifest
    check not ambiguousPriorityValidation.valid
    check ambiguousPriorityValidation.errors.len > 0

    var ambiguousExact = validManifest
    ambiguousExact.locationSources.add LocationSource(
      kind: lskExternal,
      command: "ct-pytest-adapter locate",
      grammar: "",
      pattern: "",
      producesExactRanges: true,
      priority: 2)
    let ambiguousExactValidation = ambiguousExact.validateManifest
    check not ambiguousExactValidation.valid

    var invalidPattern = validManifest
    invalidPattern.locationSources = @[
      LocationSource(
        kind: lskPattern,
        command: "",
        grammar: "",
        pattern: "",
        producesExactRanges: false,
        priority: 0)
    ]
    let invalidPatternValidation = invalidPattern.validateManifest
    check not invalidPatternValidation.valid
    check invalidPatternValidation.errors.len > 0

    var missingRunSingle = validManifest
    missingRunSingle.commandTemplates.runSingle = ""
    let missingRunSingleValidation = missingRunSingle.validateManifest
    check not missingRunSingleValidation.valid
    check missingRunSingleValidation.errors.len > 0

  test "catalog validation accepts stale markers and rejects inconsistent stale reasons":
    let provider = providerInfo("python-pytest", "python", "pytest")
    var staleItem = item(
      provider.id,
      provider.language,
      provider.framework,
      "tests/test_math.py",
      "test_math.py::test_adds",
      "test_adds",
      5)
    staleItem.stale = true
    staleItem.staleReason = "file changed since last framework-native discovery"

    check catalog(provider, @[staleItem]).validateCatalog.valid

    var inconsistent = staleItem
    inconsistent.stale = false
    let invalidCatalog = catalog(provider, @[inconsistent]).validateCatalog
    check not invalidCatalog.valid
    check invalidCatalog.errors.len > 0

  test "fake provider implements provisional interface and returns normalized catalog and events":
    let provider = TestProvider(
      info: providerInfo("fake-nim", "nim", "unittest"),
      detect: proc(projectRoot: string): ProviderResult[bool] =
        successful(projectRoot.len > 0),
      discoverProject: proc(projectRoot: string): ProviderResult[TestCatalog] =
        let provider = providerInfo("fake-nim", "nim", "unittest")
        successful(catalog(provider, @[
          item(provider.id, provider.language, provider.framework, projectRoot & "/tests/test_fake.nim", "fake suite/test passes", "test passes", 7)
        ])),
      discoverFile: proc(projectRoot, file: string): ProviderResult[TestCatalog] =
        let provider = providerInfo("fake-nim", "nim", "unittest")
        successful(catalog(provider, @[
          item(provider.id, provider.language, provider.framework, file, "fake suite/test passes", "test passes", 7)
        ])),
      locateTests: proc(projectRoot, file: string): ProviderResult[seq[TestItem]] =
        let provider = providerInfo("fake-nim", "nim", "unittest")
        successful(@[
          item(provider.id, provider.language, provider.framework, file, "fake suite/test passes", "test passes", 7,
            source = lskTreeSitter, confidence = lcHigh)
        ]),
      run: proc(scope: TestScope): ProviderResult[seq[TestEvent]] =
        successful(@[
          TestEvent(
            schemaVersion: TestEventSchemaVersion,
            kind: tekTestFinished,
            providerId: "fake-nim",
            runId: "run-fake",
            testId: scope.testId,
            status: some(tsPassed),
            message: "passed",
            output: "OK",
            durationMs: 1,
            trace: none(TraceMetadata),
            diagnostic: none(TestDiagnostic))
        ]),
      record: proc(scope: TestScope): ProviderResult[seq[TestEvent]] =
        var metadata = initTable[string, string]()
        metadata["selector"] = scope.selector
        successful(@[
          TestEvent(
            schemaVersion: TestEventSchemaVersion,
            kind: tekRecordingCreated,
            providerId: "fake-nim",
            runId: "run-fake",
            testId: scope.testId,
            status: none(TestResultStatus),
            message: "recorded",
            output: "",
            durationMs: 2,
            trace: some(TraceMetadata(
              traceId: "trace-fake",
              recordingId: "recording-fake",
              path: "/tmp/recording-fake",
              backend: "nim",
              entryPoint: scope.file & ":7",
              metadata: metadata)),
            diagnostic: none(TestDiagnostic))
        ]),
      parseEvent: proc(raw: string): ProviderResult[TestEvent] =
        successful(eventFromJsonLine(raw)),
      mapTraceEntryPoints: proc(catalog: TestCatalog; traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] =
        var mapped = initTable[string, TraceMetadata]()
        for trace in traces:
          for item in catalog.items:
            if trace.entryPoint == item.file & ":" & $item.range.startLine:
              mapped[item.id] = trace
        successful(mapped))

    check provider.detect("/tmp/project").value

    let discovered = provider.discoverProject("/tmp/project").value
    let discoveredValidation = discovered.validateCatalog
    checkpoint($discoveredValidation.errors)
    check discoveredValidation.valid
    check discovered.items.len == 1
    check discovered.items[0].id == makeTestItemId(
      "fake-nim", "nim", "unittest", "/tmp/project/tests/test_fake.nim", "fake suite/test passes")

    let located = provider.locateTests("/tmp/project", "/tmp/project/tests/test_fake.nim").value
    check located.len == 1
    check located[0].location.source == lskTreeSitter
    check located[0].location.confidence == lcHigh

    let scope = TestScope(
      kind: tskSingle,
      projectRoot: "/tmp/project",
      file: discovered.items[0].file,
      testId: discovered.items[0].id,
      selector: discovered.items[0].selector)
    let runEvents = provider.run(scope).value
    check runEvents.len == 1
    check runEvents[0].validateEvent.valid
    check runEvents[0].status == some(tsPassed)

    let recordEvents = provider.record(scope).value
    check recordEvents.len == 1
    check recordEvents[0].validateEvent.valid
    check recordEvents[0].trace.get.entryPoint == discovered.items[0].file & ":7"

    let parsed = provider.parseEvent(eventToJsonLine(recordEvents[0])).value
    check parsed.trace.get.recordingId == "recording-fake"

    let mapped = provider.mapTraceEntryPoints(discovered, @[recordEvents[0].trace.get]).value
    check mapped.hasKey(discovered.items[0].id)
    check mapped[discovered.items[0].id].traceId == "trace-fake"
