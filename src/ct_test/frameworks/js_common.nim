import std/[
  algorithm, json, options, os, osproc, sequtils, strutils, tables, times
]

import ../contracts
import ../discovery
import ../process_exec

type
  JsFrameworkKind* = enum
    jfkJest
    jfkVitest
    jfkNodeTest

  JsCommandScope* = enum
    jcsProject
    jcsFile
    jcsSingle

  JsTestDeclKind* = enum
    jtdSuite
    jtdCase

  JsTestDecl* = object
    kind*: JsTestDeclKind
    name*: string
    fullName*: string
    line*: int
    column*: int
    endColumn*: int
    tags*: seq[string]
    selector*: string
    parentSelector*: string

  SuiteFrame = object
    name: string
    selector: string
    closeDepth: int

const
  JsExtensions* = [".js", ".cjs", ".mjs", ".ts", ".cts", ".mts", ".jsx", ".tsx"]
  JsTestConfigFiles* = [
    "package.json",
    "jest.config.js",
    "jest.config.cjs",
    "jest.config.mjs",
    "jest.config.ts",
    "vitest.config.js",
    "vitest.config.cjs",
    "vitest.config.mjs",
    "vitest.config.ts",
    "vite.config.js",
    "vite.config.ts",
    "node.config.js",
    "tsconfig.json"
  ]

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isJsFile*(path: string): bool =
  if not fileExists(path):
    return false
  let ext = splitFile(path).ext.toLowerAscii
  ext in JsExtensions

proc isCandidateJsTestFile*(path: string): bool =
  if not isJsFile(path):
    return false
  let name = splitFile(path).name.toLowerAscii & splitFile(
      path).ext.toLowerAscii
  name.endsWith(".test.js") or name.endsWith(".spec.js") or
    name.endsWith(".test.cjs") or name.endsWith(".spec.cjs") or
    name.endsWith(".test.mjs") or name.endsWith(".spec.mjs") or
    name.endsWith(".test.ts") or name.endsWith(".spec.ts") or
    name.endsWith(".test.cts") or name.endsWith(".spec.cts") or
    name.endsWith(".test.mts") or name.endsWith(".spec.mts") or
    name.endsWith(".test.jsx") or name.endsWith(".spec.jsx") or
    name.endsWith(".test.tsx") or name.endsWith(".spec.tsx")

proc jsFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith("node_modules/") or rel.startsWith("dist/") or
        rel.startsWith("build/"):
      continue
    if isCandidateJsTestFile(path):
      result.add path
  result.sort(system.cmp[string])

proc packageJson*(projectRoot: string): JsonNode =
  let path = projectRoot / "package.json"
  if not fileExists(path):
    return newJObject()
  try:
    parseJson(readFile(path))
  except CatchableError:
    newJObject()

proc packageText(projectRoot: string): string =
  let path = projectRoot / "package.json"
  if fileExists(path): readFile(path) else: ""

proc dependencyVersion(pkg: JsonNode; name: string): string =
  for section in ["dependencies", "devDependencies", "peerDependencies",
      "optionalDependencies"]:
    if pkg.hasKey(section) and pkg[section].kind == JObject and pkg[
        section].hasKey(name):
      return pkg[section][name].getStr
  ""

proc scriptMentions(pkg: JsonNode; needle: string): bool =
  if not (pkg.hasKey("scripts") and pkg["scripts"].kind == JObject):
    return false
  for _, value in pkg["scripts"]:
    if value.kind == JString and value.getStr.toLowerAscii.contains(needle):
      return true
  false

proc hasDependency*(projectRoot, name: string): bool =
  packageJson(projectRoot).dependencyVersion(name).len > 0

proc hasJestProject*(projectRoot: string): bool =
  let pkg = packageJson(projectRoot)
  if pkg.dependencyVersion("jest").len > 0 or
      pkg.dependencyVersion("ts-jest").len > 0 or
      pkg.dependencyVersion("@jest/globals").len > 0:
    return true
  if pkg.scriptMentions("jest"):
    return true
  for marker in ["jest.config.js", "jest.config.cjs", "jest.config.mjs",
      "jest.config.ts"]:
    if fileExists(projectRoot / marker):
      return true
  packageText(projectRoot).contains("\"jest\"")

proc hasVitestProject*(projectRoot: string): bool =
  let pkg = packageJson(projectRoot)
  if pkg.dependencyVersion("vitest").len > 0 or pkg.scriptMentions("vitest"):
    return true
  for marker in ["vitest.config.js", "vitest.config.cjs", "vitest.config.mjs",
      "vitest.config.ts"]:
    if fileExists(projectRoot / marker):
      return true
  false

