import std/[algorithm, json, options, os, osproc, sequtils, strutils]
import std/[tables, times]

import ../contracts
import ../discovery
import ../process_exec

type
  RubyFrameworkKind* = enum
    rfkRSpec
    rfkMinitest

  RubyCommandScope* = enum
    rcsProject
    rcsFile
    rcsSingle

  RubyTestDeclKind* = enum
    rtdSuite
    rtdCase

  RubyTestDecl* = object
    kind*: RubyTestDeclKind
    name*: string
    fullName*: string
    className*: string
    line*: int
    column*: int
    endColumn*: int
    selector*: string
    parentSelector*: string
    tags*: seq[string]

  SuiteFrame = object
    name: string
    selector: string
    closeDepth: int

const
  RubyTestConfigFiles* = [
    "Gemfile",
    "Gemfile.lock",
    ".rspec",
    ".rspec-local",
    "Rakefile",
    "spec/spec_helper.rb",
    "spec/rails_helper.rb",
    "test/test_helper.rb"
  ]

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isRubyFile*(path: string): bool =
  fileExists(path) and splitFile(path).ext.toLowerAscii == ".rb"

proc projectText(projectRoot, marker: string): string =
  let path = projectRoot / marker
  if fileExists(path): readFile(path) else: ""

proc gemfileMentions(projectRoot, needle: string): bool =
  projectText(projectRoot, "Gemfile").toLowerAscii.contains(needle) or
    projectText(projectRoot, "Gemfile.lock").toLowerAscii.contains(needle)

proc hasRspecProject*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  gemfileMentions(projectRoot, "rspec") or fileExists(projectRoot / ".rspec") or
    fileExists(projectRoot / "spec/spec_helper.rb") or
    fileExists(projectRoot / "spec/rails_helper.rb")

proc hasMinitestProject*(projectRoot: string): bool =
  if not dirExists(projectRoot):
    return false
  gemfileMentions(projectRoot, "minitest") or
    fileExists(projectRoot / "test/test_helper.rb") or
    projectText(projectRoot, "Rakefile").toLowerAscii.contains("minitest")

proc isCandidateRspecFile*(path: string): bool =
  isRubyFile(path) and splitFile(path).name.toLowerAscii.endsWith("_spec")

proc isCandidateMinitestFile*(path: string): bool =
  isRubyFile(path) and
    (splitFile(path).name.toLowerAscii.endsWith("_test") or
      normalizedPath(path).replace("\\", "/").contains("/test/"))

proc rubyFiles*(projectRoot: string; predicate: proc(
    path: string): bool {.gcsafe.}): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith("vendor/") or rel.startsWith(".bundle/") or
        rel.startsWith("tmp/"):
      continue
    if predicate(path):
      result.add path
  result.sort(system.cmp[string])

