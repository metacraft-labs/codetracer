## A small, self-contained **lexical** scanner for Nim source text.
##
## What it is for
## --------------
## Several ct_test surfaces need to answer questions of the form "does this
## identifier / this ``#`` / this quote occur in *code*, or inside a comment or
## a literal?" — the Nim ``std/unittest`` provider is the first consumer, but
## the question is not framework-specific, so the answer lives here rather than
## inside one provider.
##
## Getting Nim's ``'`` right is the whole reason this module exists.  A naive
## scanner that treats every apostrophe as a character-literal opener desyncs
## on perfectly ordinary source:
##
## .. code-block:: nim
##   sizeBytes: 10485760'i64,     # <- NOT a character literal
##
## and then "skips a string" all the way to the next apostrophe — swallowing
## whatever suite/test declarations lay in between.  Nim's grammar has three
## distinct apostrophe roles (character literal, numeric type suffix, custom
## numeric literal) plus accent-quoted identifiers such as ``` `'u8` ```, and
## they can only be told apart by lexing numbers and identifiers *first*.
##
## Why a new scanner instead of reusing one
## ----------------------------------------
## Three existing tokenizers were evaluated first:
##
## * **``compiler/lexer`` from the Nim distribution.**  It is the ground truth,
##   and every rule below is written against it (see the citations on each
##   procedure).  It is nonetheless unusable here: it is not a package
##   dependency of codetracer, it ships only inside the Nim *installation*
##   (``$nim/nim/compiler``, a Nix store path that moves with every toolchain
##   bump), it pulls in ``options``/``msgs``/``idents``/``llstream`` — which own
##   global compiler configuration and *terminate the process* through
##   ``lexMessage`` on a malformed literal — and its token API is compiler
##   internals that change between minor releases.  ct_test lexes untrusted,
##   possibly-broken third-party sources; aborting on them is not an option.
## * **``std/parseutils`` / ``std/strscans``.**  Neither knows Nim's literal
##   grammar; using them would only relocate the hand-rolled part.
## * **The JavaScript lexer in ``ct_test/incremental/extractors.nim``.**
##   Different language, different literal rules.  Nothing reusable except its
##   fail-safe philosophy, which this module adopts.
##
## Fail-safe by construction
## -------------------------
## Every construct that Nim requires to close on the same line (single-quoted
## string, character literal) is terminated at the newline if its closer is
## missing, and an apostrophe with no plausible closer degrades to a single
## ordinary character.  A malformed source therefore costs at most one
## mis-classified token — never the remainder of the file.  This is the
## property the previous scanner lacked.
##
## Scope
## -----
## This is a *lexer*, not a parser: it produces a flat token stream with source
## positions.  It knows nothing about indentation, statements or scoping.

const
  NimSymStartChars* = {'a' .. 'z', 'A' .. 'Z', '\x80' .. '\xFF'}
    ## ``compiler/lexer.SymStartChars``: bytes >= 0x80 are accepted so UTF-8
    ## identifiers survive as identifiers instead of being split into punct.
  NimSymChars* = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '\x80' .. '\xFF'}
    ## ``compiler/lexer.SymChars``.
  NimIdentStartChars* = NimSymStartChars + {'_'}
  NimIdentChars* = NimSymChars + {'_'}

  MaxCharLiteralBody = 8
    ## Fail-safe bound for the character-literal lookahead.  The longest legal
    ## body is four bytes (``'\255'``, ``'\x41'``, a 4-byte UTF-8 rune); the
    ## slack keeps unusual-but-harmless input working while still refusing to
    ## treat a far-away apostrophe as a closer.

