## Noir provider for `ct test`, driving `nargo test`.
##
## WHY `nargo`, AND NOT THE TRACER WASM MODULES
## --------------------------------------------
## Every non-M13 provider in this framework wraps the language's OWN test
## runner and its own test-declaration syntax — `cargo test` + `#[test]`,
## `go test` + `func TestX`, `pytest`, `node --test`. The M13 recorder
## harnesses (`smart_contract_common`) exist for the opposite case: an
## ecosystem with no native test runner at all, where the only executable
## surface is "hand this fixture file to a recorder CLI and see whether a
## `.ct` artifact falls out". Noir is emphatically in the first group: it has
## `#[test]`, `#[test(should_fail)]`, `#[test(should_fail_with = "…")]`, and a
## `nargo test` that already speaks a JSON Lines event stream. Driving the
## tracer wasm modules instead would answer a different question — *can
## CodeTracer trace Noir?* — and would answer nothing about *which tests does
## this workspace have, and how do I run one?*, which is the question a
## provider exists to answer.
##
## The tracer wasm modules belong to the `record` capability, and this provider
## deliberately does NOT claim it. See `recordUnsupported` below for the trap
## that has to be closed before it can be claimed honestly.
##
## WHAT NOIR GIVES US THAT MOST PROVIDERS DO NOT
## ---------------------------------------------
## `nargo test --format json` emits one JSON object per line
## (`tooling/nargo_cli/src/cli/test_cmd/formatters.rs`, `JsonFormatter`), so
## this provider reports REAL per-test statuses and per-test output rather than
## mapping one process exit code onto every test in the run — which is all
## `native_m11_common.runCommand` can do, and all the Go/D/Crystal providers
## get. That is why `emitsStructuredEvents` and `canCapturePerTestOutput` are
## true here and false almost everywhere else.

import std/[algorithm, json, options, os, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import ../process_exec
import native_m11_common
import noir_test_syntax

# Re-exported wholesale so every existing importer of this module keeps seeing
# `NoirTestDecl`, `sanitizeNoir`, `parseTestAttribute`, `providerInfo`,
# `NoirNargoProviderId` and the rest unchanged. The split is a move, not an
# interface change: `noir_providers_test.nim` compiles against this module
# untouched, which is what makes it a check on the extracted code rather than
# on a copy of it.
export noir_test_syntax

const
  NoirNargoBinary* = "nargo"

  NoirRecordUnsupported* =
    "Noir trace recording is not claimed by the noir-nargo provider: the " &
    "only Noir tracer today is the tooling/tracer_wasm pair, and an " &
    "ordinary compile-then-trace run reports ok from BOTH modules while " &
    "producing a trace of one event and zero steps. Recording must not be " &
    "claimed until the record path asserts a non-trivial trace (steps > 0 " &
    "and calls > 0), not merely a successful exit and a debug_symbols field."

type
  NoirCommandScope* = enum
    ncsProject
    ncsFile
    ncsSingle


  NoirRunSummary* = object
    ## What a parsed `nargo test --format json` stream actually contained.
    ##
    ## Counted rather than inferred, because the whole point of the
    ## non-triviality rule is that "the process exited 0" and "tests ran" are
    ## different facts and a run can have the first without the second.
    finished*: int
    passed*: int
    failed*: int
    skipped*: int
    started*: int
    suiteLines*: int
    unparsedLines*: int


# The source sanitiser, the identifier lexer and the `#[test]` attribute
# parser all moved to `noir_test_syntax.nim`, which imports no `os` and no
# `process_exec` and therefore compiles for a browser. Nothing about them
# changed; see that module's header for why the split is where it is.

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc fileModulePrefix*(projectRoot, filePath: string): seq[string] =
  ## The one native step: `std/os`'s `relativePath`. Everything downstream of
  ## it is in `noir_test_syntax` and runs in a browser too.
  modulePrefixForRelative(normalizedRelative(projectRoot, filePath))

proc parseNoirTestDeclarations*(projectRoot, filePath,
    content: string): seq[NoirTestDecl] =
  ## Kept at its original signature because `noir_providers_test.nim` and the
  ## discovery tests call it this way; the parser itself is shared.
  parseNoirTestDeclarationsRelative(
    normalizedRelative(projectRoot, filePath), content)
# ---------------------------------------------------------------------------
# Provider surface
# ---------------------------------------------------------------------------

proc isNoirFile*(path: string): bool =
  path.endsWith(".nr") and fileExists(path)

proc hasNargoToml*(projectRoot: string): bool =
  dirExists(projectRoot) and fileExists(projectRoot / NoirProjectMarker)

proc isNoirSourceFile*(projectRoot, filePath: string): bool =
  isNoirFile(filePath) and
    normalizedRelative(projectRoot, filePath).startsWith("src/")

proc noirFiles*(projectRoot: string): seq[string] =
  ## `walkWorkspaceFiles`, never `walkDirRec` — docs/ct-test-provider-guide.md
  ## §"Enumerating Workspace Files". A Noir workspace routinely carries a
  ## `target/` directory and vendored git dependencies under `~/.nargo`; the
  ## shared scope keeps both out of every provider at once.
  if not dirExists(projectRoot):
    return @[]
  let sourceRoot = projectRoot / "src"
  if not dirExists(sourceRoot):
    return @[]
  for path in walkWorkspaceFiles(sourceRoot):
    if isNoirFile(path):
      result.add path
  result.sort(system.cmp[string])

# `providerCapabilities` and `providerInfo` moved to `noir_test_syntax`, so a
# browser that discovers tests reports the SAME provider identity a `ct test`
# run does. Re-exported below with the rest of the shared surface.

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: NoirTestDecl): TestItem =
  ## The native wrapper: turn the absolute path into the relative one this
  ## provider has always keyed items by, then defer to the shared builder.
  itemFromDeclRelative(info, normalizedRelative(projectRoot, filePath), decl)

