type
  GdbValue* = object # placeholder

  Value* = ref object ## Representation of a language value
    kind*: TypeKind
    typ*: Type
    elements*: seq[Value]
    text*: langstring
    cText*: langstring
    f*: langstring
    i*: langstring
    enumInt*: BiggestInt
    c*: langstring
    b*: bool
    member*: seq[Value]
    refValue*: Value
    address*: langstring
    strong*: int
    weak*: int
    r*: langstring
    items*: seq[seq[Value]]
    kindValue*: Value
    children*: seq[Value]
    shared*: seq[Value]
    msg*: langstring
    signature*: langstring
    functionLabel*: langstring
    base*: langstring
    dict*: TableLike[langstring, Value]
    members*: seq[Value]
    fields*: TableLike[langstring, Value]
    isWatch*: bool
    isType*: bool
    expression*: langstring
    isLiteral*: bool
    activeVariant*: langstring
    activeVariantValue*: Value
    activeFields*: seq[langstring]
    gdbValue*: ref GdbValue # should be nil always out of python
    partiallyExpanded*: bool

  SubPathKind* = enum
    Expression,
    Field,
    Index,
    Dereference,
    VariantKind

  SubPath* = object
    typeKind*: TypeKind
    case kind*: SubPathKind
    of Expression:
      expression*: langstring
    of Field:
      name*: langstring
    of Index:
      index*: int
    of Dereference:
      discard
    of VariantKind:
      kindNumber*: int
      variantName*: langstring

  ExpandValueTarget* = object
    subPath*: seq[SubPath]
    rrTicks*: int
    isLoadMore*: bool
    startIndex*: int
    count*: int

  CtLoadLocalsArguments* = ref object
    rrTicks*: int
    countBudget*: int
    minCountLimit*: int
    
  CtLoadLocalsResponseBody* = ref object
    locals*: seq[Variable]

  Variable* = ref object
    expression*: langstring
    value*: Value
