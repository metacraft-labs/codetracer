import std/[algorithm, json, options, os, osproc, sequtils, strutils]
import std/[tables, tempfiles, times]

import ../contracts
import ../discovery
import ../process_exec
import ../workspace_scope

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
  for path in walkWorkspaceFiles(projectRoot):
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
    selector: string; scope: RubyCommandScope;
    rspecJsonOut = ""): seq[string] =
  ## Build the argv that runs one rspec/minitest scope.
  ##
  ## ``rspecJsonOut`` is the path rspec's machine-readable results are written
  ## to. It applies to ``rfkRSpec`` only, and passing it is what puts the run on
  ## the per-test reporting path: without it the caller can learn nothing about
  ## the run beyond rspec's exit code, and rspec exits 0 for a suite in which
  ## every example was ``pending``. ``runRubyCommand`` always supplies one; the
  ## empty default exists so the *command shape* can be asserted on its own
  ## (the path is a fresh temporary file per invocation, so a command built
  ## with one is not comparable to a literal).
  ##
  ## **Why three formatter arguments rather than one.** ``--format json --out
  ## <path>`` on its own is enough to produce the document, but it also
  ## *replaces* the formatter that writes to the terminal: rspec installs its
  ## default (or the one the project's ``.rspec`` names) only when no formatter
  ## has been configured at all, and a file-bound one counts. Measured against
  ## rspec 3.13 with an all-pending suite: ``--format json --out FILE`` printed
  ## nothing at all to stdout, `.rspec`'s ``--format documentation`` included.
  ## So the stdout formatter is named explicitly and ``--out`` binds to the
  ## ``--format`` immediately before it, which is rspec's own rule.
  ##
  ## That does override a project's configured formatter with ``progress``, and
  ## the trade is deliberate: ``progress`` is rspec's own default, it still
  ## prints the failure list, the pending list and the counts line, and the
  ## alternative on offer is not "the project's formatter" but *silence*.
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
    if rspecJsonOut.len > 0:
      result.add @["--format", "progress", "--format", "json", "--out",
        rspecJsonOut]
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

# ---------------------------------------------------------------------------
# rspec's machine-readable results
# ---------------------------------------------------------------------------

type
  RspecJsonResults* = object
    ## What rspec's ``--format json`` document said — or, when it could not be
    ## used, why not.
    ##
    ## The two are kept in one value on purpose. "No events" is ambiguous
    ## between *rspec ran and matched no example* (a real, usable answer that
    ## must not be reported as a pass) and *there was no document to read* (the
    ## caller has to fall back to the exit code, and say so). Collapsing them
    ## into an empty ``seq`` is what would let a crashed run read as an honest
    ## report of nothing.
    usable*: bool
      ## ``true`` when a document was read and carried an ``examples`` array —
      ## including an EMPTY one.
    reason*: string
      ## Why the document was unusable. Empty when ``usable``.
    events*: seq[TestEvent]
      ## One ``tekTestFinished`` per example, in rspec's own order.

proc statusFromRspec(raw: string): TestResultStatus =
  ## Map one rspec example status onto the vocabulary the runner counts by.
  ##
  ## ``pending`` is rspec's spelling for a skip — an example that was declared
  ## and deliberately not executed (``skip:``, ``pending``, ``xit``). It maps to
  ## ``tsSkipped``, which ``run_orchestration.summarize`` and
  ## ``certificate_issuance.recordUnitResult`` both count separately and neither
  ## treats as evidence. It is emphatically NOT ``tsFailed``: the point of
  ## reporting skips is that they stop being claimed as passes, not that they
  ## start reddening suites.
  ##
  ## An unrecognised status becomes ``tsErrored`` rather than being dropped or
  ## optimistically passed — a status this build does not understand is a thing
  ## that happened and could not be judged.
  case raw
  of "passed": tsPassed
  of "pending": tsSkipped
  of "failed": tsFailed
  else: tsErrored

proc rspecFailureMessage(example: JsonNode): string =
  ## The human-readable reason an example did not pass, from whichever of
  ## rspec's shapes carries it.
  let exception = example{"exception"}
  if exception != nil and exception.kind == JObject:
    let message = exception{"message"}.getStr("")
    if message.len > 0:
      let class = exception{"class"}.getStr("")
      return if class.len > 0: class & ": " & message else: message
  let pendingMessage = example{"pending_message"}.getStr("")
  if pendingMessage.len > 0:
    return pendingMessage
  ""

