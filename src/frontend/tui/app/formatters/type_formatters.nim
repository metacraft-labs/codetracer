## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/formatters/type_formatters.nim — CTUI-7. CodeTracer-TUI.md §3.3.4's
## "Type Formatters": numbers in decimal AND hexadecimal on focus, booleans,
## strings and byte buffers truncated cleanly, enums, pointers with a
## dereferenced target preview, and a compact inline summary for compound
## objects.
##
## ## IT CLASSIFIES BY THE VALUE'S SHAPE FIRST AND BY ITS TYPE NAME SECOND
##
## The obvious design is a table from language type names onto formatters, and
## it is wrong here for the reason `app/views/frame_item.classifyFrame` gives
## about magic directory names: a table of `int`/`i32`/`usize`/`Field`/`BigInt`
## is wrong for every language nobody thought of, and *silently* wrong — a value
## whose type name was not recognised renders as a plain string that looks
## exactly like a correctly rendered one.
##
## What this module gets is a `(typeName, value)` pair out of
## `store/types.Variable`, and the VALUE has already been rendered from the
## wire's `TypeKind` by `headless_session.extractValueText`. So the value's
## SHAPE is a projection of the kind the engine reported — `"…"` is a string,
## `true` is a boolean, `[…]` a sequence, `{…}` a struct, `(…)` a tuple, `nil`
## the empty value — and reading the shape is reading the engine's own answer.
## The type NAME is used for two things only: naming the type in its own column,
## and disambiguating a value whose shape says nothing (an empty rendering, or
## a bare word).
##
## Measured type names on CTUI-1's corpus (2026-09-06): `Int`, `Float`,
## `String`, `Bool`, `Dict`, `Tuple`, `Object`, `NoneType` (Python) and
## `Field`, `Bool`, `Array<8, ..>` (Noir). Note `Field` — a *numeric* type whose
## value arrives as a quoted `0x…` literal. A name table keyed on "Field" would
## have to be extended for every chain language; the hex-literal shape needs no
## table and covers all of them.
##
## ## THE HEX/DECIMAL PAIR GOES BOTH WAYS, BECAUSE THE CORPUS DOES
##
## §3.3.4 asks for "numeric types formatted in decimal and hexadecimal
## simultaneously upon focus". The corpus produces numbers in both directions —
## Python's `600` and Noir's
## `"0x…7d0"` — so `vcInteger` gains the hex on focus and `vcHexLiteral` gains
## the decimal. One rule, applied from whichever side the recording chose.
##
## ## A BYTE BUFFER IS RECOGNISED FROM ITS MEMBERS, NOT FROM ITS NAME
##
## `byteBufferOf` answers only when EVERY member is an integer in `0 … 255` and
## there is at least one, so a two-element `[1, 2]` is a byte buffer and a
## `[1, 300]` is not. **No fixture in CTUI-1's corpus produces one** — Noir's
## `Array<8, ..>` holds 32-byte field elements, not bytes — so this arm is
## exercised at Tier 1 on constructed values only. That gap is recorded here
## rather than hidden, exactly as `frame_item.nim` records the `lib` badge's.

import std/[strutils, unicode]

import ../views/styled_row

type
  ValueClass* = enum
    ## What one rendered value IS, as far as this pane is concerned.
    vcUnknown       ## nothing rendered, and no type name to go on
    vcInteger       ## a decimal integer
    vcHexLiteral    ## a `0x…` literal, quoted or bare — Noir's `Field`
    vcFloat
    vcBoolean
    vcString
    vcChar
    vcEnum
    vcPointer       ## an address, optionally with a dereferenced preview
    vcStruct        ## `{a: 1, b: 2}`
    vcSequence      ## `[1, 2, 3]`
    vcTuple         ## `(1, "x")`
    vcByteBuffer    ## a sequence whose every member is a byte
    vcNone          ## `nil`
    vcError         ## `<error: …>`
    vcOpaque        ## `<function f at 0x…>` and friends — a repr, not a value