proc readSourceGuarded(path: string; text: var string): bool =
  ## Guarded `readFile`, per docs/ct-test-provider-guide.md: an unreadable
  ## file must not abort a whole workspace discovery. A bare `except:` on
  ## purpose — CONTRIBUTING.md's portability rule — because the failure comes
  ## out of the OS, not out of Nim, and the narrow form is exactly the one
  ## that has already let an exception escape in this repo.
  try:
    text = readFile(path)
    true
  except:
    false

proc noirFileCatalog*(projectRoot, filePath: string): ProviderResult[
    TestCatalog] =
  let info = providerInfo()
  if not isNoirFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Noir .nr source file",
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  if not isNoirSourceFile(projectRoot, filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[],
          diagnostics: @[diagnostic(dsInfo,
              "Noir file is outside the crate's src/ discovery root",
              filePath)]))

  var source = ""
  if not readSourceGuarded(filePath, source):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "Noir source file could not be read; it contributes no catalog " &
          "items", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))

  var items: seq[TestItem] = @[]
  for decl in parseNoirTestDeclarations(projectRoot, filePath, source):
    items.add itemFromDecl(info, projectRoot, filePath, decl)
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in noirFiles(projectRoot):
    let fileResult = noirFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
    for item in fileResult.diagnostics:
      catalog.diagnostics.add item
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc noirProjectCatalog*(projectRoot: string): ProviderResult[TestCatalog] =
  discoverProjectImpl(projectRoot)

proc noirSelectorsForFile*(projectRoot, filePath: string): seq[string] =
  noirFileCatalog(projectRoot, filePath).value.items.mapIt(it.selector)

# ---------------------------------------------------------------------------
# Command construction
# ---------------------------------------------------------------------------

proc buildNargoCommand*(selectors: seq[string];
    scope: NoirCommandScope): seq[string] =
  ## `--format json` is not optional decoration: it is the only reason this
  ## provider can report per-test results at all, so it is part of every
  ## command rather than a flag a caller may forget.
  ##
  ## FILE SCOPE IS AN EXACT LIST, NOT A PREFIX. `nargo test <substring>` is a
  ## `FunctionNameMatch::Contains` over the fully-qualified name, and a file at
  ## the crate root (`src/main.nr`) contributes an EMPTY module prefix — so
  ## the obvious "run the file's module prefix" spelling silently degrades a
  ## file-scoped run into a whole-project run, and reports it as success.
  ## `--exact a b c` is `FunctionNameMatch::Exact(Vec<String>)`, which matches
  ## any of the listed names and nothing else.
  result = @[NoirNargoBinary, "test", "--format", "json", "--show-output"]
  case scope
  of ncsProject:
    discard
  of ncsFile, ncsSingle:
    if selectors.len == 0:
      return @[]
    result.add "--exact"
    result.add selectors