type
  NimTokenKind* = enum
    ntkIdent                    ## identifier or keyword (``_`` included)
    ntkNumber                   ## numeric literal *including* its type suffix
    ntkString                   ## string literal in any of Nim's five forms
    ntkChar                     ## character literal
    ntkComment                  ## ``#``, ``##``, ``#[ ]#`` or ``##[ ]##``
    ntkPunct                    ## any other single character (operators, brackets)

  NimToken* = object
    ## One lexical token: where it is, and — for the literals whose meaning is
    ## not recoverable from their source text — what it means.
    ##
    ## Deliberately position-first.  This runs over every candidate source file
    ## in a workspace, so the token stream does NOT carry a copy of each
    ## token's source slice: use ``sliceOf`` when the text is wanted and
    ## ``identIs``/``ch`` for the comparisons that would otherwise allocate a
    ## throwaway string per token.
    kind*: NimTokenKind
    value*: string              ## DECODED body of an ``ntkString``/``ntkChar``
                                ## (escapes resolved, delimiters removed).
                                ## Empty for every other kind — their meaning
                                ## *is* their source slice.
    prefix*: string             ## generalized-raw-literal prefix: ``re"…"`` -> ``"re"``
    ch*: char                   ## the character of an ``ntkPunct`` token;
                                ## ``'\0'`` for every other kind
    multiline*: bool            ## token spans more than one source line
    terminated*: bool           ## the closing delimiter was actually found
                                ## (always true for kinds that cannot be
                                ## unterminated: identifiers, numbers, punct)
    startOffset*: int           ## byte offset of the first character
    endOffset*: int             ## byte offset ONE PAST the last character
    line*, column*: int         ## 1-based position of the first character
    endLine*, endColumn*: int   ## 1-based position of the LAST character

  NimLexer = object
    src: string
    pos: int
    line: int
    column: int
    lastLine: int               ## line of the most recently consumed character
    lastColumn: int             ## column of the most recently consumed character

proc initNimLexer(source: string): NimLexer =
  NimLexer(src: source, pos: 0, line: 1, column: 1, lastLine: 1, lastColumn: 1)

proc atEnd(lx: NimLexer): bool {.inline.} =
  lx.pos >= lx.src.len

proc peek(lx: NimLexer; offset = 0): char {.inline.} =
  ## Reading past the end yields ``'\0'``, mirroring the compiler lexer's
  ## sentinel-terminated buffer, so every lookahead below is bounds-safe.
  let i = lx.pos + offset
  if i >= 0 and i < lx.src.len: lx.src[i] else: '\0'

proc advance(lx: var NimLexer) =
  if lx.pos >= lx.src.len:
    return
  lx.lastLine = lx.line
  lx.lastColumn = lx.column
  if lx.src[lx.pos] == '\n':
    inc lx.line
    lx.column = 1
  else:
    inc lx.column
  inc lx.pos

proc advanceBy(lx: var NimLexer; count: int) =
  for _ in 0 ..< count:
    lx.advance()

proc skipSpace(lx: var NimLexer) =
  ## Whitespace, including newlines: this lexer does not model indentation.
  while lx.peek in {' ', '\t', '\r', '\n'}:
    lx.advance()

proc matchesAt(lx: NimLexer; offset: int; text: string): bool =
  for i, ch in text:
    if lx.peek(offset + i) != ch:
      return false
  true

# ---------------------------------------------------------------------------
# Individual constructs.  Each proc is entered with ``lx.pos`` on the token's
# first character and leaves it one past the token's last character.
# ---------------------------------------------------------------------------

proc skipIdent(lx: var NimLexer) =
  while lx.peek in NimIdentChars:
    lx.advance()

proc lexDigits(lx: var NimLexer; digits: set[char]) =
  ## Digit run with Nim's single-underscore separators (``1_000_000``).
  ## Mirrors ``compiler/lexer.matchUnderscoreChars``: an underscore is part of
  ## the literal only when another digit follows it.
  while true:
    if lx.peek in digits:
      lx.advance()
    elif lx.peek == '_' and lx.peek(1) in digits:
      lx.advance()
    else:
      break