proc quoteArg(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc commandToString*(parts: seq[string]): string =
  parts.mapIt(quoteArg(it)).join(" ")

proc firstQuotedArgument(
    line: string;
    startAt: int): tuple[value: string; endPos: int] =
  var i = startAt
  while i < line.len and line[i] in {' ', '\t', '('}:
    inc i
  if i >= line.len or line[i] notin {'"', '\''}:
    return ("", i)
  let quote = line[i]
  inc i
  var value = ""
  while i < line.len:
    if line[i] == '\\':
      inc i
      if i < line.len:
        value.add line[i]
        inc i
      continue
    if line[i] == quote:
      return (value, i + 1)
    value.add line[i]
    inc i
  ("", i)

proc firstDslArgument(
    line: string;
    startAt: int): tuple[value: string; endPos: int] =
  let quoted = firstQuotedArgument(line, startAt)
  if quoted.value.len > 0:
    return quoted
  var i = startAt
  while i < line.len and line[i] in {' ', '\t', '('}:
    inc i
  if i < line.len and line[i] == ':':
    inc i
  let start = i
  while i < line.len and line[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_', ':'}:
    inc i
  if i > start:
    return (line[start ..< i], i)
  ("", i)

proc countToken(line, token: string): int =
  var i = 0
  while true:
    let pos = line.find(token, i)
    if pos < 0:
      break
    let beforeOk = pos == 0 or not (line[pos - 1] in {'A'..'Z', 'a'..'z',
        '0'..'9', '_'})
    let after = pos + token.len
    let afterOk = after >= line.len or not (line[after] in {'A'..'Z', 'a'..'z',
        '0'..'9', '_'})
    if beforeOk and afterOk:
      inc result
    i = pos + token.len

proc startsWithRubyEnd(stripped: string): bool =
  stripped == "end" or stripped.startsWith("end ") or
    stripped.startsWith("end #")

proc adjustRubyDepth(stripped: string; depth: var int) =
  if startsWithRubyEnd(stripped):
    depth = max(0, depth - 1)
  depth += countToken(stripped, "do")
  if stripped.startsWith("class ") or stripped.startsWith("module ") or
      stripped.startsWith("def "):
    inc depth

proc rspecCall(
    stripped: string): tuple[callee: string; name: string; tags: seq[string]] =
  var line = stripped
  if line.startsWith("RSpec."):
    line = line["RSpec.".len .. ^1]
  for callee in ["describe", "context", "shared_examples", "shared_context"]:
    if line.startsWith(callee):
      let parsed = firstDslArgument(line, callee.len)
      if parsed.value.len == 0:
        continue
      var tags: seq[string] = @[]
      if callee.startsWith("shared_"):
        tags.add "shared-example"
      if line.contains(".skip") or line.contains(" skip:") or
          line.contains(", skip"):
        tags.add "skip"
      if line.contains(".focus") or line.contains(" focus:") or
          line.contains(", focus"):
        tags.add "focus"
      return (callee, parsed.value, tags)
  for callee in ["it", "specify", "example"]:
    if line.startsWith(callee):
      let parsed = firstQuotedArgument(line, callee.len)
      if parsed.value.len == 0:
        continue
      var tags: seq[string] = @[]
      if line.contains(".skip") or line.contains(" skip:") or
          line.contains(", skip"):
        tags.add "skip"
      if line.contains(".focus") or line.contains(" focus:") or
          line.contains(", focus"):
        tags.add "focus"
      return (callee, parsed.value, tags)
  ("", "", @[])

proc selectorFrom(relative: string; line: int): string =
  relative & ":" & $line

proc parseRspecDeclarations*(
    projectRoot, filePath, content: string): seq[RubyTestDecl] =
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
    if startsWithRubyEnd(stripped):
      depth = max(0, depth - 1)
      while suites.len > 0 and suites[^1].closeDepth > depth:
        discard suites.pop()
      continue

    let call = rspecCall(stripped)
    if call.callee.len > 0:
      let
        column = rawLine.find(call.callee) + 1
        selector = selectorFrom(relative, lineNo)
        parentSelector = if suites.len > 0: suites[^1].selector else: ""
        names = suites.mapIt(it.name) & @[call.name]
        isSuite = call.callee in [
          "describe", "context", "shared_examples", "shared_context"]
      result.add RubyTestDecl(
        kind: if isSuite: rtdSuite else: rtdCase,
        name: call.name,
        fullName: names.join(" "),
        className: "",
        line: lineNo,
        column: max(1, column),
        endColumn: max(1, column) + call.callee.len + call.name.len,
        selector: selector,
        parentSelector: parentSelector,
        tags: call.tags)
      if isSuite:
        suites.add SuiteFrame(name: call.name, selector: selector,
            closeDepth: depth + 1)
    adjustRubyDepth(stripped, depth)

proc readRubyClassName(stripped: string): tuple[name: string;
    isMinitest: bool] =
  if not stripped.startsWith("class "):
    return ("", false)
  var i = "class ".len
  let start = i
  while i < stripped.len and stripped[i] in {'A'..'Z', 'a'..'z', '0'..'9',
      '_', ':'}:
    inc i
  if i == start:
    return ("", false)
  let name = stripped[start ..< i]
  (name, stripped.contains("< Minitest::Test") or stripped.contains(
      "< MiniTest::Test") or
    stripped.contains("< Test::Unit::TestCase"))

proc readRubyMethodName(stripped: string): string =
  if not stripped.startsWith("def "):
    return ""
  var i = "def ".len
  if i < stripped.len and stripped[i..^1].startsWith("self."):
    return ""
  let start = i
  while i < stripped.len and stripped[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_',
      '?', '!'}:
    inc i
  if i > start:
    stripped[start ..< i]
  else:
    ""

proc minitestSelector*(className, methodName: string): string =
  className & "#" & methodName

proc parseMinitestDeclarations*(
    projectRoot, filePath, content: string): seq[RubyTestDecl] =
  let relative = normalizedRelative(projectRoot, filePath)
  var
    classes: seq[SuiteFrame] = @[]
    depth = 0
    lineNo = 0
  for rawLine in content.splitLines:
    inc lineNo
    let stripped = rawLine.strip
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    if startsWithRubyEnd(stripped):
      depth = max(0, depth - 1)
      while classes.len > 0 and classes[^1].closeDepth > depth:
        discard classes.pop()
      continue

    let classInfo = readRubyClassName(stripped)
    if classInfo.name.len > 0 and classInfo.isMinitest:
      let selector = relative & "::" & classInfo.name
      let column = rawLine.find("class") + 1
      result.add RubyTestDecl(
        kind: rtdSuite,
        name: classInfo.name,
        fullName: classInfo.name,
        className: classInfo.name,
        line: lineNo,
        column: max(1, column),
        endColumn: max(1, column) + "class ".len + classInfo.name.len - 1,
        selector: selector,
        parentSelector: "",
        tags: @["minitest"])
      classes.add SuiteFrame(name: classInfo.name, selector: selector,
          closeDepth: depth + 1)
    elif classes.len > 0:
      let methodName = readRubyMethodName(stripped)
      if methodName.startsWith("test_"):
        let
          className = classes[^1].name
          selector = minitestSelector(className, methodName)
          column = rawLine.find("def") + 1
        result.add RubyTestDecl(
          kind: rtdCase,
          name: methodName,
          fullName: className & " " & methodName,
          className: className,
          line: lineNo,
          column: max(1, column),
          endColumn: max(1, column) + "def ".len + methodName.len - 1,
          selector: selector,
          parentSelector: classes[^1].selector,
          tags: @["minitest"])
    adjustRubyDepth(stripped, depth)

proc buildRubyCommand*(kind: RubyFrameworkKind; projectRoot, filePath,
    selector: string; scope: RubyCommandScope): seq[string] =
  let relative = if filePath.len > 0: normalizedRelative(projectRoot,
      filePath) else: ""
  case kind
  of rfkRSpec:
    result = @["bundle", "exec", "rspec"]
    case scope
    of rcsProject:
      discard
    of rcsFile:
      result.add relative
    of rcsSingle:
      result.add selector
  of rfkMinitest:
    result = @["bundle", "exec", "ruby", "-Itest"]
    case scope
    of rcsProject:
      result.add @[
        "-e",
        "Dir['test/**/*_test.rb'].sort.each { |f| require_relative f }"]
    of rcsFile:
      result.add relative
    of rcsSingle:
      result.add @[relative, "--name", "/" & selector.replace("#", "#") & "$/"]

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

proc nonSystemExecutable(name: string): string =
  for dir in getEnv("PATH", "").split(PathSep):
    if dir.len == 0:
      continue
    let candidate = dir / name
    if fileExists(candidate) and not candidate.startsWith("/usr/bin/") and
        not candidate.startsWith("/System/"):
      return candidate
  findExe(name)

proc rubyExecutable*(): string =
  nonSystemExecutable("ruby")

proc bundleExecutable*(): string =
  nonSystemExecutable("bundle")

proc commandLine(args: seq[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

proc runRubyCommand*(providerId: string; kind: RubyFrameworkKind;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if rubyExecutable().len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Ruby is required for test execution but was not found on PATH",
            scope.file)],
        value: @[])
    if fileExists(scope.projectRoot / "Gemfile") and
        bundleExecutable().len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "bundle is required because the Ruby project has a Gemfile, " &
            "but bundle was not found on PATH",
            scope.file)],
        value: @[])

    let
      commandScope =
        case scope.kind
        of tskProject: rcsProject
        of tskFile: rcsFile
        of tskSingle: rcsSingle
      args = buildRubyCommand(kind, scope.projectRoot, scope.file,
          scope.selector, commandScope)
      execArgs =
        if args.len >= 3 and args[0] == "bundle" and args[1] == "exec":
          let executable =
            if args[2] == "ruby": rubyExecutable() else: args[2]
          if args.len > 3:
            @[bundleExecutable(), "exec", executable] & args[3 .. ^1]
          else:
            @[bundleExecutable(), "exec", executable]
        else:
          args
      command = commandLine(args)
      runId = providerId & ":" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector

    var events = @[
      event(tekRunStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    let result = execCaptured(execArgs, cwd = scope.projectRoot)
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
          "Ruby test command exited with " & $result.exitCode, result.output)
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Ruby test execution failed with exit code " & $result.exitCode,
            scope.file)],
        value: events)

