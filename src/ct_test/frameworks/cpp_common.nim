import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import ../process_exec
import native_m11_common as nativeM11

type
  CppFrameworkKind* = enum
    cfkGoogleTest
    cfkCatch2
    cfkCTest

  CppCommandScope* = enum
    ccsProject
    ccsFile
    ccsSingle

  CppTestDeclKind* = enum
    ctdCase
    ctdSuite
    ctdSection
    ctdExecutable

  CppTestDecl* = object
    kind*: CppTestDeclKind
    macroName*: string
    suite*: string
    name*: string
    selector*: string
    parentSelector*: string
    line*: int
    column*: int
    endLine*: int
    endColumn*: int
    tags*: seq[string]
    reconciled*: bool

  CTestDecl* = object
    name*: string
    command*: seq[string]
    line*: int

const
  CppConfigFiles* = [
    "CMakeLists.txt",
    "CTestTestfile.cmake",
    "compile_commands.json",
    "build/CTestTestfile.cmake"
  ]

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isCppFile*(path: string): bool =
  if not fileExists(path):
    return false
  splitFile(path).ext.toLowerAscii in [
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"]

proc cppFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith("build/") or rel.startsWith(".git/") or
        rel.startsWith("cmake-build-"):
      continue
    if isCppFile(path):
      result.add path
  result.sort(system.cmp[string])

proc readProjectFile(projectRoot, relative: string): string =
  let path = projectRoot / relative
  if fileExists(path): readFile(path) else: ""

proc hasCMakeProject*(projectRoot: string): bool =
  fileExists(projectRoot / "CMakeLists.txt")

proc textMentionsAny(text: string; needles: openArray[string]): bool =
  let lower = text.toLowerAscii
  for needle in needles:
    if lower.contains(needle.toLowerAscii):
      return true
  false

proc hasGoogleTestProject*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  let cmake = readProjectFile(projectRoot, "CMakeLists.txt")
  if cmake.textMentionsAny(["gtest", "gmock", "GoogleTest", "gtest_discover_tests"]):
    return true
  for path in cppFiles(projectRoot):
    let text = readFile(path)
    if text.contains("#include <gtest/") or text.contains("#include \"gtest/") or
        text.contains("TEST(") or text.contains("TEST_F(") or text.contains("TEST_P("):
      return true
  false

proc hasCatch2Project*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  let cmake = readProjectFile(projectRoot, "CMakeLists.txt")
  if cmake.textMentionsAny(["Catch2", "catch_discover_tests"]):
    return true
  for path in cppFiles(projectRoot):
    let text = readFile(path)
    if text.contains("#include <catch2/") or text.contains("#include \"catch2/") or
        text.contains("TEST_CASE(") or text.contains("SCENARIO("):
      return true
  false

proc hasCTestProject*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  fileExists(projectRoot / "CTestTestfile.cmake") or
    fileExists(projectRoot / "build" / "CTestTestfile.cmake") or
    readProjectFile(projectRoot, "CMakeLists.txt").textMentionsAny([
      "enable_testing", "add_test"])

proc maskRange(result: var string; content: string; startPos, endPos: int) =
  var i = startPos
  while i < endPos and i < content.len:
    result[i] = if content[i] == '\n': '\n' else: ' '
    inc i

proc sanitizeCpp*(content: string): string =
  result = content
  var i = 0
  while i < content.len:
    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '/':
      let start = i
      while i < content.len and content[i] != '\n':
        inc i
      result.maskRange(content, start, i)
      continue
    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '*':
      let start = i
      i += 2
      while i + 1 < content.len and not (content[i] == '*' and content[i + 1] == '/'):
        inc i
      if i + 1 < content.len:
        i += 2
      result.maskRange(content, start, i)
      continue
    if content[i] == '"' or content[i] == '\'':
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
      result.maskRange(content, start, i)
      continue
    inc i

proc lineColumnAt(content: string; pos: int): tuple[line: int; column: int] =
  result = (1, 1)
  var i = 0
  while i < pos and i < content.len:
    if content[i] == '\n':
      inc result.line
      result.column = 1
    else:
      inc result.column
    inc i

proc isIdentChar(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc macroStartAt(content, macroName: string; pos: int): bool =
  if pos + macroName.len >= content.len:
    return false
  if not content.continuesWith(macroName, pos):
    return false
  if pos > 0 and isIdentChar(content[pos - 1]):
    return false
  var i = pos + macroName.len
  while i < content.len and content[i] in {' ', '\t', '\n', '\r'}:
    inc i
  i < content.len and content[i] == '('

proc parenOpenAfter(content: string; pos: int): int =
  var i = pos
  while i < content.len and content[i] != '(':
    inc i
  if i < content.len: i else: -1

proc findClosingParen(content: string; openPos: int): int =
  var
    i = openPos
    depth = 0
  while i < content.len:
    if content[i] == '(':
      inc depth
    elif content[i] == ')':
      dec depth
      if depth == 0:
        return i
    inc i
  content.len - 1

proc splitTopLevelArgs(raw: string): seq[string] =
  var
    current = ""
    depth = 0
    quote = '\0'
    i = 0
  while i < raw.len:
    let ch = raw[i]
    if quote != '\0':
      current.add ch
      if ch == '\\' and i + 1 < raw.len:
        inc i
        current.add raw[i]
      elif ch == quote:
        quote = '\0'
    else:
      case ch
      of '"', '\'':
        quote = ch
        current.add ch
      of '(', '[', '{':
        inc depth
        current.add ch
      of ')', ']', '}':
        if depth > 0:
          dec depth
        current.add ch
      of ',':
        if depth == 0:
          result.add current.strip
          current = ""
        else:
          current.add ch
      else:
        current.add ch
    inc i
  if current.strip.len > 0:
    result.add current.strip

proc unquoteCppString(raw: string): string =
  let value = raw.strip
  if value.len >= 2 and value[0] == '"' and value[^1] == '"':
    var i = 1
    while i < value.len - 1:
      if value[i] == '\\' and i + 1 < value.len - 1:
        inc i
      result.add value[i]
      inc i
  else:
    result = value

proc parseMacroCalls(
    content: string;
    macroNames: openArray[string]): seq[tuple[macroName: string; args: seq[string]; startPos: int; endPos: int]] =
  let sanitized = sanitizeCpp(content)
  var i = 0
  while i < sanitized.len:
    var matched = ""
    for macroName in macroNames:
      if macroStartAt(sanitized, macroName, i):
        matched = macroName
        break
    if matched.len == 0:
      inc i
      continue
    let openPos = parenOpenAfter(sanitized, i + matched.len)
    let closePos = findClosingParen(sanitized, openPos)
    if openPos >= 0 and closePos >= openPos:
      result.add (matched, splitTopLevelArgs(content[openPos + 1 ..< closePos]), i, closePos + 1)
      i = closePos + 1
    else:
      inc i

proc parseGoogleTestDeclarations*(content: string): seq[CppTestDecl] =
  for call in parseMacroCalls(content, ["TEST", "TEST_F", "TEST_P"]):
    if call.args.len < 2:
      continue
    let
      suiteName = call.args[0].strip
      testName = call.args[1].strip
      startLoc = lineColumnAt(content, call.startPos)
      endLoc = lineColumnAt(content, call.endPos)
    result.add CppTestDecl(
      kind: if call.macroName == "TEST_P": ctdCase else: ctdCase,
      macroName: call.macroName,
      suite: suiteName,
      name: testName,
      selector: suiteName & "." & testName,
      parentSelector: suiteName,
      line: startLoc.line,
      column: startLoc.column,
      endLine: endLoc.line,
      endColumn: endLoc.column,
      tags: @[call.macroName.toLowerAscii],
      reconciled: false)

proc parseCatch2Declarations*(content: string): seq[CppTestDecl] =
  var lastCaseSelector = ""
  for call in parseMacroCalls(content, ["TEST_CASE", "SCENARIO", "SECTION"]):
    if call.args.len < 1:
      continue
    let
      name = unquoteCppString(call.args[0])
      tags = if call.args.len >= 2: @[unquoteCppString(call.args[1])] else: @[]
      startLoc = lineColumnAt(content, call.startPos)
      endLoc = lineColumnAt(content, call.endPos)
      isSection = call.macroName == "SECTION"
      selector = if isSection: lastCaseSelector & " / " & name else: name
    result.add CppTestDecl(
      kind: if isSection: ctdSection else: ctdCase,
      macroName: call.macroName,
      suite: "",
      name: name,
      selector: selector,
      parentSelector: if isSection: lastCaseSelector else: "",
      line: startLoc.line,
      column: startLoc.column,
      endLine: endLoc.line,
      endColumn: endLoc.column,
      tags: @["catch2", call.macroName.toLowerAscii] & tags,
      reconciled: false)
    if not isSection:
      lastCaseSelector = selector

proc parseGTestListOutput*(raw: string): seq[string] =
  var suite = ""
  for line in raw.splitLines:
    if line.len == 0 or line.startsWith("Running ") or line.startsWith("Listing "):
      continue
    if not line.startsWith(" ") and line.endsWith("."):
      suite = line[0 ..< line.len - 1].strip
    elif suite.len > 0:
      let testName = line.strip.split(" ")[0]
      if testName.len > 0:
        result.add suite & "." & testName

proc parseCatch2ListOutput*(raw: string): seq[string] =
  var inTests = false
  for line in raw.splitLines:
    let stripped = line.strip
    if stripped.len == 0:
      continue
    if stripped.startsWith("All available test cases:"):
      inTests = true
      continue
    if stripped.startsWith("Matching test cases:"):
      inTests = true
      continue
    if stripped.endsWith("test cases") or stripped.endsWith("test case"):
      continue
    if inTests and not stripped.startsWith("[") and
        not stripped.startsWith("~") and not stripped.contains(" tags"):
      result.add stripped

proc parseCTestListOutput*(raw: string): seq[string] =
  for line in raw.splitLines:
    let stripped = line.strip
    if stripped.startsWith("Test #"):
      let colon = stripped.find(":")
      if colon >= 0 and colon + 1 < stripped.len:
        result.add stripped[colon + 1 .. ^1].strip

proc ctestFilePath(projectRoot: string): string =
  if fileExists(projectRoot / "build" / "CTestTestfile.cmake"):
    projectRoot / "build" / "CTestTestfile.cmake"
  else:
    projectRoot / "CTestTestfile.cmake"

proc tokenizeCMakeArgs(raw: string): seq[string] =
  var
    current = ""
    quote = '\0'
    i = 0
  while i < raw.len:
    let ch = raw[i]
    if quote != '\0':
      if ch == quote:
        quote = '\0'
      else:
        current.add ch
    else:
      if raw.continuesWith("[=[", i):
        i += 3
        while i + 2 < raw.len and not raw.continuesWith("]=]", i):
          current.add raw[i]
          inc i
        if i + 2 < raw.len:
          i += 3
          continue
      case ch
      of '"', '\'':
        quote = ch
      of ' ', '\t', '\r', '\n':
        if current.len > 0:
          result.add current
          current = ""
      else:
        current.add ch
    inc i
  if current.len > 0:
    result.add current

proc parseCTestTestfile*(path: string): seq[CTestDecl] =
  if not fileExists(path):
    return @[]
  var lineNo = 0
  for line in readFile(path).splitLines:
    inc lineNo
    let stripped = line.strip
    if not stripped.startsWith("add_test("):
      continue
    let closePos = stripped.rfind(")")
    if closePos < 0:
      continue
    let args = tokenizeCMakeArgs(stripped["add_test(".len ..< closePos])
    if args.len >= 2:
      if args[0].toUpperAscii == "NAME":
        let commandStart = args.find("COMMAND")
        if commandStart >= 0 and commandStart + 1 < args.len:
          result.add CTestDecl(name: args[1], command: args[commandStart + 1 .. ^1],
              line: lineNo)
      else:
        result.add CTestDecl(name: args[0], command: args[1 .. ^1], line: lineNo)

proc findBuiltExecutable*(projectRoot: string; hint = ""): string =
  let roots = @[projectRoot / "build", projectRoot]
  for root in roots:
    if not dirExists(root):
      continue
    for path in walkDirRec(root):
      if fileExists(path) and path.splitFile.ext == "" and
          (hint.len == 0 or splitPath(path).tail.contains(hint)):
        when defined(posix):
          if (getFilePermissions(path) * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0:
            return path
        else:
          return path
  ""

proc commandLine*(args: seq[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

proc buildCppCommand*(kind: CppFrameworkKind; projectRoot, filePath,
    selector: string; scope: CppCommandScope): seq[string] =
  case kind
  of cfkGoogleTest:
    let exe = findBuiltExecutable(projectRoot, "test")
    result = @[if exe.len > 0: exe else: "<gtest-executable>"]
    case scope
    of ccsProject:
      discard
    of ccsFile:
      result.add "--gtest_filter=*"
    of ccsSingle:
      result.add "--gtest_filter=" & selector
  of cfkCatch2:
    let exe = findBuiltExecutable(projectRoot, "test")
    result = @[if exe.len > 0: exe else: "<catch2-executable>"]
    case scope
    of ccsProject:
      discard
    of ccsFile:
      discard
    of ccsSingle:
      result.add selector
  of cfkCTest:
    result = @["ctest", "--test-dir", projectRoot / "build", "--output-on-failure"]
    case scope
    of ccsProject, ccsFile:
      discard
    of ccsSingle:
      result.add @["-R", "^" & selector & "$"]

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

proc runNativeCommand*(providerId: string; kind: CppFrameworkKind;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    let commandScope =
      case scope.kind
      of tskProject: ccsProject
      of tskFile: ccsFile
      of tskSingle: ccsSingle
    var args = buildCppCommand(kind, scope.projectRoot, scope.file,
        scope.selector, commandScope)
    if args.len == 0 or args[0].startsWith("<"):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "native test executable is required but was not found under the project build directory",
            scope.file)],
        value: @[])
    if kind == cfkCTest and findExe("ctest").len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "ctest is required for CTest execution but was not found on PATH",
            scope.file)],
        value: @[])

    let
      command = commandLine(args)
      runId = providerId & ":" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    var events = @[
      event(tekRunStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    # Route the launch through the shared runner (runquota_process) rather than
    # std/osproc.execCmdEx; ``args`` is passed directly so there is no shell
    # round-trip, and the runner reports wall time itself.
    let result = execCaptured(args, cwd = scope.projectRoot)
    let duration = result.durationMs
    if result.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId, output = result.output,
          durationMs = duration)
    if result.exitCode == 0:
      events.add event(tekTestFinished, providerId, runId, testId, some(tsPassed),
          "passed", durationMs = duration)
      events.add event(tekRunFinished, providerId, runId, testId, some(tsPassed),
          "passed", durationMs = duration)
      ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)
    else:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "native test command exited with " & $result.exitCode, result.output,
          durationMs = duration)
      events.add event(tekRunFinished, providerId, runId, testId, some(tsFailed),
          "failed", durationMs = duration)
      ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "native test execution failed with exit code " & $result.exitCode,
            scope.file)],
        value: events)