proc parseRspecJsonResults*(
    providerId, runId, raw: string;
    fallbackTestId = ""): RspecJsonResults =
  ## Parse rspec's ``--format json`` document into one ``tekTestFinished``
  ## event per example.
  ##
  ## **This is the rspec provider's status decision.** ``runRubyCommand`` routes
  ## every rspec run through here, and the exit code is consulted only when this
  ## returns ``usable = false``. That indirection is the whole point: rspec
  ## exits 0 for a suite in which every example was ``pending``, so an exit-code
  ## verdict cannot tell an all-skipped file from a fully-passing one, and
  ## ``certificate_issuance`` would then name a file in which nothing ran as a
  ## covered target — which ``test-certificates-spec/Standard.md`` §8 forbids in
  ## as many words.
  ##
  ## ``fallbackTestId`` names the event when rspec's document carries neither an
  ## ``id`` nor a ``full_description``; ``contracts.validateEvent`` rejects a
  ## ``tekTestFinished`` with an empty ``testId``, so an event that would be
  ## invalid gets the scheduled unit's id instead of being emitted broken.
  ## Callers should pass one. Note that the ids in a normal document are rspec's
  ## own (``./spec/x_spec.rb[1:1]``) and never equal a catalog item id — target
  ## attribution deliberately does not go through them; see
  ## ``certificate_issuance.recordUnitResult``.
  ##
  ## Raises nothing: a malformed document is a ``usable = false`` result
  ## carrying the parser's own message, because the caller's job when rspec
  ## produced garbage is to fall back and say so, not to abort a worker thread.
  var document: JsonNode
  try:
    document = parseJson(raw)
  except CatchableError as err:
    return RspecJsonResults(usable: false,
      reason: "rspec's JSON results could not be parsed: " & err.msg)
  if document == nil or document.kind != JObject:
    return RspecJsonResults(usable: false,
      reason: "rspec's JSON results were not a JSON object")
  let examples = document{"examples"}
  if examples == nil or examples.kind != JArray:
    return RspecJsonResults(usable: false,
      reason: "rspec's JSON results carried no `examples` array")

  # An EMPTY array reaches here as `usable`, and that is the interesting case:
  # it means rspec ran and matched no example, which must be reported as "this
  # unit executed nothing" rather than as the pass its exit code claims.
  result = RspecJsonResults(usable: true, reason: "", events: @[])
  for example in examples:
    if example.kind != JObject:
      continue
    let
      rawId = example{"id"}.getStr(example{"full_description"}.getStr(""))
      testId = if rawId.len > 0: rawId else: fallbackTestId
      statusText = example{"status"}.getStr("")
      status = statusFromRspec(statusText)
      duration = int(example{"run_time"}.getFloat(0.0) * 1000)
      detail = rspecFailureMessage(example)
      message =
        if detail.len > 0: statusText & ": " & detail
        else: statusText
    if testId.len == 0:
      # Nothing to attribute the result to, and an event without a testId is
      # invalid by `validateEvent`. Skipping it silently would be the same
      # invisible-loss failure this change exists to remove, so the run is
      # reported as unusable and falls back to the exit code.
      return RspecJsonResults(usable: false,
        reason: "an rspec example carried neither `id` nor " &
          "`full_description`, so its result could not be attributed")
    result.events.add event(tekTestFinished, providerId, runId, testId,
      some(status), message, durationMs = duration)

proc readRspecJsonResults(
    providerId, runId, fallbackTestId, path: string): RspecJsonResults =
  ## Read and parse the document ``buildRubyCommand``'s ``--out`` asked for.
  ##
  ## Every way of not getting one is a distinct, named ``reason`` rather than a
  ## shrug, because the caller turns it into a diagnostic the operator reads:
  ## the file is absent when rspec died before its formatter closed (a Ruby
  ## syntax error in a spec file, a signal, a bundler failure), and empty when
  ## it was killed mid-write.
  if path.len == 0:
    return RspecJsonResults(usable: false,
      reason: "no JSON results path was requested")
  if not fileExists(path):
    return RspecJsonResults(usable: false,
      reason: "rspec wrote no JSON results to " & path &
        " (it exited before its formatter produced one)")
  var raw = ""
  try:
    raw = readFile(path)
  except CatchableError as err:
    return RspecJsonResults(usable: false,
      reason: "rspec's JSON results at " & path & " could not be read: " &
        err.msg)
  if raw.strip.len == 0:
    # The usual shape of "rspec died early", because the path is created
    # (exclusively) before rspec is launched: an aborted run leaves the empty
    # file behind rather than no file at all.
    return RspecJsonResults(usable: false,
      reason: "rspec wrote no JSON results to " & path &
        " (the file is empty; it exited before its formatter produced one)")
  parseRspecJsonResults(providerId, runId, raw, fallbackTestId)