const
  Ellipsis* = "…"
    ## One cell wide, so a truncated field's width is still its cell count.

  NumberStyle* = CellStyle(fg: "cyan")
  StringStyle* = CellStyle(fg: "bright_green")
    ## BRIGHT green rather than plain green, deliberately: plain green + bold is
    ## §3.3.4's diff accent (`diff_highlighter.ModifiedNameStyle`), and a string
    ## VALUE painted in the same colour as a CHANGED NAME would make the one
    ## thing this pane says loudest ambiguous on a screenshot.
  BooleanStyle* = CellStyle(fg: "magenta")
  PointerStyle* = CellStyle(fg: "bright_blue")
  CompoundStyle* = CellStyle(fg: "yellow")
  NoneStyle* = CellStyle(fg: "bright_black")
  ErrorStyle* = CellStyle(fg: "red")
  OpaqueStyle* = CellStyle(fg: "bright_black")
  DefaultValueStyle* = CellStyle(fg: "white")

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

func trimmedRange*(s: string): tuple[lo, hi: int] =
  ## The index range of `s` with leading and trailing blanks removed. `hi < lo`
  ## for an all-blank string.
  ##
  ## EVERY SHAPE TEST BELOW WORKS OVER A RANGE RATHER THAN OVER `s.strip()`,
  ## and that is a measured decision rather than a style. A compound value's
  ## rendering carries its whole member list — `wide_state`'s 600-entry mapping
  ## renders to about 12 KB — so a `strip()` per classification copied 12 KB to
  ## look at the first and last character, once per row per frame. Measured
  ## 2026-09-06 with this change and `truncateValue`'s reverted together, same
  ## host, same load: painting a 24-row pane holding that value cost ~11 ms
  ## before and ~4.3 ms after, against a 15 ms gate. The two halves are one
  ## optimisation — `classifyValue` and `truncateValue` are called on the same
  ## string on the same row — so the figure is reported for the pair.
  var lo = 0
  while lo < s.len and s[lo] in {' ', '\t', '\n', '\r'}:
    inc lo
  var hi = s.len - 1
  while hi >= lo and s[hi] in {' ', '\t', '\n', '\r'}:
    dec hi
  (lo, hi)

func isDecimalIntegerIn*(s: string; lo, hi: int): bool =
  ## Whether `s[lo .. hi]` is a bare, optionally signed run of digits.
  ##
  ## SHORT-CIRCUITS at the first character that is not one, so a 12 KB member
  ## list costs one comparison rather than 12 288.
  if hi < lo:
    return false
  var i = if s[lo] == '-' or s[lo] == '+': lo + 1 else: lo
  if i > hi:
    return false
  while i <= hi:
    if s[i] notin {'0' .. '9'}:
      return false
    inc i
  true

func isDecimalInteger*(s: string): bool =
  ## A bare, optionally signed run of digits. `""` is not one.
  let (lo, hi) = trimmedRange(s)
  lo == 0 and hi == s.len - 1 and isDecimalIntegerIn(s, lo, hi)

func isDecimalFloat*(s: string): bool =
  ## A decimal number carrying a `.` or an exponent. Written out rather than
  ## delegated to `parseFloat`, because `parseFloat` accepts `nan` and `inf`,
  ## which are words this module must not silently reclassify as numbers.
  if s.len == 0:
    return false
  var i = if s[0] == '-' or s[0] == '+': 1 else: 0
  var digits = 0
  var dots = 0
  var exponents = 0
  while i < s.len:
    case s[i]
    of '0' .. '9': inc digits
    of '.':
      inc dots
      if dots > 1: return false
    of 'e', 'E':
      inc exponents
      if exponents > 1 or digits == 0: return false
      if i + 1 < s.len and (s[i + 1] == '-' or s[i + 1] == '+'): inc i
    else: return false
    inc i
  digits > 0 and (dots == 1 or exponents == 1)

func isHexLiteralIn*(s: string; lo, hi: int): bool =
  ## Whether `s[lo .. hi]` is `0x` followed by at least one hex digit and
  ## nothing else. Short-circuits, for the reason `trimmedRange` records.
  if hi - lo + 1 < 3 or s[lo] != '0' or (s[lo + 1] != 'x' and s[lo + 1] != 'X'):
    return false
  for i in lo + 2 .. hi:
    if s[i] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return false
  true

func isHexLiteral*(s: string): bool =
  ## `0x` followed by at least one hex digit and nothing else.
  s.len >= 3 and isHexLiteralIn(s, 0, s.len - 1)

func unquoted*(s: string): string =
  ## The inside of a `"…"` rendering, or `s` unchanged.
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': s[1 ..< s.high] else: s

func isQuotedString*(s: string): bool =
  s.len >= 2 and s[0] == '"' and s[^1] == '"'

func isQuotedChar*(s: string): bool =
  s.len >= 2 and s[0] == '\'' and s[^1] == '\''