proc hasNodeTestProject*(projectRoot: string): bool =
  let pkg = packageJson(projectRoot)
  if pkg.scriptMentions("node --test") or
      pkg.scriptMentions("node --experimental-test"):
    return true
  if hasJestProject(projectRoot) or hasVitestProject(projectRoot):
    return false
  for path in jsFiles(projectRoot):
    let content = readFile(path)
    if content.contains("'node:test'") or content.contains("\"node:test\"") or
        content.contains("`node:test`"):
      return true
  false

proc lineColumn(content: string; position: int): tuple[line: int; column: int] =
  result = (line: 1, column: 1)
  var i = 0
  while i < position and i < content.len:
    if content[i] == '\n':
      inc result.line
      result.column = 1
    else:
      inc result.column
    inc i

proc maskRange(result: var string; startPos, endPos: int) =
  var i = startPos
  while i < endPos and i < result.len:
    result[i] = if result[i] == '\n': '\n' else: ' '
    inc i

proc sanitizeJs*(content: string): string =
  result = content
  var i = 0
  while i < content.len:
    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '/':
      let start = i
      while i < content.len and content[i] != '\n':
        inc i
      result.maskRange(start, i)
      continue
    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '*':
      let start = i
      i += 2
      while i + 1 < content.len and
          not (content[i] == '*' and content[i + 1] == '/'):
        inc i
      if i + 1 < content.len:
        i += 2
      result.maskRange(start, i)
      continue
    if content[i] in {'"', '\''}:
      let quote = content[i]
      let start = i
      inc i
      while i < content.len:
        if content[i] == '\\':
          i += 2
        elif content[i] == quote:
          inc i
          break
        else:
          inc i
      result.maskRange(start, i)
      continue
    if content[i] == '`':
      let start = i
      inc i
      while i < content.len:
        if content[i] == '\\':
          i += 2
        elif content[i] == '`':
          inc i
          break
        else:
          inc i
      result.maskRange(start, i)
      continue
    inc i

proc isIdentStart(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '_', '$'}

proc isIdentChar(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}

proc skipSpaces(content: string; pos: var int) =
  while pos < content.len and content[pos] in {' ', '\t', '\r', '\n'}:
    inc pos

proc readIdent(content: string; pos: var int): string =
  if pos >= content.len or not isIdentStart(content[pos]):
    return ""
  let start = pos
  inc pos
  while pos < content.len and isIdentChar(content[pos]):
    inc pos
  content[start ..< pos]

proc readCallee(sanitized: string; pos: int): tuple[name: string; tags: seq[
    string]; openParen: int; endPos: int] =
  var i = pos
  let base = readIdent(sanitized, i)
  if base notin ["test", "it", "describe"]:
    return ("", @[], -1, pos)
  var tags: seq[string] = @[]
  while true:
    skipSpaces(sanitized, i)
    if i >= sanitized.len or sanitized[i] != '.':
      break
    inc i
    skipSpaces(sanitized, i)
    let suffix = readIdent(sanitized, i)
    if suffix.len == 0:
      break
    tags.add suffix
    if suffix == "each":
      skipSpaces(sanitized, i)
      if i < sanitized.len and sanitized[i] in {'(', '['}:
        let open = sanitized[i]
        let close = if open == '(': ')' else: ']'
        var depth = 1
        inc i
        while i < sanitized.len and depth > 0:
          if sanitized[i] == open:
            inc depth
          elif sanitized[i] == close:
            dec depth
          inc i
  skipSpaces(sanitized, i)
  if i >= sanitized.len or sanitized[i] != '(':
    return ("", @[], -1, pos)
  (base, tags, i, i + 1)

proc readStringAt(content: string; pos: var int): string =
  skipSpaces(content, pos)
  if pos >= content.len or content[pos] notin {'"', '\'', '`'}:
    return ""
  let quote = content[pos]
  inc pos
  var value = ""
  while pos < content.len:
    if content[pos] == '\\':
      inc pos
      if pos < content.len:
        value.add content[pos]
        inc pos
      continue
    if content[pos] == quote:
      inc pos
      return value
    if quote == '`' and content[pos] == '$' and pos + 1 < content.len and
        content[pos + 1] == '{':
      return ""
    value.add content[pos]
    inc pos
  ""

proc braceDelta(line: string): int =
  for ch in line:
    if ch == '{':
      inc result
    elif ch == '}':
      dec result

proc selectorFrom(relative: string; names: seq[string]): string =
  relative & "::" & names.join(" > ")

