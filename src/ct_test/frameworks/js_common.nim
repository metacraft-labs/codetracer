import std/[
  algorithm, json, options, os, osproc, sequtils, strutils, tables, times
]

import ../contracts
import ../discovery
import ../process_exec
import ../workspace_scope

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
  for path in walkWorkspaceFiles(projectRoot):
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

const JsRecorderRepo = "codetracer-js-recorder"

proc jsRecorderCommandPrefix(workspaceRoot: string): seq[string] =
  ## Resolve the argv prefix that invokes the JavaScript recorder, in strict
  ## precedence order:
  ##
  ## 1. ``CODETRACER_JS_RECORDER_PATH`` — an explicit path always wins and is
  ##    never second-guessed by anything below. Note that
  ##    ``scripts/detect-siblings.sh`` does NOT set this (despite the name
  ##    suggesting a dev-shell contract); it is the caller's escape hatch.
  ## 2. ``codetracer-js-recorder`` on ``PATH`` — an installed recorder, and the
  ##    route the dev shell does use: ``detect-siblings.sh`` prepends the
  ##    sibling's ``node_modules/.bin``. That directory only exists when ``npm
  ##    install`` could write it, which it cannot when ``node_modules`` comes
  ##    from a read-only Nix derivation; the script warns loudly in that case.
  ## 3. The recorder checkout inside ``workspaceRoot``, run through ``node``.
  ##    This is what makes the recorder reachable in the configuration step 2
  ##    cannot cover — the caller names the workspace that contains it.
  ##
  ## ``workspaceRoot`` is ``TestScope.projectRoot``, which
  ## ``run_orchestration.scopeForItem`` sets to the workspace root the caller
  ## named. Step 3 used to start from ``getCurrentDir().parentDir`` instead, so
  ## whether a trace could be recorded at all — and by *which* repository's
  ## recorder — depended on the directory the shell happened to be in. Measured
  ## with one workspace, one binary and one environment, only the cwd differing:
  ## the workspace's own recorder from a directory beside it, a flat refusal
  ## from ``$HOME``, and an unrelated checkout's recorder from a third
  ## directory. See ``workspace_scope.siblingRepoInWorkspace``.
  let configured = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if configured.len > 0:
    return @[configured]

  let onPath = findExe(JsRecorderRepo)
  if onPath.len > 0:
    return @[onPath]

  let repo = siblingRepoInWorkspace(workspaceRoot, JsRecorderRepo)
  if repo.len > 0:
    let siblingCli = repo / "packages" / "cli" / "dist" / "index.js"
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

# ---------------------------------------------------------------------------
# node:test's machine-readable results
# ---------------------------------------------------------------------------

type
  NodeTapResults* = object
    ## What ``node --test``'s TAP stream said — or, when it could not be
    ## trusted, why not.
    ##
    ## Same shape and same reason as ``ruby_common.RspecJsonResults``: an empty
    ## ``events`` seq is ambiguous between "the runner matched no test" and
    ## "there was nothing here to read", and only the second may fall back to
    ## the exit code.
    usable*: bool
    reason*: string
    events*: seq[TestEvent]

  TapPoint = object
    ## One TAP test point: an ``ok`` / ``not ok`` line plus what its YAML block
    ## said about it.
    ok: bool
    name: string
    directive: string      ## upper-cased ``SKIP`` / ``TODO``, or empty
    isSuite: bool          ## ``type: 'suite'`` — a container, not a test
    error: string
    durationMs: int

proc indentOf(line: string): int =
  while result < line.len and line[result] == ' ':
    inc result

proc unquoteYaml(raw: string): string =
  let trimmed = raw.strip
  if trimmed.len >= 2 and trimmed[0] == trimmed[^1] and
      trimmed[0] in {'\'', '"'}:
    trimmed[1 ..< trimmed.high]
  else:
    trimmed

