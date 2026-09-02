## Multi-language build output error location parser.
##
## Parses error/warning locations from build output lines produced by:
## - Nim: `path/file.nim(line, col) severity: message`
## - TypeScript: `src/index.ts(42,5): error TS2304: message`
## - Rust (cargo): ` --> src/main.rs:42:5`
## - Noir (nargo) and anything else using `codespan-reporting` / `ariadne`:
##   `  ┌─ src/main.nr:3:19`
## - Python: `  File "script.py", line 42, in <module>`
## - GCC/Clang: `file.c:42:5: error: expected ';' ...`
## - Go: `./main.go:42:5: undefined: fmt.Printlm`
##
## This module is intentionally free of UI / framework dependencies so that
## it can be imported both by the build panel and by unit tests.
##
## ## Why the Noir matcher exists, and why severity needs a scanner
##
## `nargo` was assumed to emit Rust's ` --> ` arrow. It does not. It emits a
## box-drawing rule — `U+250C U+2500`, `┌─` — so `parseRustLocation` never
## matched, and the line then fell through to `parseColonLocation`, whose path
## heuristic accepts anything containing a `.` or a `/`. That produced a row
## that was worse than no row at all:
##
## | field | before | correct |
## | --- | --- | --- |
## | `path` | `"  ┌─ src/main.nr"` — never resolves, so it can never navigate | `"src/main.nr"` |
## | `col` | `-1`; the real column was consumed as the message | `19` |
## | `message` | `"19"` — the digits of the column | the compiler's sentence |
## | `severity` | `SevError` for **every** row, warnings included | per keyword |
##
## Measured on `test-programs/noir_build_error` with `nargo 1.0.0-beta.26`:
## three diagnostics, two of them `warning:`, and all three reported as errors.
##
## **Severity is not on the location line.** `nargo` puts the keyword on the
## line *above* it:
##
##     warning: unused variable x
##       ┌─ src/main.nr:1:9
##
## No function of that one line can therefore know whether the row is an error
## or a warning, and `inferSeverity`'s fallback — `SevError` when it recognises
## no keyword — is exactly the wrong guess: it tells a developer their warning
## is an error. So single-line parsing is not enough for this family, and
## `BuildLocationScanner` below is the shape that is: the producer that drains
## the child's output line by line owns one, and it carries the header's
## severity forward onto the location line that follows it. The state is the
## caller's, not a global, so two concurrent builds cannot contaminate each
## other and a rerun starts clean.

import std/strutils

type
  BuildSeverity* = enum
    ## Severity level extracted from a build output line.
    SevError,
    SevWarning,
    SevInfo

  ParsedBuildLocation* = object
    ## A parsed error/warning location from a build output line.
    ## `found` is true when the line matched one of the known patterns.
    found*: bool
    path*: string
    line*: int
    col*: int          ## -1 when the column is not present in the pattern
    severity*: BuildSeverity
    message*: string   ## the remaining message text (may be empty)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc inferSeverity*(text: string): BuildSeverity =
  ## Infer a severity from free-form message text.
  ## Falls back to SevError when no keyword is recognised.
  let lower = text.toLowerAscii
  if "warning" in lower:
    return SevWarning
  if "info" in lower or "note" in lower or "hint" in lower:
    return SevInfo
  return SevError

proc allDigits*(s: string): bool =
  ## Return true when every character in `s` is a decimal digit.
  if s.len == 0:
    return false
  for ch in s:
    if ch < '0' or ch > '9':
      return false
  return true

# ---------------------------------------------------------------------------
# Individual pattern parsers
#
# Each proc returns a ParsedBuildLocation with `found = true` on match.
# The order in which these are tried matters -- more specific patterns
# (like Rust's ` --> `) come first so that ambiguous lines are not
# claimed by a greedy generic pattern.
# ---------------------------------------------------------------------------

