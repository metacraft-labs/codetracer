proc asmName*(location: Location): langstring =
  ## Convert location object to string
  langstring(fmt"{location.path}:{location.functionName}")

when defined(js):
  proc jsParseUint64ToHex*(text: cstring): cstring {.importjs: "(function(s){try{const v=BigInt(s); if(v<0n) return \"\"; return v.toString(16);}catch(_){return \"\";}})(#)", nodecl.}
    ## Parse decimal text to hex using JS BigInt; returns empty string on invalid input.

func formatPointerAddress(address: langstring): string =
  ## Render pointer addresses as 0x-prefixed hex; fall back when the text is not a decimal number.
  let addressStr = $address
  if addressStr.len == 0:
    return addressStr
  if addressStr.startsWith("0x") or addressStr.startsWith("0X"):
    return addressStr
  when defined(js):
    let hex = $jsParseUint64ToHex(addressStr.cstring)
    if hex.len > 0:
      return "0x" & hex
  else:
    try:
      let parsed = parseBiggestUInt(addressStr)
      return "0x" & parsed.toHex
    except CatchableError:
      discard
  addressStr

proc text(value: Value, depth: int): string = #{.exportc: "textValue".}=
  ## Textual representation of a Value object
  var offset = repeat("  ", depth)
  var next = ""
  if value.isNil:
    next = "nil"
    return "$1$2" % [offset, next]
  next = case value.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    "Sequence($1 $2):\n$3" % [
      if not value.typ.isNil: $value.typ.kind else: "",
      if not value.typ.isNil: $value.typ.langType else: "",
      value.elements.mapIt(text(it, depth + 1)).join("\n")
    ]
  of Instance:
    var members = ""
    for i, name  in value.typ.labels:
      members.add("$1: $2\n" % [$name, text(value.members[i], 0)])

    if len(members) > 0:
      members = members[0 ..< ^1]
    "Instance($1):\n$2" % [
      $value.typ.langType,
      members
    ]
  of FunctionKind:
    "function<" & $value.functionLabel & ">"
  of Int:
    $value.i
  of Float:
    $value.f
  of Bool:
    $value.b
  of String:
    "\"$1\"" % $value.text
  of Char:
    "'$1'" % $value.c
  of CString:
    "\"$1\"" % $value.cText
  of Ref:
    "Ref:\n$1" % text(value.refValue, depth + 1)
  of Enum, Enum16, Enum32:
    "Enum($1)" % $value.enumInt
    # TODO
    #"Enum($1 $2)" % [$value.enumInt, $value.typ.enumNames[value.enumInt]]
  of TypeKind.TableKind:
    var items = value.items.mapIt("$1: $2" % [text(it[0], 0), text(it[1], 0)])
    "Table($1):\n$2" % [$value.typ.langType, items.join("\n")]
  of Union:
    "Union($1)" % $value.typ.langType
  of Pointer:
    let address = formatPointerAddress(value.address)
    var res = "Pointer($1)" % address
    if not value.refValue.isNil:
      res.add(":\n$1" % text(value.refValue, depth + 1))
    res
  of Raw:
    "Raw($1)" % $value.r
  of Variant:
    let fieldsText = if value.elements.len == 0: "" else: value.elements.mapIt(text(it, 0)).join(",")
    "$1::$2($3)" % [$value.typ.langType, $value.activeVariant, fieldsText]
  else:
    $value.kind
  result = "$1$2" % [offset, next]

proc `$`*(value: Value): string =
  ## Textual representation of a Value object
  try:
    return text(value, 0)
  except:
    return "<error>"

proc readableEnum*(value: Value): string =
  ## Textual representation of an enum value
  if value.kind in {Enum, Enum16, Enum32}:
    if value.enumInt <= value.typ.enumNames.high:
      result = $value.typ.enumNames[value.enumInt]
    else:
      result = $value.enumInt
  else:
    result = ""

