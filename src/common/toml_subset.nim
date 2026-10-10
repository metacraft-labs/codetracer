## common/toml_subset.nim — a strict reader for a small, closed TOML subset.
##
## ## WHY THIS IS IN `common/` AND WHY THERE IS ONLY ONE OF IT
##
## It was written for test certificates (`src/ct_test/certificate.nim`), which
## read TOML that travels in git notes — input anyone with push access can
## rewrite. PLAT-11 reads TOML that travels in a CLONED REPOSITORY, which is
## the same threat with a shorter supply chain, so it wants the same reader
## and specifically the same REFUSALS.
##
## Verification-Harness-Traps §14a is the reason it moved here rather than
## being written a second time: "the worst instance was a whole re-derived
## module". Two TOML readers are two answers to "what does this text mean",
## and the interesting bugs are exactly where they disagree — a duplicate
## key, a table reopened, an array nested past the recursion bound.
##
## ## WHY NOT `libs/parsetoml`
##
## codetracer vendors it and it does not compile against the pinned Nim 2.2
## toolchain (`parsetoml.nim:1725`: seq equality is a `func` and cannot call
## parsetoml's side-effecting `==`), and it is a pinned submodule that must not
## be patched from this repo.
##
## ## WHAT THE SUBSET IS
##
## Basic and literal strings, booleans, arrays, `[table]` and `[[array of
## tables]]` headers. Everything else — integers, floats, dates — is a parse
## ERROR, not a value this reader guesses at. Strictness is the feature: a
## consumer that cannot read its input must report it as unreadable rather
## than silently degrade.
##
## Two further constructs are OPT-IN, per call (`TomlExtension`): inline
## tables and multi-line strings. A test certificate MUST be read from any
## rendering of its fields (Canonical-Payload.md §5), and the standard's
## `vectors/store/` group delivers certificates written with both — an
## `[certificate.vcs]` spelled as an inline table, a `command` array of
## inline tables, a `framework = """…"""`. The certificate reader enables
## them. Nothing else does, so what a project definition or a key store
## accepts is unchanged by the certificate format's needs.
##
## ## PURITY
##
## `std/[strutils, tables]` and nothing else. No filesystem, no process, no
## clock, no network. `common/project_definitions/` asserts that import list
## byte for byte, because its own "no I/O" claim is only as good as the claim
## of everything it imports.

import std/[strutils, tables]

type
  TomlError* = object of CatchableError
    ## Raised when input is not TOML this reader accepts. Deliberately
    ## distinct from any caller's own "this record is invalid" error: "this
    ## file is not readable" and "this record is wrong" are different verdicts.


type
  TomlExtension* = enum
    ## Constructs outside the base subset that a caller may opt into.
    teInlineTables
      ## ``{ key = value, … }``, and arrays of them. TOML 1.0's rules apply:
      ## on one line, no trailing comma, and the table is complete as written
      ## — no header and no dotted key may add to it afterwards.
    teMultilineStrings
      ## ``"""…"""`` and ``'''…'''``, with TOML's trimming of a newline
      ## directly after the opening delimiter and, in the basic form, its
      ## line-ending backslash. A CRLF inside one reads as LF.

  TomlKind* = enum
    tomlString, tomlBool, tomlArray, tomlTable

  TomlNode* = ref object
    ## A parsed TOML value. Only the four kinds a certificate or a key store
    ## can contain exist; anything else is a parse error rather than a value
    ## this reader guesses at.
    case kind*: TomlKind
    of tomlString: strVal*: string
    of tomlBool: boolVal*: bool
    of tomlArray:
      items*: seq[TomlNode]
      fromValue*: bool
        ## ``true`` for an array written as a value (``k = [ … ]``), as
        ## opposed to one built by ``[[header]]`` entries. TOML forbids a
        ## later ``[[k]]`` from appending to a value array: accepting it would
        ## let one document grow an array the author already closed.
    of tomlTable:
      fields*: OrderedTable[string, TomlNode]
      explicit*: bool
        ## ``true`` once a ``[header]`` named this table directly, as opposed
        ## to it having been created implicitly by a dotted header naming one
        ## of its children. TOML permits defining a super-table after its
        ## sub-table (``vectors/payload/escapes/received.toml`` does exactly
        ## that), but not defining the same table twice.
      dotted*: bool
        ## ``true`` when this table was brought into existence by a *dotted
        ## key* (``vcs.repo = "x"``) rather than by a header. TOML forbids a
        ## later ``[header]`` from reopening such a table, and accepting it
        ## would let one document express the same field twice with different
        ## values — a disagreement a verifier would resolve silently.
      sealed*: bool
        ## ``true`` for an inline table (and every table inside one). TOML
        ## makes an inline table complete as written: no header and no dotted
        ## key may add to it later.

  TomlParser = object
    text: string
    pos: int
    depth: int
    extensions: set[TomlExtension]