proc newRspecJsonPath(): string =
  ## A fresh, exclusively-created path for one rspec invocation's results.
  ##
  ## Created rather than merely generated, and created per invocation rather
  ## than per provider: ``runRubyCommand`` runs on the orchestrator's worker
  ## threads, so several rspec processes are in flight at once and a shared or
  ## guessable name would have them overwrite each other's results — which
  ## would not fail loudly, it would silently attribute one file's outcomes to
  ## another. Returns an empty string if no temporary file can be made, which
  ## the caller reports as an exit-code fallback rather than treating as fatal.
  try:
    let (handle, path) = createTempFile("ct-test-rspec-", ".json")
    handle.close()
    path
  except CatchableError:
    ""

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
      # rspec is asked for machine-readable results; minitest is not, and gets
      # a byte-identical command to the one it has always been given. There is
      # no minitest equivalent to hand it here — minitest emits a human summary
      # line and nothing structured — so the empty path is what keeps this one
      # proc serving both without forking it, and minitest's status still comes
      # from the exit-code branch below. (`parseMinitestSummary` at the bottom
      # of this file could read that summary line, but nothing calls it; it is
      # the same on-no-run-path shape `parseRspecJsonResults` used to have.)
      rspecJsonPath = if kind == rfkRSpec: newRspecJsonPath() else: ""
      args = buildRubyCommand(kind, scope.projectRoot, scope.file,
          scope.selector, commandScope, rspecJsonPath)
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

    # ---- rspec: per-test results, with the exit code as the fallback --------
    # Read before the exit-code branch below, because when rspec produced a
    # results document that document is a strictly better answer than its exit
    # status — it distinguishes a pending example from a passing one, which the
    # exit status cannot do at all.
    var reportedResults = RspecJsonResults(usable: false, reason: "")
    if kind == rfkRSpec:
      reportedResults = readRspecJsonResults(providerId, runId, testId,
          rspecJsonPath)
    if rspecJsonPath.len > 0:
      try:
        removeFile(rspecJsonPath)
      except OSError:
        discard

    if reportedResults.usable:
      var
        anyFailed = false
        anyPassed = false
        anySkipped = false
      for finished in reportedResults.events:
        let status = finished.status.get(tsErrored)
        case status
        of tsFailed, tsErrored:
          anyFailed = true
          # A failure event carries the reason where a reader looks for it; the
          # `tekTestFinished` beside it is what the counters read.
          events.add event(tekFailure, providerId, runId, finished.testId,
              some(status), finished.message, result.output)
        of tsPassed: anyPassed = true
        of tsSkipped: anySkipped = true
        events.add finished

      # The run-level status summarises the examples, and it summarises them in
      # this order for a reason: a failure outranks everything, a pass outranks
      # a skip, and a run whose every example was skipped finishes `tsSkipped`
      # rather than `tsPassed`. Nothing counts this event — `summarize` and
      # `recordUnitResult` both read `tekTestFinished` only — but a run that
      # reported "passed" while executing nothing is precisely the sentence
      # this change exists to stop anyone writing down.
      let runStatus =
        if anyFailed: tsFailed
        elif anyPassed: tsPassed
        elif anySkipped: tsSkipped
        else: tsErrored
      events.add event(tekRunFinished, providerId, runId, testId,
          some(runStatus), $runStatus)

      var diagnostics: seq[TestDiagnostic] = @[]
      if anyFailed:
        diagnostics.add diagnostic(dsError,
            "Ruby test execution failed: rspec reported at least one failing " &
            "example (exit code " & $result.exitCode & ")",
            scope.file)
      elif result.exitCode != 0:
        # rspec exited non-zero for a reason its example list does not explain
        # — a spec file that failed to load, `--require` blowing up, a
        # `config.failure_exit_code`. Never swallowed: an unexplained non-zero
        # exit is reported as an error even though every example that DID run
        # passed.
        diagnostics.add diagnostic(dsError,
            "rspec exited with " & $result.exitCode &
            " but reported no failing example; treat the run as failed and " &
            "check the output for an error outside the examples",
            scope.file)
      elif reportedResults.events.len == 0:
        diagnostics.add diagnostic(dsWarning,
            "rspec matched no example for " &
            (if scope.selector.len > 0: scope.selector else: scope.file) &
            "; nothing executed, so this unit attests nothing",
            scope.file)
      return ProviderResult[seq[TestEvent]](diagnostics: diagnostics,
          value: events)

    # ---- The exit-code decision --------------------------------------------
    # Minitest's only status source, and rspec's fallback when no usable
    # results document was produced. It cannot see a skip — that is the known
    # limitation, and for rspec it is now announced rather than assumed, so a
    # run that quietly regressed onto this path says so instead of looking
    # identical to a per-test one.
    var diagnostics: seq[TestDiagnostic] = @[]
    if kind == rfkRSpec:
      diagnostics.add diagnostic(dsWarning,
          "falling back to rspec's exit code for this unit's status: " &
          reportedResults.reason &
          ". An exit code cannot distinguish a pending example from a " &
          "passing one, so a skip in this unit is reported as a pass",
          scope.file)
    if result.exitCode == 0:
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      ProviderResult[seq[TestEvent]](diagnostics: diagnostics, value: events)
    else:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "Ruby test command exited with " & $result.exitCode, result.output)
      # The `tekTestFinished` is what the COUNTERS read: `summarize` and
      # `certificate_issuance.recordUnitResult` both ignore `tekFailure`
      # entirely. Without it a failing unit contributed nothing to `failed`,
      # so a run in which every Ruby unit failed reported `executed 0,
      # failed 0` and exited 2 ("nothing executed") instead of 1 ("tests
      # failed") — a real failure reported as an absence. `js_common`'s
      # matching fallback has always emitted this event; this one did not.
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      diagnostics.add diagnostic(dsError,
          "Ruby test execution failed with exit code " & $result.exitCode,
          scope.file)
      ProviderResult[seq[TestEvent]](diagnostics: diagnostics, value: events)