proc parseJsTestDeclarations*(
    projectRoot, filePath, content: string): seq[JsTestDecl] =
  let
    sanitized = sanitizeJs(content)
    relative = normalizedRelative(projectRoot, filePath)
  var
    suites: seq[SuiteFrame] = @[]
    braceDepth = 0
    offset = 0
  for line in sanitized.splitLines:
    while suites.len > 0 and braceDepth < suites[^1].closeDepth:
      discard suites.pop()
    var i = 0
    while i < line.len:
      if isIdentStart(line[i]) and (i == 0 or not isIdentChar(line[i - 1])):
        let absolutePos = offset + i
        let callee = readCallee(sanitized, absolutePos)
        if callee.name.len > 0:
          var argPos = callee.openParen + 1
          let name = readStringAt(content, argPos)
          if name.len > 0:
            let
              location = lineColumn(content, absolutePos)
              activeNames = suites.mapIt(it.name)
              kind = if callee.name == "describe": jtdSuite else: jtdCase
              names = activeNames & @[name]
              selector = selectorFrom(relative, names)
              parentSelector =
                if activeNames.len > 0: selectorFrom(relative,
                    activeNames) else: ""
            var tags = @["javascript", "typescript"]
            tags.add callee.tags
            result.add JsTestDecl(
              kind: kind,
              name: name,
              fullName: names.join(" > "),
              line: location.line,
              column: location.column,
              endColumn: location.column + callee.name.len - 1,
              tags: tags,
              selector: selector,
              parentSelector: parentSelector)
            if kind == jtdSuite:
              let rest = line[i .. ^1]
              if rest.contains("{"):
                suites.add SuiteFrame(name: name, selector: selector,
                    closeDepth: braceDepth + 1)
          i = max(i + 1, callee.endPos - offset)
          continue
      inc i
    braceDepth += braceDelta(line)
    offset += line.len + 1

proc buildJsCommand*(kind: JsFrameworkKind; projectRoot, filePath,
    fullName: string; scope: JsCommandScope): seq[string] =
  let relative = if filePath.len > 0: normalizedRelative(projectRoot,
      filePath) else: ""
  case kind
  of jfkJest:
    result = @["npx", "jest", "--runInBand"]
    case scope
    of jcsProject:
      discard
    of jcsFile:
      result.add @["--runTestsByPath", relative]
    of jcsSingle:
      result.add @["--runTestsByPath", relative, "--testNamePattern", fullName]
  of jfkVitest:
    result = @["npx", "vitest", "run"]
    case scope
    of jcsProject:
      discard
    of jcsFile:
      result.add relative
    of jcsSingle:
      result.add @[relative, "-t", fullName]
  of jfkNodeTest:
    result = @["node", "--test"]
    case scope
    of jcsProject:
      discard
    of jcsFile:
      result.add relative
    of jcsSingle:
      result.add @["--test-name-pattern", fullName, relative]

proc jsFullNameFromSelector*(selector: string): string =
  let marker = selector.find("::")
  if marker < 0:
    return selector
  selector[(marker + 2) .. ^1].replace(" > ", " ")

proc commandLine(args: seq[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

proc event(
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

proc executableAvailable(name: string): bool =
  findExe(name).len > 0

proc jsRecorderCommandPrefix(): seq[string] =
  let configured = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if configured.len > 0:
    return @[configured]

  let onPath = findExe("codetracer-js-recorder")
  if onPath.len > 0:
    return @[onPath]

  let siblingCli = getCurrentDir().parentDir / "codetracer-js-recorder" /
      "packages" / "cli" / "dist" / "index.js"
  if fileExists(siblingCli) and executableAvailable("node"):
    return @["node", siblingCli]

  @[]

proc ctFilesUnder(root: string): seq[string] =
  if not dirExists(root):
    return @[]
  for path in walkDirRec(root):
    if fileExists(path) and splitFile(path).ext == ".ct":
      result.add path
  result.sort(system.cmp[string])

proc selectedSingleCaseOnly(projectRoot, filePath, selector: string): bool =
  let catalog =
    parseJsTestDeclarations(projectRoot, filePath, readFile(filePath))
  var caseCount = 0
  var selectedIsCase = false
  for decl in catalog:
    if decl.kind == jtdCase:
      inc caseCount
      if decl.selector == selector:
        selectedIsCase = true
  selectedIsCase and caseCount == 1

proc runNodeTestCommand*(providerId: string; scope: TestScope): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if not executableAvailable("node"):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Node.js is required for node:test execution but was not found " &
            "on PATH",
            scope.file)],
        value: @[])

    let
      commandScope =
        case scope.kind
        of tskProject: jcsProject
        of tskFile: jcsFile
        of tskSingle: jcsSingle
      fullName = jsFullNameFromSelector(scope.selector)
      args = buildJsCommand(jfkNodeTest, scope.projectRoot, scope.file,
          fullName, commandScope)
      runId = providerId & ":" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
      command = commandLine(args)

    var events = @[
      event(tekRunStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    let result = execCapturedShell(command, cwd = scope.projectRoot)
    if result.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = result.output)

    if result.exitCode == 0:
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)
    else:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "node --test exited with " & $result.exitCode, result.output)
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "node:test execution failed with exit code " & $result.exitCode,
            scope.file)],
        value: events)

