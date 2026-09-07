## value_presentation/value_model.nim — the ONE shape a recorded value has to
## be in before it can be presented.
##
## ## WHY A NORMALISED MODEL RATHER THAN `common_types.Value`
##
## This is forced, not preferred, and the reason is measurable in the tree:
##
##   * `common_types/language_features/value.nim`'s `Value` is defined inside an
##     `include` set that is instantiated TWICE with different bindings —
##     `src/common/types.nim` binds `langstring = string` / `TableLike = Table`,
##     `src/frontend/types.nim` binds `langstring = cstring` /
##     `TableLike = JsAssoc`. The two `Value`s are DIFFERENT, INCOMPATIBLE types
##     that share a name. `viewmodel/viewmodels/state_vm.nim`'s header says so
##     in as many words and refuses to import either.
##   * `viewmodel/headless_session.nim` — the TUI's only source of values —
##     therefore cannot see `Value` at all, and re-implemented the whole
##     renderer over `JsonNode` (`extractValueText`). That is the fourth of the
##     seven independent implementations this milestone exists to collapse.
##
## So a pipeline written against `Value` could serve the desktop and not the
## terminal, and a pipeline written against `JsonNode` could serve the terminal
## and not the desktop. `PValue` is written against neither: it is a plain tree
## of `string`, and it has one adapter per source. Every adapter is small,
## total, and testable on its own.
##
## ## EVERY SCALAR PAYLOAD IS CARRIED VERBATIM
##
## `text` holds exactly the bytes the recording produced — the wire already
## carries an integer as a STRING (`Value.i` is a `langstring`, not an int), and
## re-parsing it here would introduce a rounding decision this layer has no
## business making and would break byte-identity between a front-end that parsed
## and one that did not. Presentation adds quotes, brackets and separators; it
## never re-encodes a number.

import vocabulary

type
  PValueKind* = enum
    ## The recorded value's shape, normalised.
    ##
    ## MAPPED FROM `TypeKind`'s thirty-four members, not equal to them. Six
    ## `TypeKind`s collapse onto `pvkSequence` (`Seq`, `Set`, `HashSet`,
    ## `OrderedSet`, `Array`, `Varargs`, `Slice`) because a presentation cannot
    ## tell them apart other than by the brackets it draws, and the brackets are
    ## a function of `typeName` plus the language rather than of the kind. Three
    ## collapse onto `pvkEnum`. Keeping the distinction here would push a
    ## thirty-four-arm `case` into every presenter and into every front-end.
    pvkNil
    pvkInt
    pvkFloat
    pvkBool
    pvkString
    pvkChar
    pvkCString
    pvkEnum
    pvkSequence
    pvkRecord      ## `Instance` — named fields
    pvkTuple       ## positional fields
    pvkMap         ## `TableKind`
    pvkVariant     ## `Variant` / `Union`
    pvkPointer
    pvkReference   ## `Ref`
    pvkFunction
    pvkError
    pvkRaw
    pvkRecursion   ## a self-reference the recorder refused to follow
    pvkNotExpanded ## the recorder stopped here; more exists on request
    pvkOpaque      ## a kind this model does not name, carried rather than lost
    pvkMedia       ## bytes plus a MIME type — Project-Definitions §5.2

  PMember* = object
    ## One child of a container. `label` is "" for a positional member, which is
    ## the difference between a tuple and a record after normalisation.
    label*: string
    value*: PValue

  PEntry* = object
    ## One row of a `pvkMap`. The key is a VALUE, not a string — see
    ## `vocabulary.pkTable` for why that distinction is load-bearing.
    key*: PValue
    val*: PValue

  PValue* = ref object
    kind*: PValueKind
    typeName*: string
      ## the language's own name for the type (`i32`, `Point`, `dict`), verbatim
    sourceKind*: string
      ## the ENGINE's own name for the kind, verbatim — `Seq`, `HashSet`,
      ## `Array`, `Varargs`, `Instance`, `Enum16`. Carried because the
      ## normalisation above is lossy in exactly one way that PRESENTATION
      ## cares about: `@[…]`, `{…}`, `HashSet{…}` and `[…]` are four renderings
      ## of one `pvkSequence`, and the choice between them is the recorded
      ## kind's. Kept as a string rather than as a second enum so the model does
      ## not have to be edited every time the engine grows a kind — an
      ## unrecognised spelling falls back to the default delimiters rather than
      ## failing to compile.
    text*: string
      ## the scalar payload, verbatim. Also the enum's ORDINAL for `pvkEnum`,
      ## the address for `pvkPointer`, the message for `pvkError`, and the
      ## label for `pvkFunction`.
    enumName*: string
      ## `pvkEnum` only: the member's name when the recording carried one. Empty
      ## means the ordinal was out of range for the type's label list, which is
      ## a real recording state and renders differently from a named member.
    members*: seq[PMember]
    entries*: seq[PEntry]
    variantName*: string
      ## `pvkVariant` only
    target*: PValue
      ## `pvkPointer` / `pvkReference`: what it points at, or nil
    partial*: bool
      ## the RECORDING is incomplete here — the engine's `partiallyExpanded`.
      ## Distinct from a budget elision: one is a fact about the trace and the
      ## other is a fact about the surface, and conflating them tells a reader
      ## the debugger has no more data when the pane simply has no more room.
    mediaType*: string   ## `pvkMedia` only, e.g. `image/png`
    mediaBytes*: int     ## `pvkMedia` only