proc lexNumber(lx: var NimLexer): NimToken =
  ## Numeric literal, **including any type suffix**.
  ##
  ## Consuming the suffix here is the fix for the apostrophe desync: after this
  ## returns, ``10485760'i64`` is one token and the apostrophe is gone, so the
  ## main loop can safely treat a remaining ``'`` as a character literal.
  ##
  ## Follows ``compiler/lexer.getNumber``: base prefixes ``0x/0X 0o 0b/0B``
  ## (plus the deprecated ``0c/0C``), a decimal body with an optional fraction
  ## (only when a digit follows the ``.``, so ``1..2`` stays a range) and an
  ## optional exponent, then a suffix that is either apostrophe-introduced
  ## (``0'u8``, ``1.0'f32``, ``1'MyType``) or bare (``1u8``, ``1f32``).
  result = NimToken(kind: ntkNumber, terminated: true)
  result.startOffset = lx.pos
  result.line = lx.line
  result.column = lx.column

  if lx.peek == '0' and lx.peek(1) in {'x', 'X', 'o', 'O', 'b', 'B', 'c', 'C'}:
    let base = lx.peek(1)
    lx.advanceBy(2)
    case base
    of 'x', 'X': lx.lexDigits({'0' .. '9', 'a' .. 'f', 'A' .. 'F'})
    of 'b', 'B': lx.lexDigits({'0', '1'})
    else: lx.lexDigits({'0' .. '7'})
  else:
    lx.lexDigits({'0' .. '9'})
    if lx.peek == '.' and lx.peek(1) in {'0' .. '9'}:
      lx.advance()
      lx.lexDigits({'0' .. '9'})
    if lx.peek in {'e', 'E'}:
      # An exponent must have digits; `1e` alone is not a float literal, and
      # consuming the `e` anyway would only mis-slice an already-invalid file.
      var offset = 1
      if lx.peek(offset) in {'+', '-'}:
        inc offset
      if lx.peek(offset) in {'0' .. '9'}:
        lx.advanceBy(offset)
        lx.lexDigits({'0' .. '9'})

  # Type suffix.  ``compiler/lexer`` accepts it with or without the apostrophe
  # and requires a symbol character to follow either way.
  if lx.peek == '\'':
    if lx.peek(1) in NimSymChars:
      lx.advance()
      while lx.peek in NimIdentChars:
        lx.advance()
  elif lx.peek in {'f', 'F', 'd', 'D', 'i', 'I', 'u', 'U'}:
    while lx.peek in NimIdentChars:
      lx.advance()

  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn

proc lexLineComment(lx: var NimLexer): NimToken =
  result = NimToken(kind: ntkComment, terminated: true)
  result.startOffset = lx.pos
  result.line = lx.line
  result.column = lx.column
  while not lx.atEnd and lx.peek != '\n':
    lx.advance()
  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn

proc lexBlockComment(lx: var NimLexer): NimToken =
  ## Nested block comment.
  ##
  ## Two variants with *different* delimiters, exactly as
  ## ``compiler/lexer.skipMultiLineComment`` implements them:
  ## ``#[`` nests on ``#[`` and closes on ``]#``; the doc form ``##[`` nests on
  ## ``##[`` and closes on ``]##``.  Note that the compiler does **not** track
  ## string literals inside a block comment, so neither do we — a ``"]#"``
  ## inside a ``#[ … ]#`` comment really does close it.
  result = NimToken(kind: ntkComment)
  result.startOffset = lx.pos
  result.line = lx.line
  result.column = lx.column
  let isDoc = lx.peek(1) == '#'
  let opener = if isDoc: "##[" else: "#["
  let closer = if isDoc: "]##" else: "]#"
  var nesting = 0
  while not lx.atEnd:
    if lx.matchesAt(0, opener):
      inc nesting
      lx.advanceBy(opener.len)
    elif lx.matchesAt(0, closer):
      dec nesting
      lx.advanceBy(closer.len)
      if nesting == 0:
        result.terminated = true
        break
    else:
      lx.advance()
  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn
  result.multiline = result.endLine != result.line