proc parseNargoListTests*(output: string): seq[string] =
  ## `nargo test --list-tests` prints `<package> <fully-qualified name>` per
  ## line. Exposed so a suite can compare this provider's parsed selectors
  ## against nargo's own answer rather than against a second copy of the
  ## parser's beliefs.
  ## The shape is asserted rather than assumed: exactly two whitespace-
  ## separated fields, the second of which is a Noir path — identifiers joined
  ## by `::`. nargo prints compiler warnings above the list, complete with
  ## box-drawing rules and source excerpts, and a looser "take everything
  ## after the last space" rule swallows four of them as if they were test
  ## names. Measured: 11 "selectors" out of a 7-test crate.
  for rawLine in output.splitLines:
    let fields = rawLine.strip.splitWhitespace
    if fields.len != 2:
      continue
    let name = fields[1]
    if name.len == 0 or not isIdentStart(name[0]):
      continue
    var wellFormed = true
    for ch in name:
      if not (isIdentChar(ch) or ch == ':'):
        wellFormed = false
        break
    if wellFormed:
      result.add name
  result.sort(system.cmp[string])

# ---------------------------------------------------------------------------
# Event stream
# ---------------------------------------------------------------------------

proc jsonLineOrNil(line: string): JsonNode =
  ## Bare `except:` on purpose. `parseJson` raises `JsonParsingError` on the C
  ## backend and lets V8's raw `SyntaxError` through on the JS backend, so
  ## `except CatchableError` is not portable — CONTRIBUTING.md, "Code compiled
  ## for both backends". Here it is not hypothetical either: nargo writes
  ## compiler diagnostics and a trailing bare `Error:` to stderr, and
  ## `execCapturedShell` merges stderr into the same stream the JSON Lines
  ## arrive on.
  try:
    let node = parseJson(line)
    if node.kind == JObject: node else: nil
  except:
    nil

proc noirEventsFromOutput*(providerId, runId, output: string;
    summary: var NoirRunSummary): seq[TestEvent] =
  ## Turn one captured `nargo test --format json` stream into normalized
  ## events, and COUNT what it contained.
  ##
  ## The counting is the point. A stream that parsed cleanly and produced zero
  ## test results is not an empty success — it is a run that did not happen,
  ## and it looks exactly like a passing run to anything that consults only
  ## the exit code.
  summary = NoirRunSummary()
  for rawLine in output.splitLines:
    let line = rawLine.strip
    if line.len == 0:
      continue
    let node = jsonLineOrNil(line)
    if node.isNil:
      inc summary.unparsedLines
      continue
    let kind = if node.hasKey("type"): node["type"].getStr else: ""
    if kind != "test":
      inc summary.suiteLines
      continue
    let
      name = if node.hasKey("name"): node["name"].getStr else: ""
      eventName = if node.hasKey("event"): node["event"].getStr else: ""
      stdout = if node.hasKey("stdout"): node["stdout"].getStr else: ""
      durationMs =
        if node.hasKey("exec_time"): int(node["exec_time"].getFloat * 1000.0)
        else: 0
    if name.len == 0 or eventName.len == 0:
      inc summary.unparsedLines
      continue
    case eventName
    of "started":
      inc summary.started
      result.add event(tekTestStarted, providerId, runId, name,
          message = name)
    of "ok":
      inc summary.finished
      inc summary.passed
      if stdout.len > 0:
        result.add event(tekOutput, providerId, runId, name, output = stdout,
            durationMs = durationMs)
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsPassed), "passed", durationMs = durationMs)
    of "failed":
      inc summary.finished
      inc summary.failed
      if stdout.len > 0:
        result.add event(tekOutput, providerId, runId, name, output = stdout,
            durationMs = durationMs)
      result.add event(tekFailure, providerId, runId, name, some(tsFailed),
          if stdout.len > 0: stdout.splitLines[0] else: "nargo reported a failure",
          stdout, durationMs = durationMs)
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsFailed), "failed", durationMs = durationMs)
    of "ignored":
      inc summary.finished
      inc summary.skipped
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsSkipped), "skipped", durationMs = durationMs)
    else:
      inc summary.unparsedLines