proc parseNimLocation*(raw: string): ParsedBuildLocation =
  ## Nim format: path/file.nim(line, col) severity: message
  ## Also matches TypeScript: src/index.ts(42,5): error TS2304: message
  ##
  ## We look for `(<digits>,<digits>)` or `(<digits>)` after a file path.
  let parenLeft = raw.find("(")
  if parenLeft == -1 or parenLeft == 0:
    return ParsedBuildLocation(found: false)

  let parenRight = raw.find(")", parenLeft)
  if parenRight == -1:
    return ParsedBuildLocation(found: false)

  let inside = raw[parenLeft + 1 ..< parenRight]
  let comma = inside.find(",")

  var lineNum = -1
  var colNum = -1

  if comma != -1:
    let linePart = inside[0 ..< comma].strip
    let colPart = inside[comma + 1 .. ^1].strip
    if not allDigits(linePart):
      return ParsedBuildLocation(found: false)
    lineNum = linePart.parseInt
    if allDigits(colPart):
      colNum = colPart.parseInt
    else:
      return ParsedBuildLocation(found: false)
  else:
    let linePart = inside.strip
    if not allDigits(linePart):
      return ParsedBuildLocation(found: false)
    lineNum = linePart.parseInt

  let path = raw[0 ..< parenLeft]
  let rest = if parenRight + 1 < raw.len: raw[parenRight + 1 .. ^1].strip else: ""
  let severity = inferSeverity(rest)

  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: colNum,
    severity: severity,
    message: rest)

proc parseRustLocation*(raw: string): ParsedBuildLocation =
  ## Rust (cargo) format:  --> src/main.rs:42:5
  ## The line starts with optional whitespace followed by `-->`.
  let stripped = raw.strip
  if not stripped.startsWith("-->"):
    return ParsedBuildLocation(found: false)

  let rest = stripped[3 .. ^1].strip  # after "-->"

  # rest should be  path:line:col
  # Split from the right to handle paths containing colons (e.g. Windows).
  # We need at least one colon for path:line and optionally path:line:col.
  let lastColon = rest.rfind(":")
  if lastColon == -1:
    return ParsedBuildLocation(found: false)

  let afterLast = rest[lastColon + 1 .. ^1]
  if not allDigits(afterLast):
    return ParsedBuildLocation(found: false)

  let beforeLast = rest[0 ..< lastColon]
  let secondColon = beforeLast.rfind(":")
  if secondColon == -1:
    # Only path:line
    return ParsedBuildLocation(
      found: true,
      path: beforeLast,
      line: afterLast.parseInt,
      col: -1,
      severity: SevError,
      message: "")

  let afterSecond = beforeLast[secondColon + 1 .. ^1]
  if allDigits(afterSecond):
    # path:line:col
    return ParsedBuildLocation(
      found: true,
      path: beforeLast[0 ..< secondColon],
      line: afterSecond.parseInt,
      col: afterLast.parseInt,
      severity: SevError,
      message: "")
  else:
    # The middle segment is not digits, so treat as path:line
    return ParsedBuildLocation(
      found: true,
      path: beforeLast,
      line: afterLast.parseInt,
      col: -1,
      severity: SevError,
      message: "")

const
  BoxTopLeft = "\xE2\x94\x8C"      ## `┌` U+250C — `codespan-reporting`, which
                                   ## is what `nargo` renders through.
  BoxRoundTopLeft = "\xE2\x95\xAD" ## `╭` U+256D — `ariadne`'s corner, same
                                   ## family, same `path:line:col` payload.
  BoxHorizontal = "\xE2\x94\x80"   ## `─` U+2500