const MaxTomlNesting* = 32
  ## How deeply arrays may nest.
  ##
  ## Both consumers nest one level — a certificate's ``targets``/``paths``/
  ## ``argv``, a project definition's ``hide`` — so this is orders of magnitude
  ## of headroom. It exists because ``parseArray`` and ``parseValue`` are
  ## mutually recursive and this parser reads **hostile input**: certificates
  ## travel in git notes, which anyone with push access can rewrite
  ## (Transport.md §2), and a project definition travels in a cloned
  ## repository, which nobody evaluated at all (Project-Definitions.md §2).
  ## Unbounded, ``"[" * 200000`` overflows the C stack — a `call depth limit
  ## reached` error in a debug build, and a SIGSEGV in the ``-d:release`` build
  ## `ct` actually ships.
  ##
  ## PUBLIC so a caller's own refusal can name the bound rather than restating
  ## it (Verification-Harness-Traps §14).

proc newTomlTable(): TomlNode =
  TomlNode(kind: tomlTable, fields: initOrderedTable[string, TomlNode](),
           explicit: false, dotted: false, sealed: false)

proc seal(node: TomlNode) =
  ## Mark an inline table, and every table nested in it, complete.
  case node.kind
  of tomlTable:
    node.sealed = true
    node.explicit = true
    for child in node.fields.values:
      seal(child)
  of tomlArray:
    for item in node.items:
      seal(item)
  else: discard

proc fail(p: TomlParser; message: string) {.noreturn.} =
  ## Report the byte offset: a key store is rejected for being unreadable, and
  ## the operator's next step is to open it at the offending place.
  var line = 1
  for i in 0 ..< min(p.pos, p.text.len):
    if p.text[i] == '\n':
      inc line
  raise newException(TomlError, "line " & $line & ": " & message)

proc atEnd(p: TomlParser): bool = p.pos >= p.text.len

proc peek(p: TomlParser): char =
  if p.atEnd: '\0' else: p.text[p.pos]

proc skipInlineSpace(p: var TomlParser) =
  while not p.atEnd and p.text[p.pos] in {' ', '\t'}:
    inc p.pos

proc skipComment(p: var TomlParser) =
  if p.peek == '#':
    while not p.atEnd and p.text[p.pos] notin {'\n'}:
      inc p.pos

proc skipToNextToken(p: var TomlParser) =
  ## Skip whitespace, newlines (LF or CRLF — the reader accepts both, even
  ## though canonical output is LF-only) and comments.
  while not p.atEnd:
    case p.text[p.pos]
    of ' ', '\t', '\r', '\n':
      inc p.pos
    of '#':
      p.skipComment()
    else:
      break

proc encodeUtf8(codePoint: uint32): string =
  ## Encode a scalar value as UTF-8. Used for ``\uXXXX`` / ``\UXXXXXXXX``,
  ## which a verifier MUST accept on input for interoperability even though it
  ## MUST NOT produce them when re-serializing (Canonical-Payload.md §4).
  if codePoint <= 0x7F:
    result = $char(codePoint)
  elif codePoint <= 0x7FF:
    result = $char(0xC0 or (codePoint shr 6))
    result.add char(0x80 or (codePoint and 0x3F))
  elif codePoint <= 0xFFFF:
    result = $char(0xE0 or (codePoint shr 12))
    result.add char(0x80 or ((codePoint shr 6) and 0x3F))
    result.add char(0x80 or (codePoint and 0x3F))
  else:
    result = $char(0xF0 or (codePoint shr 18))
    result.add char(0x80 or ((codePoint shr 12) and 0x3F))
    result.add char(0x80 or ((codePoint shr 6) and 0x3F))
    result.add char(0x80 or (codePoint and 0x3F))

proc parseHexEscape(p: var TomlParser; digits: int): string =
  if p.pos + digits > p.text.len:
    p.fail("truncated unicode escape")
  var value: uint32 = 0
  for _ in 0 ..< digits:
    let ch = p.text[p.pos]
    let digit =
      case ch
      of '0'..'9': uint32(ord(ch) - ord('0'))
      of 'a'..'f': uint32(ord(ch) - ord('a') + 10)
      of 'A'..'F': uint32(ord(ch) - ord('A') + 10)
      else:
        p.fail("invalid hex digit in unicode escape: " & $ch)
    value = value * 16 + digit
    inc p.pos
  if value > 0x10FFFF'u32 or (value >= 0xD800'u32 and value <= 0xDFFF'u32):
    p.fail("unicode escape is not a scalar value")
  encodeUtf8(value)