proc rubyRecorderCommandPrefix*(): seq[string] =
  let configured = getEnv("CODETRACER_RUBY_RECORDER_PATH", "")
  if configured.len > 0:
    return @[configured]
  let rubyExe = rubyExecutable()
  if rubyExe.len == 0:
    return @[]
  let siblingRoots = [
    getCurrentDir().parentDir,
    currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir]
  for root in siblingRoots:
    let siblingCli = root / "codetracer-ruby-recorder" / "gems" /
        "codetracer-ruby-recorder" / "bin" / "codetracer-ruby-recorder"
    if fileExists(siblingCli):
      return @[rubyExe, siblingCli]
  let onPath = findExe("codetracer-ruby-recorder")
  if onPath.len > 0:
    return @[onPath]
  @[]

proc ctFilesUnder(root: string): seq[string] =
  if not dirExists(root):
    return @[]
  for path in walkDirRec(root):
    if fileExists(path) and splitFile(path).ext == ".ct":
      result.add path
  result.sort(system.cmp[string])

proc prependEnv(name, value: string): tuple[hadValue: bool; oldValue: string] =
  result = (existsEnv(name), getEnv(name))
  let current = getEnv(name, "")
  if current.len > 0:
    putEnv(name, value & PathSep & current)
  else:
    putEnv(name, value)

