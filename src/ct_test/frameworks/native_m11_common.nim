import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import ../process_exec

proc quoteCommandArg*(value: string): string =
  quoteShell(value)

proc commandLine*(args: seq[string]): string =
  args.mapIt(quoteCommandArg(it)).join(" ")

proc toolAvailable*(name: string): bool =
  findExe(name).len > 0

proc nixAvailable*(): bool =
  findExe("nix").len > 0

proc commandWithNixFallback*(args, nixPackages: seq[string]): string =
  let direct = commandLine(args)
  if args.len > 0 and toolAvailable(args[0]):
    return direct
  if nixPackages.len > 0 and nixAvailable():
    var prefixed = @["nix", "shell"]
    for pkg in nixPackages:
      prefixed.add "nixpkgs#" & pkg
    prefixed.add @["-c", "sh", "-lc", direct]
    return commandLine(prefixed)
  direct

proc missingToolDiagnostic*(tool: string; nixPackages: seq[string];
    file = ""): TestDiagnostic =
  let suffix =
    if nixPackages.len > 0:
      " Install it or run through Nix packages: " &
        nixPackages.mapIt("nixpkgs#" & it).join(" ")
    else:
      " Install it or put it on PATH."
  diagnostic(dsError, tool & " is required but was not found on PATH." & suffix,
      file)

proc event*(
    kind: TestEventKind;
    providerId, runId, testId: string;
    status = none(TestResultStatus);
    message = "";
    output = "";
    durationMs = 0): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: providerId,
    runId: runId,
    testId: testId,
    status: status,
    message: message,
    output: output,
    durationMs: durationMs,
    trace: none(TraceMetadata),
    diagnostic: none(TestDiagnostic))

proc unitOutcomeEvents*(providerId, runId, testId: string; exitCode: int;
    failureMessage: string; output = ""; durationMs = 0): seq[TestEvent] =
  ## The terminal events for a provider that runs one whole unit as a single
  ## subprocess and has nothing but its exit code to go on.
  ##
  ## **``tekTestFinished`` is emitted on BOTH branches, and that is the point.**
  ## ``run_orchestration.summarize`` and
  ## ``certificate_issuance.recordUnitResult`` count ``tekTestFinished`` and
  ## nothing else — ``tekFailure`` and ``tekRunFinished`` are invisible to both.
  ## A failure branch that emitted only those two therefore contributed *zero*
  ## to ``executed`` and zero to ``failed``, so a suite in which every unit
  ## failed reported ``executed 0, failed 0``, took the ``rvNothingExecuted``
  ## verdict and exited ``ExitNothingExecuted`` (2) instead of
  ## ``ExitTestsFailed`` (1). That makes a genuinely failing suite
  ## indistinguishable from one that never ran, which is precisely the
  ## distinction exit code 2 was introduced to draw. ``ruby_common``'s
  ## exit-code fallback and ``js_common`` already emit it; the callers of this
  ## proc did not.
  ##
  ## **Granularity: one event per UNIT, not per test.** These providers run a
  ## whole file (or project) as one subprocess and never see individual test
  ## results, so the single ``tekTestFinished`` here stands for the unit. A
  ## reader expecting one event per test case will not find one, and must not
  ## read the count as a test count. That is the same honest coarse granularity
  ## ``ruby_common``'s minitest branch reports at; making it finer needs
  ## per-test parsing in each runner, which is tracked separately.
  ##
  ## The ``tekFailure`` carries the reason and the captured output where a
  ## human looks for it; the ``tekTestFinished`` beside it is what the counters
  ## read. Both are needed — neither substitutes for the other.
  ##
  ## The predicate is "exit code is exactly zero", NOT "exit code is positive":
  ## ``execCaptured`` — the launch the three C/C++ providers use — reports a
  ## child killed by a signal as ``-1``, because runquota's
  ## ``waitForCompletion`` takes the ``WIFSIGNALED`` branch and leaves the
  ## ``exitCode: -1`` the completion was initialised with. A segfaulting test
  ## binary must land in ``tsFailed``, not ``tsPassed``.
  let status = if exitCode == 0: tsPassed else: tsFailed
  result = @[]
  if exitCode != 0:
    result.add event(tekFailure, providerId, runId, testId, some(status),
        failureMessage, output, durationMs = durationMs)
  result.add event(tekTestFinished, providerId, runId, testId, some(status),
      $status, durationMs = durationMs)
  result.add event(tekRunFinished, providerId, runId, testId, some(status),
      $status, durationMs = durationMs)

proc runCommand*(providerId: string; scope: TestScope; args,
    nixPackages: seq[string]): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if args.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError, "empty test command", scope.file)],
        value: @[])
    if not toolAvailable(args[0]) and not nixAvailable():
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[missingToolDiagnostic(args[0], nixPackages, scope.file)],
        value: @[])

    let
      command = commandWithNixFallback(args, nixPackages)
      runId = providerId & ":" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    var events = @[
      event(tekRunStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    let started = epochTime()
    let outcome = execCapturedShell(command, cwd = scope.projectRoot)
    let duration = int((epochTime() - started) * 1000)
    if outcome.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = outcome.output, durationMs = duration)
    # `go test`, `crystal spec` and `dub test` are each launched once per file
    # or project here and only their exit code is read, so this contributes one
    # unit-level `tekTestFinished` on either branch.
    events.add unitOutcomeEvents(providerId, runId, testId, outcome.exitCode,
        "test command exited with " & $outcome.exitCode, outcome.output,
        duration)
    if outcome.exitCode == 0:
      ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)
    else:
      ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "test execution failed with exit code " & $outcome.exitCode,
            scope.file)],
        value: events)