proc noirRunResult*(scope: TestScope; command: string; outcome: CapturedRun;
    summary: var NoirRunSummary): ProviderResult[seq[TestEvent]] =
  ## Assemble the run's `ProviderResult` from a captured process outcome.
  ##
  ## Separated from the process launch so the three outcomes that are easy to
  ## get wrong — a truncated capture, a stream with no test results, and a
  ## failing test — are assertable directly on a transcript instead of only
  ## through a subprocess.
  let
    providerId = NoirNargoProviderId
    runId = providerId & ":" & $scope.kind & ":" & scope.selector
    testId = if scope.testId.len > 0: scope.testId else: scope.selector
  var events = @[event(tekRunStarted, providerId, runId, testId,
      message = command)]

  if outcome.truncated:
    # `process_exec.CapturedRun.truncated` exists for exactly this: a
    # line-per-record stream cut at a bound is indistinguishable from a
    # complete short one, and a JSON Lines stream is the most list-shaped
    # output ct_test consumes.
    events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
        "nargo output was truncated at the capture bound; the per-test " &
        "results are a prefix and cannot be trusted", outcome.output,
        durationMs = outcome.durationMs)
    events.add event(tekRunFinished, providerId, runId, testId,
        some(tsErrored), "errored", durationMs = outcome.durationMs)
    summary = NoirRunSummary()
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          "nargo output was truncated at the capture bound", scope.file)],
      value: events)

  events.add noirEventsFromOutput(providerId, runId, outcome.output, summary)

  if summary.finished == 0:
    # NON-TRIVIALITY, ASSERTED BY THE PROVIDER AND NOT LEFT TO THE CALLER.
    # `nargo test` with a selector that matches nothing exits 0 and prints a
    # suite line and no test lines. Reporting that as a pass is how a suite
    # goes green over nothing.
    events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
        "nargo produced no per-test results (" & $summary.suiteLines &
        " suite line(s), " & $summary.unparsedLines & " unparsed line(s), " &
        "exit code " & $outcome.exitCode & "); a run that reports no tests " &
        "is not a passing run", outcome.output,
        durationMs = outcome.durationMs)
    events.add event(tekRunFinished, providerId, runId, testId,
        some(tsErrored), "errored", durationMs = outcome.durationMs)
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          "nargo produced no per-test results", scope.file)],
      value: events)

  let failed = summary.failed > 0
  events.add event(tekRunFinished, providerId, runId, testId,
      if failed: some(tsFailed) else: some(tsPassed),
      if failed: "failed" else: "passed", durationMs = outcome.durationMs)
  if failed:
    ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          $summary.failed & " of " & $summary.finished &
          " Noir test(s) failed", scope.file)],
      value: events)
  else:
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc runNoir(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    let commandScope =
      case scope.kind
      of tskProject: ncsProject
      of tskFile: ncsFile
      of tskSingle: ncsSingle
    let selectors =
      case commandScope
      of ncsProject: @[]
      of ncsFile: noirSelectorsForFile(scope.projectRoot, scope.file)
      of ncsSingle: @[scope.selector]
    let args = buildNargoCommand(selectors, commandScope)
    if args.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "no Noir tests were discovered in this scope, so nothing was " &
            "run; nargo was NOT invoked without a selector, because an " &
            "unselected nargo test runs the whole crate", scope.file)],
        value: @[])
    if not toolAvailable(NoirNargoBinary):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[missingToolDiagnostic(NoirNargoBinary, @[], scope.file)],
        value: @[])
    let command = commandLine(args)
    let outcome = execCapturedShell(command, cwd = scope.projectRoot)
    var summary: NoirRunSummary
    noirRunResult(scope, command, outcome, summary)

proc recordUnsupported(scope: TestScope): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, NoirRecordUnsupported, scope.file)],
    value: @[])

proc mapTraceUnsupported(catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[
    Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning,
        "Noir trace entry-point mapping is unavailable until recording is " &
        "claimed")],
    value: initTable[string, TraceMetadata]())

proc newNoirNargoM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    # A project MARKER, not a content scan — the guide's rule, and the reason
    # this probe costs one `fileExists` per registered workspace.
    ProviderResult[bool](diagnostics: @[], value: hasNargoToml(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    noirFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[
      seq[TestItem]] {.gcsafe.} =
    let catalog = noirFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = runNoir
  provider.record = recordUnsupported
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(NoirNargoProviderId, raw)
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(provider: provider,
      relevantConfigFiles: @["Nargo.toml", "Nargo.lock"])

proc newNoirNargoProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newNoirNargoM1Provider()])
