## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. This module reaches `std/*` and `monarch`'s
## token type and nothing else.
##
## app/syntax/json_tokens.nim — Monaco's JSON tokenizer, ported (PLAT-47, B4).
##
## Monaco's JSON is not a Monarch definition: its language service installs a
## scanner-based tokenizer (`monaco-editor/esm/vs/language/json/jsonMode.js`,
## `createTokenizationSupport(true)` over jsonc-parser's `createScanner`). This
## is that function, line for line: the same scanner (whitespace, strings with
## their escapes, numbers, `true`/`false`/`null`, `//` and `/* */` comments,
## anything else one "unknown" run), the same token types
## (`delimiter.bracket.json` for braces, `delimiter.array.json` for brackets,
## `string.key.json` for a string that is neither after a colon nor in an
## array, `string.value.json` otherwise, ...), and the same state carried
## between lines — the scan error that makes the next line start inside a
## string or a comment, `lastWasColon`, and the stack of enclosing objects and
## arrays.

import std/strutils

import ./monarch

type
  JsonLineState* = object
    scanError*: int        ## 0 none, 1 unterminated comment, 2 unterminated string
    lastWasColon*: bool
    parents*: string       ## 'O' / 'A' per enclosing object / array, outermost first

const
  TokenDelimObject = "delimiter.bracket.json"
  TokenDelimArray = "delimiter.array.json"
  TokenDelimColon = "delimiter.colon.json"
  TokenDelimComma = "delimiter.comma.json"
  TokenKeyword = "keyword.json"
  TokenString = "string.value.json"
  TokenNumber = "number.json"
  TokenKey = "string.key.json"
  TokenCommentBlock = "comment.block.json"
  TokenCommentLine = "comment.line.json"

func isWhite(c: char): bool = c == ' ' or c == '\t'
func isBreak(c: char): bool = c == '\n' or c == '\r'
func isDigitChar(c: char): bool = c in {'0'..'9'}

func encodeJsonState*(s: JsonLineState): string =
  "json:" & $s.scanError & ":" & (if s.lastWasColon: "1" else: "0") & ":" &
    s.parents

func decodeJsonState*(s: string): JsonLineState =
  let parts = s.split(':')
  if parts.len == 4 and parts[0] == "json":
    try:
      result.scanError = parseInt(parts[1])
    except ValueError:
      discard
    result.lastWasColon = parts[2] == "1"
    result.parents = parts[3]

type
  ScanKind = enum
    skOpenBrace, skCloseBrace, skOpenBracket, skCloseBracket, skComma,
    skColon, skNull, skTrue, skFalse, skString, skNumber, skLineComment,
    skBlockComment, skLineBreak, skTrivia, skUnknown, skEof

  Scanner = object
    text: string
    pos: int
    error: int

proc scanHex(s: var Scanner; count: int): int =
  var digits = 0
  var value = 0
  while digits < count and s.pos < s.text.len:
    let c = s.text[s.pos]
    if c in {'0'..'9'}: value = value * 16 + ord(c) - ord('0')
    elif c in {'A'..'F'}: value = value * 16 + ord(c) - ord('A') + 10
    elif c in {'a'..'f'}: value = value * 16 + ord(c) - ord('a') + 10
    else: break
    inc s.pos
    inc digits
  if digits < count: -1 else: value

proc scanNumber(s: var Scanner) =
  if s.pos < s.text.len and s.text[s.pos] == '0':
    inc s.pos
  else:
    inc s.pos
    while s.pos < s.text.len and isDigitChar(s.text[s.pos]): inc s.pos
  if s.pos < s.text.len and s.text[s.pos] == '.':
    inc s.pos
    if s.pos < s.text.len and isDigitChar(s.text[s.pos]):
      inc s.pos
      while s.pos < s.text.len and isDigitChar(s.text[s.pos]): inc s.pos
    else:
      s.error = 3
      return
  if s.pos < s.text.len and s.text[s.pos] in {'E', 'e'}:
    inc s.pos
    if s.pos < s.text.len and s.text[s.pos] in {'+', '-'}:
      inc s.pos
    if s.pos < s.text.len and isDigitChar(s.text[s.pos]):
      inc s.pos
      while s.pos < s.text.len and isDigitChar(s.text[s.pos]): inc s.pos
    else:
      s.error = 3

proc scanString(s: var Scanner) =
  while true:
    if s.pos >= s.text.len:
      s.error = 2
      return
    let c = s.text[s.pos]
    if c == '"':
      inc s.pos
      return
    if c == '\\':
      inc s.pos
      if s.pos >= s.text.len:
        s.error = 2
        return
      let c2 = s.text[s.pos]
      inc s.pos
      case c2
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't': discard
      of 'u':
        if s.scanHex(4) < 0: s.error = 4
      else: s.error = 5
      continue
    if ord(c) <= 31:
      if isBreak(c):
        s.error = 2
        return
      s.error = 6
    inc s.pos