proc parseTapPointLine(body: string): tuple[ok: bool; found: bool;
    name: string; directive: string] =
  ## Split ``ok 3 - name # SKIP why`` (or ``not ok 3 - name``) into its parts.
  ##
  ## ``body`` is the line with its leading indentation already removed; TAP
  ## nests subtests by indentation and node uses that for ``describe`` blocks,
  ## so the caller strips it rather than this routine assuming column 0.
  var rest = body
  var ok = true
  if rest.startsWith("not ok"):
    ok = false
    rest = rest["not ok".len .. ^1]
  elif rest.startsWith("ok"):
    rest = rest["ok".len .. ^1]
  else:
    return (false, false, "", "")
  # A bare `ok`/`not ok` must be followed by a separator, or `okay_thing` and
  # `not okay` would parse as test points.
  if rest.len > 0 and rest[0] notin {' ', '\t'}:
    return (false, false, "", "")
  rest = rest.strip
  # Drop the test number.
  var i = 0
  while i < rest.len and rest[i].isDigit:
    inc i
  rest = rest[i .. ^1].strip
  if rest.startsWith("-"):
    rest = rest[1 .. ^1].strip
  # ` # DIRECTIVE reason` — TAP's own escape is `\#`, which node does not emit
  # but which must not be mistaken for a directive if it ever does.
  var directive = ""
  var name = rest
  var hash = -1
  var j = 0
  while j < rest.len:
    if rest[j] == '\\':
      inc j
    elif rest[j] == '#':
      hash = j
      break
    inc j
  if hash >= 0:
    name = rest[0 ..< hash].strip
    let note = rest[(hash + 1) .. ^1].strip
    let firstWord = note.split({' ', '\t'})[0]
    if firstWord.len > 0:
      directive = firstWord.toUpperAscii
  (ok, true, name, directive)