proc lexString(lx: var NimLexer; prefix: string; prefixStart, prefixLine,
               prefixColumn: int): NimToken =
  ## String literal in every form Nim has:
  ##
  ## * ``"…"`` — escapes processed;
  ## * ``"""…"""`` — verbatim, closed by the first ``"""`` not followed by
  ##   another ``"`` (``compiler/lexer.getString``), leading newline stripped;
  ## * ``r"…"`` and any generalized raw literal ``ident"…"`` — **no** escapes,
  ##   a doubled ``""`` denotes one quote.  This is why a scanner that always
  ##   honours ``\`` desyncs on ``r"C:\dir\"``.
  ##
  ## ``value`` keeps the pre-existing decoding contract of this codebase for
  ## escapes: the backslash is dropped and the following character kept
  ## verbatim (``"a\nb"`` -> ``anb``).  Test *names* are what callers build
  ## selectors from, and those are plain text in practice; changing the
  ## decoding would silently renumber every existing selector.
  let raw = prefix.len > 0
  result = NimToken(kind: ntkString, prefix: prefix)
  result.startOffset = prefixStart
  result.line = prefixLine
  result.column = prefixColumn

  var triple = false
  if lx.peek(1) == '"' and lx.peek(2) == '"':
    triple = true
    lx.advanceBy(3)
  else:
    lx.advance()

  if triple:
    # Nim drops one leading newline (optionally preceded by blanks) so the
    # opening delimiter can sit on its own line.
    var lead = 0
    while lx.peek(lead) in {' ', '\t'}:
      inc lead
    if lx.peek(lead) == '\r' and lx.peek(lead + 1) == '\n':
      lx.advanceBy(lead + 2)
    elif lx.peek(lead) in {'\r', '\n'}:
      lx.advanceBy(lead + 1)
    while not lx.atEnd:
      if lx.peek == '"' and lx.peek(1) == '"' and lx.peek(2) == '"' and
          lx.peek(3) != '"':
        lx.advanceBy(3)
        result.terminated = true
        break
      result.value.add lx.peek
      lx.advance()
  else:
    while not lx.atEnd:
      let ch = lx.peek
      if ch == '"':
        if raw and lx.peek(1) == '"':
          # Raw / generalized literals escape a quote by doubling it.
          result.value.add '"'
          lx.advanceBy(2)
          continue
        lx.advance()
        result.terminated = true
        break
      if ch in {'\r', '\n'}:
        # Fail-safe: a single-quoted string cannot cross a line.  Stop here
        # instead of running to the next quote somewhere further down the file.
        break
      if ch == '\\' and not raw:
        lx.advance()
        if not lx.atEnd and lx.peek notin {'\r', '\n'}:
          result.value.add lx.peek
          lx.advance()
        continue
      result.value.add ch
      lx.advance()

  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn
  result.multiline = result.endLine != result.line

proc tryLexChar(lx: var NimLexer): NimToken =
  ## Character literal, or — when no closer is in reach — a bare apostrophe.
  ##
  ## Reached only when the apostrophe is *not* part of a numeric literal
  ## (``lexNumber`` has already eaten those) and not inside a comment or
  ## string.  The remaining ambiguity is the accent-quoted custom-literal
  ## operator name ``` `'u8` ```, which has no closing apostrophe on the line
  ## and therefore falls through to the ``ntkPunct`` result, exactly like
  ## ``compiler/lexer.getCharacter``'s backtick special case.
  let startPos = lx.pos
  let startLine = lx.line
  let startColumn = lx.column

  # Look for the closer without consuming anything yet.
  var offset = 1
  var found = -1
  if lx.peek(offset) == '\\':
    offset += 2
  elif lx.peek(offset) notin {'\0', '\r', '\n', '\''}:
    inc offset
  while offset <= MaxCharLiteralBody:
    let ch = lx.peek(offset)
    if ch == '\'':
      found = offset
      break
    if ch in {'\0', '\r', '\n'}:
      break
    inc offset

  if found < 0:
    result = NimToken(kind: ntkPunct, ch: '\'', terminated: true,
                      startOffset: startPos, line: startLine,
                      column: startColumn, endLine: startLine,
                      endColumn: startColumn)
    lx.advance()
    result.endOffset = lx.pos
    return

  result = NimToken(kind: ntkChar, terminated: true)
  result.startOffset = startPos
  result.line = startLine
  result.column = startColumn
  lx.advance()                      # opening '
  while lx.pos < startPos + found:
    result.value.add lx.peek
    lx.advance()
  lx.advance()                      # closing '
  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn

proc lexPunct(lx: var NimLexer): NimToken =
  ## Everything else, one character at a time.  Operator runs are deliberately
  ## *not* merged: no consumer needs operator identity, and single characters
  ## keep bracket/paren matching trivial.
  result = NimToken(kind: ntkPunct, terminated: true, ch: lx.peek)
  result.startOffset = lx.pos
  result.line = lx.line
  result.column = lx.column
  lx.advance()
  result.endOffset = lx.pos
  result.endLine = lx.lastLine
  result.endColumn = lx.lastColumn