proc parseEscape(p: var TomlParser; into: var string) =
  ## One escape sequence; ``p.pos`` is on the backslash.
  inc p.pos
  if p.atEnd:
    p.fail("unterminated escape sequence")
  let esc = p.text[p.pos]
  inc p.pos
  case esc
  of '"': into.add '"'
  of '\\': into.add '\\'
  of 'b': into.add '\b'
  of 't': into.add '\t'
  of 'n': into.add '\n'
  of 'f': into.add '\f'
  of 'r': into.add '\r'
  of 'u': into.add p.parseHexEscape(4)
  of 'U': into.add p.parseHexEscape(8)
  else: p.fail("unknown escape sequence: \\" & $esc)

proc opensMultiline(p: TomlParser; quote: char): bool =
  p.pos + 2 < p.text.len and p.text[p.pos + 1] == quote and
    p.text[p.pos + 2] == quote

proc skipOpeningNewline(p: var TomlParser) =
  ## TOML trims a newline immediately after a multi-line opening delimiter.
  if p.text.continuesWith("\r\n", p.pos):
    p.pos += 2
  elif p.peek == '\n':
    inc p.pos

proc closesMultiline(p: var TomlParser; quote: char; into: var string): bool =
  ## At a ``quote``: whether it closes the string. Up to two quotes directly
  ## before the closing three belong to the content (``"""""`` closes after
  ## two content quotes), so the whole run is measured first.
  var run = 0
  while p.pos + run < p.text.len and p.text[p.pos + run] == quote:
    inc run
  if run < 3:
    for _ in 0 ..< run: into.add quote
    p.pos += run
    return false
  if run > 5:
    p.fail("too many quotes closing a multi-line string")
  for _ in 0 ..< run - 3: into.add quote
  p.pos += run
  true

proc parseMultilineBasicString(p: var TomlParser): string =
  p.pos += 3
  p.skipOpeningNewline()
  result = ""
  while true:
    if p.atEnd:
      p.fail("unterminated multi-line basic string")
    let ch = p.text[p.pos]
    case ch
    of '"':
      if p.closesMultiline('"', result):
        return
    of '\\':
      # A line-ending backslash trims the newline and all whitespace after it.
      var probe = p.pos + 1
      while probe < p.text.len and p.text[probe] in {' ', '\t'}:
        inc probe
      if probe < p.text.len and p.text[probe] in {'\n', '\r'}:
        p.pos = probe
        while not p.atEnd and p.text[p.pos] in {' ', '\t', '\r', '\n'}:
          inc p.pos
      else:
        p.parseEscape(result)
    of '\r':
      if p.text.continuesWith("\r\n", p.pos):
        result.add '\n'
        p.pos += 2
      else:
        result.add ch
        inc p.pos
    else:
      result.add ch
      inc p.pos

proc parseBasicString(p: var TomlParser): string =
  if p.opensMultiline('"'):
    if teMultilineStrings notin p.extensions:
      p.fail("multi-line basic strings are not part of this TOML subset")
    return p.parseMultilineBasicString()
  inc p.pos                     # opening quote
  result = ""
  while true:
    if p.atEnd:
      p.fail("unterminated basic string")
    let ch = p.text[p.pos]
    case ch
    of '"':
      inc p.pos
      return
    of '\n':
      p.fail("unterminated basic string")
    of '\\':
      p.parseEscape(result)
    else:
      result.add ch
      inc p.pos

proc parseMultilineLiteralString(p: var TomlParser): string =
  p.pos += 3
  p.skipOpeningNewline()
  result = ""
  while true:
    if p.atEnd:
      p.fail("unterminated multi-line literal string")
    let ch = p.text[p.pos]
    if ch == '\'':
      if p.closesMultiline('\'', result):
        return
    elif p.text.continuesWith("\r\n", p.pos):
      result.add '\n'
      p.pos += 2
    else:
      result.add ch
      inc p.pos

proc parseLiteralString(p: var TomlParser): string =
  if p.opensMultiline('\''):
    if teMultilineStrings notin p.extensions:
      p.fail("multi-line literal strings are not part of this TOML subset")
    return p.parseMultilineLiteralString()
  inc p.pos                     # opening quote
  result = ""
  while true:
    if p.atEnd:
      p.fail("unterminated literal string")
    let ch = p.text[p.pos]
    if ch == '\'':
      inc p.pos
      return
    if ch == '\n':
      p.fail("unterminated literal string")
    result.add ch
    inc p.pos