proc toLangType*(typ: Type, lang: Lang): string =
  ## Original language textual representation of Type object, according to Lang
  if typ.isNil:
    return ""
  if lang == LangNim:
    result = case typ.kind:
      of Literal:
        toLowerAscii($typ.kind)
      of Seq, Set, HashSet, OrderedSet, Array, Varargs:
        var s = ""
        if typ.kind in {Seq, Set, Array, Varargs}:
          s = toLowerAscii($typ.kind)
        else:
          s = $typ.kind
        if typ.kind != Array:
          "$1[$2]" % [s, toLangType(typ.elementType, lang)]
        else:
          "$1[$2 $3]" % [s, $typ.length, toLangType(typ.elementType, lang)]
      of Instance:
        $typ.langType
      of Ref:
        "ref $1" % toLangType(typ.elementType, lang)
      of TableKind:
        $typ.langType
      of Variant:
        $typ.langType
      else:
        $typ.langType
  else:
    result = "!unimplemented"

func textReprDefault(value: Value, depth: int = 10): string

func textReprRust(value: Value, depth: int = 10, compact: bool = false): string

proc textRepr*(value: Value, depth: int = 10, lang: Lang = LangUnknown, compact: bool = false): string #{.exportc.}

proc testEq*(a: Value, b: Value, langType: bool = true): bool =
  ## Compare two values for equality
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    # echo "no kind"
    return false
  # echo "eq ", a, " ", b
  case a.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    if a.kind != b.kind or len(a.elements) != len(b.elements):
      # echo "not kind Seq"
      return false
    else:
      for j in 0..<len(a.elements):
        if not a.elements[j].testEq(b.elements[j]):
          return false
    return true
  of Instance:
    if a.elements.len != b.elements.len:
      return false
    if a.typ.langType != b.typ.langType:
      return false
    for i, element in a.elements:
      var bElement = b.elements[i]
      if not element.testEq(bElement):
        return false
    return true
  of Int:
    return a.i == b.i
  of Float:
    return a.f == b.f
  of String:
    return a.text == b.text
  of CString:
    return a.cText == b.cText
  of Char:
    return a.c == b.c
  of Bool:
    return a.b == b.b
  of Ref:
    return a.refValue.testEq(b.refValue, false)
  of Enum, Enum16, Enum32:
    return a.i == b.i
  of TableKind:
    if len(a.items) != len(b.items):
      return false
    else:
      for z in 0..<len(a.items):
        if not a.items[z][0].testEq(b.items[z][0]) or
           not a.items[z][1].testEq(b.items[z][1]):
          return false
    return true
  of Union:
    if a.kindValue.enumInt != b.kindValue.enumInt:
      return false
    # var c = a.kindValue
    return false
  of Pointer:
    return false #a.address == b.address
  of Raw:
    return a.r == b.r
  of Error:
    return a.msg == b.msg
  of FunctionKind:
    return a.functionLabel == b.functionLabel and a.signature == b.signature
  of TypeValue:
    if a.base != b.base:
      return false
    for label, member in a.dict:
      var bMember = b.dict[label]
      if bMember.isNil:
        return false
      if not member.testEq(bMember):
        return false
    return true
  of Tuple:
    if len(a.elements) != len(b.elements):
      return false
    return zip(a.elements, b.elements).allIt(it[0].testEq(it[1]))
  of Variant:
    if a.activeVariant != b.activeVariant:
      return false
    return zip(a.elements, b.elements).allIt(it[0].testEq(it[1]))
  of None:
    return true
  else:
    return false

func `$`*(location: Location): string =
  ## Textual representation of location
  &"Location {location.path}:{location.line}"