proc nativeRecorderPrefix*(): seq[string] =
  let configured = getEnv("CODETRACER_CT_MCR_CMD", "")
  if configured.len > 0:
    return @[configured]
  let onPath = findExe("ct-mcr")
  if onPath.len > 0:
    return @[onPath]
  let start = getCurrentDir()
  var dir = start
  while true:
    for sibling in [
      dir / "codetracer-native-recorder" / "ct_cli",
      dir.parentDir / "codetracer-native-recorder" / "ct_cli"]:
      for name in ["ct_cli-debug", "ct_cli"]:
        let path = sibling / name
        if fileExists(path):
          return @[path]
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  @[]

proc nativeRecorderEnvironmentPrefix*(): seq[string] =
  if getEnv("CT_LICENSE_DEV_NO_FFI", "").len > 0:
    @[]
  else:
    @["env", "CT_LICENSE_DEV_NO_FFI=1"]

proc ctFilesUnder(root: string): seq[string] =
  if not dirExists(root):
    return @[]
  for path in walkDirRec(root):
    if fileExists(path) and splitFile(path).ext == ".ct":
      result.add path
  result.sort(system.cmp[string])

proc recordCommand*(providerId: string; scope: TestScope; args,
    nixPackages: seq[string]; entryPoint: string): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    let recorder = nativeRecorderPrefix()
    if recorder.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "ct-mcr native recorder is required for file-level native " &
            "test recording. Set CODETRACER_CT_MCR_CMD or build " &
            "codetracer-native-recorder/ct_cli/ct_cli",
            scope.file)],
        value: @[])
    if args.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError, "empty test command", scope.file)],
        value: @[])

    let
      outputRoot = getTempDir() / ("ct-m11-record-" & $getCurrentProcessId() &
          "-" & $epochTime().int & "-" & $cpuTime())
      tracePath = outputRoot / "file.ct"
      directCommandAvailable = toolAvailable(args[0])
      testCommand = commandWithNixFallback(args, nixPackages)
      traceTargetArgs =
        if directCommandAvailable:
          args
        else:
          @["sh", "-lc", testCommand]
      # ``--interpose`` is the recorder's spelling; ct's own public flag is
      # ``--use-interpose`` and the two must not be confused. ``recorder`` here
      # is ct_cli/ct-mcr, whose parser retired ``--use-interpose`` and rejects
      # unknown options outright
      # (``codetracer-native-recorder/ct_cli/src/ct_cli/arg_parser.nim:695``).
      recordArgs = nativeRecorderEnvironmentPrefix() & recorder & @["record",
          "--interpose", "--source", scope.file, "--output", tracePath,
          "--"] & traceTargetArgs
      command = commandLine(recordArgs)
      runId = providerId & ":record:" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    createDir(outputRoot)

    var events = @[
      event(tekRecordStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    let outcome = execCapturedShell(command, cwd = scope.projectRoot)
    if outcome.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = outcome.output)
    if outcome.exitCode != 0:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "ct-mcr exited with " & $outcome.exitCode, outcome.output)
      events.add event(tekRecordFinished, providerId, runId, testId,
          some(tsFailed), "failed")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "native recording failed with exit code " & $outcome.exitCode,
            scope.file)],
        value: events)

    let traces =
      if fileExists(tracePath): @[tracePath] else: ctFilesUnder(outputRoot)
    if traces.len == 0 or getFileSize(traces[0]) <= 0:
      events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
          "ct-mcr did not produce a non-empty .ct artifact", outcome.output)
      events.add event(tekRecordFinished, providerId, runId, testId,
          some(tsErrored), "errored")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "native recording did not produce a non-empty .ct artifact",
            scope.file)],
        value: events)

    var metadata = initTable[string, string]()
    metadata["frameworkSelector"] = scope.selector
    metadata["catalogTestId"] = testId
    metadata["recordCommand"] = command
    metadata["artifactSize"] = $getFileSize(traces[0])
    let trace = TraceMetadata(
      traceId: splitFile(traces[0]).name,
      recordingId: splitFile(traces[0]).name,
      path: parentDir(traces[0]),
      backend: "native",
      entryPoint: entryPoint,
      metadata: metadata)
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: tekRecordingCreated, providerId: providerId, runId: runId,
        testId: testId, status: none(TestResultStatus), message: "recorded",
        output: "", durationMs: 0, trace: some(trace),
        diagnostic: none(TestDiagnostic))
    events.add event(tekTestFinished, providerId, runId, testId,
        some(tsPassed), "passed")
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: tekRecordFinished, providerId: providerId, runId: runId,
        testId: testId, status: some(tsPassed), message: "passed", output: "",
        durationMs: 0, trace: some(trace), diagnostic: none(TestDiagnostic))
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc parseProviderEventLine*(providerId: string; raw: string): ProviderResult[
    TestEvent] =
  try:
    ProviderResult[TestEvent](diagnostics: @[], value: eventFromJsonLine(raw))
  except CatchableError as err:
    ProviderResult[TestEvent](
      diagnostics: @[diagnostic(dsError,
          providerId & " could not parse normalized event line: " & err.msg)],
      value: TestEvent(schemaVersion: TestEventSchemaVersion,
          providerId: providerId))

proc mapTraceByCatalogId*(catalog: TestCatalog; traces: seq[
    TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] =
  var mapped = initTable[string, TraceMetadata]()
  for trace in traces:
    let catalogId = trace.metadata.getOrDefault("catalogTestId", "")
    if catalogId.len > 0:
      mapped[catalogId] = trace
      continue
    let selector = trace.metadata.getOrDefault("frameworkSelector", "")
    if selector.len == 0:
      continue
    for item in catalog.items:
      if item.selector == selector:
        mapped[item.id] = trace
  ProviderResult[Table[string, TraceMetadata]](diagnostics: @[], value: mapped)