proc parseValue(p: var TomlParser): TomlNode
proc parseInlineTable(p: var TomlParser): TomlNode

proc parseArray(p: var TomlParser): TomlNode =
  ## Arrays may span lines and may carry a trailing comma — both appear in
  ## ``vectors/payload/escapes/received.toml``, whose whole purpose is to be a
  ## non-canonical rendering that must still parse to the same values.
  inc p.depth
  if p.depth > MaxTomlNesting:
    p.fail("arrays nested more than " & $MaxTomlNesting & " deep")
  defer: dec p.depth
  inc p.pos                     # '['
  result = TomlNode(kind: tomlArray, items: @[], fromValue: true)
  while true:
    p.skipToNextToken()
    if p.atEnd:
      p.fail("unterminated array")
    if p.peek == ']':
      inc p.pos
      return
    result.items.add p.parseValue()
    p.skipToNextToken()
    if p.atEnd:
      p.fail("unterminated array")
    case p.peek
    of ',': inc p.pos
    of ']':
      inc p.pos
      return
    else:
      p.fail("expected ',' or ']' in array, got: " & $p.peek)

proc parseValue(p: var TomlParser): TomlNode =
  if p.atEnd:
    p.fail("expected a value")
  case p.peek
  of '"': TomlNode(kind: tomlString, strVal: p.parseBasicString())
  of '\'': TomlNode(kind: tomlString, strVal: p.parseLiteralString())
  of '[': p.parseArray()
  of '{':
    if teInlineTables notin p.extensions:
      p.fail("inline tables are not part of this TOML subset")
    p.parseInlineTable()
  else:
    if p.text.continuesWith("true", p.pos):
      p.pos += 4
      TomlNode(kind: tomlBool, boolVal: true)
    elif p.text.continuesWith("false", p.pos):
      p.pos += 5
      TomlNode(kind: tomlBool, boolVal: false)
    else:
      p.fail("expected a string, boolean or array value")

proc parseBareKey(p: var TomlParser): string =
  result = ""
  while not p.atEnd and p.text[p.pos] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
    result.add p.text[p.pos]
    inc p.pos
  if result.len == 0:
    p.fail("expected a key")

proc parseKeyPath(p: var TomlParser): seq[string] =
  result = @[]
  while true:
    p.skipInlineSpace()
    if p.peek == '"':
      result.add p.parseBasicString()
    elif p.peek == '\'':
      result.add p.parseLiteralString()
    else:
      result.add p.parseBareKey()
    p.skipInlineSpace()
    if p.peek == '.':
      inc p.pos
    else:
      break

proc assign(p: var TomlParser; table: TomlNode; path: seq[string];
            value: TomlNode) =
  ## ``a.b.c = value`` relative to ``table``: dotted keys create tables, and
  ## no key — and no sealed (inline) table — is written twice.
  var target = table
  for i in 0 ..< path.high:
    let segment = path[i]
    if not target.fields.hasKey(segment):
      let created = newTomlTable()
      created.dotted = true
      target.fields[segment] = created
    let next = target.fields[segment]
    if next.kind != tomlTable:
      p.fail("'" & segment & "' is not a table")
    if next.sealed:
      p.fail("'" & segment & "' is an inline table and cannot be extended")
    target = next
  let key = path[^1]
  if target.fields.hasKey(key):
    p.fail("key '" & path.join(".") & "' is defined twice")
  target.fields[key] = value

proc parseInlineTable(p: var TomlParser): TomlNode =
  ## ``{ k = v, … }`` on one line, no trailing comma (TOML 1.0).
  inc p.depth
  if p.depth > MaxTomlNesting:
    p.fail("values nested more than " & $MaxTomlNesting & " deep")
  defer: dec p.depth
  inc p.pos                     # '{'
  result = newTomlTable()
  p.skipInlineSpace()
  if p.peek == '}':
    inc p.pos
    seal(result)
    return
  while true:
    let path = p.parseKeyPath()
    p.skipInlineSpace()
    if p.peek != '=':
      p.fail("expected '=' after key in inline table")
    inc p.pos
    p.skipInlineSpace()
    let value = p.parseValue()
    p.assign(result, path, value)
    p.skipInlineSpace()
    if p.atEnd:
      p.fail("unterminated inline table")
    case p.peek
    of ',':
      inc p.pos
      p.skipInlineSpace()
      if p.peek == '}':
        p.fail("an inline table may not end with a trailing comma")
    of '}':
      inc p.pos
      seal(result)
      return
    else:
      p.fail("expected ',' or '}' in inline table, got: " & $p.peek)

