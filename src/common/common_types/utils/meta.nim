proc isIntShape*(shape: Value): bool =
  ## Is value int shaped
  not shape.isNil and shape.kind == Int

proc isStringShape*(shape: Value): bool =
  ## Is value string shaped
  not shape.isNil and shape.kind == String

proc isNumberShape*(shape: Value): bool =
  ## Is value number shaped
  not shape.isNil and shape.kind in {Int, Float}

proc isFloatShape*(shape: Value): bool =
  ## Is value float shaped
  not shape.isNil and shape.kind == Float

# text_representation.nim

func showable(value: Value): bool =
  ## Is value showabse. Currently always true
  true

proc simple*(value: Value): bool =
  ## Is value simple? not-Nil and one of {Int, Float, String, CString, Char, Bool,
  ##  Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}
  not value.isNil and
  value.kind in {Int, Float, String, CString, Char, Bool,
    Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}

proc simple*(typ: Type): bool =
  ## Is type simple? not-Nil and one of {Int, Float, String, CString, Char, Bool,
  ##  Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}
  not typ.isNil and
  typ.kind in {Int, Float, String, CString, Char, Bool,
    Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}