proc splitTrailingLineCol(rest: string): ParsedBuildLocation =
  ## `path:line:col` or `path:line`, split from the RIGHT so that a Windows
  ## drive letter or any other colon inside the path survives. Shared by the
  ## Noir matcher; `parseRustLocation` does the same thing inline.
  let lastColon = rest.rfind(":")
  if lastColon == -1:
    return ParsedBuildLocation(found: false)

  let afterLast = rest[lastColon + 1 .. ^1]
  if not allDigits(afterLast):
    return ParsedBuildLocation(found: false)

  let beforeLast = rest[0 ..< lastColon]
  let secondColon = beforeLast.rfind(":")
  if secondColon != -1:
    let middle = beforeLast[secondColon + 1 .. ^1]
    if allDigits(middle):
      return ParsedBuildLocation(
        found: true,
        path: beforeLast[0 ..< secondColon],
        line: middle.parseInt,
        col: afterLast.parseInt,
        severity: SevError,
        message: "")

  # Only `path:line`.
  if beforeLast.len == 0:
    return ParsedBuildLocation(found: false)
  ParsedBuildLocation(
    found: true,
    path: beforeLast,
    line: afterLast.parseInt,
    col: -1,
    severity: SevError,
    message: "")

proc parseNoirLocation*(raw: string): ParsedBuildLocation =
  ## Noir (`nargo`) and every other `codespan-reporting` / `ariadne` producer:
  ##
  ##     warning: unused variable x
  ##       ┌─ src/main.nr:1:9
  ##     ╭─[src/main.nr:1:9]
  ##
  ## Only the second and third lines are locations; the first carries the
  ## severity and is matched by `parseSeverityHeader`.
  ##
  ## ## `severity` is `SevError` here and that is not a claim
  ##
  ## The location line has no keyword on it, so a single-line function cannot
  ## know. `SevError` is the struct's zero value and every other parser in this
  ## module does the same for a line that carries no keyword. **Callers that
  ## have the surrounding lines must not use it** — they use
  ## `BuildLocationScanner`, which sets the field from the header above. See
  ## the module header: reporting a warning as an error is the specific defect
  ## this matcher was written to end, and it would be reintroduced by trusting
  ## this field.
  var stripped = raw.strip
  if stripped.startsWith(BoxTopLeft):
    stripped = stripped[BoxTopLeft.len .. ^1]
  elif stripped.startsWith(BoxRoundTopLeft):
    stripped = stripped[BoxRoundTopLeft.len .. ^1]
  else:
    return ParsedBuildLocation(found: false)

  # The rule between the corner and the path is any run of `─`, and the whole
  # thing may be bracketed (`ariadne`) or not (`codespan-reporting`).
  while stripped.startsWith(BoxHorizontal):
    stripped = stripped[BoxHorizontal.len .. ^1]
  stripped = stripped.strip
  if stripped.startsWith("["):
    stripped = stripped[1 .. ^1]
  if stripped.endsWith("]"):
    stripped = stripped[0 ..< stripped.len - 1]
  stripped = stripped.strip
  if stripped.len == 0:
    return ParsedBuildLocation(found: false)

  splitTrailingLineCol(stripped)

proc parsePythonLocation*(raw: string): ParsedBuildLocation =
  ## Python format:   File "script.py", line 42, in <module>
  ## Also handles:    File "script.py", line 42
  let stripped = raw.strip
  if not stripped.startsWith("File \""):
    return ParsedBuildLocation(found: false)

  let quoteEnd = stripped.find("\"", 6)  # closing quote after `File "`
  if quoteEnd == -1:
    return ParsedBuildLocation(found: false)

  let path = stripped[6 ..< quoteEnd]

  # After the closing quote we expect `, line <number>`
  let afterQuote = stripped[quoteEnd + 1 .. ^1].strip
  if not afterQuote.startsWith(", line "):
    return ParsedBuildLocation(found: false)

  let lineStr = afterQuote[7 .. ^1]  # after ", line "
  # lineStr may contain more text after the number (", in <module>")
  var numEnd = 0
  while numEnd < lineStr.len and lineStr[numEnd] >= '0' and lineStr[numEnd] <= '9':
    inc numEnd

  if numEnd == 0:
    return ParsedBuildLocation(found: false)

  let lineNum = lineStr[0 ..< numEnd].parseInt
  let rest = if numEnd < lineStr.len: lineStr[numEnd .. ^1].strip else: ""

  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: -1,
    severity: SevError,
    message: rest)