func isUnknownContent(c: char): bool =
  not (isWhite(c) or isBreak(c) or c in {'}', ']', '{', '[', '"', ':', ',', '/'})

proc scan(s: var Scanner): ScanKind =
  s.error = 0
  if s.pos >= s.text.len:
    return skEof
  let c = s.text[s.pos]
  if isWhite(c):
    while s.pos < s.text.len and isWhite(s.text[s.pos]): inc s.pos
    return skTrivia
  if isBreak(c):
    inc s.pos
    if c == '\r' and s.pos < s.text.len and s.text[s.pos] == '\n': inc s.pos
    return skLineBreak
  case c
  of '{': inc s.pos; skOpenBrace
  of '}': inc s.pos; skCloseBrace
  of '[': inc s.pos; skOpenBracket
  of ']': inc s.pos; skCloseBracket
  of ':': inc s.pos; skColon
  of ',': inc s.pos; skComma
  of '"':
    inc s.pos
    s.scanString()
    skString
  of '/':
    if s.pos + 1 < s.text.len and s.text[s.pos + 1] == '/':
      s.pos += 2
      while s.pos < s.text.len and not isBreak(s.text[s.pos]): inc s.pos
      return skLineComment
    if s.pos + 1 < s.text.len and s.text[s.pos + 1] == '*':
      s.pos += 2
      let safeLength = s.text.len - 1
      var closed = false
      while s.pos < safeLength:
        if s.text[s.pos] == '*' and s.text[s.pos + 1] == '/':
          s.pos += 2
          closed = true
          break
        inc s.pos
      if not closed:
        inc s.pos
        s.error = 1
      return skBlockComment
    inc s.pos
    skUnknown
  of '-':
    inc s.pos
    if s.pos == s.text.len or not isDigitChar(s.text[s.pos]):
      return skUnknown
    s.scanNumber()
    skNumber
  of '0'..'9':
    s.scanNumber()
    skNumber
  else:
    let start = s.pos
    while s.pos < s.text.len and isUnknownContent(s.text[s.pos]): inc s.pos
    if s.pos != start:
      case s.text[start ..< s.pos]
      of "true": return skTrue
      of "false": return skFalse
      of "null": return skNull
      else: return skUnknown
    inc s.pos
    skUnknown

proc jsonTokenizeLine*(line: string; state: var JsonLineState): seq[MonarchToken] =
  ## One line of JSON as Monaco's JSON tokenizer (with comments) tokenises it,
  ## starting in `state` and leaving `state` as the line leaves it.
  var text = line
  var inserted = 0
  case state.scanError
  of 2:
    text = "\"" & line
    inserted = 1
  of 1:
    text = "/*" & line
    inserted = 2
  else: discard
  var s = Scanner(text: text)
  var lastWasColon = state.lastWasColon
  var parents = state.parents
  var adjust = false
  var endState = state
  while true:
    var offset = s.pos
    let kind = s.scan()
    if kind == skEof:
      break
    if adjust:
      offset -= inserted
    adjust = inserted > 0
    var t = ""
    case kind
    of skOpenBrace:
      parents.add 'O'; t = TokenDelimObject; lastWasColon = false
    of skCloseBrace:
      if parents.len > 0: parents.setLen(parents.len - 1)
      t = TokenDelimObject; lastWasColon = false
    of skOpenBracket:
      parents.add 'A'; t = TokenDelimArray; lastWasColon = false
    of skCloseBracket:
      if parents.len > 0: parents.setLen(parents.len - 1)
      t = TokenDelimArray; lastWasColon = false
    of skColon:
      t = TokenDelimColon; lastWasColon = true
    of skComma:
      t = TokenDelimComma; lastWasColon = false
    of skTrue, skFalse, skNull:
      t = TokenKeyword; lastWasColon = false
    of skString:
      let inArray = parents.len > 0 and parents[^1] == 'A'
      t = if lastWasColon or inArray: TokenString else: TokenKey
      lastWasColon = false
    of skNumber:
      t = TokenNumber; lastWasColon = false
    of skLineComment: t = TokenCommentLine
    of skBlockComment: t = TokenCommentBlock
    else: discard
    endState = JsonLineState(scanError: s.error, lastWasColon: lastWasColon,
                             parents: parents)
    result.add MonarchToken(start: max(0, offset), tokenType: t)
  state = endState