proc restoreEnv(name: string; saved: tuple[hadValue: bool; oldValue: string]) =
  if saved.hadValue:
    putEnv(name, saved.oldValue)
  else:
    delEnv(name)

proc rubyEnvOptionPrefix(option: string): tuple[hadValue: bool; oldValue: string] =
  result = (existsEnv("RUBYOPT"), getEnv("RUBYOPT"))
  let current = getEnv("RUBYOPT", "")
  if current.len > 0:
    putEnv("RUBYOPT", option & " " & current)
  else:
    putEnv("RUBYOPT", option)

proc resolveRspecExecutable(projectRoot: string): ProviderResult[string] =
  let rubyExe = rubyExecutable()
  if rubyExe.len == 0:
    return ProviderResult[string](
      diagnostics: @[diagnostic(dsError,
          "Ruby recording could not resolve the RSpec executable: ruby not found")],
      value: "")
  let probe = execCaptured(@[rubyExe, "-rbundler/setup", "-e",
      "print Gem.bin_path('rspec-core', 'rspec')"], cwd = projectRoot)
  if probe.exitCode != 0:
    return ProviderResult[string](
      diagnostics: @[diagnostic(dsError,
          "Ruby recording could not resolve the RSpec executable: " &
          probe.output)],
      value: "")
  ProviderResult[string](diagnostics: @[], value: probe.output.strip)

proc recordRubyUnsupported(message: string; scope: TestScope): ProviderResult[
    seq[TestEvent]] =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, message, scope.file)],
    value: @[])