proc parseColonLocation*(raw: string): ParsedBuildLocation =
  ## Generic colon-separated format used by GCC/Clang and Go:
  ##   file.c:42:5: error: expected ';' before '}' token
  ##   ./main.go:42:5: undefined: fmt.Printlm
  ##
  ## Pattern: <path>:<line>:<col>: <rest>  or  <path>:<line>: <rest>
  ##
  ## To avoid false positives we require:
  ##   - the path portion to contain a dot (file extension) or a slash,
  ##   - <line> to be all digits.

  # Find the first colon that could end the path part.
  # Skip a leading drive letter on Windows (e.g. C:).
  var searchStart = 0
  if raw.len >= 3 and raw[1] == ':' and raw[0].isAlphaAscii:
    searchStart = 2

  let firstColon = raw.find(":", searchStart)
  if firstColon == -1:
    return ParsedBuildLocation(found: false)

  let path = raw[0 ..< firstColon]
  # Path heuristic: must look like a file reference.
  if not ("." in path or "/" in path or "\\" in path):
    return ParsedBuildLocation(found: false)

  let afterPath = raw[firstColon + 1 .. ^1]
  let secondColon = afterPath.find(":")
  if secondColon == -1:
    return ParsedBuildLocation(found: false)

  let lineStr = afterPath[0 ..< secondColon]
  if not allDigits(lineStr):
    return ParsedBuildLocation(found: false)

  let lineNum = lineStr.parseInt

  let afterLine = afterPath[secondColon + 1 .. ^1]
  let thirdColon = afterLine.find(":")
  if thirdColon != -1:
    let colStr = afterLine[0 ..< thirdColon].strip
    if allDigits(colStr):
      let rest = afterLine[thirdColon + 1 .. ^1].strip
      let severity = inferSeverity(rest)
      return ParsedBuildLocation(
        found: true,
        path: path,
        line: lineNum,
        col: colStr.parseInt,
        severity: severity,
        message: rest)

  # Only path:line: rest  (no column)
  let rest = afterLine.strip
  let severity = inferSeverity(rest)
  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: -1,
    severity: severity,
    message: rest)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc parseBuildLocation*(raw: string): ParsedBuildLocation =
  ## Try to parse an error/warning location from a build output line.
  ##
  ## Patterns are tried in order from most specific to most generic:
  ##   1. Rust (`-->`)
  ##   2. Noir / codespan / ariadne (`┌─ path:line:col`)
  ##   3. Python (`File "..."`)
  ##   4. Nim / TypeScript (`path(line,col)`)
  ##   5. GCC / Clang / Go (`path:line:col:`)
  ##
  ## Noir must come before the generic colon form, and the ordering is
  ## load-bearing rather than cosmetic: `parseColonLocation`'s path heuristic
  ## accepts anything containing a `.` or a `/`, so it *matched* the
  ## box-drawing line and produced a corrupted row instead of no row. A
  ## non-match would have been visible; that was not.

  # Rust arrow pattern is unambiguous -- try first.
  result = parseRustLocation(raw)
  if result.found:
    return

  # Noir / codespan-reporting / ariadne box rule -- also unambiguous, and it
  # must be claimed here or `parseColonLocation` claims it wrongly.
  result = parseNoirLocation(raw)
  if result.found:
    return

  # Python traceback format is also distinctive.
  result = parsePythonLocation(raw)
  if result.found:
    return

  # Nim / TypeScript parenthesised location.
  result = parseNimLocation(raw)
  if result.found:
    return

  # Generic colon format (GCC, Clang, Go, etc.).
  result = parseColonLocation(raw)
  if result.found:
    return

  return ParsedBuildLocation(found: false)