iterator unionChildren*(value: Value): (defaultstring, Value) =
  ## Yield name and value for each value field
  case value.kind:
  of Instance:
    for i, field in value.elements:
      if not value.typ.isNil and value.typ.kind == Instance and value.typ.labels.len >= i + 1:
        yield (value.typ.labels[i], field)
  of Variant:
    let variantValue = value.activeVariantValue
    debugecho "unionChildren variant"
    if variantValue.kind == Instance:
      for i, field in variantValue.elements:
        if not variantValue.typ.isNil and variantValue.typ.kind == Instance and variantValue.typ.labels.len >= i + 1:
          yield (variantValue.typ.labels[i], field)
    elif variantValue.kind == Tuple:
      for i, element in variantValue.elements:
        yield (defaultstring($i), element)
  else:
    discard

func textReprDefault(value: Value, depth: int = 10): string =
  # a repr of a language value, we probably have to do this for each lang:
  # TODO language-specific display?
  # for now we mostly use the same repr
  if value.isNil:
    return "nil"
  if depth <= 0:
    return "#"
  result = case value.kind:
  of Int:
    $value.i
  of String:
    "\"$1\"" % $value.text
  of Bool:
    $value.b
  of Float:
    $value.f
  of Char:
    "'$1'" % $value.c
  of CString:
    "\"$1\"" % $value.cText
  of Enum:
    if value.enumInt < value.typ.enumNames.len:
      $value.typ.enumNames[value.enumInt]
    else:
      &"{value.typ.langType}({value.enumInt})"
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    let elements = value.elements
    var l = ""
    let e = elements.mapIt(textReprDefault(it, depth - 1)).join(", ")
    let openText: array[6, string] = ["@[", "{", "HashSet{", "OrderedSet{", "[", "varargs["]
    let closeText: array[6, string] = ["]", "}", "}", "}", "]", "]"]
    let more = if value.partiallyExpanded: ".." else: ""
    l = openText[value.kind.int - Seq.int] & e
    l = l & more & closeText[value.kind.int - Seq.int]
    l
  of Instance:
    var record = ""
    for i, field in value.elements:
      if showable(field):
        record.add(&"{value.typ.labels[i]}:{textReprDefault(field, depth - 1)}")
        record.add(",")
      else:
        record.add(&"{value.typ.labels[i]}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record = &"{value.typ.langType}({record})"
    record
  of Union:
    var record = ""
    for name, field in unionChildren(value):
      # echo "textRepr ", name
      # if showable(field):
      record.add(&"{name}:{textReprDefault(field, depth - 1)}")
      record.add(", ")
      # else:
        # record.add(&"{name}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record = &"#{value.kindValue.textReprDefault}({record})"
    record
  of Ref:
    textReprDefault(value.refValue, depth)
  of Pointer:
    let address = formatPointerAddress(value.address)
    if not value.refValue.isNil: &"{address} -> ({textReprDefault(value.refValue)})" else: "NULL"
  of Recursion:
    "this"
  of Raw:
    "raw:" & $value.r
  of C:
    "c"
  of TableKind:
    let items = value.items
    var l = ""
    let more = if value.partiallyExpanded: ".." else: ""
    for item in items:
      l &= item.mapIt(textReprDefault(it, depth - 1)).join(": ") & " "
    l & more
    # $value.typ.langType & SUMMARY_EXPAND
  of Error:
    $value.msg
  of FunctionKind:
    &"function<{value.functionLabel}>" # $value.signature
  of TypeValue:
    $value.base
  of Tuple:
    var l = ""
    let elements = value.elements.mapIt(textReprDefault(it, depth - 1)).join(", ")
    l = "(" & elements & ")"
    l
  of Variant:
    var res: seq[string]
    if not value.activeVariantValue.isNil:
      fmt"""{value.typ.langType}::{textReprDefault(value.activeVariantValue)}"""
    elif value.activeFields.len != 0:
      var elements = value.elements[1..^1]
      var fieldsText: seq[string]
      fieldsText = elements.mapIt(textReprDefault(it, depth - 1))
      for i, v in fieldsText:
        res.add(fmt"{value.activeFields[i+1]}: {v}")
      fmt"""{value.typ.langType}::{textReprDefault(value.elements[0])}({res.join(", ")})"""
    else:
      var elements = value.elements
      res = value.elements.mapIt(textReprDefault(it, depth - 1))
      fmt"""{value.typ.langType}::{value.activeVariant}({res.join(", ")})"""
  of Html:
    "html"
  of TypeKind.None:
    "nil"
  of NonExpanded:
    ".."
  else:
    ""

func textReprRust(value: Value, depth: int = 10, compact: bool = false): string =
  let langType = if compact:
                   strutils.join(value.typ.langType.split("::")[1..^1], "::")
                 else:
                   $value.typ.langType
  if value.isNil:
    return "nil"
  if depth <= 0:
    return "#"
  result = case value.kind:
  of Int:
    if compact:
      fmt"{value.i}"
    else:
      fmt"{value.i}{value.typ.cType}"
  of String:
    "\"$1\"" % $value.text
  of Float:
    if compact:
      fmt"{value.f}"
    else:
      fmt"{value.f}{value.typ.cType}"
  of Seq, Array:
    let elements = value.elements
    var l = ""
    let e = elements.mapIt(textReprRust(it, depth - 1, compact)).join(", ")
    let more = if value.partiallyExpanded: ".." else: ""
    if (value.kind == Seq):
      l = "vec![" & e & more & "]"
    else:
      l = "[" & e & more & "]"
    l
  of Instance:
    var record = "{"
    for i, field in value.elements:
      if showable(field):
        record.add(&"{value.typ.labels[i]}:{textReprRust(field, depth - 1, compact)}")
        record.add(",")
      else:
        record.add(&"{value.typ.labels[i]}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record.add("}")
    record = &"{langType}{record}"
    record
  of Ref:
     &"ref {langType}: {textReprRust(value.refValue, depth, compact)}"
  of Pointer:
    let address = formatPointerAddress(value.address)
    if not value.refValue.isNil: &"{address} -> {textReprRust(value.refValue, depth, compact)}" else: "NULL"
  of FunctionKind:
    &"fn {value.functionLabel}: {value.signature}" # $value.signature
  of Tuple:
    let elements = value.elements.mapIt(textReprRust(it, depth - 1, compact)).join(", ")
    "(" & elements & ")"
  of Variant:
    if value.activeVariantValue.kind == Instance:
      var record = "{"
      for i, field in value.activeVariantValue.elements:
        if showable(field):
          record.add(&"{value.activeVariantValue.typ.labels[i]}:{textReprRust(field, depth - 1, compact)}")
          record.add(",")
        else:
          record.add(&"{value.activeVariantValue.typ.labels[i]}:..")
      if record.len > 1: # has at least something else than `{`
        record.setLen(record.len - 1)
        record.add("}")
      else:
        record = "" # e.g. Node Nil, with Nil having no fields => Node::Nil, not Node::Nil{}
      fmt"""{value.activeVariant}{record}"""
    elif value.activeVariantValue.kind == Variant and value.activeVariantValue.activeVariantValue.kind == Instance:
      fmt"""{textReprRust(value.activeVariantValue, depth, compact)}"""
    elif value.activeVariantValue.kind == None:
      fmt"""{langType}::{value.activeVariant}"""
    elif value.activeVariantValue.kind == Tuple:
      # tuples already have ()
      fmt"""{value.activeVariant}{textReprRust(value.activeVariantValue, depth, compact)}"""
    else:
      fmt"""{value.activeVariant}({textReprRust(value.activeVariantValue, depth, compact)})"""
  else:
    textReprDefault(value, depth)

proc textRepr*(value: Value, depth: int = 10, lang: Lang = LangUnknown, compact: bool = false): string = #{.exportc.} =
  ## Text representation of Value, depending on lang
  case lang:
    of LangUnknown:
      if CURRENT_LANG != LangUnknown:
        textRepr(value, depth, CURRENT_LANG, compact)
      else:
        textReprDefault(value, depth)
    of LangRust:
      textReprRust(value, depth, compact)
    else:
      textReprDefault(value, depth)