proc scanNimSource*(source: string): seq[NimToken] =
  ## Tokenize ``source``.  Whitespace produces no tokens; comments do (callers
  ## that want them gone can filter on ``ntkComment``).
  ##
  ## Never raises: malformed input yields the best-effort token stream
  ## described in this module's header.
  var lx = initNimLexer(source)
  while true:
    lx.skipSpace()
    if lx.atEnd:
      break
    let ch = lx.peek
    if ch == '#':
      if lx.peek(1) == '[' or (lx.peek(1) == '#' and lx.peek(2) == '['):
        result.add lx.lexBlockComment()
      else:
        result.add lx.lexLineComment()
    elif ch in {'0' .. '9'}:
      result.add lx.lexNumber()
    elif ch in NimIdentStartChars:
      let
        identStart = lx.pos
        identLine = lx.line
        identColumn = lx.column
      lx.skipIdent()
      if lx.peek == '"':
        # Generalized raw string literal: an identifier immediately followed by
        # a quote (``r"…"``, ``re"…"``, ``fmt"…"``).  ``compiler/lexer`` decides
        # this on the raw preceding character; the two agree because we only
        # get here with the identifier just consumed.  Emitted as ONE token so
        # callers see the prefix and the body together.
        result.add lx.lexString(
          lx.src[identStart ..< lx.pos], identStart, identLine, identColumn)
      else:
        result.add NimToken(
          kind: ntkIdent, terminated: true,
          startOffset: identStart, endOffset: lx.pos,
          line: identLine, column: identColumn,
          endLine: lx.lastLine, endColumn: lx.lastColumn)
    elif ch == '"':
      result.add lx.lexString("", lx.pos, lx.line, lx.column)
    elif ch == '\'':
      result.add lx.tryLexChar()
    else:
      result.add lx.lexPunct()

proc sliceOf*(source: string; token: NimToken): string =
  ## The exact source text of ``token``, delimiters and all.
  ##
  ## Tokens store offsets rather than a copy of their text (see ``NimToken``),
  ## so this is where a caller pays for the string — once, for the tokens it
  ## actually cares about, instead of once per token in the file.
  if token.startOffset >= 0 and token.endOffset <= source.len and
      token.startOffset <= token.endOffset:
    source[token.startOffset ..< token.endOffset]
  else:
    ""

proc identIs*(source: string; token: NimToken; name: string): bool =
  ## ``token`` is the identifier ``name`` — compared in place, without
  ## materialising the identifier as a string.
  token.kind == ntkIdent and
    token.endOffset - token.startOffset == name.len and
    token.endOffset <= source.len and
    (block:
      var same = true
      for i in 0 ..< name.len:
        if source[token.startOffset + i] != name[i]:
          same = false
          break
      same)

proc maskNimNonCode*(source: string; tokens: seq[NimToken]): string =
  ## ``maskNimNonCode`` over an already-scanned token stream.
  ##
  ## Tokenizing is the expensive part of every consumer, so a caller that needs
  ## both the tokens and the masked text takes this overload and pays for one
  ## scan instead of two.
  result = source
  for token in tokens:
    let blank =
      case token.kind
      of ntkComment: true
      of ntkString: token.multiline
      else: false
    if blank:
      for i in token.startOffset ..< min(token.endOffset, result.len):
        if result[i] notin {'\n', '\r'}:
          result[i] = ' '

proc maskNimNonCode*(source: string): string =
  ## Return ``source`` with **comments and multi-line string literals** blanked
  ## out — every byte replaced by a space, newlines preserved — so the result
  ## has byte-for-byte the same length and the same line/column geometry as the
  ## input, and can be scanned line by line without a comment ever being
  ## mistaken for code.
  ##
  ## Single-line string literals are left intact on purpose: the one consumer
  ## (Nim import detection) has to read ``import "some/module"``, which is legal
  ## Nim, and a single-line literal cannot hide a statement from a line-oriented
  ## scan the way a here-doc-style ``"""…"""`` block can.
  maskNimNonCode(source, scanNimSource(source))