func wrappedIn(s: string; open, close: char): bool =
  s.len >= 2 and s[0] == open and s[^1] == close

func typeNameSuggests(typeName: string; words: openArray[string]): bool =
  ## Whether `typeName`, lowercased, IS or STARTS WITH one of `words`.
  ##
  ## Not `contains`: `Object` contains no word here and `NoneType` must not
  ## match `int` through a substring nobody intended.
  let lowered = typeName.toLowerAscii()
  for w in words:
    if lowered == w or lowered.startsWith(w & "<") or
       lowered.startsWith(w & "["):
      return true
  false

func equalsIn(s: string; lo, hi: int; literal: string): bool =
  ## Whether `s[lo .. hi]` is exactly `literal`, without slicing `s`.
  if hi - lo + 1 != literal.len:
    return false
  for i in 0 ..< literal.len:
    if s[lo + i] != literal[i]:
      return false
  true

func startsWithIn(s: string; lo, hi: int; prefix: string): bool =
  if hi - lo + 1 < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    if s[lo + i] != prefix[i]:
      return false
  true

func classifyValue*(typeName, value: string): ValueClass =
  ## What `value` is. The SHAPE decides; the NAME is the tiebreak. See this
  ## module's header for why that order and not the other one.
  ##
  ## The tests are ordered CHEAPEST FIRST and every one of them is O(1) or
  ## short-circuiting, except the two scans at the end — which are reached only
  ## by a value that is not bracket-wrapped, so the big compound renderings
  ## never pay for them. See `trimmedRange` for the measurement that forced it.
  let (lo, hi) = trimmedRange(value)
  if hi >= lo:
    let first = value[lo]
    let last = value[hi]
    if equalsIn(value, lo, hi, "nil"):
      return vcNone
    if startsWithIn(value, lo, hi, "<error:"):
      return vcError
    if equalsIn(value, lo, hi, "true") or equalsIn(value, lo, hi, "false"):
      return vcBoolean
    if first == '\'' and last == '\'' and hi > lo:
      return vcChar
    if first == '"' and last == '"' and hi > lo:
      # A quoted `0x…` is how every field-element recorder in this workspace
      # renders a number. See the header.
      return if isHexLiteralIn(value, lo + 1, hi - 1): vcHexLiteral
             else: vcString
    if first == '{' and last == '}':
      return vcStruct
    if first == '[' and last == ']':
      return vcSequence
    if first == '(' and last == ')':
      return vcTuple
    if first == '<' and last == '>':
      return vcOpaque
    if isHexLiteralIn(value, lo, hi):
      return vcHexLiteral
    if isDecimalIntegerIn(value, lo, hi):
      return vcInteger
    if equalsIn(value, lo, hi, "NULL"):
      return vcPointer
    let trimmed = value[lo .. hi]
    if isDecimalFloat(trimmed):
      return vcFloat
    if trimmed.contains(" -> ") and trimmed.split(" -> ")[0].isHexLiteral():
      return vcPointer
    if trimmed.contains("::"):
      return vcEnum

  # The shape said nothing. Fall back to the type name the engine reported.
  if typeNameSuggests(typeName, ["int", "integer", "long", "short", "byte",
                                 "usize", "isize", "field", "i8", "i16", "i32",
                                 "i64", "i128", "u8", "u16", "u32", "u64",
                                 "u128", "uint", "uint8", "uint16", "uint32",
                                 "uint64", "uint128", "number", "bigint"]):
    return vcInteger
  if typeNameSuggests(typeName, ["float", "double", "f32", "f64", "decimal"]):
    return vcFloat
  if typeNameSuggests(typeName, ["bool", "boolean"]):
    return vcBoolean
  if typeNameSuggests(typeName, ["str", "string", "cstring"]):
    return vcString
  if typeNameSuggests(typeName, ["char", "rune"]):
    return vcChar
  if typeNameSuggests(typeName, ["enum"]):
    return vcEnum
  if typeNameSuggests(typeName, ["ptr", "pointer", "ref"]):
    return vcPointer
  if typeNameSuggests(typeName, ["tuple"]):
    return vcTuple
  if typeNameSuggests(typeName, ["dict", "map", "list", "array", "seq", "vec",
                                 "set", "slice", "table"]):
    return vcSequence
  if typeNameSuggests(typeName, ["none", "nonetype", "nil", "unit", "void"]):
    return vcNone
  vcUnknown