proc recordRubyCommand*(providerId: string; kind: RubyFrameworkKind;
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if scope.kind != tskSingle:
      return recordRubyUnsupported(
        providerId & " M9 recording supports single-test scopes only",
        scope)
    if rubyExecutable().len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Ruby is required for test recording but was not found on PATH",
            scope.file)],
        value: @[])
    let recorderPrefix = rubyRecorderCommandPrefix()
    if recorderPrefix.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "codetracer-ruby-recorder is required for Ruby test recording. " &
            "Set CODETRACER_RUBY_RECORDER_PATH or keep the sibling checkout " &
            "usable",
            scope.file)],
        value: @[])

    let
      outputRoot = getTempDir() / ("ct-ruby-record-" & $getCurrentProcessId() &
          "-" & $epochTime().int & "-" & $cpuTime())
      runId = providerId & ":record:" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    createDir(outputRoot)

    let targetArgs =
      case kind
      of rfkRSpec:
        let rspecExecutable = resolveRspecExecutable(scope.projectRoot)
        if rspecExecutable.diagnostics.len > 0:
          return ProviderResult[seq[TestEvent]](
            diagnostics: rspecExecutable.diagnostics,
            value: @[])
        @[rspecExecutable.value, scope.selector]
      of rfkMinitest:
        @[normalizedRelative(scope.projectRoot, scope.file), "--name",
          "/" & scope.selector & "$/"]

    let args = recorderPrefix & @["--out-dir", outputRoot] & targetArgs
    let command = commandLine(args)
    var events = @[
      event(tekRecordStarted, providerId, runId, testId, message = command),
      event(tekTestStarted, providerId, runId, testId, message = scope.selector)
    ]
    var result: CapturedRun
    result.exitCode = -1
    let
      rubyOpt = if kind == rfkRSpec:
          some(rubyEnvOptionPrefix("-rbundler/setup"))
        else:
          none(tuple[hadValue: bool; oldValue: string])
      rubyLib = if kind == rfkMinitest:
          some(prependEnv("RUBYLIB", "test"))
        else:
          none(tuple[hadValue: bool; oldValue: string])
    try:
      result = execCaptured(args, cwd = scope.projectRoot)
    finally:
      if rubyOpt.isSome:
        restoreEnv("RUBYOPT", rubyOpt.get)
      if rubyLib.isSome:
        restoreEnv("RUBYLIB", rubyLib.get)
    if result.output.len > 0:
      events.add event(tekOutput, providerId, runId, testId,
          output = result.output)
    if result.exitCode != 0:
      let capturedOutput =
        if result.output.len > 0:
          result.output
        else:
          "<no stdout/stderr captured>"
      let failureDetails =
        "codetracer-ruby-recorder failure" &
        "\nrecorderCommand: " & command &
        "\ncwd: " & scope.projectRoot &
        "\noutDir: " & outputRoot &
        "\nexitStatus: " & $result.exitCode &
        "\noutput:\n" & capturedOutput
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "codetracer-ruby-recorder exited with " & $result.exitCode,
          failureDetails)
      events.add event(tekRecordFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Ruby recording failed with exit code " & $result.exitCode &
            ". " & failureDetails,
            scope.file)],
        value: events)

    let traces = ctFilesUnder(outputRoot)
    if traces.len == 0 or getFileSize(traces[0]) <= 0:
      events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
          "codetracer-ruby-recorder did not produce a non-empty .ct artifact",
          result.output)
      events.add event(tekRecordFinished, providerId, runId, testId, some(
          tsErrored), "errored")
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Ruby recording did not produce a non-empty .ct artifact",
            scope.file)],
        value: events)

    var metadata = initTable[string, string]()
    metadata["frameworkSelector"] = scope.selector
    metadata["catalogTestId"] = testId
    metadata["recordCommand"] = command
    metadata["artifactSize"] = $getFileSize(traces[0])
    let traceDir = parentDir(traces[0])
    let trace = TraceMetadata(
      traceId: splitPath(traceDir).tail,
      recordingId: splitPath(traceDir).tail,
      path: traceDir,
      backend: "ruby",
      entryPoint: normalizedRelative(scope.projectRoot, scope.file),
      metadata: metadata)
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: tekRecordingCreated, providerId: providerId, runId: runId,
        testId: testId, status: none(TestResultStatus), message: "recorded",
        output: "", durationMs: 0, trace: some(trace),
        diagnostic: none(TestDiagnostic))
    events.add event(tekTestFinished, providerId, runId, testId, some(
        tsPassed), "passed")
    events.add TestEvent(schemaVersion: TestEventSchemaVersion,
        kind: tekRecordFinished, providerId: providerId, runId: runId,
        testId: testId, status: some(tsPassed), message: "passed", output: "",
        durationMs: 0, trace: some(trace), diagnostic: none(TestDiagnostic))
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc parseProviderEventLine*(
    providerId: string; raw: string): ProviderResult[TestEvent] =
  try:
    let event = eventFromJsonLine(raw)
    ProviderResult[TestEvent](diagnostics: @[], value: event)
  except CatchableError as err:
    ProviderResult[TestEvent](
      diagnostics: @[diagnostic(dsError,
          providerId & " could not parse normalized event line: " & err.msg)],
      value: TestEvent(schemaVersion: TestEventSchemaVersion,
          providerId: providerId))

proc parseRspecJsonResults*(
    providerId, runId: string; raw: string): seq[TestEvent] =
  let node = parseJson(raw)
  if not node.hasKey("examples") or node["examples"].kind != JArray:
    return @[]
  for example in node["examples"]:
    let
      testId = example{"id"}.getStr(example{"full_description"}.getStr(""))
      statusText = example{"status"}.getStr("")
      duration = int(example{"run_time"}.getFloat(0.0) * 1000)
      status =
        if statusText == "passed": tsPassed
        elif statusText == "pending": tsSkipped
        elif statusText == "failed": tsFailed
        else: tsErrored
    result.add event(tekTestFinished, providerId, runId, testId, some(status),
        statusText, durationMs = duration)

proc parseMinitestSummary*(providerId, runId, testId, raw: string): TestEvent =
  var status = tsErrored
  if raw.contains(", 0 failures, 0 errors"):
    status = tsPassed
  elif raw.contains(" failures") or raw.contains(" failure"):
    status = tsFailed
  event(tekTestFinished, providerId, runId, testId, some(status), $status,
      output = raw)

proc mapTraceByCatalogId*(providerId: string; catalog: TestCatalog;
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
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[],
    value: mapped)