# ---------------------------------------------------------------------------
# Severity that lives on a different line from the location
# ---------------------------------------------------------------------------

type
  ParsedSeverityHeader* = object
    ## A `codespan-reporting` / `ariadne` diagnostic *header*:
    ##
    ##     error: Expected type bool, found type Field
    ##     warning[unused_variable]: unused variable x
    ##
    ## It carries the severity and the compiler's sentence, and no location.
    ## The location is on the line below.
    found*: bool
    severity*: BuildSeverity
    message*: string

  BuildLocationScanner* = object
    ## The line-by-line reader a build producer drives, for the families whose
    ## severity is not on the location line.
    ##
    ## Explicit state, owned by the caller — deliberately not a module-level
    ## `var`. Two builds running at once must not colour each other's rows, and
    ## a rerun must not inherit the previous run's last keyword. A global would
    ## also make `parseBuildLocation` answer differently for the same input
    ## depending on what had been fed to it earlier, which is precisely the
    ## property that makes a parser untestable.
    pendingSeverity: BuildSeverity
    pendingMessage: string
    havePending: bool

proc parseSeverityHeader*(raw: string): ParsedSeverityHeader =
  ## `error: …`, `warning: …`, `note: …`, `help: …`, with an optional
  ## bracketed lint name (`warning[unused_variable]: …`).
  ##
  ## Anchored to the START of the stripped line, which is what keeps
  ## `"Aborting due to 1 previous error"` — a real line in the recorded
  ## transcript — from being read as a severity.
  let stripped = raw.strip
  let colon = stripped.find(':')
  if colon <= 0:
    return ParsedSeverityHeader(found: false)

  var keyword = stripped[0 ..< colon]
  let bracket = keyword.find('[')
  if bracket >= 0:
    if not keyword.endsWith("]"):
      return ParsedSeverityHeader(found: false)
    keyword = keyword[0 ..< bracket]

  let message =
    if colon + 1 < stripped.len: stripped[colon + 1 .. ^1].strip else: ""

  case keyword.toLowerAscii
  of "error", "fatal error":
    ParsedSeverityHeader(found: true, severity: SevError, message: message)
  of "warning", "warn":
    ParsedSeverityHeader(found: true, severity: SevWarning, message: message)
  of "note", "info", "help", "hint":
    ParsedSeverityHeader(found: true, severity: SevInfo, message: message)
  else:
    ParsedSeverityHeader(found: false)

proc reset*(scanner: var BuildLocationScanner) =
  ## Called when a new build starts. A pending keyword from the previous run
  ## must never colour the first row of the next one.
  scanner = BuildLocationScanner()

proc scan*(scanner: var BuildLocationScanner;
           raw: string): ParsedBuildLocation =
  ## One line of child output, in order, with the severity carried forward.
  ##
  ## This is what `parseBuildLocation` cannot be: for `nargo` the keyword is on
  ## the line above the location, so a producer that calls the stateless
  ## function per line reports every Noir warning as an error. On the recorded
  ## fixture that is two rows of three.
  ##
  ## A header line is consumed and yields no row of its own — the row is
  ## emitted when the location beneath it arrives, carrying the header's
  ## sentence as its message.
  let header = parseSeverityHeader(raw)
  if header.found:
    scanner.pendingSeverity = header.severity
    scanner.pendingMessage = header.message
    scanner.havePending = true
    return ParsedBuildLocation(found: false)

  result = parseNoirLocation(raw)
  if result.found:
    if scanner.havePending:
      result.severity = scanner.pendingSeverity
      result.message = scanner.pendingMessage
      scanner.havePending = false
    return

  result = parseBuildLocation(raw)
  if result.found:
    # Every other family puts the keyword on the location line itself, so the
    # parsed severity is the compiler's own and a pending header is stale.
    scanner.havePending = false
