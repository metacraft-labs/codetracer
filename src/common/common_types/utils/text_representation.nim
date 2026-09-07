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
    "\"" & $value.text & "\""
  of Char:
    "'" & $value.c & "'"
  of CString:
    "\"" & $value.cText & "\""
  of Ref:
    "Ref:\n" & text(value.refValue, depth + 1)
  of Enum, Enum16, Enum32:
    "Enum(" & $value.enumInt & ")"
    # TODO
    #"Enum($1 $2)" % [$value.enumInt, $value.typ.enumNames[value.enumInt]]
  of TypeKind.TableKind:
    var items = value.items.mapIt(text(it[0], 0) & ": " & text(it[1], 0))
    "Table(" & $value.typ.langType & "):\n" & items.join("\n")
  of Union:
    "Union(" & $value.typ.langType & ")"
  of Pointer:
    let address = formatPointerAddress(value.address)
    var res = "Pointer(" & address & ")"
    if not value.refValue.isNil:
      res.add(":\n" & text(value.refValue, depth + 1))
    res
  of Raw:
    "Raw(" & $value.r & ")"
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
        "ref " & toLangType(typ.elementType, lang)
      of TableKind:
        $typ.langType
      of Variant:
        $typ.langType
      else:
        $typ.langType
  else:
    result = "!unimplemented"

# PLAT-2 REMOVED `textRepr`, `textReprDefault`, `textReprRust` AND
# `readableEnum` FROM THIS MODULE.
#
# They were the desktop's value formatter — one of seven implementations of
# "value -> string" in this repository — and every surface that called them now
# calls `common/value_presentation/presenter.present` through
# `common_types/utils/value_presentation_bridge.presentValue`. They are DELETED
# rather than deprecated, because a migration that leaves two paths is the
# specific failure PLAT-2's verification gate exists to prevent: a per-type
# visualiser would work in whichever surfaces happened to be on the new path.
# `ci/test/value-presentation-boundary.sh` fails on any reappearance.
#
# `text` / `$` BELOW ARE KEPT, and they are not a second formatter. `$value` is
# a multi-line DIAGNOSTIC DUMP — `"Sequence(Seq [Field; 4]):\n  100\n…"` — used
# by `echo` and by error messages, never by a pane. It was reached by a pane
# exactly once (`ui/state.valueDisplayText`, as a fallback for the kinds
# `textReprDefault` rendered as ""), and that call site is gone.
#
# THE BOUNDARY GUARD DOES *NOT* CATCH `$value`, and an earlier version of this
# comment claimed it did. A rule banning `$value` inside a surface was written,
# run, and REMOVED: all five of its hits were in `src/frontend/ui/value.nim` and
# all five were false positives — `$value` over a `float` in a chart histogram,
# and `$value.typ.langType`, which is a type NAME. `$` is not lexically
# separable from `$`-on-anything-else, so `ci/test/value-presentation-boundary.sh`
# declares this as a bound in its header rather than claiming it.
#
# What covers it instead, and the limit of that: the dump is VISIBLY multi-line,
# so a pane reaching it fails that pane's own rendering assertions rather than
# any structural gate. If you are adding a fallback in `ui/state.nim` or
# anywhere else that renders a value, NOTHING WILL STOP YOU writing `$v` here —
# reach for `ui/presented_value.nim` instead. This is also recorded in
# `.agents/codebase-insights.txt`.

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