func isContainer*(k: PValueKind): bool =
  ## Whether the kind has members a surface may descend into.
  k in {pvkSequence, pvkRecord, pvkTuple, pvkMap, pvkVariant}

func childCount*(v: PValue): int =
  ## How many children `v` has, whatever kind of container it is.
  if v.isNil:
    0
  elif v.kind == pvkMap:
    v.entries.len
  else:
    v.members.len

func isHexLiteralText*(s: string): bool =
  ## `0x` followed by at least one hex digit and nothing else, optionally
  ## wrapped in the double quotes a `String`-carried field element arrives in.
  ##
  ## Written out rather than delegated to `parseHexInt` because that accepts a
  ## leading `-`, accepts `_` separators, and raises — none of which belongs in
  ## a `func` that classifies.
  var lo = 0
  var hi = s.len - 1
  if hi - lo + 1 >= 2 and s[lo] == '"' and s[hi] == '"':
    inc lo
    dec hi
  if hi - lo + 1 < 3:
    return false
  if s[lo] != '0' or (s[lo + 1] != 'x' and s[lo + 1] != 'X'):
    return false
  for i in lo + 2 .. hi:
    if s[i] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return false
  true

func isDecimalIntegerText*(s: string): bool =
  ## A bare, optionally signed run of digits. `""` is not one.
  if s.len == 0:
    return false
  var i = if s[0] == '-' or s[0] == '+': 1 else: 0
  if i >= s.len:
    return false
  while i < s.len:
    if s[i] notin {'0' .. '9'}:
      return false
    inc i
  true

func classOf*(v: PValue): PresentationClass =
  ## The value's semantic class — what a front-end colours it by.
  ##
  ## Kind-directed and therefore total: unlike
  ## `tui/app/formatters/type_formatters.classifyValue`, which had to INFER the
  ## class from the shape of an already-rendered string (`"…"` is a string,
  ## `[…]` a sequence) because that was all it was given, this reads the kind
  ## the engine reported. The inference is retained for exactly one case —
  ## `pcHexLiteral` below — where the engine reports `Int`/`String` and the
  ## recording's own spelling is the only signal.
  if v.isNil:
    return pcNone
  case v.kind
  of pvkNil: pcNone
  of pvkInt:
    if isHexLiteralText(v.text): pcHexLiteral else: pcInteger
  of pvkFloat: pcFloat
  of pvkBool: pcBoolean
  of pvkString, pvkCString:
    # A quoted `0x…` is how every field-element recorder in this workspace
    # renders a number — Noir's `Field` arrives as a `String`. Recognising it is
    # what lets the hex/decimal pair (`focusedText`) work from either side, and
    # it needs no per-language table.
    if isHexLiteralText(v.text): pcHexLiteral else: pcString
  of pvkChar: pcChar
  of pvkEnum: pcEnum
  of pvkSequence: pcSequence
  of pvkRecord: pcRecord
  of pvkTuple: pcTuple
  of pvkMap: pcMap
  of pvkVariant: pcVariant
  of pvkPointer, pvkReference: pcPointer
  of pvkFunction: pcFunction
  of pvkError: pcError
  of pvkRaw, pvkOpaque, pvkRecursion, pvkNotExpanded: pcOpaque
  of pvkMedia: pcMedia

func byteBufferOf*(v: PValue): seq[int] =
  ## The bytes `v` is, or an empty seq when it is not a byte buffer.
  ##
  ## EVERY member must be a `pvkInt` in `0 … 255` and there must be at least
  ## one, so `[1, 300]` is not a byte buffer and neither is `[]`. A predicate
  ## that accepted "most" members would render a sequence of small integers as
  ## a hex dump, which is a different value. Ported from
  ## `type_formatters.byteBufferOf`, which had to work from the rendered strings
  ## and therefore could not tell an integer from a string that looked like one.
  result = @[]
  if v.isNil or v.kind != pvkSequence or v.members.len == 0:
    return
  for m in v.members:
    let c = m.value
    if c.isNil or c.kind != pvkInt or not isDecimalIntegerText(c.text) or
       c.text.len > 3 or c.text[0] == '-':
      return @[]
    var n = 0
    for ch in c.text:
      n = n * 10 + (ord(ch) - ord('0'))
    if n > 255:
      return @[]
    result.add n

# ---------------------------------------------------------------------------
# Constructors — used by the adapters and by the suites, so that a value built
# in a test is built the same way a value decoded from a recording is.
# ---------------------------------------------------------------------------

func scalar*(kind: PValueKind; text: string; typeName = ""): PValue =
  PValue(kind: kind, text: text, typeName: typeName)

func container*(kind: PValueKind; members: seq[PMember]; typeName = "";
                partial = false): PValue =
  PValue(kind: kind, members: members, typeName: typeName, partial: partial)

func member*(label: string; value: PValue): PMember =
  PMember(label: label, value: value)