proc nativeRecorderPrefix*(): seq[string] =
  nativeM11.nativeRecorderPrefix()

proc recordNativeCommand*(providerId: string; kind: CppFrameworkKind;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  if scope.kind != tskSingle:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          providerId & " M10 recording supports single-test scopes only",
          scope.file)],
      value: @[])
  let testCommand = buildCppCommand(kind, scope.projectRoot, scope.file,
      scope.selector, ccsSingle)
  if testCommand.len == 0 or testCommand[0].startsWith("<"):
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          "native test executable is required for recording but was not found under the project build directory",
          scope.file)],
      value: @[])
  nativeM11.recordCommand(providerId, scope, testCommand, @[],
      normalizedRelative(scope.projectRoot, scope.file))

proc parseProviderEventLine*(providerId: string; raw: string): ProviderResult[TestEvent] =
  try:
    ProviderResult[TestEvent](diagnostics: @[], value: eventFromJsonLine(raw))
  except CatchableError as err:
    ProviderResult[TestEvent](
      diagnostics: @[diagnostic(dsError,
          providerId & " could not parse normalized event line: " & err.msg)],
      value: TestEvent(schemaVersion: TestEventSchemaVersion, providerId: providerId))

proc mapTraceByCatalogId*(catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] =
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

proc ctestDecls*(projectRoot: string): seq[CTestDecl] =
  parseCTestTestfile(ctestFilePath(projectRoot))