func valueStyle*(class: ValueClass): CellStyle =
  ## The colour a value of this class is drawn in.
  case class
  of vcInteger, vcHexLiteral, vcFloat: NumberStyle
  of vcString, vcChar: StringStyle
  of vcBoolean, vcEnum: BooleanStyle
  of vcPointer: PointerStyle
  of vcStruct, vcSequence, vcTuple, vcByteBuffer: CompoundStyle
  of vcNone: NoneStyle
  of vcError: ErrorStyle
  of vcOpaque: OpaqueStyle
  of vcUnknown: DefaultValueStyle

# ---------------------------------------------------------------------------
# Numbers, both ways
# ---------------------------------------------------------------------------

func toHexLiteral*(decimal: string): string =
  ## `42` -> `0x2a`, `-42` -> `-0x2a`, and "" for anything that does not fit a
  ## `BiggestInt`.
  ##
  ## An out-of-range integer answers "" rather than a wrapped value: the whole
  ## point of showing hex beside decimal is that the two say the same thing, and
  ## a silently truncated companion says something else.
  if not isDecimalInteger(decimal):
    return ""
  var negative = false
  var body = decimal
  if body[0] == '-':
    negative = true
    body = body[1 .. ^1]
  elif body[0] == '+':
    body = body[1 .. ^1]
  var acc: BiggestInt = 0
  for c in body:
    let digit = BiggestInt(ord(c) - ord('0'))
    if acc > (high(BiggestInt) - digit) div 10:
      return ""
    acc = acc * 10 + digit
  # `toHex(value, digits)` keeps the LAST `digits` nibbles, so a width smaller
  # than the number silently truncates it — `toHex(306, 1)` is `"2"`. The width
  # is therefore the full one for a `BiggestInt` and the padding is stripped
  # afterwards.
  const NibblesInBiggestInt = sizeof(BiggestInt) * 2
  let hex = toLowerAscii(toHex(acc, NibblesInBiggestInt))
                .strip(chars = {'0'}, trailing = false)
  let digits = if hex.len == 0: "0" else: hex
  (if negative: "-0x" else: "0x") & digits

func fromHexLiteral*(hex: string): string =
  ## `0x2a` -> `42`, and "" for a VALUE too large for a `BiggestInt`.
  ##
  ## The bound is on the value, not on the literal's width, and that matters for
  ## every chain language in this workspace: a Noir field element is written as
  ## 64 hex digits whatever it holds, so
  ## `0x000…2710` answers `10000` and only a genuinely wide element answers "".
  ## An implementation that refused by DIGIT COUNT would drop the decimal
  ## companion from every Noir value the corpus actually records.
  if not isHexLiteral(hex):
    return ""
  var acc: BiggestInt = 0
  for i in 2 ..< hex.len:
    let c = hex[i]
    let digit =
      if c in {'0' .. '9'}: BiggestInt(ord(c) - ord('0'))
      elif c in {'a' .. 'f'}: BiggestInt(ord(c) - ord('a') + 10)
      else: BiggestInt(ord(c) - ord('A') + 10)
    if acc > (high(BiggestInt) - digit) div 16:
      return ""
    acc = acc * 16 + digit
  $acc

func normalisedHexLiteral*(hex: string): string =
  ## A `0x…` literal with its leading zeros removed, so a 32-byte field element
  ## reads `0x7d0` rather than as sixty characters of padding a reader has to
  ## count through. `0x000…0` normalises to `0x0`.
  if not isHexLiteral(hex):
    return hex
  var i = 2
  while i < hex.high and hex[i] == '0':
    inc i
  "0x" & hex[i .. ^1].toLowerAscii()

func focusedValue*(class: ValueClass; value: string): string =
  ## §3.3.4's "numeric types formatted in decimal and hexadecimal
  ## simultaneously upon focus", from whichever side the recording chose.
  ##
  ## Returns `value` unchanged when there is no second rendering to add, so a
  ## caller never has to ask whether the value is numeric first.
  if class notin {vcInteger, vcHexLiteral}:
    return value
  let v = value.strip()
  case class
  of vcInteger:
    let hex = toHexLiteral(v)
    if hex.len == 0: v else: v & " (" & hex & ")"
  of vcHexLiteral:
    let body = unquoted(v)
    let decimal = fromHexLiteral(body)
    let shown = normalisedHexLiteral(body)
    if decimal.len == 0: shown else: shown & " (" & decimal & ")"
  else:
    v