proc descend(p: var TomlParser; root: TomlNode; path: seq[string];
             arrayOfTables: bool): TomlNode =
  ## Walk (creating as needed) to the table a ``[header]`` names.
  var current = root
  for i, segment in path:
    let last = i == path.high
    if not current.fields.hasKey(segment):
      if last and arrayOfTables:
        current.fields[segment] = TomlNode(kind: tomlArray, items: @[])
      else:
        current.fields[segment] = newTomlTable()
    let child = current.fields[segment]
    if child.kind == tomlTable and child.sealed:
      p.fail("'" & segment & "' is an inline table and cannot be extended")
    if child.kind == tomlArray and child.fromValue:
      p.fail("'" & segment & "' is an array value, not an array of tables")
    if last and arrayOfTables:
      if child.kind != tomlArray:
        p.fail("'" & segment & "' is already a table, not an array of tables")
      let entry = newTomlTable()
      entry.explicit = true
      child.items.add entry
      return entry
    if child.kind == tomlArray:
      # A dotted header addressing the most recent element of an array of
      # tables, e.g. `[[a]]` followed by `[a.b]`.
      if child.items.len == 0 or child.items[^1].kind != tomlTable:
        p.fail("'" & segment & "' is an array of non-tables")
      current = child.items[^1]
    elif child.kind == tomlTable:
      current = child
    else:
      p.fail("'" & segment & "' is not a table")
    if last:
      if current.explicit:
        p.fail("table '" & path.join(".") & "' is defined twice")
      if current.dotted:
        # TOML forbids a header from reopening a table a dotted key created.
        # Accepting it would let one document set the same field twice with
        # different values, and leave the verifier to pick one silently.
        p.fail("table '" & path.join(".") &
               "' was already defined by a dotted key")
      current.explicit = true
  current

proc parseTomlSubset*(text: string;
                     extensions: set[TomlExtension] = {}): TomlNode =
  ## Parse the TOML subset test certificates and key stores are written in,
  ## plus the ``extensions`` the caller opts into.
  ##
  ## Raises ``TomlError`` on anything outside that subset. That is deliberate:
  ## a consumer that cannot read its key store must report **unverifiable**
  ## (Verification.md §3.1), which is only possible if the reader says so
  ## instead of returning a partially-populated document.
  var p = TomlParser(text: text, pos: 0, extensions: extensions)
  result = newTomlTable()
  result.explicit = true
  var current = result
  while true:
    p.skipToNextToken()
    if p.atEnd:
      break
    if p.peek == '[':
      inc p.pos
      let arrayOfTables = p.peek == '['
      if arrayOfTables:
        inc p.pos
      let path = p.parseKeyPath()
      p.skipInlineSpace()
      if p.peek != ']':
        p.fail("unterminated table header")
      inc p.pos
      if arrayOfTables:
        if p.peek != ']':
          p.fail("unterminated array-of-tables header")
        inc p.pos
      current = p.descend(result, path, arrayOfTables)
    else:
      let path = p.parseKeyPath()
      p.skipInlineSpace()
      if p.peek != '=':
        p.fail("expected '=' after key")
      inc p.pos
      p.skipInlineSpace()
      let value = p.parseValue()
      p.assign(current, path, value)
    # Trailing content on the line, other than a comment, is an error.
    p.skipInlineSpace()
    p.skipComment()
    if not p.atEnd and p.text[p.pos] notin {'\n', '\r'}:
      p.fail("unexpected trailing content: " & $p.text[p.pos])

proc field*(node: TomlNode; name: string): TomlNode =
  ## A child by name, or ``nil``. Callers MUST test for ``nil`` — this returns
  ## a value rather than raising because "absent" is a normal, meaningful state
  ## for every optional field in the format.
  if node == nil or node.kind != tomlTable: return nil
  if not node.fields.hasKey(name): return nil
  node.fields[name]

proc strField*(node: TomlNode; name: string): string =
  let child = node.field(name)
  if child == nil or child.kind != tomlString: "" else: child.strVal

proc strSeqField*(node: TomlNode; name: string): seq[string] =
  result = @[]
  let child = node.field(name)
  if child == nil or child.kind != tomlArray: return
  for item in child.items:
    if item.kind == tomlString:
      result.add item.strVal
