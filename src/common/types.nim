import os, tables
import lang

type
  defaultstring = string
  TableLike = Table
  langstring = string

include common_types

macro time*(f: untyped): untyped =
  f

let app* = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "codetracer"

proc isNone*[T](value: T): bool =
  value.isNil

proc `%`*(c: char): JsonNode =
  return %($c)

proc `%`*(t: (int, int)): JsonNode



# proc `%`*[V](t: Table[string, V]): JsonNode =
#   result = newJObject()
#   for v, i in t: result.fields[v] = %i

proc `%`*(t: (Value, Value)): JsonNode =
  result = %(@[t[0], t[1]])

# proc `%`*(t: Table[string, Value]): JsonNode =
#   result = newJObject()
#   for v, i in t: result.fields[v] = %i

proc `%`*(t: (int, int)): JsonNode =
  result = %(@[t[0], t[1]])

proc `==`*(a: Value, b: Value): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind == Any or b.kind == Any:
    return true
  if a.kind != b.kind:
    return false
  case a.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    if a.elements.len != b.elements.len:
      return false
    for j in low(a.elements)..<high(a.elements):
      if a.elements[j] != b.elements[j]:
        return false
    return true
  of Instance:
    return false
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
  of Enum, Enum16, Enum32:
    return a.typ.langType == b.typ.langType and a.i == b.i
  of Variant:
    return a.typ.langType == b.typ.langType and a.activeVariant == b.activeVariant
  else:
    return false

proc `==`*(a: Type, b: Type): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  case a.kind:
  of Int, Float, String, CString, Char, Bool:
    a.langType == b.langType
  else:
    # TODO
    false

# iterator unionChildren*(value: Value): (defaultstring, Value) =
#   # var kindValue = value.kindValue
#   # TODO shared
#   for name, field in value.fields:
#     yield (name, field)

let INT_TYPE = Type(kind: Literal, langType: "int")
let FLOAT_TYPE = Type(kind: Literal, langType: "float")
let STRING_TYPE = Type(kind: Literal, langType: "string")
let BOOL_TYPE = Type(kind: Literal, langType: "bool")
let CHAR_TYPE = Type(kind: Literal, langType: "char")
let RAW_TYPE* = Type(kind: Raw, langType: defaultstring(""), cType: defaultstring(""))
let NIL_VALUE*: Value = nil
let NIL_TYPE*: Type = nil

proc toLiteral*(i: int): Value =
  Value(kind: Int, i: $i, typ: INT_TYPE)

proc toLiteral*(f: float): Value =
  Value(kind: Float, f: $f, typ: FLOAT_TYPE)

proc toLiteral*(b: bool): Value =
  Value(kind: Bool, b: b, typ: BOOL_TYPE)

proc toLiteral*(text: string): Value =
  Value(kind: String, text: text, typ: STRING_TYPE)

proc toLiteral*(c: char): Value =
  Value(kind: Char, c: defaultstring($c), typ: CHAR_TYPE)

template toSequence*(argKind: TypeKind, argElements: seq[Value]): Value =
  assert len(`argElements`) > 0
  block:
    var res = Value(kind: `argKind`, elements: `argElements`, length: len(`argElements`), typ: Type(kind: `argKind`, elementType: `argElements`[0].typ, length: len(`argElements`), cType: defaultstring("")))
    res.typ.langType = toLangType(result.typ)
    res

proc toInstance*(langType: string, members: Table[string, Value]): Value =
  discard

proc toEnum*(langType: string, i: int, n: defaultstring): Value =
  Value(
    kind: Enum,
    enumInt: i,
    typ: Type(
      kind: Literal,
      langType: defaultstring(langType),
      cType: defaultstring("")))

proc baseName*(a: string): string =
  extractFilename(a)

import posix # os is already imported when not defined(js)

proc ensureExists*(program: string) =
  # TODO redirect output?
  # TODO enable
  discard
  # let output = execProcess(fmt"type {program}") #  &> /dev/null") #  &> /dev/null
  # if output# if code != 0: # LINUX_ERROR_NOT_FOUND_CODE:
  #   echo fmt"EXTERNAL COMMAND ERROR: PROGRAM NOT FOUND {program}"
  #   quit 1

proc stopProcess*(a: Pid, b: cint): int =
  posix.kill(a, b)