func compactValue*(class: ValueClass; value: string): string =
  ## The unfocused rendering: what a row shows when the cursor is elsewhere.
  ##
  ## The only class that differs from its raw text is `vcHexLiteral`, whose
  ## padding is noise on every row of a Noir pane.
  ##
  ## Returns `value` ITSELF for every other class rather than `value.strip()`:
  ## the decoder never pads a rendering, and stripping copied 12 KB per row for
  ## a large compound (see `trimmedRange`).
  if class != vcHexLiteral:
    return value
  normalisedHexLiteral(unquoted(value.strip()))

# ---------------------------------------------------------------------------
# Truncation
# ---------------------------------------------------------------------------

proc truncateValue*(text: string; cells: int): string =
  ## §3.3.4's "truncated cleanly": `cells` columns, ending in `…` when
  ## something was dropped.
  ##
  ## By CELL rather than by byte or rune, because a recorded string may hold a
  ## wide glyph and a pane whose value column overflowed by one column corrupts
  ## every column after it.
  ##
  ## BOUNDED BY `cells`, never by the length of `text`: the walk stops as soon
  ## as one more cell would overflow, so clipping a 12 KB member list to twenty
  ## columns costs twenty runes. `cellWidthOf(text) <= cells` was the first
  ## implementation and it measured the WHOLE string to decide — see
  ## `trimmedRange` for what that cost.
  if cells <= 0:
    return ""
  var fits = true
  var used = 0
  for r in runes(text):
    let w = max(1, cellWidthOf($r))
    if used + w > cells:
      fits = false
      break
    used += w
  if fits:
    return text
  if cells <= 1:
    return Ellipsis
  cellSlice(text, 0, cells - 1) & Ellipsis

func stringDetail*(value: string): string =
  ## The "expandable details" §3.3.4 asks for beside a truncated string: how
  ## long the whole thing is. In CHARACTERS, which is what a reader of a
  ## program means, rather than in bytes.
  let body = unquoted(value.strip())
  $body.runeLen & " chars"

# ---------------------------------------------------------------------------
# Byte buffers
# ---------------------------------------------------------------------------

func byteBufferOf*(members: openArray[string]): seq[int] =
  ## The bytes `members` are, or an empty seq when they are not bytes.
  ##
  ## EVERY member must be an integer in `0 … 255` and there must be at least
  ## one, so `[1, 300]` is not a byte buffer and neither is `[]`. A predicate
  ## that accepted "most" members would render a sequence of small integers as
  ## a hex dump, which is a different value.
  result = @[]
  if members.len == 0:
    return
  for m in members:
    let t = m.strip()
    if not isDecimalInteger(t) or t.len > 3 or t[0] == '-':
      return @[]
    var v = 0
    for c in t:
      v = v * 10 + (ord(c) - ord('0'))
    if v > 255:
      return @[]
    result.add v

func formatByteBuffer*(bytes: openArray[int]; maxBytes: int): string =
  ## `01 02 ff … (12 bytes)` — a hex dump bounded by `maxBytes`, with the full
  ## length always reported so the bound cannot be mistaken for the buffer.
  var parts: seq[string] = @[]
  for i in 0 ..< min(bytes.len, max(0, maxBytes)):
    parts.add toLowerAscii(toHex(bytes[i], 2))
  var text = parts.join(" ")
  if bytes.len > maxBytes:
    if text.len > 0: text.add " "
    text.add Ellipsis
  if text.len > 0: text.add " "
  text & "(" & $bytes.len & " bytes)"

# ---------------------------------------------------------------------------
# Compound summaries
# ---------------------------------------------------------------------------

func compactStructSummary*(typeName, value: string): string =
  ## §3.3.4's "compact inline summary for compound objects (e.g.
  ## `Point { x: 10, y: 20 }`)".
  ##
  ## The type name LEADS, which is the whole difference between a summary and
  ## the raw rendering: `{x: 10, y: 20}` could be any record, and the sentence
  ## §3.3.4 writes is the one a reader can act on.
  let v = value.strip()
  if typeName.len == 0 or not wrappedIn(v, '{', '}'):
    return v
  typeName & " " & v

func memberCountSuffix*(count: int; singular, plural: string): string =
  ## ` (600 entries)`. Empty for a count of zero, because a compound with no
  ## members already renders as `[]` or `{}` and the count adds nothing.
  if count <= 0: ""
  else: " (" & $count & " " & (if count == 1: singular else: plural) & ")"