proc recordNodeTestCommand*(providerId: string;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if scope.kind != tskSingle:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "node:test M7 recording supports single-test scopes only",
            scope.file)],
        value: @[])

    if not fileExists(scope.file):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "node:test recording file does not exist: " & scope.file,
            scope.file)],
        value: @[])

    let ext = splitFile(scope.file).ext.toLowerAscii
    if ext in [".ts", ".tsx", ".mts", ".cts"]:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "node:test TypeScript recording requires a loader/sourcemap " &
            "adapter and is not enabled in M7",
            scope.file)],
        value: @[])

    if not selectedSingleCaseOnly(scope.projectRoot, scope.file,
        scope.selector):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "node:test M7 recording uses the JS recorder entry-file path " &
            "and only records selectors from single-case files; " &
            "multi-test file filtering is a follow-up",
            scope.file)],
        value: @[])

    let recorderPrefix = jsRecorderCommandPrefix()
    if recorderPrefix.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "codetracer-js-recorder is required for node:test recording. " &
            "Set CODETRACER_JS_RECORDER_PATH or put codetracer-js-recorder " &
            "on PATH",
            scope.file)],
        value: @[])

    let
      runId = providerId & ":record:" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
      outputRoot = getTempDir() / ("ct-node-test-record-" &
          $getCurrentProcessId() & "-" & $epochTime().int & "-" & $cpuTime())
      args = recorderPrefix & @["record", scope.file, "--out-dir", outputRoot]
      command = commandLine(args)

    createDir(outputRoot)

    var events = @[
      event(tekRecordStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]

    let result = execCapturedShell(command, cwd = scope.projectRoot)
    if result.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = result.output)

    if result.exitCode != 0:
      events.add event(
        tekFailure,
        providerId,
        runId,
        testId,
        some(tsFailed),
        "codetracer-js-recorder exited with " & $result.exitCode,
        result.output)
      events.add event(tekRecordFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "node:test recording failed with exit code " & $result.exitCode,
            scope.file)],
        value: events)

    let traces = ctFilesUnder(outputRoot)
    if traces.len == 0 or getFileSize(traces[0]) <= 0:
      events.add event(
        tekFailure,
        providerId,
        runId,
        testId,
        some(tsErrored),
        "codetracer-js-recorder did not produce a non-empty .ct artifact",
        result.output)
      events.add event(tekRecordFinished, providerId, runId, testId, some(
          tsErrored), "errored")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "node:test recording did not produce a non-empty .ct artifact",
            scope.file)],
        value: events)

    var metadata = initTable[string, string]()
    metadata["frameworkSelector"] = scope.selector
    metadata["recordCommand"] = command
    metadata["artifactSize"] = $getFileSize(traces[0])
    let traceDir = parentDir(traces[0])
    let trace = TraceMetadata(
      traceId: splitPath(traceDir).tail,
      recordingId: splitPath(traceDir).tail,
      path: traceDir,
      backend: "javascript",
      entryPoint: normalizedRelative(scope.projectRoot, scope.file),
      metadata: metadata)

    events.add TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: tekRecordingCreated,
      providerId: providerId,
      runId: runId,
      testId: testId,
      status: none(TestResultStatus),
      message: "recorded",
      output: "",
      durationMs: 0,
      trace: some(trace),
      diagnostic: none(TestDiagnostic))
    events.add event(
      tekTestFinished, providerId, runId, testId, some(tsPassed), "passed")
    events.add TestEvent(
      schemaVersion: TestEventSchemaVersion,
      kind: tekRecordFinished,
      providerId: providerId,
      runId: runId,
      testId: testId,
      status: some(tsPassed),
      message: "passed",
      output: "",
      durationMs: 0,
      trace: some(trace),
      diagnostic: none(TestDiagnostic))
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc unsupportedRecord*(providerId, milestone: string;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, providerId &
        " trace recording is not wired in " & milestone &
        "; command construction is tested for run-only support", scope.file)],
    value: @[])

proc unsupportedRun*(providerId, milestone: string;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, providerId &
        " process execution and event parsing are not wired in " & milestone &
        "; command construction is tested", scope.file)],
    value: @[])

proc parseEventUnsupported*(providerId, milestone: string): ProviderResult[
    TestEvent] {.gcsafe.} =
  ProviderResult[TestEvent](
    diagnostics: @[diagnostic(dsWarning, providerId &
        " event parsing is not implemented in " & milestone)],
    value: TestEvent(schemaVersion: TestEventSchemaVersion,
        providerId: providerId))

proc mapTraceUnsupported*(
    providerId, milestone: string;
    catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string,
        TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning, providerId &
        " trace entry-point mapping is not implemented in " & milestone)],
    value: initTable[string, TraceMetadata]())