proc parseNodeTapResults*(
    providerId, runId, fallbackTestId, raw: string): NodeTapResults =
  ## Turn ``node --test``'s TAP stream into one ``tekTestFinished`` per test.
  ##
  ## **This is the node:test provider's status decision**, and the exit code is
  ## consulted only when this returns ``usable = false``. ``node --test`` with
  ## every test skipped prints ``# pass 0`` / ``# skipped 2`` and **exits 0**,
  ## so an exit-code verdict reports the file as passing and
  ## ``certificate_issuance`` then claims it as a covered target
  ## (Standard.md §8 forbids exactly that).
  ##
  ## **No command flag is involved, deliberately.** ``node --test`` selects its
  ## reporter by whether stdout is a TTY — ``spec`` when it is, ``tap`` when it
  ## is not — and ``ct test`` always captures, so this stream is already TAP
  ## and the user's visible output is unchanged by reading it. Passing
  ## ``--test-reporter=tap`` to say so explicitly would buy nothing and would
  ## break Node 18.1–18.14, which have ``--test`` but not ``--test-reporter``.
  ## What guards the assumption is not a flag but the cross-check below.
  ##
  ## **The cross-check is the load-bearing part.** Parsing a nested TAP stream
  ## by hand can go wrong quietly — a ``describe`` block emits its own
  ## ``not ok`` line (``type: 'suite'``) that must NOT be counted, and a format
  ## change could make every point unrecognisable. Under-counting is the
  ## dangerous direction: zero events would read as "this unit executed
  ## nothing" and *withhold* a certificate that should have been issued. So the
  ## parsed tallies are checked against node's own trailing ``# tests`` /
  ## ``# pass`` / ``# fail`` / ``# skipped`` / ``# todo`` counters, and any
  ## disagreement is reported as unusable rather than believed.
  ##
  ## ``todo`` maps to ``tsSkipped``, not ``tsPassed``, and the directive is
  ## what decides it rather than the ``ok`` / ``not ok`` beside it. Node writes
  ## BOTH spellings — measured on Node 22.22: a passing ``todo`` is
  ## ``ok N - name # TODO``, one whose body throws is
  ## ``not ok N - name # TODO`` — and counts both under ``# todo`` rather than
  ## under ``# pass`` or ``# fail``. So a todo result is not evidence that
  ## anything held, whichever way node spelled it.
  var
    points: seq[TapPoint] = @[]
    sawVersion = false
    sawPlan = false
    counters = initTable[string, int]()
    lines = raw.splitLines
    i = 0
  while i < lines.len:
    let
      line = lines[i]
      indent = indentOf(line)
      body = line[min(indent, line.len) .. ^1]
    inc i

    if body.startsWith("TAP version"):
      sawVersion = true
      continue
    if indent == 0 and body.startsWith("1.."):
      sawPlan = true
      continue
    if indent == 0 and body.startsWith("# "):
      # The trailing summary block: `# tests 5`, `# pass 2`, …
      let parts = body[2 .. ^1].strip.splitWhitespace()
      if parts.len == 2:
        try:
          counters[parts[0]] = parseInt(parts[1])
        except ValueError:
          discard
      continue

    let parsed = parseTapPointLine(body)
    if not parsed.found:
      continue

    var point = TapPoint(ok: parsed.ok, name: parsed.name,
        directive: parsed.directive, isSuite: false, error: "", durationMs: 0)
    # The YAML block that follows describes the point: `type:` says whether it
    # is a test or a suite, `error:` says why it failed.
    if i < lines.len and lines[i].strip == "---":
      let yamlIndent = indentOf(lines[i])
      inc i
      while i < lines.len:
        let
          yamlLine = lines[i]
          yamlBody = yamlLine[min(indentOf(yamlLine), yamlLine.len) .. ^1]
        if indentOf(yamlLine) == yamlIndent and yamlBody == "...":
          inc i
          break
        if indentOf(yamlLine) == yamlIndent:
          if yamlBody.startsWith("type:"):
            point.isSuite = unquoteYaml(yamlBody["type:".len .. ^1]) == "suite"
          elif yamlBody.startsWith("error:"):
            point.error = unquoteYaml(yamlBody["error:".len .. ^1])
          elif yamlBody.startsWith("duration_ms:"):
            try:
              point.durationMs = int(
                parseFloat(yamlBody["duration_ms:".len .. ^1].strip))
            except ValueError:
              discard
        inc i
    points.add point

  if not sawVersion or not sawPlan:
    return NodeTapResults(usable: false,
      reason: "node --test did not produce a TAP stream (no `TAP version` " &
        "header or no plan line); its reporter may have been overridden")
  for required in ["tests", "pass", "fail", "skipped", "todo"]:
    if not counters.hasKey(required):
      return NodeTapResults(usable: false,
        reason: "node --test's TAP stream carried no `# " & required &
          "` summary counter, so its per-test results could not be checked")

  var
    events: seq[TestEvent] = @[]
    passed = 0
    failed = 0
    skipped = 0
  for point in points:
    if point.isSuite:
      continue
    let status =
      if point.directive in ["SKIP", "TODO"]: tsSkipped
      elif point.ok: tsPassed
      else: tsFailed
    case status
    of tsPassed: inc passed
    of tsSkipped: inc skipped
    else: inc failed
    let testId = if point.name.len > 0: point.name else: fallbackTestId
    if testId.len == 0:
      return NodeTapResults(usable: false,
        reason: "a node --test TAP point carried no name, so its result " &
          "could not be attributed")
    let message =
      if point.error.len > 0: $status & ": " & point.error
      else: $status
    events.add event(tekTestFinished, providerId, runId, testId, some(status),
      message, durationMs = point.durationMs)

  # THE CROSS-CHECK. `# tests` counts leaf tests and excludes suites, and
  # `# skipped` + `# todo` is what this maps onto `tsSkipped`, so agreement on
  # all three tallies means the walk above saw exactly what node reported.
  #
  # `# cancelled` is deliberately NOT folded into any of them. A cancelled test
  # is rare, its TAP spelling is not pinned by a test here, and guessing which
  # tally it lands in would make a WRONG parse pass this check — which is worse
  # than the alternative, since a run containing one simply falls back to the
  # exit code with the mismatch spelled out in `reason`.
  let
    expectedTotal = counters["tests"]
    expectedPassed = counters["pass"]
    expectedFailed = counters["fail"]
    expectedSkipped = counters["skipped"] + counters["todo"]
  if events.len != expectedTotal or passed != expectedPassed or
      failed != expectedFailed or skipped != expectedSkipped:
    return NodeTapResults(usable: false,
      reason: "node --test's TAP stream did not parse consistently with its " &
        "own summary (parsed " & $events.len & " tests / " & $passed &
        " passed / " & $failed & " failed / " & $skipped &
        " skipped+todo; node reported " & $expectedTotal & " / " &
        $expectedPassed & " / " & $expectedFailed & " / " & $expectedSkipped &
        ")")
  NodeTapResults(usable: true, reason: "", events: events)

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

    # ---- Per-test results, with the exit code as the fallback ---------------
    # Read before the exit-code branch below: when node produced a TAP stream
    # that stream is a strictly better answer than its exit status, which
    # cannot tell an all-skipped file from a fully-passing one.
    let reported = parseNodeTapResults(providerId, runId, testId, result.output)
    if reported.usable:
      var
        anyFailed = false
        anyPassed = false
        anySkipped = false
      for finished in reported.events:
        let status = finished.status.get(tsErrored)
        case status
        of tsFailed, tsErrored:
          anyFailed = true
          events.add event(tekFailure, providerId, runId, finished.testId,
              some(status), finished.message, result.output)
        of tsPassed: anyPassed = true
        of tsSkipped: anySkipped = true
        events.add finished

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
            "node:test execution failed: at least one test did not pass " &
            "(exit code " & $result.exitCode & ")",
            scope.file)
      elif result.exitCode != 0:
        # A non-zero exit its own TAP stream does not explain — a module that
        # threw at load, an uncaught async error after the plan. Never
        # swallowed.
        diagnostics.add diagnostic(dsError,
            "node --test exited with " & $result.exitCode &
            " but reported no failing test; treat the run as failed and " &
            "check the output for an error outside the tests",
            scope.file)
      elif reported.events.len == 0:
        diagnostics.add diagnostic(dsWarning,
            "node --test matched no test for " &
            (if scope.selector.len > 0: scope.selector else: scope.file) &
            "; nothing executed, so this unit attests nothing",
            scope.file)
      return ProviderResult[seq[TestEvent]](diagnostics: diagnostics,
          value: events)

    # ---- The exit-code decision --------------------------------------------
    # The fallback when no trustworthy TAP stream was produced. It cannot see a
    # skip — announced rather than assumed, so a run that regressed onto this
    # path says so instead of looking identical to a per-test one.
    var diagnostics = @[diagnostic(dsWarning,
        "falling back to node --test's exit code for this unit's status: " &
        reported.reason &
        ". An exit code cannot distinguish a skipped test from a passing " &
        "one, so a skip in this unit is reported as a pass",
        scope.file)]
    if result.exitCode == 0:
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsPassed), "passed")
      ProviderResult[seq[TestEvent]](diagnostics: diagnostics, value: events)
    else:
      events.add event(tekFailure, providerId, runId, testId, some(tsFailed),
          "node --test exited with " & $result.exitCode, result.output)
      events.add event(tekTestFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      events.add event(tekRunFinished, providerId, runId, testId, some(
          tsFailed), "failed")
      diagnostics.add diagnostic(dsError,
          "node:test execution failed with exit code " & $result.exitCode,
          scope.file)
      ProviderResult[seq[TestEvent]](diagnostics: diagnostics, value: events)

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

    let recorderPrefix = jsRecorderCommandPrefix(scope.projectRoot)
    if recorderPrefix.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "codetracer-js-recorder is required for node:test recording. " &
            "Set CODETRACER_JS_RECORDER_PATH, put codetracer-js-recorder on " &
            "PATH, or name a workspace that contains the " &
            "codetracer-js-recorder checkout (looked under " &
            scope.projectRoot & ")",
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