const RubyRecorderRepo = "codetracer-ruby-recorder"

proc rubyRecorderCommandPrefix*(workspaceRoot: string): seq[string] =
  ## Resolve the argv prefix that invokes the Ruby recorder, in strict
  ## precedence order:
  ##
  ## 1. ``CODETRACER_RUBY_RECORDER_PATH`` — an explicit path always wins. Note
  ##    that ``scripts/detect-siblings.sh`` does NOT set this (despite the name
  ##    suggesting a dev-shell contract); it is the caller's escape hatch.
  ## 2. The recorder checkout inside ``workspaceRoot``, run through ``ruby``.
  ## 3. ``codetracer-ruby-recorder`` on ``PATH`` — the route the dev shell
  ##    actually uses: ``detect-siblings.sh`` prepends the sibling's
  ##    ``gems/codetracer-ruby-recorder/bin``, which (unlike its JavaScript
  ##    counterpart) exists as soon as the extension is built.
  ##
  ## The workspace checkout deliberately outranks ``PATH`` here (JS orders
  ## those two the other way): a Ruby recorder in the workspace is the one the
  ## workspace's Gemfile and ``RUBYLIB`` are set up for, and an installed gem
  ## shadowing it would record with a different version of the recorder than
  ## the tests were written against. That order is longstanding and unchanged;
  ## only the *starting directory* of step 2 changed.
  ##
  ## ``workspaceRoot`` is ``TestScope.projectRoot``, the workspace root the
  ## caller named (``run_orchestration.scopeForItem``). Step 2 used to search
  ## two other places, neither of which the caller named:
  ##
  ## * ``getCurrentDir().parentDir`` — the shell's working directory, so which
  ##   recorder ran depended on where the user happened to be standing; and
  ## * ``currentSourcePath()`` five directories up — deterministic, but it
  ##   points into the *source tree this file was compiled from*, not the
  ##   user's workspace, and it hard-codes the assumption that this file sits
  ##   exactly four levels below a checkout whose parent is a multi-repo
  ##   workspace. In an installed build that path is the build sandbox and
  ##   resolves to nothing; in a developer checkout it silently redirected the
  ##   recording to a repository beside *this* source tree. It was also the
  ##   reason Ruby resolution appeared to work in places the otherwise
  ##   identical JS resolution did not, which made the shared defect look like
  ##   two unrelated ones.
  ##
  ## See ``workspace_scope.siblingRepoInWorkspace``.
  let configured = getEnv("CODETRACER_RUBY_RECORDER_PATH", "")
  if configured.len > 0:
    return @[configured]
  let rubyExe = rubyExecutable()
  if rubyExe.len == 0:
    return @[]
  let repo = siblingRepoInWorkspace(workspaceRoot, RubyRecorderRepo)
  if repo.len > 0:
    let siblingCli = repo / "gems" / RubyRecorderRepo / "bin" / RubyRecorderRepo
    if fileExists(siblingCli):
      return @[rubyExe, siblingCli]
  let onPath = findExe(RubyRecorderRepo)
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
    let recorderPrefix = rubyRecorderCommandPrefix(scope.projectRoot)
    if recorderPrefix.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "codetracer-ruby-recorder is required for Ruby test recording. " &
            "Set CODETRACER_RUBY_RECORDER_PATH, put codetracer-ruby-recorder " &
            "on PATH, or name a workspace that contains the " &
            "codetracer-ruby-recorder checkout (looked under " &
            scope.projectRoot & ")",
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
